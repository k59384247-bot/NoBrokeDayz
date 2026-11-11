begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

select ok(to_regclass('app_private.payment_operation_jobs') is not null,
  'durable simulated payment jobs have private lease state');
select ok(to_regprocedure('app_private.claim_payment_operation_job(uuid,smallint)') is not null,
  'only a narrow job-claim database operation is available');
select ok(to_regprocedure('app_private.complete_payment_operation_job(uuid,uuid,text,text,text,text,boolean)') is not null,
  'only a lease-bound result operation can update a simulated operation');
select ok(to_regprocedure('app_private.record_local_simulator_receipt(text,uuid,text,text)') is not null,
  'simulator callbacks have a durable receipt operation');
select ok(to_regclass('public.payment_operation_jobs') is null,
  'payment job storage remains outside API schemas');

select ok(not has_schema_privilege('anon','app_private','USAGE')
  and not has_schema_privilege('authenticated','app_private','USAGE')
  and not has_schema_privilege('service_role','app_private','USAGE'),
  'clients and generic service paths cannot access private payment records');
select ok(not has_table_privilege('anon','app_private.payment_operation_jobs','SELECT')
  and not has_table_privilege('authenticated','app_private.payment_operation_jobs','SELECT')
  and not has_table_privilege('service_role','app_private.payment_operation_jobs','SELECT'),
  'payment jobs cannot be read directly');
select ok(not has_function_privilege('anon','public.server_claim_payment_operation_for_runner(uuid,smallint)','EXECUTE')
  and not has_function_privilege('authenticated','public.server_claim_payment_operation_for_runner(uuid,smallint)','EXECUTE')
  and has_function_privilege('service_role','public.server_claim_payment_operation_for_runner(uuid,smallint)','EXECUTE'),
  'only the server runner can claim durable payment jobs');
select ok(not has_function_privilege('anon','public.server_complete_payment_operation_for_runner(uuid,uuid,text,text,text,text,boolean)','EXECUTE')
  and not has_function_privilege('authenticated','public.server_complete_payment_operation_for_runner(uuid,uuid,text,text,text,text,boolean)','EXECUTE')
  and has_function_privilege('service_role','public.server_complete_payment_operation_for_runner(uuid,uuid,text,text,text,text,boolean)','EXECUTE'),
  'only the server runner can submit a lease-bound provider result');
select ok(not has_function_privilege('anon','public.server_record_payment_simulator_receipt(text,uuid,text,text)','EXECUTE')
  and not has_function_privilege('authenticated','public.server_record_payment_simulator_receipt(text,uuid,text,text)','EXECUTE')
  and has_function_privilege('service_role','public.server_record_payment_simulator_receipt(text,uuid,text,text)','EXECUTE'),
  'only the separately authenticated callback handler can persist simulator receipts');

select set_config('test.payment_actor',(select id::text from auth.users where email='phase2-trackb@identity.test'),true);
select set_config('test.liquidity_key','81100000-0000-4000-8000-000000000000',true);
insert into app_private.provider_operations(
  operation_type,provider_adapter,provider_idempotency_key,actor_id,amount_kobo,currency,
  destination_id,destination_version,request_sha256,status
) values(
  'payout','local_simulator',current_setting('test.liquidity_key')::uuid,
  current_setting('test.payment_actor')::uuid,1000,'NGN',
  '81100000-0000-4000-8000-000000000010',1,
  extensions.digest('queued liquidity must not call the provider','sha256'),'queued_for_liquidity'
);
select is(app_private.claim_payment_operation_job(
  '81100000-0000-4000-8000-000000000003',30::smallint),null::jsonb,
  'queued-for-liquidity operation is never sent to the simulator');
select set_config('test.payment_key','81100000-0000-4000-8000-000000000001',true);
insert into app_private.provider_operations(
  operation_type,provider_adapter,provider_idempotency_key,actor_id,amount_kobo,currency,
  destination_id,destination_version,request_sha256,status
) values(
  'payout','local_simulator',current_setting('test.payment_key')::uuid,
  current_setting('test.payment_actor')::uuid,285000,'NGN',
  '81100000-0000-4000-8000-000000000002',1,
  extensions.digest('synthetic payout operation','sha256'),'pending'
);
select set_config('test.payment_operation',(select operation_id::text from app_private.provider_operations
  where provider_idempotency_key=current_setting('test.payment_key')::uuid),true);
