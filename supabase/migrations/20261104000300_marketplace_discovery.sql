begin;

-- The MVP marketplace is limited to one configured campus. This row is a
-- platform scope label, not evidence that an individual was verified there.
insert into app_private.profile_campuses(campus_id, display_label, enabled)
values ('e3af45a7-0d34-4d13-9eab-c930aee55401', 'University of Lagos', true)
on conflict (campus_id) do update set display_label = excluded.display_label, enabled = true;

alter table app_private.jobs
  add column campus_id uuid not null default 'e3af45a7-0d34-4d13-9eab-c930aee55401'
    references app_private.profile_campuses(campus_id) on delete restrict;

alter table app_private.job_terms_versions
  add column search_document tsvector generated always as (
    pg_catalog.to_tsvector(
      'pg_catalog.simple'::pg_catalog.regconfig,
      coalesce(title, '') || ' ' || coalesce(description, '')
    )
  ) stored,
  add column location_search_document tsvector generated always as (
    pg_catalog.to_tsvector(
      'pg_catalog.simple'::pg_catalog.regconfig,
      coalesce(location_detail, '')
    )
  ) stored;

create index marketplace_jobs_available_campus_created_idx
  on app_private.jobs(campus_id, created_at desc, job_id desc)
  where listing_state = 'open' and funded_funding_intent_id is not null;
create index marketplace_allocations_unassigned_job_idx
  on app_private.principal_allocations(job_id)
  where status = 'unassigned';
create index marketplace_job_terms_search_idx
  on app_private.job_terms_versions using gin(search_document);
create index marketplace_job_terms_location_search_idx
  on app_private.job_terms_versions using gin(location_search_document);
create index marketplace_job_terms_category_idx
  on app_private.job_terms_versions(category_slug, job_id, terms_version);
create index marketplace_job_terms_gross_idx
  on app_private.job_terms_versions(gross_per_worker_kobo, job_id, terms_version);
create index marketplace_job_terms_needed_by_idx
  on app_private.job_terms_versions(needed_by_at, job_id, terms_version);

create function app_private.discover_jobs_for_actor(
  p_actor uuid,
  p_filters jsonb,
  p_cursor_created_at timestamptz,
  p_cursor_job_id uuid,
  p_limit smallint
) returns jsonb language plpgsql stable security definer set search_path = '' as $function$
declare
  v_caps text[];
  v_keyword text;
  v_location text;
  v_min_gross bigint;
  v_max_gross bigint;
  v_needed_from timestamptz;
  v_needed_to timestamptz;
  v_result jsonb;
