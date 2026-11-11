begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

select ok(to_regclass('app_private.financial_reconciliation_runs') is not null
  and to_regclass('app_private.financial_reconciliation_findings') is not null,
  'reconciliation runs and immutable findings are private records');
select ok(not has_table_privilege('anon','app_private.in_app_notifications','SELECT')
  and not has_table_privilege('authenticated','app_private.in_app_notifications','SELECT')
  and not has_table_privilege('service_role','app_private.in_app_notifications','SELECT'),
  'no API or generic service role can read notice rows directly');
select ok(not has_function_privilege('anon','public.server_list_my_notifications_for_actor(uuid,timestamp with time zone,uuid)','EXECUTE')
  and not has_function_privilege('authenticated','public.server_list_my_notifications_for_actor(uuid,timestamp with time zone,uuid)','EXECUTE')
  and has_function_privilege('service_role','public.server_list_my_notifications_for_actor(uuid,timestamp with time zone,uuid)','EXECUTE'),
  'notice projections are exposed only through the server gateway');
select ok(not has_function_privilege('anon','public.server_inspect_financial_reference_for_actor(uuid,text,text,text)','EXECUTE')
  and not has_function_privilege('authenticated','public.server_inspect_financial_reference_for_actor(uuid,text,text,text)','EXECUTE')
  and has_function_privilege('service_role','public.server_inspect_financial_reference_for_actor(uuid,text,text,text)','EXECUTE'),
  'staff inspection is available only through the narrow server gateway');
select ok(not has_function_privilege('service_role','app_private.post_financial_journal(uuid,text,uuid,uuid,jsonb)','EXECUTE')
  and has_function_privilege('service_role','public.server_reconcile_financial_state_for_actor(uuid,text,text,text)','EXECUTE'),
  'the service gateway exposes reconciliation but not journal posting');

select set_config('test.notice_actor',(select id::text from auth.users where email='phase2-trackb@identity.test'),true);
select set_config('test.notice_other',(select id::text from auth.users where email='phase2-owner@identity.test'),true);
insert into app_private.financial_audit_events(actor_id,event_type,reference_id,event_data)
values(current_setting('test.notice_actor')::uuid,'withdrawal_status_changed',
  '81600000-0000-4000-8000-000000000001',jsonb_build_object('status','paid'));
select set_config('test.notice_event',(select event_id::text from app_private.financial_audit_events
  where reference_id='81600000-0000-4000-8000-000000000001'::uuid),true);
select lives_ok(format($sql$select app_private.add_financial_in_app_notification(%L::uuid,%L::uuid,'withdrawal_paid')$sql$,
  current_setting('test.notice_event'),current_setting('test.notice_actor')),
  'a financial business event can create a recipient notice in its transaction');
select lives_ok(format($sql$select app_private.add_financial_in_app_notification(%L::uuid,%L::uuid,'withdrawal_paid')$sql$,
  current_setting('test.notice_event'),current_setting('test.notice_actor')),
  'retrying the same event and notice type is idempotent');
select is((select count(*)::integer from app_private.in_app_notifications
  where financial_event_id=current_setting('test.notice_event')::uuid),1,
  'recipient event/type uniqueness prevents duplicate notices');
select is(app_private.list_my_notifications_for_actor(
  current_setting('test.notice_actor')::uuid,null,null)->'notifications'->0->>'notification_type',
  'withdrawal_paid','the recipient can read their own notice');
select is(app_private.list_my_notifications_for_actor(
  current_setting('test.notice_other')::uuid,null,null)->'notifications','[]'::jsonb,
  'another user cannot read that notice');
select is(app_private.mark_my_notification_read_for_actor(
  current_setting('test.notice_other')::uuid,
  (select notification_id from app_private.in_app_notifications
   where financial_event_id=current_setting('test.notice_event')::uuid)),null::jsonb,
  'another user cannot mark a notice read');
select lives_ok(format($sql$select app_private.mark_my_notification_read_for_actor(%L::uuid,%L::uuid)$sql$,
  current_setting('test.notice_actor'),
  (select notification_id::text from app_private.in_app_notifications
   where financial_event_id=current_setting('test.notice_event')::uuid)),
  'the recipient can mark their own notice read');
