begin;

alter table app_private.staff_grants
  drop constraint staff_grants_capability_check,
  add constraint staff_grants_capability_check check (capability in (
    'verification_review','identity_suspend','identity_unsuspend','identity_correct_user_type',
    'identity_staff_admin','dispute_review','financial_initiate','financial_approve',
    'financial_inspect','case_senior_signoff','case_appeal_review',
    'notification_delivery_review','review_moderate'
  ));

create function app_private.assignment_has_qualifying_completion(p_assignment_id uuid)
returns boolean language sql stable security definer set search_path = '' as $function$
  select exists(
    select 1 from app_private.assignments a
    where a.assignment_id=p_assignment_id and a.work_state='completed' and a.completed_at is not null
      and (
        exists(select 1 from app_private.assignment_completion_authorizations c
          where c.assignment_id=a.assignment_id and c.allocation_id=a.allocation_id) or
        exists(select 1 from app_private.assignment_case_finalizations f
          join app_private.assignment_case_award_authorizations w
            on w.finalization_id=f.finalization_id and w.assignment_id=f.assignment_id
          where f.assignment_id=a.assignment_id and f.outcome in ('full_worker_award','split')
            and w.gross_award_kobo>0)
      )
  )
$function$;

create function app_private.assignment_review_is_eligible(p_assignment_id uuid)
returns boolean language sql stable security definer set search_path = '' as $function$
  select app_private.assignment_has_qualifying_completion(p_assignment_id)
    and not exists(select 1 from app_private.assignment_cases c
      where c.assignment_id=p_assignment_id
        and (c.lifecycle_status<>'closed' or c.closed_at is null))
    and not exists(select 1 from app_private.assignment_cases c
      join app_private.assignment_case_appeal_receipts r on r.case_id=c.case_id
      where c.assignment_id=p_assignment_id and not exists(
        select 1 from app_private.assignment_case_appeal_review_versions v
        where v.appeal_id=r.appeal_id and v.action in ('upheld','changed')))
$function$;

-- Reviews are published on submission after eligibility is proved. Text stays
-- immutable; reports create a separate moderation event and never auto-hide it.
create table app_private.assignment_reviews (
  review_id uuid primary key default pg_catalog.gen_random_uuid(),
  assignment_id uuid not null references app_private.assignments(assignment_id) on delete restrict,
  reviewer_id uuid not null references auth.users(id) on delete restrict,
  subject_id uuid not null references auth.users(id) on delete restrict,
  target_role text not null check (target_role in ('worker','poster')),
  rating smallint not null check (rating between 1 and 5),
  review_text text check (review_text is null or
    (char_length(review_text) between 1 and 500 and review_text=pg_catalog.btrim(review_text))),
  idempotency_key uuid not null,
  request_sha256 bytea not null check (pg_catalog.octet_length(request_sha256)=32),
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  unique(assignment_id,target_role),
  unique(assignment_id,reviewer_id),
  unique(reviewer_id,idempotency_key),
  check (reviewer_id<>subject_id)
);
create index assignment_reviews_profile_page_idx
  on app_private.assignment_reviews(subject_id,created_at desc,review_id desc);

create table app_private.assignment_review_reports (
  report_id uuid primary key default pg_catalog.gen_random_uuid(),
  review_id uuid not null references app_private.assignment_reviews(review_id) on delete restrict,
  reporter_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  unique(review_id,reporter_id)
);
create index assignment_review_reports_queue_idx
  on app_private.assignment_review_reports(created_at,review_id);

create table app_private.assignment_review_moderation_events (
  moderation_event_id uuid primary key default pg_catalog.gen_random_uuid(),
  review_id uuid not null unique references app_private.assignment_reviews(review_id) on delete restrict,
  action text not null check (action='hidden'),
  moderator_id uuid not null references auth.users(id) on delete restrict,
  staff_grant_id uuid not null references app_private.staff_grants(grant_id) on delete restrict,
  reason text not null check (char_length(reason) between 20 and 500),
  idempotency_key uuid not null,
  request_sha256 bytea not null check (pg_catalog.octet_length(request_sha256)=32),
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  unique(moderator_id,idempotency_key)
);

