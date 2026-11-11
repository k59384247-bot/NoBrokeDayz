begin;
create extension if not exists pgtap with schema extensions;
select plan(12);

select ok(to_regprocedure('public.submit_my_verification(uuid,text,text,text)') is not null, 'users can submit a server-derived track request');
select ok(to_regprocedure('public.get_my_verification_history()') is not null, 'users can inspect only their own verification history');
select ok(to_regprocedure('public.endorse_partner_verification(uuid,text)') is not null, 'a verified student can submit an attributable partner endorsement');
select ok(to_regclass('app_private.verification_review_assignments') is not null, 'review assignment history is protected');
select ok(to_regprocedure('public.server_list_verification_assignment_candidates_for_actor(uuid,text)') is not null, 'a current reviewer can list minimally disclosed unassigned submissions');
select ok(to_regprocedure('public.server_list_verification_queue_for_actor(uuid,text)') is not null, 'a reviewer can query only their current assigned queue');
select ok(to_regprocedure('public.server_assign_verification_for_actor(uuid,uuid,uuid,uuid,text,text)') is not null, 'review assignment is a restricted server command');
select ok(to_regprocedure('public.server_review_verification_for_actor(uuid,uuid,integer,text,integer,text,text,uuid,text)') is not null, 'review decisions use expected versions and idempotency');
select ok(to_regprocedure('public.server_begin_verification_upload_for_actor(uuid,uuid,smallint,text,integer,text,text)') is not null, 'verification uploads bind a required evidence purpose');
select ok(has_function_privilege('service_role','public.server_review_verification_for_actor(uuid,uuid,integer,text,integer,text,text,uuid,text)','EXECUTE'),'server executor has the narrow review RPC grant');
select ok(not has_function_privilege('authenticated','public.server_review_verification_for_actor(uuid,uuid,integer,text,integer,text,text,uuid,text)','EXECUTE'),'browser role cannot execute review RPC');
select ok((select prosecdef and proconfig @> array['search_path=""']::text[] from pg_catalog.pg_proc where oid='public.server_review_verification_for_actor(uuid,uuid,integer,text,integer,text,text,uuid,text)'::regprocedure),'review RPC is security-definer with fixed empty search path');

select * from finish();
rollback;
