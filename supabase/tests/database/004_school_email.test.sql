begin;

create extension if not exists pgtap with schema extensions;
select plan(52);

insert into app_private.institutional_email_domains (domain, enabled, environment)
values ('school.test', true, 'synthetic_local')
on conflict (domain) do update set enabled = true, environment = 'synthetic_local';
select set_config('test.school_owner_id', (select id::text from auth.users where email = 'phase2-owner@identity.test'), true);
select set_config('test.school_other_id', (select id::text from auth.users where email = 'phase2-other@identity.test'), true);
select set_config('test.school_trackb_id', (select id::text from auth.users where email = 'phase2-trackb@identity.test'), true);

select ok(to_regclass('app_private.institutional_email_domains') is not null, 'institutional allow-list is private');
select ok(to_regclass('app_private.identity_capabilities') is not null, 'derived capabilities have a protected table');
select ok(not has_schema_privilege('authenticated', 'app_private', 'USAGE'), 'browser role cannot enter the identity schema');
select ok(not has_table_privilege('authenticated', 'app_private.school_email_challenges', 'SELECT'), 'browser role cannot read challenge digests');
select ok(not has_table_privilege('authenticated', 'app_private.institutional_email_ownerships', 'SELECT'), 'browser role cannot read ownership records');
select ok(not has_table_privilege('service_role', 'app_private.school_email_challenges', 'SELECT'), 'server executor has no direct challenge table access');
select ok(has_function_privilege('service_role', 'public.server_begin_school_challenge_for_actor(uuid,text,text,uuid)', 'EXECUTE'), 'server executor can issue through the narrow gateway');
select ok(has_function_privilege('service_role', 'public.server_confirm_school_challenge_for_actor(uuid,uuid,text)', 'EXECUTE'), 'server executor can confirm through the narrow gateway');
select ok(has_function_privilege('service_role', 'public.server_fail_school_challenge_for_actor(uuid,uuid)', 'EXECUTE'), 'server executor can invalidate a challenge after delivery failure');
select ok(not has_function_privilege('authenticated', 'public.server_begin_school_challenge_for_actor(uuid,text,text,uuid)', 'EXECUTE'), 'authenticated cannot forge server challenge issuance');
select ok(not has_function_privilege('authenticated', 'public.server_confirm_school_challenge_for_actor(uuid,uuid,text)', 'EXECUTE'), 'authenticated cannot forge server challenge confirmation');
select ok(not has_function_privilege('authenticated', 'public.server_fail_school_challenge_for_actor(uuid,uuid)', 'EXECUTE'), 'authenticated cannot invalidate server challenges');
select ok(not has_function_privilege('anon', 'public.server_confirm_school_challenge_for_actor(uuid,uuid,text)', 'EXECUTE'), 'anonymous role cannot confirm challenges');
select ok(
  (select p.prosecdef and p.proconfig @> array['search_path=""']::text[]
   from pg_catalog.pg_proc p where p.oid = 'public.server_confirm_school_challenge_for_actor(uuid,uuid,text)'::regprocedure),
  'confirmation gateway is security-definer with fixed empty search path'
);
select ok(
  (select p.prosecdef and p.proconfig @> array['search_path=""']::text[]
   from pg_catalog.pg_proc p where p.oid = 'public.server_begin_school_challenge_for_actor(uuid,text,text,uuid)'::regprocedure),
  'issuance gateway is security-definer with fixed empty search path'
);
select ok(
  (select p.prosecdef and p.proconfig @> array['search_path=""']::text[]
   from pg_catalog.pg_proc p where p.oid = 'app_private.maybe_qualify_track_a(uuid)'::regprocedure),
  'qualification helper is security-definer with fixed empty search path'
);
select ok(
  exists (select 1 from pg_catalog.pg_trigger where tgrelid = 'auth.users'::regclass and tgname = 'auth_users_reconcile_track_a' and not tgisinternal),
  'Auth contact changes reconcile eligible Track A capabilities'
);
select ok(
  exists (select 1 from pg_catalog.pg_index where indexrelid = 'app_private.institutional_email_one_active_owner'::regclass and indisunique),
  'a school address can have only one current owner'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('test.school_owner_id'), true);
select lives_ok($$select public.register_my_identity('student', true, 'age-18-v1')$$, 'school test student can complete identity onboarding');
select set_config('request.jwt.claim.sub', current_setting('test.school_other_id'), true);
select lives_ok($$select public.register_my_identity('student', true, 'age-18-v1')$$, 'second school test student can complete identity onboarding');
select set_config('request.jwt.claim.sub', current_setting('test.school_trackb_id'), true);
select lives_ok($$select public.register_my_identity('partner', true, 'age-18-v1')$$, 'Track B partner can complete identity onboarding without the student school route');
reset role;

