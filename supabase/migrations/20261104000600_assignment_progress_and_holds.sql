begin;

-- Step 7 introduces participant-controlled work progress and a minimal,
-- unresolved hold. It deliberately adds no case resolution or payout route.
alter table app_private.assignments
  add column started_at timestamptz,
  add column submitted_at timestamptz,
  add column completed_at timestamptz,
  add constraint assignments_progress_timestamps_check check (
    (work_state='assigned' and started_at is null and submitted_at is null and completed_at is null) or
    (work_state='in_progress' and started_at is not null and submitted_at is null and completed_at is null) or
    (work_state='submitted' and started_at is not null and submitted_at is not null and completed_at is null) or
    (work_state='completed' and started_at is not null and submitted_at is not null and completed_at is not null) or
    work_state='cancelled'
  );
alter table app_private.marketplace_outbox
  drop constraint marketplace_outbox_event_type_check;
alter table app_private.marketplace_outbox
  add constraint marketplace_outbox_event_type_check check (event_type in (
    'job.draft_created','job.draft_updated','job.funding_started','job.funded',
    'job.funding_failed','job.funding_exception','job.application_created',
    'job.application_accepted','job.application_rejected','job.application_withdrawn',
    'job.application_closed','job.message_created','job.assignment_started',
    'job.assignment_submitted','job.assignment_completed','job.assignment_hold_opened'
  ));

alter table app_private.in_app_notifications
  drop constraint in_app_notifications_notification_type_check;
alter table app_private.in_app_notifications
  add constraint in_app_notifications_notification_type_check check (notification_type in (
    'application_received','application_accepted','application_rejected',
    'application_withdrawn','application_closed','new_message',
    'assignment_started','assignment_submitted','assignment_completed',
    'assignment_hold_opened'
  ));

alter table app_private.financial_audit_events
  drop constraint financial_audit_events_event_type_check;
alter table app_private.financial_audit_events
  add constraint financial_audit_events_event_type_check check (event_type in (
    'financial_journal_posted','financial_inspection',
    'assignment_completion_authorized','assignment_hold_opened'
  )),
  add constraint financial_audit_events_controlled_action_journal_check check (
    event_type not in ('assignment_completion_authorized','assignment_hold_opened')
    or journal_id is not null
  );

create table app_private.assignment_holds (
  hold_id uuid primary key default pg_catalog.gen_random_uuid(),
  assignment_id uuid not null references app_private.assignments(assignment_id) on delete restrict,
  allocation_id uuid not null references app_private.principal_allocations(allocation_id) on delete restrict,
  job_id uuid not null references app_private.jobs(job_id) on delete restrict,
  opened_by uuid not null references auth.users(id) on delete restrict,
  opened_by_role text not null check (opened_by_role in ('worker','poster')),
  prior_work_state text not null check (prior_work_state in ('assigned','in_progress','submitted')),
  reason_code text not null check (reason_code in (
    'payment_not_released','incomplete_work','work_not_as_described',
    'unresponsive_no_show','conduct_safety','other'
  )),
  narrative text not null check (char_length(narrative) between 1 and 2000),
  desired_outcome text not null check (char_length(desired_outcome) between 1 and 500),
  status text not null default 'open' check (status='open'),
  created_at timestamptz not null default pg_catalog.now(),
  unique(hold_id,assignment_id,allocation_id)
);
create unique index assignment_holds_one_active_per_allocation
  on app_private.assignment_holds(allocation_id) where status='open';
create index assignment_holds_assignment_history_idx
  on app_private.assignment_holds(assignment_id,created_at desc,hold_id desc);

create function app_private.reject_assignment_hold_mutation()
returns trigger language plpgsql set search_path = '' as $function$
begin
  raise exception using errcode='55000',message='assignment_hold_is_immutable';
end;
$function$;
create trigger assignment_holds_immutable before update or delete
on app_private.assignment_holds for each row
execute function app_private.reject_assignment_hold_mutation();

