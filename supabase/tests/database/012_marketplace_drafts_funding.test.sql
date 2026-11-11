begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

select ok(to_regclass('app_private.jobs') is not null,
  'jobs are stored in the private marketplace schema');
select ok(to_regclass('app_private.job_terms_versions') is not null,
  'each draft edit appends an immutable terms version');
select ok(to_regclass('app_private.marketplace_outbox') is not null,
  'marketplace commands append domain events to a private outbox');
select ok(to_regclass('public.jobs') is null and to_regclass('public.job_terms_versions') is null,
  'job and terms records are not exposed as public tables');
select ok(not has_schema_privilege('anon','app_private','USAGE')
  and not has_schema_privilege('authenticated','app_private','USAGE')
  and not has_schema_privilege('service_role','app_private','USAGE'),
  'ordinary API and generic service roles cannot enter the private schema');
select ok(not has_table_privilege('anon','app_private.jobs','SELECT')
  and not has_table_privilege('authenticated','app_private.jobs','SELECT')
  and not has_table_privilege('service_role','app_private.jobs','SELECT')
  and not has_table_privilege('service_role','app_private.job_terms_versions','INSERT'),
  'job data has no direct API or generic service access');
select ok(not has_function_privilege('authenticated',
    'public.server_create_job_draft_for_actor(uuid,jsonb,uuid)','EXECUTE')
  and has_function_privilege('service_role',
    'public.server_create_job_draft_for_actor(uuid,jsonb,uuid)','EXECUTE'),
  'only the authenticated Edge gateway can call the narrow create command');
select ok(not has_function_privilege('authenticated',
    'public.server_start_job_funding_for_actor(uuid,uuid,integer,uuid)','EXECUTE')
  and has_function_privilege('service_role',
    'public.server_start_job_funding_for_actor(uuid,uuid,integer,uuid)','EXECUTE'),
  'browser clients cannot create funding intents or operations');

select set_config('test.poster',(
  select id::text from auth.users where email='phase2-trackb@identity.test'
),true);
select set_config('test.unverified',(
  select id::text from auth.users where email='phase2-owner@identity.test'
),true);

insert into app_private.identity_accounts(
  user_id,account_type,age_confirmed_at,age_policy_version,account_status,
  verification_track,verification_status
) values(current_setting('test.poster')::uuid,'partner',now(),'local-test-v1','active',
  'track_b_partner','approved')
on conflict(user_id) do update set account_type='partner',age_confirmed_at=excluded.age_confirmed_at,
  account_status='active',verification_track='track_b_partner',verification_status='approved';
insert into app_private.identity_phone_bindings(user_id,phone_e164,verified_at)
select u.id,'+2347000000098',u.phone_confirmed_at from auth.users u
where u.id=current_setting('test.poster')::uuid
on conflict(user_id) do update set phone_e164=excluded.phone_e164,verified_at=excluded.verified_at;
insert into app_private.identity_capabilities(user_id,capability,source)
values(current_setting('test.poster')::uuid,'can_hire','track_b_partner')
on conflict(user_id,capability) do update set source=excluded.source,revoked_at=null;

select set_config('test.terms',pg_catalog.jsonb_build_object(
  'title','Synthetic campus task',
  'description','A bounded synthetic task for a local marketplace contract test.',
  'category_slug','errands',
  'location_type','on_campus',
  'location_detail','Student Centre',
  'gross_per_worker_kobo','300000',
  'slot_count',3,
  'application_deadline_at',pg_catalog.to_char(pg_catalog.timezone('UTC',pg_catalog.now()+interval '2 days'),'YYYY-MM-DD"T"HH24:MI:SS')||'+00:00',
  'needed_by_at',pg_catalog.to_char(pg_catalog.timezone('UTC',pg_catalog.now()+interval '3 days'),'YYYY-MM-DD"T"HH24:MI:SS')||'+00:00',
  'start_requirements','Meet at the main entrance',
  'application_note','Share relevant experience'
)::text,true);
select set_config('test.created',public.server_create_job_draft_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.terms')::jsonb,
  '12000000-0000-4000-8000-000000000001'
)::text,true);
select set_config('test.job',current_setting('test.created')::jsonb->>'job_id',true);
select is(current_setting('test.created')::jsonb->>'listing_state','draft',
  'draft creation creates no funded or discoverable listing');
