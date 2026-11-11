begin;

create table app_private.profile_campuses (
  campus_id uuid primary key default pg_catalog.gen_random_uuid(),
  display_label text not null check (pg_catalog.char_length(pg_catalog.btrim(display_label)) between 1 and 80),
  enabled boolean not null default true
);
revoke all on table app_private.profile_campuses from public, anon, authenticated, service_role;

create function app_private.update_profile_for_actor_v2(p_actor uuid, p_profile jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_campus_id text;
  v_label text;
  v_profile jsonb := p_profile;
begin
  if p_profile ? 'campus_label' then
    raise exception using errcode = '22023', message = 'invalid profile';
  end if;
  if p_profile ? 'campus_id' then
    if pg_catalog.jsonb_typeof(p_profile -> 'campus_id') not in ('string','null') then
      raise exception using errcode = '22023', message = 'invalid profile';
    end if;
    v_campus_id := p_profile ->> 'campus_id';
    if v_campus_id is null then
      v_profile := (p_profile - 'campus_id') || pg_catalog.jsonb_build_object('campus_label', null);
    else
      if v_campus_id !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        raise exception using errcode = '22023', message = 'invalid profile';
      end if;
      select c.display_label into v_label from app_private.profile_campuses c
      where c.campus_id = v_campus_id::uuid and c.enabled;
      if not found then raise exception using errcode = '22023', message = 'invalid profile'; end if;
      v_profile := (p_profile - 'campus_id') || pg_catalog.jsonb_build_object('campus_label', v_label);
    end if;
  end if;
  return app_private.update_profile_for_actor(p_actor, v_profile);
end;
$function$;
revoke all on function app_private.update_profile_for_actor_v2(uuid,jsonb) from public, anon, authenticated, service_role;
grant execute on function app_private.update_profile_for_actor_v2(uuid,jsonb) to postgres;

create or replace function public.server_update_profile_for_actor(p_actor uuid, p_profile jsonb)
returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.update_profile_for_actor_v2(p_actor, p_profile)
$function$;
revoke all on function public.server_update_profile_for_actor(uuid,jsonb) from public, anon, authenticated, service_role;
grant execute on function public.server_update_profile_for_actor(uuid,jsonb) to service_role;

commit;