create table app_private.profile_reputation_projections (
  user_id uuid primary key references auth.users(id) on delete restrict,
  worker_rating_sum bigint not null default 0 check (worker_rating_sum>=0),
  worker_review_count bigint not null default 0 check (worker_review_count>=0),
  poster_rating_sum bigint not null default 0 check (poster_rating_sum>=0),
  poster_review_count bigint not null default 0 check (poster_review_count>=0),
  completed_work_count bigint not null default 0 check (completed_work_count>=0),
  updated_at timestamptz not null default pg_catalog.clock_timestamp()
);

create function app_private.reject_assignment_review_mutation()
returns trigger language plpgsql set search_path = '' as $function$
begin
  raise exception using errcode='55000',message='assignment_review_is_immutable';
end;
$function$;
create trigger assignment_reviews_immutable before update or delete
on app_private.assignment_reviews for each row
execute function app_private.reject_assignment_review_mutation();
create trigger assignment_review_reports_immutable before update or delete
on app_private.assignment_review_reports for each row
execute function app_private.reject_assignment_review_mutation();
create trigger assignment_review_moderation_events_immutable before update or delete
on app_private.assignment_review_moderation_events for each row
execute function app_private.reject_assignment_review_mutation();

create function app_private.validate_assignment_review_insert()
returns trigger language plpgsql security definer set search_path = '' as $function$
declare v_assignment app_private.assignments%rowtype;
begin
  select * into v_assignment from app_private.assignments where assignment_id=new.assignment_id;
  if not found or not app_private.assignment_review_is_eligible(new.assignment_id)
     or new.reviewer_id=new.subject_id
     or (new.target_role='worker' and
       (new.subject_id<>v_assignment.worker_id or new.reviewer_id<>v_assignment.poster_id))
     or (new.target_role='poster' and
       (new.subject_id<>v_assignment.poster_id or new.reviewer_id<>v_assignment.worker_id)) then
    raise exception using errcode='42501',message='review_not_eligible';
  end if;
  if new.review_text is not null and new.review_text ~* '([[:alpha:]][[:alnum:].+-]*://|(^|[[:space:]])www[.]|(^|[[:space:]])[[:alnum:]][[:alnum:].-]*[.][[:alpha:]]{2,}([/:?#]|[[:space:]]|$))' then
    raise exception using errcode='22023',message='invalid_review_text';
  end if;
  return new;
end;
$function$;
create trigger assignment_reviews_validate_insert before insert
on app_private.assignment_reviews for each row
execute function app_private.validate_assignment_review_insert();

create function app_private.refresh_profile_reputation_projection(p_user_id uuid)
returns void language plpgsql security definer set search_path = '' as $function$
declare
  v_worker_sum bigint;
  v_worker_count bigint;
  v_poster_sum bigint;
  v_poster_count bigint;
  v_completed_count bigint;
begin
  if p_user_id is null then return; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('profile_reputation_projection',78113));
  select coalesce(sum(r.rating) filter(where r.target_role='worker'),0)::bigint,
    count(*) filter(where r.target_role='worker')::bigint,
    coalesce(sum(r.rating) filter(where r.target_role='poster'),0)::bigint,
    count(*) filter(where r.target_role='poster')::bigint
  into v_worker_sum,v_worker_count,v_poster_sum,v_poster_count
  from app_private.assignment_reviews r
  where r.subject_id=p_user_id and not exists(
    select 1 from app_private.assignment_review_moderation_events m
    where m.review_id=r.review_id and m.action='hidden');

  select count(*)::bigint into v_completed_count from app_private.assignments a
  where a.worker_id=p_user_id and app_private.assignment_has_qualifying_completion(a.assignment_id);

  insert into app_private.profile_reputation_projections(
    user_id,worker_rating_sum,worker_review_count,poster_rating_sum,poster_review_count,
    completed_work_count,updated_at
  ) values(p_user_id,v_worker_sum,v_worker_count,v_poster_sum,v_poster_count,v_completed_count,
    pg_catalog.clock_timestamp())
  on conflict(user_id) do update set
    worker_rating_sum=excluded.worker_rating_sum,
    worker_review_count=excluded.worker_review_count,
    poster_rating_sum=excluded.poster_rating_sum,
    poster_review_count=excluded.poster_review_count,
    completed_work_count=excluded.completed_work_count,
    updated_at=excluded.updated_at;
end;
$function$;

