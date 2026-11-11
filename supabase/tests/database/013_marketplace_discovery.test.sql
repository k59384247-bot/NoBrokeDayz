begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

select ok(to_regclass('public.jobs') is null and to_regclass('public.job_terms_versions') is null,
  'job records remain private after adding discovery');
select ok(not has_schema_privilege('anon','app_private','USAGE')
  and not has_schema_privilege('authenticated','app_private','USAGE')
  and not has_schema_privilege('service_role','app_private','USAGE'),
  'read commands do not open the private schema to API roles');
select ok(not has_function_privilege('anon',
    'public.server_discover_jobs_for_actor(uuid,jsonb,timestamptz,uuid,smallint)','EXECUTE')
  and not has_function_privilege('authenticated',
    'public.server_discover_jobs_for_actor(uuid,jsonb,timestamptz,uuid,smallint)','EXECUTE')
  and has_function_privilege('service_role',
    'public.server_discover_jobs_for_actor(uuid,jsonb,timestamptz,uuid,smallint)','EXECUTE'),
  'only the server gateway can invoke discovery');
select ok(not has_function_privilege('authenticated',
    'public.server_get_discoverable_job_detail_for_actor(uuid,uuid)','EXECUTE')
  and has_function_privilege('service_role',
    'public.server_get_discoverable_job_detail_for_actor(uuid,uuid)','EXECUTE'),
  'browser clients cannot query job detail through the gateway directly');
select ok(not has_function_privilege('authenticated',
    'public.server_get_my_funded_job_history(uuid,timestamptz,uuid,smallint)','EXECUTE')
  and has_function_privilege('service_role',
    'public.server_get_my_funded_job_history(uuid,timestamptz,uuid,smallint)','EXECUTE'),
  'owner history has its own server-only query');
select ok(not has_function_privilege('authenticated',
    'public.server_get_my_funded_job_detail_for_actor(uuid,uuid)','EXECUTE')
  and has_function_privilege('service_role',
    'public.server_get_my_funded_job_detail_for_actor(uuid,uuid)','EXECUTE'),
  'historical detail has an independent owner-only server query');
select ok(exists(select 1 from pg_catalog.pg_indexes
    where schemaname='app_private' and indexname='marketplace_job_terms_search_idx')
  and exists(select 1 from pg_catalog.pg_indexes
    where schemaname='app_private' and indexname='marketplace_job_terms_location_search_idx')
  and exists(select 1 from pg_catalog.pg_indexes
    where schemaname='app_private' and indexname='marketplace_jobs_available_campus_created_idx')
  and exists(select 1 from pg_catalog.pg_indexes
    where schemaname='app_private' and indexname='marketplace_allocations_unassigned_job_idx'),
  'search, stable ordering and open-slot counting have targeted indexes');

