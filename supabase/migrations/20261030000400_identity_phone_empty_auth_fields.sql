begin;

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
    if v_phone !~ '^\+234[789][0-9]{9}$' then
      raise exception using errcode = '22023', message = 'invalid Nigerian phone number';
    end if;
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_phone, 73421));
    update auth.users stale_user
    set phone_change = null
    where stale_user.id <> new.id
      and stale_user.phone_change = v_phone
      and stale_user.phone_change_sent_at <= pg_catalog.now() - interval '5 minutes';
    if exists (
      select 1
      from auth.users existing_user
      where existing_user.id <> new.id
        and (existing_user.phone = v_phone or existing_user.phone_change = v_phone)
    ) then
      raise exception using errcode = '23505', message = 'phone number is already in use';
    end if;
  end loop;

  return new;
end;
$function$;

commit;
