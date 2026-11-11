begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

select ok(to_regclass('app_private.ledger_accounts') is not null,
  'private chart of accounts exists');
select ok(to_regclass('app_private.ledger_account_balances') is not null,
  'transactional account-balance projection exists');
select ok(to_regclass('app_private.ledger_journal_transactions') is not null,
  'immutable journal transactions exist');
select ok(to_regclass('app_private.ledger_journal_entries') is not null,
  'immutable journal entries exist');
select ok(to_regclass('app_private.funding_intents') is not null,
  'funding intents preserve exact server-side totals');
select ok(to_regclass('app_private.funding_attempts') is not null,
  'funding attempts preserve provider outcome history');
select ok(to_regclass('app_private.principal_allocations') is not null,
  'funded principal is represented per slot');
select ok(to_regclass('app_private.financial_authorizations') is not null,
  'sensitive-action authorization proofs have a private record');
select ok(to_regclass('app_private.provider_operations') is not null,
  'durable provider-operation identities exist');
select ok(to_regclass('app_private.provider_webhook_receipts') is not null,
  'provider receipt digests can be deduplicated without storing raw payloads');
select ok(to_regclass('app_private.financial_command_idempotency') is not null,
  'financial command idempotency records exist');
select ok(to_regclass('app_private.financial_exceptions') is not null,
  'mismatched or uncertain financial work can be reconciled');
select ok(to_regclass('app_private.financial_audit_events') is not null,
  'financial audit records are separate from identity audit records');
select ok(to_regclass('app_private.financial_outbox') is not null,
  'journal effects can enqueue durable domain events');
select ok(to_regclass('app_private.provider_liquidity_snapshot') is not null,
  'cleared cash, fee reserve and receivable are separate projections');
select ok(to_regclass('public.jobs') is null and to_regclass('public.wallets') is null
  and to_regclass('public.ledger_accounts') is null and to_regclass('public.principal_allocations') is null,
  'Step 2 creates no public job, wallet or ledger table');

select ok(to_regprocedure('app_private.calculate_commission_kobo(bigint)') is not null,
  'commission uses a private integer-kobo calculation');
select ok(to_regprocedure('app_private.post_financial_journal(uuid,text,uuid,uuid,jsonb)') is not null,
  'balanced journal posting has one controlled transaction boundary');
select ok(to_regprocedure('app_private.record_exact_funding(uuid,smallint)') is not null,
  'exact collection finalization creates allocations and ledger effects atomically');
select ok(to_regprocedure('app_private.rebuild_ledger_account_balances()') is not null,
  'account projections can be rebuilt from the journal');

select ok(not has_schema_privilege('anon','app_private','USAGE'),
  'anon cannot use the private financial schema');
select ok(not has_schema_privilege('authenticated','app_private','USAGE'),
  'authenticated cannot use the private financial schema');
select ok(not has_schema_privilege('service_role','app_private','USAGE'),
  'generic service role cannot use the private financial schema');
select ok(not has_function_privilege('anon','app_private.post_financial_journal(uuid,text,uuid,uuid,jsonb)','EXECUTE'),
  'anon cannot post a journal');
select ok(not has_function_privilege('authenticated','app_private.post_financial_journal(uuid,text,uuid,uuid,jsonb)','EXECUTE'),
  'authenticated cannot post a journal');
select ok(not has_function_privilege('service_role','app_private.post_financial_journal(uuid,text,uuid,uuid,jsonb)','EXECUTE'),
  'generic service role cannot post a journal');
select ok(has_function_privilege('postgres','app_private.post_financial_journal(uuid,text,uuid,uuid,jsonb)','EXECUTE'),
  'only the controlled database owner can post through the private boundary');

select is((select count(*)::integer from app_private.ledger_accounts),16,
  'chart seeds separate provider assets, job and worker liabilities, income, expenses and capital');
select is((select commission_basis_points from app_private.ledger_policy where policy_name='ordinary_completion'),500::smallint,
  'the stored local commission policy is 500 basis points');
select is(app_private.calculate_commission_kobo(1),0::bigint,
  'sub-half-kobo commission rounds down');
select is(app_private.calculate_commission_kobo(10),1::bigint,
  'exact half-kobo commission rounds up');
