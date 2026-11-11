begin;
create extension if not exists pgtap with schema extensions;
select plan(29);

select set_config('test.phone_limit_actor', (select id::text from auth.users where email='phase2-owner@identity.test'), true);
select set_config('test.phone_limit_other', (select id::text from auth.users where email='phase2-other@identity.test'), true);

select ok(to_regclass('app_private.identity_phone_sms_send_limits') is not null, 'phone send counters stay in the private schema');
select ok(to_regprocedure('public.server_reserve_phone_sms_send_for_actor(uuid,text,text)') is not null, 'the phone send reservation has a narrow server command');
select ok(has_function_privilege('service_role','public.server_reserve_phone_sms_send_for_actor(uuid,text,text)','EXECUTE'), 'the server executor has the explicit phone send reservation grant');
select ok(not has_function_privilege('authenticated','public.server_reserve_phone_sms_send_for_actor(uuid,text,text)','EXECUTE'), 'authenticated clients cannot reserve sends directly');
select ok(not has_function_privilege('anon','public.server_reserve_phone_sms_send_for_actor(uuid,text,text)','EXECUTE'), 'anonymous clients cannot reserve sends directly');
select ok(not has_schema_privilege('service_role','app_private','USAGE'), 'server executor has no broad private-schema access');
select ok(not has_table_privilege('anon','app_private.identity_phone_sms_send_limits','SELECT'), 'anonymous clients cannot read phone send counters');
select ok(not has_table_privilege('authenticated','app_private.identity_phone_sms_send_limits','SELECT'), 'authenticated clients cannot read phone send counters');
select ok(not has_table_privilege('service_role','app_private.identity_phone_sms_send_limits','SELECT'), 'server executor cannot read the private counter table');
select ok((select prosecdef and proconfig @> array['search_path=""']::text[] from pg_catalog.pg_proc where oid='public.server_reserve_phone_sms_send_for_actor(uuid,text,text)'::regprocedure), 'server reservation uses a fixed empty search path');
select ok((select prosecdef and proconfig @> array['search_path=""']::text[] from pg_catalog.pg_proc where oid='app_private.reserve_phone_sms_send(uuid,text,text)'::regprocedure), 'private reservation uses a fixed empty search path');
select ok(not has_function_privilege('service_role','app_private.reserve_phone_sms_send(uuid,text,text)','EXECUTE'), 'server executor cannot call the private helper directly');

set local role service_role;
select throws_ok($$select public.server_reserve_phone_sms_send_for_actor(current_setting('test.phone_limit_actor')::uuid,'invalid','bad request')$$,'22023','invalid_request','malformed send reservation is rejected');
select is(public.server_reserve_phone_sms_send_for_actor(current_setting('test.phone_limit_actor')::uuid,repeat('a',64),'send-limit-hour-1'),true,'first hourly send reservation succeeds');
select is(public.server_reserve_phone_sms_send_for_actor(current_setting('test.phone_limit_actor')::uuid,repeat('a',64),'send-limit-hour-2'),true,'second hourly send reservation succeeds');
select is(public.server_reserve_phone_sms_send_for_actor(current_setting('test.phone_limit_actor')::uuid,repeat('a',64),'send-limit-hour-3'),true,'third hourly send reservation succeeds');
select is(public.server_reserve_phone_sms_send_for_actor(current_setting('test.phone_limit_actor')::uuid,repeat('a',64),'send-limit-hour-4'),true,'fourth hourly send reservation succeeds');
select is(public.server_reserve_phone_sms_send_for_actor(current_setting('test.phone_limit_actor')::uuid,repeat('a',64),'send-limit-hour-5'),true,'fifth hourly send reservation succeeds');
select is(public.server_reserve_phone_sms_send_for_actor(current_setting('test.phone_limit_actor')::uuid,repeat('a',64),'send-limit-hour-6'),false,'a sixth hourly send is refused');
reset role;
select is((select count(*)::integer from app_private.identity_phone_sms_send_limits where phone_digest=repeat('a',64)),5,'hourly reservations are recorded once');

update app_private.identity_phone_sms_send_limits
set sent_at=pg_catalog.clock_timestamp()-interval '2 hours'
where phone_digest=repeat('a',64);

set local role service_role;
select is(public.server_reserve_phone_sms_send_for_actor(current_setting('test.phone_limit_actor')::uuid,repeat('a',64),'send-limit-day-6'),true,'sixth daily send succeeds after the first hour window passes');
select is(public.server_reserve_phone_sms_send_for_actor(current_setting('test.phone_limit_actor')::uuid,repeat('a',64),'send-limit-day-7'),true,'seventh daily send succeeds');
select is(public.server_reserve_phone_sms_send_for_actor(current_setting('test.phone_limit_actor')::uuid,repeat('a',64),'send-limit-day-8'),true,'eighth daily send succeeds');
select is(public.server_reserve_phone_sms_send_for_actor(current_setting('test.phone_limit_actor')::uuid,repeat('a',64),'send-limit-day-9'),true,'ninth daily send succeeds');
select is(public.server_reserve_phone_sms_send_for_actor(current_setting('test.phone_limit_actor')::uuid,repeat('a',64),'send-limit-day-10'),true,'tenth daily send succeeds');
select is(public.server_reserve_phone_sms_send_for_actor(current_setting('test.phone_limit_actor')::uuid,repeat('a',64),'send-limit-day-11'),false,'an eleventh rolling-day send is refused');
select is(public.server_reserve_phone_sms_send_for_actor(current_setting('test.phone_limit_actor')::uuid,repeat('a',64),'send-limit-day-10'),false,'a repeated Auth hook event cannot send twice');
select is(public.server_reserve_phone_sms_send_for_actor(current_setting('test.phone_limit_other')::uuid,repeat('a',64),'send-limit-other-account'),false,'the same phone cap applies across account IDs');
reset role;
select is((select count(*)::integer from app_private.identity_phone_sms_send_limits where phone_digest=repeat('a',64)),10,'daily reservations retain the rolling-day boundary');

select * from finish();
rollback;
