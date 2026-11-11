begin;

-- Step 5 records proposed and approved outcomes only. It creates no ledger,
-- payable, payout, refund operation, participant notice or deadline.
alter table app_private.assignment_case_events
  drop constraint assignment_case_events_event_type_check,
  add constraint assignment_case_events_event_type_check check (event_type in (
    'case_opened','reviewer_assigned','reviewer_reassigned','status_changed',
    'participant_response','evidence_added','decision_notified','appeal_opened',
    'case_closed','case_triaged','contact_attempt_recorded','information_requested',
    'fact_verification_recorded','nonresponse_assessed','case_decision_proposed',
    'case_decision_approved','case_decision_nonresponse_signed'
  ));

alter table app_private.assignment_case_access_audit
  drop constraint assignment_case_access_audit_action_check,
  add constraint assignment_case_access_audit_action_check check (action in (
    'case_read','case_queue_read','case_assigned','case_reassigned',
    'case_triaged','case_contact_logged','case_information_requested',
    'case_participant_responded','case_fact_recorded','case_internal_note_added',
    'case_nonresponse_assessed','case_nonresponse_signed_off',
    'case_decision_proposed','case_decision_approved',
    'case_decision_nonresponse_signed'
  ));

alter table app_private.case_command_idempotency
  drop constraint case_command_idempotency_command_name_check,
  add constraint case_command_idempotency_command_name_check check (command_name in (
    'assign_case_reviewer','triage_case','log_case_contact_attempt',
    'request_case_information','respond_to_case_information','record_case_fact',
    'add_case_internal_note','assess_case_nonresponse','signoff_case_nonresponse',
    'begin_case_file_upload','propose_case_decision','approve_case_decision',
    'signoff_decision_nonresponse'
  ));

create table app_private.assignment_case_decision_versions (
  decision_id uuid primary key default pg_catalog.gen_random_uuid(),
  case_id uuid not null references app_private.assignment_cases(case_id) on delete restrict,
  decision_version integer not null check (decision_version>0),
  proposal_case_version integer not null check (proposal_case_version>0),
  assignment_id uuid not null references app_private.assignments(assignment_id) on delete restrict,
  allocation_id uuid not null references app_private.principal_allocations(allocation_id) on delete restrict,
  proposed_by uuid not null references auth.users(id) on delete restrict,
  proposer_dispute_grant_id uuid not null references app_private.staff_grants(grant_id) on delete restrict,
  proposer_financial_grant_id uuid not null references app_private.staff_grants(grant_id) on delete restrict,
  outcome text not null check (outcome in (
    'full_worker_award','full_poster_refund','split','no_action'
  )),
  reason_code text not null check (reason_code in (
    'payment_not_released','incomplete_work','work_not_as_described',
    'unresponsive_no_show','conduct_safety','other'
  )),
  public_explanation text not null check (char_length(btrim(public_explanation)) between 20 and 2000),
  terms_version integer not null check (terms_version>0),
  terms_sha256 bytea not null check (pg_catalog.octet_length(terms_sha256)=32),
  prior_work_state text not null check (prior_work_state in ('assigned','in_progress','submitted')),
  gross_principal_kobo bigint not null check (gross_principal_kobo between 1 and 100000000),
  worker_award_gross_kobo bigint not null check (worker_award_gross_kobo>=0),
  poster_refund_gross_kobo bigint not null check (poster_refund_gross_kobo>=0),
  retained_hold_gross_kobo bigint not null check (retained_hold_gross_kobo>=0),
  commission_kobo bigint not null check (commission_kobo>=0),
  worker_net_kobo bigint not null check (worker_net_kobo>=0),
  worker_recipient_id uuid references auth.users(id) on delete restrict,
  poster_recipient_id uuid references auth.users(id) on delete restrict,
  nonresponse_assessment_id uuid references app_private.assignment_case_nonresponse_assessments(assessment_id) on delete restrict,
  evidence_snapshot jsonb not null check (
    pg_catalog.jsonb_typeof(evidence_snapshot)='object'
    and pg_catalog.octet_length(evidence_snapshot::text)<=1048576
  ),
  evidence_snapshot_sha256 bytea not null check (pg_catalog.octet_length(evidence_snapshot_sha256)=32),
  decision_sha256 bytea not null check (pg_catalog.octet_length(decision_sha256)=32),
  created_at timestamptz not null default pg_catalog.now(),
  unique(case_id,decision_version),
  unique(decision_id,decision_version,decision_sha256),
  check (gross_principal_kobo::numeric=worker_award_gross_kobo::numeric+
    poster_refund_gross_kobo::numeric+retained_hold_gross_kobo::numeric),
  check (commission_kobo<=worker_award_gross_kobo and
    worker_award_gross_kobo::numeric=commission_kobo::numeric+worker_net_kobo::numeric),
  check ((worker_award_gross_kobo=0)=(worker_recipient_id is null)),
  check ((poster_refund_gross_kobo=0)=(poster_recipient_id is null)),
  check ((outcome='full_worker_award' and worker_award_gross_kobo=gross_principal_kobo
      and poster_refund_gross_kobo=0 and retained_hold_gross_kobo=0) or
    (outcome='full_poster_refund' and worker_award_gross_kobo=0
      and poster_refund_gross_kobo=gross_principal_kobo and retained_hold_gross_kobo=0) or
    (outcome='split' and worker_award_gross_kobo>0 and poster_refund_gross_kobo>0
      and retained_hold_gross_kobo=0) or
    (outcome='no_action' and worker_award_gross_kobo=0 and poster_refund_gross_kobo=0
      and retained_hold_gross_kobo=gross_principal_kobo)),
  check ((worker_award_gross_kobo=0 and commission_kobo=0 and worker_net_kobo=0) or
    (worker_award_gross_kobo>0 and commission_kobo=app_private.calculate_commission_kobo(worker_award_gross_kobo)))
);
create index assignment_case_decision_latest_idx
  on app_private.assignment_case_decision_versions(case_id,decision_version desc);

create table app_private.assignment_case_decision_approvals (
  approval_id uuid primary key default pg_catalog.gen_random_uuid(),
  decision_id uuid not null,
  decision_version integer not null,
  decision_sha256 bytea not null check (pg_catalog.octet_length(decision_sha256)=32),
  approval_number smallint not null check (approval_number in (1,2)),
  approver_id uuid not null references auth.users(id) on delete restrict,
  financial_grant_id uuid not null references app_private.staff_grants(grant_id) on delete restrict,
  created_at timestamptz not null default pg_catalog.now(),
  foreign key(decision_id,decision_version,decision_sha256)
    references app_private.assignment_case_decision_versions(decision_id,decision_version,decision_sha256)
    on delete restrict,
  unique(decision_id,approval_number),
  unique(decision_id,approver_id)
);
create index assignment_case_decision_approvals_decision_idx
  on app_private.assignment_case_decision_approvals(decision_id,approval_number);

