begin;

create function app_private.current_profile_capabilities(p_user uuid)
returns text[] language plpgsql stable security definer set search_path = '' as $function$
declare
  v_identity app_private.identity_accounts%rowtype;
  v_login_ok boolean;
  v_phone_ok boolean;
  v_school_ok boolean;
  v_result text[] := array[]::text[];
begin
  select * into v_identity
  from app_private.identity_accounts
  where user_id = p_user and account_status = 'active'
    and age_confirmed_at is not null and verification_status = 'approved';
  if not found then return v_result; end if;

  select exists (
    select 1 from auth.users u
    where u.id = p_user and u.email is not null and u.email_confirmed_at is not null
  ) into v_login_ok;
  select exists (
    select 1 from auth.users u
    join app_private.identity_phone_bindings b on b.user_id = u.id
    where u.id = p_user and u.phone is not null and u.phone_confirmed_at is not null
      and nullif(u.phone_change, '') is null
      and b.phone_e164 = '+' || u.phone and b.verified_at = u.phone_confirmed_at
  ) into v_phone_ok;
  if not v_login_ok or not v_phone_ok then return v_result; end if;

  if v_identity.account_type = 'student' and v_identity.verification_track = 'track_a_school_email' then
    select exists (
      select 1 from app_private.institutional_email_ownerships o
      join app_private.institutional_email_domains d
        on d.domain = pg_catalog.split_part(o.normalized_email, '@', 2) and d.enabled
      where o.user_id = p_user and o.revoked_at is null
    ) into v_school_ok;
    if not v_school_ok then return v_result; end if;
  elsif v_identity.account_type = 'student' and v_identity.verification_track is distinct from 'track_a_manual' then
    return v_result;
  elsif v_identity.account_type = 'partner' and v_identity.verification_track is distinct from 'track_b_partner' then
    return v_result;
  end if;

  select coalesce(pg_catalog.array_agg(c.capability order by c.capability), array[]::text[])
    into v_result
  from app_private.identity_capabilities c
  where c.user_id = p_user and c.revoked_at is null
    and (c.capability = 'can_hire' or (c.capability = 'can_work' and v_identity.account_type = 'student'));
  return v_result;
end;
$function$;
revoke all on function app_private.current_profile_capabilities(uuid) from public, anon, authenticated, service_role;
grant execute on function app_private.current_profile_capabilities(uuid) to postgres;

create or replace function public.get_my_identity_status()
returns jsonb language plpgsql stable security definer set search_path = '' as $function$
declare
  v_actor uuid := auth.uid();
  v_identity app_private.identity_accounts%rowtype;
  v_school_email_verified boolean := false;
  v_phone_verified boolean := false;
  v_login_email_confirmed boolean := false;
  v_capabilities text[] := array[]::text[];
begin
  if v_actor is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;
  select exists (
    select 1 from app_private.identity_phone_bindings b
    join auth.users u on u.id = b.user_id
    where b.user_id = v_actor and b.phone_e164 = '+' || u.phone
      and b.verified_at = u.phone_confirmed_at
      and u.phone_confirmed_at is not null and nullif(u.phone_change, '') is null
  ) into v_phone_verified;
  select exists (
    select 1 from auth.users u where u.id = v_actor
      and u.email is not null and u.email_confirmed_at is not null
  ) into v_login_email_confirmed;
  select * into v_identity from app_private.identity_accounts where user_id = v_actor;
  if not found then
    return pg_catalog.jsonb_build_object(
      'registered', false, 'phone_verified', v_phone_verified,
      'login_email_confirmed', v_login_email_confirmed, 'verified', false,
      'can_post', false, 'can_work', false
    );
  end if;
  select exists (
    select 1 from app_private.institutional_email_ownerships o
    join app_private.institutional_email_domains d
      on d.domain = pg_catalog.split_part(o.normalized_email, '@', 2) and d.enabled
    where o.user_id = v_actor and o.revoked_at is null
  ) into v_school_email_verified;
  v_capabilities := app_private.current_profile_capabilities(v_actor);
  return pg_catalog.jsonb_build_object(
    'registered', true,
    'account_type', v_identity.account_type,
    'age_confirmed', v_identity.age_confirmed_at is not null,
    'account_status', v_identity.account_status,
    'verification_track', v_identity.verification_track,
    'verification_status', v_identity.verification_status,
    'institutional_email_verified', v_school_email_verified,
    'login_email_confirmed', v_login_email_confirmed,
    'phone_verified', v_phone_verified,
    'verified', pg_catalog.cardinality(v_capabilities) > 0,
    'can_post', 'can_hire' = any(v_capabilities),
    'can_work', 'can_work' = any(v_capabilities),
    'capabilities', pg_catalog.to_jsonb(v_capabilities)
  );