select is(app_private.calculate_commission_kobo(30),2::bigint,
  'a non-half commission fraction rounds to nearest kobo');
select is(app_private.calculate_commission_kobo(50),3::bigint,
  'second exact half-kobo commission rounds up');
select is(app_private.calculate_commission_kobo(300000),15000::bigint,
  'NGN 3,000 gross produces NGN 150 commission');
select throws_ok($$select app_private.calculate_commission_kobo(0)$$,
  '22023','invalid_amount','zero gross is rejected');
select throws_ok($$select app_private.calculate_commission_kobo(100000001)$$,
  '22023','invalid_amount','commission helper enforces the approved local per-worker bound');
select throws_ok($$select app_private.calculate_commission_kobo(-1)$$,
  '22023','invalid_amount','negative gross is rejected');

select set_config('test.first_journal',app_private.post_financial_journal(
  '31000000-0000-4000-8000-000000000001','platform_capital_contribution',null,null,
  '[{"account_code":"provider_available_cash","direction":"debit","amount_kobo":"12500"},{"account_code":"platform_capital_contributed","direction":"credit","amount_kobo":"12500"}]'::jsonb
)::text,true);
select ok(exists(select 1 from app_private.ledger_journal_entries e
  join app_private.ledger_journal_transactions t using(journal_id)
  where t.journal_id=current_setting('test.first_journal')::uuid),
  'a balanced transaction posts its immutable entries');
select is(app_private.post_financial_journal(
  '31000000-0000-4000-8000-000000000001','platform_capital_contribution',null,null,
  '[{"account_code":"provider_available_cash","direction":"debit","amount_kobo":"12500"},{"account_code":"platform_capital_contributed","direction":"credit","amount_kobo":"12500"}]'::jsonb
)::text,current_setting('test.first_journal'),
  'same effect identity and request returns the original journal');
select throws_ok($$select app_private.post_financial_journal(
  '31000000-0000-4000-8000-000000000001','platform_capital_contribution',null,null,
  '[{"account_code":"provider_available_cash","direction":"debit","amount_kobo":"12501"},{"account_code":"platform_capital_contributed","direction":"credit","amount_kobo":"12501"}]'::jsonb
)$$,'23505','idempotency_conflict','same effect key cannot be reused with changed input');
select throws_ok($$select app_private.post_financial_journal(
  '31000000-0000-4000-8000-000000000002','platform_capital_contribution',null,null,
  '[{"account_code":"provider_available_cash","direction":"debit","amount_kobo":"12500"},{"account_code":"platform_capital_contributed","direction":"credit","amount_kobo":"12499"}]'::jsonb
)$$,'22023','unbalanced_journal','unbalanced entries are rejected before posting');
select throws_ok($$select app_private.post_financial_journal(
  '31000000-0000-4000-8000-000000000003','platform_capital_contribution',null,null,
  '[{"account_code":"provider_available_cash","direction":"debit","amount_kobo":12500},{"account_code":"platform_capital_contributed","direction":"credit","amount_kobo":"12500"}]'::jsonb
)$$,'22023','invalid_journal_entry','JSON money numbers are rejected; amounts must be integer-kobo strings');
select throws_ok($$select app_private.post_financial_journal(
  '31000000-0000-4000-8000-000000000004','platform_capital_contribution',null,null,
  '[{"account_code":"provider_available_cash","direction":"debit","amount_kobo":"0"},{"account_code":"platform_capital_contributed","direction":"credit","amount_kobo":"0"}]'::jsonb
)$$,'22023','invalid_journal_entry','zero-value journal lines are rejected');
select throws_ok($$select app_private.post_financial_journal(
  '31000000-0000-4000-8000-000000000005','platform_capital_contribution',null,null,
  '[{"account_code":"provider_available_cash","direction":"debit","amount_kobo":"9223372036854775808"},{"account_code":"platform_capital_contributed","direction":"credit","amount_kobo":"9223372036854775808"}]'::jsonb
)$$,'22023','invalid_journal_entry','amounts above bigint range are rejected');
select throws_ok(format('update app_private.ledger_journal_transactions set effect_type=''changed'' where journal_id=%L::uuid',current_setting('test.first_journal')),
  '55000','financial_record_is_immutable','posted journal headers cannot be edited');
