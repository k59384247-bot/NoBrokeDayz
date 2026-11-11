begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

select ok(to_regclass('app_private.wallet_destinations') is not null
  and to_regclass('app_private.wallet_destination_versions') is not null
  and to_regclass('app_private.withdrawal_requests') is not null
  and to_regclass('app_private.withdrawal_source_allocations') is not null,
  'wallet recipients, versions, payout requests and source allocations are private records');
select ok(to_regclass('public.wallet_destinations') is null
  and to_regclass('public.withdrawal_requests') is null
  and not has_table_privilege('anon','app_private.withdrawal_requests','SELECT')
  and not has_table_privilege('authenticated','app_private.withdrawal_requests','SELECT')
  and not has_table_privilege('service_role','app_private.withdrawal_requests','SELECT'),
  'wallet and payout tables cannot be read through ordinary or generic service access');
select ok(not has_function_privilege('anon',
      'public.server_request_withdrawal_for_actor(uuid,text,uuid,integer,text,text,uuid)','EXECUTE')
  and not has_function_privilege('authenticated',
      'public.server_request_withdrawal_for_actor(uuid,text,uuid,integer,text,text,uuid)','EXECUTE')
  and has_function_privilege('service_role',
      'public.server_request_withdrawal_for_actor(uuid,text,uuid,integer,text,text,uuid)','EXECUTE')
  and not has_function_privilege('authenticated',
      'public.server_complete_worker_payout_for_runner(uuid,uuid,text,text,text,text,uuid,uuid,integer,text,text,boolean,text)','EXECUTE')
  and has_function_privilege('service_role',
      'public.server_complete_worker_payout_for_runner(uuid,uuid,text,text,text,text,uuid,uuid,integer,text,text,boolean,text)','EXECUTE'),
  'actor commands and provider completion use only the service-only actor-checked gateway');
select ok(to_regprocedure('public.server_set_withdrawal_paid(uuid)') is null
  and to_regprocedure('public.server_seed_wallet_balance(uuid,text)') is null,
  'there is no application shortcut to mark a payout paid or seed spendable balance');

select set_config('test.poster',(
  select id::text from auth.users where email='phase2-trackb@identity.test'
),true);
select set_config('test.worker',(
  select id::text from auth.users where email='phase2-profileviewer@identity.test'
),true);
select set_config('test.other',(
  select id::text from auth.users where email='phase2-owner@identity.test'
),true);
insert into app_private.identity_accounts(
  user_id,account_type,age_confirmed_at,age_policy_version,account_status,
  verification_track,verification_status
) values(current_setting('test.poster')::uuid,'partner',pg_catalog.now(),'wallet-test-v1',
  'active','track_b_partner','approved')
on conflict(user_id) do update set account_type='partner',account_status='active',
  verification_track='track_b_partner',verification_status='approved',
  age_confirmed_at=coalesce(app_private.identity_accounts.age_confirmed_at,excluded.age_confirmed_at);
insert into app_private.identity_capabilities(user_id,capability,source)
values(current_setting('test.poster')::uuid,'can_hire','track_b_partner')
on conflict(user_id,capability) do update set source=excluded.source,revoked_at=null;
insert into app_private.identity_phone_bindings(user_id,phone_e164,verified_at)
select u.id,'+2347000000098',u.phone_confirmed_at from auth.users u
where u.id=current_setting('test.poster')::uuid
on conflict(user_id) do update set phone_e164=excluded.phone_e164,verified_at=excluded.verified_at;
insert into app_private.identity_accounts(
  user_id,account_type,age_confirmed_at,age_policy_version,account_status,
  verification_track,verification_status
) values(current_setting('test.worker')::uuid,'student',pg_catalog.now(),'wallet-test-v1',
  'active','track_a_manual','approved')
on conflict(user_id) do update set account_type='student',account_status='active',
  verification_track='track_a_manual',verification_status='approved',
  age_confirmed_at=coalesce(app_private.identity_accounts.age_confirmed_at,excluded.age_confirmed_at);