create function app_private.refresh_profile_reputation_after_review()
returns trigger language plpgsql security definer set search_path = '' as $function$
begin
  perform app_private.refresh_profile_reputation_projection(new.subject_id);
  return new;
end;
$function$;
create trigger assignment_reviews_refresh_projection after insert
on app_private.assignment_reviews for each row
execute function app_private.refresh_profile_reputation_after_review();

create function app_private.refresh_profile_reputation_after_hide()
returns trigger language plpgsql security definer set search_path = '' as $function$
declare v_subject_id uuid;
begin
  select subject_id into v_subject_id from app_private.assignment_reviews
    where review_id=new.review_id;
  perform app_private.refresh_profile_reputation_projection(v_subject_id);
  return new;
end;
$function$;
create trigger assignment_review_moderation_refresh_projection after insert
on app_private.assignment_review_moderation_events for each row
execute function app_private.refresh_profile_reputation_after_hide();

create function app_private.refresh_profile_reputation_after_completion()
returns trigger language plpgsql security definer set search_path = '' as $function$
begin
  if old.work_state is distinct from new.work_state and new.work_state='completed'
     and app_private.assignment_has_qualifying_completion(new.assignment_id) then
    perform app_private.refresh_profile_reputation_projection(new.worker_id);
  end if;
  return new;
end;
$function$;
create trigger assignments_refresh_reputation_after_completion after update of work_state
on app_private.assignments for each row
execute function app_private.refresh_profile_reputation_after_completion();

create function app_private.rebuild_profile_reputation_projections()
returns integer language plpgsql security definer set search_path = '' as $function$
declare
  v_user_id uuid;
  v_count integer:=0;
begin
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('profile_reputation_projection',78113));
  for v_user_id in
    select user_id from public.profiles
    union select user_id from app_private.profile_reputation_projections
    union select a.worker_id as user_id from app_private.assignments a
      where app_private.assignment_has_qualifying_completion(a.assignment_id)
    union select r.subject_id as user_id from app_private.assignment_reviews r
    order by user_id
  loop
    perform app_private.refresh_profile_reputation_projection(v_user_id);
    v_count:=v_count+1;
  end loop;
  return v_count;
end;
$function$;