begin
  if p_actor is null or p_limit <> 21 or
     ((p_cursor_created_at is null) <> (p_cursor_job_id is null)) or
     pg_catalog.jsonb_typeof(p_filters) is distinct from 'object' or
     (p_filters - array['keyword','location','category_slug','min_gross_kobo','max_gross_kobo',
       'location_type','needed_by_from','needed_by_to']) <> '{}'::jsonb then
    raise exception using errcode = '22023', message = 'invalid_marketplace_query';
  end if;

  v_caps := app_private.current_profile_capabilities(p_actor);
  if not ('can_work' = any(v_caps) or 'can_hire' = any(v_caps)) then
    raise exception using errcode = '42501', message = 'marketplace_access_denied';
  end if;

  if p_filters ? 'keyword' then
    if pg_catalog.jsonb_typeof(p_filters->'keyword') is distinct from 'string' or
       pg_catalog.char_length(p_filters->>'keyword') > 100 then
      raise exception using errcode = '22023', message = 'invalid_marketplace_query';
    end if;
    v_keyword := nullif(pg_catalog.btrim(pg_catalog.regexp_replace(p_filters->>'keyword', '\s+', ' ', 'g')), '');
  end if;
  if p_filters ? 'location' then
    if pg_catalog.jsonb_typeof(p_filters->'location') is distinct from 'string' or
       pg_catalog.char_length(p_filters->>'location') > 100 then
      raise exception using errcode = '22023', message = 'invalid_marketplace_query';
    end if;
    v_location := nullif(pg_catalog.btrim(pg_catalog.regexp_replace(p_filters->>'location', '\s+', ' ', 'g')), '');
  end if;
  if p_filters ? 'category_slug' and
     (pg_catalog.jsonb_typeof(p_filters->'category_slug') is distinct from 'string' or
      (p_filters->>'category_slug') !~ '^[a-z0-9]+(-[a-z0-9]+){0,7}$') then
    raise exception using errcode = '22023', message = 'invalid_marketplace_query';
  end if;
  if p_filters ? 'location_type' and
     (pg_catalog.jsonb_typeof(p_filters->'location_type') is distinct from 'string' or
      p_filters->>'location_type' not in ('on_campus','remote','hybrid')) then
    raise exception using errcode = '22023', message = 'invalid_marketplace_query';
  end if;
  if p_filters ? 'min_gross_kobo' then
    if pg_catalog.jsonb_typeof(p_filters->'min_gross_kobo') is distinct from 'string' or
       (p_filters->>'min_gross_kobo') !~ '^(0|[1-9][0-9]{0,8})$' then
      raise exception using errcode = '22023', message = 'invalid_marketplace_query';
    end if;
    v_min_gross := (p_filters->>'min_gross_kobo')::bigint;
    if v_min_gross > 100000000 then
      raise exception using errcode = '22023', message = 'invalid_marketplace_query';
    end if;
  end if;
  if p_filters ? 'max_gross_kobo' then
    if pg_catalog.jsonb_typeof(p_filters->'max_gross_kobo') is distinct from 'string' or
       (p_filters->>'max_gross_kobo') !~ '^(0|[1-9][0-9]{0,8})$' then
      raise exception using errcode = '22023', message = 'invalid_marketplace_query';
    end if;
    v_max_gross := (p_filters->>'max_gross_kobo')::bigint;
    if v_max_gross > 100000000 then
      raise exception using errcode = '22023', message = 'invalid_marketplace_query';
    end if;
  end if;
  if v_min_gross is not null and v_max_gross is not null and v_min_gross > v_max_gross then
    raise exception using errcode = '22023', message = 'invalid_marketplace_query';
  end if;
  begin
    if p_filters ? 'needed_by_from' then
      if pg_catalog.jsonb_typeof(p_filters->'needed_by_from') is distinct from 'string' then
        raise exception using errcode = '22023', message = 'invalid_marketplace_query';
      end if;
      v_needed_from := (p_filters->>'needed_by_from')::timestamptz;
    end if;
    if p_filters ? 'needed_by_to' then
      if pg_catalog.jsonb_typeof(p_filters->'needed_by_to') is distinct from 'string' then
        raise exception using errcode = '22023', message = 'invalid_marketplace_query';
      end if;
      v_needed_to := (p_filters->>'needed_by_to')::timestamptz;
    end if;
  exception when others then
    raise exception using errcode = '22023', message = 'invalid_marketplace_query';
  end;
  if v_needed_from is not null and v_needed_to is not null and v_needed_from > v_needed_to then
    raise exception using errcode = '22023', message = 'invalid_marketplace_query';
  end if;

  with candidates as (
    select j.job_id, j.created_at, t.terms_version, t.title, t.description,
      t.category_slug, c.label as category_label, t.location_type, t.location_detail,
      t.gross_per_worker_kobo, t.gross_total_kobo, t.application_deadline_at,
      t.needed_by_at, t.start_requirements, t.application_note,
      i.slot_count as funded_slot_count,
      a.allocation_count, a.slots_remaining,
      p.display_name, ia.account_type
    from app_private.jobs j
    join app_private.job_terms_versions t
      on t.job_id = j.job_id and t.terms_version = j.current_terms_version
    join app_private.funding_intents i
      on i.intent_id = j.funded_funding_intent_id and i.status = 'succeeded'
      and i.terms_version = t.terms_version and i.gross_per_worker_kobo = t.gross_per_worker_kobo
      and i.slot_count = t.slot_count and i.gross_total_kobo = t.gross_total_kobo
      and i.currency = 'NGN' and i.terms_sha256 = t.terms_sha256
    join public.job_categories c on c.slug = t.category_slug and c.enabled
    join lateral (
      select count(*)::integer as allocation_count,
        count(*) filter (where pa.status = 'unassigned')::integer as slots_remaining
      from app_private.principal_allocations pa
      where pa.job_id = j.job_id
    ) a on true
    left join public.profiles p on p.user_id = j.poster_id
    left join app_private.identity_accounts ia on ia.user_id = j.poster_id
    where j.campus_id = 'e3af45a7-0d34-4d13-9eab-c930aee55401'::uuid
      and j.listing_state = 'open'
      and j.funded_funding_intent_id is not null
      and t.application_deadline_at > pg_catalog.now()
      and a.slots_remaining > 0
      and a.allocation_count = i.slot_count
      and (not (p_filters ? 'category_slug') or t.category_slug = p_filters->>'category_slug')
      and (v_min_gross is null or t.gross_per_worker_kobo >= v_min_gross)
      and (v_max_gross is null or t.gross_per_worker_kobo <= v_max_gross)
      and (not (p_filters ? 'location_type') or t.location_type = p_filters->>'location_type')
      and (v_needed_from is null or t.needed_by_at >= v_needed_from)
      and (v_needed_to is null or t.needed_by_at <= v_needed_to)
      and (v_keyword is null or t.search_document @@ pg_catalog.plainto_tsquery('pg_catalog.simple'::pg_catalog.regconfig, v_keyword))
      and (v_location is null or t.location_search_document @@ pg_catalog.plainto_tsquery('pg_catalog.simple'::pg_catalog.regconfig, v_location))
      and (p_cursor_created_at is null or (j.created_at, j.job_id) < (p_cursor_created_at, p_cursor_job_id))
    order by j.created_at desc, j.job_id desc
    limit p_limit
  )
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'job_id', job_id,
    'created_at', created_at,
    'title', title,
    'description_excerpt', pg_catalog.left(description, 220),
    'category_slug', category_slug,
    'category_label', category_label,
    'location_type', location_type,
    'location_detail', location_detail,
    'gross_per_worker_kobo', gross_per_worker_kobo::text,
    'commission_kobo', app_private.calculate_commission_kobo(gross_per_worker_kobo)::text,
    'worker_net_kobo', (gross_per_worker_kobo - app_private.calculate_commission_kobo(gross_per_worker_kobo))::text,
    'slots_remaining', slots_remaining,
    'terms_version', terms_version,
    'poster_summary', case when display_name is null and account_type is null then null
      else pg_catalog.jsonb_build_object('display_name', display_name, 'account_type', account_type) end
  ) order by created_at desc, job_id desc), '[]'::jsonb)
  into v_result from candidates;
  return v_result;