insert into app_private.identity_capabilities(user_id,capability,source)
values(current_setting('test.worker')::uuid,'can_work','track_a_manual')
on conflict(user_id,capability) do update set source=excluded.source,revoked_at=null;
insert into app_private.identity_phone_bindings(user_id,phone_e164,verified_at)
select u.id,'+2347000000100',u.phone_confirmed_at from auth.users u
where u.id=current_setting('test.worker')::uuid
on conflict(user_id) do update set phone_e164=excluded.phone_e164,verified_at=excluded.verified_at;

select set_config('test.terms',pg_catalog.jsonb_build_object(
  'title','Synthetic wallet work','description','A bounded local wallet fixture job.',
  'category_slug','errands','location_type','on_campus','location_detail','Main library',
  'gross_per_worker_kobo','300000','slot_count',1,
  'application_deadline_at',pg_catalog.to_char(pg_catalog.timezone('UTC',pg_catalog.now()+interval '2 days'),'YYYY-MM-DD"T"HH24:MI:SS')||'+00:00',
  'needed_by_at',pg_catalog.to_char(pg_catalog.timezone('UTC',pg_catalog.now()+interval '3 days'),'YYYY-MM-DD"T"HH24:MI:SS')||'+00:00',
  'start_requirements','Meet beside the library entrance'
)::text,true);

select set_config('test.draft1',public.server_create_job_draft_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.terms')::jsonb,
  '15000000-0000-4000-8000-000000000001')::text,true);
select set_config('test.job1',current_setting('test.draft1')::jsonb->>'job_id',true);
select set_config('test.funding1',public.server_start_job_funding_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.job1')::uuid,1,
  '15000000-0000-4000-8000-000000000002')::text,true);
select set_config('test.op1',current_setting('test.funding1')::jsonb->>'operation_id',true);
select set_config('test.claim1',app_private.claim_payment_operation_job(
  '15000000-0000-4000-8000-000000000003',30::smallint)::text,true);
select public.server_complete_job_funding_with_settlement_for_runner(
  current_setting('test.op1')::uuid,(current_setting('test.claim1')::jsonb->>'lease_token')::uuid,
  'succeeded','sim-'||(current_setting('test.funding1')::jsonb->>'provider_idempotency_key'),
  '300000','NGN','fake_nbd_local_merchant_v1',
  (current_setting('test.funding1')::jsonb->>'provider_idempotency_key')::uuid,
  '1500',null,false,pg_catalog.encode(extensions.digest('wallet test collection one','sha256'),'hex'),
  'available');

select set_config('test.draft2',public.server_create_job_draft_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.terms')::jsonb,
  '15000000-0000-4000-8000-000000000004')::text,true);
select set_config('test.job2',current_setting('test.draft2')::jsonb->>'job_id',true);
select set_config('test.funding2',public.server_start_job_funding_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.job2')::uuid,1,
  '15000000-0000-4000-8000-000000000005')::text,true);
select set_config('test.op2',current_setting('test.funding2')::jsonb->>'operation_id',true);
select set_config('test.claim2',app_private.claim_payment_operation_job(
  '15000000-0000-4000-8000-000000000006',30::smallint)::text,true);
select public.server_complete_job_funding_with_settlement_for_runner(
  current_setting('test.op2')::uuid,(current_setting('test.claim2')::jsonb->>'lease_token')::uuid,
  'succeeded','sim-'||(current_setting('test.funding2')::jsonb->>'provider_idempotency_key'),
  '300000','NGN','fake_nbd_local_merchant_v1',
  (current_setting('test.funding2')::jsonb->>'provider_idempotency_key')::uuid,
  '1500',null,false,pg_catalog.encode(extensions.digest('wallet test collection two','sha256'),'hex'),
  'available');

select set_config('test.application',public.server_apply_to_job_for_actor(
  current_setting('test.worker')::uuid,current_setting('test.job1')::uuid,
  null,'15000000-0000-4000-8000-000000000007')::text,true);
select set_config('test.accepted',public.server_accept_application_for_actor(
  current_setting('test.poster')::uuid,
  (current_setting('test.application')::jsonb->>'application_id')::uuid,
  '15000000-0000-4000-8000-000000000008')::text,true);