select is((select count(*)::integer from app_private.payment_operation_jobs
  where operation_id=current_setting('test.payment_operation')::uuid),1,
  'persisting an authorized local operation atomically queues one durable job');
select throws_ok($$select app_private.claim_payment_operation_job(null,30::smallint)$$,
  '22023','invalid_payment_job_claim','claim requires a worker identity');
select throws_ok($$select app_private.claim_payment_operation_job('81100000-0000-4000-8000-000000000003',2::smallint)$$,
  '22023','invalid_payment_job_claim','lease duration has a bounded range');

select set_config('test.payment_claim_a',app_private.claim_payment_operation_job(
  '81100000-0000-4000-8000-000000000003',30::smallint)::text,true);
select ok(current_setting('test.payment_claim_a')::jsonb->>'lease_token' is not null,
  'a claimed job returns a server-created lease token');
select is(current_setting('test.payment_claim_a')::jsonb->>'amount_kobo','285000',
  'money returns to the runner as an exact decimal string');
select is(current_setting('test.payment_claim_a')::jsonb->>'destination_id',
  '81100000-0000-4000-8000-000000000002',
  'the runner reads the persisted synthetic destination snapshot');
select throws_ok(format($sql$
  select app_private.complete_payment_operation_job(%L::uuid,'81100000-0000-4000-8000-000000000099',
    'unknown',null,'0','unknown_result',true)
$sql$,current_setting('test.payment_operation')),
  '40001','payment_job_lease_lost','a forged or stale lease token cannot complete work');

update app_private.payment_operation_jobs set lease_expires_at=pg_catalog.now()-interval '1 second'
where operation_id=current_setting('test.payment_operation')::uuid;
select set_config('test.payment_claim_b',app_private.claim_payment_operation_job(
  '81100000-0000-4000-8000-000000000004',30::smallint)::text,true);
select isnt(current_setting('test.payment_claim_b')::jsonb->>'lease_token',
  current_setting('test.payment_claim_a')::jsonb->>'lease_token',
  'an expired lease can be reclaimed with a new fencing token');
select is(current_setting('test.payment_claim_b')::jsonb->>'attempt_count','2',
  'reclaim increments the bounded delivery attempt count');
select lives_ok(format($sql$
  select app_private.complete_payment_operation_job(%L::uuid,%L::uuid,
    'unknown','sim-'||%L,'0','provider_timeout',true)
$sql$,current_setting('test.payment_operation'),
  current_setting('test.payment_claim_b')::jsonb->>'lease_token',current_setting('test.payment_key')),
  'a timed-out provider result remains unknown and retains its original simulator reference');
select is((select status from app_private.provider_operations
  where operation_id=current_setting('test.payment_operation')::uuid),'unknown',
  'provider acceptance uncertainty cannot become success or failure without lookup');
select lives_ok($$select app_private.record_local_simulator_receipt(
  'evt-before-retry-01',current_setting('test.payment_key')::uuid,
  'sim-'||current_setting('test.payment_key'),repeat('f',64))$$,
  'a verified event requeues an operation while its retry delay is pending');
select is((select state from app_private.payment_operation_jobs
  where operation_id=current_setting('test.payment_operation')::uuid),'queued',
  'a valid receipt starts a fresh lookup cycle for the same operation');

update app_private.payment_operation_jobs set available_at=pg_catalog.now()
where operation_id=current_setting('test.payment_operation')::uuid;
select set_config('test.payment_claim_c',app_private.claim_payment_operation_job(
  '81100000-0000-4000-8000-000000000005',30::smallint)::text,true);
select is(current_setting('test.payment_claim_c')::jsonb->>'provider_operation_reference',
  'sim-'||current_setting('test.payment_key'),
  'restart recovery reuses the reference stored by the original attempt');
select throws_ok(format($sql$
  select app_private.complete_payment_operation_job(%L::uuid,%L::uuid,
    'unknown','sim-%s','0','unknown_result',false)
$sql$,current_setting('test.payment_operation'),
  current_setting('test.payment_claim_c')::jsonb->>'lease_token',current_setting('test.payment_key')),
  '22023','invalid_payment_operation_result','unknown cannot be marked resolved without retrying lookup');
