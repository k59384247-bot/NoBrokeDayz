begin;

create table app_private.institutional_email_domains (
  domain text primary key check (domain = lower(domain) and domain !~ '[^a-z0-9.-]' and domain !~ '(^\.|\.$|\.\.|--)'),
  enabled boolean not null default true,
  environment text not null check (environment in ('synthetic_local', 'production'))
);
revoke all on table app_private.institutional_email_domains from public, anon, authenticated, service_role;

create table app_private.identity_capabilities (
  user_id uuid not null references app_private.identity_accounts (user_id) on delete cascade,
  capability text not null check (capability in ('can_hire', 'can_work')),
  source text not null check (source in ('track_a_school_email', 'track_a_manual', 'track_b_partner')),
  granted_at timestamptz not null default now(),
  revoked_at timestamptz,
  primary key (user_id, capability),
  check (revoked_at is null or revoked_at >= granted_at)
);
revoke all on table app_private.identity_capabilities from public, anon, authenticated, service_role;

create index school_email_issue_rate_idx
  on app_private.school_email_challenges (user_id, normalized_email, created_at desc);

create function app_private.school_email_normalize(p_email text)
returns text
language plpgsql
immutable
set search_path = ''
as $function$
declare
  v_email text := pg_catalog.lower(pg_catalog.btrim(p_email));
  v_domain text;
begin
  if v_email is null or pg_catalog.char_length(v_email) not between 3 and 254
     or v_email !~ '^[a-z0-9.!#$%&''*+/=?^_`{|}~-]+@[a-z0-9.-]+$'
     or v_email like '%..%' then
    return null;
  end if;
  v_domain := pg_catalog.split_part(v_email, '@', 2);
  if v_domain is null or v_domain = '' or pg_catalog.strpos(v_domain, '.') = 1
     or pg_catalog.right(v_domain, 1) = '.' then
    return null;
  end if;
  return v_email;
end;
$function$;
revoke all on function app_private.school_email_normalize(text) from public, anon, authenticated, service_role;

create function app_private.maybe_qualify_track_a(p_actor uuid)
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

create function app_private.reconcile_track_a_auth_facts()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  perform app_private.maybe_qualify_track_a(new.id);
  return new;
end;
$function$;
revoke all on function app_private.reconcile_track_a_auth_facts() from public, anon, authenticated, service_role;
create trigger auth_users_reconcile_track_a
after update of email, email_confirmed_at, phone, phone_change, phone_confirmed_at on auth.users
for each row execute function app_private.reconcile_track_a_auth_facts();

create function app_private.begin_school_challenge_for_actor(
  p_actor uuid,
  p_email text,
  p_code_digest text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_email text := app_private.school_email_normalize(p_email);
  v_domain text;
  v_version integer;
  v_challenge uuid;
  v_account app_private.identity_accounts%rowtype;
begin
  if v_email is null or p_code_digest !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = '22023', message = 'invalid_request';
  end if;
  v_domain := pg_catalog.split_part(v_email, '@', 2);
  if not exists (
    select 1 from app_private.institutional_email_domains d
    where d.domain = v_domain and d.enabled
  ) then
    return pg_catalog.jsonb_build_object('issued', false, 'state', 'unavailable');
  end if;
  select * into v_account from app_private.identity_accounts where user_id = p_actor for update;
  if not found or v_account.account_type <> 'student' then
    return pg_catalog.jsonb_build_object('issued', false, 'state', 'unavailable');
  end if;
  if exists (
    select 1 from auth.users u
    where u.id = p_actor and pg_catalog.lower(u.email) = v_email
  ) then
    return pg_catalog.jsonb_build_object('issued', false, 'state', 'unavailable');
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_actor::text || ':' || v_email, 916203));
  if exists (
    select 1 from app_private.school_email_challenges c
    where c.user_id = p_actor and c.normalized_email = v_email
      and c.created_at > pg_catalog.now() - interval '60 seconds'
  ) then
    raise exception using errcode = '22023', message = 'rate_limited';
  end if;
  if (select pg_catalog.count(*) from app_private.school_email_challenges c
      where c.user_id = p_actor and c.normalized_email = v_email
        and c.created_at > pg_catalog.now() - interval '1 hour') >= 5
     or (select pg_catalog.count(*) from app_private.school_email_challenges c
      where c.user_id = p_actor and c.normalized_email = v_email
        and c.created_at > pg_catalog.now() - interval '24 hours') >= 10 then
    raise exception using errcode = '22023', message = 'rate_limited';
  end if;

  update app_private.school_email_challenges
  set invalidated_at = pg_catalog.now()
  where user_id = p_actor and normalized_email = v_email
    and consumed_at is null and invalidated_at is null;
  select coalesce(pg_catalog.max(challenge_version), 0) + 1 into v_version
  from app_private.school_email_challenges
  where user_id = p_actor and normalized_email = v_email;
  insert into app_private.school_email_challenges (
    user_id, normalized_email, challenge_version, code_digest, digest_key_version, expires_at
  ) values (
    p_actor, v_email, v_version, pg_catalog.decode(p_code_digest, 'hex'), 1, pg_catalog.now() + interval '10 minutes'
  ) returning challenge_id into v_challenge;
  return pg_catalog.jsonb_build_object('issued', true, 'challenge_id', v_challenge);
end;
$function$;
revoke all on function app_private.begin_school_challenge_for_actor(uuid, text, text) from public, anon, authenticated, service_role;