end;
$function$;

create function app_private.get_discoverable_job_detail_for_actor(p_actor uuid, p_job_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $function$
declare
  v_caps text[];
  v_result jsonb;
begin
  v_caps := app_private.current_profile_capabilities(p_actor);
  if p_actor is null or p_job_id is null or
     not ('can_work' = any(v_caps) or 'can_hire' = any(v_caps)) then
    raise exception using errcode = '42501', message = 'marketplace_access_denied';
  end if;
  select pg_catalog.jsonb_build_object(
    'job_id', j.job_id,
    'created_at', j.created_at,
    'title', t.title,
    'description_excerpt', pg_catalog.left(t.description, 220),
    'category_slug', t.category_slug,
    'category_label', c.label,
    'location_type', t.location_type,
    'location_detail', t.location_detail,
    'gross_per_worker_kobo', t.gross_per_worker_kobo::text,
    'commission_kobo', app_private.calculate_commission_kobo(t.gross_per_worker_kobo)::text,
    'worker_net_kobo', (t.gross_per_worker_kobo - app_private.calculate_commission_kobo(t.gross_per_worker_kobo))::text,
    'slots_remaining', a.slots_remaining,
    'terms_version', t.terms_version,
    'poster_summary', case when p.display_name is null and ia.account_type is null then null
      else pg_catalog.jsonb_build_object('display_name', p.display_name, 'account_type', ia.account_type) end,
    'description', t.description,
    'application_deadline_at', t.application_deadline_at,
    'needed_by_at', t.needed_by_at,
    'start_requirements', t.start_requirements,
    'application_note', t.application_note
  ) into v_result
  from app_private.jobs j
  join app_private.job_terms_versions t
    on t.job_id = j.job_id and t.terms_version = j.current_terms_version
  join app_private.funding_intents i
    on i.intent_id = j.funded_funding_intent_id and i.status = 'succeeded'
    and i.terms_version = t.terms_version and i.gross_per_worker_kobo = t.gross_per_worker_kobo
    and i.slot_count = t.slot_count and i.gross_total_kobo = t.gross_total_kobo
    and i.currency = 'NGN' and i.terms_sha256 = t.terms_sha256
  join public.job_categories c on c.slug = t.category_slug and c.enabled
  join lateral (
    select count(*)::integer as allocation_count,
      count(*) filter (where pa.status = 'unassigned')::integer as slots_remaining
    from app_private.principal_allocations pa where pa.job_id = j.job_id
  ) a on true
  left join public.profiles p on p.user_id = j.poster_id
  left join app_private.identity_accounts ia on ia.user_id = j.poster_id
  where j.job_id = p_job_id
    and j.campus_id = 'e3af45a7-0d34-4d13-9eab-c930aee55401'::uuid
    and j.listing_state = 'open'
    and j.funded_funding_intent_id is not null
    and t.application_deadline_at > pg_catalog.now()
    and a.slots_remaining > 0
    and a.allocation_count = i.slot_count;
  if v_result is null then
    raise exception using errcode = 'P0002', message = 'job_not_found';
  end if;
  return v_result;
end;
$function$;

create function app_private.get_my_funded_job_history(
  p_actor uuid, p_cursor_created_at timestamptz, p_cursor_job_id uuid, p_limit smallint
) returns jsonb language plpgsql stable security definer set search_path = '' as $function$
declare
  v_result jsonb;
begin
  if p_actor is null or p_limit <> 21 or
     ((p_cursor_created_at is null) <> (p_cursor_job_id is null)) or
     not exists (select 1 from auth.users u where u.id = p_actor) then
    raise exception using errcode = '22023', message = 'invalid_marketplace_query';
  end if;
  with own_jobs as (
    select j.job_id, j.created_at, t.title, t.description, t.category_slug, c.label as category_label,
      t.location_type, t.location_detail, t.gross_per_worker_kobo, t.terms_version,
      a.slots_remaining,
      case when a.slots_remaining = 0 then 'filled'
        when j.listing_state = 'expired' or t.application_deadline_at <= pg_catalog.now() then 'expired'
        else 'open' end as history_state,
      p.display_name, ia.account_type
    from app_private.jobs j
    join app_private.job_terms_versions t
      on t.job_id = j.job_id and t.terms_version = j.current_terms_version
    join app_private.funding_intents i
      on i.intent_id = j.funded_funding_intent_id and i.status = 'succeeded'
      and i.terms_version = t.terms_version and i.gross_per_worker_kobo = t.gross_per_worker_kobo
      and i.slot_count = t.slot_count and i.gross_total_kobo = t.gross_total_kobo
      and i.currency = 'NGN' and i.terms_sha256 = t.terms_sha256
    join public.job_categories c on c.slug = t.category_slug
    join lateral (
      select count(*) filter (where pa.status = 'unassigned')::integer as slots_remaining
      from app_private.principal_allocations pa where pa.job_id = j.job_id
    ) a on true
    left join public.profiles p on p.user_id = j.poster_id
    left join app_private.identity_accounts ia on ia.user_id = j.poster_id
    where j.poster_id = p_actor and j.funded_funding_intent_id is not null
      and (p_cursor_created_at is null or (j.created_at, j.job_id) < (p_cursor_created_at, p_cursor_job_id))
    order by j.created_at desc, j.job_id desc
    limit p_limit
  )
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'job_id', job_id,
    'created_at', created_at,
    'title', title,
    'description_excerpt', pg_catalog.left(description, 220),
    'category_slug', category_slug,
    'category_label', category_label,
    'location_type', location_type,
    'location_detail', location_detail,
    'gross_per_worker_kobo', gross_per_worker_kobo::text,
    'commission_kobo', app_private.calculate_commission_kobo(gross_per_worker_kobo)::text,
    'worker_net_kobo', (gross_per_worker_kobo - app_private.calculate_commission_kobo(gross_per_worker_kobo))::text,
    'slots_remaining', slots_remaining,
    'terms_version', terms_version,
    'history_state', history_state,
    'poster_summary', case when display_name is null and account_type is null then null
      else pg_catalog.jsonb_build_object('display_name', display_name, 'account_type', account_type) end
  ) order by created_at desc, job_id desc), '[]'::jsonb)
  into v_result from own_jobs;
  return v_result;