select set_config('test.poster',(
  select id::text from auth.users where email='phase2-trackb@identity.test'
),true);
select set_config('test.unverified',(
  select id::text from auth.users where email='phase2-owner@identity.test'
),true);
select set_config('test.student',(
  select id::text from auth.users where email='phase2-profileviewer@identity.test'
),true);
insert into app_private.identity_accounts(
  user_id,account_type,age_confirmed_at,age_policy_version,account_status,
  verification_track,verification_status
) values(current_setting('test.poster')::uuid,'partner',pg_catalog.now(),'marketplace-read-test-v1',
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
) values(current_setting('test.student')::uuid,'student',pg_catalog.now(),'marketplace-read-test-v1',
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

select set_config('test.terms',pg_catalog.jsonb_build_object(
  'title','Synthetic carry books task',
  'description','Carry books safely between the campus library and lecture halls.',
  'category_slug','errands','location_type','on_campus','location_detail','Main library',
  'gross_per_worker_kobo','300000','slot_count',3,
  'application_deadline_at',pg_catalog.to_char(pg_catalog.timezone('UTC',pg_catalog.now()+interval '2 days'),'YYYY-MM-DD"T"HH24:MI:SS')||'+00:00',
  'needed_by_at',pg_catalog.to_char(pg_catalog.timezone('UTC',pg_catalog.now()+interval '3 days'),'YYYY-MM-DD"T"HH24:MI:SS')||'+00:00',
  'start_requirements','Meet beside the library entrance','application_note','Bring a student card'
)::text,true);
select set_config('test.draft',public.server_create_job_draft_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.terms')::jsonb,
  '13000000-0000-4000-8000-000000000001'
)::text,true);
select set_config('test.job_id',current_setting('test.draft')::jsonb->>'job_id',true);
select set_config('test.unpublished_draft',public.server_create_job_draft_for_actor(
  current_setting('test.poster')::uuid,
  current_setting('test.terms')::jsonb || '{"title":"Synthetic unpublished task"}'::jsonb,
  '13000000-0000-4000-8000-000000000010'
)::text,true);
select set_config('test.funding',public.server_start_job_funding_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.job_id')::uuid,1,
  '13000000-0000-4000-8000-000000000002'
)::text,true);
select set_config('test.operation',current_setting('test.funding')::jsonb->>'operation_id',true);
select set_config('test.claim',app_private.claim_payment_operation_job(
  '13000000-0000-4000-8000-000000000003',30::smallint)::text,true);
select public.server_complete_job_funding_operation_for_runner(
  current_setting('test.operation')::uuid,
  (current_setting('test.claim')::jsonb->>'lease_token')::uuid,
  'succeeded','sim-'||(current_setting('test.funding')::jsonb->>'provider_idempotency_key'),
  '900000','NGN','fake_nbd_local_merchant_v1',
  (current_setting('test.funding')::jsonb->>'provider_idempotency_key')::uuid,
  '4500',null,false,pg_catalog.encode(extensions.digest('marketplace read fixture','sha256'),'hex')
);

select set_config('test.discovered',public.server_discover_jobs_for_actor(
  current_setting('test.poster')::uuid,'{}'::jsonb,null,null,21::smallint
)::text,true);
select is(pg_catalog.jsonb_array_length(current_setting('test.discovered')::jsonb),1,
  'only an exact funded, open, in-deadline listing with available slots is discoverable');
select is(current_setting('test.discovered')::jsonb->0->>'gross_per_worker_kobo','300000',
  'gross pay remains an integer-kobo JSON string');
select is(current_setting('test.discovered')::jsonb->0->>'commission_kobo','15000',
  'commission is exactly 500 basis points of awarded gross');
select is(current_setting('test.discovered')::jsonb->0->>'worker_net_kobo','285000',
  'detail summary shows exact worker net after commission');
select is((current_setting('test.discovered')::jsonb->0->>'slots_remaining')::integer,3,
  'all three funded slots are available before assignment');
select ok(not (current_setting('test.discovered')::jsonb->0 ? 'poster_email')
  and not (current_setting('test.discovered')::jsonb->0 ? 'provider_reference')
  and not (current_setting('test.discovered')::jsonb->0 ? 'bank_account_number'),
  'the public projection excludes private identity, provider and bank fields');
select ok(not exists(select 1 from pg_catalog.jsonb_array_elements(
    current_setting('test.discovered')::jsonb) r
  where r->>'job_id'=current_setting('test.unpublished_draft')::jsonb->>'job_id'),
  'an unfunded draft never appears beside a funded listing');
select is(pg_catalog.jsonb_array_length(public.server_discover_jobs_for_actor(
  current_setting('test.student')::uuid,'{}'::jsonb,null,null,21::smallint
)),1,'a currently qualified active student can discover the same available listing');
select is(public.server_get_discoverable_job_detail_for_actor(
  current_setting('test.student')::uuid,current_setting('test.job_id')::uuid
)->>'terms_version','1','a qualified student can read eligible job detail');
select is(pg_catalog.jsonb_array_length(public.server_get_my_funded_job_history(
  current_setting('test.student')::uuid,null,null,21::smallint
)),0,'a non-owner cannot see the poster funded-job history');
select throws_ok($$select public.server_get_my_funded_job_detail_for_actor(
  current_setting('test.student')::uuid,current_setting('test.job_id')::uuid
)$$,'P0002','job_not_found','a non-owner cannot read funded historical detail');

