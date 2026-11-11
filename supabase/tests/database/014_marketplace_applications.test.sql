begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

select ok(to_regclass('app_private.assignment_reminder_due') is not null
  and not has_table_privilege('anon','app_private.assignment_reminder_due','SELECT')
  and not has_table_privilege('authenticated','app_private.assignment_reminder_due','SELECT')
  and not has_table_privilege('service_role','app_private.assignment_reminder_due','SELECT'),
  'reminder due records are private durable backend state');
select ok(has_function_privilege('service_role',
      'public.server_claim_assignment_reminder_for_runner(uuid,integer)','EXECUTE')
  and has_function_privilege('service_role',
      'public.server_dispatch_assignment_reminder_for_runner(uuid,uuid)','EXECUTE')
  and has_function_privilege('service_role',
      'public.server_fail_assignment_reminder_for_runner(uuid,uuid,text)','EXECUTE')
  and has_function_privilege('service_role',
      'public.server_authorize_notification_email_dispatch_for_runner(uuid,uuid)','EXECUTE')
  and not has_function_privilege('authenticated',
      'public.server_claim_assignment_reminder_for_runner(uuid,integer)','EXECUTE')
  and not has_function_privilege('anon',
      'public.server_dispatch_assignment_reminder_for_runner(uuid,uuid)','EXECUTE')
  and not has_function_privilege('service_role',
      'app_private.claim_assignment_reminder_for_runner_at(uuid,integer,timestamp with time zone)','EXECUTE'),
  'the reminder worker has only server-gateway commands and no public time override');
select ok(to_regprocedure('public.server_claim_assignment_reminder_for_runner(uuid,integer,timestamp with time zone)') is null
  and to_regprocedure('public.server_dispatch_assignment_reminder_for_runner(uuid,uuid,timestamp with time zone)') is null,
  'clients cannot backdate reminder claims or dispatches');
select ok(pg_catalog.strpos(pg_catalog.pg_get_functiondef(
      'app_private.dispatch_assignment_reminder_for_runner_at(uuid,uuid,timestamp with time zone)'::regprocedure),
      'post_financial_journal')=0
  and pg_catalog.strpos(pg_catalog.pg_get_functiondef(
      'app_private.dispatch_assignment_reminder_for_runner_at(uuid,uuid,timestamp with time zone)'::regprocedure),
      'finalize_case_for_actor')=0,
  'reminder dispatch has no ledger or case-finalization command path');

select ok(to_regclass('app_private.job_applications') is not null,
  'applications have a private persistence table');
select ok(to_regclass('public.job_applications') is null
  and to_regclass('public.assignments') is null
  and to_regclass('public.application_threads') is null,
  'application, assignment and conversation rows stay out of the public schema');
select ok(not has_schema_privilege('anon','app_private','USAGE')
  and not has_schema_privilege('authenticated','app_private','USAGE')
  and not has_schema_privilege('service_role','app_private','USAGE'),
  'application records remain inaccessible to ordinary API roles');
select ok(to_regclass('app_private.assignment_holds') is not null
  and to_regclass('public.assignment_holds') is null
  and to_regclass('app_private.assignment_completion_authorizations') is not null
  and to_regclass('public.assignment_completion_authorizations') is null,
  'hold reports and completion authorizations are private records');
select ok(to_regclass('app_private.assignment_cases') is not null
  and to_regclass('public.assignment_cases') is null
  and to_regclass('app_private.assignment_case_events') is not null
  and to_regclass('public.assignment_case_events') is null
  and to_regclass('app_private.assignment_case_access_audit') is not null
  and to_regclass('public.assignment_case_access_audit') is null,
  'case lifecycle, shared timeline and access history stay private');
select ok(pg_catalog.strpos(pg_catalog.pg_get_functiondef(
    'app_private.confirm_completion_for_actor(uuid,uuid,uuid)'::regprocedure),'assignment_cases')>0
  and pg_catalog.strpos(pg_catalog.pg_get_functiondef(
    'app_private.confirm_completion_for_actor(uuid,uuid,uuid)'::regprocedure),'assignment_holds')=0,
  'ordinary completion checks active case state and never treats an immutable old report as still open');
select ok(not has_table_privilege('anon','app_private.assignment_holds','SELECT')
  and not has_table_privilege('authenticated','app_private.assignment_holds','SELECT')
  and not has_table_privilege('service_role','app_private.assignment_holds','SELECT')
  and not has_table_privilege('service_role','app_private.assignment_cases','UPDATE')
  and not has_table_privilege('authenticated','app_private.assignment_case_events','SELECT')
  and not has_table_privilege('service_role','app_private.assignment_case_access_audit','SELECT')
  and not has_table_privilege('service_role','app_private.assignment_completion_authorizations','INSERT'),
  'ordinary API and generic service paths cannot read reports or write completion authorization');
select ok(not has_function_privilege('anon',
      'public.server_start_assignment_for_actor(uuid,uuid,uuid)','EXECUTE')
  and not has_function_privilege('authenticated',
      'public.server_start_assignment_for_actor(uuid,uuid,uuid)','EXECUTE')
  and has_function_privilege('service_role',
      'public.server_start_assignment_for_actor(uuid,uuid,uuid)','EXECUTE')
  and not has_function_privilege('authenticated',
      'public.server_confirm_completion_for_actor(uuid,uuid,uuid)','EXECUTE')
  and has_function_privilege('service_role',
      'public.server_confirm_completion_for_actor(uuid,uuid,uuid)','EXECUTE')
  and not has_function_privilege('authenticated',
      'public.server_open_assignment_hold_for_actor(uuid,uuid,text,text,text,uuid)','EXECUTE')
  and has_function_privilege('service_role',
      'public.server_open_assignment_hold_for_actor(uuid,uuid,text,text,text,uuid)','EXECUTE')
  and not has_function_privilege('authenticated',
      'public.server_get_assignment_case_for_actor(uuid,uuid)','EXECUTE')
  and has_function_privilege('service_role',
      'public.server_get_assignment_case_for_actor(uuid,uuid)','EXECUTE')
  and not has_function_privilege('authenticated',
      'public.server_list_assignment_case_queue_for_actor(uuid,text,smallint)','EXECUTE')
  and has_function_privilege('service_role',
      'public.server_list_assignment_case_queue_for_actor(uuid,text,smallint)','EXECUTE')
  and not has_function_privilege('authenticated',
      'public.server_assign_case_reviewer_for_actor(uuid,uuid,uuid,text,uuid)','EXECUTE')
  and has_function_privilege('service_role',
      'public.server_assign_case_reviewer_for_actor(uuid,uuid,uuid,text,uuid)','EXECUTE')
  and not has_function_privilege('authenticated',
      'public.server_get_assignment_case_for_reviewer(uuid,uuid,text)','EXECUTE')
  and has_function_privilege('service_role',
      'public.server_get_assignment_case_for_reviewer(uuid,uuid,text)','EXECUTE')
  and has_function_privilege('service_role',
      'public.server_get_assignment_status_for_actor(uuid,uuid)','EXECUTE'),
  'assignment commands and status use the narrow server-only RPC gateway');
select ok(to_regclass('app_private.allocation_assignment_bindings') is not null
  and to_regclass('public.allocation_assignment_bindings') is null
  and to_regclass('app_private.allocation_refund_payables') is not null
  and to_regclass('public.allocation_refund_payables') is null
  and to_regclass('app_private.assignment_cancellation_consents') is not null
  and to_regclass('public.assignment_cancellation_consents') is null,
  'cancellation consent, allocation history and refund payables stay private');
select ok(not has_table_privilege('anon','app_private.allocation_refund_payables','SELECT')
  and not has_table_privilege('authenticated','app_private.allocation_refund_payables','SELECT')
  and not has_table_privilege('service_role','app_private.allocation_refund_payables','SELECT')
  and not has_table_privilege('authenticated','app_private.assignment_cancellation_consents','INSERT'),
  'client roles and the generic service role cannot read or write cancellation records directly');
select ok(has_function_privilege('service_role',
      'public.server_cancel_unassigned_slots_for_actor(uuid,uuid,uuid[],text,uuid)','EXECUTE')
  and has_function_privilege('service_role',
      'public.server_request_prestart_cancellation_for_actor(uuid,uuid,text,uuid)','EXECUTE')
  and has_function_privilege('service_role',
      'public.server_consent_prestart_cancellation_for_actor(uuid,uuid,integer,text,uuid)','EXECUTE')
  and has_function_privilege('service_role',
      'public.server_abandon_prestart_assignment_for_actor(uuid,uuid,text,uuid)','EXECUTE')
  and not has_function_privilege('authenticated',
      'public.server_cancel_unassigned_slots_for_actor(uuid,uuid,uuid[],text,uuid)','EXECUTE')
  and not has_function_privilege('anon',
      'public.server_consent_prestart_cancellation_for_actor(uuid,uuid,integer,text,uuid)','EXECUTE'),
  'the four cancellation RPCs are available only through the server service boundary');
select ok(to_regprocedure('public.server_finalize_assignment_hold_for_actor(uuid,uuid,uuid)') is null
  and to_regprocedure('public.server_release_assignment_for_admin(uuid,uuid)') is null,
  'no generic hold resolver or administrator release command is exposed');
select ok(not has_table_privilege('anon','app_private.thread_messages','SELECT')
  and not has_table_privilege('authenticated','app_private.thread_messages','SELECT')
  and not has_table_privilege('service_role','app_private.thread_messages','SELECT'),
  'the message store is not directly readable by API or generic service roles');
select ok(not has_function_privilege('anon',
    'public.server_apply_to_job_for_actor(uuid,uuid,text,uuid)','EXECUTE')
  and not has_function_privilege('authenticated',
    'public.server_apply_to_job_for_actor(uuid,uuid,text,uuid)','EXECUTE')
  and has_function_privilege('service_role',
    'public.server_apply_to_job_for_actor(uuid,uuid,text,uuid)','EXECUTE'),
  'only the server gateway can invoke application creation');
select ok(not has_function_privilege('anon',
      'public.server_send_application_message_for_actor(uuid,uuid,uuid,text)','EXECUTE')
  and not has_function_privilege('authenticated',
      'public.server_send_application_message_for_actor(uuid,uuid,uuid,text)','EXECUTE')
  and has_function_privilege('service_role',
      'public.server_send_application_message_for_actor(uuid,uuid,uuid,text)','EXECUTE')
  and not has_function_privilege('anon',
      'public.server_get_application_thread_for_actor(uuid,uuid,bigint,smallint)','EXECUTE')
  and not has_function_privilege('authenticated',
      'public.server_get_application_thread_for_actor(uuid,uuid,bigint,smallint)','EXECUTE')
  and has_function_privilege('service_role',
      'public.server_get_application_thread_for_actor(uuid,uuid,bigint,smallint)','EXECUTE'),
  'participant message gateways are server-only and require SQL actor checks');
select ok(not has_function_privilege('anon',
      'public.server_reject_application_for_actor(uuid,uuid,uuid)','EXECUTE')
  and not has_function_privilege('authenticated',
      'public.server_reject_application_for_actor(uuid,uuid,uuid)','EXECUTE')
  and has_function_privilege('service_role',
      'public.server_reject_application_for_actor(uuid,uuid,uuid)','EXECUTE')
  and not has_function_privilege('anon',
      'public.server_withdraw_application_for_actor(uuid,uuid,uuid)','EXECUTE')
  and not has_function_privilege('authenticated',
      'public.server_withdraw_application_for_actor(uuid,uuid,uuid)','EXECUTE')
  and has_function_privilege('service_role',
      'public.server_withdraw_application_for_actor(uuid,uuid,uuid)','EXECUTE'),
  'rejection and withdrawal gateways are server-only');

select set_config('test.poster',(
  select id::text from auth.users where email='phase2-trackb@identity.test'
),true);
select set_config('test.student',(
  select id::text from auth.users where email='phase2-profileviewer@identity.test'
),true);
select set_config('test.unverified',(
  select id::text from auth.users where email='phase2-owner@identity.test'
),true);
select set_config('test.case_staff',(
  select id::text from auth.users where email='phase2-other@identity.test'
),true);
insert into public.profiles(user_id,display_name)
values(current_setting('test.student')::uuid,'Synthetic worker')
on conflict(user_id) do nothing;
insert into app_private.identity_accounts(
  user_id,account_type,age_confirmed_at,age_policy_version,account_status,
  verification_track,verification_status
) values(current_setting('test.poster')::uuid,'partner',pg_catalog.now(),'marketplace-apply-test-v1',
  'active','track_b_partner','approved')
on conflict(user_id) do update set account_type='partner',age_confirmed_at=excluded.age_confirmed_at,
  account_status='active',verification_track='track_b_partner',verification_status='approved';
insert into app_private.identity_phone_bindings(user_id,phone_e164,verified_at)
select u.id,'+2347000000098',u.phone_confirmed_at from auth.users u
where u.id=current_setting('test.poster')::uuid
on conflict(user_id) do update set phone_e164=excluded.phone_e164,verified_at=excluded.verified_at;
insert into app_private.identity_capabilities(user_id,capability,source)
values(current_setting('test.poster')::uuid,'can_hire','track_b_partner')
on conflict(user_id,capability) do update set source=excluded.source,revoked_at=null;
insert into app_private.identity_accounts(
  user_id,account_type,age_confirmed_at,age_policy_version,account_status,
  verification_track,verification_status
) values(current_setting('test.student')::uuid,'student',pg_catalog.now(),'marketplace-apply-test-v1',
  'active','track_a_manual','approved')
on conflict(user_id) do update set account_type='student',age_confirmed_at=excluded.age_confirmed_at,
  account_status='active',verification_track='track_a_manual',verification_status='approved';
insert into app_private.identity_phone_bindings(user_id,phone_e164,verified_at)
select u.id,'+2347000000100',u.phone_confirmed_at from auth.users u
where u.id=current_setting('test.student')::uuid
on conflict(user_id) do update set phone_e164=excluded.phone_e164,verified_at=excluded.verified_at;
insert into app_private.identity_capabilities(user_id,capability,source)
values(current_setting('test.student')::uuid,'can_work','track_a_manual')
on conflict(user_id,capability) do update set source=excluded.source,revoked_at=null;
insert into app_private.identity_accounts(
  user_id,account_type,age_confirmed_at,age_policy_version,account_status,
  verification_track,verification_status
) values(current_setting('test.case_staff')::uuid,'student',pg_catalog.now(),
  'marketplace-case-test-v1','active','track_a_manual','approved')
on conflict(user_id) do update set account_status='active';
insert into app_private.staff_grants(user_id,capability,granted_by,reason)
values(current_setting('test.case_staff')::uuid,'dispute_review',
  current_setting('test.case_staff')::uuid,'Synthetic local case reviewer fixture grant.');

select set_config('test.terms',pg_catalog.jsonb_build_object(
  'title','Synthetic one-slot task',
  'description','Carry books safely between the campus library and lecture halls.',
  'category_slug','errands','location_type','on_campus','location_detail','Main library',
  'gross_per_worker_kobo','300000','slot_count',1,
  'application_deadline_at',pg_catalog.to_char(pg_catalog.timezone('UTC',pg_catalog.now()+interval '2 days'),'YYYY-MM-DD"T"HH24:MI:SS')||'+00:00',
  'needed_by_at',pg_catalog.to_char(pg_catalog.timezone('UTC',pg_catalog.now()+interval '3 days'),'YYYY-MM-DD"T"HH24:MI:SS')||'+00:00',
  'start_requirements','Meet beside the library entrance'
)::text,true);
select set_config('test.draft',public.server_create_job_draft_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.terms')::jsonb,
  '14000000-0000-4000-8000-000000000001'
)::text,true);
select set_config('test.job_id',current_setting('test.draft')::jsonb->>'job_id',true);
select set_config('test.funding',public.server_start_job_funding_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.job_id')::uuid,1,
  '14000000-0000-4000-8000-000000000002'
)::text,true);
select set_config('test.operation',current_setting('test.funding')::jsonb->>'operation_id',true);
select set_config('test.claim',app_private.claim_payment_operation_job(
  '14000000-0000-4000-8000-000000000003',30::smallint)::text,true);
select public.server_complete_job_funding_operation_for_runner(
  current_setting('test.operation')::uuid,
  (current_setting('test.claim')::jsonb->>'lease_token')::uuid,
  'succeeded','sim-'||(current_setting('test.funding')::jsonb->>'provider_idempotency_key'),
  '300000','NGN','fake_nbd_local_merchant_v1',
  (current_setting('test.funding')::jsonb->>'provider_idempotency_key')::uuid,
  '1500',null,false,pg_catalog.encode(extensions.digest('marketplace application fixture','sha256'),'hex')
);

select set_config('test.journal_count_before_apply',(
  select count(*)::text from app_private.ledger_journal_transactions
),true);
select set_config('test.application',public.server_apply_to_job_for_actor(
  current_setting('test.student')::uuid,current_setting('test.job_id')::uuid,
  '  I can do this after my lecture.  ',
  '14000000-0000-4000-8000-000000000004'
)::text,true);
select set_config('test.application_id',current_setting('test.application')::jsonb->>'application_id',true);
select is(current_setting('test.application')::jsonb->>'state','applied',
  'a qualified student can create one application');
select is(current_setting('test.application')::jsonb->>'note','I can do this after my lecture.',
  'the bounded application note is normalized before storage');
select ok(current_setting('test.application')::jsonb->>'thread_id' is not null,
  'application creation also creates one private thread');
select is((select count(*)::integer from app_private.application_threads
  where application_id=current_setting('test.application_id')::uuid),1,
  'the application has exactly one thread');
select is((select count(*)::integer from app_private.job_applications
  where job_id=current_setting('test.job_id')::uuid and worker_id=current_setting('test.student')::uuid),1,
  'one worker cannot have more than one application for a job');
select is((select count(*)::integer from app_private.principal_allocations
  where job_id=current_setting('test.job_id')::uuid and status='unassigned'),1,
  'applying leaves the funded slot unassigned');
select is((select count(*)::integer from app_private.assignments
  where job_id=current_setting('test.job_id')::uuid),0,
  'applying creates no assignment and does not authorize work');
select is((select count(*)::text from app_private.ledger_journal_transactions),
  current_setting('test.journal_count_before_apply'),
  'applying posts no financial journal effect');

select is(public.server_apply_to_job_for_actor(
  current_setting('test.student')::uuid,current_setting('test.job_id')::uuid,
  'I can do this after my lecture.',
  '14000000-0000-4000-8000-000000000004'
)->>'application_id',current_setting('test.application_id'),
  'an identical retry returns the original application');
select throws_ok(format($sql$
  select public.server_apply_to_job_for_actor(%L::uuid,%L::uuid,'different note',%L::uuid)
$sql$,current_setting('test.student'),current_setting('test.job_id'),
  '14000000-0000-4000-8000-000000000004'),
  '23505','idempotency_conflict','an altered retry cannot reuse an application request key');
select throws_ok(format($sql$
  select public.server_apply_to_job_for_actor(%L::uuid,%L::uuid,null,%L::uuid)
$sql$,current_setting('test.student'),current_setting('test.job_id'),
  '14000000-0000-4000-8000-000000000005'),
  'P0001','application_already_exists','a new request key cannot reapply to the same job');
select throws_ok(format($sql$
  select public.server_apply_to_job_for_actor(%L::uuid,%L::uuid,null,%L::uuid)
$sql$,current_setting('test.poster'),current_setting('test.job_id'),
  '14000000-0000-4000-8000-000000000006'),
  '42501','verification_required','a partner cannot apply as a worker');
select throws_ok(format($sql$
  select public.server_apply_to_job_for_actor(%L::uuid,%L::uuid,null,%L::uuid)
$sql$,current_setting('test.unverified'),current_setting('test.job_id'),
  '14000000-0000-4000-8000-000000000007'),
  '42501','verification_required','an unverified account cannot apply');

update auth.users set phone='2347000000097',phone_confirmed_at=pg_catalog.now()
where id=current_setting('test.unverified')::uuid;
insert into app_private.identity_accounts(
  user_id,account_type,age_confirmed_at,age_policy_version,account_status,
  verification_track,verification_status
) values(current_setting('test.unverified')::uuid,'student',pg_catalog.now(),
  'marketplace-apply-test-v1','active','track_a_manual','approved')
on conflict(user_id) do update set account_type='student',account_status='active',
  verification_track='track_a_manual',verification_status='approved',
  age_confirmed_at=coalesce(app_private.identity_accounts.age_confirmed_at,excluded.age_confirmed_at);
insert into app_private.identity_phone_bindings(user_id,phone_e164,verified_at)
select u.id,'+2347000000097',u.phone_confirmed_at from auth.users u
where u.id=current_setting('test.unverified')::uuid
on conflict(user_id) do update set phone_e164=excluded.phone_e164,verified_at=excluded.verified_at;
insert into app_private.identity_capabilities(user_id,capability,source)
values(current_setting('test.unverified')::uuid,'can_work','track_a_manual')
on conflict(user_id,capability) do update set source=excluded.source,revoked_at=null;
select set_config('test.rejected_application',public.server_apply_to_job_for_actor(
  current_setting('test.unverified')::uuid,current_setting('test.job_id')::uuid,
  'A second synthetic applicant.','14000000-0000-4000-8000-000000000020'
)::text,true);
select set_config('test.rejected_application_id',
  current_setting('test.rejected_application')::jsonb->>'application_id',true);
select is(public.server_reject_application_for_actor(
  current_setting('test.poster')::uuid,
  current_setting('test.rejected_application_id')::uuid,
  '14000000-0000-4000-8000-000000000021'
)->>'state','rejected','the owning poster can reject a pending application');
select is(public.server_reject_application_for_actor(
  current_setting('test.poster')::uuid,
  current_setting('test.rejected_application_id')::uuid,
  '14000000-0000-4000-8000-000000000021'
)->>'application_id',current_setting('test.rejected_application_id'),
  'an identical rejection retry returns the original application');
select set_config('test.rejected_thread',public.server_get_application_thread_for_actor(
  current_setting('test.unverified')::uuid,
  current_setting('test.rejected_application_id')::uuid,0,51::smallint
)::text,true);
select is(current_setting('test.rejected_thread')::jsonb->>'thread_state','read_only',
  'a rejected application thread remains available to its participants as read-only history');
select throws_ok(format($sql$
  select public.server_send_application_message_for_actor(%L::uuid,%L::uuid,%L::uuid,'late message')
$sql$,current_setting('test.unverified'),
  current_setting('test.rejected_application')::jsonb->>'thread_id',
  '14000000-0000-4000-8000-000000000022'),
  'P0001','thread_read_only','a rejected thread cannot accept new messages');

select set_config('test.withdrawn_worker',(
  select id::text from auth.users where email='phase2-other@identity.test'
),true);
update auth.users set phone='2347000000096',phone_confirmed_at=pg_catalog.now()
where id=current_setting('test.withdrawn_worker')::uuid;
insert into app_private.identity_accounts(
  user_id,account_type,age_confirmed_at,age_policy_version,account_status,
  verification_track,verification_status
) values(current_setting('test.withdrawn_worker')::uuid,'student',pg_catalog.now(),
  'marketplace-apply-test-v1','active','track_a_manual','approved')
on conflict(user_id) do update set account_type='student',account_status='active',
  verification_track='track_a_manual',verification_status='approved',
  age_confirmed_at=coalesce(app_private.identity_accounts.age_confirmed_at,excluded.age_confirmed_at);
insert into app_private.identity_phone_bindings(user_id,phone_e164,verified_at)
select u.id,'+2347000000096',u.phone_confirmed_at from auth.users u
where u.id=current_setting('test.withdrawn_worker')::uuid
on conflict(user_id) do update set phone_e164=excluded.phone_e164,verified_at=excluded.verified_at;
insert into app_private.identity_capabilities(user_id,capability,source)
values(current_setting('test.withdrawn_worker')::uuid,'can_work','track_a_manual')
on conflict(user_id,capability) do update set source=excluded.source,revoked_at=null;
select set_config('test.withdrawn_application',public.server_apply_to_job_for_actor(
  current_setting('test.withdrawn_worker')::uuid,current_setting('test.job_id')::uuid,
  null,'14000000-0000-4000-8000-000000000023'
)::text,true);
select is(public.server_withdraw_application_for_actor(
  current_setting('test.withdrawn_worker')::uuid,
  (current_setting('test.withdrawn_application')::jsonb->>'application_id')::uuid,
  '14000000-0000-4000-8000-000000000024'
)->>'state','withdrawn','an applicant can withdraw only their own pending application');
select is(public.server_withdraw_application_for_actor(
  current_setting('test.withdrawn_worker')::uuid,
  (current_setting('test.withdrawn_application')::jsonb->>'application_id')::uuid,
  '14000000-0000-4000-8000-000000000024'
)->>'application_id',current_setting('test.withdrawn_application')::jsonb->>'application_id',
  'an identical withdrawal retry returns the original application');