insert into app_private.identity_phone_bindings (user_id, phone_e164, verified_at)
select id, '+' || phone, phone_confirmed_at from auth.users
where id = current_setting('test.school_trackb_id')::uuid and phone_confirmed_at is not null;
update app_private.identity_accounts
set verification_track = 'track_b_partner', verification_status = 'approved'
where user_id = current_setting('test.school_trackb_id')::uuid;
insert into app_private.identity_capabilities (user_id, capability, source)
values
  (current_setting('test.school_trackb_id')::uuid, 'can_hire', 'track_b_partner'),
  (current_setting('test.school_trackb_id')::uuid, 'can_work', 'track_b_partner');
set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('test.school_trackb_id'), true);
select is(public.get_my_identity_status()->>'institutional_email_verified', 'false', 'Track B does not require school email ownership');
select is(public.get_my_identity_status()->'capabilities', '["can_hire"]'::jsonb, 'Track B keeps hire-only capability and never gains worker capability');
reset role;

set local role service_role;
select is(
  public.server_begin_school_challenge_for_actor(current_setting('test.school_owner_id')::uuid, 'Student@School.Test.Attacker.Test', repeat('a', 64), pg_catalog.gen_random_uuid())->>'issued',
  'false',
  'attacker suffix domain is not accepted by the exact local allow-list'
);
select set_config(
  'test.school_request_key',
  '8756a9d2-6467-489f-8d9f-672ae9f983b7',
  true
);
select set_config(
  'test.school_challenge_id',
  public.server_begin_school_challenge_for_actor(current_setting('test.school_owner_id')::uuid, 'Student@School.Test', encode(extensions.hmac(convert_to('042871', 'UTF8'), convert_to('test-only-server-key', 'UTF8'), 'sha256'), 'hex'), current_setting('test.school_request_key')::uuid)->>'challenge_id',
  true
);
select ok(current_setting('test.school_challenge_id')::uuid is not null, 'challenge issues for the exact normalized allow-listed domain');
select is(
  public.server_begin_school_challenge_for_actor(current_setting('test.school_owner_id')::uuid, 'Student@School.Test', repeat('f', 64), current_setting('test.school_request_key')::uuid)->>'challenge_id',
  current_setting('test.school_challenge_id'),
  'same idempotency key returns the original challenge reference'
);
select is(
  public.server_begin_school_challenge_for_actor(current_setting('test.school_owner_id')::uuid, 'Student@School.Test', repeat('f', 64), current_setting('test.school_request_key')::uuid)->>'issued',
  'false',
  'idempotent retry does not issue a second challenge'
);
select throws_ok(
  $$select public.server_begin_school_challenge_for_actor(current_setting('test.school_owner_id')::uuid, 'Student@School.Test', repeat('a', 64), pg_catalog.gen_random_uuid())$$,
  '22023', 'rate_limited', 'second same-address request inside resend wait is throttled'
);
reset role;

select is((select normalized_email from app_private.school_email_challenges where challenge_id = current_setting('test.school_challenge_id')::uuid), 'student@school.test', 'address normalization lowercases local part and domain');
select is((select octet_length(code_digest) from app_private.school_email_challenges where challenge_id = current_setting('test.school_challenge_id')::uuid), 32, 'challenge stores only a fixed-size keyed digest');

set local role service_role;
select throws_ok(
  $$select public.server_confirm_school_challenge_for_actor(current_setting('test.school_other_id')::uuid, current_setting('test.school_challenge_id')::uuid, encode(extensions.hmac(convert_to('042871', 'UTF8'), convert_to('test-only-server-key', 'UTF8'), 'sha256'), 'hex'))$$,
  '22023', 'invalid_challenge', 'a different account cannot replay another account challenge'
);
select is(
  public.server_confirm_school_challenge_for_actor(current_setting('test.school_owner_id')::uuid, current_setting('test.school_challenge_id')::uuid, encode(extensions.hmac(convert_to('111111', 'UTF8'), convert_to('test-only-server-key', 'UTF8'), 'sha256'), 'hex'))->>'confirmed',
  'false', 'wrong code is rejected and recorded'
);
reset role;
select is((select failed_attempts::integer from app_private.school_email_challenges where challenge_id = current_setting('test.school_challenge_id')::uuid), 1, 'failed confirmation counter commits atomically');

