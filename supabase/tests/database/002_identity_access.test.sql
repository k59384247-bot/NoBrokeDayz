begin;

create extension if not exists pgtap with schema extensions;

select plan(46);

select set_config(
  'test.owner_id',
  (select id::text from auth.users where email = 'phase2-owner@identity.test'),
  true
);
select set_config(
  'test.other_id',
  (select id::text from auth.users where email = 'phase2-other@identity.test'),
  true
);

select ok(
  to_regclass('app_private.identity_accounts') is not null,
  'protected identity facts live in app_private'
);
select ok(to_regclass('public.profiles') is not null, 'ordinary profiles have a dedicated public table');
select ok(
  to_regprocedure('public.register_my_identity(text,boolean,text)') is not null,
  'identity provisioning has a narrow command signature'
);
select ok(
  to_regprocedure('public.get_my_identity_status()') is not null,
  'own identity status has a narrow command signature'
);
select ok(
  to_regprocedure('public.server_register_identity_for_actor(uuid,text,boolean,text)') is not null,
  'trusted server registration has a separate command signature'
);
select has_column('public', 'profiles', 'display_name', 'profile has an editable display name');
select has_column('public', 'profiles', 'bio', 'profile has an editable bio');
select ok(not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'profiles' and column_name = 'account_type'), 'profile has no account type column');
select ok(not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'profiles' and column_name = 'verified_track'), 'profile has no approval column');
select ok(not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'profiles' and column_name = 'staff_capabilities'), 'profile has no staff capability column');
select ok(not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'profiles' and column_name = 'suspended_at'), 'profile has no suspension column');
select ok(not has_schema_privilege('anon', 'app_private', 'USAGE'), 'anon cannot use protected identity schema');
select ok(not has_schema_privilege('authenticated', 'app_private', 'USAGE'), 'authenticated cannot use protected identity schema');
select ok(not has_schema_privilege('service_role', 'app_private', 'USAGE'), 'service_role has no implicit private-schema access');
select ok(not has_table_privilege('anon', 'app_private.identity_accounts', 'SELECT'), 'anon cannot read identity facts');
select ok(not has_table_privilege('authenticated', 'app_private.identity_accounts', 'UPDATE'), 'authenticated cannot update identity facts');
select ok(not has_table_privilege('service_role', 'app_private.identity_accounts', 'SELECT'), 'service_role has no implicit identity-table access');
select ok(
  exists (
    select 1 from pg_proc p
    where p.oid = to_regprocedure('public.register_my_identity(text,boolean,text)')
      and not has_function_privilege('anon', p.oid, 'EXECUTE')
  ),
  'anon cannot register an identity'
);
select ok(
  exists (
    select 1 from pg_proc p
    where p.oid = to_regprocedure('public.register_my_identity(text,boolean,text)')
      and has_function_privilege('authenticated', p.oid, 'EXECUTE')
  ),
  'authenticated can call only the validated identity command'
);
select ok(
  exists (
    select 1 from pg_proc p
    where p.oid = to_regprocedure('public.get_my_identity_status()')
      and has_function_privilege('authenticated', p.oid, 'EXECUTE')
  ),
  'authenticated can read own status through a command'
);
select ok(
  exists (
    select 1 from pg_proc p
    where p.oid = to_regprocedure('public.server_register_identity_for_actor(uuid,text,boolean,text)')
      and not has_function_privilege('authenticated', p.oid, 'EXECUTE')
  ),
  'browser users cannot execute the server-only identity command'
);
select ok(
  exists (
    select 1 from pg_proc p
    where p.oid = to_regprocedure('public.server_register_identity_for_actor(uuid,text,boolean,text)')
      and has_function_privilege('service_role', p.oid, 'EXECUTE')
  ),
  'trusted server role has an explicit narrow identity command grant'
);

set local role anon;
select throws_ok(
  $$select public.register_my_identity('student', true, 'age-18-v1')$$,
  '42501',
  'permission denied for function register_my_identity',
  'anonymous callers cannot provision an identity'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '', true);
select throws_ok(
  $$select public.register_my_identity('student', true, 'age-18-v1')$$,
  '28000',
  'authentication required',
  'identity command rejects a missing verified actor'
);