select set_config('test.assignment',current_setting('test.accepted')::jsonb->>'assignment_id',true);
select public.server_start_assignment_for_actor(current_setting('test.worker')::uuid,
  current_setting('test.assignment')::uuid,'15000000-0000-4000-8000-000000000009');
select public.server_submit_assignment_for_actor(current_setting('test.worker')::uuid,
  current_setting('test.assignment')::uuid,'15000000-0000-4000-8000-000000000010');
select public.server_confirm_completion_for_actor(current_setting('test.poster')::uuid,
  current_setting('test.assignment')::uuid,'15000000-0000-4000-8000-000000000011');

select is((public.server_get_my_wallet_for_actor(current_setting('test.worker')::uuid,null,null)
  ->'balances'->>'available_earnings_kobo'),'285000',
  'wallet projects NGN 2,850 released earnings as an integer-kobo string');
select is((public.server_get_my_wallet_for_actor(current_setting('test.poster')::uuid,null,null)
  ->'balances'->>'poster_held_principal_kobo'),'300000',
  'poster wallet keeps another job principal separately reserved');
select ok((public.server_get_my_wallet_for_actor(current_setting('test.worker')::uuid,null,null)
  ->'activity' @> '[{"activity_type":"earnings_released","amount_kobo":"285000","commission_kobo":"15000"}]'::jsonb),
  'wallet history reports net earnings and the separate 500-basis-point commission');

select set_config('test.proof_initial',
  pg_catalog.encode(extensions.digest('wallet destination proof','sha256'),'hex'),true);
select set_config('test.destination_authorization',public.server_authorize_simulated_destination_change_for_actor(
  current_setting('test.worker')::uuid,null,0,'fake_recipient_alpha',
  current_setting('test.proof_initial'))::text,true);
select set_config('test.destination_id',
  current_setting('test.destination_authorization')::jsonb->>'destination_id',true);
select throws_ok(format($sql$
  select public.server_confirm_simulated_destination_change_for_actor(%L::uuid,%L,'fake_recipient_beta',%L::uuid)
$sql$,current_setting('test.worker'),current_setting('test.proof_initial'),
  '15000000-0000-4000-8000-000000000012'),
  'P0001','confirmation_required','destination proof binds the exact synthetic recipient');
select set_config('test.destination_v1',public.server_confirm_simulated_destination_change_for_actor(
  current_setting('test.worker')::uuid,current_setting('test.proof_initial'),'fake_recipient_alpha',
  '15000000-0000-4000-8000-000000000013')::text,true);
select is(current_setting('test.destination_v1')::jsonb->>'destination_version','1',
  'first synthetic destination is versioned and owned by the actor');
select is(current_setting('test.destination_v1')::jsonb->>'ownership_verification','simulator_only',
  'destination ownership is explicitly a simulator-only fact');
select throws_ok(format($sql$
  update app_private.wallet_destination_versions set recipient_label='Changed'
  where destination_id=%L::uuid and version=1
$sql$,current_setting('test.destination_id')),
  '55000','financial_record_is_immutable','old destination versions cannot be edited');
select throws_ok(format($sql$
  select public.server_authorize_withdrawal_for_actor(%L::uuid,'285000',%L::uuid,1,%L)
$sql$,current_setting('test.poster'),current_setting('test.destination_id'),
  pg_catalog.encode(extensions.digest('partner must not withdraw worker earnings','sha256'),'hex')),
  '42501','verification_required','a poster account without worker capability cannot withdraw earnings');
select throws_ok(format($sql$
  select public.server_authorize_withdrawal_for_actor(%L::uuid,'1000000001',%L::uuid,1,%L)
$sql$,current_setting('test.worker'),current_setting('test.destination_id'),
  pg_catalog.encode(extensions.digest('too large','sha256'),'hex')),
  '22023','invalid_wallet_request','the local maximum is enforced in integer kobo at the command boundary');

select set_config('test.old_proof',
  pg_catalog.encode(extensions.digest('withdrawal old destination proof','sha256'),'hex'),true);
select public.server_authorize_withdrawal_for_actor(current_setting('test.worker')::uuid,
  '285000',current_setting('test.destination_id')::uuid,1,current_setting('test.old_proof'));
