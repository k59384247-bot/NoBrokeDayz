begin;

create table public.profiles (
  user_id uuid primary key references auth.users (id) on delete restrict,
  display_name text,
  photo_key text,
  faculty_label text,
  campus_label text,
  bio text,
  skills text[] not null default '{}',
  availability text,
  business_name text,
  business_location text,
  organisation_label text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_display_name_length check (
    display_name is null or char_length(btrim(display_name)) between 2 and 60
  ),
  constraint profiles_photo_key_length check (
    photo_key is null or (char_length(photo_key) <= 200 and photo_key !~ '(^/|\.\.|://)')
  ),
  constraint profiles_faculty_length check (faculty_label is null or char_length(faculty_label) <= 80),
  constraint profiles_campus_length check (campus_label is null or char_length(campus_label) <= 80),
  constraint profiles_bio_length check (bio is null or char_length(bio) <= 500),
  constraint profiles_skills_count check (cardinality(skills) <= 20),
  constraint profiles_availability_length check (availability is null or char_length(availability) <= 160),
  constraint profiles_business_name_length check (business_name is null or char_length(business_name) <= 100),
  constraint profiles_business_location_length check (business_location is null or char_length(business_location) <= 160),
  constraint profiles_organisation_label_length check (organisation_label is null or char_length(organisation_label) <= 100)
);

create function public.validate_profile_skills()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if exists (
    select 1
    from pg_catalog.unnest(new.skills) as skill(value)
    where skill.value is null
       or char_length(btrim(skill.value)) not between 1 and 40
  ) then
    raise exception using errcode = '22023', message = 'profile skills exceed limits';
  end if;
  return new;
end;
$function$;

revoke all on function public.validate_profile_skills() from public, anon, authenticated, service_role;
create trigger profiles_validate_skills
before insert or update of skills on public.profiles
for each row execute function public.validate_profile_skills();

create function public.set_profile_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  new.updated_at := pg_catalog.now();
  return new;
end;
$function$;

revoke all on function public.set_profile_updated_at() from public, anon, authenticated, service_role;
create trigger profiles_set_updated_at
before update on public.profiles
for each row execute function public.set_profile_updated_at();

alter table public.profiles enable row level security;
revoke all on table public.profiles from public, anon, authenticated, service_role;
grant select (user_id, display_name, photo_key, faculty_label, campus_label, bio, skills, availability, business_name, business_location, organisation_label, created_at, updated_at)
  on public.profiles to authenticated;
grant update (display_name, photo_key, faculty_label, campus_label, bio, skills, availability, business_name, business_location, organisation_label)
  on public.profiles to authenticated;
create policy profiles_select_own
  on public.profiles for select to authenticated
  using (user_id = (select auth.uid()));
