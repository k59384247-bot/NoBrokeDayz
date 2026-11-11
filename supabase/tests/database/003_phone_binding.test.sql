begin;

create extension if not exists pgtap with schema extensions;
select plan(13);

select set_config(
  'test.owner_id',
  (select id::text from auth.users where email = 'phase2-owner@identity.test'),
  true
);

select ok(to_regclass('app_private.identity_phone_bindings') is not null, 'current verified phone binding is private');
select ok(not has_schema_privilege('authenticated', 'app_private', 'USAGE'), 'authenticated role cannot enter private phone schema');
select ok(not has_schema_privilege('service_role', 'app_private', 'USAGE'), 'server role has no broad private-schema access');
select ok(not has_table_privilege('authenticated', 'app_private.identity_phone_bindings', 'SELECT'), 'authenticated cannot read phone bindings');
select ok(not has_table_privilege('authenticated', 'app_private.identity_phone_bindings', 'INSERT'), 'authenticated cannot create phone bindings');
select ok(not has_table_privilege('authenticated', 'app_private.identity_phone_bindings', 'UPDATE'), 'authenticated cannot edit phone bindings');
select ok(not has_table_privilege('service_role', 'app_private.identity_phone_bindings', 'SELECT'), 'service role has no implicit phone-binding table access');
select ok(
  exists (
    select 1 from pg_catalog.pg_trigger trigger_row
    where trigger_row.tgrelid = 'auth.users'::regclass
      and trigger_row.tgname = 'auth_users_guard_phone_uniqueness'
      and not trigger_row.tgisinternal
  ),
  'Auth phone changes pass through the cross-account uniqueness guard'
);
select ok(
  exists (
    select 1 from pg_catalog.pg_trigger trigger_row
    where trigger_row.tgrelid = 'auth.users'::regclass
      and trigger_row.tgname = 'auth_users_reconcile_phone_binding'
      and not trigger_row.tgisinternal
  ),
  'only Auth phone confirmation transitions synchronize the protected binding'
);
select ok(
  (select p.prosecdef and p.proconfig @> array['search_path=""']::text[]
   from pg_catalog.pg_proc p
   where p.oid = 'app_private.guard_auth_phone_uniqueness()'::regprocedure),
  'phone uniqueness trigger helper is security-definer with an empty search path'
);
select ok(
  (select p.prosecdef and p.proconfig @> array['search_path=""']::text[]
   from pg_catalog.pg_proc p
   where p.oid = 'app_private.reconcile_auth_phone_binding()'::regprocedure),
  'Auth reconciliation helper is security-definer with an empty search path'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('test.owner_id'), true);
select lives_ok(
  $$select public.register_my_identity('student', true, 'age-18-v1')$$,
  'synthetic owner can provision before binding a phone'
);
select is(public.get_my_identity_status() ->> 'phone_verified', 'false', 'unconfirmed phone never satisfies the shared prerequisite');
select * from finish();
rollback;
