begin;

create extension if not exists pgtap with schema extensions;

select plan(29);

insert into public.job_categories (slug, label, enabled)
values ('test-disabled', 'Test-only hidden category', false);
create table public.test_unexposed_probe (id integer primary key);
alter table public.test_unexposed_probe enable row level security;

select has_table('public', 'job_categories', 'job category reference table exists');
select ok(
  (select relrowsecurity from pg_class where oid = 'public.job_categories'::regclass),
  'row-level security is enabled'
);
select ok(has_schema_privilege('anon', 'public', 'USAGE'), 'anonymous role can use the public schema');
select ok(has_table_privilege('anon', 'public.job_categories', 'SELECT'), 'anonymous role has only intended read access');
select ok(not has_table_privilege('anon', 'public.job_categories', 'INSERT'), 'anonymous role cannot insert');
select ok(not has_table_privilege('anon', 'public.job_categories', 'UPDATE'), 'anonymous role cannot update');
select ok(not has_table_privilege('anon', 'public.job_categories', 'DELETE'), 'anonymous role cannot delete');
select ok(not has_schema_privilege('anon', 'app_private', 'USAGE'), 'anonymous role cannot use the private schema');
select ok(has_table_privilege('authenticated', 'public.job_categories', 'SELECT'), 'authenticated role can read reference data');
select ok(not has_table_privilege('authenticated', 'public.job_categories', 'INSERT'), 'authenticated role cannot insert');
select ok(not has_table_privilege('authenticated', 'public.job_categories', 'UPDATE'), 'authenticated role cannot update');
select ok(not has_table_privilege('authenticated', 'public.job_categories', 'DELETE'), 'authenticated role cannot delete');
select ok(not has_schema_privilege('authenticated', 'app_private', 'USAGE'), 'authenticated role cannot use the private schema');
select ok(not has_table_privilege('service_role', 'public.job_categories', 'SELECT'), 'service role has no category grant');
select ok(not has_schema_privilege('service_role', 'app_private', 'USAGE'), 'service role has no private schema grant');
select ok(not has_table_privilege('anon', 'public.test_unexposed_probe', 'SELECT'), 'new public tables are not automatically exposed to anon');
select ok(not has_table_privilege('authenticated', 'public.test_unexposed_probe', 'SELECT'), 'new public tables are not automatically exposed to authenticated');
select ok(not has_table_privilege('service_role', 'public.test_unexposed_probe', 'SELECT'), 'new public tables are not automatically exposed to service_role');
select ok(
  (select relrowsecurity from pg_class where oid = 'public.test_unexposed_probe'::regclass),
  'the isolated default-grant fixture has RLS enabled'
);

set local role anon;
select is((select count(*)::integer from public.job_categories), 7, 'anonymous role sees the seven enabled categories');
select is((select count(*)::integer from public.job_categories where slug = 'test-disabled'), 0, 'anonymous role cannot see a disabled category');
select throws_ok(
  $$insert into public.job_categories (slug, label) values ('anon-write', 'Not allowed')$$,
  '42501',
  'permission denied for table job_categories',
  'anonymous role cannot insert a category'
);
select throws_ok(
  $$update public.job_categories set enabled = false where slug = 'errands'$$,
  '42501',
  'permission denied for table job_categories',
  'anonymous role cannot update a category'
);
select throws_ok(
  $$delete from public.job_categories where slug = 'errands'$$,
  '42501',
  'permission denied for table job_categories',
  'anonymous role cannot delete a category'
);

set local role authenticated;
select is((select count(*)::integer from public.job_categories), 7, 'authenticated role sees the seven enabled categories');
select is((select count(*)::integer from public.job_categories where slug = 'test-disabled'), 0, 'authenticated role cannot see a disabled category');
select throws_ok(
  $$insert into public.job_categories (slug, label) values ('authenticated-write', 'Not allowed')$$,
  '42501',
  'permission denied for table job_categories',
  'authenticated role cannot insert a category'
);
select throws_ok(
  $$update public.job_categories set enabled = false where slug = 'errands'$$,
  '42501',
  'permission denied for table job_categories',
  'authenticated role cannot update a category'
);
select throws_ok(
  $$delete from public.job_categories where slug = 'errands'$$,
  '42501',
  'permission denied for table job_categories',
  'authenticated role cannot delete a category'
);

reset role;
select * from finish();
rollback;