create function app_private.submit_assignment_review_for_actor(
  p_actor uuid,p_assignment_id uuid,p_rating smallint,p_review_text text,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_assignment app_private.assignments%rowtype;
  v_old app_private.assignment_reviews%rowtype;
  v_review app_private.assignment_reviews%rowtype;
  v_target_role text;
  v_subject_id uuid;
  v_text text;
  v_hash bytea;
begin
  if p_actor is null or p_assignment_id is null or p_idempotency_key is null
     or p_rating is null or p_rating not between 1 and 5 then
    raise exception using errcode='22023',message='invalid_review';
  end if;
  v_text:=nullif(pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(p_review_text,'')),
    '[[:space:]]+',' ','g'),'');
  if v_text is not null and (pg_catalog.char_length(v_text)>500
     or v_text ~* '([[:alpha:]][[:alnum:].+-]*://|(^|[[:space:]])www[.]|(^|[[:space:]])[[:alnum:]][[:alnum:].-]*[.][[:alpha:]]{2,}([/:?#]|[[:space:]]|$))') then
    raise exception using errcode='22023',message='invalid_review_text';
  end if;
  v_hash:=extensions.digest(pg_catalog.jsonb_build_object(
    'assignment_id',p_assignment_id,'rating',p_rating,'review_text',v_text)::text,'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'assignment_review:'||p_actor::text||':'||p_idempotency_key::text,78113));
  select * into v_old from app_private.assignment_reviews
    where reviewer_id=p_actor and idempotency_key=p_idempotency_key;
  if found then
    if v_old.request_sha256<>v_hash then
      raise exception using errcode='23505',message='idempotency_conflict';
    end if;
    return pg_catalog.jsonb_build_object('replayed',true,'review',pg_catalog.jsonb_build_object(
      'review_id',v_old.review_id,'assignment_id',v_old.assignment_id,
      'target_role',v_old.target_role,'rating',v_old.rating,'review_text',v_old.review_text,
      'created_at',v_old.created_at));
  end if;

  select * into v_assignment from app_private.assignments
    where assignment_id=p_assignment_id for update;
  if not found then raise exception using errcode='P0002',message='assignment_not_found'; end if;
  if p_actor=v_assignment.worker_id then
    v_target_role:='poster';v_subject_id:=v_assignment.poster_id;
  elsif p_actor=v_assignment.poster_id then
    v_target_role:='worker';v_subject_id:=v_assignment.worker_id;
  else
    raise exception using errcode='P0002',message='assignment_not_found';
  end if;
  if not app_private.assignment_review_is_eligible(p_assignment_id) then
    raise exception using errcode='P0001',message='review_not_eligible';
  end if;
  if exists(select 1 from app_private.assignment_reviews r
      where r.assignment_id=p_assignment_id and r.reviewer_id=p_actor) then
    raise exception using errcode='23505',message='review_already_submitted';
  end if;
  insert into app_private.assignment_reviews(
    assignment_id,reviewer_id,subject_id,target_role,rating,review_text,idempotency_key,request_sha256
  ) values(p_assignment_id,p_actor,v_subject_id,v_target_role,p_rating,v_text,p_idempotency_key,v_hash)
  on conflict(assignment_id,target_role) do nothing
  returning * into v_review;
  if not found then
    raise exception using errcode='23505',message='review_already_submitted';
  end if;
  return pg_catalog.jsonb_build_object('replayed',false,'review',pg_catalog.jsonb_build_object(
    'review_id',v_review.review_id,'assignment_id',v_review.assignment_id,
    'target_role',v_review.target_role,'rating',v_review.rating,'review_text',v_review.review_text,
    'created_at',v_review.created_at));
end;
$function$;

create function app_private.report_assignment_review_for_actor(p_actor uuid,p_review_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_review app_private.assignment_reviews%rowtype;
  v_report_id uuid;
begin
  if p_actor is null or p_review_id is null then
    raise exception using errcode='22023',message='invalid_review_report';
  end if;
  select * into v_review from app_private.assignment_reviews r
    where r.review_id=p_review_id for share;
  if not found or exists(select 1 from app_private.assignment_review_moderation_events m
      where m.review_id=p_review_id and m.action='hidden')
     or pg_catalog.cardinality(app_private.current_profile_capabilities(p_actor))=0
     or pg_catalog.cardinality(app_private.current_profile_capabilities(v_review.subject_id))=0
     or not exists(select 1 from public.profiles p
       join app_private.identity_accounts a on a.user_id=p.user_id and a.account_status='active'
       where p.user_id=v_review.subject_id) then
    raise exception using errcode='P0002',message='review_not_found';
  end if;
  insert into app_private.assignment_review_reports(review_id,reporter_id)
  values(p_review_id,p_actor) on conflict(review_id,reporter_id) do nothing;
  select report_id into v_report_id from app_private.assignment_review_reports
    where review_id=p_review_id and reporter_id=p_actor;
  return pg_catalog.jsonb_build_object('report_id',v_report_id,'reported',true);
end;
$function$;

create function app_private.lock_review_moderator_grant(p_actor uuid,p_auth_aal text)
returns uuid language plpgsql security definer set search_path = '' as $function$
declare v_grant_id uuid;
begin
  if p_actor is null or p_auth_aal is distinct from 'aal2'
     or not app_private.case_staff_principal_is_human(p_actor) then return null; end if;
  perform 1 from app_private.identity_accounts a
    where a.user_id=p_actor and a.account_status='active' for share;
  if not found then return null; end if;
  select g.grant_id into v_grant_id from app_private.staff_grants g
    where g.user_id=p_actor and g.capability='review_moderate' and g.revoked_at is null for share;
  return v_grant_id;
end;
$function$;

create function app_private.list_review_moderation_queue_for_actor(
  p_actor uuid,p_auth_aal text,p_before_reported_at timestamptz default null,
  p_before_review_id uuid default null,p_limit smallint default 21
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare v_result jsonb;
begin
  if p_limit is distinct from 21 or ((p_before_reported_at is null)<>(p_before_review_id is null)) then
    raise exception using errcode='22023',message='invalid_review_cursor';
  end if;
  if app_private.lock_review_moderator_grant(p_actor,p_auth_aal) is null then
    raise exception using errcode='42501',message='review_moderation_denied';
  end if;
  with reported as (
    select r.review_id,r.target_role,r.rating,r.review_text,r.created_at,
      pg_catalog.min(q.created_at) as first_reported_at,pg_catalog.count(*)::integer as report_count
    from app_private.assignment_reviews r
    join app_private.assignment_review_reports q on q.review_id=r.review_id
    where not exists(select 1 from app_private.assignment_review_moderation_events m
        where m.review_id=r.review_id and m.action='hidden')
      and p_actor not in (r.reviewer_id,r.subject_id)
    group by r.review_id,r.target_role,r.rating,r.review_text,r.created_at
  ), filtered as (
    select r.* from reported r
    where p_before_reported_at is null or (r.first_reported_at,r.review_id)>(p_before_reported_at,p_before_review_id)
  ), candidates as (
    select r.*,pg_catalog.row_number() over(order by r.first_reported_at,r.review_id) as page_number,
      pg_catalog.count(*) over() as total_count
    from filtered r
  ), page as (select * from candidates where page_number<=20)
  select pg_catalog.jsonb_build_object(
    'items',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'review_id',p.review_id,'target_role',p.target_role,'rating',p.rating,
      'review_text',p.review_text,'created_at',p.created_at,
      'first_reported_at',p.first_reported_at,'report_count',p.report_count
    ) order by p.page_number) from page p),'[]'::jsonb),
    'next_cursor',(select pg_catalog.jsonb_build_object(
      'before_reported_at',p.first_reported_at,'before_review_id',p.review_id)
      from candidates p where p.page_number=20 and p.total_count>20)
  ) into v_result;
  return v_result;
