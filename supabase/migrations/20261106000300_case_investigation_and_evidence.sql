begin;

-- Step 4 is investigation only. It adds no decision or money command.
alter table app_private.staff_grants drop constraint staff_grants_capability_check;
alter table app_private.staff_grants add constraint staff_grants_capability_check
  check (capability in (
    'verification_review','identity_suspend','identity_unsuspend',
    'identity_correct_user_type','identity_staff_admin','dispute_review',
    'financial_initiate','financial_approve','financial_inspect','case_senior_signoff'
  ));

alter table app_private.assignment_case_events
  drop constraint assignment_case_events_audience_check,
  drop constraint assignment_case_events_event_type_check,
  add constraint assignment_case_events_audience_check
    check (audience in ('participants','worker','poster','staff')),
  add constraint assignment_case_events_event_type_check check (event_type in (
    'case_opened','reviewer_assigned','reviewer_reassigned','status_changed',
    'participant_response','evidence_added','decision_notified','appeal_opened',
    'case_closed','case_triaged','contact_attempt_recorded','information_requested',
    'fact_verification_recorded','nonresponse_assessed'
  ));

alter table app_private.assignment_case_access_audit
  drop constraint assignment_case_access_audit_action_check,
  add constraint assignment_case_access_audit_action_check check (action in (
    'case_read','case_queue_read','case_assigned','case_reassigned',
    'case_triaged','case_contact_logged','case_information_requested',
    'case_participant_responded','case_fact_recorded','case_internal_note_added',
    'case_nonresponse_assessed','case_nonresponse_signed_off'
  ));

alter table app_private.case_command_idempotency
  drop constraint case_command_idempotency_command_name_check,
  add constraint case_command_idempotency_command_name_check check (command_name in (
    'assign_case_reviewer','triage_case','log_case_contact_attempt',
    'request_case_information','respond_to_case_information','record_case_fact',
    'add_case_internal_note','assess_case_nonresponse','signoff_case_nonresponse',
    'begin_case_file_upload'
  ));

alter table app_private.case_file_policy
  add column allowed_mime_types text[] not null default
    array['image/jpeg','image/png','application/pdf']::text[],
  add constraint case_file_policy_allowed_types check (
    allowed_mime_types <@ array['image/jpeg','image/png','application/pdf']::text[]
    and cardinality(allowed_mime_types)>0
  );

create table app_private.assignment_case_triage_records (
  triage_id uuid primary key default pg_catalog.gen_random_uuid(),
  case_id uuid not null references app_private.assignment_cases(case_id) on delete restrict,
  case_version integer not null check (case_version>0),
  reviewer_id uuid not null references auth.users(id) on delete restrict,
  priority text not null check (priority in ('normal','urgent')),
  rationale text not null check (char_length(btrim(rationale)) between 1 and 500),
  acknowledged_at timestamptz not null default pg_catalog.now()
);
create index assignment_case_triage_latest_idx
  on app_private.assignment_case_triage_records(case_id,case_version desc,triage_id desc);

create table app_private.assignment_case_internal_notes (
  note_id uuid primary key default pg_catalog.gen_random_uuid(),
  case_id uuid not null references app_private.assignment_cases(case_id) on delete restrict,
  reviewer_id uuid not null references auth.users(id) on delete restrict,
  note text not null check (char_length(btrim(note)) between 1 and 2000),
  created_at timestamptz not null default pg_catalog.now()
);
create index assignment_case_internal_notes_case_idx
  on app_private.assignment_case_internal_notes(case_id,created_at,note_id);

create table app_private.assignment_case_contact_attempts (
  contact_attempt_id uuid primary key default pg_catalog.gen_random_uuid(),
  case_id uuid not null references app_private.assignment_cases(case_id) on delete restrict,
  target_party_role text not null check (target_party_role in ('worker','poster')),
  channel text not null check (channel in ('in_app','phone','email','in_person','other')),
  result text not null check (result in (
    'no_response','reached','declined','delivery_failed','contact_unavailable','other'
  )),
  recorded_by uuid not null references auth.users(id) on delete restrict,
  result_note text check (result_note is null or char_length(btrim(result_note)) between 1 and 500),
  attribution text not null default 'simulated_manual_log'
    check (attribution='simulated_manual_log'),
  recorded_at timestamptz not null default pg_catalog.now()
);
create index assignment_case_contact_attempts_scope_idx
  on app_private.assignment_case_contact_attempts(case_id,target_party_role,recorded_at,contact_attempt_id);

create table app_private.assignment_case_information_requests (
  request_id uuid primary key default pg_catalog.gen_random_uuid(),
  case_id uuid not null references app_private.assignment_cases(case_id) on delete restrict,
  target_party_role text not null check (target_party_role in ('worker','poster')),
  request_kind text not null check (request_kind in ('information','evidence')),
  request_scope text not null default 'investigation'
    check (request_scope in ('investigation','appeal')),
  request_number smallint not null check (request_number between 1 and 100),
  prompt text not null check (char_length(btrim(prompt)) between 1 and 500),
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default pg_catalog.now(),
  status text not null default 'open' check (status in ('open','responded','closed')),
  status_changed_at timestamptz,
  check ((status='open')=(status_changed_at is null)),
  unique(case_id,request_number),
  unique(case_id,request_id)
);
create index assignment_case_information_requests_party_idx
  on app_private.assignment_case_information_requests(case_id,target_party_role,status,created_at);

create table app_private.assignment_case_information_responses (
  response_id uuid primary key default pg_catalog.gen_random_uuid(),
  request_id uuid not null references app_private.assignment_case_information_requests(request_id) on delete restrict,
  case_id uuid not null references app_private.assignment_cases(case_id) on delete restrict,
  actor_id uuid not null references auth.users(id) on delete restrict,
  response text not null check (char_length(btrim(response)) between 1 and 2000),
  created_at timestamptz not null default pg_catalog.now(),
  unique(request_id,actor_id)
);

create table app_private.assignment_case_fact_reviews (
  fact_review_id uuid primary key default pg_catalog.gen_random_uuid(),
  case_id uuid not null references app_private.assignment_cases(case_id) on delete restrict,
  case_version integer not null check (case_version>0),
  reviewer_id uuid not null references auth.users(id) on delete restrict,
  fact_code text not null check (fact_code ~ '^[a-z][a-z0-9_]{1,49}$'),
  finding text not null check (finding in ('supported','not_supported','inconclusive','needs_more_information')),
  staff_reasoning text not null check (char_length(btrim(staff_reasoning)) between 20 and 2000),
  participant_summary text check (participant_summary is null or char_length(btrim(participant_summary)) between 1 and 500),
  created_at timestamptz not null default pg_catalog.now()
);
create index assignment_case_fact_reviews_case_idx
  on app_private.assignment_case_fact_reviews(case_id,case_version,fact_review_id);

create table app_private.assignment_case_nonresponse_assessments (
  assessment_id uuid primary key default pg_catalog.gen_random_uuid(),
  case_id uuid not null references app_private.assignment_cases(case_id) on delete restrict,
  target_party_role text not null check (target_party_role in ('worker','poster')),
  case_version integer not null check (case_version>0),
  reviewer_id uuid not null references auth.users(id) on delete restrict,
  contact_attempt_count smallint not null check (contact_attempt_count>=2),
  distinct_channel_count smallint not null check (distinct_channel_count>=2),
  contact_set_sha256 bytea not null check (pg_catalog.octet_length(contact_set_sha256)=32),
  substantive_reasoning text not null check (char_length(btrim(substantive_reasoning)) between 100 and 2000),
  created_at timestamptz not null default pg_catalog.now()
);
create index assignment_case_nonresponse_assessments_case_idx
  on app_private.assignment_case_nonresponse_assessments(case_id,created_at desc,assessment_id desc);