create table app_private.assignment_completion_authorizations (
  authorization_id uuid primary key default pg_catalog.gen_random_uuid(),
  assignment_id uuid not null unique references app_private.assignments(assignment_id) on delete restrict,
  allocation_id uuid not null unique references app_private.principal_allocations(allocation_id) on delete restrict,
  actor_id uuid not null references auth.users(id) on delete restrict,
  terms_version integer not null check (terms_version>0),
  terms_sha256 bytea not null check (pg_catalog.octet_length(terms_sha256)=32),
  gross_principal_kobo bigint not null check (gross_principal_kobo>0),
  commission_kobo bigint not null check (commission_kobo>=0),
  worker_net_kobo bigint not null check (worker_net_kobo>0),
  journal_id uuid not null unique references app_private.ledger_journal_transactions(journal_id) on delete restrict,
  idempotency_key uuid not null,
  created_at timestamptz not null default pg_catalog.now(),
  check (gross_principal_kobo::numeric=commission_kobo::numeric+worker_net_kobo::numeric)
);

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
            and not exists(select 1 from app_private.assignment_holds h
              where h.allocation_id=new.allocation_id and h.status='open')) or
          (new.status='dispute_held' and a.work_state in ('assigned','in_progress','submitted')
            and exists(select 1 from app_private.assignment_holds h
              where h.assignment_id=a.assignment_id and h.allocation_id=new.allocation_id
                and h.status='open')) or
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
          and not exists(select 1 from app_private.assignment_holds h
            where h.allocation_id=p.allocation_id and h.status='open')) or
        (p.status='dispute_held' and new.work_state in ('assigned','in_progress','submitted')
          and exists(select 1 from app_private.assignment_holds h
            where h.assignment_id=new.assignment_id and h.allocation_id=p.allocation_id
              and h.status='open')) or
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

create function app_private.reject_completion_authorization_mutation()
returns trigger language plpgsql set search_path = '' as $function$
begin
  raise exception using errcode='55000',message='assignment_authorization_is_immutable';
end;
$function$;
create trigger assignment_completion_authorizations_immutable before update or delete
on app_private.assignment_completion_authorizations for each row
execute function app_private.reject_completion_authorization_mutation();

drop trigger assignments_immutable on app_private.assignments;
create or replace function app_private.reject_assignment_mutation()
returns trigger language plpgsql set search_path = '' as $function$
begin
  if tg_op='DELETE' then
    raise exception using errcode='55000',message='assignment_record_is_immutable';
  end if;
  if new.assignment_id is distinct from old.assignment_id
     or new.application_id is distinct from old.application_id
     or new.job_id is distinct from old.job_id
     or new.worker_id is distinct from old.worker_id
     or new.poster_id is distinct from old.poster_id
     or new.allocation_id is distinct from old.allocation_id
     or new.funding_intent_id is distinct from old.funding_intent_id
     or new.terms_version is distinct from old.terms_version
     or new.terms_sha256 is distinct from old.terms_sha256
     or new.gross_principal_kobo is distinct from old.gross_principal_kobo
     or new.commission_basis_points is distinct from old.commission_basis_points
     or new.created_at is distinct from old.created_at
     or not (
       (old.work_state='assigned' and new.work_state='in_progress'
         and old.started_at is null and new.started_at is not null
         and new.submitted_at is null and new.completed_at is null) or
       (old.work_state='in_progress' and new.work_state='submitted'
         and new.started_at=old.started_at and old.submitted_at is null
         and new.submitted_at is not null and new.completed_at is null) or
       (old.work_state='submitted' and new.work_state='completed'
         and new.started_at=old.started_at and new.submitted_at=old.submitted_at
         and old.completed_at is null and new.completed_at is not null)
     ) then
    raise exception using errcode='55000',message='assignment_record_is_immutable';
  end if;
  return new;