select throws_ok(format('delete from app_private.ledger_journal_entries where journal_id=%L::uuid',current_setting('test.first_journal')),
  '55000','financial_record_is_immutable','posted journal entries cannot be deleted');
select is((select count(*)::integer from app_private.financial_audit_events),1,
  'posting appends one financial audit event and idempotent replay adds none');
select is((select count(*)::integer from app_private.financial_outbox),1,
  'posting appends one durable outbox event and idempotent replay adds none');

select lives_ok($$select app_private.post_financial_journal(
  '31000000-0000-4000-8000-000000000006','platform_capital_contribution',null,null,
  '[{"account_code":"provider_collection_receivable","direction":"debit","amount_kobo":"8000"},{"account_code":"platform_capital_contributed","direction":"credit","amount_kobo":"8000"}]'::jsonb
)$$,'a collection receivable can be journaled separately from settled cash');
select is((select cleared_cash_kobo from app_private.provider_liquidity_snapshot),12500::numeric,
  'only cleared provider cash appears in cleared liquidity');
select is((select collection_receivable_kobo from app_private.provider_liquidity_snapshot),8000::numeric,
  'provider receivable stays separately visible and is not treated as cash');
select is((select fee_reserve_kobo from app_private.provider_liquidity_snapshot),0::numeric,
  'platform fee reserve remains a separate source');
select throws_ok($$select app_private.post_financial_journal(
  '31000000-0000-4000-8000-000000000007','platform_capital_contribution',null,null,
  '[{"account_code":"platform_capital_contributed","direction":"debit","amount_kobo":"13000"},{"account_code":"provider_available_cash","direction":"credit","amount_kobo":"13000"}]'::jsonb
)$$,'22023','account_balance_would_be_negative','journal cannot spend cash that is not cleared');
select lives_ok($$update app_private.ledger_account_balances
  set debit_kobo=0,credit_kobo=0
  where account_id=(select account_id from app_private.ledger_accounts where account_code='provider_available_cash')$$,
  'test can demonstrate a stale projection');
select lives_ok($$select app_private.rebuild_ledger_account_balances()$$,
  'projection rebuild completes from immutable journal entries');
select is((select balance_kobo from app_private.ledger_account_balances b
  join app_private.ledger_accounts a using(account_id) where a.account_code='provider_available_cash'),12500::bigint,
  'rebuilt projection matches the journal-derived cash balance');

select set_config('test.partner_id',(select id::text from auth.users where email='phase2-trackb@identity.test'),true);
select lives_ok(format($sql$
  insert into app_private.staff_grants(user_id,capability,granted_by,reason)
  values(%L::uuid,'financial_inspect',%L::uuid,'approved local read-only inspection test grant')
$sql$,current_setting('test.partner_id'),current_setting('test.partner_id')),
  'the distinct read-only financial_inspect capability is accepted by the grant constraint');

select set_config('test.job_id','31000000-0000-4000-8000-000000000010',true);
insert into app_private.funding_intents(
  poster_id,job_id,terms_version,gross_per_worker_kobo,slot_count,gross_total_kobo,
  currency,status,idempotency_key,request_sha256
) values(current_setting('test.partner_id')::uuid,current_setting('test.job_id')::uuid,
  1,300000,3,900000,'NGN','pending','31000000-0000-4000-8000-000000000011',
  extensions.digest('three slots at 300000','sha256'));
select set_config('test.funding_intent',(select intent_id::text from app_private.funding_intents
  where idempotency_key='31000000-0000-4000-8000-000000000011'),true);
insert into app_private.provider_operations(operation_type,provider_adapter,provider_operation_reference,
  provider_idempotency_key,actor_id,funding_intent_id,amount_kobo,fee_kobo,currency,request_sha256,status)
values('collection','synthetic_test_fixture','local-fixture-collection-01',
  '31000000-0000-4000-8000-000000000017',current_setting('test.partner_id')::uuid,
  current_setting('test.funding_intent')::uuid,900000,0,'NGN',
  extensions.digest('test collection operation','sha256'),'pending');
select set_config('test.collection_operation',(select operation_id::text from app_private.provider_operations
  where provider_idempotency_key='31000000-0000-4000-8000-000000000017'),true);