select throws_ok(format($sql$
  select public.server_request_withdrawal_for_actor(%L::uuid,'284999',%L::uuid,1,%L,'20000',%L::uuid)
$sql$,current_setting('test.worker'),current_setting('test.destination_id'),current_setting('test.old_proof'),
  '15000000-0000-4000-8000-000000000014'),
  'P0001','confirmation_required','withdrawal confirmation binds the exact requested amount');
insert into app_private.financial_authorizations(
  actor_id,action,amount_kobo,destination_id,destination_version,confirmation_method,
  proof_sha256,created_at,expires_at
) values(current_setting('test.worker')::uuid,'request_withdrawal',285000,
  current_setting('test.destination_id')::uuid,1,'fresh_password',
  extensions.digest('expired withdrawal proof','sha256'),pg_catalog.now()-interval '6 minutes',
  pg_catalog.now()-interval '1 minute');
select throws_ok(format($sql$
  select public.server_request_withdrawal_for_actor(%L::uuid,'285000',%L::uuid,1,%L,'20000',%L::uuid)
$sql$,current_setting('test.worker'),current_setting('test.destination_id'),
  pg_catalog.encode(extensions.digest('expired withdrawal proof','sha256'),'hex'),
  '15000000-0000-4000-8000-000000000015'),
  'P0001','confirmation_expired','a five-minute step-up proof cannot be used after expiry');

select set_config('test.proof_change',
  pg_catalog.encode(extensions.digest('wallet destination change proof','sha256'),'hex'),true);
select set_config('test.change_authorization',public.server_authorize_simulated_destination_change_for_actor(
  current_setting('test.worker')::uuid,current_setting('test.destination_id')::uuid,1,
  'fake_recipient_beta',current_setting('test.proof_change'))::text,true);
select public.server_confirm_simulated_destination_change_for_actor(current_setting('test.worker')::uuid,
  current_setting('test.proof_change'),'fake_recipient_beta','15000000-0000-4000-8000-000000000016');
select throws_ok(format($sql$
  select public.server_request_withdrawal_for_actor(%L::uuid,'285000',%L::uuid,1,%L,'20000',%L::uuid)
$sql$,current_setting('test.worker'),current_setting('test.destination_id'),current_setting('test.old_proof'),
  '15000000-0000-4000-8000-000000000017'),
  'P0002','destination_not_found','withdrawal proof cannot retarget a newer destination version');
select is((public.server_get_my_wallet_for_actor(current_setting('test.worker')::uuid,null,null)
  ->'destination'->>'destination_version'),'2',
  'wallet shows only the new active version while old history remains immutable');

select set_config('test.proof_withdrawal',
  pg_catalog.encode(extensions.digest('wallet destination version two proof','sha256'),'hex'),true);
select public.server_authorize_withdrawal_for_actor(current_setting('test.worker')::uuid,
  '285000',current_setting('test.destination_id')::uuid,2,current_setting('test.proof_withdrawal'));
select set_config('test.withdrawal',public.server_request_withdrawal_for_actor(
  current_setting('test.worker')::uuid,'285000',current_setting('test.destination_id')::uuid,2,
  current_setting('test.proof_withdrawal'),'20000','15000000-0000-4000-8000-000000000019')::text,true);
select is(current_setting('test.withdrawal')::jsonb->>'status','queued_for_liquidity',
  'valid earnings stay visibly queued when the exact platform fee reserve is not yet available');
select is((public.server_get_my_wallet_for_actor(current_setting('test.worker')::uuid,null,null)
  ->'balances'->>'available_earnings_kobo'),'0',
  'withdrawal reservation removes the request from spendable earnings atomically');
select is((public.server_get_my_wallet_for_actor(current_setting('test.worker')::uuid,null,null)
  ->'balances'->>'withdrawal_reserved_kobo'),'285000',
  'the exact worker net remains reserved while queued for liquidity');
select is((public.server_get_my_wallet_for_actor(current_setting('test.worker')::uuid,null,null)
  ->'balances'->>'withdrawal_queued_kobo'),'285000',
  'wallet status exposes the queued withdrawal separately from other balances');
