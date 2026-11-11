begin;

-- Step 6 publishes an approved decision atomically with both durable notices,
-- then records appeals before taking any case/allocation lock.
alter table app_private.staff_grants drop constraint staff_grants_capability_check;
alter table app_private.staff_grants add constraint staff_grants_capability_check check (capability in (
  'verification_review','identity_suspend','identity_unsuspend','identity_correct_user_type',
  'identity_staff_admin','dispute_review','financial_initiate','financial_approve',
  'financial_inspect','case_senior_signoff','case_appeal_review'
));

alter table app_private.marketplace_outbox drop constraint marketplace_outbox_event_type_check;
alter table app_private.marketplace_outbox add constraint marketplace_outbox_event_type_check check (event_type in (
  'job.draft_created','job.draft_updated','job.funding_started','job.funded',
  'job.funding_failed','job.funding_exception','job.application_created',
  'job.application_accepted','job.application_rejected','job.application_withdrawn',
  'job.application_closed','job.message_created','job.assignment_started',
  'job.assignment_submitted','job.assignment_completed','job.assignment_hold_opened',
  'job.slot_refund_authorized','job.assignment_cancellation_requested',
  'job.assignment_cancellation_completed','job.assignment_abandoned',
  'job.assignment_case_reviewer_assigned','job.assignment_case_investigation_updated',
  'job.assignment_case_decision_notified','job.assignment_case_updated'
));

alter table app_private.in_app_notifications drop constraint in_app_notifications_notification_type_check;
alter table app_private.in_app_notifications add constraint in_app_notifications_notification_type_check check (notification_type in (
  'application_received','application_accepted','application_rejected','application_withdrawn',
  'application_closed','new_message','assignment_started','assignment_submitted',
  'assignment_completed','assignment_hold_opened','assignment_case_updated',
  'assignment_case_decision','withdrawal_requested','withdrawal_processing',
  'withdrawal_unknown','withdrawal_paid','withdrawal_failed','withdrawal_reversed',
  'withdrawal_exception','slot_refund_authorized','assignment_cancellation_requested',
  'assignment_cancellation_completed','assignment_abandoned'
));

alter table app_private.assignment_case_events drop constraint assignment_case_events_event_type_check;
alter table app_private.assignment_case_events add constraint assignment_case_events_event_type_check check (event_type in (
  'case_opened','reviewer_assigned','reviewer_reassigned','status_changed',
  'participant_response','evidence_added','decision_notified','appeal_opened',
  'case_closed','case_triaged','contact_attempt_recorded','information_requested',
  'fact_verification_recorded','nonresponse_assessed','case_decision_proposed',
  'case_decision_approved','case_decision_nonresponse_signed',
  'appeal_reviewer_assigned','appeal_decision_recorded'
));

alter table app_private.assignment_case_access_audit drop constraint assignment_case_access_audit_action_check;
alter table app_private.assignment_case_access_audit add constraint assignment_case_access_audit_action_check check (action in (
  'case_read','case_queue_read','case_assigned','case_reassigned','case_triaged',
  'case_contact_logged','case_information_requested','case_participant_responded',
  'case_fact_recorded','case_internal_note_added','case_nonresponse_assessed',
  'case_nonresponse_signed_off','case_decision_proposed','case_decision_approved',
  'case_decision_nonresponse_signed','case_appeal_received',
  'case_appeal_reviewer_assigned','case_appeal_evidence_requested','case_appeal_evidence_closed',
  'case_appeal_evidence_responded','case_appeal_review_decided'
));

alter table app_private.case_command_idempotency drop constraint case_command_idempotency_command_name_check;
alter table app_private.case_command_idempotency add constraint case_command_idempotency_command_name_check check (command_name in (
  'assign_case_reviewer','triage_case','log_case_contact_attempt','request_case_information',
  'respond_to_case_information','record_case_fact','add_case_internal_note',
  'assess_case_nonresponse','signoff_case_nonresponse','begin_case_file_upload',
  'propose_case_decision','approve_case_decision','signoff_decision_nonresponse',
  'record_case_appeal_receipt','process_case_appeal_receipt','assign_case_appeal_reviewer',
  'request_case_appeal_evidence','respond_case_appeal_evidence',
  'close_case_appeal_evidence_nonresponse','review_case_appeal'
));

create table app_private.assignment_case_decision_publications (
  case_id uuid primary key references app_private.assignment_cases(case_id) on delete restrict,
  decision_id uuid not null references app_private.assignment_case_decision_versions(decision_id) on delete restrict,
  decision_version integer not null check (decision_version>0),
  decision_sha256 bytea not null check (pg_catalog.octet_length(decision_sha256)=32),
  initial_reviewer_id uuid not null references auth.users(id) on delete restrict,
  marketplace_event_id uuid not null unique references app_private.marketplace_outbox(event_id) on delete restrict,
  worker_notification_id uuid not null unique references app_private.in_app_notifications(notification_id) on delete restrict,
  poster_notification_id uuid not null unique references app_private.in_app_notifications(notification_id) on delete restrict,
  durable_notified_at timestamptz not null,
  appeal_deadline_at timestamptz not null,
  created_at timestamptz not null default pg_catalog.now(),
  foreign key(decision_id,decision_version,decision_sha256)
    references app_private.assignment_case_decision_versions(decision_id,decision_version,decision_sha256),
  check (appeal_deadline_at=durable_notified_at+interval '72 hours'),
  check (worker_notification_id<>poster_notification_id)
);

create table app_private.assignment_case_appeal_receipts (
  appeal_id uuid primary key default pg_catalog.gen_random_uuid(),
  case_id uuid not null,
  initial_decision_id uuid not null,
  initial_decision_version integer not null check (initial_decision_version>0),
  initial_decision_sha256 bytea not null check (pg_catalog.octet_length(initial_decision_sha256)=32),
  actor_id uuid not null references auth.users(id) on delete restrict,
  party_role text not null check (party_role in ('worker','poster')),
  statement text not null check (char_length(btrim(statement)) between 20 and 2000),
  received_at timestamptz not null,
  idempotency_key uuid not null,
  request_sha256 bytea not null check (pg_catalog.octet_length(request_sha256)=32),
  unique(case_id,initial_decision_version,actor_id),
  unique(actor_id,idempotency_key)
);
create index assignment_case_appeal_receipts_case_idx
  on app_private.assignment_case_appeal_receipts(case_id,received_at,appeal_id);

-- This row is appended only after the receipt above has committed. Its case FK
-- and row locks therefore cannot delay the authoritative appeal timestamp.
create table app_private.assignment_case_appeal_receipt_applications (
  appeal_id uuid primary key references app_private.assignment_case_appeal_receipts(appeal_id) on delete restrict,
  case_id uuid not null references app_private.assignment_cases(case_id) on delete restrict,
  marketplace_event_id uuid not null references app_private.marketplace_outbox(event_id) on delete restrict,
  applied_at timestamptz not null default pg_catalog.clock_timestamp()
);

create table app_private.assignment_case_appeal_reviewer_assignments (
  assignment_id uuid primary key default pg_catalog.gen_random_uuid(),
  case_id uuid not null references app_private.assignment_cases(case_id) on delete restrict,
  assignment_version integer not null check (assignment_version>0),
  reviewer_id uuid not null references auth.users(id) on delete restrict,
  appeal_grant_id uuid not null references app_private.staff_grants(grant_id) on delete restrict,
  assigned_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default pg_catalog.now(),
  unique(case_id,assignment_version)
);
create index assignment_case_appeal_reviewer_current_idx
  on app_private.assignment_case_appeal_reviewer_assignments(case_id,assignment_version desc);

create table app_private.assignment_case_appeal_request_nonresponse_closures (
  request_id uuid primary key references app_private.assignment_case_information_requests(request_id) on delete restrict,
  assessment_id uuid not null references app_private.assignment_case_nonresponse_assessments(assessment_id) on delete restrict,
  signoff_id uuid not null references app_private.assignment_case_nonresponse_signoffs(signoff_id) on delete restrict,
  senior_id uuid not null references auth.users(id) on delete restrict,
  substantive_reasoning text not null check (char_length(btrim(substantive_reasoning)) between 100 and 2000),
  created_at timestamptz not null default pg_catalog.clock_timestamp()
);

alter table app_private.assignment_case_information_requests
  add column appeal_id uuid references app_private.assignment_case_appeal_receipts(appeal_id) on delete restrict,
  add column appeal_request_version integer check (appeal_request_version is null or appeal_request_version>0),
  add constraint case_information_request_appeal_scope check (
    (request_scope='appeal' and appeal_id is not null and appeal_request_version is not null)
    or (request_scope='investigation' and appeal_id is null and appeal_request_version is null)
  );
create unique index assignment_case_appeal_evidence_request_version_idx
  on app_private.assignment_case_information_requests(appeal_id,appeal_request_version)
  where appeal_id is not null;

create table app_private.assignment_case_appeal_review_versions (
  appeal_id uuid not null references app_private.assignment_case_appeal_receipts(appeal_id) on delete restrict,
  case_id uuid not null references app_private.assignment_cases(case_id) on delete restrict,
  review_version integer not null check (review_version>0),
  reviewer_id uuid not null references auth.users(id) on delete restrict,
  action text not null check (action in ('request_evidence','upheld','changed')),
  applied_decision_version integer not null check (applied_decision_version>0),
  decision_sha256 bytea not null check (pg_catalog.octet_length(decision_sha256)=32),
  public_explanation text check (public_explanation is null or char_length(btrim(public_explanation)) between 20 and 2000),
  evidence_snapshot jsonb not null check (pg_catalog.jsonb_typeof(evidence_snapshot)='object'
    and pg_catalog.octet_length(evidence_snapshot::text)<=1048576),
  evidence_snapshot_sha256 bytea not null check (pg_catalog.octet_length(evidence_snapshot_sha256)=32),
  request_id uuid references app_private.assignment_case_information_requests(request_id) on delete restrict,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  primary key(appeal_id,review_version),
  check ((action='request_evidence' and request_id is not null and public_explanation is null)
    or (action in ('upheld','changed') and request_id is null and public_explanation is not null))
);
create index assignment_case_appeal_reviews_case_idx
  on app_private.assignment_case_appeal_review_versions(case_id,created_at,appeal_id,review_version);