create table app_private.assignment_case_nonresponse_signoffs (
  signoff_id uuid primary key default pg_catalog.gen_random_uuid(),
  assessment_id uuid not null unique references app_private.assignment_case_nonresponse_assessments(assessment_id) on delete restrict,
  case_id uuid not null references app_private.assignment_cases(case_id) on delete restrict,
  reviewer_id uuid not null references auth.users(id) on delete restrict,
  senior_id uuid not null references auth.users(id) on delete restrict,
  senior_grant_id uuid not null references app_private.staff_grants(grant_id) on delete restrict,
  contact_set_sha256 bytea not null check (pg_catalog.octet_length(contact_set_sha256)=32),
  substantive_reasoning text not null check (char_length(btrim(substantive_reasoning)) between 100 and 2000),
  signed_at timestamptz not null default pg_catalog.now(),
  check (senior_id<>reviewer_id)
);

create table app_private.case_evidence_files (
  evidence_id uuid primary key default pg_catalog.gen_random_uuid(),
  evidence_number smallint not null check (evidence_number between 1 and 25),
  case_id uuid not null references app_private.assignment_cases(case_id) on delete restrict,
  owner_id uuid not null references auth.users(id) on delete restrict,
  owner_role text not null check (owner_role in ('worker','poster')),
  request_id uuid references app_private.assignment_case_information_requests(request_id) on delete restrict,
  storage_bucket text not null default 'case-evidence-quarantine'
    check (storage_bucket='case-evidence-quarantine'),
  object_key text not null unique
    check (object_key ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f-]{36}/source$'),
  content_type text not null check (content_type in ('image/jpeg','image/png','application/pdf')),
  size_bytes integer not null check (size_bytes between 1 and 100000000),
  content_sha256 bytea not null check (pg_catalog.octet_length(content_sha256)=32),
  safety_state text not null check (safety_state in ('quarantined','ready','rejected')),
  source_kind text not null default 'uploaded' check (source_kind in ('uploaded','synthetic_test')),
  created_at timestamptz not null default pg_catalog.now(),
  check ((source_kind='uploaded' and safety_state in ('quarantined','rejected')) or
    (source_kind='synthetic_test' and safety_state='ready')),
  unique(case_id,evidence_number)
);
create index case_evidence_files_case_idx
  on app_private.case_evidence_files(case_id,created_at,evidence_id);
create index case_evidence_files_owner_idx
  on app_private.case_evidence_files(case_id,owner_id,created_at,evidence_id);

create table app_private.case_file_upload_intents (
  intent_id uuid primary key default pg_catalog.gen_random_uuid(),
  evidence_id uuid not null unique default pg_catalog.gen_random_uuid(),
  case_id uuid not null references app_private.assignment_cases(case_id) on delete restrict,
  actor_id uuid not null references auth.users(id) on delete restrict,
  actor_role text not null check (actor_role in ('worker','poster')),
  request_id uuid references app_private.assignment_case_information_requests(request_id) on delete restrict,
  expected_content_type text not null check (expected_content_type in ('image/jpeg','image/png','application/pdf')),
  expected_size_bytes integer not null check (expected_size_bytes between 1 and 100000000),
  token_hash bytea not null check (pg_catalog.octet_length(token_hash)=32),
  object_key text not null unique
    check (object_key ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f-]{36}/source$'),
  state text not null default 'issued' check (state in ('issued','uploading','finalized','rejected','expired')),
  expires_at timestamptz not null,
  created_at timestamptz not null default pg_catalog.now(),
  claimed_at timestamptz,
  finalized_at timestamptz,
  idempotency_key uuid not null,
  constraint case_file_upload_intents_case_request_fkey foreign key(case_id,request_id)
    references app_private.assignment_case_information_requests(case_id,request_id) deferrable initially deferred,
  check (expires_at>created_at and expires_at<=created_at+interval '5 minutes')
);
create unique index case_file_one_live_intent_per_key
  on app_private.case_file_upload_intents(actor_id,idempotency_key);
create index case_file_upload_intents_case_idx
  on app_private.case_file_upload_intents(case_id,state,created_at);

create table app_private.case_file_access_audit (
  access_id bigint generated always as identity primary key,
  case_id uuid references app_private.assignment_cases(case_id) on delete restrict,
  actor_id uuid references auth.users(id) on delete restrict,
  evidence_id uuid,
  intent_id uuid references app_private.case_file_upload_intents(intent_id) on delete restrict,
  action text not null check (action in (
    'upload_intent_issued','upload_claimed','upload_rejected','upload_quarantined',
    'metadata_read','download_authorized','download_denied'
  )),
  reason_code text check (reason_code is null or reason_code in (
    'invalid_intent','upload_expired','size_mismatch','content_type_mismatch',
    'signature_mismatch','stored_content_mismatch','evidence_quarantined',
    'wrong_case_scope','wrong_grant','account_restricted'
  )),
  object_key_sha256 bytea check (object_key_sha256 is null or pg_catalog.octet_length(object_key_sha256)=32),
  created_at timestamptz not null default pg_catalog.now()
);
create index case_file_access_audit_case_idx
  on app_private.case_file_access_audit(case_id,created_at desc,access_id desc);
create trigger case_file_access_audit_immutable before update or delete
on app_private.case_file_access_audit for each row
execute function app_private.reject_assignment_case_event_mutation();

create trigger case_triage_records_immutable before update or delete
on app_private.assignment_case_triage_records for each row
execute function app_private.reject_assignment_case_event_mutation();
create trigger case_internal_notes_immutable before update or delete
on app_private.assignment_case_internal_notes for each row
execute function app_private.reject_assignment_case_event_mutation();
create trigger case_contact_attempts_immutable before update or delete
on app_private.assignment_case_contact_attempts for each row
execute function app_private.reject_assignment_case_event_mutation();
create trigger case_information_responses_immutable before update or delete
on app_private.assignment_case_information_responses for each row
execute function app_private.reject_assignment_case_event_mutation();
create trigger case_fact_reviews_immutable before update or delete
on app_private.assignment_case_fact_reviews for each row
execute function app_private.reject_assignment_case_event_mutation();
create trigger case_nonresponse_assessments_immutable before update or delete
on app_private.assignment_case_nonresponse_assessments for each row
execute function app_private.reject_assignment_case_event_mutation();
create trigger case_nonresponse_signoffs_immutable before update or delete
on app_private.assignment_case_nonresponse_signoffs for each row
execute function app_private.reject_assignment_case_event_mutation();
create trigger case_evidence_files_immutable before update or delete
on app_private.case_evidence_files for each row
execute function app_private.reject_assignment_case_event_mutation();

create policy case_evidence_buckets_block_browser_roles
on storage.objects as restrictive for all to anon,authenticated
using (bucket_id<>'case-evidence-quarantine')
with check (bucket_id<>'case-evidence-quarantine');
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('case-evidence-quarantine','case-evidence-quarantine',false,100000000,
  array['image/jpeg','image/png','application/pdf']::text[])
on conflict(id) do update set name=excluded.name,public=false,
  file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