select is((select count(*)::integer from app_private.withdrawal_source_allocations
  where withdrawal_id=(current_setting('test.withdrawal')::jsonb->>'withdrawal_id')::uuid),1,
  'the reservation retains its original assignment allocation source');
select is(public.server_claim_payment_operation_for_runner(
  '15000000-0000-4000-8000-000000000021',30::smallint),null::jsonb,
  'payment runner cannot claim or dispatch the queued payout without sufficient liquidity');
select app_private.post_financial_journal('15000000-0000-4000-8000-000000000018',
  'platform_capital_contribution',null,null,pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object('account_code','platform_fee_reserve_cash','direction','debit','amount_kobo','8000'),
    pg_catalog.jsonb_build_object('account_code','platform_capital_contributed','direction','credit','amount_kobo','8000')));
select is((select balance_kobo::text from app_private.ledger_account_balances b
  join app_private.ledger_accounts a using(account_id)
  where a.account_code='platform_fee_reserve_cash' and b.owner_id is null and b.allocation_id is null),
  '8000','the explicitly recorded platform reserve is separate until the queued payout is claimed');

select is(public.server_request_withdrawal_for_actor(current_setting('test.worker')::uuid,
  '285000',current_setting('test.destination_id')::uuid,2,current_setting('test.proof_withdrawal'),
  '20000','15000000-0000-4000-8000-000000000019')->>'withdrawal_id',
  current_setting('test.withdrawal')::jsonb->>'withdrawal_id',
  'identical withdrawal retries return the original durable operation');
select throws_ok(format($sql$
  select public.server_request_withdrawal_for_actor(%L::uuid,'284999',%L::uuid,2,%L,'20000',%L::uuid)
$sql$,current_setting('test.worker'),current_setting('test.destination_id'),current_setting('test.proof_withdrawal'),
  '15000000-0000-4000-8000-000000000019'),
  '23505','idempotency_conflict','an altered amount cannot reuse a withdrawal key');
select throws_ok(format($sql$
  select public.server_request_withdrawal_for_actor(%L::uuid,'285000',%L::uuid,2,%L,'20000',%L::uuid)
$sql$,current_setting('test.worker'),current_setting('test.destination_id'),current_setting('test.proof_withdrawal'),
  '15000000-0000-4000-8000-000000000020'),
  'P0001','confirmation_required','one-use confirmation cannot authorize a second withdrawal');

select set_config('test.payout_operation',(
  select operation_id::text from app_private.withdrawal_requests
  where withdrawal_id=(current_setting('test.withdrawal')::jsonb->>'withdrawal_id')::uuid
),true);
select set_config('test.provider_key',(
  select provider_idempotency_key::text from app_private.provider_operations
  where operation_id=current_setting('test.payout_operation')::uuid
),true);
select set_config('test.payout_claim',public.server_claim_payment_operation_for_runner(
  '15000000-0000-4000-8000-000000000021',30::smallint)::text,true);
select is(current_setting('test.payout_claim')::jsonb->>'destination_version','2',
  'durable runner claim carries the immutable destination version');
select is((public.server_get_my_wallet_for_actor(current_setting('test.worker')::uuid,null,null)
  ->'withdrawals'->0->>'status'),'processing',
  'verified platform fee reserve moves the same queued operation to processing');
select is((select balance_kobo::text from app_private.ledger_account_balances b
  join app_private.ledger_accounts a using(account_id)
  where a.account_code='platform_fee_reserve_cash' and b.owner_id is null and b.allocation_id is null),
  '0','the exact fee reserve gap transfers only when the queued operation becomes dispatchable');
select set_config('test.paid',public.server_complete_worker_payout_for_runner(
  current_setting('test.payout_operation')::uuid,
  (current_setting('test.payout_claim')::jsonb->>'lease_token')::uuid,
  'succeeded','sim-'||current_setting('test.provider_key'),'285000','NGN',
  current_setting('test.provider_key')::uuid,current_setting('test.destination_id')::uuid,2,
  '20000',null,false,pg_catalog.encode(extensions.digest('exact fake payout receipt','sha256'),'hex'))::text,true);
select is(current_setting('test.paid')::jsonb->>'withdrawal_status','paid',
  'authoritative fake payout result completes the worker withdrawal once');