select is(public.server_get_application_thread_for_actor(
  current_setting('test.withdrawn_worker')::uuid,
  (current_setting('test.withdrawn_application')::jsonb->>'application_id')::uuid,
  0,51::smallint
)->>'thread_state','read_only','a withdrawn application thread remains read-only history');
select throws_ok(format($sql$
  select public.server_send_application_message_for_actor(%L::uuid,%L::uuid,%L::uuid,'late message')
$sql$,current_setting('test.withdrawn_worker'),
  current_setting('test.withdrawn_application')::jsonb->>'thread_id',
  '14000000-0000-4000-8000-000000000025'),
  'P0001','thread_read_only','a withdrawn thread cannot accept new messages');
select is((select count(*)::integer from app_private.principal_allocations
  where job_id=current_setting('test.job_id')::uuid and status='unassigned'),1,
  'apply, rejection and withdrawal still leave the funded slot unassigned');

select is((select count(*)::integer from app_private.marketplace_outbox
  where event_type='job.application_created' and job_id=current_setting('test.job_id')::uuid),3,
  'each distinct qualified applicant creates one application event');
select is((select count(*)::integer from app_private.in_app_notifications
  where notification_type='application_received'),3,
  'the poster receives one durable in-app notice per application');
select is((select count(*)::integer from app_private.marketplace_outbox
  where event_type='job.application_rejected' and job_id=current_setting('test.job_id')::uuid),1,
  'rejection commits one domain event');
select is((select count(*)::integer from app_private.in_app_notifications
  where notification_type='application_rejected'),1,
  'rejection commits one applicant notice');
select is((select count(*)::integer from app_private.marketplace_outbox
  where event_type='job.application_withdrawn' and job_id=current_setting('test.job_id')::uuid),1,
  'withdrawal commits one domain event');
select is((select count(*)::integer from app_private.in_app_notifications
  where notification_type='application_withdrawn'),1,
  'withdrawal commits one poster notice');

update app_private.identity_capabilities set revoked_at=pg_catalog.now()
where user_id=current_setting('test.student')::uuid and capability='can_work';
select throws_ok(format($sql$
  select public.server_accept_application_for_actor(%L::uuid,%L::uuid,%L::uuid)
$sql$,current_setting('test.poster'),current_setting('test.application_id'),
  '14000000-0000-4000-8000-000000000008'),
  '42501','verification_required',
  'the poster cannot accept an application after the worker loses current eligibility');
select is((select state from app_private.job_applications
  where application_id=current_setting('test.application_id')::uuid),'applied',
  'an ineligible acceptance attempt leaves the application pending');
select is((select count(*)::integer from app_private.principal_allocations
  where job_id=current_setting('test.job_id')::uuid and status='unassigned'),1,
  'an ineligible acceptance attempt leaves funded capacity untouched');
update app_private.identity_capabilities set revoked_at=null
where user_id=current_setting('test.student')::uuid and capability='can_work';

select set_config('test.accepted',public.server_accept_application_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.application_id')::uuid,
  '14000000-0000-4000-8000-000000000009'
)::text,true);
select is(current_setting('test.accepted')::jsonb->>'assignment_state','assigned',
  'acceptance creates one assignment that remains assigned until the worker starts');
select is(current_setting('test.accepted')::jsonb->>'gross_principal_kobo','300000',
  'the assignment binds exactly one funded gross allocation');
select is(current_setting('test.accepted')::jsonb->>'terms_version','1',
  'the assignment binds the immutable accepted terms version');
select is(current_setting('test.accepted')::jsonb->>'thread_id',
  current_setting('test.application')::jsonb->>'thread_id',
  'acceptance reuses the application thread');
select is((select count(*)::integer from app_private.assignments
  where application_id=current_setting('test.application_id')::uuid),1,
  'one accepted application creates exactly one assignment');
select is((select count(*)::integer from app_private.principal_allocations
  where job_id=current_setting('test.job_id')::uuid and status='assigned'
    and assignment_id=(current_setting('test.accepted')::jsonb->>'assignment_id')::uuid),1,
  'the assignment and its one allocation are bound in both directions');
select is((select listing_state from app_private.jobs
  where job_id=current_setting('test.job_id')::uuid),'filled',
  'the last accepted funded slot closes listing discovery');
select is((select count(*)::text from app_private.ledger_journal_transactions),
  (current_setting('test.journal_count_before_apply')::integer+1)::text,
  'acceptance reclassifies the existing principal without reserving it twice');
select is((select count(*)::integer from app_private.ledger_journal_transactions
  where effect_type='allocation_assigned'
    and reference_id=(select allocation_id from app_private.assignments
      where assignment_id=(current_setting('test.accepted')::jsonb->>'assignment_id')::uuid)),1,
  'acceptance journals one move of this allocation from unassigned to assigned principal');
select is((select sum(e.amount_kobo)::bigint from app_private.ledger_journal_entries e
  join app_private.ledger_journal_transactions j using(journal_id)
  join app_private.ledger_accounts a using(account_id)
  where j.effect_type='allocation_assigned'
    and j.reference_id=(select allocation_id from app_private.assignments
      where assignment_id=(current_setting('test.accepted')::jsonb->>'assignment_id')::uuid)
    and a.account_code='job_principal_assigned' and e.direction='credit'),300000::bigint,
  'assignment reclassification preserves the full held gross');
select is(public.server_accept_application_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.application_id')::uuid,
  '14000000-0000-4000-8000-000000000009'
)->>'assignment_id',current_setting('test.accepted')::jsonb->>'assignment_id',
  'an identical acceptance retry returns the original assignment');
select is((select count(*)::integer from app_private.marketplace_outbox
  where event_type='job.application_accepted' and job_id=current_setting('test.job_id')::uuid),1,
  'acceptance commits one domain event');
select is((select count(*)::integer from app_private.in_app_notifications
  where notification_type='application_accepted'),2,
  'acceptance commits one in-app notice for each participant');

select throws_ok(format($sql$
  select public.server_confirm_completion_for_actor(%L::uuid,%L::uuid,%L::uuid)
$sql$,current_setting('test.poster'),current_setting('test.accepted')::jsonb->>'assignment_id',
  '14000000-0000-4000-8000-000000000040'),
  'P0001','stale_state','poster confirmation before worker submission changes no money');
select throws_ok(format($sql$
  select public.server_start_assignment_for_actor(%L::uuid,%L::uuid,%L::uuid)
$sql$,current_setting('test.poster'),current_setting('test.accepted')::jsonb->>'assignment_id',
  '14000000-0000-4000-8000-000000000041'),
  'P0002','assignment_not_found','a poster cannot start the worker assignment');
select set_config('test.started',public.server_start_assignment_for_actor(
  current_setting('test.student')::uuid,
  (current_setting('test.accepted')::jsonb->>'assignment_id')::uuid,
  '14000000-0000-4000-8000-000000000042'
)::text,true);
select is(current_setting('test.started')::jsonb->>'assignment_state','in_progress',
  'only the assigned worker explicitly starts work');
select is(public.server_start_assignment_for_actor(
  current_setting('test.student')::uuid,
  (current_setting('test.accepted')::jsonb->>'assignment_id')::uuid,
  '14000000-0000-4000-8000-000000000042'
)->>'assignment_state','in_progress','an identical start retry returns the current assignment');
select set_config('test.submitted',public.server_submit_assignment_for_actor(
  current_setting('test.student')::uuid,
  (current_setting('test.accepted')::jsonb->>'assignment_id')::uuid,
  '14000000-0000-4000-8000-000000000043'
)::text,true);
select is(current_setting('test.submitted')::jsonb->>'assignment_state','submitted',
  'the assigned worker can submit after starting');
select throws_ok(format($sql$
  select public.server_submit_assignment_review_for_actor(%L::uuid,%L::uuid,5,
    null,'15000000-0000-4000-8000-000000000015')
$sql$,current_setting('test.poster'),current_setting('test.accepted')::jsonb->>'assignment_id'),
  'P0001','review_not_eligible','an assignment in submitted state cannot be reviewed before final completion');
select is((select count(*)::integer from app_private.ledger_journal_transactions
  where effect_type='completion_released'
    and reference_id=(select allocation_id from app_private.assignments
      where assignment_id=(current_setting('test.accepted')::jsonb->>'assignment_id')::uuid)),0,
  'submission does not release principal or create earnings');
select set_config('test.completed',public.server_confirm_completion_for_actor(
  current_setting('test.poster')::uuid,
  (current_setting('test.accepted')::jsonb->>'assignment_id')::uuid,
  '14000000-0000-4000-8000-000000000044'
)::text,true);
select is(current_setting('test.completed')::jsonb->>'assignment_state','completed',
  'only the owning poster confirms submitted work');
select is(public.server_confirm_completion_for_actor(
  current_setting('test.poster')::uuid,
  (current_setting('test.accepted')::jsonb->>'assignment_id')::uuid,
  '14000000-0000-4000-8000-000000000044'
)->>'assignment_state','completed','a completion retry returns the same completed assignment');
select is((select sum(b.credit_kobo-b.debit_kobo)::bigint
  from app_private.ledger_account_balances b
  join app_private.ledger_accounts a using(account_id)
  where a.account_code='worker_earnings_available'
    and b.owner_id=current_setting('test.student')::uuid
    and b.allocation_id=(select allocation_id from app_private.assignments
      where assignment_id=(current_setting('test.accepted')::jsonb->>'assignment_id')::uuid)),285000::bigint,
  'NGN 3,000 completion credits exactly NGN 2,850 worker earnings');
select is((select sum(e.amount_kobo)::bigint from app_private.ledger_journal_entries e
  join app_private.ledger_journal_transactions j using(journal_id)
  join app_private.ledger_accounts a using(account_id)
  where j.effect_type='completion_released'
    and j.reference_id=(select allocation_id from app_private.assignments
      where assignment_id=(current_setting('test.accepted')::jsonb->>'assignment_id')::uuid)
    and a.account_code='platform_commission_revenue' and e.direction='credit'),15000::bigint,
  'the same completion posts exactly NGN 150 commission');
select is((select count(*)::integer from app_private.assignment_completion_authorizations
  where assignment_id=(current_setting('test.accepted')::jsonb->>'assignment_id')::uuid),1,
  'one immutable poster authorization is recorded for the completion');
select is((select count(*)::integer from app_private.marketplace_outbox
  where event_type='job.assignment_completed' and job_id=current_setting('test.job_id')::uuid),1,
  'completion commits one domain event');
select is((select count(*)::integer from app_private.in_app_notifications
  where notification_type='assignment_completed'),2,
  'completion commits one durable notice for each participant');
select is((select count(*)::integer from app_private.assignment_reminder_due
  where assignment_id=(current_setting('test.accepted')::jsonb->>'assignment_id')::uuid
    and status='suppressed'),3,
  'confirmation suppresses all undelivered reminder stages');
select is((select count(*)::integer from app_private.assignment_reminder_due
  where assignment_id=(current_setting('test.accepted')::jsonb->>'assignment_id')::uuid
    and notification_id is not null),0,
  'confirmation before dispatch creates no reminder notice');
select is((select count(*)::integer from app_private.assignments
  where worker_id=current_setting('test.student')::uuid and work_state='completed'),1,
  'completed work is counted from its single finalized assignment');
select ok((public.server_get_safe_profile_for_viewer(
  current_setting('test.poster')::uuid,current_setting('test.student')::uuid
)->>'completed_work_count')::integer=1,
  'the safe profile projection reports the once-only completed-work count');
select throws_ok(format($sql$
  select public.server_open_assignment_hold_for_actor(%L::uuid,%L::uuid,'other','late hold','refund',%L::uuid)
$sql$,current_setting('test.student'),current_setting('test.completed')::jsonb->>'assignment_id',
  '14000000-0000-4000-8000-000000000045'),
  'P0001','stale_state','a terminal completion cannot be put on hold');

select set_config('test.message',public.server_send_application_message_for_actor(
  current_setting('test.student')::uuid,
  (current_setting('test.application')::jsonb->>'thread_id')::uuid,
  '14000000-0000-4000-8000-000000000010','I can meet at noon.'
)::text,true);
select is(current_setting('test.message')::jsonb->>'sequence','1',
  'the first persisted message receives server sequence one');
select is(current_setting('test.message')::jsonb->>'replayed','false',
  'the sender receives acknowledgement only after the message row is saved');
select is(public.server_send_application_message_for_actor(
  current_setting('test.student')::uuid,
  (current_setting('test.application')::jsonb->>'thread_id')::uuid,
  '14000000-0000-4000-8000-000000000010','I can meet at noon.'
)->>'sequence','1','a retry with the same client message ID returns the original sequence');
select is(public.server_send_application_message_for_actor(
  current_setting('test.student')::uuid,
  (current_setting('test.application')::jsonb->>'thread_id')::uuid,
  '14000000-0000-4000-8000-000000000010','I can meet at noon.'
)->>'replayed','true','a duplicate message retry is marked as replayed');
select throws_ok(format($sql$
  select public.server_send_application_message_for_actor(%L::uuid,%L::uuid,%L::uuid,'changed retry')
$sql$,current_setting('test.student'),current_setting('test.application')::jsonb->>'thread_id',
  '14000000-0000-4000-8000-000000000010'),
  '23505','idempotency_conflict','a client message ID cannot be reused with altered text');
select set_config('test.poster_message',public.server_send_application_message_for_actor(
  current_setting('test.poster')::uuid,
  (current_setting('test.application')::jsonb->>'thread_id')::uuid,
  '14000000-0000-4000-8000-000000000011','Thank you, see you there.'
)::text,true);
select is(current_setting('test.poster_message')::jsonb->>'sequence','2',
  'each thread has a stable increasing sequence shared by both participants');
select set_config('test.thread',public.server_get_application_thread_for_actor(
  current_setting('test.student')::uuid,current_setting('test.application_id')::uuid,0,51::smallint
)::text,true);
select is(pg_catalog.jsonb_array_length(current_setting('test.thread')::jsonb->'messages'),2,
  'a participant can reload the saved private thread messages');
select is(current_setting('test.thread')::jsonb->'messages'->1->>'sequence','2',
  'thread reads preserve the server-assigned message order');
select is(current_setting('test.thread')::jsonb->>'unread_count','1',
  'unread count includes only incoming messages after the reader cursor');
select ok(not (current_setting('test.thread')::jsonb->'messages'->0 ? 'sender_id')
  and not (current_setting('test.thread')::jsonb ? 'applicant_email'),
  'thread reads omit private identifiers and contact fields');
select throws_ok(format($sql$
  select public.server_get_application_thread_for_actor(%L::uuid,%L::uuid,0,51::smallint)
$sql$,current_setting('test.unverified'),current_setting('test.application_id')),
  'P0002','application_not_found','a nonparticipant cannot read a guessed thread');
select is(public.server_mark_application_thread_read_for_actor(
  current_setting('test.poster')::uuid,
  (current_setting('test.application')::jsonb->>'thread_id')::uuid,2
)->>'last_read_sequence','2','a participant can advance their read cursor through saved messages');
select is(public.server_mark_application_thread_read_for_actor(
  current_setting('test.poster')::uuid,
  (current_setting('test.application')::jsonb->>'thread_id')::uuid,1
)->>'last_read_sequence','2','a read cursor cannot move backwards');
select is(public.server_get_application_thread_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.application_id')::uuid,0,51::smallint
)->>'unread_count','0','marking the thread read clears its incoming unread count');
select throws_ok(format($sql$
  select public.server_mark_application_thread_read_for_actor(%L::uuid,%L::uuid,3)
$sql$,current_setting('test.poster'),current_setting('test.application')::jsonb->>'thread_id'),
  '22023','invalid_application_query','a read cursor cannot advance beyond the last saved message');
select is((select count(*)::integer from app_private.thread_messages
  where thread_id=(current_setting('test.application')::jsonb->>'thread_id')::uuid),2,
  'duplicate delivery does not create an extra message row');
select is((select count(*)::integer from app_private.marketplace_outbox
  where event_type='job.message_created' and job_id=current_setting('test.job_id')::uuid),2,
  'only newly persisted messages create domain events');
select is((select count(*)::integer from app_private.in_app_notifications
  where notification_type='new_message'),2,
  'each newly persisted message notifies the other participant once');
select throws_ok(format($sql$
  update app_private.thread_messages set body='edited message' where client_message_id=%L::uuid
$sql$,'14000000-0000-4000-8000-000000000010'),
  '55000','thread_message_is_immutable','a persisted message cannot be edited');
select throws_ok(format($sql$
  update app_private.assignments set gross_principal_kobo=1 where application_id=%L::uuid
$sql$,current_setting('test.application_id')),
  '55000','assignment_record_is_immutable','an accepted assignment terms snapshot cannot be edited');
select is(pg_catalog.jsonb_array_length(public.server_get_job_applications_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.job_id')::uuid,null,null,21::smallint
)),3,'the owning poster can inspect applicants through a separate query');
select is(pg_catalog.jsonb_array_length(public.server_get_my_applications_for_actor(
  current_setting('test.student')::uuid,null,null,21::smallint
)),1,'a student can inspect only their own application history');

insert into app_private.identity_capabilities(user_id,capability,source)
values(current_setting('test.student')::uuid,'can_hire','track_a_manual')
on conflict(user_id,capability) do update set source=excluded.source,revoked_at=null;
select set_config('test.self_draft',public.server_create_job_draft_for_actor(
  current_setting('test.student')::uuid,current_setting('test.terms')::jsonb,
  '14000000-0000-4000-8000-000000000030'
)::text,true);
select set_config('test.self_job_id',current_setting('test.self_draft')::jsonb->>'job_id',true);
select set_config('test.self_funding',public.server_start_job_funding_for_actor(
  current_setting('test.student')::uuid,current_setting('test.self_job_id')::uuid,1,
  '14000000-0000-4000-8000-000000000031'
)::text,true);
select set_config('test.self_operation',current_setting('test.self_funding')::jsonb->>'operation_id',true);
select set_config('test.self_claim',app_private.claim_payment_operation_job(
  '14000000-0000-4000-8000-000000000032',30::smallint)::text,true);
select public.server_complete_job_funding_operation_for_runner(
  current_setting('test.self_operation')::uuid,
  (current_setting('test.self_claim')::jsonb->>'lease_token')::uuid,
  'succeeded','sim-'||(current_setting('test.self_funding')::jsonb->>'provider_idempotency_key'),
  '300000','NGN','fake_nbd_local_merchant_v1',
  (current_setting('test.self_funding')::jsonb->>'provider_idempotency_key')::uuid,
  '1500',null,false,pg_catalog.encode(extensions.digest('self-application fixture','sha256'),'hex')
);
select throws_ok(format($sql$
  select public.server_apply_to_job_for_actor(%L::uuid,%L::uuid,null,%L::uuid)
$sql$,current_setting('test.student'),current_setting('test.self_job_id'),
  '14000000-0000-4000-8000-000000000033'),
  'P0001','self_application_not_allowed',
  'a verified student who can also hire cannot apply to their own job');

select set_config('test.hold_draft',public.server_create_job_draft_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.terms')::jsonb,
  '14000000-0000-4000-8000-000000000050'
)::text,true);
select set_config('test.hold_job_id',current_setting('test.hold_draft')::jsonb->>'job_id',true);
select set_config('test.hold_funding',public.server_start_job_funding_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.hold_job_id')::uuid,1,
  '14000000-0000-4000-8000-000000000051'
)::text,true);
select set_config('test.hold_operation',current_setting('test.hold_funding')::jsonb->>'operation_id',true);
select set_config('test.hold_claim',app_private.claim_payment_operation_job(
  '14000000-0000-4000-8000-000000000052',30::smallint)::text,true);
select public.server_complete_job_funding_operation_for_runner(
  current_setting('test.hold_operation')::uuid,
  (current_setting('test.hold_claim')::jsonb->>'lease_token')::uuid,
  'succeeded','sim-'||(current_setting('test.hold_funding')::jsonb->>'provider_idempotency_key'),
  '300000','NGN','fake_nbd_local_merchant_v1',
  (current_setting('test.hold_funding')::jsonb->>'provider_idempotency_key')::uuid,
  '1500',null,false,pg_catalog.encode(extensions.digest('hold fixture','sha256'),'hex')
);
select set_config('test.hold_application',public.server_apply_to_job_for_actor(
  current_setting('test.unverified')::uuid,current_setting('test.hold_job_id')::uuid,
  null,'14000000-0000-4000-8000-000000000053'
)::text,true);
select set_config('test.hold_assignment',public.server_accept_application_for_actor(
  current_setting('test.poster')::uuid,
  (current_setting('test.hold_application')::jsonb->>'application_id')::uuid,
  '14000000-0000-4000-8000-000000000054'
)::text,true);
select public.server_send_application_message_for_actor(
  current_setting('test.unverified')::uuid,
  (current_setting('test.hold_application')::jsonb->>'thread_id')::uuid,
  '14000000-0000-4000-8000-000000000063','I delivered the agreed items before the deadline.'
);
select set_config('test.hold_started',public.server_start_assignment_for_actor(
  current_setting('test.unverified')::uuid,
  (current_setting('test.hold_assignment')::jsonb->>'assignment_id')::uuid,
  '14000000-0000-4000-8000-000000000055'
)::text,true);
select set_config('test.hold_submitted',public.server_submit_assignment_for_actor(
  current_setting('test.unverified')::uuid,
  (current_setting('test.hold_assignment')::jsonb->>'assignment_id')::uuid,
  '14000000-0000-4000-8000-000000000056'
)::text,true);
update app_private.identity_accounts set account_status='suspended'
where user_id=current_setting('test.unverified')::uuid;
select set_config('test.open_hold',public.server_open_assignment_hold_for_actor(
  current_setting('test.unverified')::uuid,
  (current_setting('test.hold_assignment')::jsonb->>'assignment_id')::uuid,
  'work_not_as_described','The item delivered differs from the agreed item.',
  'Please review the agreed description and delivery.',
  'Please review the submitted work.','14000000-0000-4000-8000-000000000057'
)::text,true);
select is(current_setting('test.open_hold')::jsonb->'hold'->>'status','open',
  'an eligible assigned participant can open one unresolved hold');
select is(current_setting('test.open_hold')::jsonb->'assignment'->>'assignment_state','submitted',
  'opening a hold retains the prior assignment stage');
select is((select prior_work_state from app_private.assignment_holds
  where assignment_id=(current_setting('test.hold_assignment')::jsonb->>'assignment_id')::uuid),
  'submitted','the hold records the prior work stage');
select is((select lifecycle_status from app_private.assignment_cases
  where assignment_id=(current_setting('test.hold_assignment')::jsonb->>'assignment_id')::uuid),
  'open','opening a hold creates an active case lifecycle record');
select is((select terms_sha256 from app_private.assignment_cases
  where assignment_id=(current_setting('test.hold_assignment')::jsonb->>'assignment_id')::uuid),
  (select terms_sha256 from app_private.assignments
    where assignment_id=(current_setting('test.hold_assignment')::jsonb->>'assignment_id')::uuid),
  'the case snapshots the exact accepted terms hash');
select is((select follow_up from app_private.assignment_holds
  where assignment_id=(current_setting('test.hold_assignment')::jsonb->>'assignment_id')::uuid),
  'Please review the submitted work.','a bounded optional follow-up is preserved in the immutable report');
select is(public.server_get_assignment_case_for_actor(
  current_setting('test.unverified')::uuid,
  (current_setting('test.open_hold')::jsonb->'hold'->>'hold_id')::uuid
)->>'status','open','an assignment party reads the shared current case status');
select ok(jsonb_array_length(public.server_get_assignment_case_for_actor(
  current_setting('test.unverified')::uuid,
  (current_setting('test.open_hold')::jsonb->'hold'->>'hold_id')::uuid
)->'timeline') >= 1,'participants receive a bounded shared case timeline');
select throws_ok(format($sql$
  select public.server_get_assignment_case_for_actor(%L::uuid,%L::uuid)
$sql$,current_setting('test.case_staff'),
  current_setting('test.open_hold')::jsonb->'hold'->>'hold_id'),
  'P0002','case_not_found','a nonparty cannot read the participant case projection');
