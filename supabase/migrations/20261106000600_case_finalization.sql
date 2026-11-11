begin;

-- Step 7 is a manual, service-gateway-only action. The private timestamp
-- argument is available to database fixtures; the public RPC always supplies
-- server time and exposes no clock override.
alter table app_private.case_command_idempotency
  drop constraint case_command_idempotency_command_name_check,
  add constraint case_command_idempotency_command_name_check check (command_name in (
    'assign_case_reviewer','triage_case','log_case_contact_attempt',
    'request_case_information','respond_to_case_information','record_case_fact',
    'add_case_internal_note','assess_case_nonresponse','signoff_case_nonresponse',
    'begin_case_file_upload','propose_case_decision','approve_case_decision',
    'signoff_decision_nonresponse','record_case_appeal_receipt',
    'process_case_appeal_receipt','assign_case_appeal_reviewer',
    'request_case_appeal_evidence','respond_case_appeal_evidence',
    'close_case_appeal_evidence_nonresponse','review_case_appeal',
    'finalize_case'
  ));

alter table app_private.assignment_case_events
  drop constraint assignment_case_events_event_type_check,
  add constraint assignment_case_events_event_type_check check (event_type in (
    'case_opened','reviewer_assigned','reviewer_reassigned','status_changed',
    'participant_response','evidence_added','decision_notified','appeal_opened',
    'case_closed','case_triaged','contact_attempt_recorded','information_requested',
    'fact_verification_recorded','nonresponse_assessed','case_decision_proposed',
    'case_decision_approved','case_decision_nonresponse_signed',
    'appeal_reviewer_assigned','appeal_decision_recorded'
  ));

alter table app_private.assignment_case_access_audit
  drop constraint assignment_case_access_audit_action_check,
  add constraint assignment_case_access_audit_action_check check (action in (
    'case_read','case_queue_read','case_assigned','case_reassigned',
    'case_triaged','case_contact_logged','case_information_requested',
    'case_participant_responded','case_fact_recorded','case_internal_note_added',
    'case_nonresponse_assessed','case_nonresponse_signed_off',
    'case_decision_proposed','case_decision_approved',
    'case_decision_nonresponse_signed','case_appeal_received',
    'case_appeal_reviewer_assigned','case_appeal_evidence_requested',
    'case_appeal_evidence_closed','case_appeal_evidence_responded',
    'case_appeal_review_decided','case_finalization_executed'
  ));

alter table app_private.marketplace_outbox
  drop constraint marketplace_outbox_event_type_check,
  add constraint marketplace_outbox_event_type_check check (event_type in (
    'job.draft_created','job.draft_updated','job.funding_started','job.funded',
    'job.funding_failed','job.funding_exception','job.application_created',
    'job.application_accepted','job.application_rejected','job.application_withdrawn',
    'job.application_closed','job.message_created','job.assignment_started',
    'job.assignment_submitted','job.assignment_completed','job.assignment_hold_opened',
    'job.slot_refund_authorized','job.assignment_cancellation_requested',
    'job.assignment_cancellation_completed','job.assignment_abandoned',
    'job.assignment_case_reviewer_assigned','job.assignment_case_investigation_updated',
    'job.assignment_case_decision_notified','job.assignment_case_updated',
    'job.assignment_case_finalized'
  ));
alter table app_private.in_app_notifications
  drop constraint in_app_notifications_notification_type_check,
  add constraint in_app_notifications_notification_type_check check (notification_type in (
    'application_received','application_accepted','application_rejected',
    'application_withdrawn','application_closed','new_message',
    'assignment_started','assignment_submitted','assignment_completed',
    'assignment_hold_opened','assignment_case_updated','assignment_case_decision',
    'withdrawal_requested','withdrawal_processing','withdrawal_unknown','withdrawal_paid',
    'withdrawal_failed','withdrawal_reversed','withdrawal_exception',
    'slot_refund_authorized','assignment_cancellation_requested',
    'assignment_cancellation_completed','assignment_abandoned',
    'assignment_case_finalized'
  ));

alter table app_private.ledger_journal_transactions
  drop constraint ledger_journal_transactions_effect_type_check,
  add constraint ledger_journal_transactions_effect_type_check check (effect_type in (
    'funding_collected','provider_settlement','allocation_assigned','allocation_held',
    'completion_released','withdrawal_reserved','payout_settled','platform_fee_reserve_transfer',
    'provider_refund_settled','compensating_correction','platform_capital_contribution',
    'allocation_reopened','allocation_refund_authorized','case_outcome_finalized',
    'case_hold_restored'
  ));

alter table app_private.financial_audit_events
  drop constraint financial_audit_events_event_type_check,
  add constraint financial_audit_events_event_type_check check (event_type in (
    'financial_journal_posted','financial_inspection','wallet_destination_changed',
    'withdrawal_requested','withdrawal_status_changed','financial_authorization_created',
    'provider_operation_authorized','provider_operation_status_changed',
    'financial_reconciliation_completed',
    'assignment_completion_authorized','assignment_hold_opened',
    'case_finalization_executed'
  )),
  drop constraint financial_audit_events_controlled_action_journal_check,
  add constraint financial_audit_events_controlled_action_journal_check check (
    event_type not in (
      'assignment_completion_authorized','assignment_hold_opened','case_finalization_executed'
    ) or journal_id is not null
  );

-- The ledger journal function has a fixed effect allow-list. Patch only that
-- list and fail closed if its approved definition has changed unexpectedly.
do $migration$
declare v_definition text; v_old text; v_new text;
begin
  v_old:='''allocation_reopened'',''allocation_refund_authorized''';
  v_new:='''allocation_reopened'',''allocation_refund_authorized'',''case_outcome_finalized'',''case_hold_restored''';
  v_definition:=pg_catalog.pg_get_functiondef(
    'app_private.post_financial_journal(uuid,text,uuid,uuid,jsonb)'::regprocedure);
  if pg_catalog.strpos(v_definition,v_old)=0 then
    raise exception 'case_finalization_journal_allowlist_patch_mismatch';
  end if;
  execute pg_catalog.replace(v_definition,v_old,v_new);
end;
$migration$;

-- Case decision refunds remain authorized obligations. Settlement/progress is
-- a later step and cannot be inferred from this immutable row.
alter table app_private.allocation_refund_payables
  add column case_id uuid references app_private.assignment_cases(case_id) on delete restrict,
  add column decision_id uuid references app_private.assignment_case_decision_versions(decision_id) on delete restrict,
  drop constraint allocation_refund_payables_source_check,
  add constraint allocation_refund_payables_source_check check (
    source in ('unassigned_slot','mutual_prestart','case_decision')
  ),
  drop constraint allocation_refund_payables_check,
  add constraint allocation_refund_payables_check check (
    (source='unassigned_slot' and source_assignment_id is null and cancellation_id is null
      and case_id is null and decision_id is null) or
    (source='mutual_prestart' and source_assignment_id is not null and cancellation_id is not null
      and case_id is null and decision_id is null) or
    (source='case_decision' and source_assignment_id is not null and cancellation_id is null
      and case_id is not null and decision_id is not null)
  );

alter table app_private.allocation_assignment_bindings
  drop constraint allocation_assignment_bindings_unbound_reason_check,
  add constraint allocation_assignment_bindings_unbound_reason_check check (
    unbound_reason is null or unbound_reason in (
      'worker_abandonment','mutual_prestart_cancellation','case_finalized_refund'
    )
  );