select is(current_setting('test.created')::jsonb->>'gross_total_kobo','900000',
  'the server computes three NGN 3,000 slots as exactly NGN 9,000');
select is((current_setting('test.created')::jsonb->>'terms_version')::integer,1,
  'the initial draft is terms version one');
select is((select count(*)::integer from app_private.principal_allocations
  where job_id=current_setting('test.job')::uuid),0,
  'a draft does not allocate principal');

select is((public.server_create_job_draft_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.terms')::jsonb,
  '12000000-0000-4000-8000-000000000001'
)->>'job_id'),current_setting('test.job'),
  'an identical create retry returns the original draft');
select throws_ok($$select public.server_create_job_draft_for_actor(
  current_setting('test.poster')::uuid,
  current_setting('test.terms')::jsonb || '{"title":"Changed title"}'::jsonb,
  '12000000-0000-4000-8000-000000000001'
)$$,'23505','idempotency_conflict',
  'a create idempotency key cannot be reused with altered terms');
select throws_ok($$select public.server_create_job_draft_for_actor(
  current_setting('test.unverified')::uuid,current_setting('test.terms')::jsonb,
  '12000000-0000-4000-8000-000000000002'
)$$,'42501','marketplace_access_denied',
  'an unverified account cannot create a draft at the database command boundary');
select throws_ok($$select public.server_create_job_draft_for_actor(
  current_setting('test.poster')::uuid,
  current_setting('test.terms')::jsonb || '{"category_slug":"disabled-category"}'::jsonb,
  '12000000-0000-4000-8000-000000000003'
)$$,'22023','invalid_job_terms',
  'unknown and disabled categories are rejected');
select throws_ok($$select public.server_create_job_draft_for_actor(
  current_setting('test.poster')::uuid,
  current_setting('test.terms')::jsonb || '{"gross_per_worker_kobo":300000}'::jsonb,
  '12000000-0000-4000-8000-000000000004'
)$$,'22023','invalid_job_terms',
  'money JSON must be a decimal string rather than a JavaScript number');
select throws_ok($$select public.server_create_job_draft_for_actor(
  current_setting('test.poster')::uuid,
  current_setting('test.terms')::jsonb || '{"gross_per_worker_kobo":"9223372036854775808"}'::jsonb,
  '12000000-0000-4000-8000-000000000005'
)$$,'22023','invalid_job_terms',
  'overflow and values above the approved local validation bound are rejected');

select set_config('test.edited_terms',(current_setting('test.terms')::jsonb ||
  '{"description":"A revised but still bounded task for this local contract test."}'::jsonb)::text,true);
select set_config('test.updated',public.server_update_job_draft_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.job')::uuid,1,
  current_setting('test.edited_terms')::jsonb,
  '12000000-0000-4000-8000-000000000006'
)::text,true);
select is((current_setting('test.updated')::jsonb->>'terms_version')::integer,2,
  'draft editing appends terms version two');
select is((select count(*)::integer from app_private.job_terms_versions
  where job_id=current_setting('test.job')::uuid),2,
  'the prior draft terms remain stored');
select throws_ok(format($sql$
  update app_private.job_terms_versions set title='rewritten'
  where job_id=%L::uuid and terms_version=1
$sql$,current_setting('test.job')),'55000','job_terms_are_immutable',
  'a prior terms version cannot be changed in place');
select throws_ok($$select public.server_update_job_draft_for_actor(
  current_setting('test.unverified')::uuid,current_setting('test.job')::uuid,2,
  current_setting('test.edited_terms')::jsonb,
  '12000000-0000-4000-8000-000000000007'
)$$,'42501','marketplace_access_denied',
  'an unrelated actor cannot edit the poster draft');

update app_private.identity_accounts set account_status='suspended'
where user_id=current_setting('test.poster')::uuid;
select throws_ok($$select public.server_start_job_funding_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.job')::uuid,2,
  '12000000-0000-4000-8000-000000000013'
)$$,'42501','marketplace_access_denied',
  'a suspended poster loses funding capability on the next command');
update app_private.identity_accounts set account_status='active'
where user_id=current_setting('test.poster')::uuid;