select is(jsonb_array_length(public.server_list_assignment_case_queue_for_actor(
  current_setting('test.case_staff')::uuid,'aal2',51::smallint
)->'items'),1,'AAL2 reviewer queue lists only unassigned or personally assigned active cases');
select is((public.server_list_assignment_case_queue_for_actor(
  current_setting('test.case_staff')::uuid,'aal2',51::smallint
)->'items'->0)->'assigned_to_me','false'::jsonb,
  'an unassigned reviewer queue case reports assigned_to_me as false, not JSON null');
select ok(not ((public.server_list_assignment_case_queue_for_actor(
  current_setting('test.case_staff')::uuid,'aal2',51::smallint
)->'items'->0) ? 'narrative'),
  'staff triage queue omits participant narratives and private context');
-- Give the two parties temporary synthetic reviewer grants so the next denial
-- proves the explicit party-conflict rule, rather than merely target eligibility.
insert into app_private.staff_grants(user_id,capability,granted_by,reason)
values(current_setting('test.poster')::uuid,'dispute_review',current_setting('test.case_staff')::uuid,
  'Synthetic conflict test grant for the case poster party.');
select set_config('test.case_assignment',public.server_assign_case_reviewer_for_actor(
  current_setting('test.case_staff')::uuid,
  (current_setting('test.open_hold')::jsonb->'hold'->>'hold_id')::uuid,
  current_setting('test.case_staff')::uuid,'aal2',
  '14000000-0000-4000-8000-000000000061'
)::text,true);
select is(current_setting('test.case_assignment')::jsonb->>'status','under_review',
  'an active reviewer explicitly takes the case under the current scoped grant');
select is(public.server_assign_case_reviewer_for_actor(
  current_setting('test.case_staff')::uuid,
  (current_setting('test.open_hold')::jsonb->'hold'->>'hold_id')::uuid,
  current_setting('test.case_staff')::uuid,'aal2',
  '14000000-0000-4000-8000-000000000061'
)->>'version','2','repeating the same reviewer assignment returns its original version');
select throws_ok(format($sql$
  select public.server_assign_case_reviewer_for_actor(%L::uuid,%L::uuid,%L::uuid,'aal2',%L::uuid)
$sql$,current_setting('test.case_staff'),
  current_setting('test.open_hold')::jsonb->'hold'->>'hold_id',
  current_setting('test.poster'),'14000000-0000-4000-8000-000000000061'),
  '23505','idempotency_conflict','a reviewer assignment key cannot be reused with a changed target');
select throws_ok(format($sql$
  select public.server_assign_case_reviewer_for_actor(%L::uuid,%L::uuid,%L::uuid,'aal2',%L::uuid)
$sql$,current_setting('test.case_staff'),
  current_setting('test.open_hold')::jsonb->'hold'->>'hold_id',
  current_setting('test.poster'),'14000000-0000-4000-8000-000000000064'),
  '42501','case_access_denied','an assignment party cannot be selected as reviewer');
select is(public.server_get_assignment_case_for_actor(
  current_setting('test.poster')::uuid,
  (current_setting('test.open_hold')::jsonb->'hold'->>'hold_id')::uuid
)->>'status','under_review','the poster sees the same current case stage as the worker');
select ok(not (public.server_get_assignment_case_for_actor(
  current_setting('test.poster')::uuid,
  (current_setting('test.open_hold')::jsonb->'hold'->>'hold_id')::uuid
)->'timeline'->1 ? 'reviewer_id'),
  'participant timeline hides reviewer identity and internal assignment metadata');
select ok((public.server_get_assignment_case_for_reviewer(
  current_setting('test.case_staff')::uuid,
  (current_setting('test.open_hold')::jsonb->'hold'->>'hold_id')::uuid,'aal2'
)->>'terms_snapshot') is not null,
  'assigned reviewer can inspect the exact accepted terms snapshot');
select is(public.server_get_assignment_case_for_reviewer(
  current_setting('test.case_staff')::uuid,
  (current_setting('test.open_hold')::jsonb->'hold'->>'hold_id')::uuid,'aal2'
)->'conversation_snapshot'->0->>'body',
  'I delivered the agreed items before the deadline.',
  'reviewer context is limited to the accepted assignment conversation through the opening snapshot');
select is((select max_files::integer from app_private.case_file_policy where policy_id=1),5,
  'case evidence has a configurable five-file engineering default');
select is((select max_file_bytes::bigint from app_private.case_file_policy where policy_id=1),5000000::bigint,
  'case evidence defaults to five million bytes per file, separate from identity evidence');
select is(jsonb_array_length(public.server_list_assignment_case_queue_for_actor(
  current_setting('test.case_staff')::uuid,'aal2',51::smallint
)->'items'),1,'AAL2 reviewer queue lists only unassigned or personally assigned active cases');
select is((public.server_list_assignment_case_queue_for_actor(
  current_setting('test.case_staff')::uuid,'aal2',51::smallint
)->'items'->0)->'assigned_to_me','true'::jsonb,
  'the assigned reviewer queue projection remains a boolean value');
select ok(not ((public.server_list_assignment_case_queue_for_actor(
  current_setting('test.case_staff')::uuid,'aal2',51::smallint
)->'items'->0) ? 'narrative'),
  'staff triage queue omits participant narratives and private context');
select ok(exists(select 1 from app_private.assignment_case_access_audit
  where case_id=(current_setting('test.open_hold')::jsonb->'hold'->>'hold_id')::uuid
    and actor_id=current_setting('test.case_staff')::uuid and action='case_read'),
  'reviewer detail access is audited');
select throws_ok(format($sql$
  select public.server_get_assignment_case_for_reviewer(%L::uuid,%L::uuid,'aal1')
$sql$,current_setting('test.case_staff'),
  current_setting('test.open_hold')::jsonb->'hold'->>'hold_id'),
  '42501','case_access_denied','AAL1 cannot read staff case details');
select throws_ok(format($sql$
  select public.server_list_assignment_case_queue_for_actor(%L::uuid,'aal1',51::smallint)
$sql$,current_setting('test.case_staff')),
  '42501','case_access_denied','AAL1 cannot list the reviewer case queue');
update app_private.staff_grants set revoked_at=pg_catalog.now(),
  revoked_by=current_setting('test.case_staff')::uuid
where user_id=current_setting('test.case_staff')::uuid
  and capability='dispute_review' and revoked_at is null;
insert into app_private.staff_grants(user_id,capability,granted_by,reason)
values(current_setting('test.case_staff')::uuid,'financial_inspect',
  current_setting('test.case_staff')::uuid,'Synthetic inspection-only grant after reviewer revocation.');
select throws_ok(format($sql$
  select public.server_get_assignment_case_for_reviewer(%L::uuid,%L::uuid,'aal2')
$sql$,current_setting('test.case_staff'),
  current_setting('test.open_hold')::jsonb->'hold'->>'hold_id'),
  '42501','case_access_denied','financial inspection without dispute-review cannot read case details');
select throws_ok(format($sql$
  select public.server_list_assignment_case_queue_for_actor(%L::uuid,'aal2',51::smallint)
$sql$,current_setting('test.case_staff')),
  '42501','case_access_denied','financial inspection without dispute-review cannot see the case queue');
select is(public.server_open_assignment_hold_for_actor(
  current_setting('test.unverified')::uuid,
  (current_setting('test.hold_assignment')::jsonb->>'assignment_id')::uuid,
  'work_not_as_described','The item delivered differs from the agreed item.',
  'Please review the agreed description and delivery.',
  'Please review the submitted work.','14000000-0000-4000-8000-000000000057'
)->'hold'->>'hold_id',current_setting('test.open_hold')::jsonb->'hold'->>'hold_id',
  'an identical hold retry returns the original hold');
select is((public.server_get_assignment_status_for_actor(
  current_setting('test.poster')::uuid,
  (current_setting('test.hold_assignment')::jsonb->>'assignment_id')::uuid
)->'hold'->>'narrative'),
  'The item delivered differs from the agreed item.',
  'the other assignment participant can read the report through a private projection');
select ok(not (public.server_get_assignment_status_for_actor(
  current_setting('test.poster')::uuid,
  (current_setting('test.hold_assignment')::jsonb->>'assignment_id')::uuid
)->'assignment' ? 'worker_id')
  and not (public.server_get_assignment_status_for_actor(
    current_setting('test.poster')::uuid,
    (current_setting('test.hold_assignment')::jsonb->>'assignment_id')::uuid
  )->'assignment' ? 'bank_account'),
  'participant assignment status omits identity and bank columns');
select throws_ok(format($sql$
  select public.server_get_assignment_status_for_actor(%L::uuid,%L::uuid)
$sql$,current_setting('test.withdrawn_worker'),
  current_setting('test.hold_assignment')::jsonb->>'assignment_id'),
  'P0002','assignment_not_found','a nonparticipant cannot inspect a guessed assignment status');
select is((select status from app_private.principal_allocations
  where allocation_id=(select allocation_id from app_private.assignments
    where assignment_id=(current_setting('test.hold_assignment')::jsonb->>'assignment_id')::uuid)),
  'dispute_held','a reported allocation remains held');
select is((select count(*)::integer from app_private.ledger_journal_transactions
  where effect_type='completion_released'
    and reference_id=(select allocation_id from app_private.assignments
      where assignment_id=(current_setting('test.hold_assignment')::jsonb->>'assignment_id')::uuid)),0,
  'opening a hold never releases worker earnings');
select throws_ok(format($sql$
  select public.server_confirm_completion_for_actor(%L::uuid,%L::uuid,%L::uuid)
$sql$,current_setting('test.poster'),current_setting('test.hold_assignment')::jsonb->>'assignment_id',
  '14000000-0000-4000-8000-000000000058'),
  'P0001','assignment_on_hold','a poster cannot confirm an assignment while it is held');
select throws_ok(format($sql$
  select public.server_open_assignment_hold_for_actor(%L::uuid,%L::uuid,'other','Second report','Review it',%L::uuid)
$sql$,current_setting('test.poster'),current_setting('test.hold_assignment')::jsonb->>'assignment_id',
  '14000000-0000-4000-8000-000000000059'),
  'P0001','assignment_on_hold','a second active report cannot be attached to the same allocation');
select is((select count(*)::integer from app_private.marketplace_outbox
  where event_type='job.assignment_hold_opened' and job_id=current_setting('test.hold_job_id')::uuid),1,
  'opening a hold commits one durable marketplace event');
select is((select count(*)::integer from app_private.in_app_notifications
  where notification_type='assignment_hold_opened'),2,
  'opening a hold notifies each participant once');
update app_private.identity_accounts set account_status='suspended'
where user_id=current_setting('test.unverified')::uuid;
select is(public.server_get_assignment_status_for_actor(
  current_setting('test.unverified')::uuid,
  (current_setting('test.hold_assignment')::jsonb->>'assignment_id')::uuid
)->'assignment'->>'assignment_state','submitted',
  'a suspended participant retains read-only assignment financial status');
select throws_ok(format($sql$
  select public.server_start_assignment_for_actor(%L::uuid,%L::uuid,%L::uuid)
$sql$,current_setting('test.unverified'),
  current_setting('test.hold_assignment')::jsonb->>'assignment_id',
  '14000000-0000-4000-8000-000000000060'),
  '42501','verification_required','a suspended participant cannot start assignment work');
update app_private.identity_accounts set account_status='active'
where user_id=current_setting('test.unverified')::uuid;

-- Phase 4 Step 3: per-slot cancellation, pre-start mutual consent and safe reuse.
select set_config('test.cancel_draft',public.server_create_job_draft_for_actor(
  current_setting('test.poster')::uuid,
  current_setting('test.terms')::jsonb||'{"slot_count":3}'::jsonb,
  '14000000-0000-4000-8000-000000000100'
)::text,true);
select set_config('test.cancel_job_id',current_setting('test.cancel_draft')::jsonb->>'job_id',true);
select set_config('test.cancel_funding',public.server_start_job_funding_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.cancel_job_id')::uuid,1,
  '14000000-0000-4000-8000-000000000101'
)::text,true);
select set_config('test.cancel_operation',current_setting('test.cancel_funding')::jsonb->>'operation_id',true);
select set_config('test.cancel_claim',app_private.claim_payment_operation_job(
  '14000000-0000-4000-8000-000000000102',30::smallint)::text,true);
select public.server_complete_job_funding_operation_for_runner(
  current_setting('test.cancel_operation')::uuid,
  (current_setting('test.cancel_claim')::jsonb->>'lease_token')::uuid,
  'succeeded','sim-'||(current_setting('test.cancel_funding')::jsonb->>'provider_idempotency_key'),
  '900000','NGN','fake_nbd_local_merchant_v1',
  (current_setting('test.cancel_funding')::jsonb->>'provider_idempotency_key')::uuid,
  '4500',null,false,pg_catalog.encode(extensions.digest('step3 cancellation fixture','sha256'),'hex')
);
select set_config('test.cancel_app_student',public.server_apply_to_job_for_actor(
  current_setting('test.student')::uuid,current_setting('test.cancel_job_id')::uuid,
  'First synthetic cancellation applicant.','14000000-0000-4000-8000-000000000103'
)::text,true);
select set_config('test.cancel_app_unverified',public.server_apply_to_job_for_actor(
  current_setting('test.unverified')::uuid,current_setting('test.cancel_job_id')::uuid,
  'Second synthetic cancellation applicant.','14000000-0000-4000-8000-000000000104'
)::text,true);
select set_config('test.cancel_slot1',(
  select allocation_id::text from app_private.principal_allocations
  where job_id=current_setting('test.cancel_job_id')::uuid and slot_number=1
),true);
select set_config('test.cancel_slot2',(
  select allocation_id::text from app_private.principal_allocations
  where job_id=current_setting('test.cancel_job_id')::uuid and slot_number=2
),true);
select set_config('test.cancel_slot3',(
  select allocation_id::text from app_private.principal_allocations
  where job_id=current_setting('test.cancel_job_id')::uuid and slot_number=3
),true);
select set_config('test.cancel_assignment1',public.server_accept_application_for_actor(
  current_setting('test.poster')::uuid,
  (current_setting('test.cancel_app_unverified')::jsonb->>'application_id')::uuid,
  '14000000-0000-4000-8000-000000000105'
)::text,true);
select set_config('test.cancel_assignment2',public.server_accept_application_for_actor(
  current_setting('test.poster')::uuid,
  (current_setting('test.cancel_app_student')::jsonb->>'application_id')::uuid,
  '14000000-0000-4000-8000-000000000106'
)::text,true);
select set_config('test.cancel_batch',public.server_cancel_unassigned_slots_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.cancel_job_id')::uuid,
  array[current_setting('test.cancel_slot3')::uuid,current_setting('test.cancel_slot1')::uuid],
  'I no longer need one of these places.',
  '14000000-0000-4000-8000-000000000107'
)::text,true);
select is(current_setting('test.cancel_batch')::jsonb->'results'->0->>'result',
  'refund_payable_authorized','the eligible unassigned slot in a mixed batch gets its own refund payable');
select is(current_setting('test.cancel_batch')::jsonb->'results'->1->>'result',
  'ineligible','an assigned slot in the same batch is reported ineligible without affecting it');
select is((select status from app_private.principal_allocations
  where allocation_id=current_setting('test.cancel_slot3')::uuid),'refund_payable',
  'only the explicitly selected unassigned slot becomes refund payable');
select is((select status from app_private.principal_allocations
  where allocation_id=current_setting('test.cancel_slot1')::uuid),'assigned',
  'the principal bound to another worker remains held');
select is((select count(*)::integer from app_private.allocation_refund_payables
  where allocation_id=current_setting('test.cancel_slot3')::uuid and status='authorized'),1,
  'one selected unused slot creates one identifiable payable');
select is((select count(*)::integer from app_private.assignment_cancellation_audit
  where action='unassigned_slot_refund_authorized' and allocation_id=current_setting('test.cancel_slot3')::uuid),1,
  'the poster reason is durably audited for the unused-slot authorization');
select is(public.server_cancel_unassigned_slots_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.cancel_job_id')::uuid,
  array[current_setting('test.cancel_slot3')::uuid,current_setting('test.cancel_slot1')::uuid],
  'I no longer need one of these places.','14000000-0000-4000-8000-000000000107'
)->'results'->0->>'refund_payable_id',
  current_setting('test.cancel_batch')::jsonb->'results'->0->>'refund_payable_id',
  'repeating a mixed batch returns the original per-slot results');
select throws_ok(format($sql$
  select public.server_cancel_unassigned_slots_for_actor(%L::uuid,%L::uuid,%L::uuid[],'changed reason',%L::uuid)
$sql$,current_setting('test.poster'),current_setting('test.cancel_job_id'),
  array[current_setting('test.cancel_slot3')::uuid,current_setting('test.cancel_slot1')::uuid],
  '14000000-0000-4000-8000-000000000107'),
  '23505','idempotency_conflict','a batch key cannot be replayed with changed reason');
select throws_ok(format($sql$
  select public.server_cancel_unassigned_slots_for_actor(%L::uuid,%L::uuid,%L::uuid[],'Not my job.',%L::uuid)
$sql$,current_setting('test.unverified'),current_setting('test.cancel_job_id'),
  array[current_setting('test.cancel_slot3')::uuid],'14000000-0000-4000-8000-000000000108'),
  'P0002','job_not_found','a worker cannot authorize a poster refund');

-- Start wins on assignment 1; abandonment wins on assignment 2.
select public.server_start_assignment_for_actor(
  current_setting('test.unverified')::uuid,
  (current_setting('test.cancel_assignment1')::jsonb->>'assignment_id')::uuid,
  '14000000-0000-4000-8000-000000000109'
);
select throws_ok(format($sql$
  select public.server_abandon_prestart_assignment_for_actor(%L::uuid,%L::uuid,'Too late',%L::uuid)
$sql$,current_setting('test.unverified'),
  current_setting('test.cancel_assignment1')::jsonb->>'assignment_id',
  '14000000-0000-4000-8000-000000000110'),
  'P0001','stale_state','work-started assignment cannot be abandoned as a financial cancellation');
select throws_ok(format($sql$
  select public.server_request_prestart_cancellation_for_actor(%L::uuid,%L::uuid,'Stop after work started',%L::uuid)
$sql$,current_setting('test.poster'),current_setting('test.cancel_assignment1')::jsonb->>'assignment_id',
  '14000000-0000-4000-8000-000000000119'),
  'P0001','stale_state','a poster cannot use voluntary cancellation to decide money after work starts');
update app_private.identity_accounts set account_status='suspended'
where user_id=current_setting('test.student')::uuid;
select throws_ok(format($sql$
  select public.server_abandon_prestart_assignment_for_actor(%L::uuid,%L::uuid,'Suspended request',%L::uuid)
$sql$,current_setting('test.student'),current_setting('test.cancel_assignment2')::jsonb->>'assignment_id',
  '14000000-0000-4000-8000-000000000120'),
  '42501','verification_required','a suspended worker cannot authorize financial cancellation');
update app_private.identity_accounts set account_status='active'
where user_id=current_setting('test.student')::uuid;
select set_config('test.abandoned',public.server_abandon_prestart_assignment_for_actor(
  current_setting('test.student')::uuid,
  (current_setting('test.cancel_assignment2')::jsonb->>'assignment_id')::uuid,
  'I can no longer take this work.',
  '14000000-0000-4000-8000-000000000111'
)::text,true);
select is(current_setting('test.abandoned')::jsonb->'allocation'->>'status','unassigned',
  'pre-start abandonment returns held principal to the same unassigned slot');
select is(current_setting('test.abandoned')::jsonb->>'listing_state','open',
  'discovery reopens while the original application deadline remains in the future');
select is((select count(*)::integer from app_private.allocation_refund_payables
  where allocation_id=current_setting('test.cancel_slot2')::uuid),0,
  'worker abandonment creates no poster refund');
select is((select count(*)::integer from app_private.ledger_journal_transactions
  where effect_type='allocation_reopened' and reference_id=(current_setting('test.cancel_assignment2')::jsonb->>'assignment_id')::uuid),1,
  'abandonment records one balanced internal reclassification');
select is((select count(*)::integer from app_private.allocation_assignment_bindings
  where assignment_id=(current_setting('test.cancel_assignment2')::jsonb->>'assignment_id')::uuid
    and unbound_reason='worker_abandonment'),1,
  'the cancelled assignment remains in history with an explicit closed binding');
select throws_ok(format($sql$
  select public.server_start_assignment_for_actor(%L::uuid,%L::uuid,%L::uuid)
$sql$,current_setting('test.student'),current_setting('test.cancel_assignment2')::jsonb->>'assignment_id',
  '14000000-0000-4000-8000-000000000112'),
  'P0001','stale_state','the former worker cannot start after their slot is returned');
select is(public.server_get_application_thread_for_actor(
  current_setting('test.student')::uuid,
  (current_setting('test.cancel_app_student')::jsonb->>'application_id')::uuid,0,51::smallint
)->>'thread_state','read_only','abandonment closes the original conversation while preserving its history');

select set_config('test.cancel_app_replacement',public.server_apply_to_job_for_actor(
  current_setting('test.withdrawn_worker')::uuid,current_setting('test.cancel_job_id')::uuid,
  'I can take the reopened place.','14000000-0000-4000-8000-000000000113'
)::text,true);
select set_config('test.cancel_assignment_replacement',public.server_accept_application_for_actor(
  current_setting('test.poster')::uuid,
  (current_setting('test.cancel_app_replacement')::jsonb->>'application_id')::uuid,
  '14000000-0000-4000-8000-000000000114'
)::text,true);
select is((select count(*)::integer from app_private.assignments
  where allocation_id=current_setting('test.cancel_slot2')::uuid),2,
  'reusing a funded slot preserves both its abandoned assignment and replacement assignment');
select is((select count(*)::integer from app_private.allocation_assignment_bindings
  where allocation_id=current_setting('test.cancel_slot2')::uuid),2,
  'each assignment has a separate historical binding row');
select is((select count(*)::integer from app_private.allocation_assignment_bindings
  where allocation_id=current_setting('test.cancel_slot2')::uuid and unbound_at is null),1,
  'a reused slot can have only one current assignment binding');
select throws_ok(format($sql$
  select public.server_confirm_completion_for_actor(%L::uuid,%L::uuid,%L::uuid)
$sql$,current_setting('test.poster'),current_setting('test.cancel_assignment2')::jsonb->>'assignment_id',
  '14000000-0000-4000-8000-000000000115'),
  'P0001','stale_state','an old assignment cannot release principal after its allocation is reused');

select set_config('test.cancellation_request',public.server_request_prestart_cancellation_for_actor(
  current_setting('test.poster')::uuid,
  (current_setting('test.cancel_assignment_replacement')::jsonb->>'assignment_id')::uuid,
  'We both agreed to stop before work starts.',
  '14000000-0000-4000-8000-000000000116'
)::text,true);
select is(current_setting('test.cancellation_request')::jsonb->>'status','awaiting_other_party',
  'one cancellation request records only the first participant consent');
select is((select count(*)::integer from app_private.allocation_refund_payables
  where allocation_id=current_setting('test.cancel_slot2')::uuid),0,
  'the first consent alone creates no refund payable');
select is((select count(*)::integer from app_private.ledger_journal_transactions
  where effect_type='allocation_refund_authorized'),1,
  'the first consent alone posts no refund journal');
select set_config('test.cancellation_final',public.server_consent_prestart_cancellation_for_actor(
  current_setting('test.withdrawn_worker')::uuid,
  (current_setting('test.cancellation_request')::jsonb->>'cancellation_id')::uuid,1,
  'I also agree to stop before work starts.',
  '14000000-0000-4000-8000-000000000117'
)::text,true);
select is(current_setting('test.cancellation_final')::jsonb->>'status','completed',
  'the matching second participant consent finalizes once');
select is((select status from app_private.principal_allocations
  where allocation_id=current_setting('test.cancel_slot2')::uuid),'refund_payable',
  'mutual pre-start cancellation makes the exact held principal payable to its poster');
select is((select amount_kobo::text from app_private.allocation_refund_payables
  where allocation_id=current_setting('test.cancel_slot2')::uuid),'300000',
  'mutual cancellation payable equals the original allocation gross in kobo');
select is((select state from app_private.job_applications
  where application_id=(current_setting('test.cancel_app_replacement')::jsonb->>'application_id')::uuid),
  'closed','mutual cancellation closes the accepted application without deleting it');