select lives_ok(format($sql$
  insert into app_private.funding_attempts(funding_intent_id,operation_id,attempt_number,status,
    collected_gross_kobo,provider_fee_kobo,provider_net_kobo,currency,settlement_status,
    provider_event_reference,result_sha256)
  values(%L::uuid,%L::uuid,1,'pending',null,null,null,null,null,null,null)
$sql$,current_setting('test.funding_intent'),current_setting('test.collection_operation')),
  'pending funding attempt is durably recorded before provider outcome is known');
select lives_ok(format($sql$
  update app_private.provider_operations set status='unknown',safe_error_code='provider_timeout'
  where operation_id=%L::uuid
$sql$,current_setting('test.collection_operation')),
  'a possible timeout preserves the original provider operation as unknown');
select lives_ok(format($sql$
  update app_private.funding_attempts set status='unknown'
  where funding_intent_id=%L::uuid and attempt_number=1
$sql$,current_setting('test.funding_intent')),
  'funding attempt remains attached to its original unknown operation');
select lives_ok(format($sql$
  update app_private.provider_operations set status='succeeded',fee_kobo=4500,safe_error_code=null
  where operation_id=%L::uuid
$sql$,current_setting('test.collection_operation')),
  'authoritative lookup resolves the same operation instead of launching a second collection');
select lives_ok(format($sql$
  update app_private.funding_attempts set status='succeeded',collected_gross_kobo=900000,
    provider_fee_kobo=4500,provider_net_kobo=895500,currency='NGN',settlement_status='pending',
    provider_event_reference='local-fixture-event-01',result_sha256=extensions.digest('test collection result','sha256')
  where funding_intent_id=%L::uuid and attempt_number=1
$sql$,current_setting('test.funding_intent')),
  'exact result preserves collected gross, provider fee, net and pending settlement separately');
select set_config('test.funding_attempt',(select attempt_id::text from app_private.funding_attempts
  where funding_intent_id=current_setting('test.funding_intent')::uuid and attempt_number=1),true);
select throws_ok(format('update app_private.funding_intents set status=''succeeded'' where intent_id=%L::uuid',current_setting('test.funding_intent')),
  '22023','funding_result_mismatch','funding cannot succeed without its allocation set and matching journal');
select lives_ok(format('select app_private.record_exact_funding(%L::uuid,1::smallint)',current_setting('test.funding_intent')),
  'exact success records the journal and one allocation per slot in one transaction');
select set_config('test.funding_journal',app_private.record_exact_funding(
  current_setting('test.funding_intent')::uuid,1::smallint)::text,true);
select is(app_private.record_exact_funding(current_setting('test.funding_intent')::uuid,1::smallint)::text,
  current_setting('test.funding_journal'),'retry returns the original funding journal without creating a new effect');
select is((select count(*)::integer from app_private.principal_allocations
  where funding_intent_id=current_setting('test.funding_intent')::uuid),3,
  'a three-worker job has three principal allocations');
select is((select count(distinct allocation_id)::integer from app_private.principal_allocations
  where funding_intent_id=current_setting('test.funding_intent')::uuid),3,
  'each funded slot has a distinct principal identity');
select is((select sum(gross_principal_kobo)::bigint from app_private.principal_allocations
  where funding_intent_id=current_setting('test.funding_intent')::uuid),900000::bigint,
  'slot principal adds up to exact poster funding without a surcharge');
select is((select count(distinct commission_basis_points)::integer from app_private.principal_allocations
  where funding_intent_id=current_setting('test.funding_intent')::uuid),1,
  'each funded slot snapshots the same 500-basis-point commission policy');
select is((select count(*)::integer from app_private.ledger_journal_entries e
  join app_private.ledger_accounts a using(account_id)
  where a.account_code='job_principal_unassigned'
    and e.journal_id=current_setting('test.funding_journal')::uuid),3,
  'initial funding credits each allocation separately, not one shared job balance');