end;
$function$;
create trigger assignments_guard_progress before update or delete on app_private.assignments
for each row execute function app_private.reject_assignment_mutation();

create function app_private.stable_financial_effect_key(p_label text)
returns uuid language sql immutable strict set search_path = '' as $function$
  select (pg_catalog.substr(pg_catalog.md5(p_label),1,8)||'-'||
    pg_catalog.substr(pg_catalog.md5(p_label),9,4)||'-'||
    pg_catalog.substr(pg_catalog.md5(p_label),13,4)||'-'||
    pg_catalog.substr(pg_catalog.md5(p_label),17,4)||'-'||
    pg_catalog.substr(pg_catalog.md5(p_label),21,12))::uuid
$function$;

create function app_private.post_allocation_status_journal(
  p_allocation_id uuid,p_from_status text,p_to_status text
) returns uuid language plpgsql security definer set search_path = '' as $function$
declare
  v_allocation app_private.principal_allocations%rowtype;
  v_actor uuid;
  v_effect_type text;
  v_debit_account text;
  v_credit_account text;
begin
  if not ((p_from_status='unassigned' and p_to_status='assigned') or
          (p_from_status='assigned' and p_to_status='dispute_held')) then
    raise exception using errcode='22023',message='invalid_allocation_transition';
  end if;
  select * into v_allocation from app_private.principal_allocations
  where allocation_id=p_allocation_id;
  if not found then raise exception using errcode='22023',message='invalid_allocation_transition'; end if;
  select poster_id into v_actor from app_private.assignments
  where assignment_id=v_allocation.assignment_id and allocation_id=p_allocation_id;
  if not found then raise exception using errcode='22023',message='invalid_allocation_transition'; end if;
  v_effect_type:=case when p_to_status='assigned' then 'allocation_assigned' else 'allocation_held' end;
  v_debit_account:=case when p_to_status='assigned'
    then 'job_principal_unassigned' else 'job_principal_assigned' end;
  v_credit_account:=case when p_to_status='assigned'
    then 'job_principal_assigned' else 'job_principal_dispute_held' end;
  return app_private.post_financial_journal(
    app_private.stable_financial_effect_key('nbd:'||v_effect_type||':'||p_allocation_id::text),
    v_effect_type,p_allocation_id,v_actor,pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('account_code',v_debit_account,'direction','debit',
        'amount_kobo',v_allocation.gross_principal_kobo::text,'allocation_id',p_allocation_id::text),
      pg_catalog.jsonb_build_object('account_code',v_credit_account,'direction','credit',
        'amount_kobo',v_allocation.gross_principal_kobo::text,'allocation_id',p_allocation_id::text)
    )
  );
end;
$function$;

create function app_private.journal_allocation_status_transition()
returns trigger language plpgsql security definer set search_path = '' as $function$
begin
  perform app_private.post_allocation_status_journal(new.allocation_id,old.status,new.status);
  return new;
end;
$function$;
create trigger principal_allocations_accounting_transition
after update of status on app_private.principal_allocations
for each row when (old.status is distinct from new.status and
  ((old.status='unassigned' and new.status='assigned') or
   (old.status='assigned' and new.status='dispute_held')))
execute function app_private.journal_allocation_status_transition();

-- Step 6 assigned a funded slot without changing the ledger category. Reclassify
-- those existing reservations once, by appending journals, never editing history.
do $backfill$
declare v_allocation record;
begin
  for v_allocation in
    select p.allocation_id,p.status
    from app_private.principal_allocations p
    where p.status in ('assigned','dispute_held')
    order by p.allocation_id
  loop
    if not exists(select 1 from app_private.ledger_journal_transactions j
       where j.effect_key=app_private.stable_financial_effect_key(
         'nbd:allocation_assigned:'||v_allocation.allocation_id::text)) then
      perform app_private.post_allocation_status_journal(
        v_allocation.allocation_id,'unassigned','assigned');
    end if;
    if v_allocation.status='dispute_held' and not exists(
       select 1 from app_private.ledger_journal_transactions j
       where j.effect_key=app_private.stable_financial_effect_key(
         'nbd:allocation_held:'||v_allocation.allocation_id::text)) then
      perform app_private.post_allocation_status_journal(
        v_allocation.allocation_id,'assigned','dispute_held');
    end if;
  end loop;