create or replace function app_private.guard_allocation_assignment_binding()
returns trigger language plpgsql set search_path = '' as $function$
declare v_reason text;
begin
  if tg_op='DELETE' then
    raise exception using errcode='55000',message='allocation_assignment_history_is_immutable';
  end if;
  if tg_op='INSERT' then
    if new.unbound_at is not null or new.unbound_by is not null or new.unbound_reason is not null then
      raise exception using errcode='55000',message='invalid_allocation_assignment_binding';
    end if;
    return new;
  end if;
  v_reason:=pg_catalog.current_setting('app.assignment_unbind_reason',true);
  if new.assignment_id is distinct from old.assignment_id
     or new.allocation_id is distinct from old.allocation_id
     or new.bound_by is distinct from old.bound_by
     or new.bound_at is distinct from old.bound_at
     or old.unbound_at is not null
     or new.unbound_at is null or new.unbound_by is null
     or coalesce(v_reason,'') not in (
       'worker_abandonment','mutual_prestart_cancellation','case_finalized_refund'
     ) or new.unbound_reason is distinct from v_reason then
    raise exception using errcode='55000',message='allocation_assignment_history_is_immutable';
  end if;
  return new;
end;
$function$;

create or replace function app_private.record_allocation_assignment_binding()
returns trigger language plpgsql security definer set search_path = '' as $function$
declare v_actor uuid; v_reason text;
begin
  if old.assignment_id is null and new.assignment_id is not null then
    v_actor:=nullif(pg_catalog.current_setting('app.allocation_actor',true),'')::uuid;
    insert into app_private.allocation_assignment_bindings(assignment_id,allocation_id,bound_by)
    values(new.assignment_id,new.allocation_id,coalesce(v_actor,new.poster_id));
  elsif old.assignment_id is not null and new.assignment_id is null then
    v_actor:=nullif(pg_catalog.current_setting('app.allocation_actor',true),'')::uuid;
    v_reason:=pg_catalog.current_setting('app.assignment_unbind_reason',true);
    if coalesce(v_reason,'') not in (
      'worker_abandonment','mutual_prestart_cancellation','case_finalized_refund'
    ) or v_actor is null then
      raise exception using errcode='55000',message='allocation_assignment_history_is_immutable';
    end if;
    update app_private.allocation_assignment_bindings
    set unbound_at=pg_catalog.clock_timestamp(),unbound_by=v_actor,unbound_reason=v_reason
    where assignment_id=old.assignment_id and allocation_id=old.allocation_id and unbound_at is null;
    if not found then
      raise exception using errcode='55000',message='allocation_assignment_history_is_immutable';
    end if;
  end if;
  return new;
end;
$function$;

create table app_private.assignment_case_finalizations (
  finalization_id uuid primary key default pg_catalog.gen_random_uuid(),
  case_id uuid not null unique references app_private.assignment_cases(case_id) on delete restrict,
  decision_id uuid not null unique,
  decision_version integer not null check (decision_version>0),
  decision_sha256 bytea not null check (pg_catalog.octet_length(decision_sha256)=32),
  assignment_id uuid not null references app_private.assignments(assignment_id) on delete restrict,
  allocation_id uuid not null references app_private.principal_allocations(allocation_id) on delete restrict,
  expected_case_version integer not null check (expected_case_version>0),
  prior_work_state text not null check (prior_work_state in ('assigned','in_progress','submitted')),
  outcome text not null check (outcome in (
    'full_worker_award','full_poster_refund','split','no_action'
  )),
  gross_principal_kobo bigint not null check (gross_principal_kobo>0),
  worker_award_gross_kobo bigint not null check (worker_award_gross_kobo>=0),
  poster_refund_gross_kobo bigint not null check (poster_refund_gross_kobo>=0),
  retained_hold_gross_kobo bigint not null check (retained_hold_gross_kobo>=0),
  commission_kobo bigint not null check (commission_kobo>=0),
  worker_net_kobo bigint not null check (worker_net_kobo>=0),
  approval_one_id uuid not null references app_private.assignment_case_decision_approvals(approval_id) on delete restrict,
  approval_two_id uuid not null references app_private.assignment_case_decision_approvals(approval_id) on delete restrict,
  nonresponse_signoff_id uuid references app_private.assignment_case_decision_nonresponse_signoffs(signoff_id) on delete restrict,
  finalized_by uuid not null references auth.users(id) on delete restrict,
  finalizer_dispute_grant_id uuid not null references app_private.staff_grants(grant_id) on delete restrict,
  finalizer_initiate_grant_id uuid not null references app_private.staff_grants(grant_id) on delete restrict,
  award_journal_id uuid unique references app_private.ledger_journal_transactions(journal_id) on delete restrict,
  refund_payable_id uuid unique references app_private.allocation_refund_payables(refund_payable_id) on delete restrict,
  refund_journal_id uuid unique references app_private.ledger_journal_transactions(journal_id) on delete restrict,
  hold_restore_journal_id uuid unique references app_private.ledger_journal_transactions(journal_id) on delete restrict,
  idempotency_key uuid not null,
  executed_at timestamptz not null default pg_catalog.clock_timestamp(),
  foreign key(decision_id,decision_version,decision_sha256)
    references app_private.assignment_case_decision_versions(decision_id,decision_version,decision_sha256)
    on delete restrict,
  unique(finalized_by,idempotency_key),
  check (gross_principal_kobo::numeric=worker_award_gross_kobo::numeric+
    poster_refund_gross_kobo::numeric+retained_hold_gross_kobo::numeric),
  check (worker_award_gross_kobo::numeric=commission_kobo::numeric+worker_net_kobo::numeric),
  check ((worker_award_gross_kobo=0)=(award_journal_id is null)),
  check ((poster_refund_gross_kobo=0)=(refund_payable_id is null)),
  check ((poster_refund_gross_kobo=0)=(refund_journal_id is null)),
  check ((outcome='no_action')=(hold_restore_journal_id is not null)),
  check ((outcome='full_worker_award' and worker_award_gross_kobo=gross_principal_kobo
      and poster_refund_gross_kobo=0 and retained_hold_gross_kobo=0) or
    (outcome='full_poster_refund' and worker_award_gross_kobo=0
      and poster_refund_gross_kobo=gross_principal_kobo and retained_hold_gross_kobo=0) or
    (outcome='split' and worker_award_gross_kobo>0 and poster_refund_gross_kobo>0
      and retained_hold_gross_kobo=0) or
    (outcome='no_action' and worker_award_gross_kobo=0 and poster_refund_gross_kobo=0
      and retained_hold_gross_kobo=gross_principal_kobo))
);
create index assignment_case_finalizations_assignment_idx
  on app_private.assignment_case_finalizations(assignment_id,executed_at desc);

create table app_private.assignment_case_award_authorizations (
  authorization_id uuid primary key default pg_catalog.gen_random_uuid(),
  finalization_id uuid not null unique references app_private.assignment_case_finalizations(finalization_id) on delete restrict,
  case_id uuid not null references app_private.assignment_cases(case_id) on delete restrict,
  decision_id uuid not null references app_private.assignment_case_decision_versions(decision_id) on delete restrict,
  assignment_id uuid not null unique references app_private.assignments(assignment_id) on delete restrict,
  allocation_id uuid not null unique references app_private.principal_allocations(allocation_id) on delete restrict,
  worker_id uuid not null references auth.users(id) on delete restrict,
  terms_version integer not null check (terms_version>0),
  terms_sha256 bytea not null check (pg_catalog.octet_length(terms_sha256)=32),
  gross_award_kobo bigint not null check (gross_award_kobo>0),
  commission_kobo bigint not null check (commission_kobo>=0),
  worker_net_kobo bigint not null check (worker_net_kobo>0),
  journal_id uuid not null unique references app_private.ledger_journal_transactions(journal_id) on delete restrict,
  actor_id uuid not null references auth.users(id) on delete restrict,
  idempotency_key uuid not null,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  check (gross_award_kobo::numeric=commission_kobo::numeric+worker_net_kobo::numeric)
);

