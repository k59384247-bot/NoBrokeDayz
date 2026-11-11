begin;

create or replace function app_private.maybe_qualify_track_a(p_actor uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_event_id uuid;
begin
  if not exists (
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
    return false;
  end if;

  update app_private.identity_accounts
  set verification_track = 'track_a_school_email',
      verification_status = 'approved',
      updated_at = pg_catalog.now()
  where user_id = p_actor
    and (verification_track is null or verification_track = 'track_a_school_email')
    and verification_status in ('unverified', 'approved');
  if not found then return false; end if;

  insert into app_private.identity_capabilities (user_id, capability, source)
  values
    (p_actor, 'can_hire', 'track_a_school_email'),
    (p_actor, 'can_work', 'track_a_school_email')
  on conflict (user_id, capability) do update
    set source = excluded.source, granted_at = pg_catalog.now(), revoked_at = null
    where app_private.identity_capabilities.revoked_at is not null;

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

  return exists (
    select 1 from app_private.identity_capabilities
    where user_id = p_actor and capability in ('can_hire', 'can_work') and revoked_at is null
    group by user_id having count(*) = 2
  );
end;
$function$;
revoke all on function app_private.maybe_qualify_track_a(uuid) from public, anon, authenticated, service_role;

create or replace function app_private.confirm_school_challenge_for_actor(
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
  v_difference integer := 0;
  v_i integer;
  v_inserted uuid;
  v_qualified boolean;
  v_event_id uuid;
  v_expected bytea;
  v_actual bytea;
  v_replaced boolean := false;
begin
  if p_code_digest !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = '22023', message = 'invalid_challenge';
  end if;
  -- Serialize a user's address replacement and serialize all competing claims to this address.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_actor::text, 916204));
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
  if v_difference <> 0 then
    update app_private.school_email_challenges
    set failed_attempts = failed_attempts + 1,
        invalidated_at = case when failed_attempts + 1 >= 5 then pg_catalog.now() else null end
    where challenge_id = p_challenge_id;
    return pg_catalog.jsonb_build_object('confirmed', false, 'qualified', false, 'next_steps', pg_catalog.jsonb_build_array('check_code_or_request_new'));
  end if;

  update app_private.school_email_challenges
  set consumed_at = pg_catalog.now()
  where challenge_id = p_challenge_id;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_challenge.normalized_email, 916203));
  if exists (
    select 1 from app_private.institutional_email_ownerships ownership
    where ownership.normalized_email = v_challenge.normalized_email
      and ownership.revoked_at is null and ownership.user_id <> p_actor
  ) then
    return pg_catalog.jsonb_build_object('confirmed', false, 'qualified', false, 'next_steps', pg_catalog.jsonb_build_array('contact_support'));
  end if;

  update app_private.institutional_email_ownerships
  set revoked_at = pg_catalog.now()
  where user_id = p_actor and revoked_at is null and normalized_email <> v_challenge.normalized_email;
  v_replaced := found;
  if v_replaced then
    update app_private.school_email_challenges
    set invalidated_at = pg_catalog.now()
    where user_id = p_actor and challenge_id <> p_challenge_id
      and consumed_at is null and invalidated_at is null;
    update app_private.identity_capabilities
    set revoked_at = pg_catalog.now()
    where user_id = p_actor and source = 'track_a_school_email' and revoked_at is null;
    update app_private.identity_accounts
    set verification_track = null,
        verification_status = 'unverified',
        updated_at = pg_catalog.now()
    where user_id = p_actor and verification_track = 'track_a_school_email';
    insert into app_private.identity_audit_events (actor_id, subject_id, event_type, event_data)
    values (p_actor, p_actor, 'institutional_email_replaced', pg_catalog.jsonb_build_object('challenge_version', v_challenge.challenge_version))
    returning event_id into v_event_id;
    insert into app_private.identity_outbox (event_id, subject_id, event_type, payload)
    values (v_event_id, p_actor, 'institutional_email_replaced', '{}'::jsonb);
  end if;

  insert into app_private.institutional_email_ownerships (user_id, normalized_email)
  values (p_actor, v_challenge.normalized_email)
  on conflict do nothing
  returning user_id into v_inserted;
  if v_inserted is null and not exists (
    select 1 from app_private.institutional_email_ownerships ownership
    where ownership.user_id = p_actor and ownership.normalized_email = v_challenge.normalized_email
      and ownership.revoked_at is null
  ) then
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

commit;