select lives_ok(format($sql$select app_private.mark_my_notification_read_for_actor(%L::uuid,%L::uuid)$sql$,
  current_setting('test.notice_actor'),
  (select notification_id::text from app_private.in_app_notifications
   where financial_event_id=current_setting('test.notice_event')::uuid)),
  'a repeated read acknowledgement does not change the original timestamp');

select ok(app_private.financial_audit_integrity_valid(),
  'append-only financial audit rows match the local hash chain');
select is((select count(*)::integer from app_private.financial_audit_integrity),
  (select count(*)::integer from app_private.financial_audit_events),
  'each financial audit event has an integrity-chain entry');
select throws_ok(format($sql$update app_private.financial_audit_integrity set event_hash=decode(repeat('00',32),'hex') where event_id=%L::uuid$sql$,
  current_setting('test.notice_event')),
  '55000','financial_record_is_immutable','audit integrity entries cannot be edited');

select throws_ok(format($sql$select app_private.inspect_financial_reference_for_actor(%L::uuid,'aal1','operation','81600000-0000-4000-8000-000000000010')$sql$,
  current_setting('test.notice_actor')),
  '42501','financial_inspection_denied','AAL1 cannot inspect financial records');
select throws_ok(format($sql$select app_private.inspect_financial_reference_for_actor(%L::uuid,'aal2','operation','81600000-0000-4000-8000-000000000010')$sql$,
  current_setting('test.notice_actor')),
  '42501','financial_inspection_denied','AAL2 without a current financial_inspect grant cannot inspect records');
insert into app_private.identity_accounts(user_id,account_type,age_confirmed_at,age_policy_version)
values(current_setting('test.notice_actor')::uuid,'student',pg_catalog.now(),'age-18-v1')
on conflict(user_id) do nothing;
insert into app_private.staff_grants(user_id,capability,granted_by,reason)
  values(current_setting('test.notice_actor')::uuid,'financial_inspect',
    current_setting('test.notice_actor')::uuid,'Local synthetic finance inspection grant for Step 9 tests.');
select ok(exists(select 1 from app_private.staff_grants
  where user_id=current_setting('test.notice_actor')::uuid and capability='financial_inspect'
    and revoked_at is null),
  'the test actor receives only the approved read-only inspection grant');
insert into app_private.provider_operations(
  operation_id,operation_type,provider_adapter,provider_idempotency_key,actor_id,
  amount_kobo,currency,destination_id,destination_version,request_sha256,status
) values(
  '81600000-0000-4000-8000-000000000010','payout','local_simulator',
  '81600000-0000-4000-8000-000000000011',current_setting('test.notice_actor')::uuid,
  300000,'NGN','81600000-0000-4000-8000-000000000012',1,
  extensions.digest('step 9 inspection fixture','sha256'),'pending'
);
select is(app_private.inspect_financial_reference_for_actor(
  current_setting('test.notice_actor')::uuid,'aal2','operation',
  '81600000-0000-4000-8000-000000000010')->'operations'->0->>'amount_kobo',
  '300000','the granted inspector can trace the persisted operation amount');
select is(app_private.inspect_financial_reference_for_actor(
  current_setting('test.notice_actor')::uuid,'aal2','operation',
  '81600000-0000-4000-8000-000000000010')->'payment_jobs'->0->>'state',
  'queued','inspection exposes bounded durable-job state but no lease token');
select ok(app_private.inspect_financial_reference_for_actor(
  current_setting('test.notice_actor')::uuid,'aal2','operation',
  '81600000-0000-4000-8000-000000000010')->>'inspection_event_id' is not null,
  'each financial inspection appends attributable audit evidence');
select ok(not app_private.staff_actor_has_current_capability(
  current_setting('test.notice_actor')::uuid,'financial_initiate','aal2')
  and not app_private.staff_actor_has_current_capability(
  current_setting('test.notice_actor')::uuid,'financial_approve','aal2'),
  'financial inspection grants no money initiation or approval capability');