create function app_private.reject_case_finalization_history_mutation()
returns trigger language plpgsql set search_path = '' as $function$
begin
  raise exception using errcode='55000',message='case_finalization_history_is_immutable';
end;
$function$;
create trigger assignment_case_finalizations_immutable before update or delete
on app_private.assignment_case_finalizations for each row
execute function app_private.reject_case_finalization_history_mutation();
create trigger assignment_case_award_authorizations_immutable before update or delete
on app_private.assignment_case_award_authorizations for each row
execute function app_private.reject_case_finalization_history_mutation();

alter table app_private.assignments
  add column case_finalization_id uuid references app_private.assignment_case_finalizations(finalization_id) on delete restrict,
  drop constraint assignments_progress_timestamps_check,
  add constraint assignments_progress_timestamps_check check (
    (work_state='assigned' and started_at is null and submitted_at is null and completed_at is null
      and case_finalization_id is null) or
    (work_state='in_progress' and started_at is not null and submitted_at is null and completed_at is null
      and case_finalization_id is null) or
    (work_state='submitted' and started_at is not null and submitted_at is not null and completed_at is null
      and case_finalization_id is null) or
    (work_state='completed' and completed_at is not null and
      (case_finalization_id is not null or (started_at is not null and submitted_at is not null))) or
    work_state='cancelled'
  );

create or replace function app_private.reject_assignment_mutation()
returns trigger language plpgsql set search_path = '' as $function$
declare v_transition text;
begin
  if tg_op='DELETE' then
    raise exception using errcode='55000',message='assignment_record_is_immutable';
  end if;
  v_transition:=coalesce(pg_catalog.current_setting('app.assignment_cancellation_transition',true),'');
  if new.assignment_id is distinct from old.assignment_id
     or new.application_id is distinct from old.application_id
     or new.job_id is distinct from old.job_id or new.worker_id is distinct from old.worker_id
     or new.poster_id is distinct from old.poster_id or new.allocation_id is distinct from old.allocation_id
     or new.funding_intent_id is distinct from old.funding_intent_id
     or new.terms_version is distinct from old.terms_version
     or new.terms_sha256 is distinct from old.terms_sha256
     or new.gross_principal_kobo is distinct from old.gross_principal_kobo
     or new.commission_basis_points is distinct from old.commission_basis_points
     or new.created_at is distinct from old.created_at
     or not (
       (new.work_state=old.work_state and new.started_at=old.started_at
         and new.submitted_at=old.submitted_at and new.completed_at=old.completed_at
         and new.case_finalization_id is not distinct from old.case_finalization_id) or
       (old.work_state='assigned' and new.work_state='in_progress' and old.started_at is null
         and new.started_at is not null and new.submitted_at is null and new.completed_at is null
         and new.case_finalization_id is null) or
       (old.work_state='in_progress' and new.work_state='submitted' and new.started_at=old.started_at
         and old.submitted_at is null and new.submitted_at is not null and new.completed_at is null
         and new.case_finalization_id is null) or
       (old.work_state='submitted' and new.work_state='completed' and new.started_at=old.started_at
         and new.submitted_at=old.submitted_at and old.completed_at is null and new.completed_at is not null
         and new.case_finalization_id is null) or
       (old.work_state in ('assigned','in_progress','submitted') and new.work_state='completed'
         and new.started_at=old.started_at and new.submitted_at=old.submitted_at
         and old.completed_at is null and new.completed_at is not null
         and old.case_finalization_id is null and new.case_finalization_id is not null
         and v_transition='case_finalization'
         and exists(select 1 from app_private.assignment_case_finalizations f
           where f.finalization_id=new.case_finalization_id and f.assignment_id=new.assignment_id
             and f.outcome in ('full_worker_award','split'))) or
       (old.work_state in ('assigned','in_progress','submitted') and new.work_state='cancelled'
         and new.started_at=old.started_at and new.submitted_at=old.submitted_at
         and new.completed_at=old.completed_at and old.case_finalization_id is null
         and new.case_finalization_id is not null and v_transition='case_finalization'
         and exists(select 1 from app_private.assignment_case_finalizations f
           where f.finalization_id=new.case_finalization_id and f.assignment_id=new.assignment_id
             and f.outcome='full_poster_refund')) or
       (old.work_state='assigned' and new.work_state='cancelled' and old.started_at is null
         and new.started_at is null and old.submitted_at is null and new.submitted_at is null
         and old.completed_at is null and new.completed_at is null
         and old.case_finalization_id is null and new.case_finalization_id is null
         and v_transition in ('worker_abandonment','mutual_prestart_cancellation'))
     ) then
    raise exception using errcode='55000',message='assignment_record_is_immutable';
  end if;
  return new;
end;
$function$;

create or replace function app_private.validate_assignment_allocation_pair()
returns trigger language plpgsql security definer set search_path = '' as $function$
begin
  if tg_table_name='principal_allocations' then
    if new.status in ('unassigned','refund_payable') then
      if new.assignment_id is not null then
        raise exception using errcode='22023',message='invalid_assignment_allocation_binding';
      end if;
    elsif not exists(select 1 from app_private.assignments a
      where a.assignment_id=new.assignment_id and a.allocation_id=new.allocation_id
        and a.job_id=new.job_id and a.poster_id=new.poster_id
        and a.funding_intent_id=new.funding_intent_id
        and a.gross_principal_kobo=new.gross_principal_kobo
        and a.commission_basis_points=new.commission_basis_points
        and exists(select 1 from app_private.allocation_assignment_bindings b
          where b.assignment_id=a.assignment_id and b.allocation_id=a.allocation_id and b.unbound_at is null)
        and ((new.status='assigned' and a.work_state in ('assigned','in_progress','submitted')
              and not exists(select 1 from app_private.assignment_cases c
                where c.allocation_id=new.allocation_id and c.lifecycle_status<>'closed'))
          or (new.status='dispute_held' and a.work_state in ('assigned','in_progress','submitted')
              and exists(select 1 from app_private.assignment_cases c
                where c.assignment_id=a.assignment_id and c.allocation_id=new.allocation_id
                  and c.lifecycle_status<>'closed'))
          or (new.status='worker_earnings_allocated' and a.work_state='completed'
              and not exists(select 1 from app_private.assignment_cases c
                where c.assignment_id=a.assignment_id and c.lifecycle_status<>'closed')
              and (exists(select 1 from app_private.assignment_completion_authorizations ca
                    where ca.assignment_id=a.assignment_id and ca.allocation_id=new.allocation_id)
                or exists(select 1 from app_private.assignment_case_award_authorizations ca
                    where ca.assignment_id=a.assignment_id and ca.allocation_id=new.allocation_id))))) then
      raise exception using errcode='22023',message='invalid_assignment_allocation_binding';
    end if;
  elsif new.work_state='cancelled' then
    if not exists(select 1 from app_private.allocation_assignment_bindings b
      where b.assignment_id=new.assignment_id and b.allocation_id=new.allocation_id and b.unbound_at is not null)
       or exists(select 1 from app_private.principal_allocations p
          where p.allocation_id=new.allocation_id and p.assignment_id=new.assignment_id) then
      raise exception using errcode='22023',message='invalid_assignment_allocation_binding';
    end if;
  elsif not exists(select 1 from app_private.principal_allocations p
    join app_private.allocation_assignment_bindings b
      on b.assignment_id=p.assignment_id and b.allocation_id=p.allocation_id and b.unbound_at is null
    where p.allocation_id=new.allocation_id and p.assignment_id=new.assignment_id
      and p.job_id=new.job_id and p.poster_id=new.poster_id
      and p.funding_intent_id=new.funding_intent_id
      and p.gross_principal_kobo=new.gross_principal_kobo
      and p.commission_basis_points=new.commission_basis_points
      and ((p.status='assigned' and new.work_state in ('assigned','in_progress','submitted')
            and not exists(select 1 from app_private.assignment_cases c
              where c.allocation_id=p.allocation_id and c.lifecycle_status<>'closed'))
        or (p.status='dispute_held' and new.work_state in ('assigned','in_progress','submitted')
            and exists(select 1 from app_private.assignment_cases c
              where c.assignment_id=new.assignment_id and c.allocation_id=p.allocation_id
                and c.lifecycle_status<>'closed'))
        or (p.status='worker_earnings_allocated' and new.work_state='completed'
            and not exists(select 1 from app_private.assignment_cases c
              where c.assignment_id=new.assignment_id and c.lifecycle_status<>'closed')
            and (exists(select 1 from app_private.assignment_completion_authorizations ca
                  where ca.assignment_id=new.assignment_id and ca.allocation_id=p.allocation_id)
              or exists(select 1 from app_private.assignment_case_award_authorizations ca
                  where ca.assignment_id=new.assignment_id and ca.allocation_id=p.allocation_id))))) then
    raise exception using errcode='22023',message='invalid_assignment_allocation_binding';
  end if;
  return null;