end;
$backfill$;

create or replace function app_private.assignment_command_projection(
  p_application_id uuid,p_assignment_id uuid
) returns jsonb language sql stable security definer set search_path = '' as $function$
  select pg_catalog.jsonb_build_object(
    'assignment_id',s.assignment_id,
    'application_id',s.application_id,
    'thread_id',t.thread_id,
    'job_id',s.job_id,
    'assignment_state',s.work_state,
    'started_at',s.started_at,
    'submitted_at',s.submitted_at,
    'completed_at',s.completed_at,
    'hold_status',case when p.status='dispute_held' then 'open' else null end,
    'earnings_status',case
      when p.status='dispute_held' then 'on_hold'
      when p.status='worker_earnings_allocated' then 'available'
      else 'not_released' end,
    'terms_version',s.terms_version,
    'gross_principal_kobo',s.gross_principal_kobo::text,
    'commission_kobo',app_private.calculate_commission_kobo(s.gross_principal_kobo)::text,
    'worker_net_kobo',(s.gross_principal_kobo-
      app_private.calculate_commission_kobo(s.gross_principal_kobo))::text,
    'commission_basis_points',s.commission_basis_points
  )
  from app_private.assignments s
  join app_private.application_threads t using(application_id)
  join app_private.principal_allocations p on p.allocation_id=s.allocation_id
  where s.application_id=p_application_id and s.assignment_id=p_assignment_id
$function$;

