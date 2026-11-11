begin;

create schema if not exists app_private;
revoke all on schema app_private from public, anon, authenticated, service_role;

grant usage on schema public to anon, authenticated;
revoke create on schema public from public, anon, authenticated, service_role;

alter default privileges for role postgres in schema public
  revoke all on tables from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  revoke all on sequences from public, anon, authenticated, service_role;

create table public.job_categories (
  slug text primary key check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  label text not null unique,
  enabled boolean not null default true
);

alter table public.job_categories enable row level security;

revoke all on table public.job_categories from public, anon, authenticated, service_role;
grant select on table public.job_categories to anon, authenticated;

create policy job_categories_read_enabled
  on public.job_categories
  for select
  to anon, authenticated
  using (enabled);

commit;