select is(public.server_get_application_thread_for_actor(
  current_setting('test.withdrawn_worker')::uuid,
  (current_setting('test.cancel_app_replacement')::jsonb->>'application_id')::uuid,0,51::smallint
)->>'thread_state','read_only','mutual cancellation leaves the original conversation read-only');
select throws_ok(format($sql$
  select public.server_start_assignment_for_actor(%L::uuid,%L::uuid,%L::uuid)
$sql$,current_setting('test.withdrawn_worker'),current_setting('test.cancel_assignment_replacement')::jsonb->>'assignment_id',
  '14000000-0000-4000-8000-000000000118'),
  'P0001','stale_state','final consent winning prevents the worker from starting');
select is(public.server_consent_prestart_cancellation_for_actor(
  current_setting('test.withdrawn_worker')::uuid,
  (current_setting('test.cancellation_request')::jsonb->>'cancellation_id')::uuid,1,
  'I also agree to stop before work starts.','14000000-0000-4000-8000-000000000117'
)->>'status','completed','a duplicate final consent returns the completed result without another effect');
select is((select count(*)::integer from app_private.assignment_cancellation_finalizations
  where cancellation_id=(current_setting('test.cancellation_request')::jsonb->>'cancellation_id')::uuid),1,
  'duplicate consent leaves one finalization record');
select is((public.server_get_my_wallet_for_actor(current_setting('test.poster')::uuid,null,null)
  ->'balances'->>'poster_refund_payable_kobo'),'600000',
  'wallet shows both authorized refund payables separately from held principal');
select is(jsonb_array_length(public.server_get_my_wallet_for_actor(
  current_setting('test.poster')::uuid,null,null)->'refund_payables'),2,
  'wallet lists each authorized payable without claiming external settlement');
select is((select count(*)::integer from app_private.assignment_cases c
  where c.allocation_id in (current_setting('test.cancel_slot1')::uuid,current_setting('test.cancel_slot2')::uuid)
    and c.lifecycle_status<>'closed'),0,
  'voluntary cancellation does not create a dispute case');

-- Phase 4 Step 4: scoped investigation, private participant requests and evidence quarantine.
insert into app_private.staff_grants(user_id,capability,granted_by,reason)
values(current_setting('test.case_staff')::uuid,'dispute_review',current_setting('test.case_staff')::uuid,
  'Synthetic local case reviewer regrant for Step 4 investigation tests.');
select set_config('test.case_id',current_setting('test.open_hold')::jsonb->'hold'->>'hold_id',true);
select is(public.server_case_investigation_command_for_actor(
  current_setting('test.case_staff')::uuid,current_setting('test.case_id')::uuid,'triage_case',
  jsonb_build_object('priority','normal','rationale','Initial review completed; safety and evidence remain under review.'),
  'aal2','14000000-0000-4000-8000-000000000130'
)->>'acknowledged','true','assigned AAL2 reviewer can record case triage without deciding money');
select is(public.server_case_investigation_command_for_actor(
  current_setting('test.case_staff')::uuid,current_setting('test.case_id')::uuid,'triage_case',
  jsonb_build_object('priority','normal','rationale','Initial review completed; safety and evidence remain under review.'),
  'aal2','14000000-0000-4000-8000-000000000130'
)->>'version','3','the same case command retry returns the original result');
select throws_ok($sql$
  select public.server_case_investigation_command_for_actor(
    current_setting('test.case_staff')::uuid,current_setting('test.case_id')::uuid,'triage_case',
    jsonb_build_object('priority','urgent','rationale','Changed request under the same key.'),
    'aal2','14000000-0000-4000-8000-000000000130'
  )
$sql$,'23505','idempotency_conflict','a changed triage request cannot reuse its command key');
select is(public.server_list_assignment_case_queue_for_actor(
  current_setting('test.case_staff')::uuid,'aal2',51::smallint
)->'items'->0->>'priority','normal','non-safety case priority stays a review-order hint');
select is(public.server_case_investigation_command_for_actor(
  current_setting('test.case_staff')::uuid,current_setting('test.case_id')::uuid,'add_case_internal_note',
  jsonb_build_object('note','Internal reviewer note: check the timeline against the accepted terms.'),
  'aal2','14000000-0000-4000-8000-000000000131'
)->>'recorded','true','reviewer can record a private internal note');
select set_config('test.evidence_request',public.server_case_investigation_command_for_actor(
  current_setting('test.case_staff')::uuid,current_setting('test.case_id')::uuid,'request_case_information',
  jsonb_build_object('target_party_role','worker','request_kind','evidence',
    'prompt','Please attach one image showing the completed work.'),
  'aal2','14000000-0000-4000-8000-000000000132'
)::text,true);
select is(current_setting('test.evidence_request')::jsonb->>'requested','true',
  'assigned reviewer can request bounded evidence from one party');
select ok(exists(select 1 from app_private.marketplace_outbox
  where event_type='job.assignment_case_investigation_updated'
    and payload->>'update'='information_requested')
  and exists(select 1 from app_private.in_app_notifications
    where recipient_id=current_setting('test.unverified')::uuid
      and notification_type='assignment_case_updated'),
  'information requests produce a durable targeted notification');
select is(jsonb_array_length(public.server_get_assignment_case_for_actor(
  current_setting('test.unverified')::uuid,current_setting('test.case_id')::uuid
)->'investigation'->'requests'),1,'the requested worker sees their own request in the case overview');
select is(jsonb_array_length(public.server_get_assignment_case_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.case_id')::uuid
)->'investigation'->'requests'),0,'the other party does not see a request addressed to the worker');
select ok(not (public.server_get_assignment_case_for_actor(
  current_setting('test.unverified')::uuid,current_setting('test.case_id')::uuid
)->'investigation' ? 'internal_notes'),
  'participants never receive the reviewer internal note collection');
select throws_ok($sql$
  select public.server_case_investigation_command_for_actor(
    current_setting('test.case_staff')::uuid,current_setting('test.case_id')::uuid,'request_case_information',
    jsonb_build_object('target_party_role','worker','request_kind','information',
      'prompt','Please use https://example.test to send the file.'),
    'aal2','14000000-0000-4000-8000-000000000133'
  )
$sql$,'22023','invalid_case_command','shared information requests reject public links');
select set_config('test.case_upload',public.server_issue_case_file_upload_for_actor(
  current_setting('test.unverified')::uuid,current_setting('test.case_id')::uuid,
  (current_setting('test.evidence_request')::jsonb->>'request_number')::smallint,
  'image/jpeg',4,repeat('a',64),'14000000-0000-4000-8000-000000000135'
)::text,true);
select is(public.server_claim_case_file_upload_for_actor(
  current_setting('test.unverified')::uuid,
  (current_setting('test.case_upload')::jsonb->>'intent_id')::uuid,repeat('a',64)
)->>'already_finalized','false','only the owning participant can claim the authorized evidence upload intent');
select is(public.server_reject_case_file_upload_for_actor(
  current_setting('test.unverified')::uuid,
  (current_setting('test.case_upload')::jsonb->>'intent_id')::uuid,'signature_mismatch'
)->>'recorded','true','a rejected upload remains rejected and audited');
select is((select state from app_private.case_file_upload_intents
  where intent_id=(current_setting('test.case_upload')::jsonb->>'intent_id')::uuid),
  'rejected','an invalid file never becomes reviewable evidence');
select set_config('test.case_response',public.server_case_investigation_command_for_actor(
  current_setting('test.unverified')::uuid,current_setting('test.case_id')::uuid,'respond_to_case_information',
  jsonb_build_object('request_number',(current_setting('test.evidence_request')::jsonb->>'request_number')::integer,
    'response','I have the requested photo and will submit it.'),
  'aal1','14000000-0000-4000-8000-000000000134'
)::text,true);
select is(current_setting('test.case_response')::jsonb->>'received','true',
  'an active participant can answer only their own request at AAL1');
select is(public.server_case_investigation_command_for_actor(
  current_setting('test.unverified')::uuid,current_setting('test.case_id')::uuid,'respond_to_case_information',
  jsonb_build_object('request_number',(current_setting('test.evidence_request')::jsonb->>'request_number')::integer,
    'response','I have the requested photo and will submit it.'),
  'aal1','14000000-0000-4000-8000-000000000134'
)->>'version',current_setting('test.case_response')::jsonb->>'version',
  'a repeated participant response returns its original result');
select is(public.server_get_assignment_case_for_actor(
  current_setting('test.unverified')::uuid,current_setting('test.case_id')::uuid
)->'investigation'->'requests'->0->>'response',
  'I have the requested photo and will submit it.','the participant sees their own response in the complete case overview');
select is(jsonb_array_length(public.server_get_assignment_case_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.case_id')::uuid
)->'investigation'->'requests'),0,'participant responses are not exposed to the other party');
select ok(exists(select 1 from app_private.case_file_access_audit
  where case_id=current_setting('test.case_id')::uuid and actor_id=current_setting('test.unverified')::uuid
    and action='metadata_read'),
  'participant metadata access has its own audit record');
select is(public.server_authorize_case_file_download_for_actor(
  current_setting('test.case_staff')::uuid,current_setting('test.case_id')::uuid,1::smallint,'aal2'
)->>'reason','case_evidence_not_ready','quarantined or missing file bytes cannot be downloaded');
insert into app_private.staff_grants(user_id,capability,granted_by,reason)
values(current_setting('test.student')::uuid,'dispute_review',current_setting('test.case_staff')::uuid,
  'Synthetic assigned-scope denial reviewer grant for Step 4 tests.');
select is(public.server_authorize_case_file_download_for_actor(
  current_setting('test.student')::uuid,current_setting('test.case_id')::uuid,1::smallint,'aal2'
)->>'reason','case_access_denied','a staff account with the wrong case scope cannot download case evidence');
select ok(exists(select 1 from app_private.case_file_access_audit
  where case_id=current_setting('test.case_id')::uuid and action='download_denied'),
  'denied byte access is recorded separately from metadata reads');
select ok(not has_table_privilege('authenticated','app_private.case_evidence_files','SELECT')
  and not has_table_privilege('service_role','app_private.case_evidence_files','SELECT')
  and not has_function_privilege('authenticated',
    'public.server_case_investigation_command_for_actor(uuid,uuid,text,jsonb,text,uuid)','EXECUTE')
  and has_function_privilege('service_role',
    'public.server_case_investigation_command_for_actor(uuid,uuid,text,jsonb,text,uuid)','EXECUTE'),
  'case investigation tables are private and the command RPC is service-role only');

-- Two recorded attempts across distinct channels and a separate senior signoff
-- are required before staff can classify a party as unresponsive.
select throws_ok($sql$
  select public.server_case_investigation_command_for_actor(
    current_setting('test.case_staff')::uuid,current_setting('test.case_id')::uuid,'assess_case_nonresponse',
    jsonb_build_object('target_party_role','poster','substantive_reasoning',repeat('This is a substantive reason. ',5)),
    'aal2','14000000-0000-4000-8000-000000000136'
  )
$sql$,'22023','nonresponse_contact_threshold_not_met','silence alone cannot support a nonresponse assessment');
select public.server_case_investigation_command_for_actor(
  current_setting('test.case_staff')::uuid,current_setting('test.case_id')::uuid,'log_case_contact_attempt',
  jsonb_build_object('target_party_role','poster','channel','phone','result','no_response','result_note','No answer.'),
  'aal2','14000000-0000-4000-8000-000000000137');
select public.server_case_investigation_command_for_actor(
  current_setting('test.case_staff')::uuid,current_setting('test.case_id')::uuid,'log_case_contact_attempt',
  jsonb_build_object('target_party_role','poster','channel','email','result','no_response','result_note','No reply recorded.'),
  'aal2','14000000-0000-4000-8000-000000000138');
select set_config('test.nonresponse',public.server_case_investigation_command_for_actor(
  current_setting('test.case_staff')::uuid,current_setting('test.case_id')::uuid,'assess_case_nonresponse',
  jsonb_build_object('target_party_role','poster','substantive_reasoning',repeat('Substantive case-specific reasoning for nonresponse. ',3)),
  'aal2','14000000-0000-4000-8000-000000000139'
)::text,true);
select is((select contact_attempt_count::integer from app_private.assignment_case_nonresponse_assessments
  where case_id=current_setting('test.case_id')::uuid order by created_at desc limit 1),2,
  'nonresponse assessment snapshots two logged attempts');
insert into app_private.staff_grants(user_id,capability,granted_by,reason)
values(current_setting('test.student')::uuid,'case_senior_signoff',current_setting('test.case_staff')::uuid,
  'Synthetic independent senior reviewer grant for Step 4 tests.');
select throws_ok($sql$
  select public.server_case_investigation_command_for_actor(
    current_setting('test.student')::uuid,current_setting('test.case_id')::uuid,'signoff_case_nonresponse',
    jsonb_build_object('assessment_id',(select assessment_id::text from app_private.assignment_case_nonresponse_assessments
      where case_id=current_setting('test.case_id')::uuid order by created_at desc limit 1),
      'substantive_reasoning',repeat('Independent senior review confirms the contact record and reasoning. ',2)),
    'aal1','14000000-0000-4000-8000-000000000140'
  )
$sql$,'42501','case_access_denied','AAL1 cannot supply the required senior signoff');
select throws_ok($sql$
  select public.server_case_investigation_command_for_actor(
    current_setting('test.case_staff')::uuid,current_setting('test.case_id')::uuid,'signoff_case_nonresponse',
    jsonb_build_object('assessment_id',(select assessment_id::text from app_private.assignment_case_nonresponse_assessments
      where case_id=current_setting('test.case_id')::uuid order by created_at desc limit 1),
      'substantive_reasoning',repeat('Independent senior review confirms the contact record and reasoning. ',2)),
    'aal2','14000000-0000-4000-8000-000000000141'
  )
$sql$,'42501','case_access_denied','the assigned reviewer cannot sign their own nonresponse assessment');
select public.server_case_investigation_command_for_actor(
  current_setting('test.case_staff')::uuid,current_setting('test.case_id')::uuid,'log_case_contact_attempt',
  jsonb_build_object('target_party_role','poster','channel','in_app','result','no_response'),
  'aal2','14000000-0000-4000-8000-000000000142');
select throws_ok(format($sql$
  select public.server_case_investigation_command_for_actor(
    %L::uuid,%L::uuid,'signoff_case_nonresponse',
    jsonb_build_object('assessment_id',%L::text,
      'substantive_reasoning',repeat('Independent senior review confirms the contact record and reasoning. ',2)),
    'aal2','14000000-0000-4000-8000-000000000143'
  )
$sql$,current_setting('test.student'),current_setting('test.case_id'),
  (select assessment_id from app_private.assignment_case_nonresponse_assessments
    where case_id=current_setting('test.case_id')::uuid order by created_at desc limit 1)),
  'P0001','stale_state','new contact evidence invalidates the earlier senior signoff snapshot');
select ok(exists(select 1 from app_private.assignment_case_contact_attempts
  where case_id=current_setting('test.case_id')::uuid and attribution='simulated_manual_log'
    and recorded_at is not null and recorded_by=current_setting('test.case_staff')::uuid),
  'manual contact fixtures record staff, server time and their simulated attribution');

-- Phase 4 Step 5: immutable outcome proposals, version-bound approvals and
-- separate version-bound senior signoff. No amount is executed in this step.
update auth.users set raw_app_meta_data=coalesce(raw_app_meta_data,'{}'::jsonb)||
  jsonb_build_object('staff_principal_kind','human')
where id in (current_setting('test.case_staff')::uuid,current_setting('test.student')::uuid);
insert into app_private.staff_grants(user_id,capability,granted_by,reason)
values
  (current_setting('test.case_staff')::uuid,'financial_approve',current_setting('test.case_staff')::uuid,
    'Synthetic local case decision proposer approval grant.'),
  (current_setting('test.student')::uuid,'financial_approve',current_setting('test.case_staff')::uuid,
    'Synthetic local independent case decision approval grant.'),
  (current_setting('test.case_staff')::uuid,'case_senior_signoff',current_setting('test.case_staff')::uuid,
    'Synthetic local reviewer grant used to test senior separation.');
select set_config('test.step5_assessment_result',public.server_case_investigation_command_for_actor(
  current_setting('test.case_staff')::uuid,current_setting('test.case_id')::uuid,'assess_case_nonresponse',
  jsonb_build_object('target_party_role','poster',
    'substantive_reasoning',repeat('A fresh review found the poster did not respond after the recorded attempts. ',2)),
  'aal2','14000000-0000-4000-8000-000000000151')::text,true);
select set_config('test.step5_assessment',(
  select assessment_id::text from app_private.assignment_case_nonresponse_assessments
  where case_id=current_setting('test.case_id')::uuid order by case_version desc,assessment_id desc limit 1
),true);
select is(public.server_case_investigation_command_for_actor(
  current_setting('test.student')::uuid,current_setting('test.case_id')::uuid,'signoff_case_nonresponse',
  jsonb_build_object('assessment_id',current_setting('test.step5_assessment'),
    'substantive_reasoning',repeat('The independent senior reviewed the current contact record and assessment. ',2)),
  'aal2','14000000-0000-4000-8000-000000000152')->>'signed_off','true',
  'fresh non-response assessment receives its separate current senior signoff');
select throws_ok(format($sql$
  select public.server_propose_case_decision_for_actor(%L::uuid,%L::uuid,
    (select version from app_private.assignment_cases where case_id=%L::uuid),
    jsonb_build_object('outcome','split','award_gross_kobo','200000',
      'public_explanation','Verified work supports a partial award and return of the remainder.',
      'nonresponse_assessment_id',%L::uuid),'aal1','14000000-0000-4000-8000-000000000153')
$sql$,current_setting('test.case_staff'),current_setting('test.case_id'),
  current_setting('test.case_id'),current_setting('test.step5_assessment')),
  '42501','case_access_denied','AAL1 cannot propose a case outcome');
select throws_ok(format($sql$
  select public.server_propose_case_decision_for_actor(%L::uuid,%L::uuid,
    (select version from app_private.assignment_cases where case_id=%L::uuid),
    jsonb_build_object('outcome','full_poster_refund','award_gross_kobo','0',
      'public_explanation','The poster receives a full refund under this proposal.'),
    'aal2','14000000-0000-4000-8000-000000000154')
$sql$,current_setting('test.poster'),current_setting('test.case_id'),current_setting('test.case_id')),
  '42501','case_access_denied','a case party cannot propose a staff financial outcome');
select set_config('test.step5_journal_count',
  (select count(*)::text from app_private.ledger_journal_transactions),true);
select set_config('test.step5_proposal',public.server_propose_case_decision_for_actor(
  current_setting('test.case_staff')::uuid,current_setting('test.case_id')::uuid,
  (select version from app_private.assignment_cases where case_id=current_setting('test.case_id')::uuid),
  jsonb_build_object('outcome','split','award_gross_kobo','200000',
    'public_explanation','Verified work supports a partial award and return of the remainder.',
    'nonresponse_assessment_id',current_setting('test.step5_assessment')),
  'aal2','14000000-0000-4000-8000-000000000155')::text,true);
select is(current_setting('test.step5_proposal')::jsonb->>'status','verifying',
  'a proposed split remains in review and is not finalized');
select is(current_setting('test.step5_proposal')::jsonb->>'worker_award_gross_kobo','200000',
  'split proposal records the exact gross worker award in kobo');
select is(current_setting('test.step5_proposal')::jsonb->>'poster_refund_gross_kobo','100000',
  'split proposal records only the remaining held principal as refund payable candidate');
select is(current_setting('test.step5_proposal')::jsonb->>'commission_kobo','10000',
  'five percent commission is computed only on the gross worker award');
select is(current_setting('test.step5_proposal')::jsonb->>'worker_net_kobo','190000',
  'worker net amount plus commission exactly equals the gross award');
select is((select count(*)::integer from app_private.assignment_case_decision_approvals
  where decision_id=(select decision_id from app_private.assignment_case_decision_versions
    where case_id=current_setting('test.case_id')::uuid and decision_version=1)),1,
  'the qualified proposer supplies approval one of two');
select is((select count(*)::text from app_private.ledger_journal_transactions),
  current_setting('test.step5_journal_count'),
  'case decision proposal path leaves the existing journal untouched');
select throws_ok(format($sql$
  select public.server_propose_case_decision_for_actor(%L::uuid,%L::uuid,
    (select version-1 from app_private.assignment_cases where case_id=%L::uuid),
    jsonb_build_object('outcome','no_action','award_gross_kobo','0',
      'public_explanation','Changed proposal should not reuse the earlier case version.'),
    'aal2','14000000-0000-4000-8000-000000000156')
$sql$,current_setting('test.case_staff'),current_setting('test.case_id'),current_setting('test.case_id')),
  'P0001','stale_state','an outdated case version cannot create a competing proposal');
select throws_ok(format($sql$
  select public.server_approve_case_decision_for_actor(%L::uuid,%L::uuid,1,
    (select version-1 from app_private.assignment_cases where case_id=%L::uuid),
    'aal2','14000000-0000-4000-8000-000000000157')
$sql$,current_setting('test.student'),current_setting('test.case_id'),current_setting('test.case_id')),
  'P0001','stale_state','approval with an old case version is rejected');
select throws_ok(format($sql$
  select public.server_approve_case_decision_for_actor(%L::uuid,%L::uuid,1,
    (select version from app_private.assignment_cases where case_id=%L::uuid),
    'aal2','14000000-0000-4000-8000-000000000158')
$sql$,current_setting('test.student'),current_setting('test.case_id'),current_setting('test.case_id')),
  'P0001','stale_state','non-response outcome approval waits for a decision-version senior signoff');
select throws_ok(format($sql$
  select public.server_signoff_case_decision_nonresponse_for_actor(%L::uuid,%L::uuid,1,
    (select version from app_private.assignment_cases where case_id=%L::uuid),
    repeat('The assigned reviewer cannot independently sign the non-response decision. ',2),
    'aal2','14000000-0000-4000-8000-000000000167')
$sql$,current_setting('test.case_staff'),current_setting('test.case_id'),current_setting('test.case_id')),
  '42501','case_access_denied','the assigned reviewer cannot supply the separate senior signoff');
select is(public.server_signoff_case_decision_nonresponse_for_actor(
  current_setting('test.student')::uuid,current_setting('test.case_id')::uuid,1,
  (select version from app_private.assignment_cases where case_id=current_setting('test.case_id')::uuid),
  repeat('Senior review confirms the selected assessment and exact contact snapshot. ',2),
  'aal2','14000000-0000-4000-8000-000000000159')->>'signed_off','true',
  'senior signoff binds to the exact decision version and evidence hash');
update auth.users set raw_app_meta_data=coalesce(raw_app_meta_data,'{}'::jsonb)||
  jsonb_build_object('staff_principal_kind','service')
where id=current_setting('test.student')::uuid;
select throws_ok(format($sql$
  select public.server_approve_case_decision_for_actor(%L::uuid,%L::uuid,1,
    (select version from app_private.assignment_cases where case_id=%L::uuid),
    'aal2','14000000-0000-4000-8000-000000000160')
$sql$,current_setting('test.student'),current_setting('test.case_id'),current_setting('test.case_id')),
  '42501','case_access_denied','service principals cannot supply the independent human approval');
update auth.users set raw_app_meta_data=coalesce(raw_app_meta_data,'{}'::jsonb)||
  jsonb_build_object('staff_principal_kind','human')
where id=current_setting('test.student')::uuid;
update app_private.staff_grants set revoked_at=pg_catalog.now(),
  revoked_by=current_setting('test.case_staff')::uuid
where user_id=current_setting('test.student')::uuid
  and capability='financial_approve' and revoked_at is null;
select throws_ok(format($sql$
  select public.server_approve_case_decision_for_actor(%L::uuid,%L::uuid,1,
    (select version from app_private.assignment_cases where case_id=%L::uuid),
    'aal2','14000000-0000-4000-8000-000000000161')
$sql$,current_setting('test.student'),current_setting('test.case_id'),current_setting('test.case_id')),
  '42501','case_access_denied','a revoked second-approver grant cannot approve the decision');
insert into app_private.staff_grants(user_id,capability,granted_by,reason)
values(current_setting('test.student')::uuid,'financial_approve',current_setting('test.case_staff')::uuid,
  'Synthetic regrant for current case approval test.');
select set_config('test.step5_approval',public.server_approve_case_decision_for_actor(
  current_setting('test.student')::uuid,current_setting('test.case_id')::uuid,1,
  (select version from app_private.assignment_cases where case_id=current_setting('test.case_id')::uuid),
  'aal2','14000000-0000-4000-8000-000000000162')::text,true);
select is(current_setting('test.step5_approval')::jsonb->>'approved','true',
  'a different qualified human supplies approval two and leaves the decision unexecuted');