insert into app_private.jobs(job_id,poster_id)
values('81600000-0000-4000-8000-000000000013',current_setting('test.notice_actor')::uuid);
insert into app_private.funding_intents(
  intent_id,poster_id,job_id,terms_version,gross_per_worker_kobo,slot_count,
  gross_total_kobo,currency,status,idempotency_key,request_sha256
) values(
  '81600000-0000-4000-8000-000000000014',current_setting('test.notice_actor')::uuid,
  '81600000-0000-4000-8000-000000000013',1,300000,1,300000,'NGN','pending',
  '81600000-0000-4000-8000-000000000016',extensions.digest('step 9 funding trace fixture','sha256')
);
insert into app_private.provider_operations(
  operation_id,operation_type,provider_adapter,provider_idempotency_key,actor_id,
  funding_intent_id,amount_kobo,currency,request_sha256,status
) values(
  '81600000-0000-4000-8000-000000000015','collection','local_simulator',
  '81600000-0000-4000-8000-000000000017',current_setting('test.notice_actor')::uuid,
  '81600000-0000-4000-8000-000000000014',300000,'NGN',
  extensions.digest('step 9 job operation trace fixture','sha256'),'pending'
);
select set_config('test.job_inspection_result',app_private.inspect_financial_reference_for_actor(
  current_setting('test.notice_actor')::uuid,'aal2','job',
  '81600000-0000-4000-8000-000000000013')::text,true);
select is(current_setting('test.job_inspection_result')::jsonb->'operations'->0->>'operation_id',
  '81600000-0000-4000-8000-000000000015',
  'job-reference inspection follows the correct funding-intent key to its provider operation');
select is(current_setting('test.job_inspection_result')::jsonb->'funding'->0->>'intent_id',
  '81600000-0000-4000-8000-000000000014',
  'job-reference inspection includes its immutable funding intent');

insert into app_private.ledger_account_balances(account_id,owner_id,allocation_id,debit_kobo,credit_kobo)
select account_id,null,null,1,0 from app_private.ledger_accounts
where account_code='provider_processing_fee_expense';
select set_config('test.reconciliation_result',app_private.reconcile_financial_state_for_actor(
  current_setting('test.notice_actor')::uuid,'aal2','0','0')::text,true);
select is(current_setting('test.reconciliation_result')::jsonb->>'status','mismatch',
  'reconciliation marks inconsistencies for investigation without correcting balances');
select ok((current_setting('test.reconciliation_result')::jsonb->>'money_movement_authorized')::boolean=false
  and (current_setting('test.reconciliation_result')::jsonb->>'signed_checkpoint_proven')::boolean=false,
  'reconciliation creates no money authorization and claims no signed audit checkpoint');
select ok((current_setting('test.reconciliation_result')::jsonb->'findings')::text like '%projection_balance_mismatch%'
  and (current_setting('test.reconciliation_result')::jsonb->'findings')::text like '%unresolved_operation%',
  'reconciliation preserves projection and unresolved-operation findings');
select set_config('test.reconciliation_trace',app_private.inspect_financial_reference_for_actor(
  current_setting('test.notice_actor')::uuid,'aal2','reconciliation_run',
  current_setting('test.reconciliation_result')::jsonb->>'run_id')::text,true);
select is(current_setting('test.reconciliation_trace')::jsonb->'reconciliation'->>'status','mismatch',
  'authorized trace can retrieve a saved mismatch run');
select ok((current_setting('test.reconciliation_trace')::jsonb->'reconciliation_findings')::text like '%projection_balance_mismatch%'
  and (current_setting('test.reconciliation_trace')::jsonb->'reconciliation_findings')::text like '%unresolved_operation%'
  and (current_setting('test.reconciliation_trace')::jsonb->'financial_outbox')::text like '%financial.reconciliation_completed%',
  'saved mismatch findings and reconciliation outbox event remain traceable');
select is((select status from app_private.provider_operations
  where operation_id='81600000-0000-4000-8000-000000000010'::uuid),'pending',
  'reconciliation never changes an operation result');
select is((select count(*)::integer from app_private.ledger_journal_transactions),0,
  'reconciliation never posts or resets journal history');
select ok((select count(*) from app_private.financial_reconciliation_findings
  where run_id=(current_setting('test.reconciliation_result')::jsonb->>'run_id')::uuid)>0,
  'mismatch evidence remains available after the reconciliation response');
select ok(app_private.financial_audit_integrity_valid(),
  'reconciliation and inspection audit events remain chained');

select * from finish();
rollback;