select is((select count(*)::integer from app_private.ledger_journal_transactions
  where effect_type='payout_settled' and reference_id=(current_setting('test.withdrawal')::jsonb->>'withdrawal_id')::uuid),1,
  'one payout has exactly one settlement journal');
select is((select sum(b.balance_kobo)::text from app_private.ledger_account_balances b
  join app_private.ledger_accounts a using(account_id)
  where a.account_code='worker_withdrawal_reserved' and b.owner_id=current_setting('test.worker')::uuid),
  '0','successful settlement clears only the reserved worker liability');
select is((select sum(b.balance_kobo)::text from app_private.ledger_account_balances b
  join app_private.ledger_accounts a using(account_id)
  where a.account_code='provider_available_cash' and b.owner_id is null and b.allocation_id is null),
  '300000','remaining provider cash exactly covers the other job principal');
select is((select sum(b.balance_kobo)::text from app_private.ledger_account_balances b
  join app_private.ledger_accounts a using(account_id)
  where a.account_code='provider_payout_fee_expense' and b.owner_id is null and b.allocation_id is null),
  '20000','payout cost is charged to platform expense and not worker earnings');
select is((public.server_get_my_wallet_for_actor(current_setting('test.worker')::uuid,null,null)
  ->'withdrawals'->0->>'status'),'paid','wallet history shows paid only after the verified result');

-- A provider reversal is authoritative only after the prior paid result. The
-- callback stores a receipt and wakes lookup; it never applies money itself.
select public.server_record_payment_simulator_receipt('PAYOUT_REV_0001',
  current_setting('test.provider_key')::uuid,'sim-'||current_setting('test.provider_key'),
  pg_catalog.encode(extensions.digest('simulated reversal receipt','sha256'),'hex'));
select set_config('test.reversal_claim',public.server_claim_payment_operation_for_runner(
  '15000000-0000-4000-8000-000000000022',30::smallint)::text,true);
select set_config('test.reversed',public.server_complete_worker_payout_for_runner(
  current_setting('test.payout_operation')::uuid,
  (current_setting('test.reversal_claim')::jsonb->>'lease_token')::uuid,
  'reversed','sim-'||current_setting('test.provider_key'),'285000','NGN',
  current_setting('test.provider_key')::uuid,current_setting('test.destination_id')::uuid,2,
  '20000',null,false,pg_catalog.encode(extensions.digest('authoritative fake reversal','sha256'),'hex'))::text,true);
select is(current_setting('test.reversed')::jsonb->>'withdrawal_status','reversed',
  'an observed reversal after payment restores the exact worker earnings once');
select is((public.server_get_my_wallet_for_actor(current_setting('test.worker')::uuid,null,null)
  ->'balances'->>'available_earnings_kobo'),'285000',
  'reversal restores the worker net without editing the original payout journal');
select is((select sum(b.balance_kobo)::text from app_private.ledger_account_balances b
  join app_private.ledger_accounts a using(account_id)
  where a.account_code='provider_available_cash' and b.owner_id is null and b.allocation_id is null),
  '585000','reversal returns payout principal but does not assume the provider fee was refunded');
select is((select sum(b.balance_kobo)::text from app_private.ledger_account_balances b
  join app_private.ledger_accounts a using(account_id)
  where a.account_code='provider_payout_fee_expense' and b.owner_id is null and b.allocation_id is null),
  '20000','provider fee remains a platform expense after payout reversal');
select is((select count(*)::integer from app_private.ledger_journal_transactions
  where effect_type='compensating_correction'
    and reference_id=(current_setting('test.withdrawal')::jsonb->>'withdrawal_id')::uuid),1,
  'reversal appends one compensating journal');

select app_private.post_financial_journal('15000000-0000-4000-8000-000000000029',
  'platform_capital_contribution',null,null,pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object('account_code','platform_fee_reserve_cash','direction','debit','amount_kobo','20000'),
    pg_catalog.jsonb_build_object('account_code','platform_capital_contributed','direction','credit','amount_kobo','20000')));