end;
$function$;
revoke all on function public.get_my_identity_status() from public, anon, authenticated, service_role;
grant execute on function public.get_my_identity_status() to authenticated;

create function app_private.update_profile_for_actor(p_actor uuid, p_profile jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_type text;
  v_result jsonb;
  v_key text;
begin
  if p_actor is null or p_profile is null or pg_catalog.jsonb_typeof(p_profile) <> 'object' then
    raise exception using errcode = '22023', message = 'invalid profile';
  end if;
  for v_key in select pg_catalog.jsonb_object_keys(p_profile) loop
    if v_key not in ('display_name','photo_key','faculty_label','campus_label','bio','skills','availability','business_name','business_location','organisation_label') then
      raise exception using errcode = '22023', message = 'invalid profile';
    end if;
  end loop;
  for v_key in select unnest(array['display_name','photo_key','faculty_label','campus_label','bio','availability','business_name','business_location','organisation_label']) loop
    if p_profile ? v_key and pg_catalog.jsonb_typeof(p_profile -> v_key) not in ('string','null') then
      raise exception using errcode = '22023', message = 'invalid profile';
    end if;
  end loop;
  if p_profile ? 'skills' and pg_catalog.jsonb_typeof(p_profile -> 'skills') not in ('array','null') then
    raise exception using errcode = '22023', message = 'invalid profile';
  end if;
  if p_profile ? 'skills' and pg_catalog.jsonb_typeof(p_profile -> 'skills') = 'array' and (
    pg_catalog.jsonb_array_length(p_profile -> 'skills') > 20 or exists (
      select 1 from pg_catalog.jsonb_array_elements(p_profile -> 'skills') e(value)
      where pg_catalog.jsonb_typeof(e.value) <> 'string'
        or pg_catalog.char_length(pg_catalog.btrim(e.value #>> '{}')) not between 1 and 40
    )
  ) then raise exception using errcode = '22023', message = 'invalid profile'; end if;

  select account_type into v_type from app_private.identity_accounts
  where user_id = p_actor and account_status = 'active';
  if not found then raise exception using errcode = '42501', message = 'profile unavailable'; end if;
  if v_type <> 'partner' and (p_profile ? 'business_name' or p_profile ? 'business_location') then
    raise exception using errcode = '22023', message = 'invalid profile';
  end if;
  if p_profile ? 'photo_key' and p_profile ->> 'photo_key' is not null
    and (pg_catalog.char_length(p_profile ->> 'photo_key') > 200 or
      (p_profile ->> 'photo_key') !~ ('^avatars/' || p_actor::text || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$')) then
    raise exception using errcode = '22023', message = 'invalid profile';
  end if;

  update public.profiles p set
    display_name = case when p_profile ? 'display_name' then nullif(pg_catalog.btrim(p_profile ->> 'display_name'), '') else p.display_name end,
    photo_key = case when p_profile ? 'photo_key' then p_profile ->> 'photo_key' else p.photo_key end,
    faculty_label = case when p_profile ? 'faculty_label' then nullif(pg_catalog.btrim(p_profile ->> 'faculty_label'), '') else p.faculty_label end,
    campus_label = case when p_profile ? 'campus_label' then nullif(pg_catalog.btrim(p_profile ->> 'campus_label'), '') else p.campus_label end,
    bio = case when p_profile ? 'bio' then nullif(pg_catalog.btrim(p_profile ->> 'bio'), '') else p.bio end,
    skills = case when p_profile ? 'skills' and pg_catalog.jsonb_typeof(p_profile -> 'skills') = 'null' then array[]::text[] when p_profile ? 'skills' then coalesce((select pg_catalog.array_agg(pg_catalog.btrim(e.value #>> '{}') order by e.ordinality) from pg_catalog.jsonb_array_elements(p_profile -> 'skills') with ordinality e(value, ordinality)), array[]::text[]) else p.skills end,
    availability = case when p_profile ? 'availability' then nullif(pg_catalog.btrim(p_profile ->> 'availability'), '') else p.availability end,
    business_name = case when p_profile ? 'business_name' then nullif(pg_catalog.btrim(p_profile ->> 'business_name'), '') else p.business_name end,
    business_location = case when p_profile ? 'business_location' then nullif(pg_catalog.btrim(p_profile ->> 'business_location'), '') else p.business_location end,
    organisation_label = case when p_profile ? 'organisation_label' then nullif(pg_catalog.btrim(p_profile ->> 'organisation_label'), '') else p.organisation_label end
  where p.user_id = p_actor
  returning pg_catalog.jsonb_build_object(
    'display_name', p.display_name, 'photo_key', p.photo_key,
    'faculty_label', p.faculty_label, 'campus_label', p.campus_label,
    'bio', p.bio, 'skills', pg_catalog.to_jsonb(p.skills),
    'availability', p.availability, 'business_name', p.business_name,
    'business_location', p.business_location, 'organisation_label', p.organisation_label,
    'created_at', p.created_at, 'updated_at', p.updated_at
  ) into v_result;
  if v_result is null then raise exception using errcode = '42501', message = 'profile unavailable'; end if;
  return v_result;
end;
$function$;
revoke all on function app_private.update_profile_for_actor(uuid,jsonb) from public, anon, authenticated, service_role;
grant execute on function app_private.update_profile_for_actor(uuid,jsonb) to postgres;

create function app_private.get_safe_profile_for_viewer(p_viewer uuid, p_subject uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $function$
declare
  v_type text;
  v_caps text[];
  v_profile jsonb;
begin
  if p_viewer is null or p_subject is null
    or pg_catalog.cardinality(app_private.current_profile_capabilities(p_viewer)) = 0 then
    raise exception using errcode = 'P0002', message = 'profile_not_found';
  end if;
  v_caps := app_private.current_profile_capabilities(p_subject);
  if pg_catalog.cardinality(v_caps) = 0 then
    raise exception using errcode = 'P0002', message = 'profile_not_found';
  end if;
  select a.account_type, pg_catalog.jsonb_build_object(
    'profile_id', p.user_id,
    'account_type', a.account_type,
    'verified_badge', true,
    'display_name', p.display_name,
    'photo_key', p.photo_key,
    'faculty_label', p.faculty_label,
    'campus_label', p.campus_label,
    'bio', p.bio,
    'skills', pg_catalog.to_jsonb(p.skills),
    'availability', p.availability,
    'business_name', p.business_name,
    'business_location', p.business_location,
    'organisation_label', p.organisation_label,
    'worker_rating', null,
    'worker_review_count', 0,
    'poster_rating', null,
    'poster_review_count', 0,
    'completed_work_count', 0
  ) into v_type, v_profile
  from public.profiles p
  join app_private.identity_accounts a on a.user_id = p.user_id
  where p.user_id = p_subject and a.account_status = 'active';
  if v_profile is null then raise exception using errcode = 'P0002', message = 'profile_not_found'; end if;
  return v_profile;
end;
$function$;
revoke all on function app_private.get_safe_profile_for_viewer(uuid,uuid) from public, anon, authenticated, service_role;
grant execute on function app_private.get_safe_profile_for_viewer(uuid,uuid) to postgres;

create function public.server_update_profile_for_actor(p_actor uuid, p_profile jsonb)
returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.update_profile_for_actor(p_actor, p_profile)
$function$;
revoke all on function public.server_update_profile_for_actor(uuid,jsonb) from public, anon, authenticated, service_role;
grant execute on function public.server_update_profile_for_actor(uuid,jsonb) to service_role;

create function public.server_get_safe_profile_for_viewer(p_viewer uuid, p_subject uuid)
returns jsonb language sql stable security definer set search_path = '' as $function$
  select app_private.get_safe_profile_for_viewer(p_viewer, p_subject)
$function$;
revoke all on function public.server_get_safe_profile_for_viewer(uuid,uuid) from public, anon, authenticated, service_role;
grant execute on function public.server_get_safe_profile_for_viewer(uuid,uuid) to service_role;

revoke update on public.profiles from authenticated;
revoke update (display_name, photo_key, faculty_label, campus_label, bio, skills, availability, business_name, business_location, organisation_label) on public.profiles from authenticated;
drop policy profiles_update_own on public.profiles;

commit;
