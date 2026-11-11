begin;

create or replace function app_private.list_assignment_case_queue_for_actor(
  p_actor uuid,p_auth_aal text,p_limit smallint
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare v_items jsonb; v_count integer;
begin
  if p_limit<>51 or not app_private.lock_case_reviewer_scope(p_actor,p_auth_aal) then
    raise exception using errcode='42501',message='case_access_denied';
  end if;
  with eligible as (
    select c.case_id,c.assignment_id,c.lifecycle_status,c.opened_at,h.reason_code,c.reviewer_id,
      greatest(0,floor(extract(epoch from pg_catalog.now()-c.opened_at)))::bigint as age_seconds,
      (h.reason_code='conduct_safety' or coalesce(t.priority,'normal')='urgent') as urgent
    from app_private.assignment_cases c
    join app_private.assignment_holds h on h.hold_id=c.hold_id
    join app_private.assignments a on a.assignment_id=c.assignment_id
    join app_private.principal_allocations p on p.allocation_id=c.allocation_id
    left join lateral (select priority from app_private.assignment_case_triage_records
      where case_id=c.case_id order by case_version desc,triage_id desc limit 1) t on true
    where c.lifecycle_status in ('open','under_review','contacting_other_party','verifying')
      and p.status='dispute_held'
      and (c.reviewer_id is null or c.reviewer_id=p_actor)
      and p_actor not in (a.worker_id,a.poster_id)
    order by urgent desc,c.opened_at,c.case_id limit p_limit
  ), page as (
    select * from eligible order by urgent desc,opened_at,case_id limit 50
  )
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'case_id',case_id,'assignment_id',assignment_id,'status',lifecycle_status,
      'opened_at',opened_at,'age_seconds',age_seconds::text,'reason_code',reason_code,
      'priority',case when urgent then 'urgent' else 'normal' end,
      'assigned_to_me',coalesce(reviewer_id=p_actor,false)
    ) order by urgent desc,opened_at,case_id),'[]'::jsonb),
    (select count(*)::integer from eligible)
    into v_items,v_count from page;
  insert into app_private.assignment_case_access_audit(case_id,actor_id,action)
    select (item->>'case_id')::uuid,p_actor,'case_queue_read'
    from pg_catalog.jsonb_array_elements(v_items) as q(item);
  return pg_catalog.jsonb_build_object('items',v_items,'truncated',v_count>50);
end;
$function$;

commit;