select set_config('test.filtered',public.server_discover_jobs_for_actor(
  current_setting('test.poster')::uuid,
  '{"keyword":"carry books","location":"Main library","category_slug":"errands","min_gross_kobo":"300000","location_type":"on_campus"}'::jsonb,
  null,null,21::smallint
)::text,true);
select is(pg_catalog.jsonb_array_length(current_setting('test.filtered')::jsonb),1,
  'keyword, category, gross pay and location filters combine without broadening row access');
select is(pg_catalog.jsonb_array_length(public.server_discover_jobs_for_actor(
  current_setting('test.poster')::uuid,'{"keyword":"chemistry"}'::jsonb,null,null,21::smallint
)),0,'full-text keyword filtering does not match unrelated descriptions');
select throws_ok($$select app_private.discover_jobs_for_actor(
  current_setting('test.poster')::uuid,'{"min_gross_kobo":300000}'::jsonb,null,null,21::smallint
)$$,'22023','invalid_marketplace_query',
  'database rejects numeric kobo filters rather than coercing browser numbers');
select throws_ok($$select public.server_discover_jobs_for_actor(
  current_setting('test.unverified')::uuid,'{}'::jsonb,null,null,21::smallint
)$$,'42501','marketplace_access_denied',
  'unverified identities cannot query discoverable jobs at the database boundary');

select set_config('test.detail',public.server_get_discoverable_job_detail_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.job_id')::uuid
)::text,true);
select is(current_setting('test.detail')::jsonb->>'terms_version','1',
  'job detail binds the exact immutable terms version');
select is(current_setting('test.detail')::jsonb->>'needed_by_at',
  (current_setting('test.terms')::jsonb->>'needed_by_at'),
  'job detail exposes needed-by separately from the application deadline');

insert into app_private.job_applications(
  application_id,job_id,worker_id,applied_terms_version,state,applied_at,decided_at,decided_by
) values
  ('14000000-0000-4000-8000-000000000001',current_setting('test.job_id')::uuid,
    current_setting('test.student')::uuid,1,'accepted',pg_catalog.now(),pg_catalog.now(),current_setting('test.poster')::uuid),
  ('14000000-0000-4000-8000-000000000002',current_setting('test.job_id')::uuid,
    (select id from auth.users where email='phase2-owner@identity.test'),1,'accepted',pg_catalog.now(),pg_catalog.now(),current_setting('test.poster')::uuid),
  ('14000000-0000-4000-8000-000000000003',current_setting('test.job_id')::uuid,
    (select id from auth.users where email='phase2-other@identity.test'),1,'accepted',pg_catalog.now(),pg_catalog.now(),current_setting('test.poster')::uuid);
insert into app_private.application_threads(application_id)
select application_id from app_private.job_applications
where job_id=current_setting('test.job_id')::uuid;
insert into app_private.assignments(
  assignment_id,application_id,job_id,worker_id,poster_id,allocation_id,
  funding_intent_id,terms_version,terms_sha256,gross_principal_kobo,commission_basis_points
)
select case pa.slot_number
    when 1 then '13000000-0000-4000-8000-000000000004'::uuid
    when 2 then '13000000-0000-4000-8000-000000000005'::uuid
    else '13000000-0000-4000-8000-000000000006'::uuid end,
  a.application_id,pa.job_id,a.worker_id,pa.poster_id,pa.allocation_id,
  pa.funding_intent_id,t.terms_version,t.terms_sha256,
  pa.gross_principal_kobo,pa.commission_basis_points