select is(current_setting('test.step5_approval')::jsonb->>'gross_principal_kobo','300000',
  'second approver receives the exact gross allocation in the safe decision response');
select is((select count(distinct approver_id)::integer from app_private.assignment_case_decision_approvals
  where decision_id=(select decision_id from app_private.assignment_case_decision_versions
    where case_id=current_setting('test.case_id')::uuid and decision_version=1)),2,
  'two approval records have distinct staff identities');
select is((select status from app_private.principal_allocations
  where allocation_id=(select allocation_id from app_private.assignment_cases
    where case_id=current_setting('test.case_id')::uuid)),'dispute_held',
  'approved Step 5 decision leaves the entire allocation held');
select is((select count(*)::integer from app_private.assignment_completion_authorizations
  where assignment_id=(select assignment_id from app_private.assignment_cases
    where case_id=current_setting('test.case_id')::uuid)),0,
  'Step 5 creates no worker earnings authorization');
select is((select count(*)::integer from app_private.allocation_refund_payables
  where allocation_id=(select allocation_id from app_private.assignment_cases
    where case_id=current_setting('test.case_id')::uuid)),0,
  'Step 5 creates no poster refund payable');
select throws_ok(format($sql$
  select public.server_approve_case_decision_for_actor(%L::uuid,%L::uuid,1,
    (select version from app_private.assignment_cases where case_id=%L::uuid),
    'aal2','14000000-0000-4000-8000-000000000163')
$sql$,current_setting('test.student'),current_setting('test.case_id'),current_setting('test.case_id')),
  '42501','case_access_denied','one staff identity cannot supply both approvals even with multiple grants');
select is(public.server_approve_case_decision_for_actor(
  current_setting('test.student')::uuid,current_setting('test.case_id')::uuid,1,
  (select version-1 from app_private.assignment_cases where case_id=current_setting('test.case_id')::uuid),
  'aal2','14000000-0000-4000-8000-000000000162')->>'decision_version','1',
  'same approval key replays the saved immutable response');
select throws_ok(format($sql$
  select public.server_approve_case_decision_for_actor(%L::uuid,%L::uuid,2,
    (select version-1 from app_private.assignment_cases where case_id=%L::uuid),
    'aal2','14000000-0000-4000-8000-000000000162')
$sql$,current_setting('test.student'),current_setting('test.case_id'),current_setting('test.case_id')),
  '23505','idempotency_conflict','the approval key cannot be reused for a changed request');
select is((public.server_get_assignment_case_for_reviewer(
  current_setting('test.case_staff')::uuid,current_setting('test.case_id')::uuid,'aal2'
)->'investigation'->'decision'->>'status'),'approved',
  'assigned reviewer receives a safe summary after approval');
select is((public.server_get_assignment_case_for_actor(
  current_setting('test.unverified')::uuid,current_setting('test.case_id')::uuid
)->>'status'),'decision_made',
  'participants see the approved decision state after the durable Step 6 notice');
select ok(not (public.server_get_assignment_case_for_actor(
  current_setting('test.unverified')::uuid,current_setting('test.case_id')::uuid)->'investigation' ? 'decision'),
  'participants do not receive decision amounts or staff-only evidence summaries before Step 6');

-- Changing the proposal creates versions, with only each new proposer approval.
select set_config('test.step5_no_action',public.server_propose_case_decision_for_actor(
  current_setting('test.case_staff')::uuid,current_setting('test.case_id')::uuid,
  (select version from app_private.assignment_cases where case_id=current_setting('test.case_id')::uuid),
  jsonb_build_object('outcome','no_action','award_gross_kobo','0',
    'public_explanation','No financial award is justified by this reviewed evidence.',
    'nonresponse_assessment_id',current_setting('test.step5_assessment')),
  'aal2','14000000-0000-4000-8000-000000000164')::text,true);
select is(current_setting('test.step5_no_action')::jsonb->>'retained_hold_gross_kobo','300000',
  'no-action proposal retains the exact amount in the existing hold');
select is(current_setting('test.step5_no_action')::jsonb->>'poster_refund_gross_kobo','0',
  'no-action does not create a poster refund amount');
select is(current_setting('test.step5_no_action')::jsonb->>'decision_version','2',
  'changing the proposed outcome creates a new immutable decision version');
select is((select count(*)::integer from app_private.assignment_case_decision_approvals
  where decision_id=(select decision_id from app_private.assignment_case_decision_versions
    where case_id=current_setting('test.case_id')::uuid and decision_version=2)),1,
  'a replacement version receives only its own proposer approval');
select set_config('test.step5_refund',public.server_propose_case_decision_for_actor(
  current_setting('test.case_staff')::uuid,current_setting('test.case_id')::uuid,
  (select version from app_private.assignment_cases where case_id=current_setting('test.case_id')::uuid),
  jsonb_build_object('outcome','full_poster_refund','award_gross_kobo','0',
    'public_explanation','Evidence supports a full return of the held principal.',
    'nonresponse_assessment_id',current_setting('test.step5_assessment')),
  'aal2','14000000-0000-4000-8000-000000000165')::text,true);
select is(current_setting('test.step5_refund')::jsonb->>'poster_refund_gross_kobo','300000',
  'full-refund proposal returns the exact held principal in its decision amounts');
select set_config('test.step5_award',public.server_propose_case_decision_for_actor(
  current_setting('test.case_staff')::uuid,current_setting('test.case_id')::uuid,
  (select version from app_private.assignment_cases where case_id=current_setting('test.case_id')::uuid),
  jsonb_build_object('outcome','full_worker_award','award_gross_kobo','300000',
    'public_explanation','Evidence supports a full award of the held worker amount.',
    'nonresponse_assessment_id',current_setting('test.step5_assessment')),
  'aal2','14000000-0000-4000-8000-000000000166')::text,true);
select is(current_setting('test.step5_award')::jsonb->>'commission_kobo','15000',
  'full award computes commission from the entire gross worker award');
select is((current_setting('test.step5_award')::jsonb->>'decision_version')::integer,4,
  'full worker award is preserved as a separate decision version');
select ok((select count(distinct encode(decision_sha256,'hex'))=4
  from app_private.assignment_case_decision_versions where case_id=current_setting('test.case_id')::uuid),
  'changed outcome and amounts produce distinct immutable decision hashes');
select is((public.server_get_assignment_case_for_reviewer(
  current_setting('test.case_staff')::uuid,current_setting('test.case_id')::uuid,'aal2'
)->'investigation'->'decision'->>'approval_count'),'1',
  'older approvals are not copied to the latest decision version');
update app_private.staff_grants set revoked_at=pg_catalog.now(),
  revoked_by=current_setting('test.student')::uuid
where user_id=current_setting('test.case_staff')::uuid
  and capability='financial_approve' and revoked_at is null;
select throws_ok(format($sql$
  select public.server_approve_case_decision_for_actor(%L::uuid,%L::uuid,4,
    (select version from app_private.assignment_cases where case_id=%L::uuid),
    'aal2','14000000-0000-4000-8000-000000000168')
$sql$,current_setting('test.case_staff'),current_setting('test.case_id'),current_setting('test.case_id')),
  '42501','case_access_denied','financial_inspect alone remains read-only when financial_approve is revoked');
select ok(not has_table_privilege('authenticated','app_private.assignment_case_decision_versions','SELECT')
  and not has_table_privilege('service_role','app_private.assignment_case_decision_versions','SELECT')
  and has_function_privilege('service_role',
    'public.server_propose_case_decision_for_actor(uuid,uuid,integer,jsonb,text,uuid)','EXECUTE')
  and not has_function_privilege('authenticated',
    'public.server_approve_case_decision_for_actor(uuid,uuid,integer,integer,text,uuid)','EXECUTE'),
  'decision history is private and decision commands are reachable only through the server boundary');

-- Phase 4 Step 6: durable shared decision notice and one strict-before appeal per party.
select is((select appeal_deadline_at-durable_notified_at
  from app_private.assignment_case_decision_publications
  where case_id=current_setting('test.case_id')::uuid),interval '72 hours',
  'the initial decision starts exactly one stored 72-hour appeal window');
select ok((select count(*)=2 and count(distinct n.event_id)=1 and count(distinct n.created_at)=1
    and min(n.created_at)=max(n.created_at)
  from app_private.in_app_notifications n
  join app_private.assignment_case_decision_publications p on p.marketplace_event_id=n.event_id
  where p.case_id=current_setting('test.case_id')::uuid
    and n.notification_type='assignment_case_decision'
    and n.recipient_id in (current_setting('test.unverified')::uuid,current_setting('test.poster')::uuid))
  and exists(select 1 from app_private.assignment_case_decision_publications p
    join app_private.marketplace_outbox o on o.event_id=p.marketplace_event_id
    where p.case_id=current_setting('test.case_id')::uuid
      and (o.payload->'decision'->>'decision_version')::integer=p.decision_version
      and p.worker_notification_id<>p.poster_notification_id),
  'both parties receive the same approved decision version in durable in-app notices');
select is(public.server_get_assignment_case_for_actor(
  current_setting('test.unverified')::uuid,current_setting('test.case_id')::uuid)
    ->'appeal'->'decision'->>'decision_version','1',
  'the worker sees the exact initial approved decision version');
select is(public.server_get_assignment_case_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.case_id')::uuid)
    ->'appeal'->'decision'->>'decision_version','1',
  'the poster sees the same initial approved decision version');
select is(app_private.case_appeal_finalization_block_reason(current_setting('test.case_id')::uuid,
  (select appeal_deadline_at-interval '1 microsecond' from app_private.assignment_case_decision_publications
    where case_id=current_setting('test.case_id')::uuid)),
  'appeal_window_open','finalization stays blocked immediately before the stored deadline');
select set_config('test.step6_deadline',(select appeal_deadline_at::text
  from app_private.assignment_case_decision_publications
  where case_id=current_setting('test.case_id')::uuid),true);
select throws_ok($sql$
  select app_private.record_case_appeal_receipt_at_for_actor(
    current_setting('test.poster')::uuid,current_setting('test.case_id')::uuid,
    'I am appealing this decision because the reviewed facts do not match the agreed work.',
    'aal1','14000000-0000-4000-8000-000000000171',
    current_setting('test.step6_deadline')::timestamptz)
$sql$,'P0001','appeal_window_closed','an appeal received at the exact deadline is late');
select throws_ok($sql$
  select app_private.record_case_appeal_receipt_at_for_actor(
    current_setting('test.poster')::uuid,current_setting('test.case_id')::uuid,
    'I am appealing this decision because the reviewed facts do not match the agreed work.',
    'aal1','14000000-0000-4000-8000-000000000172',
    current_setting('test.step6_deadline')::timestamptz+interval '1 microsecond')
$sql$,'P0001','appeal_window_closed','an appeal received after the exact deadline is late');
select set_config('test.step6_poster_appeal',app_private.record_case_appeal_receipt_at_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.case_id')::uuid,
  'I am appealing this decision because the reviewed facts do not match the agreed work.',
  'aal1','14000000-0000-4000-8000-000000000173',
  (select durable_notified_at+interval '71 hours 59 minutes'
    from app_private.assignment_case_decision_publications
    where case_id=current_setting('test.case_id')::uuid))::text,true);
select set_config('test.step6_poster_applied',app_private.process_case_appeal_receipt_for_actor(
  current_setting('test.poster')::uuid,
  (current_setting('test.step6_poster_appeal')::jsonb->>'appeal_id')::uuid,'aal1')::text,true);
select is(current_setting('test.step6_poster_applied')::jsonb->>'applied','true',
  'a durable timely receipt applies under the case lock');
select is(app_private.case_appeal_finalization_block_reason(current_setting('test.case_id')::uuid,
  current_setting('test.step6_deadline')::timestamptz),
  'timely_appeal_unresolved','one timely appeal blocks finalization at and after the deadline');
select is((app_private.record_case_appeal_receipt_at_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.case_id')::uuid,
  'I am appealing this decision because the reviewed facts do not match the agreed work.',
  'aal1','14000000-0000-4000-8000-000000000173',
  current_setting('test.step6_deadline')::timestamptz)->>'appeal_id'),
  current_setting('test.step6_poster_appeal')::jsonb->>'appeal_id',
  'a retry of the same timely receipt returns its original record');
select throws_ok($sql$
  select app_private.record_case_appeal_receipt_at_for_actor(
    current_setting('test.poster')::uuid,current_setting('test.case_id')::uuid,
    'I am appealing this decision because the reviewed facts do not match the agreed work.',
    'aal1','14000000-0000-4000-8000-000000000174',
    (select durable_notified_at+interval '71 hours 59 minutes 1 second'
      from app_private.assignment_case_decision_publications
      where case_id=current_setting('test.case_id')::uuid)
  )
$sql$,'23505',null,'a party cannot open a second appeal with a new key');
select set_config('test.step6_worker_appeal',app_private.record_case_appeal_receipt_at_for_actor(
  current_setting('test.unverified')::uuid,current_setting('test.case_id')::uuid,
  'I am appealing because the decision does not reflect the work I submitted for review.',
  'aal1','14000000-0000-4000-8000-000000000175',
  (select durable_notified_at+interval '71 hours 58 minutes'
    from app_private.assignment_case_decision_publications
    where case_id=current_setting('test.case_id')::uuid))::text,true);
select set_config('test.step6_worker_applied',app_private.process_case_appeal_receipt_for_actor(
  current_setting('test.unverified')::uuid,
  (current_setting('test.step6_worker_appeal')::jsonb->>'appeal_id')::uuid,'aal1')::text,true);
select is((select count(*)::integer from app_private.assignment_case_appeal_receipts
  where case_id=current_setting('test.case_id')::uuid),2,
  'one timely appeal from each party is preserved independently');
select ok((public.server_get_assignment_case_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.case_id')::uuid)->'appeal'->>'other_party_appeal_received')='true'
  and public.server_get_assignment_case_for_actor(
    current_setting('test.unverified')::uuid,current_setting('test.case_id')::uuid)->'appeal'->>'other_party_appeal_received'='true',
  'each party sees that the other appealed without seeing their private statement');
select ok((select status='dispute_held' from app_private.principal_allocations
    where allocation_id=(select allocation_id from app_private.assignment_cases
      where case_id=current_setting('test.case_id')::uuid))
  and (select count(*)::text from app_private.ledger_journal_transactions)=current_setting('test.step5_journal_count'),
  'appeal receipt and review do not release the hold or move money');
select ok((select count(*)::integer from app_private.assignment_case_appeal_receipt_applications
  where case_id=current_setting('test.case_id')::uuid)=2,
  'each durable receipt is applied exactly once');

-- Phase 4 Step 7: only a currently authorized human can finalize the exact
-- approved version after the original appeal window and every timely appeal.
select ok(has_function_privilege('service_role',
      'public.server_finalize_case_for_actor(uuid,uuid,integer,integer,text,uuid)','EXECUTE')
    and not has_function_privilege('authenticated',
      'public.server_finalize_case_for_actor(uuid,uuid,integer,integer,text,uuid)','EXECUTE')
    and has_function_privilege('postgres',
      'app_private.finalize_case_for_actor_at(uuid,uuid,integer,integer,text,uuid,timestamptz)','EXECUTE')
    and not has_function_privilege('service_role',
      'app_private.finalize_case_for_actor_at(uuid,uuid,integer,integer,text,uuid,timestamptz)','EXECUTE'),
  'only the authenticated server gateway can finalize, while the historical clock helper is postgres-only');
select throws_ok(format($sql$
  select public.server_finalize_case_for_actor(%L::uuid,%L::uuid,1,
    (select version from app_private.assignment_cases where case_id=%L::uuid),
    'aal2','14000000-0000-4000-8000-000000000180')
$sql$,current_setting('test.case_staff'),current_setting('test.case_id'),current_setting('test.case_id')),
  '42501','case_access_denied','a reviewer without financial_initiate cannot finalize');
select ok((select status='dispute_held' from app_private.principal_allocations
  where allocation_id=(select allocation_id from app_private.assignment_cases
    where case_id=current_setting('test.case_id')::uuid)),
  'a denied finalization leaves the held allocation untouched');
insert into app_private.staff_grants(user_id,capability,granted_by,reason)
values(current_setting('test.case_staff')::uuid,'financial_initiate',current_setting('test.case_staff')::uuid,
  'Synthetic local grant to test explicit case finalization.');
select throws_ok(format($sql$
  select public.server_finalize_case_for_actor(%L::uuid,%L::uuid,1,
    (select version from app_private.assignment_cases where case_id=%L::uuid),
    'aal2','14000000-0000-4000-8000-000000000181')
$sql$,current_setting('test.case_staff'),current_setting('test.case_id'),current_setting('test.case_id')),
  'P0001','stale_state','unresolved party appeals prevent case execution');
select ok((select count(*)::integer from app_private.ledger_journal_transactions)=
    current_setting('test.step5_journal_count')::integer,
  'an unresolved appeal cannot create a journal entry');

-- A third synthetic human is used only to prove reviewer separation in this
-- local test; no fixture represents staffed live operations.
insert into auth.users(
  instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,created_at,updated_at
) values(
  '00000000-0000-0000-0000-000000000000','14000000-0000-4000-8000-000000000190',
  'authenticated','authenticated','phase4-step7-reviewer@identity.test','',pg_catalog.now(),
  jsonb_build_object('provider','email','providers',jsonb_build_array('email'),
    'staff_principal_kind','human'),'{}'::jsonb,pg_catalog.now(),pg_catalog.now()
);
insert into app_private.identity_accounts(
  user_id,account_type,age_confirmed_at,age_policy_version,account_status,
  verification_track,verification_status
) values('14000000-0000-4000-8000-000000000190','student',pg_catalog.now(),
  'phase4-step7-reviewer-v1','active','track_a_manual','approved');
insert into app_private.staff_grants(user_id,capability,granted_by,reason) values
  ('14000000-0000-4000-8000-000000000190','dispute_review',current_setting('test.case_staff')::uuid,
    'Synthetic local appeal reviewer grant for separation test.'),
  ('14000000-0000-4000-8000-000000000190','case_appeal_review',current_setting('test.case_staff')::uuid,
    'Synthetic local appeal review grant for separation test.'),
  ('14000000-0000-4000-8000-000000000190','financial_approve',current_setting('test.case_staff')::uuid,
    'Synthetic local version approval grant for finalization test.'),
  ('14000000-0000-4000-8000-000000000190','financial_initiate',current_setting('test.case_staff')::uuid,
    'Synthetic local finalization grant for exact outcome test.');
insert into auth.users(
  instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,created_at,updated_at
) values(
  '00000000-0000-0000-0000-000000000000','14000000-0000-4000-8000-000000000191',
  'authenticated','authenticated','phase4-step7-senior@identity.test','',pg_catalog.now(),
  jsonb_build_object('provider','email','providers',jsonb_build_array('email'),
    'staff_principal_kind','human'),'{}'::jsonb,pg_catalog.now(),pg_catalog.now()
);
insert into app_private.identity_accounts(
  user_id,account_type,age_confirmed_at,age_policy_version,account_status,
  verification_track,verification_status
) values('14000000-0000-4000-8000-000000000191','student',pg_catalog.now(),
  'phase4-step7-senior-v1','active','track_a_manual','approved');
insert into app_private.staff_grants(user_id,capability,granted_by,reason)
values('14000000-0000-4000-8000-000000000191','case_senior_signoff',
  current_setting('test.case_staff')::uuid,'Synthetic local independent senior sign-off grant.');
select public.server_assign_case_appeal_reviewer_for_actor(
  current_setting('test.case_staff')::uuid,current_setting('test.case_id')::uuid,
  '14000000-0000-4000-8000-000000000190','aal2','14000000-0000-4000-8000-000000000182');
-- Keep this pgTAP file's appeal evidence-request state untouched: every test
-- command runs at one transaction timestamp. The separate local Edge journey
-- verifies the successful two-channel contact and senior-signed closure flow.
select throws_ok($sql$
  select public.server_case_appeal_command_for_actor(
    '14000000-0000-4000-8000-000000000190',current_setting('test.case_id')::uuid,
    'request_case_appeal_evidence',jsonb_build_object(
      'appeal_id',current_setting('test.step6_poster_appeal')::jsonb->>'appeal_id',
      'target_party_role','worker','request_kind','evidence',
      'prompt','Please upload evidence at https://invalid.test/file.'),
    'aal2','14000000-0000-4000-8000-000000000208')
$sql$,'22023','invalid_case_command','appeal evidence requests reject public URLs');
select throws_ok(format($sql$
  select public.server_case_appeal_command_for_actor(
    %L::uuid,%L::uuid,'close_case_appeal_evidence_nonresponse',jsonb_build_object(
      'request_number',1,'substantive_reasoning',repeat('The independent senior reviewed the contact log and confirmed that it does not decide the financial outcome. ',2)),
    'aal2','14000000-0000-4000-8000-000000000209')
$sql$,current_setting('test.case_staff'),current_setting('test.case_id')),
  '42501','case_access_denied','the initial reviewer cannot close an appeal evidence request as senior signer');
select set_config('test.step7_proposal',public.server_propose_case_decision_for_actor(
  '14000000-0000-4000-8000-000000000190',current_setting('test.case_id')::uuid,
  (select version from app_private.assignment_cases where case_id=current_setting('test.case_id')::uuid),
  jsonb_build_object('outcome','split','award_gross_kobo','200000',
    'public_explanation','A fresh independent review supports the verified partial worker award.',
    'nonresponse_assessment_id',current_setting('test.step5_assessment')),
  'aal2','14000000-0000-4000-8000-000000000183')::text,true);
select is(current_setting('test.step7_proposal')::jsonb->>'decision_version','5',
  'a changed appeal outcome receives its own immutable decision version');
select is(current_setting('test.step7_proposal')::jsonb->>'worker_net_kobo','190000',
  'NGN 3,000 allocation and NGN 2,000 gross award produce NGN 1,900 worker net');
select is(current_setting('test.step7_proposal')::jsonb->>'commission_kobo','10000',
  'commission is NGN 100 on the worker award only');
select is(current_setting('test.step7_proposal')::jsonb->>'poster_refund_gross_kobo','100000',
  'the remaining NGN 1,000 becomes the exact poster refund obligation');
select public.server_signoff_case_decision_nonresponse_for_actor(
  '14000000-0000-4000-8000-000000000191',current_setting('test.case_id')::uuid,5,
  (select version from app_private.assignment_cases where case_id=current_setting('test.case_id')::uuid),
  repeat('An independent senior reviewed the two-channel contact record and this exact decision version. ',2),
  'aal2','14000000-0000-4000-8000-000000000184');
select set_config('test.step7_approved',public.server_approve_case_decision_for_actor(
  current_setting('test.student')::uuid,current_setting('test.case_id')::uuid,5,
  (select version from app_private.assignment_cases where case_id=current_setting('test.case_id')::uuid),
  'aal2','14000000-0000-4000-8000-000000000185')::text,true);
select is(current_setting('test.step7_approved')::jsonb->>'approved','true',
  'a second independent current human approves the appeal decision version');
select public.server_case_appeal_command_for_actor(
  '14000000-0000-4000-8000-000000000190',current_setting('test.case_id')::uuid,
  'review_case_appeal',jsonb_build_object(
    'appeal_id',current_setting('test.step6_poster_appeal')::jsonb->>'appeal_id',
    'action','changed','public_explanation','The appeal review adopts the newly approved split decision.',
    'decision_version',5),'aal2','14000000-0000-4000-8000-000000000206');
select public.server_case_appeal_command_for_actor(
  '14000000-0000-4000-8000-000000000190',current_setting('test.case_id')::uuid,
  'review_case_appeal',jsonb_build_object(
    'appeal_id',current_setting('test.step6_worker_appeal')::jsonb->>'appeal_id',
    'action','upheld','public_explanation','The appeal review upholds the approved decision after reviewing the submitted facts.'),
  'aal2','14000000-0000-4000-8000-000000000207');
select is((select count(*)::integer from app_private.assignment_case_appeal_review_versions
  where case_id=current_setting('test.case_id')::uuid and action in ('upheld','changed')),2,
  'both parties’ timely appeals receive immutable review outcomes');
select is((select status from app_private.principal_allocations
  where allocation_id=(select allocation_id from app_private.assignment_cases
    where case_id=current_setting('test.case_id')::uuid)),'dispute_held',
  'the changed outcome remains held after its approvals');
select throws_ok(format($sql$
  select app_private.finalize_case_for_actor_at('14000000-0000-4000-8000-000000000190',%L::uuid,5,
    (select version from app_private.assignment_cases where case_id=%L::uuid),
    'aal2','14000000-0000-4000-8000-000000000186',pg_catalog.clock_timestamp())
$sql$,current_setting('test.case_id'),current_setting('test.case_id')),
  'P0001','appeal_window_open','a fully approved outcome is still blocked before the stored deadline');
select throws_ok(format($sql$
  select app_private.finalize_case_for_actor_at('14000000-0000-4000-8000-000000000190',%L::uuid,1,
    (select version from app_private.assignment_cases where case_id=%L::uuid),
    'aal2','14000000-0000-4000-8000-000000000187',
    (select appeal_deadline_at from app_private.assignment_case_decision_publications where case_id=%L::uuid))
$sql$,current_setting('test.case_id'),current_setting('test.case_id'),current_setting('test.case_id')),
  'P0001','stale_decision_version','a finalizer cannot execute an older decision version');
update app_private.staff_grants set revoked_at=pg_catalog.now(),
  revoked_by=current_setting('test.case_staff')::uuid
where user_id='14000000-0000-4000-8000-000000000190'
  and capability='financial_initiate' and revoked_at is null;
select throws_ok(format($sql$
  select app_private.finalize_case_for_actor_at('14000000-0000-4000-8000-000000000190',%L::uuid,5,
    (select version from app_private.assignment_cases where case_id=%L::uuid),
    'aal2','14000000-0000-4000-8000-000000000188',
    (select appeal_deadline_at from app_private.assignment_case_decision_publications where case_id=%L::uuid))
$sql$,current_setting('test.case_id'),current_setting('test.case_id'),current_setting('test.case_id')),
  '42501','case_access_denied','a revoked finalizer grant blocks execution at the database boundary');
insert into app_private.staff_grants(user_id,capability,granted_by,reason)
values('14000000-0000-4000-8000-000000000190','financial_initiate',
  current_setting('test.case_staff')::uuid,'Synthetic local finalizer regrant for successful test.');
select set_config('test.step7_finalized',app_private.finalize_case_for_actor_at(
  '14000000-0000-4000-8000-000000000190',current_setting('test.case_id')::uuid,5,
  (select version from app_private.assignment_cases where case_id=current_setting('test.case_id')::uuid),
  'aal2','14000000-0000-4000-8000-000000000189',
  (select appeal_deadline_at from app_private.assignment_case_decision_publications
    where case_id=current_setting('test.case_id')::uuid))::text,true);
select is(current_setting('test.step7_finalized')::jsonb->>'status','closed',
  'the authorized finalizer closes the case after the exact deadline');
select is(current_setting('test.step7_finalized')::jsonb->>'finalization_status','executed',
  'decision execution is recorded separately from the case decision and closure');
select is(current_setting('test.step7_finalized')::jsonb->>'refund_status','authorized',
  'the refund remains an authorized payable, not a settled refund');
select is((select status from app_private.principal_allocations
  where allocation_id=(select allocation_id from app_private.assignment_cases
    where case_id=current_setting('test.case_id')::uuid)),'worker_earnings_allocated',
  'the awarded assignment receives its exact worker earnings allocation');
select is((select work_state from app_private.assignments
  where assignment_id=(select assignment_id from app_private.assignment_cases
    where case_id=current_setting('test.case_id')::uuid)),'completed',
  'a worker award completes the historical assignment');
select is((select state from app_private.job_applications
  where application_id=(select application_id from app_private.assignments
    where assignment_id=(select assignment_id from app_private.assignment_cases
      where case_id=current_setting('test.case_id')::uuid))),'closed',
  'the completed assignment conversation becomes read-only');
select is((select -b.balance_kobo from app_private.ledger_account_balances b
  join app_private.ledger_accounts a using(account_id)
  where a.account_code='worker_earnings_available'
    and b.owner_id=current_setting('test.unverified')::uuid
    and b.allocation_id=(select allocation_id from app_private.assignment_cases
      where case_id=current_setting('test.case_id')::uuid)),190000::bigint,
  'exactly NGN 1,900 is credited as worker earnings');
select is((select sum(e.amount_kobo)::bigint from app_private.ledger_journal_entries e
  join app_private.ledger_journal_transactions j using(journal_id)
  join app_private.ledger_accounts a using(account_id)
  where j.effect_type='case_outcome_finalized' and a.account_code='platform_commission_revenue'
    and e.allocation_id=(select allocation_id from app_private.assignment_cases
      where case_id=current_setting('test.case_id')::uuid) and e.direction='credit'),10000::bigint,
  'the NGN 100 commission is charged only on the NGN 2,000 worker award');
select is((select amount_kobo::text from app_private.allocation_refund_payables
  where allocation_id=(select allocation_id from app_private.assignment_cases
    where case_id=current_setting('test.case_id')::uuid)),'100000',
  'the NGN 1,000 refund portion is recorded as a poster payable');
select is((select -b.balance_kobo from app_private.ledger_account_balances b
  join app_private.ledger_accounts a using(account_id)
  where a.account_code='poster_refund_payable'
    and b.owner_id=current_setting('test.poster')::uuid
    and b.allocation_id=(select allocation_id from app_private.assignment_cases
      where case_id=current_setting('test.case_id')::uuid)),100000::bigint,
  'the poster refund stays separate from spendable wallet funds');
select is((select count(*)::integer from app_private.provider_operations
  where allocation_id=(select allocation_id from app_private.assignment_cases
    where case_id=current_setting('test.case_id')::uuid) and operation_type='refund'),0,
  'case finalization does not dispatch an external refund operation');
select is((select count(*)::integer from app_private.provider_operations
  where allocation_id=(select allocation_id from app_private.assignment_cases
    where case_id=current_setting('test.case_id')::uuid) and operation_type='payout'),0,
  'case finalization does not request a worker bank payout');
select is((public.server_get_assignment_case_for_actor(
  current_setting('test.unverified')::uuid,current_setting('test.case_id')::uuid)
  ->'finalization'->>'refund_status'),'authorized',
  'participants see the pending authorization without seeing staff or journal identifiers');
select is(public.server_finalize_case_for_actor(
  '14000000-0000-4000-8000-000000000190',current_setting('test.case_id')::uuid,5,
  (select version-1 from app_private.assignment_cases where case_id=current_setting('test.case_id')::uuid),
  'aal2','14000000-0000-4000-8000-000000000189')->>'finalization_status','executed',
  'a duplicate finalization key replays the one saved execution after closure');
select throws_ok(format($sql$
  select public.server_finalize_case_for_actor('14000000-0000-4000-8000-000000000190',%L::uuid,5,
    (select version from app_private.assignment_cases where case_id=%L::uuid),
    'aal2','14000000-0000-4000-8000-000000000192')
$sql$,current_setting('test.case_id'),current_setting('test.case_id')),
  'P0001','stale_state','a new key cannot execute a conflicting second outcome');
select is((select count(*)::integer from app_private.assignment_case_finalizations
  where case_id=current_setting('test.case_id')::uuid),1,
  'one case has exactly one immutable final execution');

-- A second isolated case proves no action only restores the prior work state.
insert into auth.users(
  instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,created_at,updated_at
) values(
  '00000000-0000-0000-0000-000000000000','14000000-0000-4000-8000-000000000193',
  'authenticated','authenticated','phase4-step7-second-human@identity.test','',pg_catalog.now(),
  jsonb_build_object('provider','email','providers',jsonb_build_array('email'),
    'staff_principal_kind','human'),'{}'::jsonb,pg_catalog.now(),pg_catalog.now()
);
insert into app_private.identity_accounts(
  user_id,account_type,age_confirmed_at,age_policy_version,account_status,
  verification_track,verification_status
) values('14000000-0000-4000-8000-000000000193','student',pg_catalog.now(),
  'phase4-step7-second-human-v1','active','track_a_manual','approved');
update auth.users set raw_app_meta_data=coalesce(raw_app_meta_data,'{}'::jsonb)||
  jsonb_build_object('staff_principal_kind','human')
where id=current_setting('test.unverified')::uuid;
update app_private.identity_accounts set account_status='active'
where user_id=current_setting('test.unverified')::uuid;
insert into app_private.staff_grants(user_id,capability,granted_by,reason)
values(current_setting('test.unverified')::uuid,'financial_approve',current_setting('test.case_staff')::uuid,
  'Synthetic local independent second decision approver grant.');
select set_config('test.step7_noaction_draft',public.server_create_job_draft_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.terms')::jsonb,
  '14000000-0000-4000-8000-000000000194')::text,true);