create policy profiles_update_own
  on public.profiles for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create table app_private.identity_accounts (
  user_id uuid primary key references auth.users (id) on delete restrict,
  account_type text not null check (account_type in ('student', 'partner')),
  age_confirmed_at timestamptz not null,
  age_policy_version text not null check (char_length(age_policy_version) between 1 and 40),
  account_status text not null default 'active' check (account_status in ('active', 'suspended')),
  verification_track text check (verification_track in ('track_a_school_email', 'track_a_manual', 'track_b_partner')),
  verification_status text not null default 'unverified'
    check (verification_status in ('unverified', 'pending', 'needs_information', 'rejected', 'approved')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table app_private.institutional_email_ownerships (
  ownership_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references app_private.identity_accounts (user_id) on delete restrict,
  normalized_email text not null check (char_length(normalized_email) between 3 and 254 and normalized_email = lower(normalized_email)),
  verified_at timestamptz not null default now(),
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  check (revoked_at is null or revoked_at >= verified_at)
);
create unique index institutional_email_one_active_owner
  on app_private.institutional_email_ownerships (normalized_email) where revoked_at is null;
create unique index institutional_email_one_active_address_per_user
  on app_private.institutional_email_ownerships (user_id) where revoked_at is null;

create table app_private.school_email_challenges (
  challenge_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references app_private.identity_accounts (user_id) on delete restrict,
  normalized_email text not null check (char_length(normalized_email) between 3 and 254 and normalized_email = lower(normalized_email)),
  challenge_version integer not null check (challenge_version > 0),
  code_digest bytea not null check (octet_length(code_digest) = 32),
  digest_key_version smallint not null check (digest_key_version > 0),
  expires_at timestamptz not null,
  failed_attempts smallint not null default 0 check (failed_attempts between 0 and 5),
  created_at timestamptz not null default now(),
  consumed_at timestamptz,
  invalidated_at timestamptz,
  unique (user_id, normalized_email, challenge_version)
);
create unique index school_email_one_open_challenge
  on app_private.school_email_challenges (user_id, normalized_email)
  where consumed_at is null and invalidated_at is null;

create table app_private.verification_submissions (
  submission_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references app_private.identity_accounts (user_id) on delete restrict,
  submission_version integer not null check (submission_version > 0),
  track text not null check (track in ('track_a_manual', 'track_b_partner')),
  status text not null default 'pending'
    check (status in ('pending', 'needs_information', 'rejected', 'approved')),
  legal_name text check (legal_name is null or char_length(btrim(legal_name)) between 2 and 120),
  narrative text check (narrative is null or char_length(narrative) between 20 and 1000),
  submitted_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, track, submission_version),
  unique (submission_id, user_id)
);

create function app_private.guard_verification_submission_update()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  if new.submission_id is distinct from old.submission_id
     or new.user_id is distinct from old.user_id
     or new.submission_version is distinct from old.submission_version
     or new.track is distinct from old.track
     or new.legal_name is distinct from old.legal_name
     or new.narrative is distinct from old.narrative
     or new.submitted_at is distinct from old.submitted_at
     or new.created_at is distinct from old.created_at then
    raise exception using errcode = '55000', message = 'verification submission fields are immutable';
  end if;

  if old.status <> 'pending' or new.status not in ('needs_information', 'rejected', 'approved') then
    raise exception using errcode = '55000', message = 'verification submission transition not allowed';
  end if;

  new.updated_at := pg_catalog.now();
  return new;
end;
$function$;
revoke all on function app_private.guard_verification_submission_update() from public, anon, authenticated, service_role;
create trigger verification_submissions_guard_update
before update on app_private.verification_submissions
for each row execute function app_private.guard_verification_submission_update();

create table app_private.verification_evidence (
  evidence_id uuid primary key default gen_random_uuid(),
  submission_id uuid not null,
  user_id uuid not null,
  evidence_position smallint not null check (evidence_position between 1 and 3),
  object_key text not null unique check (char_length(object_key) between 1 and 300),
  content_type text not null check (content_type in ('image/jpeg', 'image/png', 'application/pdf')),
  size_bytes integer not null check (size_bytes between 1 and 5000000),
  content_sha256 bytea check (content_sha256 is null or octet_length(content_sha256) = 32),
  safety_state text not null default 'quarantined' check (safety_state in ('quarantined', 'ready', 'rejected')),
  created_at timestamptz not null default now(),
  finalized_at timestamptz,
  foreign key (submission_id, user_id)
    references app_private.verification_submissions (submission_id, user_id) on delete restrict,
  unique (submission_id, evidence_position)
);

create table app_private.verification_reviews (
  review_id uuid primary key default gen_random_uuid(),
  submission_id uuid not null references app_private.verification_submissions (submission_id) on delete restrict,
  reviewer_id uuid not null references auth.users (id) on delete restrict,
  decision text not null check (decision in ('needs_information', 'rejected', 'approved')),
  reason text not null check (char_length(btrim(reason)) between 20 and 500),
  internal_note text check (internal_note is null or char_length(internal_note) <= 2000),
  decision_version integer not null check (decision_version > 0),
  created_at timestamptz not null default now(),
  unique (submission_id, decision_version)
);

create table app_private.staff_grants (
  grant_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete restrict,
  capability text not null check (capability in ('verification_review', 'identity_suspend', 'identity_unsuspend', 'identity_correct_user_type')),
  granted_by uuid not null references auth.users (id) on delete restrict,
  reason text not null check (char_length(btrim(reason)) between 20 and 500),
  granted_at timestamptz not null default now(),
  revoked_at timestamptz,
  revoked_by uuid references auth.users (id) on delete restrict,
  check ((revoked_at is null) = (revoked_by is null))
);
create unique index staff_grants_one_active_capability
  on app_private.staff_grants (user_id, capability) where revoked_at is null;

create table app_private.identity_audit_events (
  event_id uuid primary key default gen_random_uuid(),
  actor_id uuid references auth.users (id) on delete restrict,
  subject_id uuid references auth.users (id) on delete restrict,
  event_type text not null check (char_length(event_type) between 1 and 80),
  event_data jsonb not null default '{}'::jsonb check (pg_catalog.jsonb_typeof(event_data) = 'object'),
  created_at timestamptz not null default now()
);

create table app_private.identity_outbox (
  event_id uuid primary key references app_private.identity_audit_events (event_id) on delete restrict,
  subject_id uuid not null references auth.users (id) on delete restrict,
  event_type text not null check (char_length(event_type) between 1 and 80),
  payload jsonb not null default '{}'::jsonb check (pg_catalog.jsonb_typeof(payload) = 'object'),
  delivery_state text not null default 'pending' check (delivery_state in ('pending', 'processing', 'delivered', 'failed')),
  attempt_count smallint not null default 0 check (attempt_count >= 0),
  available_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create function app_private.reject_identity_history_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  raise exception using errcode = '55000', message = 'identity history is append-only';
end;
$function$;
revoke all on function app_private.reject_identity_history_mutation() from public, anon, authenticated, service_role;
create trigger identity_audit_events_append_only
before update or delete on app_private.identity_audit_events
for each row execute function app_private.reject_identity_history_mutation();
create trigger verification_reviews_append_only
before update or delete on app_private.verification_reviews
for each row execute function app_private.reject_identity_history_mutation();

revoke all on all tables in schema app_private from public, anon, authenticated, service_role;
revoke all on all sequences in schema app_private from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema app_private
  revoke all on tables from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema app_private
  revoke all on sequences from public, anon, authenticated, service_role;

create function app_private.register_identity_for_actor(
  p_actor uuid,
  p_account_type text,
  p_age_confirmed boolean,
  p_age_policy_version text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_existing app_private.identity_accounts%rowtype;
  v_inserted uuid;
  v_event_id uuid;
begin
  if p_actor is null then
    raise exception using errcode = '22023', message = 'invalid account subject';
  end if;
  if p_account_type is null or p_account_type not in ('student', 'partner') then
    raise exception using errcode = '22023', message = 'invalid account type';
  end if;
  if p_age_confirmed is distinct from true then
    raise exception using errcode = '22023', message = 'age confirmation required';
  end if;
  if p_age_policy_version is null or char_length(p_age_policy_version) not between 1 and 40 then
    raise exception using errcode = '22023', message = 'invalid age policy version';
  end if;

  insert into app_private.identity_accounts (user_id, account_type, age_confirmed_at, age_policy_version)
  values (p_actor, p_account_type, pg_catalog.now(), p_age_policy_version)
  on conflict (user_id) do nothing
  returning user_id into v_inserted;

  if v_inserted is not null then
    insert into public.profiles (user_id) values (p_actor);
    insert into app_private.identity_audit_events (actor_id, subject_id, event_type, event_data)
    values (
      p_actor,
      p_actor,
      'identity_registered',
      pg_catalog.jsonb_build_object('account_type', p_account_type, 'age_policy_version', p_age_policy_version)
    )
    returning event_id into v_event_id;
    insert into app_private.identity_outbox (event_id, subject_id, event_type, payload)
    values (
      v_event_id,
      p_actor,
      'identity_registered',
      pg_catalog.jsonb_build_object('account_type', p_account_type)
    );
  end if;

  select * into v_existing from app_private.identity_accounts where user_id = p_actor;
  if v_existing.account_type <> p_account_type then
    raise exception using errcode = '23514', message = 'account type is immutable after registration';
  end if;

  return pg_catalog.jsonb_build_object(
    'registered', true,
    'account_type', v_existing.account_type,
    'age_confirmed', true,
    'age_confirmed_at', v_existing.age_confirmed_at,
    'age_policy_version', v_existing.age_policy_version,
    'account_status', v_existing.account_status,
    'verification_track', v_existing.verification_track,
    'verification_status', v_existing.verification_status
  );
end;
$function$;

create function public.register_my_identity(p_account_type text, p_age_confirmed boolean, p_age_policy_version text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;
  return app_private.register_identity_for_actor(v_actor, p_account_type, p_age_confirmed, p_age_policy_version);
end;
$function$;

create function public.server_register_identity_for_actor(
  p_actor uuid,
  p_account_type text,
  p_age_confirmed boolean,
  p_age_policy_version text
)
returns jsonb
language sql
security definer
set search_path = ''
as $function$
  select app_private.register_identity_for_actor(p_actor, p_account_type, p_age_confirmed, p_age_policy_version)
$function$;
comment on function public.server_register_identity_for_actor(uuid, text, boolean, text) is
  'Trusted-server gateway only. The server must validate the caller Auth token and derive p_actor from that verified subject; never forward a caller-supplied actor ID.';

create function public.get_my_identity_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_actor uuid := auth.uid();
  v_identity app_private.identity_accounts%rowtype;
  v_school_email_verified boolean;
begin
  if v_actor is null then
    raise exception using errcode = '28000', message = 'authentication required';
  end if;

  select * into v_identity from app_private.identity_accounts where user_id = v_actor;
  if not found then
    return pg_catalog.jsonb_build_object('registered', false);
  end if;

  select exists (
    select 1 from app_private.institutional_email_ownerships ownership
    where ownership.user_id = v_actor and ownership.revoked_at is null
  ) into v_school_email_verified;

  return pg_catalog.jsonb_build_object(
    'registered', true,
    'account_type', v_identity.account_type,
    'age_confirmed', true,
    'account_status', v_identity.account_status,
    'verification_track', v_identity.verification_track,
    'verification_status', v_identity.verification_status,
    'institutional_email_verified', v_school_email_verified
  );
end;
$function$;

revoke all on function app_private.register_identity_for_actor(uuid, text, boolean, text) from public, anon, authenticated, service_role;
revoke all on function public.register_my_identity(text, boolean, text) from public, anon, authenticated, service_role;
revoke all on function public.server_register_identity_for_actor(uuid, text, boolean, text) from public, anon, authenticated, service_role;
revoke all on function public.get_my_identity_status() from public, anon, authenticated, service_role;
grant execute on function public.register_my_identity(text, boolean, text) to authenticated;
grant execute on function public.server_register_identity_for_actor(uuid, text, boolean, text) to service_role;
grant execute on function public.get_my_identity_status() to authenticated;

commit;