select set_config(
  'request.jwt.claim.sub',
  current_setting('test.owner_id'),
  true
);
select lives_ok(
  $$select public.register_my_identity('student', true, 'age-18-v1')$$,
  'authenticated owner can create their own identity'
);
select is(
  public.get_my_identity_status() ->> 'account_type',
  'student',
  'own status returns the protected account type without exposing private rows'
);
select is(
  public.get_my_identity_status() ->> 'verification_status',
  'unverified',
  'Auth user metadata cannot approve an identity'
);
select is(
  public.get_my_identity_status() ->> 'account_status',
  'active',
  'Auth user metadata cannot change protected account status'
);
select ok(
  not (public.get_my_identity_status() ? 'staff_capabilities'),
  'own status does not accept or return staff grants from Auth metadata'
);
select lives_ok(
  $$select public.register_my_identity('student', true, 'age-18-v1')$$,
  'repeated registration with the same account type is idempotent'
);
select throws_ok(
  $$select public.register_my_identity('student', false, 'age-18-v1')$$,
  '22023',
  'age confirmation required',
  'registration requires an explicit 18+ affirmation'
);
select is((select count(*)::integer from public.profiles), 1, 'owner sees one own profile and no unrelated profiles');
select throws_ok(
  $$update public.profiles set display_name = 'Synthetic Student' where user_id = auth.uid()$$,
  '42501',
  'permission denied for table profiles',
  'owner edits must use the controlled profile command'
);
select throws_ok(
  $$update public.profiles set bio = pg_catalog.repeat('x', 501) where user_id = auth.uid()$$,
  '42501',
  'permission denied for table profiles',
  'overlong values cannot bypass the controlled profile command'
);
select set_config('request.jwt.claim.sub', current_setting('test.other_id'), true);
select is((select count(*)::integer from public.profiles), 0, 'unrelated account cannot read the owner''s profile');
select set_config('request.jwt.claim.sub', current_setting('test.owner_id'), true);
select throws_ok(
  $$update public.profiles set user_id = auth.uid() where user_id = auth.uid()$$,
  '42501',
  'permission denied for table profiles',
  'owner cannot change the identity key of their profile'
);
select throws_ok(
  $$select account_type from app_private.identity_accounts$$,
  '42501',
  'permission denied for schema app_private',
  'authenticated owner cannot read protected identity rows directly'
);
select throws_ok(
  $$select public.register_my_identity('partner', true, 'age-18-v1')$$,
  '23514',
  'account type is immutable after registration',
  'registration retry cannot change the selected account type'
);

reset role;
set local role service_role;
select lives_ok(
  $$select public.server_register_identity_for_actor(current_setting('test.other_id')::uuid, 'partner', true, 'age-18-v1')$$,
  'trusted server executor can provision only through the scoped command'
);
reset role;
select is(
  (select account_type from app_private.identity_accounts where user_id = current_setting('test.other_id')::uuid),
  'partner',
  'server command records the requested account type for its target Auth user'
);
select is(
  (select count(*)::integer from app_private.identity_audit_events where subject_id = current_setting('test.owner_id')::uuid and event_type = 'identity_registered'),
  1,
  'registration retry appends exactly one audit event'
);
select is(
  (select count(*)::integer from app_private.identity_outbox where subject_id = current_setting('test.owner_id')::uuid and event_type = 'identity_registered'),
  1,
  'registration retry enqueues exactly one identity event'
);
select throws_ok(
  $$update app_private.identity_audit_events set event_type = 'rewritten' where subject_id = current_setting('test.owner_id')::uuid and event_type = 'identity_registered'$$,
  '55000',
  'identity history is append-only',
  'identity audit history cannot be edited after posting'
);
insert into app_private.verification_submissions (user_id, submission_version, track, narrative)
values (current_setting('test.owner_id')::uuid, 1, 'track_a_manual', 'Synthetic verification submission narrative');
select lives_ok(
  $$update app_private.verification_submissions set status = 'needs_information' where user_id = current_setting('test.owner_id')::uuid$$,
  'pending verification submission can receive one review transition'
);
select throws_ok(
  $$update app_private.verification_submissions set status = 'approved' where user_id = current_setting('test.owner_id')::uuid$$,
  '55000',
  'verification submission transition not allowed',
  'reviewed verification submission cannot receive a second decision'
);
select throws_ok(
  $$update app_private.verification_submissions set narrative = 'Changed synthetic submission narrative' where user_id = current_setting('test.owner_id')::uuid$$,
  '55000',
  'verification submission fields are immutable',
  'submitted evidence and narrative cannot be rewritten in place'
);
select * from finish();
rollback;