select set_config('test.step7_noaction_job',current_setting('test.step7_noaction_draft')::jsonb->>'job_id',true);
select set_config('test.step7_noaction_funding',public.server_start_job_funding_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.step7_noaction_job')::uuid,1,
  '14000000-0000-4000-8000-000000000195')::text,true);
select set_config('test.step7_noaction_operation',current_setting('test.step7_noaction_funding')::jsonb->>'operation_id',true);
select set_config('test.step7_noaction_claim',app_private.claim_payment_operation_job(
  '14000000-0000-4000-8000-000000000196',30::smallint)::text,true);
select public.server_complete_job_funding_operation_for_runner(
  current_setting('test.step7_noaction_operation')::uuid,
  (current_setting('test.step7_noaction_claim')::jsonb->>'lease_token')::uuid,
  'succeeded','sim-'||(current_setting('test.step7_noaction_funding')::jsonb->>'provider_idempotency_key'),
  '300000','NGN','fake_nbd_local_merchant_v1',
  (current_setting('test.step7_noaction_funding')::jsonb->>'provider_idempotency_key')::uuid,
  '1500',null,false,pg_catalog.encode(extensions.digest('no-action case finalization fixture','sha256'),'hex'));
select set_config('test.step7_noaction_application',public.server_apply_to_job_for_actor(
  current_setting('test.student')::uuid,current_setting('test.step7_noaction_job')::uuid,
  null,'14000000-0000-4000-8000-000000000197')::text,true);
select set_config('test.step7_noaction_assignment',public.server_accept_application_for_actor(
  current_setting('test.poster')::uuid,
  (current_setting('test.step7_noaction_application')::jsonb->>'application_id')::uuid,
  '14000000-0000-4000-8000-000000000198')::text,true);
select set_config('test.step7_noaction_started',public.server_start_assignment_for_actor(
  current_setting('test.student')::uuid,
  (current_setting('test.step7_noaction_assignment')::jsonb->>'assignment_id')::uuid,
  '14000000-0000-4000-8000-000000000215')::text,true);
select set_config('test.step7_noaction_submitted',public.server_submit_assignment_for_actor(
  current_setting('test.student')::uuid,
  (current_setting('test.step7_noaction_assignment')::jsonb->>'assignment_id')::uuid,
  '14000000-0000-4000-8000-000000000216')::text,true);
select set_config('test.reminder_assignment',
  current_setting('test.step7_noaction_submitted')::jsonb->>'assignment_id',true);
select set_config('test.reminder_submitted_at',(
  select submitted_at::text from app_private.assignments
  where assignment_id=current_setting('test.reminder_assignment')::uuid
),true);
select is((select count(*)::integer from app_private.assignment_reminder_due
  where assignment_id=current_setting('test.reminder_assignment')::uuid),3,
  'committed submission creates durable 24, 48 and 72 hour due records');
select is((select count(distinct reminder_key)::integer from app_private.assignment_reminder_due
  where assignment_id=current_setting('test.reminder_assignment')::uuid),3,
  'each stage has a stable assignment/version/generation key');
select is((select count(*)::integer from app_private.assignment_reminder_due r
  where r.assignment_id=current_setting('test.reminder_assignment')::uuid
    and r.terms_version=1 and r.generation_event_id=(select event_id from app_private.marketplace_outbox
      where event_type='job.assignment_submitted'
        and payload->>'assignment_id'=current_setting('test.reminder_assignment'))
    and ((r.stage_hours in (24,48) and r.recipient_id=current_setting('test.poster')::uuid)
      or (r.stage_hours=72 and r.recipient_id=current_setting('test.student')::uuid))),3,
  '24/48 hour reminders target the poster and 72 hour guidance targets the worker');
select is(app_private.claim_assignment_reminder_for_runner_at(
  '14000000-0000-4000-8000-000000000217',60,
  current_setting('test.reminder_submitted_at')::timestamptz+interval '23 hours 59 minutes'
),null::jsonb,'a reminder cannot be claimed before its 24 hour due time');
select set_config('test.reminder_first_claim',app_private.claim_assignment_reminder_for_runner_at(
  '14000000-0000-4000-8000-000000000217',60,
  current_setting('test.reminder_submitted_at')::timestamptz+interval '24 hours'
)::text,true);
select is(current_setting('test.reminder_first_claim')::jsonb->>'stage_hours','24',
  'the first due stage is claimed at exactly 24 hours');
select is(app_private.claim_assignment_reminder_for_runner_at(
  '14000000-0000-4000-8000-000000000218',60,
  current_setting('test.reminder_submitted_at')::timestamptz+interval '24 hours'
),null::jsonb,'a second worker cannot claim the same active reminder lease');
select is(app_private.claim_assignment_reminder_for_runner_at(
  '14000000-0000-4000-8000-000000000218',60,
  current_setting('test.reminder_submitted_at')::timestamptz+interval '24 hours 61 seconds'
),null::jsonb,'a restarted worker waits for the expired lease retry backoff');
select set_config('test.reminder_reclaimed',app_private.claim_assignment_reminder_for_runner_at(
  '14000000-0000-4000-8000-000000000219',60,
  current_setting('test.reminder_submitted_at')::timestamptz+interval '24 hours 2 minutes'
)::text,true);
select is(current_setting('test.reminder_reclaimed')::jsonb->>'stage_hours','24',
  'the same reminder is reclaimed after a worker restart');
select set_config('test.reminder_failed',app_private.fail_assignment_reminder_for_runner_at(
  (current_setting('test.reminder_reclaimed')::jsonb->>'reminder_id')::uuid,
  (current_setting('test.reminder_reclaimed')::jsonb->>'lease_token')::uuid,
  'runner_failure',current_setting('test.reminder_submitted_at')::timestamptz+interval '24 hours 2 minutes'
)::text,true);
select is(current_setting('test.reminder_failed')::jsonb->>'status','retry_wait',
  'a transient reminder worker failure enters bounded retry wait');
select is(app_private.claim_assignment_reminder_for_runner_at(
  '14000000-0000-4000-8000-000000000219',60,
  current_setting('test.reminder_submitted_at')::timestamptz+interval '24 hours 2 minutes 29 seconds'
),null::jsonb,'a reminder retry respects its server-side backoff');
select set_config('test.reminder_retry_claim',app_private.claim_assignment_reminder_for_runner_at(
  '14000000-0000-4000-8000-000000000220',60,
  current_setting('test.reminder_submitted_at')::timestamptz+interval '24 hours 4 minutes'
)::text,true);
select is(current_setting('test.reminder_retry_claim')::jsonb->>'stage_hours','24',
  'the pending 24 hour reminder can be reclaimed after backoff');
select set_config('test.reminder_24_dispatch',app_private.dispatch_assignment_reminder_for_runner_at(
  (current_setting('test.reminder_retry_claim')::jsonb->>'reminder_id')::uuid,
  (current_setting('test.reminder_retry_claim')::jsonb->>'lease_token')::uuid,
  current_setting('test.reminder_submitted_at')::timestamptz+interval '24 hours 4 minutes'
)::text,true);
select is(current_setting('test.reminder_24_dispatch')::jsonb->>'status','dispatched',
  'the poster receives the 24 hour in-app notice only after its event commits');
select is((select count(*)::integer from app_private.in_app_notifications
  where notification_type='assignment_reminder_24h'
    and recipient_id=current_setting('test.poster')::uuid),1,
  'one reminder stage creates one poster notice');
select is((select count(*)::integer from app_private.notification_email_deliveries d
  join app_private.in_app_notifications n using(notification_id)
  where n.notification_type='assignment_reminder_24h'
    and n.recipient_id=current_setting('test.poster')::uuid),1,
  'the reminder creates one supplementary email intent without sending email');
select throws_ok(format($sql$select app_private.dispatch_assignment_reminder_for_runner_at(%L::uuid,%L::uuid,%L::timestamptz)$sql$,
  current_setting('test.reminder_retry_claim')::jsonb->>'reminder_id',
  current_setting('test.reminder_retry_claim')::jsonb->>'lease_token',
  (current_setting('test.reminder_submitted_at')::timestamptz+interval '24 hours 4 minutes')::text),
  '55000','reminder_lease_lost','a lost dispatch acknowledgement cannot create a duplicate notice');
select is((select count(*)::integer from app_private.in_app_notifications
  where notification_type='assignment_reminder_24h'
    and recipient_id=current_setting('test.poster')::uuid),1,
  'a repeated dispatch cannot duplicate a saved reminder');
select set_config('test.reminder_48_claim',app_private.claim_assignment_reminder_for_runner_at(
  '14000000-0000-4000-8000-000000000220',60,
  current_setting('test.reminder_submitted_at')::timestamptz+interval '48 hours'
)::text,true);
select is(current_setting('test.reminder_48_claim')::jsonb->>'stage_hours','48',
  'the second due stage is claimable after 48 hours');
select set_config('test.reminder_48_dispatch',app_private.dispatch_assignment_reminder_for_runner_at(
  (current_setting('test.reminder_48_claim')::jsonb->>'reminder_id')::uuid,
  (current_setting('test.reminder_48_claim')::jsonb->>'lease_token')::uuid,
  current_setting('test.reminder_submitted_at')::timestamptz+interval '48 hours'
)::text,true);
select is(current_setting('test.reminder_48_dispatch')::jsonb->>'notification_type',
  'assignment_reminder_48h','the 48 hour notice remains a poster action reminder');
select set_config('test.reminder_72_claim',app_private.claim_assignment_reminder_for_runner_at(
  '14000000-0000-4000-8000-000000000221',60,
  current_setting('test.reminder_submitted_at')::timestamptz+interval '72 hours'
 )::text,true);
select is(current_setting('test.reminder_72_claim')::jsonb->>'stage_hours','72',
  'the 72 hour worker guidance can be claimed at its due boundary');
select set_config('test.step7_noaction_hold',public.server_open_assignment_hold_for_actor(
  current_setting('test.poster')::uuid,
  (current_setting('test.step7_noaction_assignment')::jsonb->>'assignment_id')::uuid,
  'other','Please review the agreed task details.','Please check the approved terms.',null,
  '14000000-0000-4000-8000-000000000199')::text,true);
select throws_ok(format($sql$select app_private.dispatch_assignment_reminder_for_runner_at(%L::uuid,%L::uuid,%L::timestamptz)$sql$,
  current_setting('test.reminder_72_claim')::jsonb->>'reminder_id',
  current_setting('test.reminder_72_claim')::jsonb->>'lease_token',
  (current_setting('test.reminder_submitted_at')::timestamptz+interval '72 hours')::text),
  '55000','reminder_lease_lost','opening a dispute suppresses an already-claimed reminder before dispatch');
select is((select status from app_private.assignment_reminder_due
  where reminder_id=(current_setting('test.reminder_72_claim')::jsonb->>'reminder_id')::uuid),
  'suppressed','the disputed assignment cancels its pending reminder work');
select set_config('test.step7_noaction_case',current_setting('test.step7_noaction_hold')::jsonb->'hold'->>'case_id',true);
select public.server_assign_case_reviewer_for_actor(
  '14000000-0000-4000-8000-000000000190',current_setting('test.step7_noaction_case')::uuid,
  '14000000-0000-4000-8000-000000000190','aal2','14000000-0000-4000-8000-000000000200');
select public.server_case_investigation_command_for_actor(
  '14000000-0000-4000-8000-000000000190',current_setting('test.step7_noaction_case')::uuid,
  'record_case_fact',jsonb_build_object('fact_code','terms_review','finding','supported',
    'staff_reasoning','The accepted terms and case report were compared for the no-action review.'),
  'aal2','14000000-0000-4000-8000-000000000201');
select set_config('test.step7_noaction_proposal',public.server_propose_case_decision_for_actor(
  '14000000-0000-4000-8000-000000000190',current_setting('test.step7_noaction_case')::uuid,
  (select version from app_private.assignment_cases where case_id=current_setting('test.step7_noaction_case')::uuid),
  jsonb_build_object('outcome','no_action','award_gross_kobo','0',
    'public_explanation','The review supports returning the assignment to its prior work stage.'),
  'aal2','14000000-0000-4000-8000-000000000202')::text,true);
select public.server_approve_case_decision_for_actor(
  current_setting('test.unverified')::uuid,current_setting('test.step7_noaction_case')::uuid,1,
  (select version from app_private.assignment_cases where case_id=current_setting('test.step7_noaction_case')::uuid),
  'aal2','14000000-0000-4000-8000-000000000203');
select set_config('test.step7_noaction_finalized',app_private.finalize_case_for_actor_at(
  '14000000-0000-4000-8000-000000000190',current_setting('test.step7_noaction_case')::uuid,1,
  (select version from app_private.assignment_cases where case_id=current_setting('test.step7_noaction_case')::uuid),
  'aal2','14000000-0000-4000-8000-000000000204',
  (select appeal_deadline_at from app_private.assignment_case_decision_publications
    where case_id=current_setting('test.step7_noaction_case')::uuid))::text,true);
select is(current_setting('test.step7_noaction_finalized')::jsonb->>'outcome','no_action',
  'no action is a separately recorded final decision');
select is((select status from app_private.principal_allocations
  where allocation_id=(select allocation_id from app_private.assignment_cases
    where case_id=current_setting('test.step7_noaction_case')::uuid)),'assigned',
  'no action restores the allocation from held back to assigned');
select is((select work_state from app_private.assignments
  where assignment_id=(select assignment_id from app_private.assignment_cases
    where case_id=current_setting('test.step7_noaction_case')::uuid)),'submitted',
  'no action restores exactly the prior assignment work stage');
select is((select count(*)::integer from app_private.assignment_case_award_authorizations
  where case_id=current_setting('test.step7_noaction_case')::uuid),0,
  'no action creates no worker award authorization');
select is((select count(*)::integer from app_private.allocation_refund_payables
  where allocation_id=(select allocation_id from app_private.assignment_cases
    where case_id=current_setting('test.step7_noaction_case')::uuid)),0,
  'no action creates no poster refund payable');
select is((select count(*)::integer from app_private.ledger_journal_transactions j
  where j.effect_type='case_hold_restored' and j.reference_id=(select finalization_id
    from app_private.assignment_case_finalizations
    where case_id=current_setting('test.step7_noaction_case')::uuid)),1,
  'no action records only the balanced internal hold classification restoration');
select set_config('test.reminder_finalization_at',(
  select executed_at::text from app_private.assignment_case_finalizations
  where case_id=current_setting('test.step7_noaction_case')::uuid
),true);
select is((select count(*)::integer from app_private.assignment_reminder_due
  where assignment_id=current_setting('test.reminder_assignment')::uuid
    and generation_event_id=(select event_id from app_private.marketplace_outbox
      where event_type='job.assignment_case_finalized'
        and payload->>'case_id'=current_setting('test.step7_noaction_case')
        and payload->>'outcome'='no_action')),3,
  'no-action finalization restores submitted work with a fresh reminder generation');
select is((select count(*)::integer from app_private.assignment_reminder_due r
  where r.assignment_id=current_setting('test.reminder_assignment')::uuid
    and r.generation_event_id=(select event_id from app_private.marketplace_outbox
      where event_type='job.assignment_case_finalized'
        and payload->>'case_id'=current_setting('test.step7_noaction_case')
        and payload->>'outcome'='no_action')
    and r.due_at=current_setting('test.reminder_finalization_at')::timestamptz+
      pg_catalog.make_interval(hours=>r.stage_hours)),3,
  'the new 24/48/72 hour sequence starts from the finalization server time');
select set_config('test.reminder_financial_state_before',(
  select pg_catalog.jsonb_build_object(
    'journals',(select count(*) from app_private.ledger_journal_transactions),
    'allocation',(select status from app_private.principal_allocations
      where assignment_id=current_setting('test.reminder_assignment')::uuid),
    'case',(select lifecycle_status from app_private.assignment_cases
      where case_id=current_setting('test.step7_noaction_case')::uuid),
    'balances',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_array(
      a.account_code,b.owner_id,b.balance_kobo::text) order by a.account_code,b.owner_id)
      from app_private.ledger_account_balances b join app_private.ledger_accounts a using(account_id)
      where b.allocation_id=(select allocation_id from app_private.assignments
        where assignment_id=current_setting('test.reminder_assignment')::uuid)),'[]'::jsonb)
  )::text
),true);
select set_config('test.reminder_catchup_claim',app_private.claim_assignment_reminder_for_runner_at(
  '14000000-0000-4000-8000-000000000222',60,
  current_setting('test.reminder_finalization_at')::timestamptz+interval '80 hours'
)::text,true);
select is(current_setting('test.reminder_catchup_claim')::jsonb->>'stage_hours','72',
  'after downtime only the latest due stage is claimed');