-- A known failure restores the reservation, and a timeout keeps it reserved
-- until a later lookup resolves the original provider operation.
select set_config('test.failure_proof',
  pg_catalog.encode(extensions.digest('known failure proof','sha256'),'hex'),true);
select public.server_authorize_withdrawal_for_actor(current_setting('test.worker')::uuid,
  '285000',current_setting('test.destination_id')::uuid,2,current_setting('test.failure_proof'));
select set_config('test.failure_request',public.server_request_withdrawal_for_actor(
  current_setting('test.worker')::uuid,'285000',current_setting('test.destination_id')::uuid,2,
  current_setting('test.failure_proof'),'20000','15000000-0000-4000-8000-000000000023')::text,true);
select set_config('test.failure_operation',(
  select operation_id::text from app_private.withdrawal_requests
  where withdrawal_id=(current_setting('test.failure_request')::jsonb->>'withdrawal_id')::uuid
),true);
select set_config('test.failure_key',(
  select provider_idempotency_key::text from app_private.provider_operations
  where operation_id=current_setting('test.failure_operation')::uuid
),true);
select set_config('test.failure_claim',public.server_claim_payment_operation_for_runner(
  '15000000-0000-4000-8000-000000000024',30::smallint)::text,true);
select set_config('test.failure_result',public.server_complete_worker_payout_for_runner(
  current_setting('test.failure_operation')::uuid,
  (current_setting('test.failure_claim')::jsonb->>'lease_token')::uuid,
  'failed','sim-'||current_setting('test.failure_key'),'285000','NGN',
  current_setting('test.failure_key')::uuid,current_setting('test.destination_id')::uuid,2,
  '20000',null,false,pg_catalog.encode(extensions.digest('simulated known payout failure','sha256'),'hex'))::text,true);
select is(current_setting('test.failure_result')::jsonb->>'withdrawal_status','failed',
  'known provider failure reaches the failed status after the original operation is checked');
select is((public.server_get_my_wallet_for_actor(current_setting('test.worker')::uuid,null,null)
  ->'balances'->>'available_earnings_kobo'),'285000',
  'known failure returns the reserved net to spendable earnings once');
select is((select sum(b.balance_kobo)::text from app_private.ledger_account_balances b
  join app_private.ledger_accounts a using(account_id)
  where a.account_code='provider_payout_fee_expense' and b.owner_id is null and b.allocation_id is null),
  '40000','the original and known-failure provider costs remain separate platform expenses');
select is((select count(*)::integer from app_private.ledger_journal_transactions
  where effect_type='compensating_correction'
    and reference_id=(current_setting('test.failure_request')::jsonb->>'withdrawal_id')::uuid),1,
  'known failure appends one compensating journal');

select app_private.post_financial_journal('15000000-0000-4000-8000-000000000025',
  'platform_capital_contribution',null,null,pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object('account_code','platform_fee_reserve_cash','direction','debit','amount_kobo','20000'),
    pg_catalog.jsonb_build_object('account_code','platform_capital_contributed','direction','credit','amount_kobo','20000')));
select set_config('test.unknown_proof',
  pg_catalog.encode(extensions.digest('unknown payout proof','sha256'),'hex'),true);
select public.server_authorize_withdrawal_for_actor(current_setting('test.worker')::uuid,
  '285000',current_setting('test.destination_id')::uuid,2,current_setting('test.unknown_proof'));
select set_config('test.unknown_request',public.server_request_withdrawal_for_actor(
  current_setting('test.worker')::uuid,'285000',current_setting('test.destination_id')::uuid,2,
  current_setting('test.unknown_proof'),'20000','15000000-0000-4000-8000-000000000026')::text,true);
select set_config('test.unknown_operation',(
  select operation_id::text from app_private.withdrawal_requests
  where withdrawal_id=(current_setting('test.unknown_request')::jsonb->>'withdrawal_id')::uuid
),true);
select set_config('test.unknown_key',(
  select provider_idempotency_key::text from app_private.provider_operations
  where operation_id=current_setting('test.unknown_operation')::uuid
),true);
select set_config('test.unknown_claim',public.server_claim_payment_operation_for_runner(
  '15000000-0000-4000-8000-000000000027',30::smallint)::text,true);
