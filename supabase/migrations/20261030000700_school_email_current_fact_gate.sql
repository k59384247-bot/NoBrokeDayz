begin;

create or replace function app_private.maybe_qualify_track_a(p_actor uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_qualified boolean := false;
  v_event_id uuid;
begin
  if exists (
    select 1
    from app_private.identity_accounts account
    join auth.users auth_user on auth_user.id = account.user_id
    join app_private.institutional_email_ownerships ownership
      on ownership.user_id = account.user_id and ownership.revoked_at is null
    join app_private.institutional_email_domains allow_domain
      on allow_domain.domain = pg_catalog.split_part(ownership.normalized_email, '@', 2)
     and allow_domain.enabled
    join app_private.identity_phone_bindings phone
      on phone.user_id = account.user_id
     and phone.phone_e164 = '+' || auth_user.phone
     and phone.verified_at = auth_user.phone_confirmed_at
    where account.user_id = p_actor
      and account.account_type = 'student'
      and account.age_confirmed_at is not null
      and account.account_status = 'active'
      and auth_user.email is not null
      and auth_user.email_confirmed_at is not null
      and auth_user.phone_confirmed_at is not null
      and nullif(auth_user.phone_change, '') is null
  ) then
    update app_private.identity_accounts
    set verification_track = 'track_a_school_email',
        verification_status = 'approved',
        updated_at = pg_catalog.now()
    where user_id = p_actor
      and (verification_track is null or verification_track = 'track_a_school_email')
      and verification_status in ('unverified', 'approved');

    if found then
      insert into app_private.identity_capabilities (user_id, capability, source)
      values
        (p_actor, 'can_hire', 'track_a_school_email'),
        (p_actor, 'can_work', 'track_a_school_email')
      on conflict (user_id, capability) do nothing;
      if found then
        insert into app_private.identity_audit_events (actor_id, subject_id, event_type, event_data)
        values (
          p_actor,
          p_actor,
          'track_a_school_email_qualified',
          pg_catalog.jsonb_build_object('source', 'supplementary_school_email', 'capabilities', pg_catalog.jsonb_build_array('can_hire', 'can_work'))
        ) returning event_id into v_event_id;
        insert into app_private.identity_outbox (event_id, subject_id, event_type, payload)
        values (
          v_event_id,
          p_actor,
          'track_a_school_email_qualified',
          pg_catalog.jsonb_build_object('capabilities', pg_catalog.jsonb_build_array('can_hire', 'can_work'))
        );
      end if;
      v_qualified := true;
    end if;
  end if;
  return v_qualified;
end;
$function$;
revoke all on function app_private.maybe_qualify_track_a(uuid) from public, anon, authenticated, service_role;

create or replace function public.get_my_identity_status()
returns jsonb language plpgsql stable security definer set search_path = '' as $function$
declare
  v_actor uuid := auth.uid();
  v_identity app_private.identity_accounts%rowtype;
  v_school_email_verified boolean;
  v_phone_verified boolean;
  v_capabilities jsonb := '[]'::jsonb;
begin
  if v_actor is null then raise exception using errcode = '28000', message = 'authentication required'; end if;
  select exists (
    select 1 from app_private.identity_phone_bindings binding
    join auth.users auth_user on auth_user.id = binding.user_id
    where binding.user_id = v_actor and binding.phone_e164 = '+' || auth_user.phone
      and binding.verified_at = auth_user.phone_confirmed_at
      and auth_user.phone_confirmed_at is not null and nullif(auth_user.phone_change, '') is null
  ) into v_phone_verified;
  select * into v_identity from app_private.identity_accounts where user_id = v_actor;
  if not found then return pg_catalog.jsonb_build_object('registered', false, 'phone_verified', v_phone_verified); end if;
  select exists (
    select 1 from app_private.institutional_email_ownerships ownership
    join app_private.institutional_email_domains allow_domain
      on allow_domain.domain = pg_catalog.split_part(ownership.normalized_email, '@', 2)
     and allow_domain.enabled
    where ownership.user_id = v_actor and ownership.revoked_at is null
  ) into v_school_email_verified;
  if v_identity.account_status = 'active' and v_phone_verified and v_school_email_verified
     and v_identity.age_confirmed_at is not null
     and v_identity.verification_status = 'approved'
     and exists (select 1 from auth.users u where u.id = v_actor and u.email is not null and u.email_confirmed_at is not null) then
    select coalesce(pg_catalog.jsonb_agg(capability order by capability), '[]'::jsonb) into v_capabilities
    from app_private.identity_capabilities where user_id = v_actor and revoked_at is null;
  end if;
  return pg_catalog.jsonb_build_object(
    'registered', true, 'account_type', v_identity.account_type,
    'age_confirmed', v_identity.age_confirmed_at is not null,
    'account_status', v_identity.account_status,
    'verification_track', v_identity.verification_track,
    'verification_status', v_identity.verification_status,
    'institutional_email_verified', v_school_email_verified,
    'phone_verified', v_phone_verified,
    'capabilities', v_capabilities
  );
end;
$function$;
revoke all on function public.get_my_identity_status() from public, anon, authenticated, service_role;
grant execute on function public.get_my_identity_status() to authenticated;

commit;