create function app_private.assignment_hold_projection(p_hold_id uuid,p_assignment_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $function$
  select pg_catalog.jsonb_build_object(
    'hold_id',h.hold_id,'status',h.status,
    'prior_assignment_state',h.prior_work_state,
    'reason_code',h.reason_code,'narrative',h.narrative,
    'desired_outcome',h.desired_outcome,'opened_at',h.created_at
  )
  from app_private.assignment_holds h
  where h.hold_id=p_hold_id and h.assignment_id=p_assignment_id
$function$;

create function app_private.start_assignment_for_actor(
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
  v_event_id uuid;
  v_result jsonb;
begin
  if p_actor is null or p_assignment_id is null or p_idempotency_key is null then
    raise exception using errcode='22023',message='invalid_assignment_request';
  end if;
  select * into v_assignment from app_private.assignments where assignment_id=p_assignment_id;
  if not found or v_assignment.worker_id<>p_actor then
    raise exception using errcode='P0002',message='assignment_not_found';
  end if;
  v_caps:=app_private.current_profile_capabilities(p_actor);
  if not ('can_work'=any(v_caps)) then
    raise exception using errcode='42501',message='verification_required';
  end if;
  v_hash:=extensions.digest(pg_catalog.jsonb_build_object('assignment_id',p_assignment_id)::text,'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    p_actor::text||':start_assignment:'||p_idempotency_key::text,428118));
  select * into v_existing from app_private.financial_command_idempotency
  where actor_id=p_actor and command_name='start_assignment' and idempotency_key=p_idempotency_key;

  select * into v_allocation from app_private.principal_allocations
  where allocation_id=v_assignment.allocation_id for update;
  select * into v_assignment from app_private.assignments
  where assignment_id=p_assignment_id for update;
  v_caps:=app_private.current_profile_capabilities(p_actor);
  if not ('can_work'=any(v_caps)) then
    raise exception using errcode='42501',message='verification_required';
  end if;
  if v_assignment.worker_id<>p_actor then
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
    and terms_sha256=v_assignment.terms_sha256
    and currency='NGN';
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
  if v_allocation.status<>'assigned' or v_assignment.work_state<>'assigned' then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  update app_private.assignments set work_state='in_progress',started_at=pg_catalog.now()
  where assignment_id=p_assignment_id;
  v_event_id:=app_private.append_marketplace_event(p_actor,v_job.job_id,
    'job.assignment_started',v_assignment.terms_version,
    pg_catalog.jsonb_build_object('assignment_id',p_assignment_id));
  perform app_private.add_in_app_notification(v_event_id,v_assignment.poster_id,'assignment_started');
  v_result:=app_private.assignment_command_projection(v_assignment.application_id,p_assignment_id);
  insert into app_private.financial_command_idempotency(
    actor_id,command_name,idempotency_key,request_sha256,response_reference_id,response_code
  ) values(p_actor,'start_assignment',p_idempotency_key,v_hash,
    v_assignment.application_id,'assignment:'||p_assignment_id::text);
  return v_result;
end;
$function$;

create function app_private.submit_assignment_for_actor(
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
  v_event_id uuid;
  v_result jsonb;
begin
  if p_actor is null or p_assignment_id is null or p_idempotency_key is null then
    raise exception using errcode='22023',message='invalid_assignment_request';
  end if;
  select * into v_assignment from app_private.assignments where assignment_id=p_assignment_id;
  if not found or v_assignment.worker_id<>p_actor then
    raise exception using errcode='P0002',message='assignment_not_found';
  end if;
  v_caps:=app_private.current_profile_capabilities(p_actor);
  if not ('can_work'=any(v_caps)) then
    raise exception using errcode='42501',message='verification_required';
  end if;
  v_hash:=extensions.digest(pg_catalog.jsonb_build_object('assignment_id',p_assignment_id)::text,'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    p_actor::text||':submit_assignment:'||p_idempotency_key::text,428118));
  select * into v_existing from app_private.financial_command_idempotency
  where actor_id=p_actor and command_name='submit_assignment' and idempotency_key=p_idempotency_key;
  select * into v_allocation from app_private.principal_allocations
  where allocation_id=v_assignment.allocation_id for update;
  select * into v_assignment from app_private.assignments
  where assignment_id=p_assignment_id for update;
  v_caps:=app_private.current_profile_capabilities(p_actor);
  if not ('can_work'=any(v_caps)) then
    raise exception using errcode='42501',message='verification_required';
  end if;
  if v_assignment.worker_id<>p_actor then
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
  if v_allocation.status<>'assigned' or v_assignment.work_state<>'in_progress' then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  update app_private.assignments set work_state='submitted',submitted_at=pg_catalog.now()
  where assignment_id=p_assignment_id;
  v_event_id:=app_private.append_marketplace_event(p_actor,v_job.job_id,
    'job.assignment_submitted',v_assignment.terms_version,
    pg_catalog.jsonb_build_object('assignment_id',p_assignment_id));
  perform app_private.add_in_app_notification(v_event_id,v_assignment.poster_id,'assignment_submitted');
  v_result:=app_private.assignment_command_projection(v_assignment.application_id,p_assignment_id);
  insert into app_private.financial_command_idempotency(
    actor_id,command_name,idempotency_key,request_sha256,response_reference_id,response_code
  ) values(p_actor,'submit_assignment',p_idempotency_key,v_hash,
    v_assignment.application_id,'assignment:'||p_assignment_id::text);
  return v_result;
end;
$function$;

create function app_private.confirm_completion_for_actor(
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
  if exists(select 1 from app_private.assignment_holds h
       where h.allocation_id=v_allocation.allocation_id and h.status='open') then
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

create function app_private.open_assignment_hold_for_actor(
  p_actor uuid,p_assignment_id uuid,p_reason_code text,p_narrative text,
  p_desired_outcome text,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_caps text[];
  v_assignment app_private.assignments%rowtype;
  v_allocation app_private.principal_allocations%rowtype;
  v_job app_private.jobs%rowtype;
  v_funding app_private.funding_intents%rowtype;
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
  if char_length(p_narrative) not between 1 and 2000
     or char_length(p_desired_outcome) not between 1 and 500
     or p_reason_code not in ('payment_not_released','incomplete_work','work_not_as_described',
       'unresponsive_no_show','conduct_safety','other') then
    raise exception using errcode='22023',message='invalid_assignment_hold';
  end if;
  select * into v_assignment from app_private.assignments where assignment_id=p_assignment_id;
  if not found or p_actor not in (v_assignment.worker_id,v_assignment.poster_id) then
    raise exception using errcode='P0002',message='assignment_not_found';
  end if;
  v_role:=case when p_actor=v_assignment.worker_id then 'worker' else 'poster' end;
  v_caps:=app_private.current_profile_capabilities(p_actor);
  if (v_role='worker' and not ('can_work'=any(v_caps))) or
     (v_role='poster' and not ('can_hire'=any(v_caps))) then
    raise exception using errcode='42501',message='verification_required';
  end if;
  v_hash:=extensions.digest(pg_catalog.jsonb_build_object(
    'assignment_id',p_assignment_id,'reason_code',p_reason_code,
    'narrative',p_narrative,'desired_outcome',p_desired_outcome)::text,'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    p_actor::text||':open_assignment_hold:'||p_idempotency_key::text,428118));
  select * into v_existing from app_private.financial_command_idempotency
  where actor_id=p_actor and command_name='open_assignment_hold' and idempotency_key=p_idempotency_key;
  select * into v_allocation from app_private.principal_allocations
  where allocation_id=v_assignment.allocation_id for update;
  select * into v_assignment from app_private.assignments
  where assignment_id=p_assignment_id for update;
  v_caps:=app_private.current_profile_capabilities(p_actor);
  if (v_role='worker' and not ('can_work'=any(v_caps))) or
     (v_role='poster' and not ('can_hire'=any(v_caps))) then
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
  insert into app_private.assignment_holds(
    hold_id,assignment_id,allocation_id,job_id,opened_by,opened_by_role,
    prior_work_state,reason_code,narrative,desired_outcome
  ) values(v_hold_id,v_assignment.assignment_id,v_allocation.allocation_id,
    v_assignment.job_id,p_actor,v_role,v_assignment.work_state,p_reason_code,
    p_narrative,p_desired_outcome);
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

create function app_private.get_assignment_status_for_actor(p_actor uuid,p_assignment_id uuid)
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
  select hold_id into v_hold_id from app_private.assignment_holds
  where assignment_id=p_assignment_id and status='open';
  return pg_catalog.jsonb_build_object(
    'assignment',app_private.assignment_command_projection(
      v_assignment.application_id,v_assignment.assignment_id),
    'hold',case when v_hold_id is null then null
      else app_private.assignment_hold_projection(v_hold_id,p_assignment_id) end
  );
end;
$function$;

create function public.server_start_assignment_for_actor(
  p_actor uuid,p_assignment_id uuid,p_idempotency_key uuid
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.start_assignment_for_actor(p_actor,p_assignment_id,p_idempotency_key)
$function$;
create function public.server_submit_assignment_for_actor(
  p_actor uuid,p_assignment_id uuid,p_idempotency_key uuid
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.submit_assignment_for_actor(p_actor,p_assignment_id,p_idempotency_key)
$function$;
create function public.server_confirm_completion_for_actor(
  p_actor uuid,p_assignment_id uuid,p_idempotency_key uuid
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.confirm_completion_for_actor(p_actor,p_assignment_id,p_idempotency_key)
$function$;
create function public.server_open_assignment_hold_for_actor(
  p_actor uuid,p_assignment_id uuid,p_reason_code text,p_narrative text,
  p_desired_outcome text,p_idempotency_key uuid
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.open_assignment_hold_for_actor(
    p_actor,p_assignment_id,p_reason_code,p_narrative,p_desired_outcome,p_idempotency_key)
$function$;
create function public.server_get_assignment_status_for_actor(p_actor uuid,p_assignment_id uuid)
returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.get_assignment_status_for_actor(p_actor,p_assignment_id)
$function$;

create or replace function app_private.get_safe_profile_for_viewer(p_viewer uuid,p_subject uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $function$
declare
  v_type text;
  v_caps text[];
  v_profile jsonb;
begin
  if p_viewer is null or p_subject is null
    or pg_catalog.cardinality(app_private.current_profile_capabilities(p_viewer))=0 then
    raise exception using errcode='P0002',message='profile_not_found';
  end if;
  v_caps:=app_private.current_profile_capabilities(p_subject);
  if pg_catalog.cardinality(v_caps)=0 then
    raise exception using errcode='P0002',message='profile_not_found';
  end if;
  select ia.account_type,pg_catalog.jsonb_build_object(
    'profile_id',p.user_id,'account_type',ia.account_type,'verified_badge',true,
    'display_name',p.display_name,'photo_key',p.photo_key,'faculty_label',p.faculty_label,
    'campus_label',p.campus_label,'bio',p.bio,'skills',pg_catalog.to_jsonb(p.skills),
    'availability',p.availability,'business_name',p.business_name,
    'business_location',p.business_location,'organisation_label',p.organisation_label,
    'worker_rating',null,'worker_review_count',0,'poster_rating',null,'poster_review_count',0,
    'completed_work_count',(select count(*)::integer from app_private.assignments s
      where s.worker_id=p.user_id and s.work_state='completed')
  ) into v_type,v_profile
  from public.profiles p
  join app_private.identity_accounts ia on ia.user_id=p.user_id
  where p.user_id=p_subject and ia.account_status='active';
  if v_profile is null then raise exception using errcode='P0002',message='profile_not_found'; end if;
  return v_profile;
end;
$function$;

revoke all on table app_private.assignment_holds,app_private.assignment_completion_authorizations
  from public,anon,authenticated,service_role;
revoke all on function app_private.reject_assignment_hold_mutation(),
  app_private.reject_completion_authorization_mutation(),
  app_private.validate_assignment_allocation_pair(),
  app_private.stable_financial_effect_key(text),
  app_private.post_allocation_status_journal(uuid,text,text),
  app_private.journal_allocation_status_transition(),
  app_private.assignment_command_projection(uuid,uuid),
  app_private.assignment_hold_projection(uuid,uuid),
  app_private.start_assignment_for_actor(uuid,uuid,uuid),
  app_private.submit_assignment_for_actor(uuid,uuid,uuid),
  app_private.confirm_completion_for_actor(uuid,uuid,uuid),
  app_private.open_assignment_hold_for_actor(uuid,uuid,text,text,text,uuid),
  app_private.get_assignment_status_for_actor(uuid,uuid)
  from public,anon,authenticated,service_role;
revoke all on function public.server_start_assignment_for_actor(uuid,uuid,uuid),
  public.server_submit_assignment_for_actor(uuid,uuid,uuid),
  public.server_confirm_completion_for_actor(uuid,uuid,uuid),
  public.server_open_assignment_hold_for_actor(uuid,uuid,text,text,text,uuid),
  public.server_get_assignment_status_for_actor(uuid,uuid)
  from public,anon,authenticated,service_role;
grant execute on function public.server_start_assignment_for_actor(uuid,uuid,uuid),
  public.server_submit_assignment_for_actor(uuid,uuid,uuid),
  public.server_confirm_completion_for_actor(uuid,uuid,uuid),
  public.server_open_assignment_hold_for_actor(uuid,uuid,text,text,text,uuid),
  public.server_get_assignment_status_for_actor(uuid,uuid)
  to service_role;

commit;