select lives_ok(format($sql$
  select app_private.complete_payment_operation_job(%L::uuid,%L::uuid,
    'succeeded','sim-%s','0',null,false)
$sql$,current_setting('test.payment_operation'),
  current_setting('test.payment_claim_c')::jsonb->>'lease_token',current_setting('test.payment_key')),
  'authoritative lookup resolves the same provider operation');
select is((select status from app_private.provider_operations
  where operation_id=current_setting('test.payment_operation')::uuid),'succeeded',
  'only an authoritative runner result changes the provider status');
select is((select count(*)::integer from app_private.ledger_journal_transactions),0,
  'provider acceptance does not itself create a money movement');
select is((select count(*)::integer from app_private.financial_authorizations),0,
  'automatic lookup retries do not create release authorization');

select throws_ok(format($sql$
  select app_private.record_local_simulator_receipt('bad',%L::uuid,
    'sim-%s',repeat('a',64))
$sql$,current_setting('test.payment_key'),current_setting('test.payment_key')),
  '22023','invalid_simulator_receipt','event references follow the documented simulator protocol shape');
select lives_ok(format($sql$
  select app_private.record_local_simulator_receipt('evt-replay-01',%L::uuid,
    'sim-%s',repeat('a',64))
$sql$,current_setting('test.payment_key'),current_setting('test.payment_key')),
  'a verified callback can durably store the event before acknowledgement');
select is((select count(*)::integer from app_private.provider_webhook_receipts
  where provider_adapter='local_simulator' and provider_event_reference='evt-replay-01'),1,
  'the callback receipt is durable');
select is(app_private.record_local_simulator_receipt('evt-replay-01',
  current_setting('test.payment_key')::uuid,'sim-'||current_setting('test.payment_key'),repeat('a',64))->>'duplicate',
  'true','a replay with the same signed body is idempotent');
select throws_ok($$select app_private.record_local_simulator_receipt(
  'evt-replay-01',current_setting('test.payment_key')::uuid,
  'sim-'||current_setting('test.payment_key'),repeat('b',64))$$,
  '23505','simulator_event_reference_conflict','same event identity cannot be replayed with altered contents');
select lives_ok($$select app_private.record_local_simulator_receipt(
  'evt-later-02',current_setting('test.payment_key')::uuid,
  'sim-'||current_setting('test.payment_key'),repeat('e',64))$$,
  'a later event can prompt lookup after an earlier terminal event');
select is((select status from app_private.provider_operations
  where operation_id=current_setting('test.payment_operation')::uuid),'succeeded',
  'a duplicate or out-of-order receipt never applies its event status directly');
select lives_ok($$select app_private.record_local_simulator_receipt(
  'evt-outorder-02',current_setting('test.payment_key')::uuid,
  'wrong-sim-ref',repeat('c',64))$$,
  'a signed event with a mismatched reference is retained for inspection');
select ok(exists(select 1 from app_private.financial_exceptions
  where operation_id=current_setting('test.payment_operation')::uuid and exception_type='reference_mismatch'),
  'mismatched signed events create an exception and never mutate payment status');
select is((select status from app_private.provider_operations
  where operation_id=current_setting('test.payment_operation')::uuid),'succeeded',
  'callback status and order never directly change provider operation state');
select lives_ok(format('update app_private.payment_operation_jobs set state=''complete'' where operation_id=%L::uuid',
  current_setting('test.payment_operation')),
  'test fixture parks the completed operation before the independent retry case');

select set_config('test.retry_key','81100000-0000-4000-8000-000000000011',true);
insert into app_private.provider_operations(
  operation_type,provider_adapter,provider_idempotency_key,actor_id,amount_kobo,currency,
  destination_id,destination_version,request_sha256,status
) values('payout','local_simulator',current_setting('test.retry_key')::uuid,
  current_setting('test.payment_actor')::uuid,100,'NGN',
  '81100000-0000-4000-8000-000000000012',1,
  extensions.digest('bounded retry operation','sha256'),'pending');
select set_config('test.retry_operation',(select operation_id::text from app_private.provider_operations
  where provider_idempotency_key=current_setting('test.retry_key')::uuid),true);