end;
$function$;

create function app_private.hide_assignment_review_for_actor(
  p_actor uuid,p_review_id uuid,p_reason text,p_auth_aal text,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_grant_id uuid;
  v_review app_private.assignment_reviews%rowtype;
  v_old app_private.assignment_review_moderation_events%rowtype;
  v_reason text;
  v_hash bytea;
  v_event app_private.assignment_review_moderation_events%rowtype;
begin
  if p_actor is null or p_review_id is null or p_idempotency_key is null then
    raise exception using errcode='22023',message='invalid_review_moderation';
  end if;
  v_reason:=pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(p_reason,'')),
    '[[:space:]]+',' ','g');
  if pg_catalog.char_length(v_reason) not between 20 and 500 then
    raise exception using errcode='22023',message='invalid_review_moderation_reason';
  end if;
  v_grant_id:=app_private.lock_review_moderator_grant(p_actor,p_auth_aal);
  if v_grant_id is null then raise exception using errcode='42501',message='review_moderation_denied'; end if;
  v_hash:=extensions.digest(pg_catalog.jsonb_build_object(
    'review_id',p_review_id,'reason',v_reason)::text,'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'review_moderation:'||p_actor::text||':'||p_idempotency_key::text,78113));
  select * into v_old from app_private.assignment_review_moderation_events
    where moderator_id=p_actor and idempotency_key=p_idempotency_key;
  if found then
    if v_old.request_sha256<>v_hash then
      raise exception using errcode='23505',message='idempotency_conflict';
    end if;
    return pg_catalog.jsonb_build_object('review_id',v_old.review_id,'status','hidden','replayed',true);
  end if;
  select * into v_review from app_private.assignment_reviews where review_id=p_review_id for update;
  if not found then raise exception using errcode='P0002',message='review_not_found'; end if;
  if p_actor in (v_review.reviewer_id,v_review.subject_id) then
    raise exception using errcode='42501',message='review_moderation_denied';
  end if;
  if not exists(select 1 from app_private.assignment_review_reports q where q.review_id=p_review_id) then
    raise exception using errcode='P0001',message='review_moderation_requires_report';
  end if;
  insert into app_private.assignment_review_moderation_events(
    review_id,action,moderator_id,staff_grant_id,reason,idempotency_key,request_sha256
  ) values(p_review_id,'hidden',p_actor,v_grant_id,v_reason,p_idempotency_key,v_hash)
  on conflict(review_id) do nothing
  returning * into v_event;
  if not found then
    raise exception using errcode='P0001',message='review_already_hidden';
  end if;
  return pg_catalog.jsonb_build_object('review_id',v_event.review_id,'status','hidden','replayed',false);
end;
$function$;

create function app_private.list_profile_reviews_for_viewer(
  p_viewer uuid,p_subject uuid,p_before_created_at timestamptz default null,
  p_before_review_id uuid default null
) returns jsonb language plpgsql stable security definer set search_path = '' as $function$
declare v_result jsonb;
begin
  if p_viewer is null or p_subject is null
     or ((p_before_created_at is null)<>(p_before_review_id is null)) then
    raise exception using errcode='22023',message='invalid_review_cursor';
  end if;
  if pg_catalog.cardinality(app_private.current_profile_capabilities(p_viewer))=0
     or pg_catalog.cardinality(app_private.current_profile_capabilities(p_subject))=0
     or not exists(select 1 from public.profiles p
       join app_private.identity_accounts a on a.user_id=p.user_id and a.account_status='active'
       where p.user_id=p_subject) then
    raise exception using errcode='P0002',message='profile_not_found';
  end if;
  with filtered as (
    select r.review_id,r.target_role,r.rating,r.review_text,r.created_at
    from app_private.assignment_reviews r
    where r.subject_id=p_subject and not exists(
      select 1 from app_private.assignment_review_moderation_events m
      where m.review_id=r.review_id and m.action='hidden')
      and (p_before_created_at is null or (r.created_at,r.review_id)<(p_before_created_at,p_before_review_id))
  ), candidates as (
    select r.*,pg_catalog.row_number() over(order by r.created_at desc,r.review_id desc) as page_number,
      pg_catalog.count(*) over() as total_count
    from filtered r
  ), page as (select * from candidates where page_number<=20)
  select pg_catalog.jsonb_build_object(
    'items',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'review_id',p.review_id,'target_role',p.target_role,'rating',p.rating,
      'review_text',p.review_text,'created_at',p.created_at) order by p.page_number)
      from page p),'[]'::jsonb),
    'next_cursor',(select pg_catalog.jsonb_build_object(
      'before_created_at',p.created_at,'before_review_id',p.review_id)
      from candidates p where p.page_number=20 and p.total_count>20)
  ) into v_result;
  return v_result;