alter table app_private.marketplace_outbox drop constraint marketplace_outbox_event_type_check;
alter table app_private.marketplace_outbox add constraint marketplace_outbox_event_type_check check (event_type in (
  'job.draft_created','job.draft_updated','job.funding_started','job.funded',
  'job.funding_failed','job.funding_exception','job.application_created',
  'job.application_accepted','job.application_rejected','job.application_withdrawn',
  'job.application_closed','job.message_created','job.assignment_started',
  'job.assignment_submitted','job.assignment_completed','job.assignment_hold_opened',
  'job.slot_refund_authorized','job.assignment_cancellation_requested',
  'job.assignment_cancellation_completed','job.assignment_abandoned',
  'job.assignment_case_reviewer_assigned','job.assignment_case_investigation_updated'
));

create or replace function app_private.guard_assignment_case_lifecycle()
returns trigger language plpgsql set search_path = '' as $function$
declare v_transition text;
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
     or new.version<>old.version+1
     or old.lifecycle_status in ('decision_made','appeal','refund_pending','closed') then
    raise exception using errcode='55000',message='invalid_case_lifecycle_transition';
  end if;
  if v_transition='assign_reviewer' then
    if new.lifecycle_status<>'under_review' or new.reviewer_id is null then
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
  else
    raise exception using errcode='55000',message='invalid_case_lifecycle_transition';
  end if;
  new.updated_at:=pg_catalog.now();
  return new;
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
  return pg_catalog.jsonb_build_object(
    'case_id',v_case.case_id,'assignment_id',v_case.assignment_id,
    'status',v_case.lifecycle_status,'version',v_case.version,
    'opened_at',v_case.opened_at,'updated_at',v_case.updated_at,
    'timeline',v_timeline,'timeline_truncated',v_total>100,
    'hold',app_private.assignment_hold_projection(v_case.hold_id,v_case.assignment_id)
  );
end;
$function$;