select lives_ok($sql$
  do $body$
  declare v_claim jsonb; v_index integer;
  begin
    for v_index in 1..5 loop
      update app_private.payment_operation_jobs set available_at=pg_catalog.now()
        where operation_id=current_setting('test.retry_operation')::uuid;
      v_claim:=app_private.claim_payment_operation_job('81100000-0000-4000-8000-000000000013',30::smallint);
      perform app_private.complete_payment_operation_job(
        current_setting('test.retry_operation')::uuid,(v_claim->>'lease_token')::uuid,
        'unknown',null,'0','unknown_result',true);
    end loop;
  end
  $body$;
  $sql$,'unknown operation retry count is capped at five attempts');
select is((select state from app_private.payment_operation_jobs
  where operation_id=current_setting('test.retry_operation')::uuid),'exhausted',
  'a fifth unresolved result stops automatic retries');
select is((select status from app_private.provider_operations
  where operation_id=current_setting('test.retry_operation')::uuid),'unknown',
  'bounded retry exhaustion preserves an honest unknown result');
select lives_ok($$select app_private.record_local_simulator_receipt(
  'evt-resolve-03',current_setting('test.retry_key')::uuid,
  'sim-'||current_setting('test.retry_key'),repeat('d',64))$$,
  'a new verified event can schedule authoritative lookup after retry exhaustion');
select is((select state from app_private.payment_operation_jobs
  where operation_id=current_setting('test.retry_operation')::uuid),'queued',
  'a verified event reopens lookup without creating a new payment identity');
select is((select attempt_count from app_private.payment_operation_jobs
  where operation_id=current_setting('test.retry_operation')::uuid),0::smallint,
  'event-driven reconciliation starts a new bounded lookup cycle');
select lives_ok(format('update app_private.payment_operation_jobs set state=''exhausted'' where operation_id=%L::uuid',
  current_setting('test.retry_operation')),
  'test fixture parks the reconciled operation before the lost-consumer case');

select set_config('test.crash_key','81100000-0000-4000-8000-000000000021',true);
insert into app_private.provider_operations(
  operation_type,provider_adapter,provider_idempotency_key,actor_id,amount_kobo,currency,
  destination_id,destination_version,request_sha256,status
) values('payout','local_simulator',current_setting('test.crash_key')::uuid,
  current_setting('test.payment_actor')::uuid,100,'NGN',
  '81100000-0000-4000-8000-000000000022',1,
  extensions.digest('consumer crash retry operation','sha256'),'pending');
select set_config('test.crash_operation',(select operation_id::text from app_private.provider_operations
  where provider_idempotency_key=current_setting('test.crash_key')::uuid),true);
select lives_ok($sql$
  do $body$
  declare v_claim jsonb; v_index integer;
  begin
    for v_index in 1..5 loop
      v_claim:=app_private.claim_payment_operation_job('81100000-0000-4000-8000-000000000023',30::smallint);
      if v_claim is null or v_claim->>'operation_id'<>current_setting('test.crash_operation') then
        raise exception 'unexpected job claimed';
      end if;
      update app_private.payment_operation_jobs set lease_expires_at=pg_catalog.now()-interval '1 second'
        where operation_id=current_setting('test.crash_operation')::uuid;
    end loop;
    v_claim:=app_private.claim_payment_operation_job('81100000-0000-4000-8000-000000000023',30::smallint);
    if v_claim is not null then raise exception 'exhausted lease was reclaimed'; end if;
  end
  $body$;
  $sql$,'a consumer that repeatedly dies is fenced and eventually exhausted');
select is((select state from app_private.payment_operation_jobs
  where operation_id=current_setting('test.crash_operation')::uuid),'exhausted',
  'five expired leases stop automatic consumer recovery');
select is((select attempt_count from app_private.payment_operation_jobs
  where operation_id=current_setting('test.crash_operation')::uuid),5::smallint,
  'expired consumer leases count against the retry bound');
select is((select status from app_private.provider_operations
  where operation_id=current_setting('test.crash_operation')::uuid),'unknown',
  'an exhausted consumer leaves an unresolved provider result honestly unknown');

select throws_ok(format('delete from app_private.payment_operation_jobs where operation_id=%L::uuid',
  current_setting('test.payment_operation')),'55000','payment_operation_job_is_immutable',
  'durable job history cannot be deleted');

select * from finish();
rollback;
