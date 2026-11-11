begin;

create table app_private.identity_phone_sms_send_limits (
  request_id text primary key check (char_length(request_id) between 1 and 128),
  phone_digest text not null check (phone_digest ~ '^[0-9a-f]{64}$'),
  sent_at timestamptz not null default pg_catalog.clock_timestamp()
);

create index identity_phone_sms_send_limits_phone_sent_idx
  on app_private.identity_phone_sms_send_limits(phone_digest, sent_at desc);

revoke all on table app_private.identity_phone_sms_send_limits
  from public, anon, authenticated, service_role;

create function app_private.reserve_phone_sms_send(
  p_actor uuid,
  p_phone_digest text,
  p_request_id text
) returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_hour_count integer;
  v_day_count integer;
begin
  if p_actor is null or not exists (select 1 from auth.users where id = p_actor)
     or p_phone_digest is null or p_phone_digest !~ '^[0-9a-f]{64}$'
     or p_request_id is null or p_request_id !~ '^[A-Za-z0-9._:-]{1,128}$' then
    raise exception using errcode = '22023', message = 'invalid_request';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('phone-sms-request:' || p_request_id, 3031103)
  );
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('phone-sms-digest:' || p_phone_digest, 3031103)
  );

  if exists (
    select 1 from app_private.identity_phone_sms_send_limits
    where request_id = p_request_id
  ) then
    return false;
  end if;

  with expired as (
    select request_id
    from app_private.identity_phone_sms_send_limits
    where sent_at <= v_now - interval '24 hours'
    order by sent_at
    for update skip locked
    limit 100
  )
  delete from app_private.identity_phone_sms_send_limits s
  using expired e
  where s.request_id = e.request_id;

  select count(*)::integer into v_hour_count
  from app_private.identity_phone_sms_send_limits
  where phone_digest = p_phone_digest
    and sent_at > v_now - interval '1 hour';

  select count(*)::integer into v_day_count
  from app_private.identity_phone_sms_send_limits
  where phone_digest = p_phone_digest
    and sent_at > v_now - interval '24 hours';

  if v_hour_count >= 5 or v_day_count >= 10 then
    return false;
  end if;

  insert into app_private.identity_phone_sms_send_limits(request_id, phone_digest, sent_at)
  values (p_request_id, p_phone_digest, v_now);
  return true;
end;
$function$;

create function public.server_reserve_phone_sms_send_for_actor(
  p_actor uuid,
  p_phone_digest text,
  p_request_id text
) returns boolean
language sql
security definer
set search_path = ''
as $function$
  select app_private.reserve_phone_sms_send($1, $2, $3)
$function$;

revoke all on function app_private.reserve_phone_sms_send(uuid, text, text)
  from public, anon, authenticated, service_role;
revoke all on function public.server_reserve_phone_sms_send_for_actor(uuid, text, text)
  from public, anon, authenticated, service_role;
grant execute on function public.server_reserve_phone_sms_send_for_actor(uuid, text, text)
  to service_role;
grant execute on function app_private.reserve_phone_sms_send(uuid, text, text)
  to postgres;

commit;