end;
$function$;

create or replace function app_private.guard_allocation_change()
returns trigger language plpgsql security definer set search_path = '' as $function$
declare
  v_intent app_private.funding_intents%rowtype;
  v_transition text;
begin
  if tg_op='INSERT' then
    select * into v_intent from app_private.funding_intents where intent_id=new.funding_intent_id for key share;
    if not found or v_intent.status not in ('pending','unknown') or new.job_id<>v_intent.job_id
       or new.poster_id<>v_intent.poster_id or new.gross_principal_kobo<>v_intent.gross_per_worker_kobo
       or new.slot_number>v_intent.slot_count or new.status<>'unassigned' or new.assignment_id is not null
       or new.commission_basis_points<>500 or not exists(select 1 from app_private.funding_attempts a
         where a.funding_intent_id=v_intent.intent_id and a.status='succeeded'
           and a.collected_gross_kobo=v_intent.gross_total_kobo and a.currency=v_intent.currency) then
      raise exception using errcode='22023',message='invalid_principal_allocation';
    end if;
    return new;
  end if;
  if tg_op='DELETE' then
    raise exception using errcode='55000',message='principal_allocation_is_immutable';
  end if;
  v_transition:=coalesce(pg_catalog.current_setting('app.allocation_transition',true),'');
  if new.allocation_id is distinct from old.allocation_id
     or new.funding_intent_id is distinct from old.funding_intent_id
     or new.job_id is distinct from old.job_id or new.poster_id is distinct from old.poster_id
     or new.slot_number is distinct from old.slot_number
     or new.gross_principal_kobo is distinct from old.gross_principal_kobo
     or new.commission_basis_points is distinct from old.commission_basis_points
     or new.created_at is distinct from old.created_at
     or not (
       (old.status='unassigned' and new.status='assigned' and old.assignment_id is null and new.assignment_id is not null) or
       (old.status='assigned' and new.status in ('dispute_held','worker_earnings_allocated') and new.assignment_id=old.assignment_id) or
       (old.status='assigned' and new.status='unassigned' and old.assignment_id is not null and new.assignment_id is null and v_transition='worker_abandonment') or
       (old.status='assigned' and new.status='refund_payable' and old.assignment_id is not null and new.assignment_id is null and v_transition='mutual_prestart_cancellation') or
       (old.status='unassigned' and new.status='refund_payable' and old.assignment_id is null and new.assignment_id is null and v_transition='poster_unassigned_cancellation') or
       (old.status='dispute_held' and new.status='worker_earnings_allocated' and new.assignment_id=old.assignment_id and v_transition='case_finalization'
         and exists(select 1 from app_private.assignment_case_finalizations f where f.allocation_id=new.allocation_id
           and f.assignment_id=new.assignment_id and f.outcome in ('full_worker_award','split'))) or
       (old.status='dispute_held' and new.status='refund_payable' and old.assignment_id is not null and new.assignment_id is null and v_transition='case_finalization'
         and exists(select 1 from app_private.assignment_case_finalizations f where f.allocation_id=new.allocation_id
           and f.assignment_id=old.assignment_id and f.outcome='full_poster_refund')) or
       (old.status='dispute_held' and new.status='assigned' and new.assignment_id=old.assignment_id and v_transition='case_finalization'
         and exists(select 1 from app_private.assignment_case_finalizations f where f.allocation_id=new.allocation_id
           and f.assignment_id=new.assignment_id and f.outcome='no_action'))
     ) then
    raise exception using errcode='55000',message='principal_allocation_is_immutable';
  end if;
  new.updated_at:=pg_catalog.now();
  return new;
end;
$function$;

create or replace function app_private.guard_assignment_case_lifecycle()
returns trigger language plpgsql set search_path = '' as $function$
declare v_transition text;
begin
  if tg_op='DELETE' then
    raise exception using errcode='55000',message='case_lifecycle_cannot_be_deleted';
  end if;
  v_transition:=coalesce(pg_catalog.current_setting('app.assignment_case_transition',true),'');
  if new.case_id is distinct from old.case_id or new.hold_id is distinct from old.hold_id
     or new.assignment_id is distinct from old.assignment_id or new.allocation_id is distinct from old.allocation_id
     or new.terms_version is distinct from old.terms_version or new.terms_sha256 is distinct from old.terms_sha256
     or new.prior_work_state is distinct from old.prior_work_state or new.thread_id is distinct from old.thread_id
     or new.thread_through_sequence is distinct from old.thread_through_sequence
     or new.opened_at is distinct from old.opened_at or new.version<>old.version+1 then
    raise exception using errcode='55000',message='invalid_case_lifecycle_transition';
  end if;
  if v_transition='finalize_case' then
    if old.lifecycle_status<>'decision_made' or new.lifecycle_status<>'closed'
       or old.closed_at is not null or new.closed_at is null
       or new.reviewer_id is distinct from old.reviewer_id then
      raise exception using errcode='55000',message='invalid_case_lifecycle_transition';
    end if;
  else
    if new.closed_at is distinct from old.closed_at then
      raise exception using errcode='55000',message='invalid_case_lifecycle_transition';
    end if;
    if v_transition='assign_reviewer' then
      if old.lifecycle_status not in ('open','under_review','contacting_other_party','verifying')
         or new.lifecycle_status<>'under_review' or new.reviewer_id is null then
        raise exception using errcode='55000',message='invalid_case_lifecycle_transition';
      end if;
    elsif v_transition in ('triage_case','log_case_contact_attempt','request_case_information',
        'respond_to_case_information','record_case_fact','add_case_internal_note',
        'assess_case_nonresponse','signoff_case_nonresponse') then
      if old.lifecycle_status not in ('open','under_review','contacting_other_party','verifying')
         or new.lifecycle_status not in ('under_review','contacting_other_party','verifying')
         or new.reviewer_id is distinct from old.reviewer_id then
        raise exception using errcode='55000',message='invalid_case_lifecycle_transition';
      end if;
    elsif v_transition='propose_case_decision' then
      if old.lifecycle_status not in ('verifying','decision_made') or new.lifecycle_status<>'verifying'
         or new.reviewer_id is distinct from old.reviewer_id then
        raise exception using errcode='55000',message='invalid_case_lifecycle_transition';
      end if;
    elsif v_transition='approve_case_decision' then
      if old.lifecycle_status<>'verifying' or new.lifecycle_status<>'decision_made'
         or new.reviewer_id is distinct from old.reviewer_id then
        raise exception using errcode='55000',message='invalid_case_lifecycle_transition';
      end if;
    elsif v_transition='submit_case_appeal' then
      if old.lifecycle_status not in ('decision_made','appeal','verifying')
         or new.lifecycle_status not in ('appeal','verifying')
         or new.reviewer_id is distinct from old.reviewer_id then
        raise exception using errcode='55000',message='invalid_case_lifecycle_transition';
      end if;
    elsif v_transition='assign_case_appeal_reviewer' then
      if old.lifecycle_status not in ('appeal','verifying','decision_made')
         or new.lifecycle_status<>'verifying' or new.reviewer_id is null
         or new.reviewer_id=(select initial_reviewer_id
           from app_private.assignment_case_decision_publications where case_id=old.case_id) then
        raise exception using errcode='55000',message='invalid_case_lifecycle_transition';
      end if;
    elsif v_transition='appeal_decision_recorded' then
      if old.lifecycle_status not in ('appeal','verifying','decision_made')
         or new.lifecycle_status not in ('appeal','decision_made')
         or new.reviewer_id is distinct from old.reviewer_id then
        raise exception using errcode='55000',message='invalid_case_lifecycle_transition';
      end if;
    else
      raise exception using errcode='55000',message='invalid_case_lifecycle_transition';
    end if;
  end if;
  new.updated_at:=pg_catalog.clock_timestamp();
  return new;