select is((select min(allocation_principal_kobo)::bigint from (
  select -sum(b.balance_kobo)::bigint as allocation_principal_kobo
  from app_private.ledger_account_balances b join app_private.ledger_accounts a using(account_id)
  where b.allocation_id in (select allocation_id from app_private.principal_allocations
    where funding_intent_id=current_setting('test.funding_intent')::uuid)
    and a.account_code in ('job_principal_unassigned','job_principal_assigned','job_principal_dispute_held',
      'worker_earnings_available','worker_withdrawal_reserved','poster_refund_payable','platform_commission_revenue')
  group by b.allocation_id
) allocation_totals),300000::bigint,
  'each funded allocation retains its own NGN 3,000 principal conservation balance');
select is((select cleared_cash_kobo from app_private.provider_liquidity_snapshot),12500::numeric,
  'pending settlement does not turn the collection receivable into cleared provider cash');
select is((select collection_receivable_kobo from app_private.provider_liquidity_snapshot),903500::numeric,
  'provider net collection is recorded as a receivable until settlement is available');
select is((select b.balance_kobo from app_private.ledger_account_balances b
  join app_private.ledger_accounts a using(account_id) where a.account_code='provider_processing_fee_expense'),4500::bigint,
  'the collection fee is a separate platform expense, not a poster surcharge or reduced principal');
select throws_ok(format($sql$
  insert into app_private.principal_allocations(funding_intent_id,job_id,poster_id,slot_number,
    gross_principal_kobo,commission_basis_points,status)
  values(%L::uuid,current_setting('test.job_id')::uuid,current_setting('test.partner_id')::uuid,
    1,300000,500,'unassigned')
$sql$,current_setting('test.funding_intent')),'22023','invalid_principal_allocation',
  'a funded slot cannot be allocated twice');
select throws_ok(format('update app_private.funding_intents set gross_per_worker_kobo=299999 where intent_id=%L::uuid',current_setting('test.funding_intent')),
  '55000','funding_intent_is_immutable','successful funding terms cannot be edited');
select throws_ok(format('update app_private.principal_allocations set gross_principal_kobo=299999 where funding_intent_id=%L::uuid',current_setting('test.funding_intent')),
  '55000','principal_allocation_is_immutable','funded per-slot principal cannot be edited');
select throws_ok($$insert into app_private.funding_intents(
    poster_id,job_id,terms_version,gross_per_worker_kobo,slot_count,gross_total_kobo,
    currency,status,idempotency_key,request_sha256
  ) values(current_setting('test.partner_id')::uuid,'31000000-0000-4000-8000-000000000012',1,
    300000,3,899999,'NGN','pending','31000000-0000-4000-8000-000000000013',
    extensions.digest('mismatched total','sha256'))$$,'23514',null,
  'funding total must equal gross per worker multiplied by slots exactly');
select throws_ok($$insert into app_private.funding_intents(
    poster_id,job_id,terms_version,gross_per_worker_kobo,slot_count,gross_total_kobo,
    currency,status,idempotency_key,request_sha256
  ) values(current_setting('test.partner_id')::uuid,'31000000-0000-4000-8000-000000000014',1,
    100000001,1,100000001,'NGN','pending','31000000-0000-4000-8000-000000000015',
    extensions.digest('over local bound','sha256'))$$,'23514',null,
  'local funding records reject the approved per-worker bound plus one');
select lives_ok($$insert into app_private.funding_intents(
    poster_id,job_id,terms_version,gross_per_worker_kobo,slot_count,gross_total_kobo,
    currency,status,idempotency_key,request_sha256
  ) values(current_setting('test.partner_id')::uuid,'31000000-0000-4000-8000-000000000022',1,
    100000000,10,1000000000,'NGN','pending','31000000-0000-4000-8000-000000000023',
    extensions.digest('approved local maximum','sha256'))$$,
  'the local per-worker, ten-slot and total validation bounds include their approved maxima');
select throws_ok($$insert into app_private.funding_intents(
    poster_id,job_id,terms_version,gross_per_worker_kobo,slot_count,gross_total_kobo,
    currency,status,idempotency_key,request_sha256
  ) values(current_setting('test.partner_id')::uuid,'31000000-0000-4000-8000-000000000024',1,
    100000000,11,1100000000,'NGN','pending','31000000-0000-4000-8000-000000000025',
    extensions.digest('over slot bound','sha256'))$$,'23514',null,
  'the local funding table rejects more than ten slots');