set local role service_role;
select set_config(
  'test.school_confirm_result',
  public.server_confirm_school_challenge_for_actor(current_setting('test.school_owner_id')::uuid, current_setting('test.school_challenge_id')::uuid, encode(extensions.hmac(convert_to('042871', 'UTF8'), convert_to('test-only-server-key', 'UTF8'), 'sha256'), 'hex'))::text,
  true
);
select is(
  current_setting('test.school_confirm_result')::jsonb->>'confirmed',
  'true', 'correct code consumes the challenge and creates ownership'
);
select is(
  current_setting('test.school_confirm_result')::jsonb->>'qualified',
  'false', 'school email alone does not qualify without current phone proof'
);
select throws_ok(
  $$select public.server_confirm_school_challenge_for_actor(current_setting('test.school_owner_id')::uuid, current_setting('test.school_challenge_id')::uuid, encode(extensions.hmac(convert_to('042871', 'UTF8'), convert_to('test-only-server-key', 'UTF8'), 'sha256'), 'hex'))$$,
  '22023', 'invalid_challenge', 'a consumed code cannot be used again'
);
reset role;

select is((select count(*)::integer from app_private.institutional_email_ownerships where normalized_email = 'student@school.test' and revoked_at is null), 1, 'verified supplementary address has one owner');
select is((select email from auth.users where id = current_setting('test.school_owner_id')::uuid), 'phase2-owner@identity.test', 'supplementary verification never replaces the login email');

set local role service_role;
select set_config(
  'test.school_conflict_challenge_id',
  public.server_begin_school_challenge_for_actor(current_setting('test.school_other_id')::uuid, 'student@school.test', encode(extensions.hmac(convert_to('777777', 'UTF8'), convert_to('test-only-server-key', 'UTF8'), 'sha256'), 'hex'), pg_catalog.gen_random_uuid())->>'challenge_id',
  true
);
select is(
  public.server_confirm_school_challenge_for_actor(current_setting('test.school_other_id')::uuid, current_setting('test.school_conflict_challenge_id')::uuid, encode(extensions.hmac(convert_to('777777', 'UTF8'), convert_to('test-only-server-key', 'UTF8'), 'sha256'), 'hex'))->>'confirmed',
  'false', 'a verified address owned by another account fails without an owner lookup result'
);
select set_config(
  'test.school_replacement_challenge_id',
  public.server_begin_school_challenge_for_actor(current_setting('test.school_owner_id')::uuid, 'replacement@school.test', encode(extensions.hmac(convert_to('888888', 'UTF8'), convert_to('test-only-server-key', 'UTF8'), 'sha256'), 'hex'), pg_catalog.gen_random_uuid())->>'challenge_id',
  true
);
select is(
  public.server_confirm_school_challenge_for_actor(current_setting('test.school_owner_id')::uuid, current_setting('test.school_replacement_challenge_id')::uuid, encode(extensions.hmac(convert_to('888888', 'UTF8'), convert_to('test-only-server-key', 'UTF8'), 'sha256'), 'hex'))->>'confirmed',
  'true', 'verified replacement address replaces the same users previous supplementary address'
);
reset role;
select is((select count(*)::integer from app_private.institutional_email_ownerships where normalized_email = 'student@school.test' and revoked_at is null), 0, 'conflicting account does not receive an ownership row');
select ok((select revoked_at is not null from app_private.institutional_email_ownerships where user_id = current_setting('test.school_owner_id')::uuid and normalized_email = 'student@school.test'), 'replacement revokes the prior active school proof');
select is((select count(*)::integer from app_private.institutional_email_ownerships where user_id = current_setting('test.school_owner_id')::uuid and revoked_at is null), 1, 'replacement leaves exactly one active school address for the user');
select is((select count(*)::integer from app_private.identity_audit_events where subject_id = current_setting('test.school_owner_id')::uuid and event_type = 'institutional_email_replaced'), 1, 'replacement records an append-only audit event');