select set_config('test.funding',public.server_start_job_funding_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.job')::uuid,2,
  '12000000-0000-4000-8000-000000000008'
)::text,true);
select set_config('test.intent',current_setting('test.funding')::jsonb->>'funding_intent_id',true);
select set_config('test.operation',current_setting('test.funding')::jsonb->>'operation_id',true);
select is(current_setting('test.funding')::jsonb->>'amount_kobo','900000',
  'funding intent binds the exact gross total');
select is(current_setting('test.funding')::jsonb->>'currency','NGN',
  'funding intent binds NGN currency');
select is(current_setting('test.funding')::jsonb->>'merchant_identity','fake_nbd_local_merchant_v1',
  'funding uses the explicitly synthetic local merchant identity');
select is((select listing_state from app_private.jobs where job_id=current_setting('test.job')::uuid),
  'awaiting_payment','funding locks terms and leaves the listing unpublished while pending');
select is((select count(*)::integer from app_private.payment_operation_jobs q
  join app_private.provider_operations o using(operation_id)
  where o.operation_id=current_setting('test.operation')::uuid and q.state='queued'),1,
  'the stable collection operation is durably queued before its provider boundary');
select throws_ok($$select public.server_update_job_draft_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.job')::uuid,2,
  current_setting('test.terms')::jsonb,
  '12000000-0000-4000-8000-000000000009'
)$$,'P0001','stale_state',
  'price, slot and scope edits cannot reinterpret an active funding snapshot');
select is((public.server_start_job_funding_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.job')::uuid,2,
  '12000000-0000-4000-8000-000000000008'
)->>'funding_intent_id'),current_setting('test.intent'),
  'an identical funding retry returns the original operation identity');
select throws_ok($$select public.server_start_job_funding_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.job')::uuid,1,
  '12000000-0000-4000-8000-000000000008'
)$$,'23505','idempotency_conflict',
  'a funding idempotency key cannot be reused with altered terms version');

select set_config('test.claim',app_private.claim_payment_operation_job(
  '12000000-0000-4000-8000-000000000010',30::smallint)::text,true);
select is(current_setting('test.claim')::jsonb->>'merchant_identity',
  (select merchant_identity from app_private.provider_operations
    where operation_id=current_setting('test.operation')::uuid),
  'collection claim preserves the persisted merchant identity for runner validation');
select lives_ok(format($sql$
  select public.server_complete_job_funding_operation_for_runner(
    %L::uuid,%L::uuid,'succeeded',%L,'900000','NGN','fake_nbd_local_merchant_v1',
    %L::uuid,'4500',null,false,pg_catalog.encode(extensions.digest('exact simulator result','sha256'),'hex')
  )
$sql$,
  current_setting('test.operation'),current_setting('test.claim')::jsonb->>'lease_token',
  'sim-'||(current_setting('test.funding')::jsonb->>'provider_idempotency_key'),
  current_setting('test.funding')::jsonb->>'provider_idempotency_key'),
  'only the lease-bound exact simulator result can finalize funding');
select is((select listing_state from app_private.jobs where job_id=current_setting('test.job')::uuid),
  case when now() >= (select application_deadline_at from app_private.job_terms_versions
    where job_id=current_setting('test.job')::uuid and terms_version=2) then 'expired' else 'open' end,
  'exact funding publishes the job only if its application deadline is still open');
select is((select count(*)::integer from app_private.principal_allocations
  where funding_intent_id=current_setting('test.intent')::uuid),3,
  'one successful three-slot funding result creates three allocations');
select is((select sum(gross_principal_kobo)::bigint from app_private.principal_allocations
  where funding_intent_id=current_setting('test.intent')::uuid),900000::bigint,
  'per-slot principal conserves the exact poster total');
select is((select count(*)::integer from app_private.ledger_journal_transactions
  where effect_type='funding_collected'),1,
  'one successful result creates one funding journal');
select is((select collection_receivable_kobo from app_private.provider_liquidity_snapshot),895500::numeric,
  'provider net receipt remains a receivable until separate settlement evidence arrives');
select is((select sum(b.balance_kobo) from app_private.ledger_account_balances b
  join app_private.ledger_accounts a using(account_id)
  where a.account_code='provider_processing_fee_expense'),4500::numeric,
  'the collection processing fee is recorded separately as a platform expense');