end;
$function$;

create function app_private.finalize_case_for_actor_at(
  p_actor uuid,p_case_id uuid,p_decision_version integer,p_expected_case_version integer,
  p_auth_aal text,p_idempotency_key uuid,p_as_of timestamptz
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_case app_private.assignment_cases%rowtype;
  v_assignment app_private.assignments%rowtype;
  v_allocation app_private.principal_allocations%rowtype;
  v_decision app_private.assignment_case_decision_versions%rowtype;
  v_publication app_private.assignment_case_decision_publications%rowtype;
  v_existing app_private.case_command_idempotency%rowtype;
  v_finalization_id uuid:=pg_catalog.gen_random_uuid();
  v_payable_id uuid;
  v_refund_journal_id uuid;
  v_award_journal_id uuid;
  v_hold_journal_id uuid;
  v_primary_journal_id uuid;
  v_finalizer_dispute_grant uuid;
  v_finalizer_initiate_grant uuid;
  v_proposer_dispute_grant uuid;
  v_proposer_financial_grant uuid;
  v_approval_one uuid;
  v_approval_two uuid;
  v_approver_one uuid;
  v_approver_two uuid;
  v_proposer_account_status text;
  v_signoff app_private.assignment_case_decision_nonresponse_signoffs%rowtype;
  v_nonresponse_signoff_id uuid;
  v_approval_count integer;
  v_current_held bigint;
  v_request_hash bytea;
  v_block_reason text;
  v_response jsonb;
  v_entries jsonb;
  v_event_id uuid;
  v_sequence integer;
begin
  if p_actor is null or p_case_id is null or p_decision_version is null or p_decision_version<1
     or p_expected_case_version is null or p_expected_case_version<1
     or p_idempotency_key is null or p_as_of is null then
    raise exception using errcode='22023',message='invalid_case_command';
  end if;
  v_request_hash:=extensions.digest(pg_catalog.jsonb_build_object(
    'case_id',p_case_id,'decision_version',p_decision_version,
    'expected_case_version',p_expected_case_version
  )::text,'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    p_actor::text||':finalize_case:'||p_idempotency_key::text,428118));

  select * into v_case from app_private.assignment_cases where case_id=p_case_id for update;
  if not found then raise exception using errcode='P0002',message='case_not_found'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'case_appeal_receipt_finalization:'||p_case_id::text,428118));
  select * into v_assignment from app_private.assignments
    where assignment_id=v_case.assignment_id for update;
  select * into v_allocation from app_private.principal_allocations
    where allocation_id=v_case.allocation_id for update;
  select g.grant_id into v_finalizer_dispute_grant
    from app_private.staff_grants g where g.user_id=p_actor
      and g.capability='dispute_review' and g.revoked_at is null for share;
  select g.grant_id into v_finalizer_initiate_grant
    from app_private.staff_grants g where g.user_id=p_actor
      and g.capability='financial_initiate' and g.revoked_at is null for share;
  if not app_private.lock_case_reviewer_scope(p_actor,p_auth_aal)
     or v_case.reviewer_id is distinct from p_actor or p_actor in (v_assignment.worker_id,v_assignment.poster_id)
     or v_finalizer_dispute_grant is null or v_finalizer_initiate_grant is null
     or not app_private.case_staff_principal_is_human(p_actor) then
    raise exception using errcode='42501',message='case_access_denied';
  end if;

  select * into v_existing from app_private.case_command_idempotency
  where actor_id=p_actor and command_name='finalize_case' and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.request_sha256<>v_request_hash then
      raise exception using errcode='23505',message='idempotency_conflict';
    end if;
    return v_existing.response;
  end if;
  if v_case.lifecycle_status<>'decision_made' or v_case.closed_at is not null
     or v_case.version<>p_expected_case_version
     or v_allocation.status<>'dispute_held'
     or v_allocation.assignment_id<>v_assignment.assignment_id
     or v_allocation.gross_principal_kobo<>v_assignment.gross_principal_kobo
     or v_case.prior_work_state<>v_assignment.work_state then
    raise exception using errcode='P0001',message='stale_state';
  end if;

  v_decision:=app_private.case_effective_approved_decision(p_case_id);
  if v_decision.decision_id is null or v_decision.decision_version<>p_decision_version
     or v_decision.case_id<>p_case_id or v_decision.assignment_id<>v_assignment.assignment_id
     or v_decision.allocation_id<>v_allocation.allocation_id
     or v_decision.gross_principal_kobo<>v_allocation.gross_principal_kobo
     or v_decision.terms_version<>v_assignment.terms_version
     or v_decision.terms_sha256<>v_assignment.terms_sha256
     or v_decision.prior_work_state<>v_case.prior_work_state then
    raise exception using errcode='P0001',message='stale_decision_version';
  end if;
  select * into v_publication from app_private.assignment_case_decision_publications
    where case_id=p_case_id for share;
  if not found then raise exception using errcode='P0001',message='decision_not_durably_notified'; end if;
  v_block_reason:=app_private.case_appeal_finalization_block_reason(p_case_id,p_as_of);
  if v_block_reason is not null then
    raise exception using errcode='P0001',message=v_block_reason;
  end if;

  if not exists(select 1 from app_private.funding_intents f
       where f.intent_id=v_allocation.funding_intent_id and f.job_id=v_allocation.job_id
         and f.poster_id=v_allocation.poster_id and f.status='succeeded'
         and f.currency='NGN') then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  select -b.balance_kobo into v_current_held
  from app_private.ledger_account_balances b
  join app_private.ledger_accounts a using(account_id)
  where a.account_code='job_principal_dispute_held'
    and b.allocation_id=v_allocation.allocation_id and b.owner_id is null;
  if v_current_held is distinct from v_allocation.gross_principal_kobo then
    raise exception using errcode='P0001',message='stale_state';
  end if;

  select g.grant_id into v_proposer_dispute_grant
  from app_private.staff_grants g where g.grant_id=v_decision.proposer_dispute_grant_id
    and g.user_id=v_decision.proposed_by and g.capability='dispute_review'
    and g.revoked_at is null for share;
  select g.grant_id into v_proposer_financial_grant
  from app_private.staff_grants g where g.grant_id=v_decision.proposer_financial_grant_id
    and g.user_id=v_decision.proposed_by and g.capability='financial_approve'
    and g.revoked_at is null for share;
  if v_proposer_dispute_grant is null or v_proposer_financial_grant is null
     or v_decision.proposed_by in (v_assignment.worker_id,v_assignment.poster_id)
     or not app_private.case_staff_principal_is_human(v_decision.proposed_by) then
    raise exception using errcode='42501',message='case_access_denied';
  end if;
  select ia.account_status into v_proposer_account_status
  from app_private.identity_accounts ia where ia.user_id=v_decision.proposed_by for share;
  if v_proposer_account_status is distinct from 'active' then
    raise exception using errcode='42501',message='case_access_denied';
  end if;

  perform 1 from app_private.assignment_case_decision_approvals ap
  join app_private.staff_grants g on g.grant_id=ap.financial_grant_id and g.user_id=ap.approver_id
  join app_private.identity_accounts ia on ia.user_id=ap.approver_id
  where ap.decision_id=v_decision.decision_id and ap.decision_version=v_decision.decision_version
    and ap.decision_sha256=v_decision.decision_sha256 for share of g,ia;

  select count(*)::integer into v_approval_count
  from app_private.assignment_case_decision_approvals ap
  join app_private.staff_grants g on g.grant_id=ap.financial_grant_id
    and g.user_id=ap.approver_id and g.capability='financial_approve' and g.revoked_at is null
  join app_private.identity_accounts ia on ia.user_id=ap.approver_id and ia.account_status='active'
  where ap.decision_id=v_decision.decision_id and ap.decision_version=v_decision.decision_version
    and ap.decision_sha256=v_decision.decision_sha256
    and ap.approver_id not in (v_assignment.worker_id,v_assignment.poster_id)
    and app_private.case_staff_principal_is_human(ap.approver_id);
  if v_approval_count<>2 or (select count(distinct ap.approver_id)::integer
       from app_private.assignment_case_decision_approvals ap
       where ap.decision_id=v_decision.decision_id and ap.decision_sha256=v_decision.decision_sha256)<>2
     or not exists(select 1 from app_private.assignment_case_decision_approvals ap
       where ap.decision_id=v_decision.decision_id and ap.approval_number=1
         and ap.approver_id=v_decision.proposed_by) then
    raise exception using errcode='42501',message='case_access_denied';
  end if;
  select approval_id,approver_id into v_approval_one,v_approver_one
    from app_private.assignment_case_decision_approvals
    where decision_id=v_decision.decision_id and approval_number=1
      and decision_sha256=v_decision.decision_sha256;
  select approval_id,approver_id into v_approval_two,v_approver_two
    from app_private.assignment_case_decision_approvals
    where decision_id=v_decision.decision_id and approval_number=2
      and decision_sha256=v_decision.decision_sha256;
  if v_approver_one is null or v_approver_two is null or v_approver_one=v_approver_two then
    raise exception using errcode='42501',message='case_access_denied';
  end if;

  if v_decision.nonresponse_assessment_id is not null then
    select s.* into v_signoff from app_private.assignment_case_decision_nonresponse_signoffs s
    join app_private.staff_grants g on g.grant_id=s.senior_grant_id and g.user_id=s.senior_id
      and g.capability='case_senior_signoff' and g.revoked_at is null
    join app_private.identity_accounts ia on ia.user_id=s.senior_id and ia.account_status='active'
    where s.decision_id=v_decision.decision_id and s.decision_version=v_decision.decision_version
      and s.decision_sha256=v_decision.decision_sha256
      and s.assessment_id=v_decision.nonresponse_assessment_id
      and s.senior_id not in (v_assignment.worker_id,v_assignment.poster_id,
        v_case.reviewer_id,v_decision.proposed_by)
      and app_private.case_staff_principal_is_human(s.senior_id)
    for share of s,g,ia;
    if not found then raise exception using errcode='42501',message='case_access_denied'; end if;
    v_nonresponse_signoff_id:=v_signoff.signoff_id;
  end if;

  if v_decision.worker_award_gross_kobo>0 then
    v_entries:=pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('account_code','job_principal_dispute_held','direction','debit',
        'amount_kobo',v_decision.worker_award_gross_kobo::text,
        'allocation_id',v_allocation.allocation_id::text),
      pg_catalog.jsonb_build_object('account_code','worker_earnings_available','direction','credit',
        'amount_kobo',v_decision.worker_net_kobo::text,
        'allocation_id',v_allocation.allocation_id::text,'owner_id',v_assignment.worker_id::text)
    );
    if v_decision.commission_kobo>0 then
      v_entries:=v_entries||pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('account_code','platform_commission_revenue','direction','credit',
          'amount_kobo',v_decision.commission_kobo::text,
          'allocation_id',v_allocation.allocation_id::text));
    end if;
    v_award_journal_id:=app_private.post_financial_journal(
      app_private.stable_financial_effect_key('nbd:case_award:'||p_case_id::text||':'||v_decision.decision_version::text),
      'case_outcome_finalized',v_finalization_id,p_actor,v_entries);
  end if;
  if v_decision.poster_refund_gross_kobo>0 then
    v_payable_id:=pg_catalog.gen_random_uuid();
    v_refund_journal_id:=app_private.post_financial_journal(
      app_private.stable_financial_effect_key('nbd:allocation_refund_authorized:'||v_allocation.allocation_id::text),
      'allocation_refund_authorized',v_payable_id,p_actor,pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('account_code','job_principal_dispute_held','direction','debit',
          'amount_kobo',v_decision.poster_refund_gross_kobo::text,
          'allocation_id',v_allocation.allocation_id::text),
        pg_catalog.jsonb_build_object('account_code','poster_refund_payable','direction','credit',
          'amount_kobo',v_decision.poster_refund_gross_kobo::text,
          'allocation_id',v_allocation.allocation_id::text,'owner_id',v_assignment.poster_id::text)
      ));
    insert into app_private.allocation_refund_payables(
      refund_payable_id,allocation_id,poster_id,amount_kobo,source,source_assignment_id,
      case_id,decision_id,reason,status,authorized_by,idempotency_key
    ) values(v_payable_id,v_allocation.allocation_id,v_assignment.poster_id,
      v_decision.poster_refund_gross_kobo,'case_decision',v_assignment.assignment_id,
      p_case_id,v_decision.decision_id,
      'Case decision '||v_decision.decision_version::text||' refund authorization',
      'authorized',p_actor,p_idempotency_key);
  end if;
  if v_decision.outcome='no_action' then
    v_hold_journal_id:=app_private.post_financial_journal(
      app_private.stable_financial_effect_key('nbd:case_hold_restored:'||p_case_id::text||':'||v_decision.decision_version::text),
      'case_hold_restored',v_finalization_id,p_actor,pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('account_code','job_principal_dispute_held','direction','debit',
          'amount_kobo',v_decision.gross_principal_kobo::text,
          'allocation_id',v_allocation.allocation_id::text),
        pg_catalog.jsonb_build_object('account_code','job_principal_assigned','direction','credit',
          'amount_kobo',v_decision.gross_principal_kobo::text,
          'allocation_id',v_allocation.allocation_id::text)
      ));
  end if;

  v_primary_journal_id:=coalesce(v_award_journal_id,v_refund_journal_id,v_hold_journal_id);
  if v_primary_journal_id is null then
    raise exception using errcode='P0001',message='stale_decision_version';
  end if;
  insert into app_private.assignment_case_finalizations(
    finalization_id,case_id,decision_id,decision_version,decision_sha256,
    assignment_id,allocation_id,expected_case_version,prior_work_state,outcome,
    gross_principal_kobo,worker_award_gross_kobo,poster_refund_gross_kobo,
    retained_hold_gross_kobo,commission_kobo,worker_net_kobo,
    approval_one_id,approval_two_id,nonresponse_signoff_id,finalized_by,
    finalizer_dispute_grant_id,finalizer_initiate_grant_id,award_journal_id,
    refund_payable_id,refund_journal_id,hold_restore_journal_id,idempotency_key
  ) values(v_finalization_id,p_case_id,v_decision.decision_id,v_decision.decision_version,
    v_decision.decision_sha256,v_assignment.assignment_id,v_allocation.allocation_id,
    p_expected_case_version,v_case.prior_work_state,v_decision.outcome,
    v_decision.gross_principal_kobo,v_decision.worker_award_gross_kobo,
    v_decision.poster_refund_gross_kobo,v_decision.retained_hold_gross_kobo,
    v_decision.commission_kobo,v_decision.worker_net_kobo,v_approval_one,v_approval_two,
    v_nonresponse_signoff_id,p_actor,v_finalizer_dispute_grant,v_finalizer_initiate_grant,
    v_award_journal_id,v_payable_id,v_refund_journal_id,v_hold_journal_id,p_idempotency_key);

  if v_award_journal_id is not null then
    insert into app_private.assignment_case_award_authorizations(
      finalization_id,case_id,decision_id,assignment_id,allocation_id,worker_id,
      terms_version,terms_sha256,gross_award_kobo,commission_kobo,worker_net_kobo,
      journal_id,actor_id,idempotency_key
    ) values(v_finalization_id,p_case_id,v_decision.decision_id,v_assignment.assignment_id,
      v_allocation.allocation_id,v_assignment.worker_id,v_assignment.terms_version,
      v_assignment.terms_sha256,v_decision.worker_award_gross_kobo,
      v_decision.commission_kobo,v_decision.worker_net_kobo,v_award_journal_id,p_actor,p_idempotency_key);
  end if;

  perform pg_catalog.set_config('app.allocation_transition','case_finalization',true);
  if v_decision.outcome in ('full_worker_award','split') then
    perform pg_catalog.set_config('app.assignment_cancellation_transition','case_finalization',true);
    update app_private.assignments set work_state='completed',completed_at=pg_catalog.clock_timestamp(),
      case_finalization_id=v_finalization_id
      where assignment_id=v_assignment.assignment_id and work_state=v_case.prior_work_state;
    if not found then raise exception using errcode='P0001',message='stale_state'; end if;
    update app_private.job_applications set state='closed',decided_at=pg_catalog.clock_timestamp(),decided_by=p_actor
      where application_id=v_assignment.application_id and state='accepted';
    if not found then raise exception using errcode='P0001',message='stale_state'; end if;
    update app_private.principal_allocations set status='worker_earnings_allocated'
      where allocation_id=v_allocation.allocation_id and status='dispute_held';
    if not found then raise exception using errcode='P0001',message='stale_state'; end if;
  elsif v_decision.outcome='full_poster_refund' then
    perform pg_catalog.set_config('app.allocation_actor',p_actor::text,true);
    perform pg_catalog.set_config('app.assignment_unbind_reason','case_finalized_refund',true);
    update app_private.principal_allocations set assignment_id=null,status='refund_payable'
      where allocation_id=v_allocation.allocation_id and assignment_id=v_assignment.assignment_id
        and status='dispute_held';
    if not found then raise exception using errcode='P0001',message='stale_state'; end if;
    perform pg_catalog.set_config('app.assignment_cancellation_transition','case_finalization',true);
    update app_private.assignments set work_state='cancelled',case_finalization_id=v_finalization_id
      where assignment_id=v_assignment.assignment_id and work_state=v_case.prior_work_state;
    if not found then raise exception using errcode='P0001',message='stale_state'; end if;
    update app_private.job_applications set state='closed',decided_at=pg_catalog.clock_timestamp(),decided_by=p_actor
      where application_id=v_assignment.application_id and state='accepted';
    if not found then raise exception using errcode='P0001',message='stale_state'; end if;
  else
    perform pg_catalog.set_config('app.assignment_case_transition','finalize_case',true);
    update app_private.assignment_cases set lifecycle_status='closed',closed_at=pg_catalog.clock_timestamp(),
      version=version+1 where case_id=p_case_id and version=p_expected_case_version;
    if not found then raise exception using errcode='P0001',message='stale_state'; end if;
    update app_private.principal_allocations set status='assigned'
      where allocation_id=v_allocation.allocation_id and status='dispute_held';
    if not found then raise exception using errcode='P0001',message='stale_state'; end if;
  end if;

  if v_decision.outcome<>'no_action' then
    perform pg_catalog.set_config('app.assignment_case_transition','finalize_case',true);
    update app_private.assignment_cases set lifecycle_status='closed',closed_at=pg_catalog.clock_timestamp(),
      version=version+1 where case_id=p_case_id and version=p_expected_case_version;
    if not found then raise exception using errcode='P0001',message='stale_state'; end if;
  end if;
  perform pg_catalog.set_config('app.assignment_case_transition','',true);
  perform pg_catalog.set_config('app.allocation_transition','',true);
  perform pg_catalog.set_config('app.assignment_cancellation_transition','',true);
  perform pg_catalog.set_config('app.assignment_unbind_reason','',true);
  perform pg_catalog.set_config('app.allocation_actor','',true);

  select coalesce(max(sequence),0)+1 into v_sequence
    from app_private.assignment_case_events where case_id=p_case_id;
  insert into app_private.assignment_case_events(
    case_id,sequence,actor_id,audience,event_type,payload
  ) values(p_case_id,v_sequence,p_actor,'participants','case_closed',pg_catalog.jsonb_build_object(
    'status','closed','update','The case decision has been finalized.',
    'decision_version',v_decision.decision_version,'outcome',v_decision.outcome,
    'gross_principal_kobo',v_decision.gross_principal_kobo::text,
    'worker_award_gross_kobo',v_decision.worker_award_gross_kobo::text,
    'poster_refund_gross_kobo',v_decision.poster_refund_gross_kobo::text,
    'retained_hold_gross_kobo',v_decision.retained_hold_gross_kobo::text,
    'commission_kobo',v_decision.commission_kobo::text,
    'worker_net_kobo',v_decision.worker_net_kobo::text,
    'execution_status','executed',
    'refund_status',case when v_payable_id is null then 'not_applicable' else 'authorized' end
  ));
  v_event_id:=app_private.append_marketplace_event(p_actor,v_assignment.job_id,
    'job.assignment_case_finalized',v_assignment.terms_version,pg_catalog.jsonb_build_object(
      'case_id',p_case_id,'decision_version',v_decision.decision_version,
      'outcome',v_decision.outcome,'execution_status','executed',
      'refund_status',case when v_payable_id is null then 'not_applicable' else 'authorized' end
    ));
  perform app_private.add_in_app_notification(v_event_id,v_assignment.worker_id,'assignment_case_finalized');
  perform app_private.add_in_app_notification(v_event_id,v_assignment.poster_id,'assignment_case_finalized');
  insert into app_private.assignment_case_access_audit(case_id,actor_id,action)
    values(p_case_id,p_actor,'case_finalization_executed');
  insert into app_private.financial_audit_events(actor_id,event_type,journal_id,reference_id,event_data)
    values(p_actor,'case_finalization_executed',v_primary_journal_id,p_case_id,
      pg_catalog.jsonb_build_object('case_id',p_case_id,'decision_version',v_decision.decision_version,
        'outcome',v_decision.outcome,'execution_status','executed',
        'refund_status',case when v_payable_id is null then 'not_applicable' else 'authorized' end,
        'gross_principal_kobo',v_decision.gross_principal_kobo::text,
        'worker_award_gross_kobo',v_decision.worker_award_gross_kobo::text,
        'poster_refund_gross_kobo',v_decision.poster_refund_gross_kobo::text,
        'commission_kobo',v_decision.commission_kobo::text,
        'worker_net_kobo',v_decision.worker_net_kobo::text));

  v_response:=pg_catalog.jsonb_build_object(
    'case_id',p_case_id,'status','closed','version',p_expected_case_version+1,
    'finalization_status','executed','decision_version',v_decision.decision_version,
    'outcome',v_decision.outcome,'gross_principal_kobo',v_decision.gross_principal_kobo::text,
    'worker_award_gross_kobo',v_decision.worker_award_gross_kobo::text,
    'poster_refund_gross_kobo',v_decision.poster_refund_gross_kobo::text,
    'retained_hold_gross_kobo',v_decision.retained_hold_gross_kobo::text,
    'commission_kobo',v_decision.commission_kobo::text,'worker_net_kobo',v_decision.worker_net_kobo::text,
    'refund_status',case when v_payable_id is null then 'not_applicable' else 'authorized' end
  );
  insert into app_private.case_command_idempotency(actor_id,command_name,idempotency_key,request_sha256,response)
    values(p_actor,'finalize_case',p_idempotency_key,v_request_hash,v_response);
  return v_response;
