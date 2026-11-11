begin;
create extension if not exists pgtap with schema extensions;
select plan(21);
select set_config('test.staff_actor',(select id::text from auth.users where email='phase2-owner@identity.test'),true);
select set_config('test.staff_subject',(select id::text from auth.users where email='phase2-other@identity.test'),true);
insert into app_private.identity_accounts(user_id,account_type,age_confirmed_at,age_policy_version)
values(current_setting('test.staff_actor')::uuid,'student',now(),'age-18-v1'),(current_setting('test.staff_subject')::uuid,'student',now(),'age-18-v1')
on conflict(user_id) do nothing;
insert into public.profiles(user_id,display_name)
values(current_setting('test.staff_actor')::uuid,'Synthetic Reviewer'),(current_setting('test.staff_subject')::uuid,'Synthetic Subject')
on conflict(user_id) do nothing;
insert into app_private.staff_grants(user_id,capability,granted_by,reason)
values
 (current_setting('test.staff_actor')::uuid,'identity_suspend',current_setting('test.staff_actor')::uuid,'Synthetic local suspension test grant.'),
 (current_setting('test.staff_actor')::uuid,'identity_unsuspend',current_setting('test.staff_actor')::uuid,'Synthetic local unsuspension test grant.'),
 (current_setting('test.staff_actor')::uuid,'verification_review',current_setting('test.staff_actor')::uuid,'Synthetic local reviewer test grant.');

select ok(to_regprocedure('public.server_set_identity_suspension_for_actor(uuid,uuid,boolean,text,uuid,text)') is not null,'suspension is a narrow server-only command');
select ok(to_regprocedure('public.get_my_identity_help_context()') is not null,'suspended owners retain a narrow own-help command');
select ok(to_regclass('app_private.identity_suspension_events') is not null,'suspension changes keep private history');
select ok(has_function_privilege('service_role','public.server_set_identity_suspension_for_actor(uuid,uuid,boolean,text,uuid,text)','EXECUTE'),'server executor has the deliberate suspension RPC grant');
select ok(not has_function_privilege('authenticated','public.server_set_identity_suspension_for_actor(uuid,uuid,boolean,text,uuid,text)','EXECUTE'),'authenticated clients cannot call the suspension RPC');
select ok((select prosecdef and proconfig @> array['search_path=""']::text[] from pg_catalog.pg_proc where oid='public.server_set_identity_suspension_for_actor(uuid,uuid,boolean,text,uuid,text)'::regprocedure),'suspension RPC uses a fixed empty search path');
select ok(not has_schema_privilege('service_role','app_private','USAGE'),'server executor cannot directly read the private schema');
select ok(not has_table_privilege('authenticated','app_private.staff_grants','UPDATE'),'client cannot change staff grants directly');
select ok(has_function_privilege('authenticated','public.get_my_identity_help_context()','EXECUTE') and not has_function_privilege('anon','public.get_my_identity_help_context()','EXECUTE'),'only signed-in owners can use the narrow help route');
select ok(not exists(
  select 1 from pg_catalog.unnest(array[
    'app_private.audit_staff_grant_change()'::regprocedure,
    'public.current_user_account_active()'::regprocedure,
    'public.get_my_identity_help_context()'::regprocedure,
    'app_private.staff_actor_has_current_capability(uuid,text,text)'::regprocedure,
    'app_private.set_identity_suspension_for_actor(uuid,uuid,boolean,text,uuid,text)'::regprocedure,
    'public.server_set_identity_suspension_for_actor(uuid,uuid,boolean,text,uuid,text)'::regprocedure,
    'app_private.list_verification_candidates(uuid,text)'::regprocedure,
    'app_private.list_verification_queue(uuid,text)'::regprocedure,
    'app_private.reconcile_staff_access_after_auth_change()'::regprocedure
  ]) as f(oid)
  join pg_catalog.pg_proc p on p.oid=f.oid
  where p.prosecdef and not p.proconfig @> array['search_path=""']::text[]
),'all Step 8 security-definer helpers pin an empty search_path');

set local role service_role;
select set_config('test.staff_suspension_result',public.server_set_identity_suspension_for_actor(current_setting('test.staff_actor')::uuid,current_setting('test.staff_subject')::uuid,true,'Synthetic suspension reason for a local access test.','50000000-0000-0000-0000-000000000001','aal2')::text,true);
reset role;
select is((select account_status from app_private.identity_accounts where user_id=current_setting('test.staff_subject')::uuid),'suspended','authorized suspension changes current protected state');
select is((select count(*)::integer from app_private.identity_suspension_events where subject_id=current_setting('test.staff_subject')::uuid and action='suspended'),'1','suspension history is retained');
set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.staff_subject'),true);
select set_config('request.jwt.claim.role','authenticated',true);
select is((select count(*)::integer from public.profiles where user_id=auth.uid()),0,'suspension blocks direct profile access with the existing token');
select is(public.get_my_identity_help_context()->>'support_route_available','true','suspended owner can still reach own help route');
select ok(not has_table_privilege('authenticated','public.profiles','UPDATE'),'generic profile writes are revoked for all client tokens');
reset role;
select is((select display_name from public.profiles where user_id=current_setting('test.staff_subject')::uuid),'Synthetic Subject','suspension does not change or destroy profile data');

set local role service_role;
select public.server_set_identity_suspension_for_actor(current_setting('test.staff_actor')::uuid,current_setting('test.staff_subject')::uuid,false,'Synthetic unsuspension reason after local access test.','50000000-0000-0000-0000-000000000002','aal2');
reset role;
select is((select account_status from app_private.identity_accounts where user_id=current_setting('test.staff_subject')::uuid),'active','authorized unsuspension restores active status only');
select ok(exists(select 1 from app_private.identity_suspension_events where subject_id=current_setting('test.staff_subject')::uuid and action='unsuspended'),'unsuspension is retained in history');

update app_private.staff_grants set revoked_at=now(),revoked_by=current_setting('test.staff_actor')::uuid where user_id=current_setting('test.staff_actor')::uuid and capability='verification_review' and revoked_at is null;
set local role service_role;
select throws_ok($$select public.server_list_verification_assignment_candidates_for_actor(current_setting('test.staff_actor')::uuid,'aal2')$$,'42501',null,'revoked reviewer grant denies a still-valid AAL2 token');
reset role;
select ok(exists(select 1 from app_private.identity_audit_events where subject_id=current_setting('test.staff_subject')::uuid and event_type in ('identity_suspended','identity_unsuspended')),'suspension and unsuspension are audited');
select ok(exists(select 1 from app_private.identity_audit_events where subject_id=current_setting('test.staff_actor')::uuid and event_type='staff_grant_revoked'),'staff grant revocation is audited');
select * from finish();
rollback;
