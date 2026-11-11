begin;

-- A report is an immutable fact. The case row below is the separately mutable
-- current lifecycle which decides whether that report still freezes a slot.
alter table app_private.assignment_holds
  add column follow_up text check (follow_up is null or char_length(follow_up) between 1 and 500);
drop index app_private.assignment_holds_one_active_per_allocation;

create table app_private.assignment_cases (
  case_id uuid primary key,
  hold_id uuid not null unique,
  assignment_id uuid not null,
  allocation_id uuid not null,
  lifecycle_status text not null check (lifecycle_status in (
    'open','under_review','contacting_other_party','verifying',
    'decision_made','appeal','refund_pending','closed'
  )),
  version integer not null default 1 check (version>0),
  reviewer_id uuid references auth.users(id) on delete restrict,
  terms_version integer not null check (terms_version>0),
  terms_sha256 bytea not null check (pg_catalog.octet_length(terms_sha256)=32),
  prior_work_state text not null check (prior_work_state in ('assigned','in_progress','submitted')),
  thread_id uuid not null references app_private.application_threads(thread_id) on delete restrict,
  thread_through_sequence bigint not null check (thread_through_sequence>=0),
  opened_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  closed_at timestamptz,
  foreign key (hold_id,assignment_id,allocation_id)
    references app_private.assignment_holds(hold_id,assignment_id,allocation_id) on delete restrict,
  foreign key (assignment_id) references app_private.assignments(assignment_id) on delete restrict,
  check (case_id=hold_id),
  check ((lifecycle_status='closed')=(closed_at is not null))
);
create unique index assignment_cases_one_active_per_allocation
  on app_private.assignment_cases(allocation_id) where lifecycle_status<>'closed';
create index assignment_cases_assignment_history_idx
  on app_private.assignment_cases(assignment_id,opened_at desc,case_id desc);

create table app_private.assignment_case_events (
  event_id uuid primary key default pg_catalog.gen_random_uuid(),
  case_id uuid not null references app_private.assignment_cases(case_id) on delete restrict,
  sequence integer not null check (sequence>0),
  actor_id uuid references auth.users(id) on delete restrict,
  audience text not null check (audience in ('participants','staff')),
  event_type text not null check (event_type in (
    'case_opened','reviewer_assigned','reviewer_reassigned','status_changed',
    'participant_response','evidence_added','decision_notified','appeal_opened','case_closed'
  )),
  payload jsonb not null check (pg_catalog.jsonb_typeof(payload)='object'
    and pg_catalog.octet_length(payload::text)<=16384),
  created_at timestamptz not null default pg_catalog.now(),
  unique(case_id,sequence)
);
create index assignment_case_events_timeline_idx
  on app_private.assignment_case_events(case_id,sequence desc);

create table app_private.assignment_case_access_audit (
  access_id uuid primary key default pg_catalog.gen_random_uuid(),
  case_id uuid not null references app_private.assignment_cases(case_id) on delete restrict,
  actor_id uuid not null references auth.users(id) on delete restrict,
  action text not null check (action in ('case_read','case_queue_read','case_assigned','case_reassigned')),
  previous_reviewer_id uuid references auth.users(id) on delete restrict,
  new_reviewer_id uuid references auth.users(id) on delete restrict,
  created_at timestamptz not null default pg_catalog.now()
);
create index assignment_case_access_audit_case_idx
  on app_private.assignment_case_access_audit(case_id,created_at desc,access_id desc);

create table app_private.case_command_idempotency (
  actor_id uuid not null references auth.users(id) on delete restrict,
  command_name text not null check (command_name in ('assign_case_reviewer')),
  idempotency_key uuid not null,
  request_sha256 bytea not null check (pg_catalog.octet_length(request_sha256)=32),
  response jsonb not null check (pg_catalog.jsonb_typeof(response)='object'),
  created_at timestamptz not null default pg_catalog.now(),
  primary key(actor_id,command_name,idempotency_key)
);

-- Dispute evidence defaults are independent from identity verification files.
-- Uploads remain unavailable until the later scanning/quarantine step is built.
create table app_private.case_file_policy (
  policy_id smallint primary key default 1 check (policy_id=1),
  max_files smallint not null default 5 check (max_files between 1 and 25),
  max_file_bytes bigint not null default 5000000 check (max_file_bytes between 1 and 100000000),
  updated_at timestamptz not null default pg_catalog.now()
);
insert into app_private.case_file_policy(policy_id) values (1);

-- Preserve all Phase 3 reports and create current lifecycle records for them.
insert into app_private.assignment_cases(
  case_id,hold_id,assignment_id,allocation_id,lifecycle_status,terms_version,
  terms_sha256,prior_work_state,thread_id,thread_through_sequence,opened_at,updated_at
)
select h.hold_id,h.hold_id,h.assignment_id,h.allocation_id,'open',a.terms_version,
  a.terms_sha256,h.prior_work_state,t.thread_id,t.last_sequence,h.created_at,h.created_at
from app_private.assignment_holds h
join app_private.assignments a on a.assignment_id=h.assignment_id
join app_private.application_threads t on t.application_id=a.application_id;
insert into app_private.assignment_case_events(
  case_id,sequence,actor_id,audience,event_type,payload,created_at
)
select c.case_id,1,h.opened_by,'participants','case_opened',pg_catalog.jsonb_build_object(
  'status','open','reporter_role',h.opened_by_role,'reason_code',h.reason_code,
  'narrative',h.narrative,'desired_outcome',h.desired_outcome,'follow_up',h.follow_up,
  'prior_assignment_state',h.prior_work_state),h.created_at
from app_private.assignment_cases c
join app_private.assignment_holds h on h.hold_id=c.hold_id;

alter table app_private.marketplace_outbox
  drop constraint marketplace_outbox_event_type_check;