select is((select count(*)::integer from app_private.marketplace_outbox
  where job_id=current_setting('test.job')::uuid and event_type='job.funded'),1,
  'funding publication and its durable event commit together');
update app_private.payment_operation_jobs set state='queued',attempt_count=0,
  available_at=pg_catalog.now()
where operation_id=current_setting('test.operation')::uuid;
select set_config('test.duplicate_claim',app_private.claim_payment_operation_job(
  '12000000-0000-4000-8000-000000000015',30::smallint)::text,true);
select lives_ok(format($sql$
  select public.server_complete_job_funding_operation_for_runner(
    %L::uuid,%L::uuid,'succeeded',%L,'900000','NGN','fake_nbd_local_merchant_v1',
    %L::uuid,'4500',null,false,pg_catalog.encode(extensions.digest('extra collection','sha256'),'hex')
  )
$sql$,
  current_setting('test.operation'),
  current_setting('test.duplicate_claim')::jsonb->>'lease_token',
  'sim-extra-'||(current_setting('test.funding')::jsonb->>'provider_idempotency_key'),
  current_setting('test.funding')::jsonb->>'provider_idempotency_key'),
  'an additional success with a new provider reference is retained for ops reconciliation');
select is((select count(*)::integer from app_private.financial_exceptions
  where operation_id=current_setting('test.operation')::uuid
    and exception_type='duplicate_collection'),1,
  'an extra collection is explicitly classified as a duplicate-collection exception');
select is((select safe_reference from app_private.financial_exceptions
  where operation_id=current_setting('test.operation')::uuid
    and exception_type='duplicate_collection' limit 1),
  'sim-extra-'||(current_setting('test.funding')::jsonb->>'provider_idempotency_key'),
  'the unexpected provider reference remains attached for reconciliation');
select is((select count(*)::integer from app_private.ledger_journal_transactions
  where effect_type='funding_collected'),1,
  'an extra collection does not post a second funding journal');
select is((select count(*)::integer from app_private.principal_allocations
  where funding_intent_id=current_setting('test.intent')::uuid),3,
  'an extra collection does not duplicate the original slot allocations');
update app_private.identity_accounts set account_status='suspended'
where user_id=current_setting('test.poster')::uuid;
select set_config('test.owner_status',public.server_get_job_funding_status_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.job')::uuid
)::text,true);
select is((current_setting('test.owner_status')::jsonb->>'expected_gross_kobo'),'900000',
  'a suspended owner can still read their own exact funding status');
select ok(not (current_setting('test.owner_status')::jsonb ? 'merchant_identity'),
  'the own-status projection does not disclose the fake merchant identity');
update app_private.identity_accounts set account_status='active'
where user_id=current_setting('test.poster')::uuid;
select throws_ok($$select public.server_get_job_funding_status_for_actor(
  current_setting('test.unverified')::uuid,current_setting('test.job')::uuid
)$$,'P0002','job_not_found',
  'another actor cannot inspect the poster funding status');
select throws_ok($$select public.server_update_job_draft_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.job')::uuid,2,
  current_setting('test.terms')::jsonb,
  '12000000-0000-4000-8000-000000000014'
)$$,'P0001','stale_state',
  'funded terms cannot be edited in place');

select set_config('test.mismatch_terms',(current_setting('test.terms')::jsonb ||
  '{"title":"Synthetic mismatch task","gross_per_worker_kobo":"300000","slot_count":1}'::jsonb)::text,true);
select set_config('test.mismatch_job',public.server_create_job_draft_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.mismatch_terms')::jsonb,
  '12000000-0000-4000-8000-000000000011'
)::text,true);
select set_config('test.mismatch_job_id',current_setting('test.mismatch_job')::jsonb->>'job_id',true);
select set_config('test.mismatch_funding',public.server_start_job_funding_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.mismatch_job_id')::uuid,1,
  '12000000-0000-4000-8000-000000000012'
)::text,true);
select set_config('test.mismatch_operation',current_setting('test.mismatch_funding')::jsonb->>'operation_id',true);
select set_config('test.mismatch_claim',app_private.claim_payment_operation_job(
  '12000000-0000-4000-8000-000000000013',30::smallint)::text,true);
