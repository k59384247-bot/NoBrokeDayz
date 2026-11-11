begin;
create extension if not exists pgtap with schema extensions;
select plan(23);
select set_config('test.review_owner',(select id::text from auth.users where email='phase2-owner@identity.test'),true);
select set_config('test.review_other',(select id::text from auth.users where email='phase2-other@identity.test'),true);
select set_config('test.review_trackb',(select id::text from auth.users where email='phase2-trackb@identity.test'),true);
insert into app_private.identity_accounts(user_id,account_type,age_confirmed_at,age_policy_version)
values(current_setting('test.review_owner')::uuid,'student',now(),'age-18-v1'),(current_setting('test.review_other')::uuid,'student',now(),'age-18-v1')
on conflict(user_id) do nothing;
insert into app_private.staff_grants(user_id,capability,granted_by,reason)
values(current_setting('test.review_other')::uuid,'verification_review',current_setting('test.review_owner')::uuid,'Synthetic transaction scoped review grant.'),
      (current_setting('test.review_owner')::uuid,'verification_review',current_setting('test.review_other')::uuid,'Synthetic unassigned reviewer scope grant.');

set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.review_owner'),true);
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('test.review_submit',public.submit_my_verification('10000000-0000-0000-0000-000000000001',null,'Synthetic student fallback narrative suitable for review.',null)::text,true);
select is(public.submit_my_verification('10000000-0000-0000-0000-000000000001',null,'Synthetic student fallback narrative suitable for review.',null)->>'submission_id',current_setting('test.review_submit')::jsonb->>'submission_id','identical submit retry returns the same version');
select throws_ok($$select public.submit_my_verification('10000000-0000-0000-0000-000000000001',null,'Different synthetic student fallback narrative for this same request.',null)$$,'23505','idempotency_conflict','same submit key cannot silently change the request');
select is((current_setting('test.review_submit')::jsonb->>'status'),'pending','student fallback submission becomes pending');
select is(jsonb_array_length(public.get_my_verification_history()),1,'owner can inspect own submission history');
select set_config('request.jwt.claim.sub',current_setting('test.review_other'),true);
select is(jsonb_array_length(public.get_my_verification_history()),0,'another account cannot inspect the owner history');
select set_config('request.jwt.claim.sub',current_setting('test.review_owner'),true);
select throws_ok($$select * from app_private.verification_submissions$$,'42501',null,'authenticated clients cannot read private submissions');
reset role;