create or replace function app_private.case_investigation_command_for_actor(
  p_actor uuid,p_case_id uuid,p_action text,p_payload jsonb,p_auth_aal text,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_case app_private.assignment_cases%rowtype;
  v_assignment app_private.assignments%rowtype;
  v_request app_private.assignment_case_information_requests%rowtype;
  v_assessment app_private.assignment_case_nonresponse_assessments%rowtype;
  v_actor_role text;
  v_account_status text;
  v_grant_id uuid;
  v_hash bytea;
  v_contact_hash bytea;
  v_existing app_private.case_command_idempotency%rowtype;
  v_result jsonb;
  v_event_id uuid;
  v_seq integer;
  v_new_status text;
  v_request_no smallint;
  v_attempt_count integer;
  v_channel_count integer;
  v_reason text;
begin
  if p_actor is null or p_case_id is null or p_idempotency_key is null
     or p_payload is null or pg_catalog.jsonb_typeof(p_payload)<>'object'
     or coalesce(p_action,'') not in ('triage_case','log_case_contact_attempt','request_case_information',
       'respond_to_case_information','record_case_fact','add_case_internal_note',
       'assess_case_nonresponse','signoff_case_nonresponse') then
    raise exception using errcode='22023',message='invalid_case_command';
  end if;
  if p_action='respond_to_case_information' then
    if p_auth_aal is null or p_auth_aal not in ('aal1','aal2') then
      raise exception using errcode='42501',message='case_access_denied';
    end if;
  elsif p_auth_aal is distinct from 'aal2' then
    raise exception using errcode='42501',message='case_access_denied';
  end if;

  v_hash:=extensions.digest(pg_catalog.jsonb_build_object(
    'case_id',p_case_id,'action',p_action,'payload',p_payload)::text,'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    p_actor::text||':'||p_action||':'||p_idempotency_key::text,428118));
  select * into v_case from app_private.assignment_cases where case_id=p_case_id for update;
  if not found then raise exception using errcode='P0002',message='case_not_found'; end if;
  if v_case.lifecycle_status not in ('open','under_review','contacting_other_party','verifying') then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  select * into v_assignment from app_private.assignments
  where assignment_id=v_case.assignment_id for share;
  v_actor_role:=case when p_actor=v_assignment.worker_id then 'worker'
    when p_actor=v_assignment.poster_id then 'poster' else null end;
  select account_status into v_account_status from app_private.identity_accounts
  where user_id=p_actor for share;
  if not found then raise exception using errcode='42501',message='case_access_denied'; end if;

  if p_action='respond_to_case_information' then
    if v_actor_role is null or v_account_status not in ('active','suspended') then
      raise exception using errcode='42501',message='case_access_denied';
    end if;
  elsif p_action='signoff_case_nonresponse' then
    if v_actor_role is not null or v_account_status<>'active' then
      raise exception using errcode='42501',message='case_access_denied';
    end if;
    perform 1 from app_private.staff_grants where user_id=p_actor
      and capability='case_senior_signoff' and revoked_at is null for share;
    if not found then raise exception using errcode='42501',message='case_access_denied'; end if;
  else
    if v_actor_role is not null or v_account_status<>'active'
       or v_case.reviewer_id is distinct from p_actor
       or not app_private.lock_case_reviewer_scope(p_actor,p_auth_aal) then
      raise exception using errcode='42501',message='case_access_denied';
    end if;
  end if;

  select * into v_existing from app_private.case_command_idempotency
  where actor_id=p_actor and command_name=p_action and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.request_sha256<>v_hash then
      raise exception using errcode='23505',message='idempotency_conflict';
    end if;
    return v_existing.response;
  end if;

  if p_action='respond_to_case_information' then
    if v_actor_role is null or v_account_status is null or v_account_status not in ('active','suspended')
       or p_payload - array['request_number','response']::text[]<>'{}'::jsonb
       or (p_payload->>'request_number') !~ '^[1-9][0-9]{0,2}$'
       or pg_catalog.char_length(pg_catalog.btrim(coalesce(p_payload->>'response','')))
          not between 1 and 2000 then
      raise exception using errcode='42501',message='case_access_denied';
    end if;
    select * into v_request from app_private.assignment_case_information_requests
    where case_id=p_case_id and request_number=(p_payload->>'request_number')::smallint
      and target_party_role=v_actor_role and status='open' and request_scope='investigation'
    for update;
    if not found then raise exception using errcode='P0001',message='stale_state'; end if;
    update app_private.assignment_case_information_requests
      set status='responded',status_changed_at=pg_catalog.now()
      where request_id=v_request.request_id;
    insert into app_private.assignment_case_information_responses(
      request_id,case_id,actor_id,response
    ) values(v_request.request_id,p_case_id,p_actor,pg_catalog.btrim(p_payload->>'response'));
    v_new_status:=case when v_case.lifecycle_status='open' then 'under_review'
      else v_case.lifecycle_status end;
    perform pg_catalog.set_config('app.assignment_case_transition','respond_to_case_information',true);
    update app_private.assignment_cases set lifecycle_status=v_new_status,version=version+1
      where case_id=p_case_id;
    perform pg_catalog.set_config('app.assignment_case_transition','',true);
    insert into app_private.assignment_case_access_audit(case_id,actor_id,action)
      values(p_case_id,p_actor,'case_participant_responded');
    select coalesce(max(sequence),0)+1 into v_seq
      from app_private.assignment_case_events where case_id=p_case_id;
    insert into app_private.assignment_case_events(case_id,sequence,actor_id,audience,event_type,payload)
      values(p_case_id,v_seq,p_actor,v_actor_role,'participant_response',
        pg_catalog.jsonb_build_object('update','Your response was received.'));
    if v_case.reviewer_id is not null then
      v_event_id:=app_private.append_marketplace_event(p_actor,v_assignment.job_id,
        'job.assignment_case_investigation_updated',v_assignment.terms_version,
        pg_catalog.jsonb_build_object('case_id',p_case_id,'update','participant_response_received'));
      perform app_private.add_in_app_notification(v_event_id,v_case.reviewer_id,'assignment_case_updated');
    end if;
    v_result:=pg_catalog.jsonb_build_object('case_id',p_case_id,'status',v_new_status,
      'version',v_case.version+1,'request_number',v_request.request_number,'received',true);
  else
    if p_action='signoff_case_nonresponse' then
      if p_auth_aal is distinct from 'aal2' or v_actor_role is not null or v_account_status<>'active' then
        raise exception using errcode='42501',message='case_access_denied';
      end if;
    elsif not app_private.lock_case_reviewer_scope(p_actor,p_auth_aal)
       or v_actor_role is not null or v_case.reviewer_id is distinct from p_actor
       or v_account_status<>'active' then
      raise exception using errcode='42501',message='case_access_denied';
    end if;
    if p_action='triage_case' then
      if p_payload - array['priority','rationale']::text[]<>'{}'::jsonb
         or coalesce(p_payload->>'priority','') not in ('normal','urgent')
         or pg_catalog.char_length(pg_catalog.btrim(coalesce(p_payload->>'rationale','')))
            not between 1 and 500 then
        raise exception using errcode='22023',message='invalid_case_command';
      end if;
      select case when h.reason_code='conduct_safety' then 'urgent'
        else p_payload->>'priority' end into v_reason
        from app_private.assignment_holds h where h.hold_id=v_case.hold_id;
      insert into app_private.assignment_case_triage_records(
        case_id,case_version,reviewer_id,priority,rationale
      ) values(p_case_id,v_case.version+1,p_actor,v_reason,
        pg_catalog.btrim(p_payload->>'rationale'));
      v_new_status:='under_review';
      insert into app_private.assignment_case_access_audit(case_id,actor_id,action)
        values(p_case_id,p_actor,'case_triaged');
      select coalesce(max(sequence),0)+1 into v_seq from app_private.assignment_case_events where case_id=p_case_id;
      insert into app_private.assignment_case_events(case_id,sequence,actor_id,audience,event_type,payload)
        values(p_case_id,v_seq,p_actor,'participants','case_triaged',
          pg_catalog.jsonb_build_object('status','under_review','update','A reviewer is looking into the case.'));
      v_event_id:=app_private.append_marketplace_event(p_actor,v_assignment.job_id,
        'job.assignment_case_investigation_updated',v_assignment.terms_version,
        pg_catalog.jsonb_build_object('case_id',p_case_id,'update','case_triaged'));
      perform app_private.add_in_app_notification(v_event_id,v_assignment.worker_id,'assignment_case_updated');
      perform app_private.add_in_app_notification(v_event_id,v_assignment.poster_id,'assignment_case_updated');
      v_result:=pg_catalog.jsonb_build_object('case_id',p_case_id,'status',v_new_status,
        'version',v_case.version+1,'priority',v_reason,'acknowledged',true);
    elsif p_action='log_case_contact_attempt' then
      if p_payload - array['target_party_role','channel','result','result_note']::text[]<>'{}'::jsonb
         or coalesce(p_payload->>'target_party_role','') not in ('worker','poster')
         or coalesce(p_payload->>'channel','') not in ('in_app','phone','email','in_person','other')
         or coalesce(p_payload->>'result','') not in ('no_response','reached','declined','delivery_failed','contact_unavailable','other')
         or (p_payload ? 'result_note' and p_payload->'result_note'<>'null'::jsonb
           and pg_catalog.char_length(pg_catalog.btrim(p_payload->>'result_note')) not between 1 and 500) then
        raise exception using errcode='22023',message='invalid_case_command';
      end if;
      insert into app_private.assignment_case_contact_attempts(
        case_id,target_party_role,channel,result,recorded_by,result_note
      ) values(p_case_id,p_payload->>'target_party_role',p_payload->>'channel',
        p_payload->>'result',p_actor,nullif(pg_catalog.btrim(p_payload->>'result_note'),''));
      v_new_status:='contacting_other_party';
      insert into app_private.assignment_case_access_audit(case_id,actor_id,action)
        values(p_case_id,p_actor,'case_contact_logged');
      v_result:=pg_catalog.jsonb_build_object('case_id',p_case_id,'status',v_new_status,
        'version',v_case.version+1,'recorded',true,'attribution','simulated_manual_log');
    elsif p_action='request_case_information' then
      if p_payload - array['target_party_role','request_kind','prompt']::text[]<>'{}'::jsonb
         or coalesce(p_payload->>'target_party_role','') not in ('worker','poster')
         or coalesce(p_payload->>'request_kind','') not in ('information','evidence')
         or pg_catalog.char_length(pg_catalog.btrim(coalesce(p_payload->>'prompt','')))
            not between 1 and 500 then
        raise exception using errcode='22023',message='invalid_case_command';
      end if;
      if p_payload->>'prompt' ~* '(https?://|www[.]|[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12})' then
        raise exception using errcode='22023',message='invalid_case_command';
      end if;
      select (coalesce(max(request_number),0)+1)::smallint into v_request_no
        from app_private.assignment_case_information_requests where case_id=p_case_id;
      if v_request_no>100 then raise exception using errcode='P0001',message='stale_state'; end if;
      insert into app_private.assignment_case_information_requests(
        case_id,target_party_role,request_kind,request_scope,request_number,prompt,created_by
      ) values(p_case_id,p_payload->>'target_party_role',p_payload->>'request_kind','investigation',
        v_request_no,pg_catalog.btrim(p_payload->>'prompt'),p_actor) returning * into v_request;
      v_new_status:='contacting_other_party';
      insert into app_private.assignment_case_access_audit(case_id,actor_id,action)
        values(p_case_id,p_actor,'case_information_requested');
      select coalesce(max(sequence),0)+1 into v_seq from app_private.assignment_case_events where case_id=p_case_id;
      insert into app_private.assignment_case_events(case_id,sequence,actor_id,audience,event_type,payload)
        values(p_case_id,v_seq,p_actor,v_request.target_party_role,'information_requested',
          pg_catalog.jsonb_build_object('request_number',v_request.request_number,
            'request_kind',v_request.request_kind,'prompt',v_request.prompt,'status','open'));
      v_event_id:=app_private.append_marketplace_event(p_actor,v_assignment.job_id,
        'job.assignment_case_investigation_updated',v_assignment.terms_version,
        pg_catalog.jsonb_build_object('case_id',p_case_id,'update','information_requested'));
      perform app_private.add_in_app_notification(v_event_id,
        case v_request.target_party_role when 'worker' then v_assignment.worker_id else v_assignment.poster_id end,
        'assignment_case_updated');
      v_result:=pg_catalog.jsonb_build_object('case_id',p_case_id,'status',v_new_status,
        'version',v_case.version+1,'request_number',v_request.request_number,'requested',true);
    elsif p_action='record_case_fact' then
      if p_payload - array['fact_code','finding','staff_reasoning']::text[]<>'{}'::jsonb
         or coalesce(p_payload->>'fact_code','') !~ '^[a-z][a-z0-9_]{1,49}$'
         or coalesce(p_payload->>'finding','') not in ('supported','not_supported','inconclusive','needs_more_information')
         or pg_catalog.char_length(pg_catalog.btrim(coalesce(p_payload->>'staff_reasoning','')))
            not between 20 and 2000 then
        raise exception using errcode='22023',message='invalid_case_command';
      end if;
      insert into app_private.assignment_case_fact_reviews(
        case_id,case_version,reviewer_id,fact_code,finding,staff_reasoning
      ) values(p_case_id,v_case.version+1,p_actor,p_payload->>'fact_code',
        p_payload->>'finding',pg_catalog.btrim(p_payload->>'staff_reasoning'));
      v_new_status:='verifying';
      insert into app_private.assignment_case_access_audit(case_id,actor_id,action)
        values(p_case_id,p_actor,'case_fact_recorded');
      v_result:=pg_catalog.jsonb_build_object('case_id',p_case_id,'status',v_new_status,
        'version',v_case.version+1,'recorded',true);
    elsif p_action='add_case_internal_note' then
      if p_payload - array['note']::text[]<>'{}'::jsonb
         or pg_catalog.char_length(pg_catalog.btrim(coalesce(p_payload->>'note',''))) not between 1 and 2000 then
        raise exception using errcode='22023',message='invalid_case_command';
      end if;
      insert into app_private.assignment_case_internal_notes(case_id,reviewer_id,note)
        values(p_case_id,p_actor,pg_catalog.btrim(p_payload->>'note'));
      v_new_status:=v_case.lifecycle_status;
      insert into app_private.assignment_case_access_audit(case_id,actor_id,action)
        values(p_case_id,p_actor,'case_internal_note_added');
      v_result:=pg_catalog.jsonb_build_object('case_id',p_case_id,'status',v_new_status,
        'version',v_case.version+1,'recorded',true);
    elsif p_action='assess_case_nonresponse' then
      if p_payload - array['target_party_role','substantive_reasoning']::text[]<>'{}'::jsonb
         or coalesce(p_payload->>'target_party_role','') not in ('worker','poster')
         or pg_catalog.char_length(pg_catalog.btrim(coalesce(p_payload->>'substantive_reasoning','')))
            not between 100 and 2000 then
        raise exception using errcode='22023',message='invalid_case_command';
      end if;
      select count(*),count(distinct channel),extensions.digest(
        coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_array(contact_attempt_id,channel,result,recorded_at)
          order by recorded_at,contact_attempt_id),'[]'::jsonb)::text,'sha256')
        into v_attempt_count,v_channel_count,v_contact_hash
      from app_private.assignment_case_contact_attempts
      where case_id=p_case_id and target_party_role=p_payload->>'target_party_role' and result='no_response';
      if v_attempt_count<2 or v_channel_count<2 then
        raise exception using errcode='22023',message='nonresponse_contact_threshold_not_met';
      end if;
      insert into app_private.assignment_case_nonresponse_assessments(
        case_id,target_party_role,case_version,reviewer_id,contact_attempt_count,
        distinct_channel_count,contact_set_sha256,substantive_reasoning
      ) values(p_case_id,p_payload->>'target_party_role',v_case.version+1,p_actor,
        v_attempt_count,v_channel_count,v_contact_hash,pg_catalog.btrim(p_payload->>'substantive_reasoning'))
        returning * into v_assessment;
      v_new_status:='verifying';
      insert into app_private.assignment_case_access_audit(case_id,actor_id,action)
        values(p_case_id,p_actor,'case_nonresponse_assessed');
      select coalesce(max(sequence),0)+1 into v_seq from app_private.assignment_case_events where case_id=p_case_id;
      insert into app_private.assignment_case_events(case_id,sequence,actor_id,audience,event_type,payload)
        values(p_case_id,v_seq,p_actor,'staff','nonresponse_assessed',
          pg_catalog.jsonb_build_object('assessment_id',v_assessment.assessment_id));
      v_result:=pg_catalog.jsonb_build_object('case_id',p_case_id,'status',v_new_status,
        'version',v_case.version+1,'assessed',true,'needs_senior_signoff',true);
    elsif p_action='signoff_case_nonresponse' then
      if p_payload - array['assessment_id','substantive_reasoning']::text[]<>'{}'::jsonb
         or coalesce(p_payload->>'assessment_id','') !~* '^[0-9a-f-]{36}$'
         or pg_catalog.char_length(pg_catalog.btrim(coalesce(p_payload->>'substantive_reasoning','')))
            not between 100 and 2000 then
        raise exception using errcode='22023',message='invalid_case_command';
      end if;
      select * into v_assessment from app_private.assignment_case_nonresponse_assessments
        where assessment_id=(p_payload->>'assessment_id')::uuid and case_id=p_case_id for share;
      if not found or v_assessment.reviewer_id<>v_case.reviewer_id then
        raise exception using errcode='P0001',message='stale_state';
      end if;
      select account_status into v_account_status from app_private.identity_accounts
        where user_id=p_actor for share;
      select grant_id into v_grant_id from app_private.staff_grants
        where user_id=p_actor and capability='case_senior_signoff' and revoked_at is null for share;
      if not found or v_account_status is distinct from 'active' or p_actor in (v_assignment.worker_id,v_assignment.poster_id)
         or p_actor=v_case.reviewer_id then
        raise exception using errcode='42501',message='case_access_denied';
      end if;
      select count(*),count(distinct channel),extensions.digest(
        coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_array(contact_attempt_id,channel,result,recorded_at)
          order by recorded_at,contact_attempt_id),'[]'::jsonb)::text,'sha256')
        into v_attempt_count,v_channel_count,v_contact_hash
      from app_private.assignment_case_contact_attempts
      where case_id=p_case_id and target_party_role=v_assessment.target_party_role and result='no_response';
      if v_attempt_count<2 or v_channel_count<2 or v_contact_hash<>v_assessment.contact_set_sha256 then
        raise exception using errcode='P0001',message='stale_state';
      end if;
      insert into app_private.assignment_case_nonresponse_signoffs(
        assessment_id,case_id,reviewer_id,senior_id,senior_grant_id,contact_set_sha256,substantive_reasoning
      ) values(v_assessment.assessment_id,p_case_id,v_assessment.reviewer_id,p_actor,v_grant_id,
        v_contact_hash,pg_catalog.btrim(p_payload->>'substantive_reasoning'));
      v_new_status:='verifying';
      insert into app_private.assignment_case_access_audit(case_id,actor_id,action)
        values(p_case_id,p_actor,'case_nonresponse_signed_off');
      select coalesce(max(sequence),0)+1 into v_seq from app_private.assignment_case_events where case_id=p_case_id;
      insert into app_private.assignment_case_events(case_id,sequence,actor_id,audience,event_type,payload)
        values(p_case_id,v_seq,p_actor,'staff','nonresponse_assessed',
          pg_catalog.jsonb_build_object('senior_signoff_recorded',true));
      v_result:=pg_catalog.jsonb_build_object('case_id',p_case_id,'status',v_new_status,
        'version',v_case.version+1,'signed_off',true);
    end if;

    perform pg_catalog.set_config('app.assignment_case_transition',p_action,true);
    update app_private.assignment_cases set lifecycle_status=v_new_status,version=version+1
      where case_id=p_case_id;
    perform pg_catalog.set_config('app.assignment_case_transition','',true);
  end if;
  insert into app_private.case_command_idempotency(
    actor_id,command_name,idempotency_key,request_sha256,response
  ) values(p_actor,p_action,p_idempotency_key,v_hash,v_result);
  return v_result;