end;
$function$;

create or replace function app_private.get_safe_profile_for_viewer(p_viewer uuid,p_subject uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $function$
declare
  v_profile jsonb;
  v_projection app_private.profile_reputation_projections%rowtype;
begin
  if p_viewer is null or p_subject is null
     or pg_catalog.cardinality(app_private.current_profile_capabilities(p_viewer))=0
     or pg_catalog.cardinality(app_private.current_profile_capabilities(p_subject))=0 then
    raise exception using errcode='P0002',message='profile_not_found';
  end if;
  select * into v_projection from app_private.profile_reputation_projections p where p.user_id=p_subject;
  select pg_catalog.jsonb_build_object(
    'profile_id',p.user_id,'account_type',a.account_type,'verified_badge',true,
    'display_name',p.display_name,'photo_key',p.photo_key,'faculty_label',p.faculty_label,
    'campus_label',p.campus_label,'bio',p.bio,'skills',pg_catalog.to_jsonb(p.skills),
    'availability',p.availability,'business_name',p.business_name,
    'business_location',p.business_location,'organisation_label',p.organisation_label,
    'worker_rating',case when coalesce(v_projection.worker_review_count,0)=0 then null
      else pg_catalog.round(v_projection.worker_rating_sum::numeric/v_projection.worker_review_count,2) end,
    'worker_review_count',coalesce(v_projection.worker_review_count,0),
    'poster_rating',case when coalesce(v_projection.poster_review_count,0)=0 then null
      else pg_catalog.round(v_projection.poster_rating_sum::numeric/v_projection.poster_review_count,2) end,
    'poster_review_count',coalesce(v_projection.poster_review_count,0),
    'completed_work_count',coalesce(v_projection.completed_work_count,0)
  ) into v_profile
  from public.profiles p join app_private.identity_accounts a on a.user_id=p.user_id
  where p.user_id=p_subject and a.account_status='active';
  if v_profile is null then raise exception using errcode='P0002',message='profile_not_found'; end if;
  return v_profile;
end;
$function$;

select app_private.rebuild_profile_reputation_projections();

create or replace function public.server_get_safe_profile_for_viewer(p_viewer uuid,p_subject uuid)
returns jsonb language sql stable security definer set search_path = '' as $function$
  select app_private.get_safe_profile_for_viewer(p_viewer,p_subject)
$function$;
create function public.server_list_profile_reviews_for_viewer(
  p_viewer uuid,p_subject uuid,p_before_created_at timestamptz default null,p_before_review_id uuid default null
) returns jsonb language sql stable security definer set search_path = '' as $function$
  select app_private.list_profile_reviews_for_viewer($1,$2,$3,$4)
$function$;
create function public.server_submit_assignment_review_for_actor(
  p_actor uuid,p_assignment_id uuid,p_rating smallint,p_review_text text,p_idempotency_key uuid
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.submit_assignment_review_for_actor($1,$2,$3,$4,$5)
$function$;
create function public.server_report_assignment_review_for_actor(p_actor uuid,p_review_id uuid)
returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.report_assignment_review_for_actor($1,$2)
$function$;
create function public.server_list_review_moderation_queue_for_actor(
  p_actor uuid,p_auth_aal text,p_before_reported_at timestamptz default null,
  p_before_review_id uuid default null,p_limit smallint default 21
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.list_review_moderation_queue_for_actor($1,$2,$3,$4,$5)
$function$;
create function public.server_hide_assignment_review_for_actor(
  p_actor uuid,p_review_id uuid,p_reason text,p_auth_aal text,p_idempotency_key uuid
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.hide_assignment_review_for_actor($1,$2,$3,$4,$5)
$function$;

revoke all on table app_private.assignment_reviews,app_private.assignment_review_reports,
  app_private.assignment_review_moderation_events,app_private.profile_reputation_projections
from public,anon,authenticated,service_role;
revoke all on function app_private.assignment_has_qualifying_completion(uuid),
  app_private.assignment_review_is_eligible(uuid),
  app_private.reject_assignment_review_mutation(),
  app_private.validate_assignment_review_insert(),
  app_private.refresh_profile_reputation_projection(uuid),
  app_private.refresh_profile_reputation_after_review(),
  app_private.refresh_profile_reputation_after_hide(),
  app_private.refresh_profile_reputation_after_completion(),
  app_private.rebuild_profile_reputation_projections(),
  app_private.submit_assignment_review_for_actor(uuid,uuid,smallint,text,uuid),
  app_private.report_assignment_review_for_actor(uuid,uuid),
  app_private.lock_review_moderator_grant(uuid,text),
  app_private.list_review_moderation_queue_for_actor(uuid,text,timestamp with time zone,uuid,smallint),
  app_private.hide_assignment_review_for_actor(uuid,uuid,text,text,uuid),
  app_private.list_profile_reviews_for_viewer(uuid,uuid,timestamp with time zone,uuid),
  app_private.get_safe_profile_for_viewer(uuid,uuid)
from public,anon,authenticated,service_role;
revoke all on function public.server_get_safe_profile_for_viewer(uuid,uuid),
  public.server_list_profile_reviews_for_viewer(uuid,uuid,timestamp with time zone,uuid),
  public.server_submit_assignment_review_for_actor(uuid,uuid,smallint,text,uuid),
  public.server_report_assignment_review_for_actor(uuid,uuid),
  public.server_list_review_moderation_queue_for_actor(uuid,text,timestamp with time zone,uuid,smallint),
  public.server_hide_assignment_review_for_actor(uuid,uuid,text,text,uuid)
from public,anon,authenticated,service_role;
grant execute on function app_private.rebuild_profile_reputation_projections(),
  app_private.submit_assignment_review_for_actor(uuid,uuid,smallint,text,uuid),
  app_private.report_assignment_review_for_actor(uuid,uuid),
  app_private.list_review_moderation_queue_for_actor(uuid,text,timestamp with time zone,uuid,smallint),
  app_private.hide_assignment_review_for_actor(uuid,uuid,text,text,uuid),
  app_private.list_profile_reviews_for_viewer(uuid,uuid,timestamp with time zone,uuid),
  app_private.get_safe_profile_for_viewer(uuid,uuid)
to postgres;
grant execute on function public.server_get_safe_profile_for_viewer(uuid,uuid),
  public.server_list_profile_reviews_for_viewer(uuid,uuid,timestamp with time zone,uuid),
  public.server_submit_assignment_review_for_actor(uuid,uuid,smallint,text,uuid),
  public.server_report_assignment_review_for_actor(uuid,uuid),
  public.server_list_review_moderation_queue_for_actor(uuid,text,timestamp with time zone,uuid,smallint),
  public.server_hide_assignment_review_for_actor(uuid,uuid,text,text,uuid)
to service_role;

commit;