select throws_ok($$insert into app_private.funding_intents(
    poster_id,job_id,terms_version,gross_per_worker_kobo,slot_count,gross_total_kobo,
    currency,status,idempotency_key,request_sha256
  ) values(current_setting('test.partner_id')::uuid,'31000000-0000-4000-8000-000000000026',1,
    300000,1,300000,'NGN','succeeded','31000000-0000-4000-8000-000000000027',
    extensions.digest('cannot seed funded state','sha256'))$$,'55000','funding_intent_must_start_pending',
  'funding intent cannot skip its pending and verified-result states');
select throws_ok($$insert into app_private.provider_operations(operation_type,provider_idempotency_key,
    actor_id,amount_kobo,currency,destination_id,destination_version,request_sha256,status)
  values('payout','31000000-0000-4000-8000-000000000028',current_setting('test.partner_id')::uuid,
    285000,'NGN','31000000-0000-4000-8000-000000000029',1,
    extensions.digest('cannot seed paid state','sha256'),'paid')$$,'55000','provider_operation_must_start_pending',
  'payout operation cannot be inserted directly as already paid');

select lives_ok(format($sql$
  insert into app_private.financial_authorizations(actor_id,action,amount_kobo,destination_id,
    destination_version,candidate_fingerprint_sha256,confirmation_method,proof_sha256,created_at,expires_at)
  values(%L::uuid,'request_withdrawal',285000,'31000000-0000-4000-8000-000000000020',1,null,
    'fresh_password',extensions.digest('synthetic proof','sha256'),now(),now()+interval '5 minutes')
$sql$,current_setting('test.partner_id')),
  'server-bound withdrawal proof records exact amount, destination version and five-minute expiry');
select is((select amount_kobo::text from app_private.financial_authorizations
  where actor_id=current_setting('test.partner_id')::uuid and action='request_withdrawal'
  order by created_at desc limit 1),'285000',
  'withdrawal proof is bound to the exact integer-kobo amount');
select is((select destination_version from app_private.financial_authorizations
  where actor_id=current_setting('test.partner_id')::uuid and action='request_withdrawal'
  order by created_at desc limit 1),1,
  'withdrawal proof is bound to one immutable destination version');
select throws_ok(format($sql$
  insert into app_private.financial_authorizations(actor_id,action,amount_kobo,destination_id,
    destination_version,candidate_fingerprint_sha256,confirmation_method,proof_sha256,created_at,expires_at)
  values(%L::uuid,'request_withdrawal',285000,'31000000-0000-4000-8000-000000000021',1,null,
    'fresh_password',extensions.digest('synthetic proof too long','sha256'),now(),now()+interval '5 minutes 1 second')
$sql$,current_setting('test.partner_id')),'23514',null,
  'proof cannot be valid beyond the approved five-minute lifetime');
select throws_ok(format($sql$
  insert into app_private.financial_authorizations(actor_id,action,amount_kobo,destination_id,
    destination_version,candidate_fingerprint_sha256,confirmation_method,proof_sha256,created_at,expires_at,consumed_at)
  values(%L::uuid,'request_withdrawal',285000,'31000000-0000-4000-8000-000000000030',1,null,
    'fresh_password',extensions.digest('cannot preconsume','sha256'),now(),now()+interval '5 minutes',now())
$sql$,current_setting('test.partner_id')),'55000','financial_authorization_must_start_unused',
  'a new sensitive-action proof cannot be pre-consumed');

set local role anon;
select throws_ok($$select * from app_private.ledger_accounts$$,'42501',null,
  'actual anon role cannot read private financial accounts');
reset role;
set local role authenticated;
select throws_ok($$select * from app_private.ledger_journal_entries$$,'42501',null,
  'actual authenticated role cannot read journal entries');
reset role;
set local role service_role;
select throws_ok($$select app_private.post_financial_journal(
  '31000000-0000-4000-8000-000000000099','service_role_attack',null,null,'[]'::jsonb
)$$,'42501',null,'actual generic service role cannot invoke the private posting function');
select throws_ok($$select * from app_private.provider_operations$$,'42501',null,
  'actual generic service role cannot inspect private provider operations');
reset role;

select * from finish();
rollback;