select lives_ok(format($sql$
  select public.server_complete_job_funding_operation_for_runner(
    %L::uuid,%L::uuid,'succeeded',%L,'299999','NGN','fake_nbd_local_merchant_v1',
    %L::uuid,'0',null,false,pg_catalog.encode(extensions.digest('wrong gross','sha256'),'hex')
  )
$sql$,
  current_setting('test.mismatch_operation'),
  current_setting('test.mismatch_claim')::jsonb->>'lease_token',
  'sim-'||(current_setting('test.mismatch_funding')::jsonb->>'provider_idempotency_key'),
  current_setting('test.mismatch_funding')::jsonb->>'provider_idempotency_key'),
  'a simulator amount mismatch is parked as an ops exception rather than funded');
select is((select listing_state from app_private.jobs
  where job_id=current_setting('test.mismatch_job_id')::uuid),'awaiting_payment',
  'mismatched collection cannot publish the job');
select is((select count(*)::integer from app_private.principal_allocations
  where job_id=current_setting('test.mismatch_job_id')::uuid),0,
  'mismatched collection creates no allocation');
select is((select count(*)::integer from app_private.ledger_journal_transactions
  where reference_id=(current_setting('test.mismatch_funding')::jsonb->>'funding_intent_id')::uuid),0,
  'mismatched collection creates no funding journal');
select is((select count(*)::integer from app_private.financial_exceptions
  where operation_id=current_setting('test.mismatch_operation')::uuid
    and exception_type='amount_mismatch'),1,
  'mismatched amount creates one reconciliation exception');

select set_config('test.currency_terms',(current_setting('test.terms')::jsonb ||
  '{"title":"Synthetic currency mismatch task","slot_count":1}'::jsonb)::text,true);
select set_config('test.currency_job',public.server_create_job_draft_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.currency_terms')::jsonb,
  '12000000-0000-4000-8000-000000000025'
)::text,true);
select set_config('test.currency_job_id',current_setting('test.currency_job')::jsonb->>'job_id',true);
select set_config('test.currency_funding',public.server_start_job_funding_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.currency_job_id')::uuid,1,
  '12000000-0000-4000-8000-000000000026'
)::text,true);
select set_config('test.currency_operation',current_setting('test.currency_funding')::jsonb->>'operation_id',true);
select set_config('test.currency_claim',app_private.claim_payment_operation_job(
  '12000000-0000-4000-8000-000000000027',30::smallint)::text,true);
select lives_ok(format($sql$
  select public.server_complete_job_funding_operation_for_runner(
    %L::uuid,%L::uuid,'succeeded',%L,'300000','USD','fake_nbd_local_merchant_v1',
    %L::uuid,'0',null,false,pg_catalog.encode(extensions.digest('wrong currency','sha256'),'hex')
  )
$sql$,
  current_setting('test.currency_operation'),
  current_setting('test.currency_claim')::jsonb->>'lease_token',
  'sim-'||(current_setting('test.currency_funding')::jsonb->>'provider_idempotency_key'),
  current_setting('test.currency_funding')::jsonb->>'provider_idempotency_key'),
  'a successful collection in the wrong currency is retained as an exception');
select is((select count(*)::integer from app_private.financial_exceptions
  where operation_id=current_setting('test.currency_operation')::uuid
    and exception_type='currency_mismatch'),1,
  'wrong currency has a specific reconciliation exception');
select is((select count(*)::integer from app_private.principal_allocations
  where job_id=current_setting('test.currency_job_id')::uuid),0,
  'wrong currency creates no job allocation');

select set_config('test.reference_terms',(current_setting('test.terms')::jsonb ||
  '{"title":"Synthetic reference mismatch task","slot_count":1}'::jsonb)::text,true);
select set_config('test.reference_job',public.server_create_job_draft_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.reference_terms')::jsonb,
  '12000000-0000-4000-8000-000000000028'
)::text,true);
select set_config('test.reference_job_id',current_setting('test.reference_job')::jsonb->>'job_id',true);
select set_config('test.reference_funding',public.server_start_job_funding_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.reference_job_id')::uuid,1,
  '12000000-0000-4000-8000-000000000029'
)::text,true);
select set_config('test.reference_operation',current_setting('test.reference_funding')::jsonb->>'operation_id',true);
select set_config('test.reference_claim',app_private.claim_payment_operation_job(
  '12000000-0000-4000-8000-000000000030',30::smallint)::text,true);