alter table app_private.marketplace_outbox
  add constraint marketplace_outbox_event_type_check check (event_type in (
    'job.draft_created','job.draft_updated','job.funding_started','job.funded',
    'job.funding_failed','job.funding_exception','job.application_created',
    'job.application_accepted','job.application_rejected','job.application_withdrawn',
    'job.application_closed','job.message_created','job.assignment_started',
    'job.assignment_submitted','job.assignment_completed','job.assignment_hold_opened',
    'job.assignment_case_reviewer_assigned'
  ));
alter table app_private.in_app_notifications
  drop constraint in_app_notifications_notification_type_check;
alter table app_private.in_app_notifications
  add constraint in_app_notifications_notification_type_check check (notification_type in (
    'application_received','application_accepted','application_rejected',
    'application_withdrawn','application_closed','new_message',
    'assignment_started','assignment_submitted','assignment_completed',
    'assignment_hold_opened','assignment_case_updated',
    'withdrawal_requested','withdrawal_processing','withdrawal_unknown',
    'withdrawal_paid','withdrawal_failed','withdrawal_reversed','withdrawal_exception'
  ));

create function app_private.reject_assignment_case_event_mutation()
returns trigger language plpgsql set search_path = '' as $function$
begin
  raise exception using errcode='55000',message='case_history_is_immutable';
end;
$function$;
create trigger assignment_case_events_immutable before update or delete
on app_private.assignment_case_events for each row
execute function app_private.reject_assignment_case_event_mutation();
create trigger assignment_case_access_audit_immutable before update or delete
on app_private.assignment_case_access_audit for each row
execute function app_private.reject_assignment_case_event_mutation();
create trigger case_command_idempotency_immutable before update or delete
on app_private.case_command_idempotency for each row
execute function app_private.reject_assignment_case_event_mutation();

create function app_private.guard_assignment_case_lifecycle()
returns trigger language plpgsql set search_path = '' as $function$
begin
  if tg_op='DELETE' then
    raise exception using errcode='55000',message='case_lifecycle_cannot_be_deleted';
  end if;
  if new.case_id is distinct from old.case_id
     or new.hold_id is distinct from old.hold_id
     or new.assignment_id is distinct from old.assignment_id
     or new.allocation_id is distinct from old.allocation_id
     or new.terms_version is distinct from old.terms_version
     or new.terms_sha256 is distinct from old.terms_sha256
     or new.prior_work_state is distinct from old.prior_work_state
     or new.thread_id is distinct from old.thread_id
     or new.thread_through_sequence is distinct from old.thread_through_sequence
     or new.opened_at is distinct from old.opened_at
     or coalesce(current_setting('app.assignment_case_transition',true),'')<>'assign_reviewer'
     or new.lifecycle_status<>'under_review'
     or new.reviewer_id is null
     or new.closed_at is not null
     or new.version<>old.version+1 then
    raise exception using errcode='55000',message='invalid_case_lifecycle_transition';
  end if;
  new.updated_at:=pg_catalog.now();
  return new;
end;
$function$;
create trigger assignment_cases_controlled_update before update or delete
on app_private.assignment_cases for each row
execute function app_private.guard_assignment_case_lifecycle();

create or replace function app_private.validate_assignment_allocation_pair()
returns trigger language plpgsql security definer set search_path = '' as $function$
begin
  if tg_table_name='principal_allocations' then
    if new.status<>'unassigned' and not exists (
      select 1 from app_private.assignments a
      where a.assignment_id=new.assignment_id and a.allocation_id=new.allocation_id
        and a.job_id=new.job_id and a.poster_id=new.poster_id
        and a.funding_intent_id=new.funding_intent_id
        and a.gross_principal_kobo=new.gross_principal_kobo
        and a.commission_basis_points=new.commission_basis_points
        and (
          (new.status='assigned' and a.work_state in ('assigned','in_progress','submitted')
            and not exists(select 1 from app_private.assignment_cases c
              where c.allocation_id=new.allocation_id and c.lifecycle_status<>'closed')) or
          (new.status='dispute_held' and a.work_state in ('assigned','in_progress','submitted')
            and exists(select 1 from app_private.assignment_cases c
              where c.assignment_id=a.assignment_id and c.allocation_id=new.allocation_id
                and c.lifecycle_status<>'closed')) or
          (new.status='worker_earnings_allocated' and a.work_state='completed'
            and exists(select 1 from app_private.assignment_completion_authorizations c
              where c.assignment_id=a.assignment_id and c.allocation_id=new.allocation_id))
        )
    ) then
      raise exception using errcode='22023',message='invalid_assignment_allocation_binding';
    end if;
  elsif not exists (
    select 1 from app_private.principal_allocations p
    where p.allocation_id=new.allocation_id and p.assignment_id=new.assignment_id
      and p.job_id=new.job_id and p.poster_id=new.poster_id
      and p.funding_intent_id=new.funding_intent_id
      and p.gross_principal_kobo=new.gross_principal_kobo
      and p.commission_basis_points=new.commission_basis_points
      and (
        (p.status='assigned' and new.work_state in ('assigned','in_progress','submitted')
          and not exists(select 1 from app_private.assignment_cases c
            where c.allocation_id=p.allocation_id and c.lifecycle_status<>'closed')) or
        (p.status='dispute_held' and new.work_state in ('assigned','in_progress','submitted')
          and exists(select 1 from app_private.assignment_cases c
            where c.assignment_id=new.assignment_id and c.allocation_id=p.allocation_id
              and c.lifecycle_status<>'closed')) or
        (p.status='worker_earnings_allocated' and new.work_state='completed'
          and exists(select 1 from app_private.assignment_completion_authorizations c
            where c.assignment_id=new.assignment_id and c.allocation_id=p.allocation_id))
      )
  ) then
    raise exception using errcode='22023',message='invalid_assignment_allocation_binding';
  end if;
  return null;
end;
$function$;