create function app_private.fail_school_challenge_for_actor(p_actor uuid, p_challenge_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
begin
  update app_private.school_email_challenges
  set invalidated_at = pg_catalog.now()
  where challenge_id = p_challenge_id and user_id = p_actor
    and consumed_at is null and invalidated_at is null;
  return pg_catalog.jsonb_build_object('invalidated', found);
end;
$function$;
revoke all on function app_private.fail_school_challenge_for_actor(uuid, uuid) from public, anon, authenticated, service_role;

create function app_private.confirm_school_challenge_for_actor(
  p_actor uuid,
  p_challenge_id uuid,
  p_code_digest text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_challenge app_private.school_email_challenges%rowtype;
  v_match boolean := true;
  v_difference integer := 0;
  v_i integer;
  v_inserted uuid;
  v_qualified boolean;
  v_event_id uuid;
  v_expected bytea;
  v_actual bytea;
begin
  if p_code_digest !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = '22023', message = 'invalid_challenge';
  end if;
  select * into v_challenge
  from app_private.school_email_challenges
  where challenge_id = p_challenge_id and user_id = p_actor
  for update;
  if not found or v_challenge.consumed_at is not null or v_challenge.invalidated_at is not null
     or v_challenge.expires_at <= pg_catalog.now() or v_challenge.failed_attempts >= 5 then
    raise exception using errcode = '22023', message = 'invalid_challenge';
  end if;
  v_actual := pg_catalog.decode(p_code_digest, 'hex');
  v_expected := v_challenge.code_digest;
  for v_i in 0..31 loop
    v_difference := v_difference | (pg_catalog.get_byte(v_actual, v_i) # pg_catalog.get_byte(v_expected, v_i));
  end loop;
  v_match := v_difference = 0;
  if not v_match then
    update app_private.school_email_challenges
    set failed_attempts = failed_attempts + 1,
        invalidated_at = case when failed_attempts + 1 >= 5 then pg_catalog.now() else null end
    where challenge_id = p_challenge_id;
    return pg_catalog.jsonb_build_object('confirmed', false, 'qualified', false, 'next_steps', pg_catalog.jsonb_build_array('check_code_or_request_new'));
  end if;

  update app_private.school_email_challenges
  set consumed_at = pg_catalog.now()
  where challenge_id = p_challenge_id;

  insert into app_private.institutional_email_ownerships (user_id, normalized_email)
  values (p_actor, v_challenge.normalized_email)
  on conflict do nothing
  returning user_id into v_inserted;
  if v_inserted is null and not exists (
    select 1 from app_private.institutional_email_ownerships ownership
    where ownership.user_id = p_actor and ownership.normalized_email = v_challenge.normalized_email
      and ownership.revoked_at is null
  ) then
    -- A different account owns this address. Consume the proof without disclosing that fact.
    return pg_catalog.jsonb_build_object('confirmed', false, 'qualified', false, 'next_steps', pg_catalog.jsonb_build_array('contact_support'));
  end if;

  if v_inserted is not null then
    insert into app_private.identity_audit_events (actor_id, subject_id, event_type, event_data)
    values (p_actor, p_actor, 'institutional_email_verified', pg_catalog.jsonb_build_object('challenge_version', v_challenge.challenge_version))
    returning event_id into v_event_id;
    insert into app_private.identity_outbox (event_id, subject_id, event_type, payload)
    values (v_event_id, p_actor, 'institutional_email_verified', '{}'::jsonb);
  end if;

  v_qualified := app_private.maybe_qualify_track_a(p_actor);
  return pg_catalog.jsonb_build_object(
    'confirmed', true,
    'qualified', v_qualified,
    'next_steps', case when v_qualified then '[]'::jsonb else pg_catalog.jsonb_build_array('complete_shared_requirements') end
  );
end;
$function$;
revoke all on function app_private.confirm_school_challenge_for_actor(uuid, uuid, text) from public, anon, authenticated, service_role;

create function public.server_begin_school_challenge_for_actor(p_actor uuid, p_email text, p_code_digest text)
returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.begin_school_challenge_for_actor(p_actor, p_email, p_code_digest)
$function$;
create function public.server_confirm_school_challenge_for_actor(p_actor uuid, p_challenge_id uuid, p_code_digest text)
returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.confirm_school_challenge_for_actor(p_actor, p_challenge_id, p_code_digest)
$function$;
create function public.server_fail_school_challenge_for_actor(p_actor uuid, p_challenge_id uuid)
returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.fail_school_challenge_for_actor(p_actor, p_challenge_id)
$function$;
revoke all on function public.server_begin_school_challenge_for_actor(uuid, text, text) from public, anon, authenticated, service_role;
revoke all on function public.server_confirm_school_challenge_for_actor(uuid, uuid, text) from public, anon, authenticated, service_role;
revoke all on function public.server_fail_school_challenge_for_actor(uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function public.server_begin_school_challenge_for_actor(uuid, text, text) to service_role;
grant execute on function public.server_confirm_school_challenge_for_actor(uuid, uuid, text) to service_role;
grant execute on function public.server_fail_school_challenge_for_actor(uuid, uuid) to service_role;

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
    where ownership.user_id = v_actor and ownership.revoked_at is null
  ) into v_school_email_verified;
  if v_identity.account_status = 'active' and v_phone_verified and v_identity.age_confirmed_at is not null then
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