select lives_ok(format($sql$
  select public.server_complete_job_funding_operation_for_runner(
    %L::uuid,%L::uuid,'succeeded',%L,'300000','NGN','fake_nbd_local_merchant_v1',
    %L::uuid,'0',null,false,pg_catalog.encode(extensions.digest('wrong reference','sha256'),'hex')
  )
$sql$,
  current_setting('test.reference_operation'),
  current_setting('test.reference_claim')::jsonb->>'lease_token',
  'sim-wrong-'||(current_setting('test.reference_funding')::jsonb->>'provider_idempotency_key'),
  current_setting('test.reference_funding')::jsonb->>'provider_idempotency_key'),
  'a success under an unexpected provider reference cannot fund the job');
select is((select count(*)::integer from app_private.financial_exceptions
  where operation_id=current_setting('test.reference_operation')::uuid
    and exception_type='reference_mismatch'),1,
  'wrong provider reference has a specific reconciliation exception');
select is((select count(*)::integer from app_private.principal_allocations
  where job_id=current_setting('test.reference_job_id')::uuid),0,
  'wrong provider reference creates no job allocation');

select set_config('test.merchant_terms',(current_setting('test.terms')::jsonb ||
  '{"title":"Synthetic merchant mismatch task","slot_count":1}'::jsonb)::text,true);
select set_config('test.merchant_job',public.server_create_job_draft_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.merchant_terms')::jsonb,
  '12000000-0000-4000-8000-000000000015'
)::text,true);
select set_config('test.merchant_job_id',current_setting('test.merchant_job')::jsonb->>'job_id',true);
select set_config('test.merchant_funding',public.server_start_job_funding_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.merchant_job_id')::uuid,1,
  '12000000-0000-4000-8000-000000000016'
)::text,true);
select set_config('test.merchant_operation',current_setting('test.merchant_funding')::jsonb->>'operation_id',true);
select set_config('test.merchant_claim',app_private.claim_payment_operation_job(
  '12000000-0000-4000-8000-000000000017',30::smallint)::text,true);
select lives_ok(format($sql$
  select public.server_complete_job_funding_operation_for_runner(
    %L::uuid,%L::uuid,'succeeded',%L,'300000','NGN','fake_wrong_merchant_v1',
    %L::uuid,'0',null,false,pg_catalog.encode(extensions.digest('wrong merchant','sha256'),'hex')
  )
$sql$,
  current_setting('test.merchant_operation'),
  current_setting('test.merchant_claim')::jsonb->>'lease_token',
  'sim-'||(current_setting('test.merchant_funding')::jsonb->>'provider_idempotency_key'),
  current_setting('test.merchant_funding')::jsonb->>'provider_idempotency_key'),
  'a collection from the wrong fake merchant is parked for reconciliation');
select is((select count(*)::integer from app_private.financial_exceptions
  where operation_id=current_setting('test.merchant_operation')::uuid
    and exception_type='merchant_mismatch'),1,
  'wrong merchant identity has one specifically categorized exception');
select is((select count(*)::integer from app_private.principal_allocations
  where job_id=current_setting('test.merchant_job_id')::uuid),0,
  'wrong merchant identity creates no job allocation');

select set_config('test.unknown_terms',(current_setting('test.terms')::jsonb ||
  '{"title":"Synthetic unknown task","slot_count":1}'::jsonb)::text,true);
select set_config('test.unknown_job',public.server_create_job_draft_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.unknown_terms')::jsonb,
  '12000000-0000-4000-8000-000000000018'
)::text,true);
select set_config('test.unknown_job_id',current_setting('test.unknown_job')::jsonb->>'job_id',true);
select set_config('test.unknown_funding',public.server_start_job_funding_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.unknown_job_id')::uuid,1,
  '12000000-0000-4000-8000-000000000019'
)::text,true);
select set_config('test.unknown_operation',current_setting('test.unknown_funding')::jsonb->>'operation_id',true);
select is((public.server_record_job_funding_unknown_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.unknown_operation')::uuid
)->>'status'),'unknown',
  'a collection initialization timeout is explicitly recorded as unknown');