select set_config('test.unknown_result',public.server_complete_worker_payout_for_runner(
  current_setting('test.unknown_operation')::uuid,
  (current_setting('test.unknown_claim')::jsonb->>'lease_token')::uuid,
  'unknown',null,null,null,null,null,null,'0','provider_timeout',true,null)::text,true);
select is(current_setting('test.unknown_result')::jsonb->>'withdrawal_status','unknown',
  'provider acceptance with a lost response stays unknown');
select is((public.server_get_my_wallet_for_actor(current_setting('test.worker')::uuid,null,null)
  ->'balances'->>'available_earnings_kobo'),'0',
  'unknown payout does not restore spendable balance');
select is((public.server_get_my_wallet_for_actor(current_setting('test.worker')::uuid,null,null)
  ->'balances'->>'withdrawal_reserved_kobo'),'285000',
  'unknown payout keeps the exact worker amount reserved');
select is((select state from app_private.payment_operation_jobs
  where operation_id=current_setting('test.unknown_operation')::uuid),'retry',
  'unknown provider result leaves a durable bounded-retry job');
-- Each pgTAP file runs in one transaction, so transaction_timestamp() does
-- not advance during a sleep. This local fixture advances only the job's
-- scheduling timestamp to model the next poll after its bounded backoff.
update app_private.payment_operation_jobs set available_at=pg_catalog.now()-interval '1 second'
where operation_id=current_setting('test.unknown_operation')::uuid;
select set_config('test.lookup_claim',public.server_claim_payment_operation_for_runner(
  '15000000-0000-4000-8000-000000000028',30::smallint)::text,true);
select set_config('test.lookup_result',public.server_complete_worker_payout_for_runner(
  current_setting('test.unknown_operation')::uuid,
  (current_setting('test.lookup_claim')::jsonb->>'lease_token')::uuid,
  'succeeded','sim-'||current_setting('test.unknown_key'),'285000','NGN',
  current_setting('test.unknown_key')::uuid,current_setting('test.destination_id')::uuid,2,
  '20000',null,false,pg_catalog.encode(extensions.digest('original operation lookup succeeded','sha256'),'hex'))::text,true);
select is(current_setting('test.lookup_result')::jsonb->>'withdrawal_status','paid',
  'lookup resolves the original operation to paid without creating a new payout identity');
select is((select count(*)::integer from app_private.ledger_journal_transactions
  where effect_type='payout_settled'
    and reference_id=(current_setting('test.unknown_request')::jsonb->>'withdrawal_id')::uuid),1,
  'unknown recovery posts exactly one payout journal');
select is((select sum(b.balance_kobo)::text from app_private.ledger_account_balances b
  join app_private.ledger_accounts a using(account_id)
  where a.account_code='provider_payout_fee_expense' and b.owner_id is null and b.allocation_id is null),
  '60000','successful lookup adds the final payout fee without reducing worker receipt');
select is((select sum(b.balance_kobo)::text from app_private.ledger_account_balances b
  join app_private.ledger_accounts a using(account_id)
  where a.account_code='provider_available_cash' and b.owner_id is null and b.allocation_id is null),
  '300000','all other job principal remains in provider cash after failure, reversal and recovery');

-- Suspended actors keep their own safe financial status but cannot command a
-- new withdrawal; no destination, bank detail or action authority is restored.
update app_private.identity_accounts set account_status='suspended'
where user_id=current_setting('test.worker')::uuid;
select ok(public.server_get_my_wallet_for_actor(current_setting('test.worker')::uuid,null,null)
  ->'balances' is not null,'suspended verified account can read its own financial status');
select is(public.server_get_my_wallet_for_actor(current_setting('test.worker')::uuid,null,null)
  ->'destination','null'::jsonb,'suspended wallet projection hides the current recipient');
select throws_ok(format($sql$
  select public.server_authorize_withdrawal_for_actor(%L::uuid,'1',%L::uuid,2,%L)
$sql$,current_setting('test.worker'),current_setting('test.destination_id'),
  pg_catalog.encode(extensions.digest('suspended request','sha256'),'hex')),
  '42501','verification_required','suspension blocks destination authorization and withdrawals');

select * from finish();
rollback;