end;
$function$;

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
      'assigned_to_me',reviewer_id=p_actor
    ) order by urgent desc,opened_at,case_id),'[]'::jsonb),
    (select count(*)::integer from eligible)
    into v_items,v_count from page;
  insert into app_private.assignment_case_access_audit(case_id,actor_id,action)
    select (item->>'case_id')::uuid,p_actor,'case_queue_read'
    from pg_catalog.jsonb_array_elements(v_items) as q(item);
  return pg_catalog.jsonb_build_object('items',v_items,'truncated',v_count>50);
end;
$function$;

create function app_private.case_investigation_projection(p_case_id uuid,p_actor uuid,p_staff boolean)
returns jsonb language plpgsql security definer set search_path = '' as $function$
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
      'verified_facts',v_facts,'internal_notes',v_notes,'nonresponse',v_nonresponse,'files',v_files)
    else jsonb_build_object('requests',v_requests,'files',v_files) end);
end;
$function$;

create or replace function app_private.get_assignment_case_for_actor(p_actor uuid,p_case_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare v_result jsonb; v_role text;
begin
  v_result:=app_private.case_participant_projection(p_case_id,p_actor);
  if v_result is null then raise exception using errcode='P0002',message='case_not_found'; end if;
  select case when a.worker_id=p_actor then 'worker' else 'poster' end into v_role
    from app_private.assignment_cases c join app_private.assignments a using(assignment_id)
    where c.case_id=p_case_id;
  return v_result||app_private.case_investigation_projection(p_case_id,p_actor,false)||
    jsonb_build_object('participant_role',v_role);
end;
$function$;

alter function app_private.get_assignment_case_for_reviewer(uuid,uuid,text)
  rename to get_assignment_case_for_reviewer_base;

create function app_private.get_assignment_case_for_reviewer(
  p_actor uuid,p_case_id uuid,p_auth_aal text
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare v_result jsonb;
begin
  if not exists(select 1 from app_private.assignment_cases c where c.case_id=p_case_id
      and c.reviewer_id=p_actor
      and c.lifecycle_status in ('open','under_review','contacting_other_party','verifying')) then
    raise exception using errcode='42501',message='case_access_denied';
  end if;
  v_result:=app_private.get_assignment_case_for_reviewer_base(p_actor,p_case_id,p_auth_aal);
  return v_result||app_private.case_investigation_projection(p_case_id,p_actor,true);
end;
$function$;

create function app_private.issue_case_file_upload_for_actor(
  p_actor uuid,p_case_id uuid,p_request_number smallint,p_content_type text,
  p_size_bytes integer,p_token_hash_hex text,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_assignment app_private.assignments%rowtype;
  v_case app_private.assignment_cases%rowtype;
  v_request app_private.assignment_case_information_requests%rowtype;
  v_account_status text;
  v_role text;
  v_hash bytea;
  v_token_hash bytea;
  v_existing app_private.case_command_idempotency%rowtype;
  v_file_count integer;
  v_max_files integer;
  v_max_bytes bigint;
  v_intent uuid;
  v_evidence uuid;
  v_object_key text;
  v_result jsonb;
  v_expires_at timestamptz;
begin
  if p_actor is null or p_case_id is null or p_request_number is null
     or p_content_type is null or p_size_bytes is null or p_idempotency_key is null
     or coalesce(p_token_hash_hex,'') !~ '^[0-9a-f]{64}$' then
    raise exception using errcode='22023',message='invalid_case_upload';
  end if;
  v_token_hash:=pg_catalog.decode(p_token_hash_hex,'hex');
  v_hash:=extensions.digest(pg_catalog.jsonb_build_object('case_id',p_case_id,
    'request_number',p_request_number,'content_type',p_content_type,'size_bytes',p_size_bytes,
    'token_hash_hex',p_token_hash_hex)::text,'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    p_actor::text||':begin_case_file_upload:'||p_idempotency_key::text,428118));
  select * into v_case from app_private.assignment_cases where case_id=p_case_id for update;
  if not found or v_case.lifecycle_status not in ('open','under_review','contacting_other_party','verifying') then
    raise exception using errcode='P0002',message='case_not_found';
  end if;
  select * into v_assignment from app_private.assignments where assignment_id=v_case.assignment_id;
  v_role:=case when p_actor=v_assignment.worker_id then 'worker'
    when p_actor=v_assignment.poster_id then 'poster' else null end;
  select account_status into v_account_status from app_private.identity_accounts
    where user_id=p_actor for share;
  if v_role is null or v_account_status is null or v_account_status not in ('active','suspended') then
    raise exception using errcode='42501',message='case_access_denied';
  end if;
  select * into v_request from app_private.assignment_case_information_requests
    where case_id=p_case_id and request_number=p_request_number and target_party_role=v_role
      and request_kind='evidence' and request_scope='investigation' and status='open' for share;
  if not found then raise exception using errcode='42501',message='case_access_denied'; end if;
  select * into v_existing from app_private.case_command_idempotency
    where actor_id=p_actor and command_name='begin_case_file_upload' and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.request_sha256<>v_hash then
      raise exception using errcode='23505',message='idempotency_conflict';
    end if;
    return v_existing.response;
  end if;
  select max_files,max_file_bytes into v_max_files,v_max_bytes
    from app_private.case_file_policy where policy_id=1;
  if p_content_type not in (select unnest(allowed_mime_types) from app_private.case_file_policy where policy_id=1)
     or p_size_bytes<1 or p_size_bytes>v_max_bytes then
    raise exception using errcode='22023',message='invalid_case_upload';
  end if;
  select (select count(*) from app_private.case_evidence_files where case_id=p_case_id)
       +(select count(*) from app_private.case_file_upload_intents
          where case_id=p_case_id and state in ('issued','uploading') and expires_at>pg_catalog.now())
    into v_file_count;
  if v_file_count>=v_max_files then raise exception using errcode='P0001',message='case_file_limit_reached'; end if;
  v_intent:=pg_catalog.gen_random_uuid();
  v_evidence:=pg_catalog.gen_random_uuid();
  v_object_key:=p_case_id::text||'/'||p_actor::text||'/'||v_evidence::text||'/source';
  insert into app_private.case_file_upload_intents(
    intent_id,evidence_id,case_id,actor_id,actor_role,request_id,expected_content_type,
    expected_size_bytes,token_hash,object_key,state,expires_at,idempotency_key
  ) values(v_intent,v_evidence,p_case_id,p_actor,v_role,v_request.request_id,p_content_type,
    p_size_bytes,v_token_hash,v_object_key,'issued',pg_catalog.now()+interval '5 minutes',p_idempotency_key)
    returning expires_at into v_expires_at;
  insert into app_private.case_file_access_audit(case_id,actor_id,intent_id,action)
    values(p_case_id,p_actor,v_intent,'upload_intent_issued');
  v_result:=pg_catalog.jsonb_build_object('intent_id',v_intent,'evidence_number',null,
    'object_key',v_object_key,'content_type',p_content_type,'size_bytes',p_size_bytes,
    'expires_at',v_expires_at);
  insert into app_private.case_command_idempotency(
    actor_id,command_name,idempotency_key,request_sha256,response
  ) values(p_actor,'begin_case_file_upload',p_idempotency_key,v_hash,v_result);
  return v_result;
end;
$function$;

create function app_private.claim_case_file_upload_for_actor(
  p_actor uuid,p_intent_id uuid,p_token_hash_hex text
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_intent app_private.case_file_upload_intents%rowtype;
  v_case app_private.assignment_cases%rowtype;
  v_assignment app_private.assignments%rowtype;
  v_status text;
  v_file app_private.case_evidence_files%rowtype;
begin
  select * into v_intent from app_private.case_file_upload_intents
    where intent_id=p_intent_id for update;
  if not found or v_intent.actor_id<>p_actor
     or coalesce(p_token_hash_hex,'') !~ '^[0-9a-f]{64}$'
     or v_intent.token_hash<>pg_catalog.decode(p_token_hash_hex,'hex') then
    raise exception using errcode='42501',message='invalid_upload_intent';
  end if;
  select * into v_case from app_private.assignment_cases where case_id=v_intent.case_id for share;
  select * into v_assignment from app_private.assignments where assignment_id=v_case.assignment_id;
  select account_status into v_status from app_private.identity_accounts where user_id=p_actor for share;
  if v_status is null or v_status not in ('active','suspended') or
     (case when p_actor=v_assignment.worker_id then 'worker' when p_actor=v_assignment.poster_id then 'poster' else null end)
       is distinct from v_intent.actor_role then
    raise exception using errcode='42501',message='invalid_upload_intent';
  end if;
  if v_intent.state='finalized' then
    select * into v_file from app_private.case_evidence_files
      where evidence_id=v_intent.evidence_id;
    return pg_catalog.jsonb_build_object('already_finalized',true,'object_key',v_intent.object_key,
      'content_type',v_file.content_type,'size_bytes',v_file.size_bytes,
      'sha256_hex',pg_catalog.encode(v_file.content_sha256,'hex'),
      'safety_state',v_file.safety_state,'evidence_number',v_file.evidence_number);
  end if;
  if v_intent.state<>'issued' or v_intent.expires_at<=pg_catalog.now()
     or v_case.lifecycle_status not in ('open','under_review','contacting_other_party','verifying')
     or not exists(select 1 from app_private.assignment_case_information_requests r
       where r.request_id=v_intent.request_id and r.status='open') then
    insert into app_private.case_file_access_audit(case_id,actor_id,intent_id,action,reason_code)
      values(v_intent.case_id,p_actor,p_intent_id,'upload_rejected','upload_expired');
    raise exception using errcode='42501',message='invalid_upload_intent';
  end if;
  update app_private.case_file_upload_intents set state='uploading',claimed_at=pg_catalog.now()
    where intent_id=p_intent_id;
  insert into app_private.case_file_access_audit(case_id,actor_id,intent_id,action)
    values(v_intent.case_id,p_actor,p_intent_id,'upload_claimed');
  return pg_catalog.jsonb_build_object('already_finalized',false,'object_key',v_intent.object_key,
    'content_type',v_intent.expected_content_type,'size_bytes',v_intent.expected_size_bytes,
    'evidence_id',v_intent.evidence_id,'case_id',v_intent.case_id);
end;
$function$;

create function app_private.reject_case_file_upload_for_actor(
  p_actor uuid,p_intent_id uuid,p_reason_code text
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare v_intent app_private.case_file_upload_intents%rowtype;
begin
  select * into v_intent from app_private.case_file_upload_intents
    where intent_id=p_intent_id and actor_id=p_actor for update;
  if not found or v_intent.state not in ('issued','uploading') then
    return pg_catalog.jsonb_build_object('recorded',false);
  end if;
  update app_private.case_file_upload_intents set state='rejected' where intent_id=p_intent_id;
  insert into app_private.case_file_access_audit(case_id,actor_id,intent_id,action,reason_code)
    values(v_intent.case_id,p_actor,p_intent_id,'upload_rejected',
      case when p_reason_code in ('size_mismatch','content_type_mismatch','signature_mismatch','stored_content_mismatch')
        then p_reason_code else 'invalid_intent' end);
  return pg_catalog.jsonb_build_object('recorded',true);
end;
$function$;

create function app_private.finalize_case_file_upload_for_actor(
  p_actor uuid,p_intent_id uuid,p_size_bytes integer,p_content_type text,p_sha256_hex text
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_intent app_private.case_file_upload_intents%rowtype;
  v_case app_private.assignment_cases%rowtype;
  v_assignment app_private.assignments%rowtype;
  v_number smallint;
  v_event integer;
  v_outbox_event uuid;
begin
  select * into v_intent from app_private.case_file_upload_intents
    where intent_id=p_intent_id and actor_id=p_actor for update;
  if not found then raise exception using errcode='42501',message='invalid_upload_intent'; end if;
  if v_intent.state='finalized' then
    return app_private.claim_case_file_upload_for_actor(p_actor,p_intent_id,
      pg_catalog.encode(v_intent.token_hash,'hex'));
  end if;
  if v_intent.state<>'uploading' or p_size_bytes<>v_intent.expected_size_bytes
     or p_content_type<>v_intent.expected_content_type or coalesce(p_sha256_hex,'') !~ '^[0-9a-f]{64}$'
     or v_intent.expires_at<=pg_catalog.now() then
    raise exception using errcode='42501',message='invalid_upload_intent';
  end if;
  select * into v_case from app_private.assignment_cases where case_id=v_intent.case_id for update;
  if v_case.lifecycle_status not in ('open','under_review','contacting_other_party','verifying') then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  if not exists(select 1 from app_private.assignment_case_information_requests r
    where r.request_id=v_intent.request_id and r.status='open') then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  select (coalesce(max(evidence_number),0)+1)::smallint into v_number
    from app_private.case_evidence_files where case_id=v_intent.case_id;
  insert into app_private.case_evidence_files(
    evidence_id,evidence_number,case_id,owner_id,owner_role,request_id,storage_bucket,
    object_key,content_type,size_bytes,content_sha256,safety_state,source_kind
  ) values(v_intent.evidence_id,v_number,v_intent.case_id,p_actor,v_intent.actor_role,
    v_intent.request_id,'case-evidence-quarantine',v_intent.object_key,p_content_type,
    p_size_bytes,pg_catalog.decode(p_sha256_hex,'hex'),'quarantined','uploaded');
  update app_private.case_file_upload_intents set state='finalized',finalized_at=pg_catalog.now()
    where intent_id=p_intent_id;
  insert into app_private.case_file_access_audit(case_id,actor_id,evidence_id,intent_id,action,
    object_key_sha256) values(v_intent.case_id,p_actor,v_intent.evidence_id,p_intent_id,
    'upload_quarantined',extensions.digest(v_intent.object_key,'sha256'));
  select * into v_assignment from app_private.assignments where assignment_id=v_case.assignment_id;
  select coalesce(max(sequence),0)+1 into v_event from app_private.assignment_case_events
    where case_id=v_intent.case_id;
  insert into app_private.assignment_case_events(case_id,sequence,actor_id,audience,event_type,payload)
    values(v_intent.case_id,v_event,p_actor,v_intent.actor_role,'evidence_added',
      pg_catalog.jsonb_build_object('evidence_number',v_number,'safety_state','quarantined',
        'update','The uploaded file is awaiting safety inspection.'));
  if v_case.reviewer_id is not null then
    v_outbox_event:=app_private.append_marketplace_event(p_actor,v_assignment.job_id,
      'job.assignment_case_investigation_updated',v_assignment.terms_version,
      pg_catalog.jsonb_build_object('case_id',v_intent.case_id,'update','evidence_received'));
    perform app_private.add_in_app_notification(v_outbox_event,v_case.reviewer_id,'assignment_case_updated');
  end if;
  return pg_catalog.jsonb_build_object('evidence_number',v_number,
    'safety_state','quarantined','reviewable',false);
end;
$function$;

create function app_private.authorize_case_file_download_for_actor(
  p_actor uuid,p_case_id uuid,p_evidence_number smallint,p_auth_aal text
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare v_file app_private.case_evidence_files%rowtype;
begin
  if not exists(select 1 from app_private.assignment_cases where case_id=p_case_id) then
    raise exception using errcode='P0002',message='case_not_found';
  end if;
  if not app_private.lock_case_reviewer_scope(p_actor,p_auth_aal)
     or not exists(select 1 from app_private.assignment_cases c where c.case_id=p_case_id
       and c.reviewer_id=p_actor and c.lifecycle_status in ('open','under_review','contacting_other_party','verifying')) then
    insert into app_private.case_file_access_audit(case_id,actor_id,evidence_id,action,reason_code)
      values(p_case_id,p_actor,null,'download_denied','wrong_grant');
    return pg_catalog.jsonb_build_object('denied',true,'reason','case_access_denied');
  end if;
  select * into v_file from app_private.case_evidence_files
    where case_id=p_case_id and evidence_number=p_evidence_number and safety_state='ready';
  if not found then
    insert into app_private.case_file_access_audit(case_id,actor_id,action,reason_code)
      values(p_case_id,p_actor,'download_denied','evidence_quarantined');
    return pg_catalog.jsonb_build_object('denied',true,'reason','case_evidence_not_ready');
  end if;
  insert into app_private.case_file_access_audit(case_id,actor_id,evidence_id,action,
    object_key_sha256) values(p_case_id,p_actor,v_file.evidence_id,'download_authorized',
    extensions.digest(v_file.object_key,'sha256'));
  return pg_catalog.jsonb_build_object('bucket',v_file.storage_bucket,'object_key',v_file.object_key,
    'content_type',v_file.content_type,'size_bytes',v_file.size_bytes,
    'sha256_hex',pg_catalog.encode(v_file.content_sha256,'hex'));
end;
$function$;

create function public.server_case_investigation_command_for_actor(
  p_actor uuid,p_case_id uuid,p_action text,p_payload jsonb,p_auth_aal text,p_idempotency_key uuid
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.case_investigation_command_for_actor(
    p_actor,p_case_id,p_action,p_payload,p_auth_aal,p_idempotency_key)
$function$;
create or replace function public.server_get_assignment_case_for_actor(p_actor uuid,p_case_id uuid)
returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.get_assignment_case_for_actor(p_actor,p_case_id)
$function$;
create or replace function public.server_get_assignment_case_for_reviewer(
  p_actor uuid,p_case_id uuid,p_auth_aal text
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.get_assignment_case_for_reviewer(p_actor,p_case_id,p_auth_aal)
$function$;
create function public.server_issue_case_file_upload_for_actor(
  p_actor uuid,p_case_id uuid,p_request_number smallint,p_content_type text,
  p_size_bytes integer,p_token_hash_hex text,p_idempotency_key uuid
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.issue_case_file_upload_for_actor(
    p_actor,p_case_id,p_request_number,p_content_type,p_size_bytes,p_token_hash_hex,p_idempotency_key)
$function$;
create function public.server_claim_case_file_upload_for_actor(
  p_actor uuid,p_intent_id uuid,p_token_hash_hex text
)
returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.claim_case_file_upload_for_actor(p_actor,p_intent_id,p_token_hash_hex)
$function$;
create function public.server_reject_case_file_upload_for_actor(
  p_actor uuid,p_intent_id uuid,p_reason_code text
)
returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.reject_case_file_upload_for_actor(p_actor,p_intent_id,p_reason_code)
$function$;
create function public.server_finalize_case_file_upload_for_actor(
  p_actor uuid,p_intent_id uuid,p_size_bytes integer,p_content_type text,p_sha256_hex text
)
returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.finalize_case_file_upload_for_actor(
    p_actor,p_intent_id,p_size_bytes,p_content_type,p_sha256_hex)
$function$;
create function public.server_authorize_case_file_download_for_actor(
  p_actor uuid,p_case_id uuid,p_evidence_number smallint,p_auth_aal text
)
returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.authorize_case_file_download_for_actor(
    p_actor,p_case_id,p_evidence_number,p_auth_aal)
$function$;

revoke all on table app_private.assignment_case_triage_records,
  app_private.assignment_case_internal_notes,app_private.assignment_case_contact_attempts,
  app_private.assignment_case_information_requests,app_private.assignment_case_information_responses,
  app_private.assignment_case_fact_reviews,app_private.assignment_case_nonresponse_assessments,
  app_private.assignment_case_nonresponse_signoffs,app_private.case_evidence_files,
  app_private.case_file_upload_intents,app_private.case_file_access_audit
  from public,anon,authenticated,service_role;
revoke all on function app_private.case_investigation_command_for_actor(uuid,uuid,text,jsonb,text,uuid),
  app_private.case_investigation_projection(uuid,uuid,boolean),
  app_private.get_assignment_case_for_reviewer(uuid,uuid,text),
  app_private.issue_case_file_upload_for_actor(uuid,uuid,smallint,text,integer,text,uuid),
  app_private.claim_case_file_upload_for_actor(uuid,uuid,text),
  app_private.reject_case_file_upload_for_actor(uuid,uuid,text),
  app_private.finalize_case_file_upload_for_actor(uuid,uuid,integer,text,text),
  app_private.authorize_case_file_download_for_actor(uuid,uuid,smallint,text),
  app_private.get_assignment_case_for_reviewer_base(uuid,uuid,text)
  from public,anon,authenticated,service_role;
revoke all on function public.server_case_investigation_command_for_actor(uuid,uuid,text,jsonb,text,uuid),
  public.server_issue_case_file_upload_for_actor(uuid,uuid,smallint,text,integer,text,uuid),
  public.server_claim_case_file_upload_for_actor(uuid,uuid,text),
  public.server_reject_case_file_upload_for_actor(uuid,uuid,text),
  public.server_finalize_case_file_upload_for_actor(uuid,uuid,integer,text,text),
  public.server_authorize_case_file_download_for_actor(uuid,uuid,smallint,text)
  from public,anon,authenticated,service_role;
grant execute on function public.server_case_investigation_command_for_actor(uuid,uuid,text,jsonb,text,uuid),
  public.server_issue_case_file_upload_for_actor(uuid,uuid,smallint,text,integer,text,uuid),
  public.server_claim_case_file_upload_for_actor(uuid,uuid,text),
  public.server_reject_case_file_upload_for_actor(uuid,uuid,text),
  public.server_finalize_case_file_upload_for_actor(uuid,uuid,integer,text,text),
  public.server_authorize_case_file_download_for_actor(uuid,uuid,smallint,text)
  to service_role;

revoke all on function app_private.case_investigation_command_for_actor(uuid,uuid,text,jsonb,text,uuid),
  app_private.issue_case_file_upload_for_actor(uuid,uuid,smallint,text,integer,text,uuid),
  app_private.claim_case_file_upload_for_actor(uuid,uuid,text),
  app_private.reject_case_file_upload_for_actor(uuid,uuid,text),
  app_private.finalize_case_file_upload_for_actor(uuid,uuid,integer,text,text),
  app_private.authorize_case_file_download_for_actor(uuid,uuid,smallint,text)
  from public,anon,authenticated,service_role;

commit;