set local role service_role;
select set_config('test.review_submission',current_setting('test.review_submit')::jsonb->>'submission_id',true);
select is(jsonb_array_length(public.server_list_verification_assignment_candidates_for_actor(current_setting('test.review_other')::uuid,'aal2')),1,'current AAL2 reviewer sees minimal unassigned candidate');
select set_config('test.review_assignment',public.server_assign_verification_for_actor(current_setting('test.review_other')::uuid,current_setting('test.review_other')::uuid,current_setting('test.review_submission')::uuid,null,'Assign synthetic case for transaction tests.','aal2')->>'assignment_id',true);
select is(jsonb_array_length(public.server_list_verification_queue_for_actor(current_setting('test.review_other')::uuid,'aal2')),1,'assigned reviewer sees the detailed queue');
select is(jsonb_array_length(public.server_list_verification_queue_for_actor(current_setting('test.review_owner')::uuid,'aal2')),0,'granted reviewer cannot inspect a submission outside their assignment scope');
select throws_ok($$select public.server_list_verification_queue_for_actor(current_setting('test.review_other')::uuid,'aal1')$$,'42501',null,'AAL1 reviewer cannot inspect the queue');
select set_config('test.review_decision',public.server_review_verification_for_actor(current_setting('test.review_other')::uuid,current_setting('test.review_submission')::uuid,1,'pending',0,'needs_information','Please provide a clearer synthetic student ID image for this review.','20000000-0000-0000-0000-000000000001','aal2')::text,true);
select is((current_setting('test.review_decision')::jsonb->>'status'),'needs_information','assigned reviewer records a reasoned needs-information decision');
select is(public.server_review_verification_for_actor(current_setting('test.review_other')::uuid,current_setting('test.review_submission')::uuid,1,'pending',0,'needs_information','Please provide a clearer synthetic student ID image for this review.','20000000-0000-0000-0000-000000000001','aal2'),current_setting('test.review_decision')::jsonb,'same decision retry returns the committed result');
select is(public.server_review_verification_for_actor(current_setting('test.review_other')::uuid,current_setting('test.review_submission')::uuid,1,'pending',0,'rejected','Reject synthetic test request after stale expected status conflict.','20000000-0000-0000-0000-000000000002','aal2')->>'error','stale_state','contradictory stale decision is safely rejected');
reset role;
select is((select count(*)::integer from app_private.verification_reviews where submission_id=current_setting('test.review_submission')::uuid),1,'decision retry does not duplicate review history');
insert into app_private.identity_accounts(user_id,account_type,age_confirmed_at,age_policy_version)
values(current_setting('test.review_trackb')::uuid,'partner',now(),'age-18-v1')
on conflict(user_id) do nothing;
set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.review_trackb'),true);
select set_config('request.jwt.claim.role','authenticated',true);
select public.submit_my_verification('30000000-0000-0000-0000-000000000001','Synthetic Partner LLC','Synthetic partner submission narrative for human review.','shop_photo');
reset role;
select is((select track from app_private.verification_submissions where user_id=current_setting('test.review_trackb')::uuid),'track_b_partner','partner type always selects the human-reviewed Track B route');
select ok(not exists(select 1 from app_private.identity_capabilities where user_id=current_setting('test.review_trackb')::uuid and capability='can_work' and revoked_at is null),'partner submission cannot grant work capability');
select set_config('test.review_partner_submission',(select submission_id::text from app_private.verification_submissions where user_id=current_setting('test.review_trackb')::uuid),true);
select set_config('test.review_partner_assignment',public.server_assign_verification_for_actor(current_setting('test.review_other')::uuid,current_setting('test.review_other')::uuid,current_setting('test.review_partner_submission')::uuid,null,'Assign synthetic Track B file fixture for review.','aal2')->>'assignment_id',true);
insert into app_private.identity_phone_bindings(user_id,phone_e164,verified_at)
select id,case when phone like '+%' then phone else '+'||phone end,phone_confirmed_at from auth.users where id=current_setting('test.review_trackb')::uuid
on conflict(user_id) do update set phone_e164=excluded.phone_e164,verified_at=excluded.verified_at;
with fixture as (select gen_random_uuid() id)
insert into app_private.verification_evidence(evidence_id,submission_id,user_id,evidence_position,evidence_kind,object_key,storage_bucket,content_type,size_bytes,content_sha256,safety_state,finalized_at)
select id,current_setting('test.review_partner_submission')::uuid,current_setting('test.review_trackb')::uuid,1,'government_id',current_setting('test.review_trackb')||'/'||current_setting('test.review_partner_submission')||'/'||id||'/source','verification-private','application/pdf',100,extensions.digest(convert_to('synthetic test-only ready evidence','UTF8'),'sha256'),'ready',now() from fixture;
with fixture as (select gen_random_uuid() id)
insert into app_private.verification_evidence(evidence_id,submission_id,user_id,evidence_position,evidence_kind,object_key,storage_bucket,content_type,size_bytes,content_sha256,safety_state,finalized_at)
select id,current_setting('test.review_partner_submission')::uuid,current_setting('test.review_trackb')::uuid,2,'campus_shop_location',current_setting('test.review_trackb')||'/'||current_setting('test.review_partner_submission')||'/'||id||'/source','verification-private','image/png',100,extensions.digest(convert_to('synthetic test-only ready evidence','UTF8'),'sha256'),'ready',now() from fixture;
select ok(app_private.verification_submission_evidence_complete(current_setting('test.review_partner_submission')::uuid),'partner requires both ready government ID and selected campus connection evidence');
select set_config('test.review_partner_decision',public.server_review_verification_for_actor(current_setting('test.review_other')::uuid,current_setting('test.review_partner_submission')::uuid,1,'pending',0,'approved','Synthetic evidence requirements satisfied in transaction fixture.','40000000-0000-0000-0000-000000000001','aal2')::text,true);
select is((current_setting('test.review_partner_decision')::jsonb->>'status'),'approved','assigned reviewer can approve partner after required evidence is ready');
select ok(exists(select 1 from app_private.identity_capabilities where user_id=current_setting('test.review_trackb')::uuid and capability='can_hire' and source='track_b_partner' and revoked_at is null),'approved partner receives hire capability when current shared checks pass');
select ok(not exists(select 1 from app_private.identity_capabilities where user_id=current_setting('test.review_trackb')::uuid and capability='can_work' and revoked_at is null),'partner approval never grants work capability');
set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.review_owner'),true);
select public.submit_my_verification('10000000-0000-0000-0000-000000000002',null,'Synthetic student fallback resubmission version two for review.',null);
reset role;
select is((select count(*)::integer from app_private.verification_submissions where user_id=current_setting('test.review_owner')::uuid and track='track_a_manual'),2,'resubmission creates a second preserved version');
select is((select count(*)::integer from app_private.identity_outbox where subject_id=current_setting('test.review_owner')::uuid and event_type='verification_result'),3,'submission versions and committed review each retain notice requests');
select ok(not has_function_privilege('authenticated','public.server_review_verification_for_actor(uuid,uuid,integer,text,integer,text,text,uuid,text)','EXECUTE'),'browser cannot call the restricted review command');
select * from finish();
rollback;