create table app_private.assignment_case_decision_nonresponse_signoffs (
  signoff_id uuid primary key default pg_catalog.gen_random_uuid(),
  decision_id uuid not null,
  decision_version integer not null,
  decision_sha256 bytea not null check (pg_catalog.octet_length(decision_sha256)=32),
  assessment_id uuid not null references app_private.assignment_case_nonresponse_assessments(assessment_id) on delete restrict,
  case_id uuid not null references app_private.assignment_cases(case_id) on delete restrict,
  senior_id uuid not null references auth.users(id) on delete restrict,
  senior_grant_id uuid not null references app_private.staff_grants(grant_id) on delete restrict,
  contact_set_sha256 bytea not null check (pg_catalog.octet_length(contact_set_sha256)=32),
  substantive_reasoning text not null check (char_length(btrim(substantive_reasoning)) between 100 and 2000),
  created_at timestamptz not null default pg_catalog.now(),
  foreign key(decision_id,decision_version,decision_sha256)
    references app_private.assignment_case_decision_versions(decision_id,decision_version,decision_sha256)
    on delete restrict,
  unique(decision_id)
);

create function app_private.reject_case_decision_history_mutation()
returns trigger language plpgsql set search_path = '' as $function$
begin
  raise exception using errcode='55000',message='case_decision_history_is_immutable';
end;
$function$;
create trigger assignment_case_decision_versions_immutable before update or delete
on app_private.assignment_case_decision_versions for each row
execute function app_private.reject_case_decision_history_mutation();
create trigger assignment_case_decision_approvals_immutable before update or delete
on app_private.assignment_case_decision_approvals for each row
execute function app_private.reject_case_decision_history_mutation();
create trigger assignment_case_decision_nonresponse_signoffs_immutable before update or delete
on app_private.assignment_case_decision_nonresponse_signoffs for each row
execute function app_private.reject_case_decision_history_mutation();

create or replace function app_private.guard_assignment_case_lifecycle()
returns trigger language plpgsql set search_path = '' as $function$
declare
  v_transition text;
begin
  if tg_op='DELETE' then
    raise exception using errcode='55000',message='case_lifecycle_cannot_be_deleted';
  end if;
  v_transition:=coalesce(pg_catalog.current_setting('app.assignment_case_transition',true),'');
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
     or new.closed_at is distinct from old.closed_at
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
    if old.lifecycle_status not in ('verifying','decision_made')
       or new.lifecycle_status<>'verifying'
       or new.reviewer_id is distinct from old.reviewer_id then
      raise exception using errcode='55000',message='invalid_case_lifecycle_transition';
    end if;
  elsif v_transition='approve_case_decision' then
    if old.lifecycle_status<>'verifying' or new.lifecycle_status<>'decision_made'
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

create function app_private.case_staff_principal_is_human(p_actor uuid)
returns boolean language sql stable security definer set search_path = '' as $function$
  select exists(select 1 from auth.users u where u.id=p_actor
    and u.raw_app_meta_data->>'staff_principal_kind'='human')
$function$;
revoke all on function app_private.case_staff_principal_is_human(uuid)
  from public,anon,authenticated,service_role;

create function app_private.case_decision_evidence_snapshot(
  p_case_id uuid,p_nonresponse_assessment_id uuid
) returns jsonb language plpgsql stable security definer set search_path = '' as $function$
declare
  v_case app_private.assignment_cases%rowtype;
  v_assignment app_private.assignments%rowtype;
  v_terms app_private.job_terms_versions%rowtype;
  v_hold app_private.assignment_holds%rowtype;
  v_result jsonb;
begin
  select * into v_case from app_private.assignment_cases where case_id=p_case_id;
  select * into v_assignment from app_private.assignments where assignment_id=v_case.assignment_id;
  select * into v_terms from app_private.job_terms_versions
    where job_id=v_assignment.job_id and terms_version=v_case.terms_version;
  select * into v_hold from app_private.assignment_holds where hold_id=v_case.hold_id;
  select pg_catalog.jsonb_build_object(
    'case_id',v_case.case_id,
    'case_version',v_case.version,
    'assignment_id',v_case.assignment_id,
    'allocation_id',v_case.allocation_id,
    'prior_work_state',v_case.prior_work_state,
    'report',pg_catalog.jsonb_build_object(
      'reason_code',v_hold.reason_code,
      'narrative_sha256',pg_catalog.encode(extensions.digest(v_hold.narrative,'sha256'),'hex'),
      'desired_outcome_sha256',pg_catalog.encode(extensions.digest(v_hold.desired_outcome,'sha256'),'hex'),
      'follow_up_sha256',case when v_hold.follow_up is null then null
        else pg_catalog.encode(extensions.digest(v_hold.follow_up,'sha256'),'hex') end),
    'terms',pg_catalog.jsonb_build_object(
      'version',v_terms.terms_version,'sha256',pg_catalog.encode(v_terms.terms_sha256,'hex'),
      'title',v_terms.title,'description',v_terms.description,'category_slug',v_terms.category_slug,
      'location_type',v_terms.location_type,'location_detail',v_terms.location_detail,
      'gross_per_worker_kobo',v_terms.gross_per_worker_kobo::text,'slot_count',v_terms.slot_count,
      'gross_total_kobo',v_terms.gross_total_kobo::text,
      'application_deadline_at',v_terms.application_deadline_at,'needed_by_at',v_terms.needed_by_at,
      'start_requirements',v_terms.start_requirements,'application_note',v_terms.application_note),
    'conversation',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'message_id',m.message_id,'sequence',m.sequence::text,
      'sender_role',case when m.sender_id=v_assignment.worker_id then 'worker' else 'poster' end,
      'body_sha256',pg_catalog.encode(extensions.digest(m.body,'sha256'),'hex'),
      'created_at',m.created_at) order by m.sequence)
      from app_private.thread_messages m where m.thread_id=v_case.thread_id
        and m.sequence<=v_case.thread_through_sequence),'[]'::jsonb),
    'triage',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'priority',t.priority,'rationale',t.rationale,'acknowledged_at',t.acknowledged_at)
      order by t.case_version,t.triage_id)
      from app_private.assignment_case_triage_records t where t.case_id=p_case_id),'[]'::jsonb),
    'contacts',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'attempt_id',c.contact_attempt_id,'target_party_role',c.target_party_role,
      'channel',c.channel,'result',c.result,'attribution',c.attribution,
      'result_note',c.result_note,'recorded_by',c.recorded_by,'recorded_at',c.recorded_at)
      order by c.recorded_at,c.contact_attempt_id)
      from app_private.assignment_case_contact_attempts c where c.case_id=p_case_id),'[]'::jsonb),
    'requests',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'request_number',r.request_number,'target_party_role',r.target_party_role,
      'request_kind',r.request_kind,'request_scope',r.request_scope,'prompt',r.prompt,
      'status',r.status,'created_by',r.created_by,'created_at',r.created_at,
      'responses',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'actor_id',x.actor_id,'response_sha256',pg_catalog.encode(extensions.digest(x.response,'sha256'),'hex'),
        'created_at',x.created_at) order by x.created_at,x.response_id)
        from app_private.assignment_case_information_responses x where x.request_id=r.request_id),'[]'::jsonb))
      order by r.request_number)
      from app_private.assignment_case_information_requests r where r.case_id=p_case_id),'[]'::jsonb),
    'verified_facts',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'fact_code',f.fact_code,'finding',f.finding,'staff_reasoning',f.staff_reasoning,
      'recorded_at',f.created_at,'reviewer_id',f.reviewer_id)
      order by f.case_version,f.fact_review_id)
      from app_private.assignment_case_fact_reviews f where f.case_id=p_case_id),'[]'::jsonb),
    'files',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'evidence_number',f.evidence_number,'content_type',f.content_type,'size_bytes',f.size_bytes,
      'content_sha256',pg_catalog.encode(f.content_sha256,'hex'),'safety_state',f.safety_state,
      'source_kind',f.source_kind,'created_at',f.created_at)
      order by f.evidence_number)
      from app_private.case_evidence_files f where f.case_id=p_case_id),'[]'::jsonb),
    'selected_nonresponse_assessment',case when p_nonresponse_assessment_id is null then null else
      (select pg_catalog.jsonb_build_object('assessment_id',n.assessment_id,
        'target_party_role',n.target_party_role,'case_version',n.case_version,
        'contact_attempt_count',n.contact_attempt_count,'distinct_channel_count',n.distinct_channel_count,
        'contact_set_sha256',pg_catalog.encode(n.contact_set_sha256,'hex'),
        'substantive_reasoning',n.substantive_reasoning,'reviewer_id',n.reviewer_id,
        'senior_signoff',s.signoff_id is not null)
       from app_private.assignment_case_nonresponse_assessments n
       left join app_private.assignment_case_nonresponse_signoffs s using(assessment_id)
       where n.assessment_id=p_nonresponse_assessment_id and n.case_id=p_case_id) end
  ) into v_result;
  return v_result;