select is((select count(*)::integer from app_private.assignment_reminder_due r
  where r.assignment_id=current_setting('test.reminder_assignment')::uuid
    and r.generation_event_id=(select event_id from app_private.marketplace_outbox
      where event_type='job.assignment_case_finalized'
        and payload->>'case_id'=current_setting('test.step7_noaction_case')
        and payload->>'outcome'='no_action')
    and r.stage_hours in (24,48) and r.status='coalesced'),2,
  'downtime catch-up coalesces older due stages instead of sending a burst');
select set_config('test.reminder_catchup_dispatch',app_private.dispatch_assignment_reminder_for_runner_at(
  (current_setting('test.reminder_catchup_claim')::jsonb->>'reminder_id')::uuid,
  (current_setting('test.reminder_catchup_claim')::jsonb->>'lease_token')::uuid,
  current_setting('test.reminder_finalization_at')::timestamptz+interval '80 hours'
)::text,true);
select is(current_setting('test.reminder_catchup_dispatch')::jsonb->>'notification_type',
  'assignment_dispute_guidance_72h','catch-up sends dispute guidance to the worker once');
select is((select count(*)::integer from app_private.in_app_notifications
  where notification_type='assignment_dispute_guidance_72h'
    and recipient_id=current_setting('test.student')::uuid),1,
  'the worker receives one dispute-route guidance notice');
select is((select pg_catalog.jsonb_build_object(
    'journals',(select count(*) from app_private.ledger_journal_transactions),
    'allocation',(select status from app_private.principal_allocations
      where assignment_id=current_setting('test.reminder_assignment')::uuid),
    'case',(select lifecycle_status from app_private.assignment_cases
      where case_id=current_setting('test.step7_noaction_case')::uuid),
    'balances',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_array(
      a.account_code,b.owner_id,b.balance_kobo::text) order by a.account_code,b.owner_id)
      from app_private.ledger_account_balances b join app_private.ledger_accounts a using(account_id)
      where b.allocation_id=(select allocation_id from app_private.assignments
        where assignment_id=current_setting('test.reminder_assignment')::uuid)),'[]'::jsonb)
  )::text),current_setting('test.reminder_financial_state_before'),
  'reminder dispatch leaves journals, allocation, case and all allocation balances unchanged');

-- A separate held assignment covers the full-refund cancellation branch.
select set_config('test.step7_refund_draft',public.server_create_job_draft_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.terms')::jsonb,
  '14000000-0000-4000-8000-000000000208')::text,true);
select set_config('test.step7_refund_job',current_setting('test.step7_refund_draft')::jsonb->>'job_id',true);
select set_config('test.step7_refund_funding',public.server_start_job_funding_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.step7_refund_job')::uuid,1,
  '14000000-0000-4000-8000-000000000209')::text,true);
select set_config('test.step7_refund_operation',current_setting('test.step7_refund_funding')::jsonb->>'operation_id',true);
select set_config('test.step7_refund_claim',app_private.claim_payment_operation_job(
  '14000000-0000-4000-8000-000000000210',30::smallint)::text,true);
select public.server_complete_job_funding_operation_for_runner(
  current_setting('test.step7_refund_operation')::uuid,
  (current_setting('test.step7_refund_claim')::jsonb->>'lease_token')::uuid,
  'succeeded','sim-'||(current_setting('test.step7_refund_funding')::jsonb->>'provider_idempotency_key'),
  '300000','NGN','fake_nbd_local_merchant_v1',
  (current_setting('test.step7_refund_funding')::jsonb->>'provider_idempotency_key')::uuid,
  '1500',null,false,pg_catalog.encode(extensions.digest('full refund finalization fixture','sha256'),'hex'));
select set_config('test.step7_refund_application',public.server_apply_to_job_for_actor(
  current_setting('test.student')::uuid,current_setting('test.step7_refund_job')::uuid,
  null,'14000000-0000-4000-8000-000000000211')::text,true);
select set_config('test.step7_refund_assignment',public.server_accept_application_for_actor(
  current_setting('test.poster')::uuid,
  (current_setting('test.step7_refund_application')::jsonb->>'application_id')::uuid,
  '14000000-0000-4000-8000-000000000212')::text,true);
select public.server_start_assignment_for_actor(
  current_setting('test.student')::uuid,
  (current_setting('test.step7_refund_assignment')::jsonb->>'assignment_id')::uuid,
  '14000000-0000-4000-8000-000000000223');
select public.server_submit_assignment_for_actor(
  current_setting('test.student')::uuid,
  (current_setting('test.step7_refund_assignment')::jsonb->>'assignment_id')::uuid,
  '14000000-0000-4000-8000-000000000224');
select set_config('test.step7_refund_hold',public.server_open_assignment_hold_for_actor(
  current_setting('test.poster')::uuid,
  (current_setting('test.step7_refund_assignment')::jsonb->>'assignment_id')::uuid,
  'other','The agreed details need a review.','Please review the accepted terms.',null,
  '14000000-0000-4000-8000-000000000213')::text,true);
select set_config('test.step7_refund_case',current_setting('test.step7_refund_hold')::jsonb->'hold'->>'case_id',true);
select public.server_assign_case_reviewer_for_actor(
  '14000000-0000-4000-8000-000000000190',current_setting('test.step7_refund_case')::uuid,
  '14000000-0000-4000-8000-000000000190','aal2','14000000-0000-4000-8000-000000000214');
select public.server_case_investigation_command_for_actor(
  '14000000-0000-4000-8000-000000000190',current_setting('test.step7_refund_case')::uuid,
  'record_case_fact',jsonb_build_object('fact_code','terms_review','finding','supported',
    'staff_reasoning','The accepted terms and participant report support the full-refund review.'),
  'aal2','14000000-0000-4000-8000-000000000215');
select set_config('test.step7_refund_proposal',public.server_propose_case_decision_for_actor(
  '14000000-0000-4000-8000-000000000190',current_setting('test.step7_refund_case')::uuid,
  (select version from app_private.assignment_cases where case_id=current_setting('test.step7_refund_case')::uuid),
  jsonb_build_object('outcome','full_poster_refund','award_gross_kobo','0',
    'public_explanation','The reviewed evidence supports returning the full held principal.'),
  'aal2','14000000-0000-4000-8000-000000000216')::text,true);
select public.server_approve_case_decision_for_actor(
  current_setting('test.unverified')::uuid,current_setting('test.step7_refund_case')::uuid,1,
  (select version from app_private.assignment_cases where case_id=current_setting('test.step7_refund_case')::uuid),
  'aal2','14000000-0000-4000-8000-000000000217');
select set_config('test.step7_refund_finalized',app_private.finalize_case_for_actor_at(
  '14000000-0000-4000-8000-000000000190',current_setting('test.step7_refund_case')::uuid,1,
  (select version from app_private.assignment_cases where case_id=current_setting('test.step7_refund_case')::uuid),
  'aal2','14000000-0000-4000-8000-000000000218',
  (select appeal_deadline_at from app_private.assignment_case_decision_publications
    where case_id=current_setting('test.step7_refund_case')::uuid))::text,true);
select is(current_setting('test.step7_refund_finalized')::jsonb->>'outcome','full_poster_refund',
  'full refund is a distinct executed case outcome');
select is((select work_state from app_private.assignments
  where assignment_id=(select assignment_id from app_private.assignment_cases
    where case_id=current_setting('test.step7_refund_case')::uuid)),'cancelled',
  'full refund cancels the historical assignment');
select is((select count(*)::integer from app_private.assignment_reminder_due
  where assignment_id=(select assignment_id from app_private.assignment_cases
    where case_id=current_setting('test.step7_refund_case')::uuid)
    and status='suppressed'),3,
  'dispute and cancellation suppress the full reminder sequence');
select is((select count(*)::integer from app_private.assignment_reminder_due
  where assignment_id=(select assignment_id from app_private.assignment_cases
    where case_id=current_setting('test.step7_refund_case')::uuid)
    and notification_id is not null),0,
  'a cancelled assignment receives no reminder notice');
select is((select status from app_private.principal_allocations
  where allocation_id=(select allocation_id from app_private.assignment_cases
    where case_id=current_setting('test.step7_refund_case')::uuid)),'refund_payable',
  'full refund makes the held slot a refund payable');
select is((select assignment_id from app_private.principal_allocations
  where allocation_id=(select allocation_id from app_private.assignment_cases
    where case_id=current_setting('test.step7_refund_case')::uuid)),null::uuid,
  'full refund unbinds only this allocation for future work');
select is((select unbound_reason from app_private.allocation_assignment_bindings
  where assignment_id=(select assignment_id from app_private.assignment_cases
    where case_id=current_setting('test.step7_refund_case')::uuid)),'case_finalized_refund',
  'full refund preserves the assignment binding history with its reason');
select is((select state from app_private.job_applications
  where application_id=(select application_id from app_private.assignments
    where assignment_id=(select assignment_id from app_private.assignment_cases
      where case_id=current_setting('test.step7_refund_case')::uuid))),'closed',
  'full refund closes the historical application conversation');
select is((select amount_kobo::text from app_private.allocation_refund_payables
  where allocation_id=(select allocation_id from app_private.assignment_cases
    where case_id=current_setting('test.step7_refund_case')::uuid)),'300000',
  'full refund creates only the exact poster payable');
select is((public.server_get_assignment_case_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.step7_refund_case')::uuid)
  ->'finalization'->>'refund_status'),'authorized',
  'closed case distinguishes the authorized refund from settlement');
select is((select count(*)::integer from app_private.provider_operations
  where allocation_id=(select allocation_id from app_private.assignment_cases
    where case_id=current_setting('test.step7_refund_case')::uuid)
    and operation_type in ('refund','payout')),0,
  'full case refund creates no external refund or worker payout operation');

-- Phase 4 Step 8: only materialize existing refund authorities, retain the
-- charge/allocation mapping, and use the existing leased provider runner.
select is((select count(*)::integer from app_private.provider_operations
  where operation_type='refund'),0,
  'refund authorization alone creates no provider operation before the runner prepares it');
select ok(app_private.prepare_local_refund_operations()>=1,
  'the durable runner materializes operations only from existing refund payables');
select ok((select m.original_provider_reference='sim-'||f.provider_idempotency_key::text
    and m.amount_kobo=r.amount_kobo
    and m.allocation_id=r.allocation_id
    and m.source_collection_operation_id=f.operation_id
  from app_private.refund_operation_mappings m
  join app_private.allocation_refund_payables r using(refund_payable_id)
  join app_private.funding_attempts a on a.attempt_id=m.funding_attempt_id
  join app_private.provider_operations f on f.operation_id=a.operation_id
  where r.allocation_id=(select allocation_id from app_private.assignment_cases
    where case_id=current_setting('test.step7_refund_case')::uuid)),
  'the refund operation durably binds its exact payable, original charge, allocation and reference');
select ok(not has_function_privilege('anon',
    'public.server_complete_refund_operation_for_runner(uuid,uuid,text,text,text,text,uuid,text,text,text,text,boolean,text)','EXECUTE')
  and not has_function_privilege('authenticated',
    'public.server_complete_refund_operation_for_runner(uuid,uuid,text,text,text,text,uuid,text,text,text,text,boolean,text)','EXECUTE')
  and has_function_privilege('service_role',
    'public.server_complete_refund_operation_for_runner(uuid,uuid,text,text,text,text,uuid,text,text,text,text,boolean,text)','EXECUTE')
  and to_regclass('app_private.refund_operation_mappings') is not null
  and to_regclass('app_private.refund_operation_jobs') is null,
  'refund settlement uses the existing service runner and keeps its mapping private');
select is((select p.status from app_private.allocation_refund_progress p
  join app_private.assignment_cases c using(allocation_id)
  where c.case_id=current_setting('test.step7_refund_case')::uuid),'queued_for_liquidity',
  'an uncleared collection keeps its refund queued and payable');
select app_private.post_financial_journal('14000000-0000-4000-8000-000000000241',
  'platform_capital_contribution',null,null,pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object('account_code','platform_fee_reserve_cash','direction','debit','amount_kobo','1000'),
    pg_catalog.jsonb_build_object('account_code','platform_capital_contributed','direction','credit','amount_kobo','1000')));
select is(public.server_claim_payment_operation_for_runner(
  '14000000-0000-4000-8000-000000000219',30::smallint),null::jsonb,
  'even available platform fee reserve cannot send a refund against an uncleared source collection');

-- A three-slot collection proves the cap and independent allocation outcomes.
select set_config('test.step8_terms',
  (current_setting('test.terms')::jsonb||'{"slot_count":3}'::jsonb)::text,true);
select set_config('test.step8_draft',public.server_create_job_draft_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.step8_terms')::jsonb,
  '14000000-0000-4000-8000-000000000220')::text,true);
select set_config('test.step8_job',current_setting('test.step8_draft')::jsonb->>'job_id',true);
select set_config('test.step8_funding',public.server_start_job_funding_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.step8_job')::uuid,1,
  '14000000-0000-4000-8000-000000000221')::text,true);
select set_config('test.step8_collection',current_setting('test.step8_funding')::jsonb->>'operation_id',true);
select set_config('test.step8_collection_claim',app_private.claim_payment_operation_job(
  '14000000-0000-4000-8000-000000000222',30::smallint)::text,true);
select public.server_complete_job_funding_operation_for_runner(
  current_setting('test.step8_collection')::uuid,
  (current_setting('test.step8_collection_claim')::jsonb->>'lease_token')::uuid,
  'succeeded','sim-'||(current_setting('test.step8_funding')::jsonb->>'provider_idempotency_key'),
  '900000','NGN','fake_nbd_local_merchant_v1',
  (current_setting('test.step8_funding')::jsonb->>'provider_idempotency_key')::uuid,
  '1500',null,false,pg_catalog.encode(extensions.digest('step8 refund collection fixture','sha256'),'hex'));
select public.server_complete_job_funding_settlement_for_runner(
  current_setting('test.step8_collection')::uuid,'available');
select set_config('test.step8_slots',(
  select pg_catalog.jsonb_agg(allocation_id::text order by slot_number)::text
  from app_private.principal_allocations where job_id=current_setting('test.step8_job')::uuid
),true);
select set_config('test.step8_cancel',public.server_cancel_unassigned_slots_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.step8_job')::uuid,
  array[(current_setting('test.step8_slots')::jsonb->>0)::uuid,
        (current_setting('test.step8_slots')::jsonb->>1)::uuid,
        (current_setting('test.step8_slots')::jsonb->>2)::uuid],
  'This synthetic local slot is no longer needed.',
  '14000000-0000-4000-8000-000000000223')::text,true);
update app_private.local_refund_fee_policy set expected_fee_kobo=1000
where provider_adapter='local_simulator';
select ok(app_private.prepare_local_refund_operations()>=3,
  'each canceled slot receives its own durable refund operation');
select is((select count(*)::integer from app_private.refund_operation_mappings m
  join app_private.principal_allocations a using(allocation_id)
  where a.job_id=current_setting('test.step8_job')::uuid),3,
  'one operation mapping exists for each authorized slot refund');
select is((select sum(m.amount_kobo)::text from app_private.refund_operation_mappings m
  join app_private.principal_allocations a using(allocation_id)
  where a.job_id=current_setting('test.step8_job')::uuid),'900000',
  'cumulative slot refunds equal, and cannot exceed, the NGN 9,000 source collection');
select is((select count(distinct m.original_provider_reference)::integer
  from app_private.refund_operation_mappings m
  join app_private.principal_allocations a using(allocation_id)
  where a.job_id=current_setting('test.step8_job')::uuid),1,
  'all slot refunds retain the same original source charge reference');
select is(public.server_claim_payment_operation_for_runner(
  '14000000-0000-4000-8000-000000000224',30::smallint),null::jsonb,
  'refunds stay queued when cleared principal exists but platform fee cash is short');
select is((select count(*)::integer from app_private.allocation_refund_progress p
  join app_private.principal_allocations a using(allocation_id)
  where a.job_id=current_setting('test.step8_job')::uuid and p.status='queued_for_liquidity'),3,
  'fee shortage leaves every authorized slot refund queued');
select app_private.post_financial_journal('14000000-0000-4000-8000-000000000225',
  'platform_capital_contribution',null,null,pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object('account_code','platform_fee_reserve_cash','direction','debit','amount_kobo','3500'),
    pg_catalog.jsonb_build_object('account_code','platform_capital_contributed','direction','credit','amount_kobo','3500')));

-- The first slot settles, the second fails, and the third becomes unknown then settles
-- after a same-identity lookup retry. None of these statuses affect another slot.
select set_config('test.step8_claim1',public.server_claim_payment_operation_for_runner(
  '14000000-0000-4000-8000-000000000226',30::smallint)::text,true);
select set_config('test.step8_allocation1',(
  select allocation_id::text from app_private.refund_operation_mappings
  where operation_id=(current_setting('test.step8_claim1')::jsonb->>'operation_id')::uuid
),true);
select is(current_setting('test.step8_claim1')::jsonb->>'operation_type','refund',
  'the existing runner claims a refund operation after exact fee liquidity is reserved');
select set_config('test.step8_result1',public.server_complete_refund_operation_for_runner(
  (current_setting('test.step8_claim1')::jsonb->>'operation_id')::uuid,
  (current_setting('test.step8_claim1')::jsonb->>'lease_token')::uuid,
  'settled','sim-'||(current_setting('test.step8_claim1')::jsonb->>'provider_idempotency_key'),
  current_setting('test.step8_claim1')::jsonb->>'amount_kobo','NGN',
  (current_setting('test.step8_claim1')::jsonb->>'provider_idempotency_key')::uuid,
  current_setting('test.step8_claim1')::jsonb->>'source_provider_reference','1000','available',
  null,false,pg_catalog.encode(extensions.digest('step8 settled result','sha256'),'hex'))::text,true);
select is(current_setting('test.step8_result1')::jsonb->>'bank_receipt_confirmed','false',
  'provider settlement does not claim the poster received a bank credit');
select is(current_setting('test.step8_result1')::jsonb->>'fee_treatment','platform_expense',
  'the exact refund principal is preserved while the provider fee is charged to the platform');
select set_config('test.step8_claim2',public.server_claim_payment_operation_for_runner(
  '14000000-0000-4000-8000-000000000227',30::smallint)::text,true);
select set_config('test.step8_allocation2',(
  select allocation_id::text from app_private.refund_operation_mappings
  where operation_id=(current_setting('test.step8_claim2')::jsonb->>'operation_id')::uuid
),true);
select set_config('test.step8_result2',public.server_complete_refund_operation_for_runner(
  (current_setting('test.step8_claim2')::jsonb->>'operation_id')::uuid,
  (current_setting('test.step8_claim2')::jsonb->>'lease_token')::uuid,
  'failed','sim-'||(current_setting('test.step8_claim2')::jsonb->>'provider_idempotency_key'),
  current_setting('test.step8_claim2')::jsonb->>'amount_kobo','NGN',
  (current_setting('test.step8_claim2')::jsonb->>'provider_idempotency_key')::uuid,
  current_setting('test.step8_claim2')::jsonb->>'source_provider_reference','1000','pending',
  null,false,pg_catalog.encode(extensions.digest('step8 known failure','sha256'),'hex'))::text,true);
select is((select p.status from app_private.allocation_refund_progress p
  join app_private.refund_operation_mappings m on m.refund_payable_id=p.refund_payable_id
  join app_private.principal_allocations a on a.allocation_id=m.allocation_id
  where a.allocation_id=current_setting('test.step8_allocation2')::uuid),'failed',
  'a known failed provider attempt keeps only its own refund entitlement visible');
select is((public.server_get_my_wallet_for_actor(current_setting('test.poster')::uuid,null,null)
  ->'refund_payables') @> '[{"status":"failed","amount_kobo":"300000"}]'::jsonb,true,
  'poster wallet shows the failed amount as an unresolved refund status');
select set_config('test.step8_claim3',public.server_claim_payment_operation_for_runner(
  '14000000-0000-4000-8000-000000000228',30::smallint)::text,true);
select set_config('test.step8_allocation3',(
  select allocation_id::text from app_private.refund_operation_mappings
  where operation_id=(current_setting('test.step8_claim3')::jsonb->>'operation_id')::uuid
),true);
update app_private.payment_operation_jobs set lease_expires_at=pg_catalog.now()-interval '1 second'
where operation_id=(current_setting('test.step8_claim3')::jsonb->>'operation_id')::uuid;
select set_config('test.step8_reclaimed_lease',app_private.claim_payment_operation_job(
  '14000000-0000-4000-8000-000000000231',30::smallint)::text,true);
select is(current_setting('test.step8_reclaimed_lease')::jsonb->>'operation_id',
  current_setting('test.step8_claim3')::jsonb->>'operation_id',
  'an expired lease is reclaimed for the same durable refund operation');
select throws_ok(format($sql$
  select public.server_complete_refund_operation_for_runner(
    %L::uuid,%L::uuid,'unknown',null,null,null,null,null,'0','pending','unknown_result',true,%L)
$sql$,
  current_setting('test.step8_claim3')::jsonb->>'operation_id',
  current_setting('test.step8_claim3')::jsonb->>'lease_token',repeat('a',64)),
  '40001','payment_job_lease_lost','the expired lease cannot overwrite the reclaimed result');
select set_config('test.step8_result3',public.server_complete_refund_operation_for_runner(
  (current_setting('test.step8_reclaimed_lease')::jsonb->>'operation_id')::uuid,
  (current_setting('test.step8_reclaimed_lease')::jsonb->>'lease_token')::uuid,
  'unknown','sim-'||(current_setting('test.step8_reclaimed_lease')::jsonb->>'provider_idempotency_key'),
  current_setting('test.step8_reclaimed_lease')::jsonb->>'amount_kobo','NGN',
  (current_setting('test.step8_reclaimed_lease')::jsonb->>'provider_idempotency_key')::uuid,
  current_setting('test.step8_reclaimed_lease')::jsonb->>'source_provider_reference','1000','pending',
  'unknown_result',true,pg_catalog.encode(extensions.digest('step8 unknown result','sha256'),'hex'))::text,true);
select is((select p.status from app_private.allocation_refund_progress p
  join app_private.refund_operation_mappings m on m.refund_payable_id=p.refund_payable_id
  join app_private.principal_allocations a on a.allocation_id=m.allocation_id
  where a.allocation_id=current_setting('test.step8_allocation3')::uuid),'unknown',
  'an unknown external result remains visible and keeps its payable protected');
select is((select count(*)::integer from app_private.refund_operation_mappings m
  join app_private.principal_allocations a using(allocation_id)
  where a.job_id=current_setting('test.step8_job')::uuid),3,
  'retrying an unknown operation does not create a second refund identity');
update app_private.payment_operation_jobs set available_at=pg_catalog.now()
where operation_id=(current_setting('test.step8_claim3')::jsonb->>'operation_id')::uuid;
select set_config('test.step8_receipt',public.server_record_payment_simulator_receipt(
  'step8-refund-retry-event-0001',
  (current_setting('test.step8_claim3')::jsonb->>'provider_idempotency_key')::uuid,
  'sim-'||(current_setting('test.step8_claim3')::jsonb->>'provider_idempotency_key'),
  pg_catalog.encode(extensions.digest('step8 refund callback','sha256'),'hex'))::text,true);
select is(current_setting('test.step8_receipt')::jsonb->>'matched','true',
  'a callback queues reconciliation for an existing refund authorization');
select is(public.server_record_payment_simulator_receipt(
  'step8-refund-retry-event-0001',
  (current_setting('test.step8_claim3')::jsonb->>'provider_idempotency_key')::uuid,
  'sim-'||(current_setting('test.step8_claim3')::jsonb->>'provider_idempotency_key'),
  pg_catalog.encode(extensions.digest('step8 refund callback','sha256'),'hex'))->>'duplicate','true',
  'a repeated callback is idempotent');
select set_config('test.step8_retry_claim',public.server_claim_payment_operation_for_runner(
  '14000000-0000-4000-8000-000000000229',30::smallint)::text,true);
select is(current_setting('test.step8_retry_claim')::jsonb->>'operation_id',
  current_setting('test.step8_claim3')::jsonb->>'operation_id',
  'lease recovery and reconciliation reuse the original operation and effect identity');