create function app_private.reject_appeal_history_mutation()
returns trigger language plpgsql set search_path = '' as $function$
begin
  raise exception using errcode='55000',message='case_appeal_history_is_immutable';
end;
$function$;
create trigger assignment_case_appeal_receipts_immutable before update or delete
on app_private.assignment_case_appeal_receipts for each row
execute function app_private.reject_appeal_history_mutation();
create trigger assignment_case_appeal_receipt_applications_immutable before update or delete
on app_private.assignment_case_appeal_receipt_applications for each row
execute function app_private.reject_appeal_history_mutation();
create trigger assignment_case_appeal_reviewer_assignments_immutable before update or delete
on app_private.assignment_case_appeal_reviewer_assignments for each row
execute function app_private.reject_appeal_history_mutation();
create trigger assignment_case_appeal_reviews_immutable before update or delete
on app_private.assignment_case_appeal_review_versions for each row
execute function app_private.reject_appeal_history_mutation();
create trigger assignment_case_decision_publications_immutable before update or delete
on app_private.assignment_case_decision_publications for each row
execute function app_private.reject_appeal_history_mutation();
create trigger assignment_case_appeal_request_closures_immutable before update or delete
on app_private.assignment_case_appeal_request_nonresponse_closures for each row
execute function app_private.reject_appeal_history_mutation();

create function app_private.guard_case_information_request_version()
returns trigger language plpgsql set search_path = '' as $function$
begin
  if tg_op='DELETE' or new.request_id is distinct from old.request_id
     or new.case_id is distinct from old.case_id
     or new.target_party_role is distinct from old.target_party_role
     or new.request_kind is distinct from old.request_kind
     or new.request_scope is distinct from old.request_scope
     or new.request_number is distinct from old.request_number
     or new.prompt is distinct from old.prompt
     or new.created_by is distinct from old.created_by
     or new.created_at is distinct from old.created_at
     or new.appeal_id is distinct from old.appeal_id
     or new.appeal_request_version is distinct from old.appeal_request_version
     or not (old.status='open' and new.status in ('responded','closed')
       and new.status_changed_at is not null) then
    raise exception using errcode='55000',message='case_information_request_version_is_immutable';
  end if;
  return new;
end;
$function$;
create trigger assignment_case_information_request_version_guard
before update or delete on app_private.assignment_case_information_requests
for each row execute function app_private.guard_case_information_request_version();

create function app_private.publish_case_decision_after_second_approval()
returns trigger language plpgsql security definer set search_path = '' as $function$
declare
  v_decision app_private.assignment_case_decision_versions%rowtype;
  v_case app_private.assignment_cases%rowtype;
  v_assignment app_private.assignments%rowtype;
  v_notified_at timestamptz;
  v_deadline timestamptz;
  v_event uuid;
  v_worker_notice uuid;
  v_poster_notice uuid;
  v_seq integer;
  v_summary jsonb;
begin
  if new.approval_number<>2 or exists(
      select 1 from app_private.assignment_case_decision_publications p where p.case_id=(
        select d.case_id from app_private.assignment_case_decision_versions d where d.decision_id=new.decision_id)) then
    return new;
  end if;
  select * into v_decision from app_private.assignment_case_decision_versions
    where decision_id=new.decision_id and decision_version=new.decision_version
      and decision_sha256=new.decision_sha256;
  if not found then raise exception using errcode='P0001',message='stale_state'; end if;
  select * into v_case from app_private.assignment_cases where case_id=v_decision.case_id;
  select * into v_assignment from app_private.assignments where assignment_id=v_case.assignment_id;
  if v_case.lifecycle_status<>'verifying'
     or (select count(*) from app_private.assignment_case_decision_approvals ap
       join app_private.staff_grants g on g.grant_id=ap.financial_grant_id and g.user_id=ap.approver_id
         and g.capability='financial_approve' and g.revoked_at is null
       join app_private.identity_accounts ia on ia.user_id=ap.approver_id and ia.account_status='active'
       where ap.decision_id=v_decision.decision_id and ap.approval_number=1
         and ap.decision_sha256=v_decision.decision_sha256
         and ap.approver_id not in (v_assignment.worker_id,v_assignment.poster_id)
         and app_private.case_staff_principal_is_human(ap.approver_id))<>1
     or (select count(*) from app_private.assignment_case_decision_approvals ap
       join app_private.staff_grants g on g.grant_id=ap.financial_grant_id and g.user_id=ap.approver_id
         and g.capability='financial_approve' and g.revoked_at is null
       join app_private.identity_accounts ia on ia.user_id=ap.approver_id and ia.account_status='active'
       where ap.decision_id=v_decision.decision_id and ap.decision_sha256=v_decision.decision_sha256
         and ap.approver_id not in (v_assignment.worker_id,v_assignment.poster_id)
         and app_private.case_staff_principal_is_human(ap.approver_id))<>2
     or not exists(select 1 from app_private.assignment_case_decision_nonresponse_signoffs s
       join app_private.staff_grants g on g.grant_id=s.senior_grant_id and g.user_id=s.senior_id
         and g.capability='case_senior_signoff' and g.revoked_at is null
       join app_private.identity_accounts ia on ia.user_id=s.senior_id and ia.account_status='active'
       where s.decision_id=v_decision.decision_id and s.decision_sha256=v_decision.decision_sha256
         and s.assessment_id=v_decision.nonresponse_assessment_id
         and s.senior_id not in (v_assignment.worker_id,v_assignment.poster_id)
         and s.senior_id<>v_decision.proposed_by
         and app_private.case_staff_principal_is_human(s.senior_id))
       and v_decision.nonresponse_assessment_id is not null then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  v_notified_at:=pg_catalog.clock_timestamp();
  v_deadline:=v_notified_at+interval '72 hours';
  v_summary:=pg_catalog.jsonb_build_object(
    'decision_version',v_decision.decision_version,'outcome',v_decision.outcome,
    'reason_code',v_decision.reason_code,'public_explanation',v_decision.public_explanation,
    'gross_principal_kobo',v_decision.gross_principal_kobo::text,
    'worker_award_gross_kobo',v_decision.worker_award_gross_kobo::text,
    'poster_refund_gross_kobo',v_decision.poster_refund_gross_kobo::text,
    'retained_hold_gross_kobo',v_decision.retained_hold_gross_kobo::text,
    'commission_kobo',v_decision.commission_kobo::text,'worker_net_kobo',v_decision.worker_net_kobo::text,
    'notified_at',v_notified_at,'appeal_deadline_at',v_deadline);
  v_event:=pg_catalog.gen_random_uuid();
  insert into app_private.marketplace_outbox(
    event_id,actor_id,job_id,event_type,terms_version,payload,created_at
  ) values(v_event,null,v_assignment.job_id,'job.assignment_case_decision_notified',
    v_assignment.terms_version,pg_catalog.jsonb_build_object('case_id',v_case.case_id,
      'event','decision_notified','decision',v_summary),v_notified_at);
  insert into app_private.in_app_notifications(
    event_id,recipient_id,notification_type,created_at
  ) values(v_event,v_assignment.worker_id,'assignment_case_decision',v_notified_at)
    returning notification_id into v_worker_notice;
  insert into app_private.in_app_notifications(
    event_id,recipient_id,notification_type,created_at
  ) values(v_event,v_assignment.poster_id,'assignment_case_decision',v_notified_at)
    returning notification_id into v_poster_notice;
  select coalesce(max(sequence),0)+1 into v_seq from app_private.assignment_case_events
    where case_id=v_case.case_id;
  insert into app_private.assignment_case_events(
    case_id,sequence,actor_id,audience,event_type,payload,created_at
  ) values(v_case.case_id,v_seq,null,'participants','decision_notified',v_summary,v_notified_at);
  insert into app_private.assignment_case_decision_publications(
    case_id,decision_id,decision_version,decision_sha256,initial_reviewer_id,
    marketplace_event_id,worker_notification_id,poster_notification_id,
    durable_notified_at,appeal_deadline_at
  ) values(v_case.case_id,v_decision.decision_id,v_decision.decision_version,
    v_decision.decision_sha256,v_decision.proposed_by,v_event,v_worker_notice,v_poster_notice,
    v_notified_at,v_deadline);
  return new;
end;
$function$;
create trigger assignment_case_decision_publish_after_approval
after insert on app_private.assignment_case_decision_approvals
for each row execute function app_private.publish_case_decision_after_second_approval();

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
     or new.opened_at is distinct from old.opened_at or new.closed_at is distinct from old.closed_at
     or new.version<>old.version+1 then
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
       or new.reviewer_id=(select initial_reviewer_id from app_private.assignment_case_decision_publications
         where case_id=old.case_id) then
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
  new.updated_at:=pg_catalog.now();
  return new;
end;
$function$;

create function app_private.lock_case_appeal_reviewer_scope(p_actor uuid,p_auth_aal text)
returns boolean language plpgsql security definer set search_path = '' as $function$
begin
  if p_actor is null or p_auth_aal is distinct from 'aal2'
     or not app_private.case_staff_principal_is_human(p_actor) then return false; end if;
  perform 1 from app_private.identity_accounts a where a.user_id=p_actor
    and a.account_status='active' for share;
  if not found then return false; end if;
  perform 1 from app_private.staff_grants g where g.user_id=p_actor
    and g.capability='case_appeal_review' and g.revoked_at is null for share;
  return found;