create or replace function app_private.assignment_hold_projection(p_hold_id uuid,p_assignment_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $function$
  select pg_catalog.jsonb_build_object(
    'case_id',h.hold_id,'hold_id',h.hold_id,'status',h.status,'prior_assignment_state',h.prior_work_state,
    'reason_code',h.reason_code,'narrative',h.narrative,'desired_outcome',h.desired_outcome,
    'follow_up',h.follow_up,'opened_at',h.created_at
  )
  from app_private.assignment_holds h
  where h.hold_id=p_hold_id and h.assignment_id=p_assignment_id
$function$;

create or replace function app_private.open_assignment_case_for_actor(
  p_actor uuid,p_assignment_id uuid,p_reason_code text,p_narrative text,
  p_desired_outcome text,p_follow_up text,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_caps text[];
  v_account_status text;
  v_assignment app_private.assignments%rowtype;
  v_allocation app_private.principal_allocations%rowtype;
  v_job app_private.jobs%rowtype;
  v_funding app_private.funding_intents%rowtype;
  v_thread app_private.application_threads%rowtype;
  v_hash bytea;
  v_existing app_private.financial_command_idempotency%rowtype;
  v_hold_id uuid:=pg_catalog.gen_random_uuid();
  v_role text;
  v_event_id uuid;
begin
  if p_actor is null or p_assignment_id is null or p_idempotency_key is null
     or p_reason_code is null or p_narrative is null or p_desired_outcome is null then
    raise exception using errcode='22023',message='invalid_assignment_hold';
  end if;
  p_narrative:=pg_catalog.btrim(p_narrative);
  p_desired_outcome:=pg_catalog.btrim(p_desired_outcome);
  p_follow_up:=nullif(pg_catalog.btrim(p_follow_up),'');
  if char_length(p_narrative) not between 1 and 2000
     or char_length(p_desired_outcome) not between 1 and 500
     or (p_follow_up is not null and char_length(p_follow_up)>500)
     or p_reason_code not in ('payment_not_released','incomplete_work','work_not_as_described',
       'unresponsive_no_show','conduct_safety','other') then
    raise exception using errcode='22023',message='invalid_assignment_hold';
  end if;
  select * into v_assignment from app_private.assignments where assignment_id=p_assignment_id;
  if not found or p_actor not in (v_assignment.worker_id,v_assignment.poster_id) then
    raise exception using errcode='P0002',message='assignment_not_found';
  end if;
  v_role:=case when p_actor=v_assignment.worker_id then 'worker' else 'poster' end;
  select account_status into v_account_status from app_private.identity_accounts where user_id=p_actor;
  v_caps:=app_private.current_profile_capabilities(p_actor);
  if v_account_status is null or v_account_status not in ('active','suspended') or
     (v_account_status='active' and
       ((v_role='worker' and not ('can_work'=any(v_caps))) or
        (v_role='poster' and not ('can_hire'=any(v_caps))))) then
    raise exception using errcode='42501',message='verification_required';
  end if;
  v_hash:=extensions.digest(pg_catalog.jsonb_build_object(
    'assignment_id',p_assignment_id,'reason_code',p_reason_code,
    'narrative',p_narrative,'desired_outcome',p_desired_outcome,'follow_up',p_follow_up)::text,'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    p_actor::text||':open_assignment_hold:'||p_idempotency_key::text,428118));
  select * into v_existing from app_private.financial_command_idempotency
  where actor_id=p_actor and command_name='open_assignment_hold' and idempotency_key=p_idempotency_key;
  select * into v_allocation from app_private.principal_allocations
  where allocation_id=v_assignment.allocation_id for update;
  select * into v_assignment from app_private.assignments
  where assignment_id=p_assignment_id for update;
  select account_status into v_account_status from app_private.identity_accounts where user_id=p_actor;
  v_caps:=app_private.current_profile_capabilities(p_actor);
  if v_account_status is null or v_account_status not in ('active','suspended') or
     (v_account_status='active' and
       ((v_role='worker' and not ('can_work'=any(v_caps))) or
        (v_role='poster' and not ('can_hire'=any(v_caps))))) then
    raise exception using errcode='42501',message='verification_required';
  end if;
  if p_actor not in (v_assignment.worker_id,v_assignment.poster_id) then
    raise exception using errcode='P0002',message='assignment_not_found';
  end if;
  if v_allocation.assignment_id<>v_assignment.assignment_id
     or v_assignment.gross_principal_kobo<>v_allocation.gross_principal_kobo
     or v_assignment.commission_basis_points<>v_allocation.commission_basis_points then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  select * into v_funding from app_private.funding_intents
  where intent_id=v_assignment.funding_intent_id and status='succeeded'
    and job_id=v_assignment.job_id and poster_id=v_assignment.poster_id
    and terms_version=v_assignment.terms_version
    and gross_per_worker_kobo=v_assignment.gross_principal_kobo
    and terms_sha256=v_assignment.terms_sha256 and currency='NGN';
  if not found then raise exception using errcode='P0001',message='stale_state'; end if;
  select * into v_job from app_private.jobs where job_id=v_assignment.job_id;
  if not found or v_job.funded_funding_intent_id<>v_assignment.funding_intent_id then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  if v_existing.actor_id is not null then
    if v_existing.request_sha256<>v_hash then
      raise exception using errcode='23505',message='idempotency_conflict';
    end if;
    return pg_catalog.jsonb_build_object(
      'assignment',app_private.assignment_command_projection(
        v_assignment.application_id,v_assignment.assignment_id),
      'hold',app_private.assignment_hold_projection(
        v_existing.response_reference_id,v_assignment.assignment_id));
  end if;
  if v_allocation.status='dispute_held' then
    raise exception using errcode='P0001',message='assignment_on_hold';
  end if;
  if v_assignment.work_state in ('completed','cancelled') or v_allocation.status<>'assigned' then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  if v_assignment.work_state not in ('assigned','in_progress','submitted') then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  select * into v_thread from app_private.application_threads
  where application_id=v_assignment.application_id;
  if not found or not exists(select 1 from app_private.job_terms_versions t
      where t.job_id=v_assignment.job_id and t.terms_version=v_assignment.terms_version
        and t.terms_sha256=v_assignment.terms_sha256) then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  insert into app_private.assignment_holds(
    hold_id,assignment_id,allocation_id,job_id,opened_by,opened_by_role,
    prior_work_state,reason_code,narrative,desired_outcome,follow_up
  ) values(v_hold_id,v_assignment.assignment_id,v_allocation.allocation_id,
    v_assignment.job_id,p_actor,v_role,v_assignment.work_state,p_reason_code,
    p_narrative,p_desired_outcome,p_follow_up);
  insert into app_private.assignment_cases(
    case_id,hold_id,assignment_id,allocation_id,lifecycle_status,terms_version,
    terms_sha256,prior_work_state,thread_id,thread_through_sequence
  ) values(v_hold_id,v_hold_id,v_assignment.assignment_id,v_allocation.allocation_id,
    'open',v_assignment.terms_version,v_assignment.terms_sha256,v_assignment.work_state,
    v_thread.thread_id,v_thread.last_sequence);
  insert into app_private.assignment_case_events(
    case_id,sequence,actor_id,audience,event_type,payload
  ) values(v_hold_id,1,p_actor,'participants','case_opened',pg_catalog.jsonb_build_object(
    'status','open','reporter_role',v_role,'reason_code',p_reason_code,
    'narrative',p_narrative,'desired_outcome',p_desired_outcome,'follow_up',p_follow_up,
    'prior_assignment_state',v_assignment.work_state));
  update app_private.principal_allocations set status='dispute_held'
  where allocation_id=v_allocation.allocation_id and status='assigned';
  if not found then raise exception using errcode='P0001',message='assignment_on_hold'; end if;
  v_event_id:=app_private.append_marketplace_event(p_actor,v_job.job_id,
    'job.assignment_hold_opened',v_assignment.terms_version,
    pg_catalog.jsonb_build_object(
      'assignment_id',v_assignment.assignment_id,'hold_id',v_hold_id,
      'prior_assignment_state',v_assignment.work_state,'reason_code',p_reason_code));
  perform app_private.add_in_app_notification(v_event_id,v_assignment.worker_id,'assignment_hold_opened');
  perform app_private.add_in_app_notification(v_event_id,v_assignment.poster_id,'assignment_hold_opened');
  insert into app_private.financial_audit_events(
    actor_id,event_type,journal_id,reference_id,event_data
  ) values(p_actor,'assignment_hold_opened',
    (select j.journal_id from app_private.ledger_journal_transactions j
      where j.effect_key=app_private.stable_financial_effect_key(
        'nbd:allocation_held:'||v_allocation.allocation_id::text)),
    v_assignment.assignment_id,
    pg_catalog.jsonb_build_object('action','assignment_hold_opened',
      'hold_id',v_hold_id,'allocation_id',v_allocation.allocation_id));
  insert into app_private.financial_command_idempotency(
    actor_id,command_name,idempotency_key,request_sha256,response_reference_id,response_code
  ) values(p_actor,'open_assignment_hold',p_idempotency_key,v_hash,
    v_hold_id,'hold:'||p_assignment_id::text);
  return pg_catalog.jsonb_build_object(
    'assignment',app_private.assignment_command_projection(
      v_assignment.application_id,v_assignment.assignment_id),
    'hold',app_private.assignment_hold_projection(v_hold_id,v_assignment.assignment_id));
end;
$function$;

create or replace function app_private.open_assignment_hold_for_actor(
  p_actor uuid,p_assignment_id uuid,p_reason_code text,p_narrative text,
  p_desired_outcome text,p_idempotency_key uuid
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.open_assignment_case_for_actor(
    p_actor,p_assignment_id,p_reason_code,p_narrative,p_desired_outcome,null,p_idempotency_key)
$function$;

create or replace function app_private.get_assignment_status_for_actor(p_actor uuid,p_assignment_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $function$
declare
  v_assignment app_private.assignments%rowtype;
  v_hold_id uuid;
begin
  if p_actor is null or p_assignment_id is null then
    raise exception using errcode='22023',message='invalid_assignment_query';
  end if;
  select * into v_assignment from app_private.assignments
  where assignment_id=p_assignment_id;
  if not found or p_actor not in (v_assignment.worker_id,v_assignment.poster_id) then
    raise exception using errcode='P0002',message='assignment_not_found';
  end if;
  select hold_id into v_hold_id from app_private.assignment_cases
  where assignment_id=p_assignment_id and lifecycle_status<>'closed';
  return pg_catalog.jsonb_build_object(
    'assignment',app_private.assignment_command_projection(
      v_assignment.application_id,v_assignment.assignment_id),
    'hold',case when v_hold_id is null then null
      else app_private.assignment_hold_projection(v_hold_id,p_assignment_id) end
  );
end;
$function$;

-- The old report rows are immutable and therefore cannot serve as the current
-- hold predicate after a case is later closed. Keep completion checks on the
-- effective case lifecycle plus the allocation's canonical held status.
create or replace function app_private.confirm_completion_for_actor(
  p_actor uuid,p_assignment_id uuid,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_caps text[];
  v_assignment app_private.assignments%rowtype;
  v_allocation app_private.principal_allocations%rowtype;
  v_job app_private.jobs%rowtype;
  v_funding app_private.funding_intents%rowtype;
  v_hash bytea;
  v_existing app_private.financial_command_idempotency%rowtype;
  v_commission bigint;
  v_worker_net bigint;
  v_effect_key uuid;
  v_journal_id uuid;
  v_entries jsonb;
  v_event_id uuid;
  v_result jsonb;
begin
  if p_actor is null or p_assignment_id is null or p_idempotency_key is null then
    raise exception using errcode='22023',message='invalid_assignment_request';
  end if;
  select * into v_assignment from app_private.assignments where assignment_id=p_assignment_id;
  if not found or v_assignment.poster_id<>p_actor then
    raise exception using errcode='P0002',message='assignment_not_found';
  end if;
  v_caps:=app_private.current_profile_capabilities(p_actor);
  if not ('can_hire'=any(v_caps)) then
    raise exception using errcode='42501',message='verification_required';
  end if;
  v_hash:=extensions.digest(pg_catalog.jsonb_build_object('assignment_id',p_assignment_id)::text,'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    p_actor::text||':confirm_completion:'||p_idempotency_key::text,428118));
  select * into v_existing from app_private.financial_command_idempotency
  where actor_id=p_actor and command_name='confirm_completion' and idempotency_key=p_idempotency_key;
  select * into v_allocation from app_private.principal_allocations
  where allocation_id=v_assignment.allocation_id for update;
  select * into v_assignment from app_private.assignments
  where assignment_id=p_assignment_id for update;
  v_caps:=app_private.current_profile_capabilities(p_actor);
  if not ('can_hire'=any(v_caps)) then
    raise exception using errcode='42501',message='verification_required';
  end if;
  if v_assignment.poster_id<>p_actor then
    raise exception using errcode='P0002',message='assignment_not_found';
  end if;
  if v_allocation.assignment_id<>v_assignment.assignment_id
     or v_assignment.gross_principal_kobo<>v_allocation.gross_principal_kobo
     or v_assignment.commission_basis_points<>v_allocation.commission_basis_points then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  select * into v_funding from app_private.funding_intents
  where intent_id=v_assignment.funding_intent_id and status='succeeded'
    and job_id=v_assignment.job_id and poster_id=v_assignment.poster_id
    and terms_version=v_assignment.terms_version
    and gross_per_worker_kobo=v_assignment.gross_principal_kobo
    and terms_sha256=v_assignment.terms_sha256 and currency='NGN';
  if not found then raise exception using errcode='P0001',message='stale_state'; end if;
  select * into v_job from app_private.jobs where job_id=v_assignment.job_id;
  if not found or v_job.funded_funding_intent_id<>v_assignment.funding_intent_id then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  if v_existing.actor_id is not null then
    if v_existing.request_sha256<>v_hash then
      raise exception using errcode='23505',message='idempotency_conflict';
    end if;
    return app_private.assignment_command_projection(
      v_existing.response_reference_id,pg_catalog.split_part(v_existing.response_code,':',2)::uuid);
  end if;
  if v_allocation.status='dispute_held' then
    raise exception using errcode='P0001',message='assignment_on_hold';
  end if;
  if v_allocation.status<>'assigned' or v_assignment.work_state<>'submitted' then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  if exists(select 1 from app_private.assignment_cases c
       where c.allocation_id=v_allocation.allocation_id and c.lifecycle_status<>'closed') then
    raise exception using errcode='P0001',message='assignment_on_hold';
  end if;

  v_commission:=app_private.calculate_commission_kobo(v_assignment.gross_principal_kobo);
  v_worker_net:=v_assignment.gross_principal_kobo-v_commission;
  v_effect_key:=app_private.stable_financial_effect_key(
    'nbd:completion_released:'||v_allocation.allocation_id::text);
  v_entries:=pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object('account_code','job_principal_assigned','direction','debit',
      'amount_kobo',v_assignment.gross_principal_kobo::text,
      'allocation_id',v_allocation.allocation_id::text),
    pg_catalog.jsonb_build_object('account_code','worker_earnings_available','direction','credit',
      'amount_kobo',v_worker_net::text,'allocation_id',v_allocation.allocation_id::text,
      'owner_id',v_assignment.worker_id::text)
  );
  if v_commission>0 then
    v_entries:=v_entries||pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('account_code','platform_commission_revenue','direction','credit',
        'amount_kobo',v_commission::text,'allocation_id',v_allocation.allocation_id::text));
  end if;
  v_journal_id:=app_private.post_financial_journal(
    v_effect_key,'completion_released',v_allocation.allocation_id,p_actor,v_entries);
  insert into app_private.assignment_completion_authorizations(
    assignment_id,allocation_id,actor_id,terms_version,terms_sha256,
    gross_principal_kobo,commission_kobo,worker_net_kobo,journal_id,idempotency_key
  ) values(v_assignment.assignment_id,v_allocation.allocation_id,p_actor,
    v_assignment.terms_version,v_assignment.terms_sha256,v_assignment.gross_principal_kobo,
    v_commission,v_worker_net,v_journal_id,p_idempotency_key);
  insert into app_private.financial_audit_events(
    actor_id,event_type,journal_id,reference_id,event_data
  ) values(p_actor,'assignment_completion_authorized',v_journal_id,v_assignment.assignment_id,
    pg_catalog.jsonb_build_object(
      'allocation_id',v_allocation.allocation_id,'terms_version',v_assignment.terms_version,
      'gross_principal_kobo',v_assignment.gross_principal_kobo::text,
      'commission_kobo',v_commission::text,'worker_net_kobo',v_worker_net::text));
  update app_private.principal_allocations set status='worker_earnings_allocated'
  where allocation_id=v_allocation.allocation_id and status='assigned';
  if not found then raise exception using errcode='P0001',message='stale_state'; end if;
  update app_private.assignments set work_state='completed',completed_at=pg_catalog.now()
  where assignment_id=v_assignment.assignment_id and work_state='submitted';
  if not found then raise exception using errcode='P0001',message='stale_state'; end if;
  v_event_id:=app_private.append_marketplace_event(p_actor,v_job.job_id,
    'job.assignment_completed',v_assignment.terms_version,
    pg_catalog.jsonb_build_object(
      'assignment_id',v_assignment.assignment_id,'terms_version',v_assignment.terms_version,
      'journal_id',v_journal_id));
  perform app_private.add_in_app_notification(v_event_id,v_assignment.worker_id,'assignment_completed');
  perform app_private.add_in_app_notification(v_event_id,v_assignment.poster_id,'assignment_completed');
  v_result:=app_private.assignment_command_projection(v_assignment.application_id,p_assignment_id);
  insert into app_private.financial_command_idempotency(
    actor_id,command_name,idempotency_key,request_sha256,response_reference_id,response_code
  ) values(p_actor,'confirm_completion',p_idempotency_key,v_hash,
    v_assignment.application_id,'assignment:'||p_assignment_id::text);
  return v_result;
end;
$function$;

create function app_private.case_participant_projection(p_case_id uuid,p_actor uuid)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_case app_private.assignment_cases%rowtype;
  v_assignment app_private.assignments%rowtype;
  v_timeline jsonb;
  v_total integer;
begin
  select * into v_case from app_private.assignment_cases where case_id=p_case_id for share;
  if not found then return null; end if;
  select * into v_assignment from app_private.assignments where assignment_id=v_case.assignment_id;
  if p_actor not in (v_assignment.worker_id,v_assignment.poster_id) then return null; end if;
  select count(*) into v_total from app_private.assignment_case_events
    where case_id=p_case_id and audience='participants';
  select coalesce(jsonb_agg(x.item order by x.sequence),'[]'::jsonb) into v_timeline
  from (
    select e.sequence,pg_catalog.jsonb_build_object(
      'event_type',e.event_type,'created_at',e.created_at,'details',e.payload
    ) as item
    from app_private.assignment_case_events e
    where e.case_id=p_case_id and e.audience='participants'
    order by e.sequence desc limit 100
  ) x;
  return pg_catalog.jsonb_build_object(
    'case_id',v_case.case_id,'assignment_id',v_case.assignment_id,
    'status',v_case.lifecycle_status,'version',v_case.version,
    'opened_at',v_case.opened_at,'updated_at',v_case.updated_at,
    'timeline',v_timeline,'timeline_truncated',v_total>100,
    'hold',app_private.assignment_hold_projection(v_case.hold_id,v_case.assignment_id)
  );
end;
$function$;

create function app_private.get_assignment_case_for_actor(p_actor uuid,p_case_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare v_result jsonb;
begin
  if p_actor is null or p_case_id is null then
    raise exception using errcode='22023',message='invalid_case_query';
  end if;
  v_result:=app_private.case_participant_projection(p_case_id,p_actor);
  if v_result is null then raise exception using errcode='P0002',message='case_not_found'; end if;
  return v_result;
end;
$function$;

create function app_private.lock_case_reviewer_scope(p_actor uuid,p_auth_aal text)
returns boolean language plpgsql security definer set search_path = '' as $function$
declare v_grant_id uuid;
begin
  if p_actor is null or p_auth_aal is distinct from 'aal2' then return false; end if;
  perform 1 from app_private.identity_accounts a
  where a.user_id=p_actor and a.account_status='active' for share;
  if not found then return false; end if;
  select g.grant_id into v_grant_id from app_private.staff_grants g
  where g.user_id=p_actor and g.capability='dispute_review' and g.revoked_at is null
  for share;
  return found;
end;
$function$;

create function app_private.list_assignment_case_queue_for_actor(
  p_actor uuid,p_auth_aal text,p_limit smallint
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_items jsonb;
  v_count integer;
begin
  if p_limit<>51 or not app_private.lock_case_reviewer_scope(p_actor,p_auth_aal) then
    raise exception using errcode='42501',message='case_access_denied';
  end if;
  with eligible as (
    select c.case_id,c.assignment_id,c.lifecycle_status,c.opened_at,h.reason_code,
      c.reviewer_id,greatest(0,
        floor(extract(epoch from pg_catalog.now()-c.opened_at)))::bigint as age_seconds
    from app_private.assignment_cases c
    join app_private.assignment_holds h on h.hold_id=c.hold_id
    join app_private.assignments a on a.assignment_id=c.assignment_id
    join app_private.principal_allocations p on p.allocation_id=c.allocation_id
    where c.lifecycle_status in ('open','under_review','contacting_other_party','verifying')
      and p.status='dispute_held'
      and (c.reviewer_id is null or c.reviewer_id=p_actor)
      and p_actor not in (a.worker_id,a.poster_id)
    order by c.opened_at,c.case_id
    limit p_limit
  ), page as (
    select * from eligible order by opened_at,case_id limit 50
  )
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'case_id',case_id,'assignment_id',assignment_id,'status',lifecycle_status,
    'opened_at',opened_at,'age_seconds',age_seconds::text,'reason_code',reason_code,
    'assigned_to_me',reviewer_id=p_actor
  ) order by opened_at,case_id),'[]'::jsonb),
    (select count(*)::integer from eligible)
  into v_items,v_count from page;
  insert into app_private.assignment_case_access_audit(case_id,actor_id,action)
  select (item->>'case_id')::uuid,p_actor,'case_queue_read'
  from pg_catalog.jsonb_array_elements(v_items) as q(item);
  return pg_catalog.jsonb_build_object('items',v_items,'truncated',v_count>50);
end;
$function$;

create function app_private.assign_case_reviewer_for_actor(
  p_actor uuid,p_case_id uuid,p_reviewer_id uuid,p_auth_aal text,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_case app_private.assignment_cases%rowtype;
  v_assignment app_private.assignments%rowtype;
  v_allocation app_private.principal_allocations%rowtype;
  v_target_status text;
  v_authority_user uuid;
  v_grant_id uuid;
  v_previous uuid;
  v_hash bytea;
  v_existing app_private.case_command_idempotency%rowtype;
  v_event uuid;
  v_result jsonb;
  v_action text;
  v_sequence integer;
begin
  if p_actor is null or p_case_id is null or p_reviewer_id is null or p_idempotency_key is null
     or p_auth_aal is distinct from 'aal2' then
    raise exception using errcode='42501',message='case_access_denied';
  end if;
  for v_authority_user in
    select distinct u.user_id from pg_catalog.unnest(array[p_actor,p_reviewer_id]) as u(user_id)
    order by u.user_id
  loop
    select a.account_status into v_target_status from app_private.identity_accounts a
    where a.user_id=v_authority_user for share;
    if not found or v_target_status<>'active' then
      raise exception using errcode='42501',message='case_access_denied';
    end if;
    select g.grant_id into v_grant_id from app_private.staff_grants g
    where g.user_id=v_authority_user and g.capability='dispute_review' and g.revoked_at is null
    for share;
    if not found then raise exception using errcode='42501',message='case_access_denied'; end if;
  end loop;
  v_hash:=extensions.digest(pg_catalog.jsonb_build_object(
    'case_id',p_case_id,'reviewer_id',p_reviewer_id)::text,'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    p_actor::text||':assign_case_reviewer:'||p_idempotency_key::text,428118));
  select * into v_existing from app_private.case_command_idempotency
  where actor_id=p_actor and command_name='assign_case_reviewer' and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.request_sha256<>v_hash then
      raise exception using errcode='23505',message='idempotency_conflict';
    end if;
    return v_existing.response;
  end if;
  select * into v_case from app_private.assignment_cases where case_id=p_case_id;
  if not found then raise exception using errcode='P0002',message='case_not_found'; end if;
  select * into v_assignment from app_private.assignments where assignment_id=v_case.assignment_id;
  if p_actor in (v_assignment.worker_id,v_assignment.poster_id)
     or p_reviewer_id in (v_assignment.worker_id,v_assignment.poster_id) then
    raise exception using errcode='42501',message='case_access_denied';
  end if;
  select * into v_allocation from app_private.principal_allocations
    where allocation_id=v_case.allocation_id for update;
  select * into v_assignment from app_private.assignments
    where assignment_id=v_case.assignment_id for update;
  select * into v_case from app_private.assignment_cases where case_id=p_case_id for update;
  if v_case.lifecycle_status not in ('open','under_review')
     or v_allocation.status<>'dispute_held' then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  v_previous:=v_case.reviewer_id;
  if v_previous is null then
    if p_actor<>p_reviewer_id then raise exception using errcode='42501',message='case_access_denied'; end if;
    v_action:='case_assigned';
  else
    if p_actor<>v_previous or v_previous=p_reviewer_id then
      raise exception using errcode='42501',message='case_access_denied';
    end if;
    v_action:='case_reassigned';
  end if;
  perform pg_catalog.set_config('app.assignment_case_transition','assign_reviewer',true);
  update app_private.assignment_cases set reviewer_id=p_reviewer_id,
    lifecycle_status='under_review',version=version+1
  where case_id=p_case_id;
  perform pg_catalog.set_config('app.assignment_case_transition','',true);
  select coalesce(max(sequence),0)+1 into v_sequence
  from app_private.assignment_case_events where case_id=p_case_id;
  insert into app_private.assignment_case_events(
    case_id,sequence,actor_id,audience,event_type,payload
  ) values(p_case_id,v_sequence,p_actor,'staff',
    case when v_previous is null then 'reviewer_assigned' else 'reviewer_reassigned' end,
    pg_catalog.jsonb_build_object('previous_reviewer_id',v_previous,'reviewer_id',p_reviewer_id));
  insert into app_private.assignment_case_events(
    case_id,sequence,actor_id,audience,event_type,payload
  ) values(p_case_id,v_sequence+1,p_actor,'participants',
    case when v_previous is null then 'reviewer_assigned' else 'reviewer_reassigned' end,
    pg_catalog.jsonb_build_object('status','under_review','update','A reviewer is looking into the case.'));
  insert into app_private.assignment_case_access_audit(
    case_id,actor_id,action,previous_reviewer_id,new_reviewer_id
  ) values(p_case_id,p_actor,v_action,v_previous,p_reviewer_id);
  v_event:=app_private.append_marketplace_event(p_actor,v_assignment.job_id,
    'job.assignment_case_reviewer_assigned',v_assignment.terms_version,
    pg_catalog.jsonb_build_object('assignment_id',v_assignment.assignment_id,'case_id',p_case_id,
      'status','under_review'));
  perform app_private.add_in_app_notification(v_event,v_assignment.worker_id,'assignment_case_updated');
  perform app_private.add_in_app_notification(v_event,v_assignment.poster_id,'assignment_case_updated');
  v_result:=pg_catalog.jsonb_build_object(
    'case_id',p_case_id,'status','under_review','version',v_case.version+1,
    'assigned',true);
  insert into app_private.case_command_idempotency(
    actor_id,command_name,idempotency_key,request_sha256,response
  ) values(p_actor,'assign_case_reviewer',p_idempotency_key,v_hash,v_result);
  return v_result;
end;
$function$;

create function app_private.get_assignment_case_for_reviewer(
  p_actor uuid,p_case_id uuid,p_auth_aal text
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_case app_private.assignment_cases%rowtype;
  v_assignment app_private.assignments%rowtype;
  v_terms jsonb;
  v_messages jsonb;
  v_message_count integer;
begin
  if p_case_id is null or not app_private.lock_case_reviewer_scope(p_actor,p_auth_aal) then
    raise exception using errcode='42501',message='case_access_denied';
  end if;
  select * into v_case from app_private.assignment_cases where case_id=p_case_id for share;
  if not found then raise exception using errcode='P0002',message='case_not_found'; end if;
  select * into v_assignment from app_private.assignments where assignment_id=v_case.assignment_id;
  if p_actor in (v_assignment.worker_id,v_assignment.poster_id) or v_case.reviewer_id<>p_actor then
    raise exception using errcode='42501',message='case_access_denied';
  end if;
  insert into app_private.assignment_case_access_audit(case_id,actor_id,action)
  values(p_case_id,p_actor,'case_read');
  select pg_catalog.jsonb_build_object(
    'job_id',t.job_id,'terms_version',t.terms_version,'title',t.title,
    'description',t.description,'category_slug',t.category_slug,
    'location_type',t.location_type,'location_detail',t.location_detail,
    'gross_per_worker_kobo',t.gross_per_worker_kobo::text,'slot_count',t.slot_count,
    'gross_total_kobo',t.gross_total_kobo::text,'application_deadline_at',t.application_deadline_at,
    'needed_by_at',t.needed_by_at,'start_requirements',t.start_requirements,
    'application_note',t.application_note,'terms_sha256',pg_catalog.encode(t.terms_sha256,'hex')
  ) into v_terms from app_private.job_terms_versions t
  where t.job_id=v_assignment.job_id and t.terms_version=v_case.terms_version
    and t.terms_sha256=v_case.terms_sha256;
  select count(*) into v_message_count from app_private.thread_messages m
  where m.thread_id=v_case.thread_id and m.sequence<=v_case.thread_through_sequence;
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'sequence',m.sequence::text,
    'sender_role',case when m.sender_id=v_assignment.worker_id then 'worker' else 'poster' end,
    'body',m.body,'created_at',m.created_at
  ) order by m.sequence),'[]'::jsonb) into v_messages
  from (select m.* from app_private.thread_messages m
    where m.thread_id=v_case.thread_id and m.sequence<=v_case.thread_through_sequence
    order by m.sequence desc limit 100) m;
  return pg_catalog.jsonb_build_object(
    'case_id',v_case.case_id,'assignment_id',v_case.assignment_id,
    'status',v_case.lifecycle_status,'version',v_case.version,
    'opened_at',v_case.opened_at,'updated_at',v_case.updated_at,
    'hold',app_private.assignment_hold_projection(v_case.hold_id,v_case.assignment_id),
    'terms_snapshot',v_terms,'conversation_snapshot',v_messages,
    'conversation_truncated',v_message_count>100
  );
end;
$function$;

create function public.server_open_assignment_hold_for_actor(
  p_actor uuid,p_assignment_id uuid,p_reason_code text,p_narrative text,
  p_desired_outcome text,p_follow_up text,p_idempotency_key uuid
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.open_assignment_case_for_actor(
    p_actor,p_assignment_id,p_reason_code,p_narrative,p_desired_outcome,p_follow_up,p_idempotency_key)
$function$;
create function public.server_get_assignment_case_for_actor(p_actor uuid,p_case_id uuid)
returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.get_assignment_case_for_actor(p_actor,p_case_id)
$function$;
create function public.server_list_assignment_case_queue_for_actor(
  p_actor uuid,p_auth_aal text,p_limit smallint
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.list_assignment_case_queue_for_actor(p_actor,p_auth_aal,p_limit)
$function$;
create function public.server_assign_case_reviewer_for_actor(
  p_actor uuid,p_case_id uuid,p_reviewer_id uuid,p_auth_aal text,p_idempotency_key uuid
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.assign_case_reviewer_for_actor(
    p_actor,p_case_id,p_reviewer_id,p_auth_aal,p_idempotency_key)
$function$;
create function public.server_get_assignment_case_for_reviewer(
  p_actor uuid,p_case_id uuid,p_auth_aal text
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.get_assignment_case_for_reviewer(p_actor,p_case_id,p_auth_aal)
$function$;

revoke all on table app_private.assignment_cases,app_private.assignment_case_events,
  app_private.assignment_case_access_audit,app_private.case_command_idempotency,
  app_private.case_file_policy from public,anon,authenticated,service_role;
revoke all on function app_private.reject_assignment_case_event_mutation(),
  app_private.guard_assignment_case_lifecycle(),
  app_private.open_assignment_case_for_actor(uuid,uuid,text,text,text,text,uuid),
  app_private.assign_case_reviewer_for_actor(uuid,uuid,uuid,text,uuid),
  app_private.get_assignment_case_for_actor(uuid,uuid),
  app_private.list_assignment_case_queue_for_actor(uuid,text,smallint),
  app_private.lock_case_reviewer_scope(uuid,text),
  app_private.get_assignment_case_for_reviewer(uuid,uuid,text),
  app_private.case_participant_projection(uuid,uuid),
  app_private.assignment_hold_projection(uuid,uuid),
  app_private.validate_assignment_allocation_pair(),
  app_private.get_assignment_status_for_actor(uuid,uuid),
  app_private.open_assignment_hold_for_actor(uuid,uuid,text,text,text,uuid)
  from public,anon,authenticated,service_role;
revoke all on function public.server_open_assignment_hold_for_actor(uuid,uuid,text,text,text,uuid),
  public.server_open_assignment_hold_for_actor(uuid,uuid,text,text,text,text,uuid),
  public.server_get_assignment_case_for_actor(uuid,uuid),
  public.server_list_assignment_case_queue_for_actor(uuid,text,smallint),
  public.server_assign_case_reviewer_for_actor(uuid,uuid,uuid,text,uuid),
  public.server_get_assignment_case_for_reviewer(uuid,uuid,text)
  from public,anon,authenticated,service_role;
grant execute on function public.server_open_assignment_hold_for_actor(uuid,uuid,text,text,text,uuid),
  public.server_open_assignment_hold_for_actor(uuid,uuid,text,text,text,text,uuid),
  public.server_get_assignment_case_for_actor(uuid,uuid),
  public.server_list_assignment_case_queue_for_actor(uuid,text,smallint),
  public.server_assign_case_reviewer_for_actor(uuid,uuid,uuid,text,uuid),
  public.server_get_assignment_case_for_reviewer(uuid,uuid,text)
  to service_role;

commit;