end;
$function$;

create function public.server_finalize_case_for_actor(
  p_actor uuid,p_case_id uuid,p_decision_version integer,p_expected_case_version integer,
  p_auth_aal text,p_idempotency_key uuid
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.finalize_case_for_actor_at(
    p_actor,p_case_id,p_decision_version,p_expected_case_version,p_auth_aal,
    p_idempotency_key,pg_catalog.clock_timestamp())
$function$;

-- Serialize durable appeal receipt insertion with execution. The receipt RPC
-- takes this lock before assigning database receipt time; finalization takes it
-- only after the case row, so a timely committed receipt cannot be skipped.
create or replace function public.server_record_case_appeal_receipt_for_actor(
  p_actor uuid,p_case_id uuid,p_statement text,p_auth_aal text,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path = '' as $function$
begin
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'case_appeal_receipt_finalization:'||p_case_id::text,428118));
  return app_private.record_case_appeal_receipt_at_for_actor(
    p_actor,p_case_id,p_statement,p_auth_aal,p_idempotency_key,pg_catalog.clock_timestamp());
end;
$function$;

-- Participant history remains available after closure with only the public
-- final outcome and truthful refund authorization state.
create or replace function app_private.get_assignment_case_for_actor(p_actor uuid,p_case_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare v_result jsonb; v_appeal jsonb; v_role text; v_finalization jsonb;
begin
  if p_actor is null or p_case_id is null then
    raise exception using errcode='22023',message='invalid_case_query';
  end if;
  v_result:=app_private.case_participant_projection(p_case_id,p_actor);
  if v_result is null then raise exception using errcode='P0002',message='case_not_found'; end if;
  select case when a.worker_id=p_actor then 'worker' else 'poster' end into v_role
    from app_private.assignment_cases c join app_private.assignments a using(assignment_id)
    where c.case_id=p_case_id;
  v_result:=v_result||app_private.case_investigation_projection(p_case_id,p_actor,false)||
    pg_catalog.jsonb_build_object('participant_role',v_role);
  v_appeal:=app_private.case_appeal_participant_projection(p_case_id,p_actor);
  if v_appeal is not null then
    v_result:=v_result||pg_catalog.jsonb_build_object('appeal',v_appeal);
    if v_appeal->>'status'='under_review' then
      v_result:=v_result||pg_catalog.jsonb_build_object('status','appeal');
    end if;
  end if;
  select pg_catalog.jsonb_build_object(
    'status','executed','decision_version',f.decision_version,'outcome',f.outcome,
    'gross_principal_kobo',f.gross_principal_kobo::text,
    'worker_award_gross_kobo',f.worker_award_gross_kobo::text,
    'poster_refund_gross_kobo',f.poster_refund_gross_kobo::text,
    'retained_hold_gross_kobo',f.retained_hold_gross_kobo::text,
    'commission_kobo',f.commission_kobo::text,'worker_net_kobo',f.worker_net_kobo::text,
    'refund_status',case when f.refund_payable_id is null then 'not_applicable' else 'authorized' end,
    'executed_at',f.executed_at
  ) into v_finalization from app_private.assignment_case_finalizations f where f.case_id=p_case_id;
  v_result:=v_result||pg_catalog.jsonb_build_object('finalization',v_finalization);
  return v_result;
end;
$function$;

create function app_private.job_funded_slots_completed(p_job_id uuid)
returns boolean language sql stable security definer set search_path = '' as $function$
  select exists(select 1 from app_private.principal_allocations p
    join app_private.assignments a on a.assignment_id=p.assignment_id
      and a.allocation_id=p.allocation_id and a.work_state='completed'
    where p.job_id=p_job_id and p.status='worker_earnings_allocated')
    and not exists(select 1 from app_private.principal_allocations p
      where p.job_id=p_job_id and (p.status<>'worker_earnings_allocated' or exists(
        select 1 from app_private.allocation_refund_payables r
        where r.allocation_id=p.allocation_id and r.status='authorized'
      )))
$function$;

do $migration$
declare v_definition text; v_old text; v_new text;
begin
  v_old:='case when a.slots_remaining = 0 then ''filled''';
  v_new:='case when app_private.job_funded_slots_completed(j.job_id) then ''completed'' when a.slots_remaining = 0 then ''filled''';
  v_definition:=pg_catalog.pg_get_functiondef(
    'app_private.get_my_funded_job_history(uuid,timestamp with time zone,uuid,smallint)'::regprocedure);
  if pg_catalog.strpos(v_definition,v_old)=0 then raise exception 'case_job_history_completion_patch_mismatch'; end if;
  execute pg_catalog.replace(v_definition,v_old,v_new);
  v_definition:=pg_catalog.pg_get_functiondef(
    'app_private.get_my_funded_job_detail(uuid,uuid)'::regprocedure);
  if pg_catalog.strpos(v_definition,v_old)=0 then raise exception 'case_job_detail_completion_patch_mismatch'; end if;
  execute pg_catalog.replace(v_definition,v_old,v_new);
end;
$migration$;

revoke all on table app_private.assignment_case_finalizations,
  app_private.assignment_case_award_authorizations from public,anon,authenticated,service_role;
revoke all on function app_private.finalize_case_for_actor_at(uuid,uuid,integer,integer,text,uuid,timestamp with time zone),
  app_private.job_funded_slots_completed(uuid) from public,anon,authenticated,service_role;
revoke all on function public.server_finalize_case_for_actor(uuid,uuid,integer,integer,text,uuid)
  from public,anon,authenticated,service_role;
grant execute on function app_private.finalize_case_for_actor_at(uuid,uuid,integer,integer,text,uuid,timestamp with time zone)
  to postgres;
grant execute on function public.server_finalize_case_for_actor(uuid,uuid,integer,integer,text,uuid)
  to service_role;

commit;