end;
$function$;

-- A receipt deliberately has no case or publication FK and no case-row lock.
-- This first RPC commits before the handler applies the receipt under case locks.
create function app_private.record_case_appeal_receipt_at_for_actor(
  p_actor uuid,p_case_id uuid,p_statement text,p_auth_aal text,p_idempotency_key uuid,
  p_received_at timestamptz
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_pub app_private.assignment_case_decision_publications%rowtype;
  v_assignment app_private.assignments%rowtype;
  v_receipt app_private.assignment_case_appeal_receipts%rowtype;
  v_role text;
  v_account_status text;
  v_hash bytea;
begin
  if p_actor is null or p_case_id is null or p_idempotency_key is null
     or p_received_at is null or p_auth_aal is null or p_auth_aal not in ('aal1','aal2')
     or pg_catalog.char_length(pg_catalog.btrim(coalesce(p_statement,''))) not between 20 and 2000
     or p_statement ~* '(https?://|www[.]|[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12})' then
    raise exception using errcode='22023',message='invalid_case_appeal';
  end if;
  v_hash:=extensions.digest(pg_catalog.jsonb_build_object(
    'case_id',p_case_id,'statement',pg_catalog.btrim(p_statement))::text,'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    p_actor::text||':record_case_appeal_receipt:'||p_idempotency_key::text,428118));
  select * into v_receipt from app_private.assignment_case_appeal_receipts
    where actor_id=p_actor and idempotency_key=p_idempotency_key;
  if found then
    if v_receipt.request_sha256<>v_hash then
      raise exception using errcode='23505',message='idempotency_conflict';
    end if;
    return pg_catalog.jsonb_build_object('appeal_id',v_receipt.appeal_id,'received',true,
      'received_at',v_receipt.received_at,'replayed',true);
  end if;
  select * into v_pub from app_private.assignment_case_decision_publications where case_id=p_case_id;
  if not found then raise exception using errcode='P0002',message='case_not_found'; end if;
  if p_received_at>=v_pub.appeal_deadline_at then
    raise exception using errcode='P0001',message='appeal_window_closed';
  end if;
  select a.* into v_assignment from app_private.assignments a
    join app_private.assignment_cases c using(assignment_id) where c.case_id=p_case_id;
  v_role:=case when p_actor=v_assignment.worker_id then 'worker'
    when p_actor=v_assignment.poster_id then 'poster' else null end;
  select account_status into v_account_status from app_private.identity_accounts
    where user_id=p_actor;
  if v_role is null or v_account_status is null or v_account_status not in ('active','suspended') then
    raise exception using errcode='42501',message='case_access_denied';
  end if;
  insert into app_private.assignment_case_appeal_receipts(
    case_id,initial_decision_id,initial_decision_version,initial_decision_sha256,
    actor_id,party_role,statement,received_at,idempotency_key,request_sha256
  ) values(p_case_id,v_pub.decision_id,v_pub.decision_version,v_pub.decision_sha256,
    p_actor,v_role,pg_catalog.btrim(p_statement),p_received_at,p_idempotency_key,v_hash)
  returning * into v_receipt;
  return pg_catalog.jsonb_build_object('appeal_id',v_receipt.appeal_id,'received',true,
    'received_at',v_receipt.received_at,'replayed',false);
end;
$function$;

create function app_private.process_case_appeal_receipt_for_actor(
  p_actor uuid,p_appeal_id uuid,p_auth_aal text
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_receipt app_private.assignment_case_appeal_receipts%rowtype;
  v_case app_private.assignment_cases%rowtype;
  v_assignment app_private.assignments%rowtype;
  v_pub app_private.assignment_case_decision_publications%rowtype;
  v_event uuid;
  v_seq integer;
  v_status text;
  v_account_status text;
begin
  if p_actor is null or p_appeal_id is null or p_auth_aal is null or p_auth_aal not in ('aal1','aal2') then
    raise exception using errcode='22023',message='invalid_case_appeal';
  end if;
  select * into v_receipt from app_private.assignment_case_appeal_receipts
    where appeal_id=p_appeal_id and actor_id=p_actor;
  if not found then raise exception using errcode='42501',message='case_access_denied'; end if;
  select * into v_case from app_private.assignment_cases where case_id=v_receipt.case_id for update;
  if not found then raise exception using errcode='P0002',message='case_not_found'; end if;
  select * into v_assignment from app_private.assignments where assignment_id=v_case.assignment_id;
  select * into v_pub from app_private.assignment_case_decision_publications where case_id=v_case.case_id;
  select account_status into v_account_status from app_private.identity_accounts where user_id=p_actor;
  if v_pub.decision_version<>v_receipt.initial_decision_version
     or v_pub.decision_sha256<>v_receipt.initial_decision_sha256
     or v_receipt.received_at>=v_pub.appeal_deadline_at
     or v_account_status is null or v_account_status not in ('active','suspended')
     or (case when p_actor=v_assignment.worker_id then 'worker'
          when p_actor=v_assignment.poster_id then 'poster' else null end) is distinct from v_receipt.party_role then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  if exists(select 1 from app_private.assignment_case_appeal_receipt_applications
    where appeal_id=p_appeal_id) then
    return pg_catalog.jsonb_build_object('case_id',v_case.case_id,
      'status',v_case.lifecycle_status,'version',v_case.version,'received',true,'applied',true);
  end if;
  if v_case.lifecycle_status not in ('decision_made','appeal','verifying') then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  v_status:=case when v_case.lifecycle_status='decision_made' then 'appeal' else v_case.lifecycle_status end;
  perform pg_catalog.set_config('app.assignment_case_transition','submit_case_appeal',true);
  update app_private.assignment_cases set lifecycle_status=v_status,version=version+1
    where case_id=v_case.case_id;
  perform pg_catalog.set_config('app.assignment_case_transition','',true);
  v_event:=app_private.append_marketplace_event(p_actor,v_assignment.job_id,
    'job.assignment_case_updated',v_assignment.terms_version,
    pg_catalog.jsonb_build_object('case_id',v_case.case_id,'update','appeal_received'));
  perform app_private.add_in_app_notification(v_event,v_assignment.worker_id,'assignment_case_updated');
  perform app_private.add_in_app_notification(v_event,v_assignment.poster_id,'assignment_case_updated');
  select coalesce(max(sequence),0)+1 into v_seq from app_private.assignment_case_events where case_id=v_case.case_id;
  insert into app_private.assignment_case_events(case_id,sequence,actor_id,audience,event_type,payload)
    values(v_case.case_id,v_seq,p_actor,'participants','appeal_opened',
      pg_catalog.jsonb_build_object('update','An appeal was received and is being reviewed.'));
  insert into app_private.assignment_case_access_audit(case_id,actor_id,action)
    values(v_case.case_id,p_actor,'case_appeal_received');
  insert into app_private.assignment_case_appeal_receipt_applications(appeal_id,case_id,marketplace_event_id)
    values(p_appeal_id,v_case.case_id,v_event);
  return pg_catalog.jsonb_build_object('case_id',v_case.case_id,'status',v_status,
    'version',v_case.version+1,'received',true,'applied',true);
end;
$function$;

create function app_private.case_appeal_finalization_block_reason(
  p_case_id uuid,p_as_of timestamptz default null
) returns text language plpgsql security definer set search_path = '' as $function$
declare v_now timestamptz:=coalesce(p_as_of,pg_catalog.clock_timestamp());
begin
  if not exists(select 1 from app_private.assignment_case_decision_publications p where p.case_id=p_case_id) then
    return 'decision_not_durably_notified';
  end if;
  if v_now<(select appeal_deadline_at from app_private.assignment_case_decision_publications where case_id=p_case_id) then
    return 'appeal_window_open';
  end if;
  if exists(select 1 from app_private.assignment_case_appeal_receipts a
    where a.case_id=p_case_id and a.received_at<
      (select appeal_deadline_at from app_private.assignment_case_decision_publications where case_id=p_case_id)
      and not exists(select 1 from app_private.assignment_case_appeal_review_versions r
        where r.appeal_id=a.appeal_id and r.action in ('upheld','changed'))) then
    return 'timely_appeal_unresolved';
  end if;
  if exists(select 1 from app_private.assignment_case_information_requests r
    where r.case_id=p_case_id and r.request_scope='appeal' and r.status='open'
      and exists(select 1 from app_private.assignment_case_appeal_receipts a where a.appeal_id=r.appeal_id)
      and not exists(select 1 from app_private.assignment_case_appeal_review_versions v
        where v.appeal_id=r.appeal_id and v.action in ('upheld','changed'))) then
    return 'appeal_evidence_request_open';
  end if;
  return null;
end;
$function$;

create function app_private.case_effective_approved_decision(p_case_id uuid)
returns app_private.assignment_case_decision_versions
language sql stable security definer set search_path = '' as $function$
  select d.* from app_private.assignment_case_decision_versions d
  where d.case_id=p_case_id and (
    (d.decision_version=(select p.decision_version from app_private.assignment_case_decision_publications p where p.case_id=p_case_id))
    or exists(select 1 from app_private.assignment_case_appeal_review_versions r
      where r.case_id=p_case_id and r.action='changed' and r.applied_decision_version=d.decision_version
        and r.decision_sha256=d.decision_sha256)
  ) order by d.decision_version desc limit 1
$function$;

create function app_private.assign_case_appeal_reviewer_for_actor(
  p_actor uuid,p_case_id uuid,p_reviewer_id uuid,p_auth_aal text,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_case app_private.assignment_cases%rowtype;
  v_assignment app_private.assignments%rowtype;
  v_pub app_private.assignment_case_decision_publications%rowtype;
  v_old app_private.assignment_case_appeal_reviewer_assignments%rowtype;
  v_grant uuid;
  v_actor_account text;
  v_target_account text;
  v_hash bytea;
  v_existing app_private.case_command_idempotency%rowtype;
  v_version integer;
  v_event uuid;
  v_seq integer;
  v_result jsonb;
begin
  if p_actor is null or p_case_id is null or p_reviewer_id is null or p_idempotency_key is null
     or p_auth_aal is distinct from 'aal2' then
    raise exception using errcode='22023',message='invalid_case_command';
  end if;
  v_hash:=extensions.digest(pg_catalog.jsonb_build_object('case_id',p_case_id,'reviewer_id',p_reviewer_id)::text,'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    p_actor::text||':assign_case_appeal_reviewer:'||p_idempotency_key::text,428118));
  select * into v_existing from app_private.case_command_idempotency
    where actor_id=p_actor and command_name='assign_case_appeal_reviewer' and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.request_sha256<>v_hash then raise exception using errcode='23505',message='idempotency_conflict'; end if;
    return v_existing.response;
  end if;
  select * into v_case from app_private.assignment_cases where case_id=p_case_id for update;
  if not found then raise exception using errcode='P0002',message='case_not_found'; end if;
  select * into v_assignment from app_private.assignments where assignment_id=v_case.assignment_id;
  select * into v_pub from app_private.assignment_case_decision_publications where case_id=p_case_id;
  select account_status into v_actor_account from app_private.identity_accounts where user_id=p_actor for share;
  select g.grant_id into v_grant from app_private.staff_grants g
    where g.user_id=p_actor and g.capability='dispute_review' and g.revoked_at is null for share;
  if v_actor_account is distinct from 'active' or p_actor in (v_assignment.worker_id,v_assignment.poster_id)
     or v_grant is null or not app_private.case_staff_principal_is_human(p_actor) then
    raise exception using errcode='42501',message='case_access_denied';
  end if;
  select account_status into v_target_account from app_private.identity_accounts where user_id=p_reviewer_id for share;
  select g.grant_id into v_grant from app_private.staff_grants g
    where g.user_id=p_reviewer_id and g.capability='case_appeal_review' and g.revoked_at is null for share;
  if v_target_account is distinct from 'active' or v_grant is null
     or p_reviewer_id in (v_assignment.worker_id,v_assignment.poster_id,v_pub.initial_reviewer_id)
     or not app_private.case_staff_principal_is_human(p_reviewer_id)
     or not exists(select 1 from app_private.staff_grants g
       where g.user_id=p_reviewer_id and g.capability='dispute_review' and g.revoked_at is null)
     or not exists(select 1 from app_private.staff_grants g
       where g.user_id=p_reviewer_id and g.capability='financial_approve' and g.revoked_at is null) then
    raise exception using errcode='42501',message='case_access_denied';
  end if;
  if v_case.lifecycle_status not in ('appeal','verifying','decision_made') or not exists(
    select 1 from app_private.assignment_case_appeal_receipts a where a.case_id=p_case_id
      and a.received_at<v_pub.appeal_deadline_at and not exists(
        select 1 from app_private.assignment_case_appeal_review_versions r
        where r.appeal_id=a.appeal_id and r.action in ('upheld','changed'))) then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  select * into v_old from app_private.assignment_case_appeal_reviewer_assignments
    where case_id=p_case_id order by assignment_version desc limit 1;
  if v_old.reviewer_id=p_reviewer_id then
    v_result:=pg_catalog.jsonb_build_object('case_id',p_case_id,'status',v_case.lifecycle_status,
      'version',v_case.version,'assigned',true);
  else
    select coalesce(max(assignment_version),0)+1 into v_version
      from app_private.assignment_case_appeal_reviewer_assignments where case_id=p_case_id;
    insert into app_private.assignment_case_appeal_reviewer_assignments(
      case_id,assignment_version,reviewer_id,appeal_grant_id,assigned_by
    ) values(p_case_id,v_version,p_reviewer_id,v_grant,p_actor);
    perform pg_catalog.set_config('app.assignment_case_transition','assign_case_appeal_reviewer',true);
    update app_private.assignment_cases set reviewer_id=p_reviewer_id,lifecycle_status='verifying',version=version+1
      where case_id=p_case_id;
    perform pg_catalog.set_config('app.assignment_case_transition','',true);
    select coalesce(max(sequence),0)+1 into v_seq from app_private.assignment_case_events where case_id=p_case_id;
    insert into app_private.assignment_case_events(case_id,sequence,actor_id,audience,event_type,payload)
      values(p_case_id,v_seq,p_actor,'participants','appeal_reviewer_assigned',
        pg_catalog.jsonb_build_object('update','A separate reviewer is reviewing the appeal.'));
    v_event:=app_private.append_marketplace_event(p_actor,v_assignment.job_id,
      'job.assignment_case_updated',v_assignment.terms_version,
      pg_catalog.jsonb_build_object('case_id',p_case_id,'update','appeal_reviewer_assigned'));
    perform app_private.add_in_app_notification(v_event,v_assignment.worker_id,'assignment_case_updated');
    perform app_private.add_in_app_notification(v_event,v_assignment.poster_id,'assignment_case_updated');
    insert into app_private.assignment_case_access_audit(case_id,actor_id,action,new_reviewer_id)
      values(p_case_id,p_actor,'case_appeal_reviewer_assigned',p_reviewer_id);
    v_result:=pg_catalog.jsonb_build_object('case_id',p_case_id,'status','verifying',
      'version',v_case.version+1,'assigned',true);
  end if;
  insert into app_private.case_command_idempotency(actor_id,command_name,idempotency_key,request_sha256,response)
    values(p_actor,'assign_case_appeal_reviewer',p_idempotency_key,v_hash,v_result);
  return v_result;
end;
$function$;

create function app_private.case_appeal_command_for_actor(
  p_actor uuid,p_case_id uuid,p_action text,p_payload jsonb,p_auth_aal text,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_case app_private.assignment_cases%rowtype;
  v_assignment app_private.assignments%rowtype;
  v_pub app_private.assignment_case_decision_publications%rowtype;
  v_receipt app_private.assignment_case_appeal_receipts%rowtype;
  v_request app_private.assignment_case_information_requests%rowtype;
  v_decision app_private.assignment_case_decision_versions%rowtype;
  v_assessment app_private.assignment_case_nonresponse_assessments%rowtype;
  v_signoff app_private.assignment_case_nonresponse_signoffs%rowtype;
  v_existing app_private.case_command_idempotency%rowtype;
  v_role text;
  v_account_status text;
  v_grant uuid;
  v_hash bytea;
  v_event uuid;
  v_seq integer;
  v_request_number smallint;
  v_review_version integer;
  v_appeal_id uuid;
  v_action text;
  v_explanation text;
  v_snapshot jsonb;
  v_snapshot_hash bytea;
  v_approval_count integer;
  v_status text;
  v_result jsonb;
begin
  if p_actor is null or p_case_id is null or p_idempotency_key is null or p_payload is null
     or pg_catalog.jsonb_typeof(p_payload)<>'object'
     or p_action is null or p_action not in ('request_case_appeal_evidence','respond_case_appeal_evidence',
       'close_case_appeal_evidence_nonresponse','review_case_appeal') then
    raise exception using errcode='22023',message='invalid_case_command';
  end if;
  v_hash:=extensions.digest(pg_catalog.jsonb_build_object('case_id',p_case_id,
    'action',p_action,'payload',p_payload)::text,'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    p_actor::text||':'||p_action||':'||p_idempotency_key::text,428118));
  select * into v_existing from app_private.case_command_idempotency
    where actor_id=p_actor and command_name=p_action and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.request_sha256<>v_hash then raise exception using errcode='23505',message='idempotency_conflict'; end if;
    return v_existing.response;
  end if;
  select * into v_case from app_private.assignment_cases where case_id=p_case_id for update;
  if not found then raise exception using errcode='P0002',message='case_not_found'; end if;
  select * into v_assignment from app_private.assignments where assignment_id=v_case.assignment_id;
  select * into v_pub from app_private.assignment_case_decision_publications where case_id=p_case_id;
  if not found then raise exception using errcode='P0001',message='stale_state'; end if;
  v_role:=case when p_actor=v_assignment.worker_id then 'worker'
    when p_actor=v_assignment.poster_id then 'poster' else null end;
  select account_status into v_account_status from app_private.identity_accounts where user_id=p_actor;

  if p_action='respond_case_appeal_evidence' then
    if p_auth_aal is null or p_auth_aal not in ('aal1','aal2') or v_role is null
       or v_account_status is null or v_account_status not in ('active','suspended')
       or p_payload-array['request_number','response']::text[]<>'{}'::jsonb
       or coalesce(p_payload->>'request_number','') !~ '^[1-9][0-9]{0,2}$'
       or pg_catalog.char_length(pg_catalog.btrim(coalesce(p_payload->>'response',''))) not between 1 and 2000 then
      raise exception using errcode='42501',message='case_access_denied';
    end if;
    select * into v_request from app_private.assignment_case_information_requests r
      where r.case_id=p_case_id and r.request_number=(p_payload->>'request_number')::smallint
        and r.target_party_role=v_role and r.request_scope='appeal' and r.status='open' for update;
    if not found or not exists(select 1 from app_private.assignment_case_appeal_receipts a
      where a.appeal_id=v_request.appeal_id and not exists(select 1
        from app_private.assignment_case_appeal_review_versions rv where rv.appeal_id=a.appeal_id
          and rv.action in ('upheld','changed'))) then
      raise exception using errcode='P0001',message='stale_state';
    end if;
    insert into app_private.assignment_case_information_responses(request_id,case_id,actor_id,response)
      values(v_request.request_id,p_case_id,p_actor,pg_catalog.btrim(p_payload->>'response'));
    update app_private.assignment_case_information_requests set status='responded',status_changed_at=pg_catalog.clock_timestamp()
      where request_id=v_request.request_id;
    select coalesce(max(sequence),0)+1 into v_seq from app_private.assignment_case_events where case_id=p_case_id;
    insert into app_private.assignment_case_events(case_id,sequence,actor_id,audience,event_type,payload)
      values(p_case_id,v_seq,p_actor,v_role,'participant_response',
        pg_catalog.jsonb_build_object('update','Your appeal response was received.'));
    v_event:=app_private.append_marketplace_event(p_actor,v_assignment.job_id,
      'job.assignment_case_updated',v_assignment.terms_version,
      pg_catalog.jsonb_build_object('case_id',p_case_id,'update','appeal_evidence_received'));
    if v_case.reviewer_id is not null then
      perform app_private.add_in_app_notification(v_event,v_case.reviewer_id,'assignment_case_updated');
    end if;
    insert into app_private.assignment_case_access_audit(case_id,actor_id,action)
      values(p_case_id,p_actor,'case_appeal_evidence_responded');
    v_result:=pg_catalog.jsonb_build_object('case_id',p_case_id,'status',v_case.lifecycle_status,
      'version',v_case.version,'request_number',v_request.request_number,'received',true);
  else
    if p_auth_aal is distinct from 'aal2' or v_role is not null or v_account_status is distinct from 'active'
       or not app_private.case_staff_principal_is_human(p_actor) then
      raise exception using errcode='42501',message='case_access_denied';
    end if;
    if p_action='close_case_appeal_evidence_nonresponse' then
      if p_payload-array['request_number','substantive_reasoning']::text[]<>'{}'::jsonb
         or coalesce(p_payload->>'request_number','') !~ '^[1-9][0-9]{0,2}$'
         or pg_catalog.char_length(pg_catalog.btrim(coalesce(p_payload->>'substantive_reasoning',''))) not between 100 and 2000 then
        raise exception using errcode='22023',message='invalid_case_command';
      end if;
      select g.grant_id into v_grant from app_private.staff_grants g where g.user_id=p_actor
        and g.capability='case_senior_signoff' and g.revoked_at is null for share;
      if v_grant is null or p_actor in (v_pub.initial_reviewer_id,v_case.reviewer_id) then
        raise exception using errcode='42501',message='case_access_denied';
      end if;
      select * into v_request from app_private.assignment_case_information_requests r
        where r.case_id=p_case_id and r.request_number=(p_payload->>'request_number')::smallint
          and r.request_scope='appeal' and r.status='open' for update;
      if not found then raise exception using errcode='P0001',message='stale_state'; end if;
      select * into v_assessment from app_private.assignment_case_nonresponse_assessments a
        where a.case_id=p_case_id and a.target_party_role=v_request.target_party_role
          and a.created_at>v_request.created_at
        order by a.created_at desc,a.assessment_id desc limit 1;
      select * into v_signoff from app_private.assignment_case_nonresponse_signoffs s
        where s.assessment_id=v_assessment.assessment_id and s.senior_id=p_actor;
      if v_assessment.assessment_id is null or v_signoff.signoff_id is null
         or not exists(select 1 from app_private.staff_grants g
          where g.grant_id=v_signoff.senior_grant_id and g.user_id=p_actor
            and g.capability='case_senior_signoff' and g.revoked_at is null)
         or not exists(select 1 from app_private.assignment_case_contact_attempts c
          where c.case_id=p_case_id and c.target_party_role=v_request.target_party_role
            and c.result='no_response' and c.recorded_at>v_request.created_at
          group by c.case_id having count(*)>=2 and count(distinct c.channel)>=2)
         or not exists(select 1 from app_private.assignment_case_contact_attempts c
          where c.case_id=p_case_id and c.target_party_role=v_request.target_party_role
            and c.result='no_response'
          group by c.case_id having extensions.digest(coalesce(jsonb_agg(jsonb_build_array(
              c.contact_attempt_id,c.channel,c.result,c.recorded_at)
              order by c.recorded_at,c.contact_attempt_id),'[]'::jsonb)::text,'sha256')
              =v_assessment.contact_set_sha256)
         or p_actor in (v_assignment.worker_id,v_assignment.poster_id,v_pub.initial_reviewer_id,v_case.reviewer_id) then
        raise exception using errcode='P0001',message='nonresponse_contact_threshold_not_met';
      end if;
      insert into app_private.assignment_case_appeal_request_nonresponse_closures(
        request_id,assessment_id,signoff_id,senior_id,substantive_reasoning
      ) values(v_request.request_id,v_assessment.assessment_id,v_signoff.signoff_id,p_actor,
        pg_catalog.btrim(p_payload->>'substantive_reasoning'));
      update app_private.assignment_case_information_requests set status='closed',status_changed_at=pg_catalog.clock_timestamp()
        where request_id=v_request.request_id;
      insert into app_private.assignment_case_access_audit(case_id,actor_id,action)
        values(p_case_id,p_actor,'case_appeal_evidence_closed');
      v_event:=app_private.append_marketplace_event(p_actor,v_assignment.job_id,
        'job.assignment_case_updated',v_assignment.terms_version,
        pg_catalog.jsonb_build_object('case_id',p_case_id,'update','appeal_evidence_request_closed'));
      perform app_private.add_in_app_notification(v_event,
        case v_request.target_party_role when 'worker' then v_assignment.worker_id else v_assignment.poster_id end,
        'assignment_case_updated');
      v_result:=pg_catalog.jsonb_build_object('case_id',p_case_id,'status',v_case.lifecycle_status,
        'version',v_case.version,'request_number',v_request.request_number,'closed',true);
    else
      if not app_private.lock_case_appeal_reviewer_scope(p_actor,p_auth_aal)
         or not exists(select 1 from app_private.staff_grants g where g.user_id=p_actor
           and g.capability='dispute_review' and g.revoked_at is null)
         or p_actor in (v_assignment.worker_id,v_assignment.poster_id,v_pub.initial_reviewer_id)
         or not exists(select 1 from app_private.assignment_case_appeal_reviewer_assignments a
           where a.case_id=p_case_id and a.reviewer_id=p_actor
             and a.assignment_version=(select max(a2.assignment_version)
               from app_private.assignment_case_appeal_reviewer_assignments a2 where a2.case_id=p_case_id)) then
        raise exception using errcode='42501',message='case_access_denied';
      end if;
      if p_action='request_case_appeal_evidence' then
        if p_payload-array['appeal_id','target_party_role','request_kind','prompt']::text[]<>'{}'::jsonb
           or coalesce(p_payload->>'appeal_id','') !~* '^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$'
           or coalesce(p_payload->>'target_party_role','') not in ('worker','poster')
           or coalesce(p_payload->>'request_kind','') not in ('information','evidence')
           or pg_catalog.char_length(pg_catalog.btrim(coalesce(p_payload->>'prompt',''))) not between 1 and 500
           or p_payload->>'prompt' ~* '(https?://|www[.]|[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12})' then
          raise exception using errcode='22023',message='invalid_case_command';
        end if;
        v_appeal_id:=(p_payload->>'appeal_id')::uuid;
        select * into v_receipt from app_private.assignment_case_appeal_receipts a
          where a.appeal_id=v_appeal_id and a.case_id=p_case_id;
        if not found or exists(select 1 from app_private.assignment_case_appeal_review_versions r
          where r.appeal_id=v_appeal_id and r.action in ('upheld','changed')) then
          raise exception using errcode='P0001',message='stale_state';
        end if;
        v_decision:=app_private.case_effective_approved_decision(p_case_id);
        if v_decision.decision_id is null then raise exception using errcode='P0001',message='stale_state'; end if;
        select (coalesce(max(request_number),0)+1)::smallint into v_request_number
          from app_private.assignment_case_information_requests where case_id=p_case_id;
        if v_request_number>100 then raise exception using errcode='P0001',message='stale_state'; end if;
        insert into app_private.assignment_case_information_requests(
          case_id,target_party_role,request_kind,request_scope,request_number,prompt,created_by,
          appeal_id,appeal_request_version
        ) values(p_case_id,p_payload->>'target_party_role',p_payload->>'request_kind','appeal',
          v_request_number,pg_catalog.btrim(p_payload->>'prompt'),p_actor,v_appeal_id,
          (select coalesce(max(appeal_request_version),0)+1 from app_private.assignment_case_information_requests
            where appeal_id=v_appeal_id)) returning * into v_request;
        v_snapshot:=app_private.case_decision_evidence_snapshot(p_case_id,null);
        v_snapshot_hash:=extensions.digest(v_snapshot::text,'sha256');
        select coalesce(max(review_version),0)+1 into v_review_version
          from app_private.assignment_case_appeal_review_versions where appeal_id=v_appeal_id;
        insert into app_private.assignment_case_appeal_review_versions(
          appeal_id,case_id,review_version,reviewer_id,action,applied_decision_version,
          decision_sha256,evidence_snapshot,evidence_snapshot_sha256,request_id
        ) values(v_appeal_id,p_case_id,v_review_version,p_actor,'request_evidence',
          v_decision.decision_version,v_decision.decision_sha256,v_snapshot,v_snapshot_hash,v_request.request_id);
        select coalesce(max(sequence),0)+1 into v_seq from app_private.assignment_case_events where case_id=p_case_id;
        insert into app_private.assignment_case_events(case_id,sequence,actor_id,audience,event_type,payload)
          values(p_case_id,v_seq,p_actor,v_request.target_party_role,'information_requested',
            pg_catalog.jsonb_build_object('request_number',v_request_number,'request_kind',v_request.request_kind,
              'prompt',v_request.prompt,'status','open'));
        v_event:=app_private.append_marketplace_event(p_actor,v_assignment.job_id,
          'job.assignment_case_updated',v_assignment.terms_version,
          pg_catalog.jsonb_build_object('case_id',p_case_id,'update','appeal_information_requested'));
        perform app_private.add_in_app_notification(v_event,
          case v_request.target_party_role when 'worker' then v_assignment.worker_id else v_assignment.poster_id end,
          'assignment_case_updated');
        insert into app_private.assignment_case_access_audit(case_id,actor_id,action)
          values(p_case_id,p_actor,'case_appeal_evidence_requested');
        v_result:=pg_catalog.jsonb_build_object('case_id',p_case_id,'status',v_case.lifecycle_status,
          'version',v_case.version,'request_number',v_request_number,'requested',true);
      elsif p_action='review_case_appeal' then
        if p_payload-array['appeal_id','action','public_explanation','decision_version']::text[]<>'{}'::jsonb
           or coalesce(p_payload->>'appeal_id','') !~* '^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$'
           or coalesce(p_payload->>'action','') not in ('upheld','changed')
           or pg_catalog.char_length(pg_catalog.btrim(coalesce(p_payload->>'public_explanation',''))) not between 20 and 2000
           or p_payload->>'public_explanation' ~* '(https?://|www[.]|[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12})'
           or (p_payload->>'action'='changed' and coalesce(p_payload->>'decision_version','') !~ '^[1-9][0-9]{0,4}$')
           or (p_payload->>'action'='upheld' and p_payload ? 'decision_version') then
          raise exception using errcode='22023',message='invalid_case_command';
        end if;
        v_appeal_id:=(p_payload->>'appeal_id')::uuid;
        v_action:=p_payload->>'action';
        v_explanation:=pg_catalog.btrim(p_payload->>'public_explanation');
        select * into v_receipt from app_private.assignment_case_appeal_receipts a
          where a.appeal_id=v_appeal_id and a.case_id=p_case_id;
        if not found or v_receipt.received_at>=v_pub.appeal_deadline_at
           or exists(select 1 from app_private.assignment_case_appeal_review_versions r
             where r.appeal_id=v_appeal_id and r.action in ('upheld','changed'))
           or exists(select 1 from app_private.assignment_case_information_requests r
             where r.appeal_id=v_appeal_id and r.status='open') then
          raise exception using errcode='P0001',message='stale_state';
        end if;
        if v_action='changed' then
          select * into v_decision from app_private.assignment_case_decision_versions d
            where d.case_id=p_case_id and d.decision_version=(p_payload->>'decision_version')::integer
              and d.decision_version>v_pub.decision_version
              and d.decision_version=(select max(d2.decision_version) from app_private.assignment_case_decision_versions d2 where d2.case_id=p_case_id);
        else
          v_decision:=app_private.case_effective_approved_decision(p_case_id);
        end if;
        if v_decision.decision_id is null then raise exception using errcode='P0001',message='stale_state'; end if;
        select count(*)::integer into v_approval_count
        from app_private.assignment_case_decision_approvals ap
        join app_private.staff_grants g on g.grant_id=ap.financial_grant_id and g.user_id=ap.approver_id
          and g.capability='financial_approve' and g.revoked_at is null
        join app_private.identity_accounts ia on ia.user_id=ap.approver_id and ia.account_status='active'
        where ap.decision_id=v_decision.decision_id and ap.decision_sha256=v_decision.decision_sha256
          and ap.approver_id not in (v_assignment.worker_id,v_assignment.poster_id)
          and app_private.case_staff_principal_is_human(ap.approver_id);
        if v_approval_count<>2 or (v_decision.nonresponse_assessment_id is not null and not exists(
          select 1 from app_private.assignment_case_decision_nonresponse_signoffs s
          join app_private.staff_grants g on g.grant_id=s.senior_grant_id and g.user_id=s.senior_id
            and g.capability='case_senior_signoff' and g.revoked_at is null
          join app_private.identity_accounts ia on ia.user_id=s.senior_id and ia.account_status='active'
          where s.decision_id=v_decision.decision_id and s.decision_sha256=v_decision.decision_sha256
            and s.senior_id not in (v_assignment.worker_id,v_assignment.poster_id,p_actor)
            and app_private.case_staff_principal_is_human(s.senior_id))) then
          raise exception using errcode='P0001',message='stale_state';
        end if;
        v_snapshot:=case when v_action='changed' then v_decision.evidence_snapshot
          else app_private.case_decision_evidence_snapshot(p_case_id,null) end;
        v_snapshot_hash:=extensions.digest(v_snapshot::text,'sha256');
        select coalesce(max(review_version),0)+1 into v_review_version
          from app_private.assignment_case_appeal_review_versions where appeal_id=v_appeal_id;
        insert into app_private.assignment_case_appeal_review_versions(
          appeal_id,case_id,review_version,reviewer_id,action,applied_decision_version,
          decision_sha256,public_explanation,evidence_snapshot,evidence_snapshot_sha256
        ) values(v_appeal_id,p_case_id,v_review_version,p_actor,v_action,v_decision.decision_version,
          v_decision.decision_sha256,v_explanation,v_snapshot,v_snapshot_hash);
        v_status:=case when exists(select 1 from app_private.assignment_case_appeal_receipts a
          where a.case_id=p_case_id and not exists(select 1 from app_private.assignment_case_appeal_review_versions r
            where r.appeal_id=a.appeal_id and r.action in ('upheld','changed'))) then 'appeal' else 'decision_made' end;
        perform pg_catalog.set_config('app.assignment_case_transition','appeal_decision_recorded',true);
        update app_private.assignment_cases set lifecycle_status=v_status,version=version+1 where case_id=p_case_id;
        perform pg_catalog.set_config('app.assignment_case_transition','',true);
        select coalesce(max(sequence),0)+1 into v_seq from app_private.assignment_case_events where case_id=p_case_id;
        insert into app_private.assignment_case_events(case_id,sequence,actor_id,audience,event_type,payload)
          values(p_case_id,v_seq,p_actor,'participants','appeal_decision_recorded',
            pg_catalog.jsonb_build_object('update','The appeal review is complete.',
              'decision_version',v_decision.decision_version,'outcome',v_decision.outcome,
              'reason_code',v_decision.reason_code,'public_explanation',v_explanation,
              'gross_principal_kobo',v_decision.gross_principal_kobo::text,
              'worker_award_gross_kobo',v_decision.worker_award_gross_kobo::text,
              'poster_refund_gross_kobo',v_decision.poster_refund_gross_kobo::text,
              'retained_hold_gross_kobo',v_decision.retained_hold_gross_kobo::text,
              'commission_kobo',v_decision.commission_kobo::text,'worker_net_kobo',v_decision.worker_net_kobo::text));
        v_event:=app_private.append_marketplace_event(p_actor,v_assignment.job_id,
          'job.assignment_case_decision_notified',v_assignment.terms_version,
          pg_catalog.jsonb_build_object('case_id',p_case_id,'event','appeal_decision_recorded',
            'decision_version',v_decision.decision_version,'outcome',v_decision.outcome));
        perform app_private.add_in_app_notification(v_event,v_assignment.worker_id,'assignment_case_decision');
        perform app_private.add_in_app_notification(v_event,v_assignment.poster_id,'assignment_case_decision');
        insert into app_private.assignment_case_access_audit(case_id,actor_id,action)
          values(p_case_id,p_actor,'case_appeal_review_decided');
        v_result:=pg_catalog.jsonb_build_object('case_id',p_case_id,'status',v_status,
          'version',v_case.version+1,'appeal_decided',true,'action',v_action,
          'decision_version',v_decision.decision_version);
      else
        raise exception using errcode='22023',message='invalid_case_command';
      end if;
    end if;
  end if;
  insert into app_private.case_command_idempotency(actor_id,command_name,idempotency_key,request_sha256,response)
    values(p_actor,p_action,p_idempotency_key,v_hash,v_result);
  return v_result;
end;
$function$;

create function app_private.case_appeal_participant_projection(p_case_id uuid,p_actor uuid)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_pub app_private.assignment_case_decision_publications%rowtype;
  v_assignment app_private.assignments%rowtype;
  v_role text;
  v_decision app_private.assignment_case_decision_versions%rowtype;
  v_my_appeal app_private.assignment_case_appeal_receipts%rowtype;
  v_requests jsonb;
  v_result jsonb;
  v_effective_version integer;
begin
  select * into v_pub from app_private.assignment_case_decision_publications where case_id=p_case_id;
  if not found then return null; end if;
  select a.* into v_assignment from app_private.assignments a
    join app_private.assignment_cases c using(assignment_id) where c.case_id=p_case_id;
  v_role:=case when p_actor=v_assignment.worker_id then 'worker'
    when p_actor=v_assignment.poster_id then 'poster' else null end;
  if v_role is null then return null; end if;
  select d.decision_version into v_effective_version
  from app_private.assignment_case_appeal_review_versions r
  join app_private.assignment_case_decision_versions d
    on d.case_id=r.case_id and d.decision_version=r.applied_decision_version
       and d.decision_sha256=r.decision_sha256
  where r.case_id=p_case_id and r.action='changed'
  order by r.created_at desc,r.appeal_id desc,r.review_version desc limit 1;
  select * into v_decision from app_private.assignment_case_decision_versions
    where case_id=p_case_id and decision_version=coalesce(v_effective_version,v_pub.decision_version);
  select * into v_my_appeal from app_private.assignment_case_appeal_receipts
    where case_id=p_case_id and actor_id=p_actor and initial_decision_version=v_pub.decision_version;
  select coalesce(jsonb_agg(jsonb_build_object('request_number',r.request_number,
    'request_kind',r.request_kind,'prompt',r.prompt,'status',r.status,'created_at',r.created_at,
    'response',x.response,'responded_at',x.created_at) order by r.request_number),'[]'::jsonb)
    into v_requests from app_private.assignment_case_information_requests r
    left join lateral(select response,created_at from app_private.assignment_case_information_responses
      where request_id=r.request_id and actor_id=p_actor order by created_at limit 1) x on true
    where r.case_id=p_case_id and r.target_party_role=v_role and r.request_scope='appeal';
  v_result:=pg_catalog.jsonb_build_object(
    'decision',pg_catalog.jsonb_build_object('decision_version',v_decision.decision_version,
      'outcome',v_decision.outcome,'reason_code',v_decision.reason_code,
      'public_explanation',v_decision.public_explanation,
      'gross_principal_kobo',v_decision.gross_principal_kobo::text,
      'worker_award_gross_kobo',v_decision.worker_award_gross_kobo::text,
      'poster_refund_gross_kobo',v_decision.poster_refund_gross_kobo::text,
      'retained_hold_gross_kobo',v_decision.retained_hold_gross_kobo::text,
      'commission_kobo',v_decision.commission_kobo::text,'worker_net_kobo',v_decision.worker_net_kobo::text),
    'durable_notified_at',v_pub.durable_notified_at,'appeal_deadline_at',v_pub.appeal_deadline_at,
    'can_appeal',pg_catalog.clock_timestamp()<v_pub.appeal_deadline_at and v_my_appeal.appeal_id is null,
    'my_appeal',case when v_my_appeal.appeal_id is null then null else jsonb_build_object(
      'statement',v_my_appeal.statement,'received_at',v_my_appeal.received_at,
      'status',coalesce((select r.action from app_private.assignment_case_appeal_review_versions r
        where r.appeal_id=v_my_appeal.appeal_id order by r.review_version desc limit 1),'under_review')) end,
    'other_party_appeal_received',exists(select 1 from app_private.assignment_case_appeal_receipts a
      where a.case_id=p_case_id and a.party_role<>v_role and a.initial_decision_version=v_pub.decision_version),
    'status',case when exists(select 1 from app_private.assignment_case_appeal_receipts a
      where a.case_id=p_case_id and not exists(select 1 from app_private.assignment_case_appeal_review_versions r
        where r.appeal_id=a.appeal_id and r.action in ('upheld','changed'))) then 'under_review'
      when pg_catalog.clock_timestamp()<v_pub.appeal_deadline_at then 'window_open'
      else 'window_closed' end,'requests',v_requests);
  return v_result;
end;
$function$;

create or replace function app_private.get_assignment_case_for_actor(p_actor uuid,p_case_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare v_result jsonb; v_appeal jsonb; v_role text;
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
    v_result:=v_result||jsonb_build_object('appeal',v_appeal);
    if v_appeal->>'status'='under_review' then v_result:=v_result||jsonb_build_object('status','appeal'); end if;
  end if;
  return v_result;
end;
$function$;

create function app_private.list_assignment_case_appeal_queue_for_actor(
  p_actor uuid,p_auth_aal text,p_limit smallint
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare v_items jsonb; v_truncated boolean;
begin
  if p_limit<>51 or not app_private.lock_case_appeal_reviewer_scope(p_actor,p_auth_aal)
     or not exists(select 1 from app_private.staff_grants g where g.user_id=p_actor
       and g.capability='dispute_review' and g.revoked_at is null) then
    raise exception using errcode='42501',message='case_access_denied';
  end if;
  select coalesce(jsonb_agg(x.item order by x.received_at desc,x.case_id),'[]'::jsonb)
    into v_items from (
      select c.case_id,c.opened_at as received_at,jsonb_build_object(
        'case_id',c.case_id,'assignment_id',c.assignment_id,'status',
        case when exists(select 1 from app_private.assignment_case_appeal_review_versions r
          join app_private.assignment_case_appeal_receipts a using(appeal_id)
          where a.case_id=c.case_id and r.action in ('upheld','changed')) then c.lifecycle_status else 'appeal' end,
        'opened_at',c.opened_at,'age_seconds',greatest(0,extract(epoch from pg_catalog.clock_timestamp()-c.opened_at))::bigint::text,
        'appeal_deadline_at',p.appeal_deadline_at,
        'pending_appeal_count',(select count(*)::integer from app_private.assignment_case_appeal_receipts a
          where a.case_id=c.case_id and a.received_at<p.appeal_deadline_at and not exists(
            select 1 from app_private.assignment_case_appeal_review_versions r
            where r.appeal_id=a.appeal_id and r.action in ('upheld','changed'))),
        'assigned_to_me',exists(select 1 from app_private.assignment_case_appeal_reviewer_assignments ar
          where ar.case_id=c.case_id and ar.reviewer_id=p_actor and ar.assignment_version=(
            select max(ar2.assignment_version) from app_private.assignment_case_appeal_reviewer_assignments ar2
            where ar2.case_id=c.case_id))) as item
      from app_private.assignment_cases c
      join app_private.assignment_case_decision_publications p using(case_id)
      where exists(select 1 from app_private.assignment_case_appeal_receipts a
        where a.case_id=c.case_id and a.received_at<p.appeal_deadline_at and not exists(
          select 1 from app_private.assignment_case_appeal_review_versions r
          where r.appeal_id=a.appeal_id and r.action in ('upheld','changed')))
      order by c.opened_at limit 50
    ) x;
  select exists(select 1 from app_private.assignment_cases c
    join app_private.assignment_case_decision_publications p using(case_id)
    where exists(select 1 from app_private.assignment_case_appeal_receipts a
      where a.case_id=c.case_id and a.received_at<p.appeal_deadline_at and not exists(
        select 1 from app_private.assignment_case_appeal_review_versions r
        where r.appeal_id=a.appeal_id and r.action in ('upheld','changed')))
    order by c.opened_at offset 50 limit 1) into v_truncated;
  insert into app_private.assignment_case_access_audit(case_id,actor_id,action)
    select (i->>'case_id')::uuid,p_actor,'case_queue_read' from jsonb_array_elements(v_items) i;
  return jsonb_build_object('items',v_items,'truncated',v_truncated);
end;
$function$;

create function app_private.get_assignment_case_appeal_for_reviewer(
  p_actor uuid,p_case_id uuid,p_auth_aal text
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_case app_private.assignment_cases%rowtype;
  v_assignment app_private.assignments%rowtype;
  v_pub app_private.assignment_case_decision_publications%rowtype;
  v_base jsonb;
  v_investigation jsonb;
  v_appeals jsonb;
  v_result jsonb;
begin
  if not app_private.lock_case_appeal_reviewer_scope(p_actor,p_auth_aal)
     or not exists(select 1 from app_private.staff_grants g where g.user_id=p_actor
       and g.capability='dispute_review' and g.revoked_at is null) then
    raise exception using errcode='42501',message='case_access_denied';
  end if;
  select * into v_case from app_private.assignment_cases where case_id=p_case_id for share;
  if not found then raise exception using errcode='P0002',message='case_not_found'; end if;
  select * into v_assignment from app_private.assignments where assignment_id=v_case.assignment_id;
  select * into v_pub from app_private.assignment_case_decision_publications where case_id=p_case_id;
  if p_actor in (v_assignment.worker_id,v_assignment.poster_id,v_pub.initial_reviewer_id)
     or v_case.reviewer_id is distinct from p_actor
     or not exists(select 1 from app_private.assignment_case_appeal_reviewer_assignments ar
       where ar.case_id=p_case_id and ar.reviewer_id=p_actor and ar.assignment_version=(
         select max(ar2.assignment_version) from app_private.assignment_case_appeal_reviewer_assignments ar2
         where ar2.case_id=p_case_id)) then
    raise exception using errcode='42501',message='case_access_denied';
  end if;
  v_base:=app_private.get_assignment_case_for_reviewer_base(p_actor,p_case_id,p_auth_aal);
  v_investigation:=app_private.case_investigation_projection(p_case_id,p_actor,true)->'investigation';
  v_investigation:=pg_catalog.jsonb_set(v_investigation,'{internal_notes}','[]'::jsonb,true);
  select coalesce(jsonb_agg(jsonb_build_object(
    'appeal_id',a.appeal_id,'party_role',a.party_role,'statement',a.statement,
    'received_at',a.received_at,
    'status',coalesce((select r.action from app_private.assignment_case_appeal_review_versions r
       where r.appeal_id=a.appeal_id order by r.review_version desc limit 1),'under_review'),
    'review_versions',coalesce((select jsonb_agg(jsonb_build_object(
       'review_version',r.review_version,'action',r.action,'applied_decision_version',r.applied_decision_version,
       'public_explanation',r.public_explanation,'evidence_snapshot_sha256',encode(r.evidence_snapshot_sha256,'hex'),
       'created_at',r.created_at,'request_number',q.request_number)
       order by r.review_version) from app_private.assignment_case_appeal_review_versions r
       left join app_private.assignment_case_information_requests q on q.request_id=r.request_id
       where r.appeal_id=a.appeal_id),'[]'::jsonb),
    'requests',coalesce((select jsonb_agg(jsonb_build_object('request_number',q.request_number,
       'target_party_role',q.target_party_role,'request_kind',q.request_kind,'prompt',q.prompt,
       'status',q.status,'created_at',q.created_at,'response',x.response,'responded_at',x.created_at)
       order by q.request_number) from app_private.assignment_case_information_requests q
       left join lateral(select response,created_at from app_private.assignment_case_information_responses
         where request_id=q.request_id order by created_at limit 1) x on true
       where q.appeal_id=a.appeal_id),'[]'::jsonb)
    ) order by a.received_at,a.appeal_id),'[]'::jsonb) into v_appeals
  from app_private.assignment_case_appeal_receipts a where a.case_id=p_case_id;
  insert into app_private.assignment_case_access_audit(case_id,actor_id,action)
    values(p_case_id,p_actor,'case_read');
  v_result:=v_base||jsonb_build_object('investigation',v_investigation,
    'appeal_review',jsonb_build_object('initial_decision_version',v_pub.decision_version,
      'initial_decision_sha256',encode(v_pub.decision_sha256,'hex'),
      'appeal_deadline_at',v_pub.appeal_deadline_at,'durable_notified_at',v_pub.durable_notified_at,
      'appeals',v_appeals,'finalization_block_reason',app_private.case_appeal_finalization_block_reason(p_case_id,null)));
  return v_result;
end;
$function$;

create function public.server_record_case_appeal_receipt_for_actor(
  p_actor uuid,p_case_id uuid,p_statement text,p_auth_aal text,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path = '' as $function$
begin
  return app_private.record_case_appeal_receipt_at_for_actor(
    p_actor,p_case_id,p_statement,p_auth_aal,p_idempotency_key,pg_catalog.clock_timestamp());
end;
$function$;
create function public.server_process_case_appeal_receipt_for_actor(
  p_actor uuid,p_appeal_id uuid,p_auth_aal text
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.process_case_appeal_receipt_for_actor(p_actor,p_appeal_id,p_auth_aal)
$function$;
create function public.server_assign_case_appeal_reviewer_for_actor(
  p_actor uuid,p_case_id uuid,p_reviewer_id uuid,p_auth_aal text,p_idempotency_key uuid
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.assign_case_appeal_reviewer_for_actor(p_actor,p_case_id,p_reviewer_id,p_auth_aal,p_idempotency_key)
$function$;
create function public.server_case_appeal_command_for_actor(
  p_actor uuid,p_case_id uuid,p_action text,p_payload jsonb,p_auth_aal text,p_idempotency_key uuid
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.case_appeal_command_for_actor(p_actor,p_case_id,p_action,p_payload,p_auth_aal,p_idempotency_key)
$function$;
create function public.server_list_assignment_case_appeal_queue_for_actor(
  p_actor uuid,p_auth_aal text,p_limit smallint
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.list_assignment_case_appeal_queue_for_actor(p_actor,p_auth_aal,p_limit)
$function$;
create function public.server_get_assignment_case_appeal_for_reviewer(
  p_actor uuid,p_case_id uuid,p_auth_aal text
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.get_assignment_case_appeal_for_reviewer(p_actor,p_case_id,p_auth_aal)
$function$;

revoke all on table app_private.assignment_case_decision_publications,
  app_private.assignment_case_appeal_receipts,app_private.assignment_case_appeal_receipt_applications,
  app_private.assignment_case_appeal_reviewer_assignments,
  app_private.assignment_case_appeal_review_versions,
  app_private.assignment_case_appeal_request_nonresponse_closures
  from public,anon,authenticated,service_role;
revoke all on function app_private.lock_case_appeal_reviewer_scope(uuid,text),
  app_private.record_case_appeal_receipt_at_for_actor(uuid,uuid,text,text,uuid,timestamp with time zone),
  app_private.process_case_appeal_receipt_for_actor(uuid,uuid,text),
  app_private.case_appeal_finalization_block_reason(uuid,timestamp with time zone),
  app_private.case_appeal_participant_projection(uuid,uuid),
  app_private.case_effective_approved_decision(uuid),
  app_private.assign_case_appeal_reviewer_for_actor(uuid,uuid,uuid,text,uuid),
  app_private.case_appeal_command_for_actor(uuid,uuid,text,jsonb,text,uuid),
  app_private.list_assignment_case_appeal_queue_for_actor(uuid,text,smallint),
  app_private.get_assignment_case_appeal_for_reviewer(uuid,uuid,text),
  app_private.get_assignment_case_for_actor(uuid,uuid)
  from public,anon,authenticated,service_role;
revoke all on function public.server_record_case_appeal_receipt_for_actor(uuid,uuid,text,text,uuid),
  public.server_process_case_appeal_receipt_for_actor(uuid,uuid,text),
  public.server_assign_case_appeal_reviewer_for_actor(uuid,uuid,uuid,text,uuid),
  public.server_case_appeal_command_for_actor(uuid,uuid,text,jsonb,text,uuid),
  public.server_list_assignment_case_appeal_queue_for_actor(uuid,text,smallint),
  public.server_get_assignment_case_appeal_for_reviewer(uuid,uuid,text)
  from public,anon,authenticated,service_role;
grant execute on function public.server_record_case_appeal_receipt_for_actor(uuid,uuid,text,text,uuid),
  public.server_process_case_appeal_receipt_for_actor(uuid,uuid,text),
  public.server_assign_case_appeal_reviewer_for_actor(uuid,uuid,uuid,text,uuid),
  public.server_case_appeal_command_for_actor(uuid,uuid,text,jsonb,text,uuid),
  public.server_list_assignment_case_appeal_queue_for_actor(uuid,text,smallint),
  public.server_get_assignment_case_appeal_for_reviewer(uuid,uuid,text)
  to service_role;

-- Keep the existing quarantine upload pipeline and permit its already-requested
-- evidence files during an unresolved appeal. Fail the migration if the frozen
-- Step 4 function text no longer matches the narrow changes below.
do $migration$
declare
  v_definition text;
  v_old text;
  v_new text;
begin
  v_old:='v_case.lifecycle_status not in (''open'',''under_review'',''contacting_other_party'',''verifying'')';
  v_new:='v_case.lifecycle_status not in (''open'',''under_review'',''contacting_other_party'',''verifying'',''appeal'',''decision_made'')';
  v_definition:=pg_catalog.pg_get_functiondef(
    'app_private.issue_case_file_upload_for_actor(uuid,uuid,smallint,text,integer,text,uuid)'::regprocedure);
  if pg_catalog.strpos(v_definition,v_old)=0 then raise exception 'appeal_upload_status_patch_mismatch'; end if;
  v_definition:=pg_catalog.replace(v_definition,v_old,v_new);
  v_old:='request_kind=''evidence'' and request_scope=''investigation'' and status=''open''';
  v_new:='request_kind=''evidence'' and status=''open'' and (request_scope=''investigation'' or (request_scope=''appeal'' and exists(
        select 1 from app_private.assignment_case_appeal_receipts ar
        where ar.appeal_id=app_private.assignment_case_information_requests.appeal_id
          and not exists(select 1 from app_private.assignment_case_appeal_review_versions rv
            where rv.appeal_id=ar.appeal_id and rv.action in (''upheld'',''changed'')))))';
  if pg_catalog.strpos(v_definition,v_old)=0 then raise exception 'appeal_upload_scope_patch_mismatch'; end if;
  execute pg_catalog.replace(v_definition,v_old,v_new);

  v_old:='v_case.lifecycle_status not in (''open'',''under_review'',''contacting_other_party'',''verifying'')';
  v_new:='v_case.lifecycle_status not in (''open'',''under_review'',''contacting_other_party'',''verifying'',''appeal'',''decision_made'')';
  v_definition:=pg_catalog.pg_get_functiondef(
    'app_private.claim_case_file_upload_for_actor(uuid,uuid,text)'::regprocedure);
  if pg_catalog.strpos(v_definition,v_old)=0 then raise exception 'appeal_upload_claim_status_patch_mismatch'; end if;
  v_definition:=pg_catalog.replace(v_definition,v_old,v_new);
  v_old:='r.request_id=v_intent.request_id and r.status=''open''';
  v_new:='r.request_id=v_intent.request_id and r.status=''open'' and (r.request_scope=''investigation'' or (r.request_scope=''appeal'' and exists(
       select 1 from app_private.assignment_case_appeal_receipts ar where ar.appeal_id=r.appeal_id
         and not exists(select 1 from app_private.assignment_case_appeal_review_versions rv
           where rv.appeal_id=ar.appeal_id and rv.action in (''upheld'',''changed'')))))';
  if pg_catalog.strpos(v_definition,v_old)=0 then raise exception 'appeal_upload_claim_scope_patch_mismatch'; end if;
  execute pg_catalog.replace(v_definition,v_old,v_new);

  v_old:='v_case.lifecycle_status not in (''open'',''under_review'',''contacting_other_party'',''verifying'')';
  v_new:='v_case.lifecycle_status not in (''open'',''under_review'',''contacting_other_party'',''verifying'',''appeal'',''decision_made'')';
  v_definition:=pg_catalog.pg_get_functiondef(
    'app_private.finalize_case_file_upload_for_actor(uuid,uuid,integer,text,text)'::regprocedure);
  if pg_catalog.strpos(v_definition,v_old)=0 then raise exception 'appeal_upload_finalize_status_patch_mismatch'; end if;
  v_definition:=pg_catalog.replace(v_definition,v_old,v_new);
  v_old:='r.request_id=v_intent.request_id and r.status=''open''';
  v_new:='r.request_id=v_intent.request_id and r.status=''open'' and (r.request_scope=''investigation'' or (r.request_scope=''appeal'' and exists(
       select 1 from app_private.assignment_case_appeal_receipts ar where ar.appeal_id=r.appeal_id
         and not exists(select 1 from app_private.assignment_case_appeal_review_versions rv
           where rv.appeal_id=ar.appeal_id and rv.action in (''upheld'',''changed'')))))';
  if pg_catalog.strpos(v_definition,v_old)=0 then raise exception 'appeal_upload_finalize_scope_patch_mismatch'; end if;
  execute pg_catalog.replace(v_definition,v_old,v_new);
end;
$migration$;

commit;