select set_config('test.unknown_claim',app_private.claim_payment_operation_job(
  '12000000-0000-4000-8000-000000000020',30::smallint)::text,true);
select lives_ok(format($sql$
  select public.server_complete_job_funding_operation_for_runner(
    %L::uuid,%L::uuid,'unknown',null,null,null,null,null,'0','unknown_result',true,null
  )
$sql$,
  current_setting('test.unknown_operation'),
  current_setting('test.unknown_claim')::jsonb->>'lease_token'),
  'an unresolved result remains pending reconciliation after a runner lookup');
select is((select count(*)::integer from app_private.financial_exceptions
  where operation_id=current_setting('test.unknown_operation')::uuid
    and exception_type='unknown_result'),1,
  'unknown collection results create an ops reconciliation exception');
select is((select count(*)::integer from app_private.marketplace_outbox
  where job_id=current_setting('test.unknown_job_id')::uuid
    and event_type='job.funding_exception' and payload->>'reason'='unknown_result'),1,
  'unknown funding is durably published to the ops event outbox');
select is((select count(*)::integer from app_private.principal_allocations
  where job_id=current_setting('test.unknown_job_id')::uuid),0,
  'unknown collection results create no allocation');
select is((public.server_get_job_funding_status_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.unknown_job_id')::uuid
)->>'status'),'unknown',
  'the owner sees unresolved funding as unknown rather than success');

select set_config('test.failed_terms',(current_setting('test.terms')::jsonb ||
  '{"title":"Synthetic definitive failure task","slot_count":1}'::jsonb)::text,true);
select set_config('test.failed_job',public.server_create_job_draft_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.failed_terms')::jsonb,
  '12000000-0000-4000-8000-000000000021'
)::text,true);
select set_config('test.failed_job_id',current_setting('test.failed_job')::jsonb->>'job_id',true);
select set_config('test.failed_funding',public.server_start_job_funding_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.failed_job_id')::uuid,1,
  '12000000-0000-4000-8000-000000000022'
)::text,true);
select set_config('test.failed_operation',current_setting('test.failed_funding')::jsonb->>'operation_id',true);
select set_config('test.failed_claim',app_private.claim_payment_operation_job(
  '12000000-0000-4000-8000-000000000023',30::smallint)::text,true);
select lives_ok(format($sql$
  select public.server_complete_job_funding_operation_for_runner(
    %L::uuid,%L::uuid,'failed',%L,'300000','NGN','fake_nbd_local_merchant_v1',
    %L::uuid,'0',null,false,pg_catalog.encode(extensions.digest('definitive decline','sha256'),'hex')
  )
$sql$,
  current_setting('test.failed_operation'),
  current_setting('test.failed_claim')::jsonb->>'lease_token',
  'sim-'||(current_setting('test.failed_funding')::jsonb->>'provider_idempotency_key'),
  current_setting('test.failed_funding')::jsonb->>'provider_idempotency_key'),
  'only authoritative definitive failure returns an uncollected job to draft');
select is((select listing_state from app_private.jobs
  where job_id=current_setting('test.failed_job_id')::uuid),'draft',
  'definitive failure leaves the job unfunded and editable');
select is((select count(*)::integer from app_private.principal_allocations
  where job_id=current_setting('test.failed_job_id')::uuid),0,
  'definitive failure creates no principal allocations');
select set_config('test.retry_funding',public.server_start_job_funding_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.failed_job_id')::uuid,1,
  '12000000-0000-4000-8000-000000000024'
)::text,true);
select is((select attempt_number from app_private.funding_intents
  where intent_id=(current_setting('test.retry_funding')::jsonb->>'funding_intent_id')::uuid),2,
  'a new post-failure funding intent is a separately numbered second attempt');
select is((select a.attempt_number::integer from app_private.funding_attempts a
  where a.operation_id=(current_setting('test.retry_funding')::jsonb->>'operation_id')::uuid),2,
  'the funding attempt and new immutable intent use the same attempt number');
select isnt((current_setting('test.failed_funding')::jsonb->>'provider_idempotency_key'),
  (current_setting('test.retry_funding')::jsonb->>'provider_idempotency_key'),
  'a definitive failure retry gets a new stable provider idempotency key');

select finish();
rollback;