select public.server_complete_refund_operation_for_runner(
  (current_setting('test.step8_retry_claim')::jsonb->>'operation_id')::uuid,
  (current_setting('test.step8_retry_claim')::jsonb->>'lease_token')::uuid,
  'settled','sim-'||(current_setting('test.step8_retry_claim')::jsonb->>'provider_idempotency_key'),
  current_setting('test.step8_retry_claim')::jsonb->>'amount_kobo','NGN',
  (current_setting('test.step8_retry_claim')::jsonb->>'provider_idempotency_key')::uuid,
  current_setting('test.step8_retry_claim')::jsonb->>'source_provider_reference','1000','available',
  null,false,pg_catalog.encode(extensions.digest('step8 retry settled result','sha256'),'hex'));
select is((select count(*)::integer from app_private.provider_refund_settlement_records
  where operation_id in (select operation_id from app_private.refund_operation_mappings m
    join app_private.principal_allocations a using(allocation_id)
    where a.job_id=current_setting('test.step8_job')::uuid)),2,
  'only the two independently settled slot refunds have settlement records');
select is((select sum(b.balance_kobo)::text from app_private.ledger_account_balances b
  join app_private.ledger_accounts a using(account_id)
  where a.account_code='provider_refund_fee_expense'),'3000',
  'settled and failed refund fees are platform expenses');
select is((select count(*)::integer from app_private.ledger_journal_transactions j
  where j.effect_key in (select settlement_effect_id from app_private.refund_operation_mappings m
    join app_private.principal_allocations a using(allocation_id)
    where a.job_id=current_setting('test.step8_job')::uuid)
    and j.effect_type='provider_refund_settled'),2,
  'each settled refund creates one balanced settlement journal effect');

-- A reversal opens a separate review incident and does not rewrite the journal.
select set_config('test.step8_settled_key',(
  select o.provider_idempotency_key::text from app_private.refund_operation_mappings m
  join app_private.provider_operations o using(operation_id)
  where m.operation_id=(current_setting('test.step8_claim1')::jsonb->>'operation_id')::uuid
),true);
select set_config('test.step8_settled_operation',(
  current_setting('test.step8_claim1')::jsonb->>'operation_id'
),true);
select set_config('test.step8_journals_before_reversal',(
  select count(*)::text from app_private.ledger_journal_transactions
),true);
select public.server_record_payment_simulator_receipt('step8-refund-reversal-event-0001',
  current_setting('test.step8_settled_key')::uuid,
  'sim-'||current_setting('test.step8_settled_key'),
  pg_catalog.encode(extensions.digest('step8 refund reversal callback','sha256'),'hex'));
select set_config('test.step8_reversal_claim',public.server_claim_payment_operation_for_runner(
  '14000000-0000-4000-8000-000000000230',30::smallint)::text,true);
select public.server_complete_refund_operation_for_runner(
  current_setting('test.step8_settled_operation')::uuid,
  (current_setting('test.step8_reversal_claim')::jsonb->>'lease_token')::uuid,
  'reversed','sim-'||current_setting('test.step8_settled_key'),
  '300000','NGN',current_setting('test.step8_settled_key')::uuid,
  (select original_provider_reference from app_private.refund_operation_mappings
    where operation_id=current_setting('test.step8_settled_operation')::uuid),
  '1000','available',null,false,
  pg_catalog.encode(extensions.digest('step8 verified refund reversal','sha256'),'hex'));
select is((select count(*)::integer from app_private.refund_reversal_incidents
  where operation_id=current_setting('test.step8_settled_operation')::uuid and status='open'),1,
  'a verified reversal creates one separately reviewable incident');
select is((select count(*)::text from app_private.ledger_journal_transactions),
  current_setting('test.step8_journals_before_reversal'),
  'reversal observation does not silently edit or post a compensating journal');
select public.server_record_payment_simulator_receipt('step8-refund-stale-event-0001',
  current_setting('test.step8_settled_key')::uuid,
  'sim-'||current_setting('test.step8_settled_key'),
  pg_catalog.encode(extensions.digest('step8 stale settlement callback','sha256'),'hex'));
select set_config('test.step8_stale_claim',public.server_claim_payment_operation_for_runner(
  '14000000-0000-4000-8000-000000000232',30::smallint)::text,true);
select set_config('test.step8_stale_result',public.server_complete_refund_operation_for_runner(
  current_setting('test.step8_settled_operation')::uuid,
  (current_setting('test.step8_stale_claim')::jsonb->>'lease_token')::uuid,
  'settled','sim-'||current_setting('test.step8_settled_key'),
  '300000','NGN',current_setting('test.step8_settled_key')::uuid,
  (select original_provider_reference from app_private.refund_operation_mappings
    where operation_id=current_setting('test.step8_settled_operation')::uuid),
  '1000','available',null,false,
  pg_catalog.encode(extensions.digest('step8 stale settlement result','sha256'),'hex'))::text,true);
select is(current_setting('test.step8_stale_result')::jsonb->>'conflicting_result','true',
  'a stale settlement observation after reversal becomes a reconciliation exception');
select is(current_setting('test.step8_stale_result')::jsonb->>'refund_status','reversed',
  'a conflicting stale result cannot overwrite the reversal state');
select is((select count(*)::text from app_private.ledger_journal_transactions),
  current_setting('test.step8_journals_before_reversal'),
  'an out-of-order result does not create another settlement or compensating journal');
insert into app_private.staff_grants(user_id,capability,granted_by,reason)
values(current_setting('test.case_staff')::uuid,'financial_inspect',
  current_setting('test.case_staff')::uuid,'Synthetic local reconciliation fixture for Step 8.')
on conflict do nothing;
select set_config('test.step8_reconciliation',app_private.reconcile_financial_state_for_actor(
  current_setting('test.case_staff')::uuid,'aal2','0','0')::text,true);
select ok((current_setting('test.step8_reconciliation')::jsonb->'findings')::text like '%refund_reversal_open%'
  and exists(select 1 from app_private.financial_reconciliation_findings
    where finding_code='refund_reversal_open'
      and reference_id=current_setting('test.step8_settled_operation')::uuid),
  'the authorized read-only reconciliation run surfaces the reversal incident without correcting money');

-- Phase 5 Step 6: reviews attach only to qualifying finalized work, publish
-- safe role-specific totals, and keep moderation/report records append-only.
select ok(to_regclass('app_private.assignment_reviews') is not null
  and to_regclass('app_private.assignment_review_reports') is not null
  and to_regclass('app_private.assignment_review_moderation_events') is not null
  and not has_table_privilege('anon','app_private.assignment_reviews','SELECT')
  and not has_table_privilege('authenticated','app_private.assignment_reviews','SELECT')
  and not has_table_privilege('service_role','app_private.assignment_reviews','SELECT')
  and not has_table_privilege('service_role','app_private.assignment_reviews','INSERT')
  and not has_table_privilege('service_role','app_private.assignment_reviews','UPDATE'),
  'review, report and moderation records are private and server-mediated');
select ok(has_function_privilege('service_role',
      'public.server_submit_assignment_review_for_actor(uuid,uuid,smallint,text,uuid)','EXECUTE')
    and has_function_privilege('service_role',
      'public.server_report_assignment_review_for_actor(uuid,uuid)','EXECUTE')
    and has_function_privilege('service_role',
      'public.server_list_profile_reviews_for_viewer(uuid,uuid,timestamp with time zone,uuid)','EXECUTE')
    and has_function_privilege('service_role',
      'public.server_hide_assignment_review_for_actor(uuid,uuid,text,text,uuid)','EXECUTE')
    and not has_function_privilege('authenticated',
      'public.server_submit_assignment_review_for_actor(uuid,uuid,smallint,text,uuid)','EXECUTE')
    and not has_function_privilege('service_role',
      'app_private.rebuild_profile_reputation_projections()','EXECUTE'),
  'only narrow server RPCs are public and projection rebuild is a database-owner operation');
select ok(app_private.assignment_review_is_eligible(
    (current_setting('test.accepted')::jsonb->>'assignment_id')::uuid)
  and not app_private.assignment_review_is_eligible(
    (current_setting('test.step7_noaction_assignment')::jsonb->>'assignment_id')::uuid)
  and not app_private.assignment_review_is_eligible(
    (current_setting('test.step7_refund_assignment')::jsonb->>'assignment_id')::uuid)
  and not app_private.assignment_review_is_eligible(
    (current_setting('test.cancel_assignment_replacement')::jsonb->>'assignment_id')::uuid),
  'ordinary completion qualifies while no-action, refund-only and cancellation do not');
select ok(app_private.assignment_review_is_eligible((select assignment_id
  from app_private.assignment_cases where case_id=current_setting('test.case_id')::uuid)),
  'the finally closed split worker award qualifies after all appeal outcomes are recorded');

insert into app_private.staff_grants(user_id,capability,granted_by,reason)
values(current_setting('test.case_staff')::uuid,'review_moderate',
  current_setting('test.case_staff')::uuid,'Synthetic human review-moderation test grant.'),
  (current_setting('test.student')::uuid,'review_moderate',
  current_setting('test.case_staff')::uuid,'Synthetic party-conflict review-moderation test grant.')
on conflict do nothing;

select set_config('test.review_worker',public.server_submit_assignment_review_for_actor(
  current_setting('test.poster')::uuid,
  (current_setting('test.accepted')::jsonb->>'assignment_id')::uuid,5,
  '  Reliable   and careful work.  ','15000000-0000-4000-8000-000000000001')::text,true);
select set_config('test.review_poster',public.server_submit_assignment_review_for_actor(
  current_setting('test.student')::uuid,
  (current_setting('test.accepted')::jsonb->>'assignment_id')::uuid,4,
  'Clear and respectful communication.','15000000-0000-4000-8000-000000000002')::text,true);
select is(current_setting('test.review_worker')::jsonb->'review'->>'target_role','worker',
  'poster review target and role are derived from the assignment');
select is(current_setting('test.review_worker')::jsonb->'review'->>'review_text',
  'Reliable and careful work.','review text whitespace is normalized at the database boundary');
select is(public.server_submit_assignment_review_for_actor(
  current_setting('test.poster')::uuid,
  (current_setting('test.accepted')::jsonb->>'assignment_id')::uuid,5,
  'Reliable   and careful work.','15000000-0000-4000-8000-000000000001')->>'replayed','true',
  'a lost review acknowledgement retries the same immutable saved review');
select throws_ok(format($sql$
  select public.server_submit_assignment_review_for_actor(%L::uuid,%L::uuid,3,
    'Changed payload','15000000-0000-4000-8000-000000000001')
$sql$,current_setting('test.poster'),current_setting('test.accepted')::jsonb->>'assignment_id'),
  '23505','idempotency_conflict','a review retry key cannot be reused with changed content');
select throws_ok(format($sql$
  select public.server_submit_assignment_review_for_actor(%L::uuid,%L::uuid,3,
    null,'15000000-0000-4000-8000-000000000003')
$sql$,current_setting('test.poster'),current_setting('test.accepted')::jsonb->>'assignment_id'),
  '23505','review_already_submitted','a second key cannot create another review in the same direction');
select throws_ok(format($sql$
  select public.server_submit_assignment_review_for_actor(%L::uuid,%L::uuid,5,
    null,'15000000-0000-4000-8000-000000000004')
$sql$,current_setting('test.case_staff'),current_setting('test.accepted')::jsonb->>'assignment_id'),
  'P0002','assignment_not_found','an unrelated user cannot review this assignment');
select throws_ok(format($sql$
  select public.server_submit_assignment_review_for_actor(%L::uuid,%L::uuid,5,
    'https://private.example.test','15000000-0000-4000-8000-000000000005')
$sql$,current_setting('test.poster'),current_setting('test.accepted')::jsonb->>'assignment_id'),
  '22023','invalid_review_text','review text cannot contain a URL');
select throws_ok(format($sql$
  select public.server_submit_assignment_review_for_actor(%L::uuid,%L::uuid,5,
    'Private site example.test','15000000-0000-4000-8000-000000000017')
$sql$,current_setting('test.poster'),current_setting('test.accepted')::jsonb->>'assignment_id'),
  '22023','invalid_review_text','bare domain links are rejected as URLs too');
select throws_ok(format($sql$
  select public.server_submit_assignment_review_for_actor(%L::uuid,%L::uuid,5,
    repeat('x',501),'15000000-0000-4000-8000-000000000016')
$sql$,current_setting('test.poster'),current_setting('test.accepted')::jsonb->>'assignment_id'),
  '22023','invalid_review_text','review text over 500 characters is rejected at the database boundary');
select throws_ok(format($sql$
  select public.server_report_assignment_review_for_actor(%L::uuid,%L::uuid)
$sql$,current_setting('test.case_staff'),current_setting('test.review_worker')::jsonb->'review'->>'review_id'),
  'P0002','review_not_found','an actor without permission to view the profile cannot report its review');

select is((public.server_get_safe_profile_for_viewer(
  current_setting('test.poster')::uuid,current_setting('test.student')::uuid)
  ->>'worker_rating'),'5','worker average reflects reviews received as a worker');
select is((public.server_get_safe_profile_for_viewer(
  current_setting('test.poster')::uuid,current_setting('test.student')::uuid)
  ->>'worker_review_count'),'1','worker count includes one visible qualifying review');
select is((public.server_get_safe_profile_for_viewer(
  current_setting('test.poster')::uuid,current_setting('test.student')::uuid)
  ->>'poster_rating'),null,'worker profile remains unrated as a poster with no poster reviews');
select is((public.server_get_safe_profile_for_viewer(
  current_setting('test.poster')::uuid,current_setting('test.poster')::uuid)
  ->>'poster_rating'),'4','poster average reflects reviews received as a poster');
select is((public.server_get_safe_profile_for_viewer(
  current_setting('test.poster')::uuid,current_setting('test.poster')::uuid)
  ->>'poster_review_count'),'1','poster count is separate from worker count');
select is((public.server_get_safe_profile_for_viewer(
  current_setting('test.poster')::uuid,current_setting('test.student')::uuid)
  ->>'completed_work_count'),(select count(*)::text from app_private.assignments a
    where a.worker_id=current_setting('test.student')::uuid
      and app_private.assignment_has_qualifying_completion(a.assignment_id)),
  'completed work count follows each qualifying worker assignment exactly once');
select ok(not (public.server_get_safe_profile_for_viewer(
    current_setting('test.poster')::uuid,current_setting('test.student')::uuid) ? 'rank')
    and not (public.server_get_safe_profile_for_viewer(
    current_setting('test.poster')::uuid,current_setting('test.student')::uuid) ? 'quality_label'),
  'safe profiles expose no ranking or quality label');
select set_config('test.review_public_page',public.server_list_profile_reviews_for_viewer(
  current_setting('test.poster')::uuid,current_setting('test.poster')::uuid,null,null)::text,true);
select ok(current_setting('test.review_public_page')::jsonb->'items'->0 ? 'review_id'
    and not (current_setting('test.review_public_page')::jsonb->'items'->0 ? 'reviewer_id')
    and not (current_setting('test.review_public_page')::jsonb->'items'->0 ? 'reporter_id'),
  'profile review pages expose safe review content without reviewer or reporter identity');

select is(public.server_report_assignment_review_for_actor(
  current_setting('test.poster')::uuid,
  (current_setting('test.review_worker')::jsonb->'review'->>'review_id')::uuid)->>'reported','true',
  'any qualified viewer can report a review they can see');
select is(public.server_report_assignment_review_for_actor(
  current_setting('test.poster')::uuid,
  (current_setting('test.review_worker')::jsonb->'review'->>'review_id')::uuid)->>'reported','true',
  'repeated reports by one user are idempotent');
select is((select count(*)::integer from app_private.assignment_review_reports
  where review_id=(current_setting('test.review_worker')::jsonb->'review'->>'review_id')::uuid),1,
  'one reporter creates one report row for a review');
select set_config('test.review_queue',public.server_list_review_moderation_queue_for_actor(
  current_setting('test.case_staff')::uuid,'aal2',null,null,21)::text,true);
select ok(current_setting('test.review_queue')::jsonb->'items'->0 ? 'review_text'
    and not (current_setting('test.review_queue')::jsonb->'items'->0 ? 'reporter_id')
    and not (current_setting('test.review_queue')::jsonb->'items'->0 ? 'reporter_ids'),
  'moderation queue contains reported review content but hides reporter identities');
select throws_ok(format($sql$
  select public.server_list_review_moderation_queue_for_actor(%L::uuid,'aal1',null,null,21)
$sql$,current_setting('test.case_staff')),
  '42501','review_moderation_denied','AAL1 cannot read the moderation queue');
select throws_ok(format($sql$
  select public.server_hide_assignment_review_for_actor(%L::uuid,%L::uuid,
    'This review contains private contact details.','aal2','15000000-0000-4000-8000-000000000006')
$sql$,current_setting('test.case_staff'),current_setting('test.review_poster')::jsonb->'review'->>'review_id'),
  'P0001','review_moderation_requires_report','a moderator cannot hide an unreported review');
select throws_ok(format($sql$
  select public.server_hide_assignment_review_for_actor(%L::uuid,%L::uuid,
    'This review contains private contact details.','aal2','15000000-0000-4000-8000-000000000007')
$sql$,current_setting('test.student'),current_setting('test.review_worker')::jsonb->'review'->>'review_id'),
  '42501','review_moderation_denied','a review subject cannot moderate their own review');
select throws_ok(format($sql$
  select public.server_hide_assignment_review_for_actor(%L::uuid,%L::uuid,
    'This review contains private contact details.','aal2','15000000-0000-4000-8000-000000000014')
$sql$,current_setting('test.student'),current_setting('test.review_poster')::jsonb->'review'->>'review_id'),
  '42501','review_moderation_denied','a review author cannot moderate their own review');
select set_config('test.review_hidden',public.server_hide_assignment_review_for_actor(
  current_setting('test.case_staff')::uuid,
  (current_setting('test.review_worker')::jsonb->'review'->>'review_id')::uuid,
  'This review contains private contact details.','aal2',
  '15000000-0000-4000-8000-000000000008')::text,true);
select is(current_setting('test.review_hidden')::jsonb->>'status','hidden',
  'a separate qualified human can hide a reported review');
select is(public.server_hide_assignment_review_for_actor(
  current_setting('test.case_staff')::uuid,
  (current_setting('test.review_worker')::jsonb->'review'->>'review_id')::uuid,
  'This review contains private contact details.','aal2',
  '15000000-0000-4000-8000-000000000008')->>'replayed','true',
  'a lost moderation acknowledgement replays the same hide event');
select ok(exists(select 1 from app_private.assignment_review_moderation_events m
    join app_private.staff_grants g on g.grant_id=m.staff_grant_id
    where m.review_id=(current_setting('test.review_worker')::jsonb->'review'->>'review_id')::uuid
      and m.moderator_id=current_setting('test.case_staff')::uuid
      and g.capability='review_moderate' and m.reason='This review contains private contact details.'),
  'hide decisions preserve the original review and append the moderator, grant and reason');
update app_private.staff_grants set revoked_at=pg_catalog.now(),
  revoked_by=current_setting('test.case_staff')::uuid
where user_id=current_setting('test.case_staff')::uuid
  and capability='review_moderate' and revoked_at is null;
select throws_ok(format($sql$
  select public.server_list_review_moderation_queue_for_actor(%L::uuid,'aal2',null,null,21)
$sql$,current_setting('test.case_staff')),
  '42501','review_moderation_denied','a revoked review moderation grant blocks later queue reads');
select is((public.server_get_safe_profile_for_viewer(
  current_setting('test.poster')::uuid,current_setting('test.student')::uuid)
  ->>'worker_rating'),null,'hidden review scores are excluded from the public worker average');
select is((public.server_get_safe_profile_for_viewer(
  current_setting('test.poster')::uuid,current_setting('test.student')::uuid)
  ->>'worker_review_count'),'0','hidden reviews are excluded from public review counts');
select is((public.server_get_safe_profile_for_viewer(
  current_setting('test.poster')::uuid,current_setting('test.poster')::uuid)
  ->>'poster_rating'),'4','hiding a worker review does not change poster averages');
select is((public.server_list_profile_reviews_for_viewer(
  current_setting('test.poster')::uuid,current_setting('test.student')::uuid,null,null)
  ->'items'),'[]'::jsonb,'hidden review text is removed from public profile reads');
select is((select count(*)::integer from app_private.assignment_reviews
  where review_id=(current_setting('test.review_worker')::jsonb->'review'->>'review_id')::uuid),1,
  'moderation preserves the immutable original review record');
select throws_ok(format($sql$
  select public.server_submit_assignment_review_for_actor(%L::uuid,%L::uuid,1,
    null,'15000000-0000-4000-8000-000000000009')
$sql$,current_setting('test.poster'),current_setting('test.accepted')::jsonb->>'assignment_id'),
  '23505','review_already_submitted','hiding a review does not free the one-review slot');
select throws_ok(format($sql$
  update app_private.assignment_reviews set rating=1 where review_id=%L::uuid
$sql$,current_setting('test.review_poster')::jsonb->'review'->>'review_id'),
  '55000','assignment_review_is_immutable','submitted ratings and text cannot be edited');

select set_config('test.review_rebuild_before',(
  select pg_catalog.jsonb_build_object('worker_rating_sum',worker_rating_sum,
    'worker_review_count',worker_review_count,'poster_rating_sum',poster_rating_sum,
    'poster_review_count',poster_review_count,'completed_work_count',completed_work_count)::text
  from app_private.profile_reputation_projections
  where user_id=current_setting('test.student')::uuid),true);
select ok(app_private.rebuild_profile_reputation_projections()>0
  and app_private.rebuild_profile_reputation_projections()>0,
  'profile reputation projections rebuild repeatably from authoritative records');
select is((select pg_catalog.jsonb_build_object('worker_rating_sum',worker_rating_sum,
    'worker_review_count',worker_review_count,'poster_rating_sum',poster_rating_sum,
    'poster_review_count',poster_review_count,'completed_work_count',completed_work_count)::text
  from app_private.profile_reputation_projections
  where user_id=current_setting('test.student')::uuid),
  current_setting('test.review_rebuild_before'),
  'projection totals match their pre-rebuild authoritative state');
select is(public.server_get_safe_profile_for_viewer(
  current_setting('test.poster')::uuid,current_setting('test.student')::uuid)->>'completed_work_count',
  current_setting('test.review_rebuild_before')::jsonb->>'completed_work_count',
  'rebuild preserves the completed-work total after repeated runs');

select set_config('test.review_split',public.server_submit_assignment_review_for_actor(
  current_setting('test.poster')::uuid,
  (select assignment_id from app_private.assignment_cases where case_id=current_setting('test.case_id')::uuid),
  5,'Final worker award followed independent case and appeal review.',
  '15000000-0000-4000-8000-000000000010')::text,true);
select is(current_setting('test.review_split')::jsonb->'review'->>'target_role','worker',
  'a finalized split worker award permits a review in the worker direction');
select is((select worker_review_count::text from app_private.profile_reputation_projections
  where user_id=current_setting('test.unverified')::uuid),'1',
  'the finalized worker award immediately updates the worker-side projection');
select throws_ok(format($sql$
  select public.server_submit_assignment_review_for_actor(%L::uuid,%L::uuid,5,
    null,'15000000-0000-4000-8000-000000000011')
$sql$,current_setting('test.poster'),current_setting('test.step7_noaction_assignment')::jsonb->>'assignment_id'),
  'P0001','review_not_eligible','no-action closure does not unlock review without completed work');
select throws_ok(format($sql$
  select public.server_submit_assignment_review_for_actor(%L::uuid,%L::uuid,5,
    null,'15000000-0000-4000-8000-000000000012')
$sql$,current_setting('test.poster'),current_setting('test.step7_refund_assignment')::jsonb->>'assignment_id'),
  'P0001','review_not_eligible','refund-only case closure does not unlock a review');
select throws_ok(format($sql$
  select public.server_submit_assignment_review_for_actor(%L::uuid,%L::uuid,5,
    null,'15000000-0000-4000-8000-000000000013')
$sql$,current_setting('test.poster'),current_setting('test.cancel_assignment_replacement')::jsonb->>'assignment_id'),
  'P0001','review_not_eligible','prestart cancellation does not unlock a review');
select throws_ok(format($sql$
  select public.server_update_profile_for_actor(%L::uuid,
    jsonb_build_object('worker_review_count',99,'worker_rating',5))
$sql$,current_setting('test.student')),
  '22023','invalid profile','generic profile writes cannot set review projections');

select * from finish();
rollback;