end;
$function$;

create function app_private.propose_case_decision_for_actor(
  p_actor uuid,p_case_id uuid,p_expected_case_version integer,p_payload jsonb,
  p_auth_aal text,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_case app_private.assignment_cases%rowtype;
  v_assignment app_private.assignments%rowtype;
  v_allocation app_private.principal_allocations%rowtype;
  v_hold app_private.assignment_holds%rowtype;
  v_assessment app_private.assignment_case_nonresponse_assessments%rowtype;
  v_dispute_grant uuid;
  v_financial_grant uuid;
  v_account_status text;
  v_outcome text;
  v_award bigint;
  v_refund bigint;
  v_retained bigint;
  v_commission bigint;
  v_worker_net bigint;
  v_version integer;
  v_snapshot jsonb;
  v_snapshot_hash bytea;
  v_decision_hash bytea;
  v_decision_id uuid;
  v_decision app_private.assignment_case_decision_versions%rowtype;
  v_request_hash bytea;
  v_existing app_private.case_command_idempotency%rowtype;
  v_result jsonb;
  v_recipient_worker uuid;
  v_recipient_poster uuid;
  v_nonresponse_id uuid;
  v_seq integer;
begin
  if p_actor is null or p_case_id is null or p_idempotency_key is null
     or p_expected_case_version is null or p_payload is null
     or pg_catalog.jsonb_typeof(p_payload)<>'object'
     or p_payload - array['outcome','award_gross_kobo','public_explanation',
       'nonresponse_assessment_id']::text[]<>'{}'::jsonb then
    raise exception using errcode='22023',message='invalid_case_command';
  end if;
  if p_auth_aal is distinct from 'aal2' then
    raise exception using errcode='42501',message='case_access_denied';
  end if;
  if pg_catalog.char_length(pg_catalog.btrim(coalesce(p_payload->>'public_explanation','')))
       not between 20 and 2000
     or p_payload->>'public_explanation' ~* '(https?://|www[.]|[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12})'
     or coalesce(p_payload->>'outcome','') not in
       ('full_worker_award','full_poster_refund','split','no_action')
     or coalesce(p_payload->>'award_gross_kobo','') !~ '^(0|[1-9][0-9]{0,8})$'
     or (p_payload ? 'nonresponse_assessment_id' and
       p_payload->'nonresponse_assessment_id'<>'null'::jsonb and
       coalesce(p_payload->>'nonresponse_assessment_id','') !~* '^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$') then
    raise exception using errcode='22023',message='invalid_case_decision';
  end if;
  v_outcome:=p_payload->>'outcome';
  v_award:=(p_payload->>'award_gross_kobo')::bigint;
  v_nonresponse_id:=nullif(p_payload->>'nonresponse_assessment_id','')::uuid;
  v_request_hash:=extensions.digest(pg_catalog.jsonb_build_object(
    'case_id',p_case_id,'expected_case_version',p_expected_case_version,'payload',p_payload)::text,'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    p_actor::text||':propose_case_decision:'||p_idempotency_key::text,428118));
  select * into v_case from app_private.assignment_cases where case_id=p_case_id for update;
  if not found then raise exception using errcode='P0002',message='case_not_found'; end if;
  select * into v_assignment from app_private.assignments where assignment_id=v_case.assignment_id for share;
  select account_status into v_account_status from app_private.identity_accounts where user_id=p_actor for share;
  select g.grant_id into v_dispute_grant from app_private.staff_grants g
    where g.user_id=p_actor and g.capability='dispute_review' and g.revoked_at is null for share;
  select g.grant_id into v_financial_grant from app_private.staff_grants g
    where g.user_id=p_actor and g.capability='financial_approve' and g.revoked_at is null for share;
  if v_account_status is distinct from 'active' or v_case.reviewer_id is distinct from p_actor
     or p_actor in (v_assignment.worker_id,v_assignment.poster_id)
     or v_dispute_grant is null or v_financial_grant is null
     or not app_private.case_staff_principal_is_human(p_actor)
     or not app_private.lock_case_reviewer_scope(p_actor,p_auth_aal) then
    raise exception using errcode='42501',message='case_access_denied';
  end if;
  select * into v_existing from app_private.case_command_idempotency
    where actor_id=p_actor and command_name='propose_case_decision' and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.request_sha256<>v_request_hash then
      raise exception using errcode='23505',message='idempotency_conflict';
    end if;
    return v_existing.response;
  end if;
  if v_case.lifecycle_status not in ('verifying','decision_made')
     or v_case.version<>p_expected_case_version then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  select * into v_allocation from app_private.principal_allocations
    where allocation_id=v_case.allocation_id for update;
  select * into v_hold from app_private.assignment_holds where hold_id=v_case.hold_id;
  if v_allocation.status<>'dispute_held' or v_allocation.assignment_id<>v_assignment.assignment_id
     or v_allocation.gross_principal_kobo<>v_assignment.gross_principal_kobo
     or v_case.terms_version<>v_assignment.terms_version
     or v_case.terms_sha256<>v_assignment.terms_sha256 then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  if v_hold.reason_code='unresponsive_no_show' and v_nonresponse_id is null then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  if v_award>v_allocation.gross_principal_kobo then
    raise exception using errcode='22023',message='invalid_case_decision';
  end if;
  if v_outcome='full_worker_award' and v_award<>v_allocation.gross_principal_kobo then
    raise exception using errcode='22023',message='invalid_case_decision';
  elsif v_outcome='full_poster_refund' and v_award<>0 then
    raise exception using errcode='22023',message='invalid_case_decision';
  elsif v_outcome='split' and v_award not between 1 and v_allocation.gross_principal_kobo-1 then
    raise exception using errcode='22023',message='invalid_case_decision';
  elsif v_outcome='no_action' and v_award<>0 then
    raise exception using errcode='22023',message='invalid_case_decision';
  end if;
  v_refund:=case when v_outcome in ('full_poster_refund','split')
    then v_allocation.gross_principal_kobo-v_award else 0 end;
  v_retained:=case when v_outcome='no_action' then v_allocation.gross_principal_kobo else 0 end;
  v_commission:=case when v_award=0 then 0 else app_private.calculate_commission_kobo(v_award) end;
  v_worker_net:=v_award-v_commission;
  v_recipient_worker:=case when v_award>0 then v_assignment.worker_id else null end;
  v_recipient_poster:=case when v_refund>0 then v_assignment.poster_id else null end;
  if v_nonresponse_id is not null then
    select * into v_assessment from app_private.assignment_case_nonresponse_assessments
      where assessment_id=v_nonresponse_id and case_id=p_case_id for share;
    if not found or not exists(select 1 from app_private.assignment_case_nonresponse_signoffs s
        join app_private.staff_grants g on g.grant_id=s.senior_grant_id and g.revoked_at is null
        where s.assessment_id=v_nonresponse_id and s.contact_set_sha256=v_assessment.contact_set_sha256)
       or exists(select 1 from app_private.assignment_case_contact_attempts c
          where c.case_id=p_case_id and c.target_party_role=v_assessment.target_party_role
            and c.result='no_response' and c.recorded_at>v_assessment.created_at) then
      raise exception using errcode='P0001',message='stale_state';
    end if;
  end if;
  v_snapshot:=app_private.case_decision_evidence_snapshot(p_case_id,v_nonresponse_id);
  if v_nonresponse_id is not null and v_snapshot->'selected_nonresponse_assessment' is null then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  v_snapshot_hash:=extensions.digest(v_snapshot::text,'sha256');
  select coalesce(max(decision_version),0)+1 into v_version
    from app_private.assignment_case_decision_versions where case_id=p_case_id;
  v_decision_hash:=extensions.digest(pg_catalog.jsonb_build_object(
    'case_id',p_case_id,'decision_version',v_version,'proposal_case_version',v_case.version+1,
    'assignment_id',v_assignment.assignment_id,'allocation_id',v_allocation.allocation_id,
    'proposed_by',p_actor,'outcome',v_outcome,'reason_code',v_hold.reason_code,
    'public_explanation',pg_catalog.btrim(p_payload->>'public_explanation'),
    'terms_version',v_case.terms_version,'terms_sha256',pg_catalog.encode(v_case.terms_sha256,'hex'),
    'prior_work_state',v_case.prior_work_state,'gross_principal_kobo',v_allocation.gross_principal_kobo::text,
    'worker_award_gross_kobo',v_award::text,'poster_refund_gross_kobo',v_refund::text,
    'retained_hold_gross_kobo',v_retained::text,'commission_kobo',v_commission::text,
    'worker_net_kobo',v_worker_net::text,'worker_recipient_id',v_recipient_worker,
    'poster_recipient_id',v_recipient_poster,'evidence_snapshot_sha256',pg_catalog.encode(v_snapshot_hash,'hex'))::text,'sha256');
  insert into app_private.assignment_case_decision_versions(
    case_id,decision_version,proposal_case_version,assignment_id,allocation_id,proposed_by,
    proposer_dispute_grant_id,proposer_financial_grant_id,outcome,reason_code,public_explanation,
    terms_version,terms_sha256,prior_work_state,gross_principal_kobo,worker_award_gross_kobo,
    poster_refund_gross_kobo,retained_hold_gross_kobo,commission_kobo,worker_net_kobo,
    worker_recipient_id,poster_recipient_id,nonresponse_assessment_id,evidence_snapshot,
    evidence_snapshot_sha256,decision_sha256)
  values(p_case_id,v_version,v_case.version+1,v_assignment.assignment_id,v_allocation.allocation_id,
    p_actor,v_dispute_grant,v_financial_grant,v_outcome,v_hold.reason_code,
    pg_catalog.btrim(p_payload->>'public_explanation'),v_case.terms_version,v_case.terms_sha256,
    v_case.prior_work_state,v_allocation.gross_principal_kobo,v_award,v_refund,v_retained,
    v_commission,v_worker_net,v_recipient_worker,v_recipient_poster,v_nonresponse_id,v_snapshot,
    v_snapshot_hash,v_decision_hash) returning * into v_decision;
  insert into app_private.assignment_case_decision_approvals(
    decision_id,decision_version,decision_sha256,approval_number,approver_id,financial_grant_id
  ) values(v_decision.decision_id,v_version,v_decision_hash,1,p_actor,v_financial_grant);
  perform pg_catalog.set_config('app.assignment_case_transition','propose_case_decision',true);
  update app_private.assignment_cases set lifecycle_status='verifying',version=version+1
    where case_id=p_case_id;
  perform pg_catalog.set_config('app.assignment_case_transition','',true);
  insert into app_private.assignment_case_access_audit(case_id,actor_id,action)
    values(p_case_id,p_actor,'case_decision_proposed');
  select coalesce(max(sequence),0)+1 into v_seq from app_private.assignment_case_events where case_id=p_case_id;
  insert into app_private.assignment_case_events(case_id,sequence,actor_id,audience,event_type,payload)
    values(p_case_id,v_seq,p_actor,'staff','case_decision_proposed',pg_catalog.jsonb_build_object(
      'decision_version',v_version,'decision_sha256',pg_catalog.encode(v_decision_hash,'hex'),
      'outcome',v_outcome));
  v_result:=pg_catalog.jsonb_build_object('case_id',p_case_id,'status','verifying',
    'case_version',v_case.version+1,'decision_version',v_version,'outcome',v_outcome,
    'gross_principal_kobo',v_allocation.gross_principal_kobo::text,
    'worker_award_gross_kobo',v_award::text,'poster_refund_gross_kobo',v_refund::text,
    'retained_hold_gross_kobo',v_retained::text,'commission_kobo',v_commission::text,
    'worker_net_kobo',v_worker_net::text,'decision_sha256',pg_catalog.encode(v_decision_hash,'hex'),
    'approval_count',1,'required_approvals',2,'approved',false,'proposed',true);
  insert into app_private.case_command_idempotency(actor_id,command_name,idempotency_key,request_sha256,response)
    values(p_actor,'propose_case_decision',p_idempotency_key,v_request_hash,v_result);
  return v_result;
end;
$function$;

create function app_private.approve_case_decision_for_actor(
  p_actor uuid,p_case_id uuid,p_decision_version integer,p_expected_case_version integer,
  p_auth_aal text,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_case app_private.assignment_cases%rowtype;
  v_assignment app_private.assignments%rowtype;
  v_decision app_private.assignment_case_decision_versions%rowtype;
  v_approval app_private.assignment_case_decision_approvals%rowtype;
  v_actor_role text;
  v_account_status text;
  v_grant_id uuid;
  v_request_hash bytea;
  v_existing app_private.case_command_idempotency%rowtype;
  v_result jsonb;
  v_seq integer;
begin
  if p_actor is null or p_case_id is null or p_decision_version is null or p_decision_version<1
     or p_expected_case_version is null or p_idempotency_key is null then
    raise exception using errcode='22023',message='invalid_case_command';
  end if;
  if p_auth_aal is distinct from 'aal2' then
    raise exception using errcode='42501',message='case_access_denied';
  end if;
  v_request_hash:=extensions.digest(pg_catalog.jsonb_build_object('case_id',p_case_id,
    'decision_version',p_decision_version,'expected_case_version',p_expected_case_version)::text,'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    p_actor::text||':approve_case_decision:'||p_idempotency_key::text,428118));
  select * into v_case from app_private.assignment_cases where case_id=p_case_id for update;
  if not found then raise exception using errcode='P0002',message='case_not_found'; end if;
  select * into v_assignment from app_private.assignments where assignment_id=v_case.assignment_id for share;
  v_actor_role:=case when p_actor=v_assignment.worker_id then 'worker'
    when p_actor=v_assignment.poster_id then 'poster' else null end;
  select account_status into v_account_status from app_private.identity_accounts where user_id=p_actor for share;
  select g.grant_id into v_grant_id from app_private.staff_grants g
    where g.user_id=p_actor and g.capability='financial_approve' and g.revoked_at is null for share;
  if v_account_status is distinct from 'active' or v_actor_role is not null or v_grant_id is null
     or not app_private.case_staff_principal_is_human(p_actor) then
    raise exception using errcode='42501',message='case_access_denied';
  end if;
  select * into v_existing from app_private.case_command_idempotency
    where actor_id=p_actor and command_name='approve_case_decision' and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.request_sha256<>v_request_hash then
      raise exception using errcode='23505',message='idempotency_conflict';
    end if;
    return v_existing.response;
  end if;
  select * into v_decision from app_private.assignment_case_decision_versions
    where case_id=p_case_id and decision_version=p_decision_version for update;
  if not found then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  if exists(select 1 from app_private.assignment_case_decision_approvals
      where decision_id=v_decision.decision_id and approver_id=p_actor) then
    raise exception using errcode='42501',message='case_access_denied';
  end if;
  if v_case.lifecycle_status<>'verifying'
     or v_case.version<>p_expected_case_version or v_case.version<>v_decision.proposal_case_version
     or not exists(select 1 from app_private.principal_allocations a
       where a.allocation_id=v_decision.allocation_id and a.assignment_id=v_decision.assignment_id
         and a.status='dispute_held' and a.gross_principal_kobo=v_decision.gross_principal_kobo) then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  select * into v_approval from app_private.assignment_case_decision_approvals
    where decision_id=v_decision.decision_id and approval_number=1 for share;
  if not found or v_approval.approver_id=v_decision.proposed_by
     and v_approval.approver_id=p_actor
     or v_approval.decision_sha256<>v_decision.decision_sha256
     or not exists(select 1 from app_private.staff_grants g
        where g.grant_id=v_approval.financial_grant_id and g.user_id=v_approval.approver_id
          and g.capability='financial_approve' and g.revoked_at is null)
     or v_approval.financial_grant_id<>v_decision.proposer_financial_grant_id
     or not exists(select 1 from app_private.staff_grants g
        where g.grant_id=v_decision.proposer_dispute_grant_id and g.user_id=v_decision.proposed_by
          and g.capability='dispute_review' and g.revoked_at is null)
     or not exists(select 1 from app_private.identity_accounts a
        where a.user_id=v_approval.approver_id and a.account_status='active')
     or not app_private.case_staff_principal_is_human(v_approval.approver_id)
     or not app_private.case_staff_principal_is_human(v_decision.proposed_by) then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  if v_decision.nonresponse_assessment_id is not null and not exists(
      select 1 from app_private.assignment_case_decision_nonresponse_signoffs s
      join app_private.staff_grants g on g.grant_id=s.senior_grant_id and g.revoked_at is null
      where s.decision_id=v_decision.decision_id
        and s.decision_version=v_decision.decision_version
        and s.decision_sha256=v_decision.decision_sha256
        and s.assessment_id=v_decision.nonresponse_assessment_id
        and s.senior_id<>v_decision.proposed_by
        and app_private.case_staff_principal_is_human(s.senior_id)) then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  insert into app_private.assignment_case_decision_approvals(
    decision_id,decision_version,decision_sha256,approval_number,approver_id,financial_grant_id
  ) values(v_decision.decision_id,v_decision.decision_version,v_decision.decision_sha256,2,p_actor,v_grant_id);
  perform pg_catalog.set_config('app.assignment_case_transition','approve_case_decision',true);
  update app_private.assignment_cases set lifecycle_status='decision_made',version=version+1
    where case_id=p_case_id;
  perform pg_catalog.set_config('app.assignment_case_transition','',true);
  insert into app_private.assignment_case_access_audit(case_id,actor_id,action)
    values(p_case_id,p_actor,'case_decision_approved');
  select coalesce(max(sequence),0)+1 into v_seq from app_private.assignment_case_events where case_id=p_case_id;
  insert into app_private.assignment_case_events(case_id,sequence,actor_id,audience,event_type,payload)
    values(p_case_id,v_seq,p_actor,'staff','case_decision_approved',pg_catalog.jsonb_build_object(
      'decision_version',v_decision.decision_version,
      'decision_sha256',pg_catalog.encode(v_decision.decision_sha256,'hex'),'approval_count',2));
  v_result:=pg_catalog.jsonb_build_object('case_id',p_case_id,'status','decision_made',
    'case_version',v_case.version+1,'decision_version',v_decision.decision_version,
    'outcome',v_decision.outcome,'gross_principal_kobo',v_decision.gross_principal_kobo::text,
    'worker_award_gross_kobo',v_decision.worker_award_gross_kobo::text,
    'poster_refund_gross_kobo',v_decision.poster_refund_gross_kobo::text,
    'retained_hold_gross_kobo',v_decision.retained_hold_gross_kobo::text,
    'commission_kobo',v_decision.commission_kobo::text,'worker_net_kobo',v_decision.worker_net_kobo::text,
    'decision_sha256',pg_catalog.encode(v_decision.decision_sha256,'hex'),
    'approval_count',2,'required_approvals',2,'approved',true,'proposed',false);
  insert into app_private.case_command_idempotency(actor_id,command_name,idempotency_key,request_sha256,response)
    values(p_actor,'approve_case_decision',p_idempotency_key,v_request_hash,v_result);
  return v_result;
end;
$function$;

create function app_private.signoff_case_decision_nonresponse_for_actor(
  p_actor uuid,p_case_id uuid,p_decision_version integer,p_expected_case_version integer,
  p_substantive_reasoning text,p_auth_aal text,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_case app_private.assignment_cases%rowtype;
  v_assignment app_private.assignments%rowtype;
  v_decision app_private.assignment_case_decision_versions%rowtype;
  v_assessment app_private.assignment_case_nonresponse_assessments%rowtype;
  v_grant_id uuid;
  v_account_status text;
  v_attempt_count integer;
  v_channel_count integer;
  v_contact_hash bytea;
  v_request_hash bytea;
  v_existing app_private.case_command_idempotency%rowtype;
  v_result jsonb;
  v_seq integer;
begin
  if p_actor is null or p_case_id is null or p_decision_version is null or p_decision_version<1
     or p_expected_case_version is null or p_idempotency_key is null
     or pg_catalog.char_length(pg_catalog.btrim(coalesce(p_substantive_reasoning,''))) not between 100 and 2000 then
    raise exception using errcode='22023',message='invalid_case_command';
  end if;
  if p_auth_aal is distinct from 'aal2' then
    raise exception using errcode='42501',message='case_access_denied';
  end if;
  v_request_hash:=extensions.digest(pg_catalog.jsonb_build_object('case_id',p_case_id,
    'decision_version',p_decision_version,'expected_case_version',p_expected_case_version,
    'substantive_reasoning',pg_catalog.btrim(p_substantive_reasoning))::text,'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    p_actor::text||':signoff_decision_nonresponse:'||p_idempotency_key::text,428118));
  select * into v_case from app_private.assignment_cases where case_id=p_case_id for update;
  if not found then raise exception using errcode='P0002',message='case_not_found'; end if;
  select * into v_assignment from app_private.assignments where assignment_id=v_case.assignment_id for share;
  select account_status into v_account_status from app_private.identity_accounts where user_id=p_actor for share;
  select g.grant_id into v_grant_id from app_private.staff_grants g
    where g.user_id=p_actor and g.capability='case_senior_signoff' and g.revoked_at is null for share;
  if v_account_status is distinct from 'active' or p_actor in (v_assignment.worker_id,v_assignment.poster_id)
     or p_actor=v_case.reviewer_id or v_grant_id is null
     or not app_private.case_staff_principal_is_human(p_actor) then
    raise exception using errcode='42501',message='case_access_denied';
  end if;
  select * into v_existing from app_private.case_command_idempotency
    where actor_id=p_actor and command_name='signoff_decision_nonresponse'
      and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.request_sha256<>v_request_hash then
      raise exception using errcode='23505',message='idempotency_conflict';
    end if;
    return v_existing.response;
  end if;
  select * into v_decision from app_private.assignment_case_decision_versions
    where case_id=p_case_id and decision_version=p_decision_version for update;
  if not found or v_decision.nonresponse_assessment_id is null
     or v_case.lifecycle_status<>'verifying' or v_case.version<>p_expected_case_version
     or v_case.version<>v_decision.proposal_case_version then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  select * into v_assessment from app_private.assignment_case_nonresponse_assessments
    where assessment_id=v_decision.nonresponse_assessment_id and case_id=p_case_id for share;
  if not found or not exists(select 1 from app_private.assignment_case_nonresponse_signoffs s
      join app_private.staff_grants g on g.grant_id=s.senior_grant_id and g.revoked_at is null
      where s.assessment_id=v_assessment.assessment_id
        and s.contact_set_sha256=v_assessment.contact_set_sha256) then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  select count(*),count(distinct channel),extensions.digest(
    coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_array(contact_attempt_id,channel,result,recorded_at)
      order by recorded_at,contact_attempt_id),'[]'::jsonb)::text,'sha256')
    into v_attempt_count,v_channel_count,v_contact_hash
  from app_private.assignment_case_contact_attempts
  where case_id=p_case_id and target_party_role=v_assessment.target_party_role and result='no_response';
  if v_attempt_count<2 or v_channel_count<2 or v_contact_hash<>v_assessment.contact_set_sha256
     or exists(select 1 from app_private.assignment_case_decision_nonresponse_signoffs
       where decision_id=v_decision.decision_id) then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  insert into app_private.assignment_case_decision_nonresponse_signoffs(
    decision_id,decision_version,decision_sha256,assessment_id,case_id,senior_id,senior_grant_id,
    contact_set_sha256,substantive_reasoning
  ) values(v_decision.decision_id,v_decision.decision_version,v_decision.decision_sha256,
    v_assessment.assessment_id,p_case_id,p_actor,v_grant_id,v_contact_hash,
    pg_catalog.btrim(p_substantive_reasoning));
  insert into app_private.assignment_case_access_audit(case_id,actor_id,action)
    values(p_case_id,p_actor,'case_decision_nonresponse_signed');
  select coalesce(max(sequence),0)+1 into v_seq from app_private.assignment_case_events where case_id=p_case_id;
  insert into app_private.assignment_case_events(case_id,sequence,actor_id,audience,event_type,payload)
    values(p_case_id,v_seq,p_actor,'staff','case_decision_nonresponse_signed',pg_catalog.jsonb_build_object(
      'decision_version',v_decision.decision_version,
      'decision_sha256',pg_catalog.encode(v_decision.decision_sha256,'hex'),'signed_off',true));
  v_result:=pg_catalog.jsonb_build_object('case_id',p_case_id,'status','verifying',
    'case_version',v_case.version,'decision_version',v_decision.decision_version,
    'decision_sha256',pg_catalog.encode(v_decision.decision_sha256,'hex'),'signed_off',true);
  insert into app_private.case_command_idempotency(actor_id,command_name,idempotency_key,request_sha256,response)
    values(p_actor,'signoff_decision_nonresponse',p_idempotency_key,v_request_hash,v_result);
  return v_result;
end;
$function$;

create or replace function app_private.case_investigation_projection(
  p_case_id uuid,p_actor uuid,p_staff boolean
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_assignment app_private.assignments%rowtype;
  v_role text;
  v_triage jsonb;
  v_contacts jsonb;
  v_requests jsonb;
  v_facts jsonb;
  v_notes jsonb;
  v_nonresponse jsonb;
  v_files jsonb;
  v_decision jsonb;
begin
  select a.* into v_assignment from app_private.assignment_cases c
    join app_private.assignments a on a.assignment_id=c.assignment_id where c.case_id=p_case_id;
  if not found then return null; end if;
  v_role:=case when p_actor=v_assignment.worker_id then 'worker'
    when p_actor=v_assignment.poster_id then 'poster' else null end;
  if p_staff then
    select coalesce(jsonb_agg(jsonb_build_object('priority',priority,'rationale',rationale,
      'acknowledged_at',acknowledged_at) order by case_version,triage_id),'[]'::jsonb)
      into v_triage from app_private.assignment_case_triage_records where case_id=p_case_id;
    select coalesce(jsonb_agg(jsonb_build_object('target_party_role',target_party_role,'channel',channel,
      'result',result,'result_note',result_note,'attribution',attribution,'recorded_at',recorded_at)
      order by recorded_at,contact_attempt_id),'[]'::jsonb)
      into v_contacts from app_private.assignment_case_contact_attempts where case_id=p_case_id;
    select coalesce(jsonb_agg(jsonb_build_object('request_number',r.request_number,'target_party_role',r.target_party_role,
      'request_kind',r.request_kind,'prompt',r.prompt,'status',r.status,'created_at',r.created_at,
      'response',x.response,'responded_at',x.created_at) order by r.request_number),'[]'::jsonb)
      into v_requests from app_private.assignment_case_information_requests r
      left join lateral (select response,created_at from app_private.assignment_case_information_responses
        where request_id=r.request_id order by created_at limit 1) x on true where r.case_id=p_case_id;
    select coalesce(jsonb_agg(jsonb_build_object('fact_code',fact_code,'finding',finding,
      'staff_reasoning',staff_reasoning,'recorded_at',created_at) order by case_version,fact_review_id),'[]'::jsonb)
      into v_facts from app_private.assignment_case_fact_reviews where case_id=p_case_id;
    select coalesce(jsonb_agg(jsonb_build_object('note',note,'created_at',created_at)
      order by created_at,note_id),'[]'::jsonb)
      into v_notes from app_private.assignment_case_internal_notes where case_id=p_case_id;
    select coalesce(jsonb_agg(jsonb_build_object('target_party_role',a.target_party_role,
      'contact_attempt_count',a.contact_attempt_count,'distinct_channel_count',a.distinct_channel_count,
      'substantive_reasoning',a.substantive_reasoning,'assessed_at',a.created_at,
      'senior_signed_off',s.signoff_id is not null,'senior_signoff_reasoning',s.substantive_reasoning,
      'signed_off_at',s.signed_at) order by a.created_at,a.assessment_id),'[]'::jsonb)
      into v_nonresponse from app_private.assignment_case_nonresponse_assessments a
      left join app_private.assignment_case_nonresponse_signoffs s using(assessment_id)
      where a.case_id=p_case_id;
    select case when d.decision_id is null then null else jsonb_build_object(
      'decision_version',d.decision_version,'outcome',d.outcome,'reason_code',d.reason_code,
      'public_explanation',d.public_explanation,'gross_principal_kobo',d.gross_principal_kobo::text,
      'worker_award_gross_kobo',d.worker_award_gross_kobo::text,
      'poster_refund_gross_kobo',d.poster_refund_gross_kobo::text,
      'retained_hold_gross_kobo',d.retained_hold_gross_kobo::text,
      'commission_kobo',d.commission_kobo::text,'worker_net_kobo',d.worker_net_kobo::text,
      'terms_version',d.terms_version,'terms_sha256',pg_catalog.encode(d.terms_sha256,'hex'),
      'evidence_item_count',jsonb_array_length(d.evidence_snapshot->'conversation')+
        jsonb_array_length(d.evidence_snapshot->'contacts')+
        jsonb_array_length(d.evidence_snapshot->'requests')+
        jsonb_array_length(d.evidence_snapshot->'verified_facts')+
        jsonb_array_length(d.evidence_snapshot->'files'),
      'evidence_snapshot_sha256',pg_catalog.encode(d.evidence_snapshot_sha256,'hex'),
      'decision_sha256',pg_catalog.encode(d.decision_sha256,'hex'),
      'approval_count',(select count(*)::integer from app_private.assignment_case_decision_approvals ap
        join app_private.staff_grants g on g.grant_id=ap.financial_grant_id and g.user_id=ap.approver_id
          and g.capability='financial_approve' and g.revoked_at is null
        join app_private.identity_accounts ia on ia.user_id=ap.approver_id and ia.account_status='active'
        where ap.decision_id=d.decision_id and ap.decision_sha256=d.decision_sha256
          and app_private.case_staff_principal_is_human(ap.approver_id)),
      'required_approvals',2,'nonresponse_signoff_required',d.nonresponse_assessment_id is not null,
      'nonresponse_signed_off',exists(select 1 from app_private.assignment_case_decision_nonresponse_signoffs s
        join app_private.staff_grants g on g.grant_id=s.senior_grant_id and g.user_id=s.senior_id
          and g.capability='case_senior_signoff' and g.revoked_at is null
        join app_private.identity_accounts ia on ia.user_id=s.senior_id and ia.account_status='active'
        where s.decision_id=d.decision_id and s.decision_sha256=d.decision_sha256
          and app_private.case_staff_principal_is_human(s.senior_id)),
      'created_at',d.created_at,'approved_at',(select ap.created_at
        from app_private.assignment_case_decision_approvals ap
        where ap.decision_id=d.decision_id and ap.approval_number=2),
      'status',case when exists(select 1 from app_private.assignment_case_decision_approvals ap
        where ap.decision_id=d.decision_id and ap.approval_number=2)
          and (select count(*) from app_private.assignment_case_decision_approvals ap
            join app_private.staff_grants g on g.grant_id=ap.financial_grant_id
              and g.user_id=ap.approver_id and g.capability='financial_approve' and g.revoked_at is null
            join app_private.identity_accounts ia on ia.user_id=ap.approver_id and ia.account_status='active'
            where ap.decision_id=d.decision_id and app_private.case_staff_principal_is_human(ap.approver_id))=2
          and (d.nonresponse_assessment_id is null or exists(
            select 1 from app_private.assignment_case_decision_nonresponse_signoffs s
            join app_private.staff_grants g on g.grant_id=s.senior_grant_id and g.user_id=s.senior_id
              and g.capability='case_senior_signoff' and g.revoked_at is null
            join app_private.identity_accounts ia on ia.user_id=s.senior_id and ia.account_status='active'
            where s.decision_id=d.decision_id and s.decision_sha256=d.decision_sha256
              and app_private.case_staff_principal_is_human(s.senior_id))) then 'approved'
        when d.nonresponse_assessment_id is not null and not exists(
          select 1 from app_private.assignment_case_decision_nonresponse_signoffs s
          join app_private.staff_grants g on g.grant_id=s.senior_grant_id and g.user_id=s.senior_id
            and g.capability='case_senior_signoff' and g.revoked_at is null
          join app_private.identity_accounts ia on ia.user_id=s.senior_id and ia.account_status='active'
          where s.decision_id=d.decision_id and s.decision_sha256=d.decision_sha256
            and app_private.case_staff_principal_is_human(s.senior_id))
          then 'awaiting_nonresponse_signoff'
        else 'awaiting_second_approval' end
    ) end into v_decision
    from app_private.assignment_case_decision_versions d
    where d.case_id=p_case_id order by d.decision_version desc limit 1;
  else
    select coalesce(jsonb_agg(jsonb_build_object('request_number',r.request_number,
      'request_kind',r.request_kind,'prompt',r.prompt,'status',r.status,'created_at',r.created_at,
      'response',x.response,'responded_at',x.created_at) order by r.request_number),'[]'::jsonb)
      into v_requests from app_private.assignment_case_information_requests r
      left join lateral (select response,created_at from app_private.assignment_case_information_responses
        where request_id=r.request_id and actor_id=p_actor order by created_at limit 1) x on true
      where r.case_id=p_case_id and r.target_party_role=v_role and r.request_scope='investigation';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('evidence_number',evidence_number,
    'request_number',r.request_number,'content_type',content_type,'size_bytes',size_bytes,
    'safety_state',safety_state,'created_at',f.created_at) order by evidence_number),'[]'::jsonb)
    into v_files from app_private.case_evidence_files f
    left join app_private.assignment_case_information_requests r on r.request_id=f.request_id
    where f.case_id=p_case_id and (p_staff or f.owner_id=p_actor);
  insert into app_private.case_file_access_audit(case_id,actor_id,action)
    values(p_case_id,p_actor,'metadata_read');
  return jsonb_build_object('investigation',case when p_staff then jsonb_build_object(
      'triage',v_triage,'contact_attempts',v_contacts,'requests',v_requests,
      'verified_facts',v_facts,'internal_notes',v_notes,'nonresponse',v_nonresponse,
      'files',v_files,'decision',v_decision)
    else jsonb_build_object('requests',v_requests,'files',v_files) end);
end;
$function$;

create or replace function app_private.case_participant_projection(p_case_id uuid,p_actor uuid)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_case app_private.assignment_cases%rowtype;
  v_assignment app_private.assignments%rowtype;
  v_role text;
  v_timeline jsonb;
  v_total integer;
  v_status text;
begin
  select * into v_case from app_private.assignment_cases where case_id=p_case_id for share;
  if not found then return null; end if;
  select * into v_assignment from app_private.assignments where assignment_id=v_case.assignment_id;
  v_role:=case when p_actor=v_assignment.worker_id then 'worker'
    when p_actor=v_assignment.poster_id then 'poster' else null end;
  if v_role is null then return null; end if;
  select count(*) into v_total from app_private.assignment_case_events
    where case_id=p_case_id and audience in ('participants',v_role);
  select coalesce(pg_catalog.jsonb_agg(x.item order by x.sequence),'[]'::jsonb) into v_timeline
  from (
    select e.sequence,pg_catalog.jsonb_build_object(
      'event_type',e.event_type,'created_at',e.created_at,'details',e.payload
    ) as item
    from app_private.assignment_case_events e
    where e.case_id=p_case_id and e.audience in ('participants',v_role)
    order by e.sequence desc limit 100
  ) x;
  v_status:=case when v_case.lifecycle_status='decision_made' and not exists(
    select 1 from app_private.assignment_case_events e where e.case_id=p_case_id
      and e.event_type='decision_notified') then 'verifying' else v_case.lifecycle_status end;
  return pg_catalog.jsonb_build_object(
    'case_id',v_case.case_id,'assignment_id',v_case.assignment_id,
    'status',v_status,'version',v_case.version,
    'opened_at',v_case.opened_at,'updated_at',v_case.updated_at,
    'timeline',v_timeline,'timeline_truncated',v_total>100,
    'hold',app_private.assignment_hold_projection(v_case.hold_id,v_case.assignment_id)
  );
end;
$function$;

create or replace function app_private.get_assignment_case_for_reviewer(
  p_actor uuid,p_case_id uuid,p_auth_aal text
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare v_result jsonb;
begin
  if not exists(select 1 from app_private.assignment_cases c where c.case_id=p_case_id
      and c.reviewer_id=p_actor
      and c.lifecycle_status in ('open','under_review','contacting_other_party','verifying','decision_made')) then
    raise exception using errcode='42501',message='case_access_denied';
  end if;
  v_result:=app_private.get_assignment_case_for_reviewer_base(p_actor,p_case_id,p_auth_aal);
  return v_result||app_private.case_investigation_projection(p_case_id,p_actor,true);
end;
$function$;

create function public.server_propose_case_decision_for_actor(
  p_actor uuid,p_case_id uuid,p_expected_case_version integer,p_payload jsonb,
  p_auth_aal text,p_idempotency_key uuid
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.propose_case_decision_for_actor(
    p_actor,p_case_id,p_expected_case_version,p_payload,p_auth_aal,p_idempotency_key)
$function$;

create function public.server_approve_case_decision_for_actor(
  p_actor uuid,p_case_id uuid,p_decision_version integer,p_expected_case_version integer,
  p_auth_aal text,p_idempotency_key uuid
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.approve_case_decision_for_actor(
    p_actor,p_case_id,p_decision_version,p_expected_case_version,p_auth_aal,p_idempotency_key)
$function$;

create function public.server_signoff_case_decision_nonresponse_for_actor(
  p_actor uuid,p_case_id uuid,p_decision_version integer,p_expected_case_version integer,
  p_substantive_reasoning text,p_auth_aal text,p_idempotency_key uuid
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.signoff_case_decision_nonresponse_for_actor(
    p_actor,p_case_id,p_decision_version,p_expected_case_version,
    p_substantive_reasoning,p_auth_aal,p_idempotency_key)
$function$;

revoke all on table app_private.assignment_case_decision_versions,
  app_private.assignment_case_decision_approvals,
  app_private.assignment_case_decision_nonresponse_signoffs
  from public,anon,authenticated,service_role;
revoke all on function app_private.case_decision_evidence_snapshot(uuid,uuid),
  app_private.propose_case_decision_for_actor(uuid,uuid,integer,jsonb,text,uuid),
  app_private.approve_case_decision_for_actor(uuid,uuid,integer,integer,text,uuid),
  app_private.signoff_case_decision_nonresponse_for_actor(uuid,uuid,integer,integer,text,text,uuid),
  app_private.case_investigation_projection(uuid,uuid,boolean),
  app_private.case_participant_projection(uuid,uuid),
  app_private.get_assignment_case_for_reviewer(uuid,uuid,text),
  app_private.guard_assignment_case_lifecycle(),
  app_private.reject_case_decision_history_mutation()
  from public,anon,authenticated,service_role;
revoke all on function public.server_propose_case_decision_for_actor(uuid,uuid,integer,jsonb,text,uuid),
  public.server_approve_case_decision_for_actor(uuid,uuid,integer,integer,text,uuid),
  public.server_signoff_case_decision_nonresponse_for_actor(uuid,uuid,integer,integer,text,text,uuid)
  from public,anon,authenticated,service_role;
grant execute on function public.server_propose_case_decision_for_actor(uuid,uuid,integer,jsonb,text,uuid),
  public.server_approve_case_decision_for_actor(uuid,uuid,integer,integer,text,uuid),
  public.server_signoff_case_decision_nonresponse_for_actor(uuid,uuid,integer,integer,text,text,uuid)
  to service_role;

commit;