end;
$function$;

create function app_private.get_my_funded_job_detail(p_actor uuid, p_job_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $function$
declare
  v_result jsonb;
begin
  if p_actor is null or p_job_id is null or
     not exists (select 1 from auth.users u where u.id = p_actor) then
    raise exception using errcode = '22023', message = 'invalid_marketplace_query';
  end if;
  select pg_catalog.jsonb_build_object(
    'job_id', j.job_id,
    'created_at', j.created_at,
    'title', t.title,
    'description_excerpt', pg_catalog.left(t.description, 220),
    'category_slug', t.category_slug,
    'category_label', c.label,
    'location_type', t.location_type,
    'location_detail', t.location_detail,
    'gross_per_worker_kobo', t.gross_per_worker_kobo::text,
    'commission_kobo', app_private.calculate_commission_kobo(t.gross_per_worker_kobo)::text,
    'worker_net_kobo', (t.gross_per_worker_kobo - app_private.calculate_commission_kobo(t.gross_per_worker_kobo))::text,
    'slots_remaining', a.slots_remaining,
    'terms_version', t.terms_version,
    'history_state', case when a.slots_remaining = 0 then 'filled'
      when j.listing_state = 'expired' or t.application_deadline_at <= pg_catalog.now() then 'expired'
      else 'open' end,
    'poster_summary', case when p.display_name is null and ia.account_type is null then null
      else pg_catalog.jsonb_build_object('display_name', p.display_name, 'account_type', ia.account_type) end,
    'description', t.description,
    'application_deadline_at', t.application_deadline_at,
    'needed_by_at', t.needed_by_at,
    'start_requirements', t.start_requirements,
    'application_note', t.application_note
  ) into v_result
  from app_private.jobs j
  join app_private.job_terms_versions t
    on t.job_id = j.job_id and t.terms_version = j.current_terms_version
  join app_private.funding_intents i
    on i.intent_id = j.funded_funding_intent_id and i.status = 'succeeded'
    and i.terms_version = t.terms_version and i.gross_per_worker_kobo = t.gross_per_worker_kobo
    and i.slot_count = t.slot_count and i.gross_total_kobo = t.gross_total_kobo
    and i.currency = 'NGN' and i.terms_sha256 = t.terms_sha256
  join public.job_categories c on c.slug = t.category_slug
  join lateral (
    select count(*) filter (where pa.status = 'unassigned')::integer as slots_remaining
    from app_private.principal_allocations pa where pa.job_id = j.job_id
  ) a on true
  left join public.profiles p on p.user_id = j.poster_id
  left join app_private.identity_accounts ia on ia.user_id = j.poster_id
  where j.job_id = p_job_id and j.poster_id = p_actor and j.funded_funding_intent_id is not null;
  if v_result is null then
    raise exception using errcode = 'P0002', message = 'job_not_found';
  end if;
  return v_result;
end;
$function$;

create function public.server_discover_jobs_for_actor(
  p_actor uuid, p_filters jsonb, p_cursor_created_at timestamptz, p_cursor_job_id uuid, p_limit smallint
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.discover_jobs_for_actor(p_actor, p_filters, p_cursor_created_at, p_cursor_job_id, p_limit)
$function$;
create function public.server_get_discoverable_job_detail_for_actor(p_actor uuid, p_job_id uuid)
returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.get_discoverable_job_detail_for_actor(p_actor, p_job_id)
$function$;
create function public.server_get_my_funded_job_history(
  p_actor uuid, p_cursor_created_at timestamptz, p_cursor_job_id uuid, p_limit smallint
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.get_my_funded_job_history(p_actor, p_cursor_created_at, p_cursor_job_id, p_limit)
$function$;
create function public.server_get_my_funded_job_detail_for_actor(p_actor uuid, p_job_id uuid)
returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.get_my_funded_job_detail(p_actor, p_job_id)
$function$;

revoke all on table app_private.profile_campuses, app_private.jobs,
  app_private.job_terms_versions, app_private.principal_allocations
  from public, anon, authenticated, service_role;
revoke all on function app_private.discover_jobs_for_actor(uuid,jsonb,timestamptz,uuid,smallint),
  app_private.get_discoverable_job_detail_for_actor(uuid,uuid),
  app_private.get_my_funded_job_history(uuid,timestamptz,uuid,smallint),
  app_private.get_my_funded_job_detail(uuid,uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.server_discover_jobs_for_actor(uuid,jsonb,timestamptz,uuid,smallint),
  public.server_get_discoverable_job_detail_for_actor(uuid,uuid),
  public.server_get_my_funded_job_history(uuid,timestamptz,uuid,smallint),
  public.server_get_my_funded_job_detail_for_actor(uuid,uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.server_discover_jobs_for_actor(uuid,jsonb,timestamptz,uuid,smallint),
  public.server_get_discoverable_job_detail_for_actor(uuid,uuid),
  public.server_get_my_funded_job_history(uuid,timestamptz,uuid,smallint),
  public.server_get_my_funded_job_detail_for_actor(uuid,uuid)
  to service_role;

commit;