set local role service_role;
select set_config(
  'test.school_attempt_challenge_id',
  public.server_begin_school_challenge_for_actor(current_setting('test.school_other_id')::uuid, 'attempts@school.test', encode(extensions.hmac(convert_to('222222', 'UTF8'), convert_to('test-only-server-key', 'UTF8'), 'sha256'), 'hex'), pg_catalog.gen_random_uuid())->>'challenge_id',
  true
);
select lives_ok($command$do $body$ begin for attempt in 1..5 loop perform public.server_confirm_school_challenge_for_actor(current_setting('test.school_other_id')::uuid, current_setting('test.school_attempt_challenge_id')::uuid, encode(extensions.hmac(convert_to('111111', 'UTF8'), convert_to('test-only-server-key', 'UTF8'), 'sha256'), 'hex')); end loop; end $body$;$command$, 'five invalid attempts execute inside atomic confirmation commands');
reset role;
select is((select failed_attempts::integer from app_private.school_email_challenges where challenge_id = current_setting('test.school_attempt_challenge_id')::uuid), 5, 'fifth invalid code consumes the attempt budget');
select ok((select invalidated_at is not null from app_private.school_email_challenges where challenge_id = current_setting('test.school_attempt_challenge_id')::uuid), 'fifth invalid attempt locks the challenge');
set local role service_role;
select throws_ok(
  $$select public.server_confirm_school_challenge_for_actor(current_setting('test.school_other_id')::uuid, current_setting('test.school_attempt_challenge_id')::uuid, encode(extensions.hmac(convert_to('222222', 'UTF8'), convert_to('test-only-server-key', 'UTF8'), 'sha256'), 'hex'))$$,
  '22023', 'invalid_challenge', 'correct code after five failures cannot confirm'
);
select set_config(
  'test.school_expired_challenge_id',
  public.server_begin_school_challenge_for_actor(current_setting('test.school_other_id')::uuid, 'expired@school.test', encode(extensions.hmac(convert_to('333333', 'UTF8'), convert_to('test-only-server-key', 'UTF8'), 'sha256'), 'hex'), pg_catalog.gen_random_uuid())->>'challenge_id',
  true
);
reset role;
update app_private.school_email_challenges set expires_at = now() - interval '1 second' where challenge_id = current_setting('test.school_expired_challenge_id')::uuid;
set local role service_role;
select throws_ok(
  $$select public.server_confirm_school_challenge_for_actor(current_setting('test.school_other_id')::uuid, current_setting('test.school_expired_challenge_id')::uuid, encode(extensions.hmac(convert_to('333333', 'UTF8'), convert_to('test-only-server-key', 'UTF8'), 'sha256'), 'hex'))$$,
  '22023', 'invalid_challenge', 'expired challenge is rejected'
);
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('test.school_owner_id'), true);
select is(public.get_my_identity_status()->'capabilities', '[]'::jsonb, 'pending phone keeps school-verified student restricted');
reset role;

insert into app_private.school_email_challenges (
  user_id, normalized_email, challenge_version, code_digest, digest_key_version, expires_at, created_at, consumed_at
)
select current_setting('test.school_other_id')::uuid, 'hour-cap@school.test', attempt,
       pg_catalog.decode(pg_catalog.repeat('a', 64), 'hex'), 1,
       now() + interval '10 minutes', now() - interval '2 minutes' - attempt * interval '1 minute', now()
from pg_catalog.generate_series(1, 5) attempt;
set local role service_role;
select throws_ok(
  $$select public.server_begin_school_challenge_for_actor(current_setting('test.school_other_id')::uuid, 'hour-cap@school.test', repeat('a', 64), pg_catalog.gen_random_uuid())$$,
  '22023', 'rate_limited', 'five challenges in the rolling hour enforce the hourly issuance cap'
);
reset role;

insert into app_private.school_email_challenges (
  user_id, normalized_email, challenge_version, code_digest, digest_key_version, expires_at, created_at, consumed_at
)
select current_setting('test.school_other_id')::uuid, 'day-cap@school.test', attempt,
       pg_catalog.decode(pg_catalog.repeat('b', 64), 'hex'), 1,
       now() + interval '10 minutes', now() - (attempt + 1) * interval '1 hour', now()
from pg_catalog.generate_series(1, 9) attempt;
set local role service_role;
select set_config(
  'test.school_day_cap_challenge_id',
  public.server_begin_school_challenge_for_actor(current_setting('test.school_other_id')::uuid, 'day-cap@school.test', repeat('c', 64), pg_catalog.gen_random_uuid())->>'challenge_id',
  true
);
reset role;
update app_private.school_email_challenges set created_at = now() - interval '61 seconds' where challenge_id = current_setting('test.school_day_cap_challenge_id')::uuid;
set local role service_role;
select throws_ok(
  $$select public.server_begin_school_challenge_for_actor(current_setting('test.school_other_id')::uuid, 'day-cap@school.test', repeat('d', 64), pg_catalog.gen_random_uuid())$$,
  '22023', 'rate_limited', 'ten challenges in the rolling day enforce the daily issuance cap'
);
reset role;

select * from finish();
rollback;
