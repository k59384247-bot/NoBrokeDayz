begin;

-- Auth v2.197 stores country-code digits without '+' and clears phone_change to ''.
create or replace function app_private.guard_auth_phone_uniqueness()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_phone text;
begin
  if tg_op = 'UPDATE'
     and new.phone is not distinct from old.phone
     and new.phone_change is not distinct from old.phone_change then
    return new;
  end if;

  for v_phone in
    select distinct candidate.phone
    from pg_catalog.unnest(array[nullif(new.phone, ''), nullif(new.phone_change, '')]) as candidate(phone)
    where candidate.phone is not null
    order by candidate.phone
  loop
    if v_phone !~ '^234[789][0-9]{9}$' then
      raise exception using errcode = '22023', message = 'invalid Nigerian phone number';
    end if;
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_phone, 73421));
    update auth.users stale_user
    set phone_change = '', phone_change_token = ''
    where stale_user.id <> new.id
      and stale_user.phone_change = v_phone
      and stale_user.phone_change_sent_at <= pg_catalog.now() - interval '5 minutes';
    if exists (
      select 1 from auth.users existing_user
      where existing_user.id <> new.id
        and (existing_user.phone = v_phone or existing_user.phone_change = v_phone)
    ) then
      raise exception using errcode = '23505', message = 'phone number is already in use';
    end if;
  end loop;
  return new;
end;
$function$;

create or replace function app_private.reconcile_auth_phone_binding()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if nullif(new.phone_change, '') is not null
     and new.phone_change is distinct from old.phone_change then
    delete from app_private.identity_phone_bindings where user_id = new.id;
    return new;
  end if;

  if nullif(old.phone_change, '') is not null
     and nullif(new.phone_change, '') is null
     and new.phone = old.phone_change
     and new.phone_confirmed_at is not null then
    insert into app_private.identity_phone_bindings (user_id, phone_e164, verified_at)
    values (new.id, '+' || new.phone, new.phone_confirmed_at)
    on conflict (user_id) do update
      set phone_e164 = excluded.phone_e164,
          verified_at = excluded.verified_at;
    return new;
  end if;

  if new.phone is distinct from old.phone or new.phone_confirmed_at is null then
    delete from app_private.identity_phone_bindings where user_id = new.id;
  end if;
  return new;
end;
$function$;

create or replace function public.get_my_identity_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_actor uuid := auth.uid();
  v_identity app_private.identity_accounts%rowtype;
  v_school_email_verified boolean;
  v_phone_verified boolean;
begin
  if v_actor is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;

  select exists (
    select 1
    from app_private.identity_phone_bindings binding
    join auth.users auth_user on auth_user.id = binding.user_id
    where binding.user_id = v_actor
      and binding.phone_e164 = '+' || auth_user.phone
      and binding.verified_at = auth_user.phone_confirmed_at
      and nullif(auth_user.phone_change, '') is null
  ) into v_phone_verified;

  select * into v_identity from app_private.identity_accounts where user_id = v_actor;
  if not found then
    return pg_catalog.jsonb_build_object('registered', false, 'phone_verified', v_phone_verified);
  end if;

  select exists (
    select 1 from app_private.institutional_email_ownerships ownership
    where ownership.user_id = v_actor and ownership.revoked_at is null
  ) into v_school_email_verified;

  return pg_catalog.jsonb_build_object(
    'registered', true,
    'account_type', v_identity.account_type,
    'age_confirmed', true,
    'account_status', v_identity.account_status,
    'verification_track', v_identity.verification_track,
    'verification_status', v_identity.verification_status,
    'institutional_email_verified', v_school_email_verified,
    'phone_verified', v_phone_verified
  );
end;
$function$;

revoke all on function app_private.guard_auth_phone_uniqueness() from public, anon, authenticated, service_role;
revoke all on function app_private.reconcile_auth_phone_binding() from public, anon, authenticated, service_role;
revoke all on function public.get_my_identity_status() from public, anon, authenticated, service_role;
grant execute on function public.get_my_identity_status() to authenticated;

commit;