from app_private.principal_allocations pa
join app_private.job_terms_versions t
  on t.job_id=pa.job_id and t.terms_version=1
join app_private.job_applications a
  on a.job_id=pa.job_id and a.application_id=case pa.slot_number
    when 1 then '14000000-0000-4000-8000-000000000001'::uuid
    when 2 then '14000000-0000-4000-8000-000000000002'::uuid
    else '14000000-0000-4000-8000-000000000003'::uuid end
where pa.job_id=current_setting('test.job_id')::uuid;
update app_private.principal_allocations pa
set status='assigned',assignment_id=a.assignment_id
from app_private.assignments a
where a.allocation_id=pa.allocation_id and pa.slot_number=1
  and pa.job_id=current_setting('test.job_id')::uuid;
select set_config('test.partial',public.server_discover_jobs_for_actor(
  current_setting('test.poster')::uuid,'{}'::jsonb,null,null,21::smallint
)::text,true);
select is((current_setting('test.partial')::jsonb->0->>'slots_remaining')::integer,2,
  'a partial fill stays discoverable with only unassigned slots counted');
update app_private.principal_allocations pa
set status='assigned',assignment_id=a.assignment_id
from app_private.assignments a
where a.allocation_id=pa.allocation_id and pa.status='unassigned'
  and pa.job_id=current_setting('test.job_id')::uuid;
update app_private.jobs set listing_state='filled'
where job_id=current_setting('test.job_id')::uuid;
select is(pg_catalog.jsonb_array_length(public.server_discover_jobs_for_actor(
  current_setting('test.poster')::uuid,'{}'::jsonb,null,null,21::smallint
)),0,'a fully assigned listing is absent from discovery');
select is(pg_catalog.jsonb_array_length(public.server_discover_jobs_for_actor(
  current_setting('test.poster')::uuid,'{}'::jsonb,
  (select created_at-interval '1 microsecond' from app_private.jobs
    where job_id=current_setting('test.job_id')::uuid),
  '00000000-0000-0000-0000-000000000000'::uuid,21::smallint
)),0,'a stale cursor rechecks capacity and cannot return a job that filled after page one');
select is(public.server_get_my_funded_job_history(
  current_setting('test.poster')::uuid,null,null,21::smallint
)->0->>'history_state','filled',
  'the poster retains a separate funded history record after the last slot is assigned');
select set_config('test.filled_detail',public.server_get_my_funded_job_detail_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.job_id')::uuid
)::text,true);
select is(current_setting('test.filled_detail')::jsonb->>'history_state','filled',
  'a filled job remains inspectable through its separate owner detail query');
select is(current_setting('test.filled_detail')::jsonb->>'description',
  current_setting('test.terms')::jsonb->>'description',
  'owner history detail retains the immutable funded description');

update app_private.identity_accounts set account_status='suspended'
where user_id=current_setting('test.poster')::uuid;
select throws_ok($$select public.server_discover_jobs_for_actor(
  current_setting('test.poster')::uuid,'{}'::jsonb,null,null,21::smallint
)$$,'42501','marketplace_access_denied',
  'the same actor token loses discovery immediately after suspension');
select is(pg_catalog.jsonb_array_length(public.server_get_my_funded_job_history(
  current_setting('test.poster')::uuid,null,null,21::smallint
)),1,'the owner can still inspect their own funded history while suspended');
select is(public.server_get_my_funded_job_detail_for_actor(
  current_setting('test.poster')::uuid,current_setting('test.job_id')::uuid
)->>'history_state','filled',
  'suspension does not erase the owner’s read-only funded history');
update app_private.identity_accounts set account_status='active'
where user_id=current_setting('test.poster')::uuid;

select throws_ok(format($sql$
  update app_private.jobs set listing_state='cancelled' where job_id=%L::uuid
$sql$,current_setting('test.job_id')),'55000','invalid_job_state_transition',
  'cancellation remains disabled at the database transition boundary');

select * from finish();
rollback;
