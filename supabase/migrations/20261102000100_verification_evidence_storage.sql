begin;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('verification-quarantine', 'verification-quarantine', false, 5000000,
   array['image/jpeg', 'image/png', 'application/pdf']::text[]),
  ('verification-private', 'verification-private', false, 5000000,
   array['image/jpeg', 'image/png', 'application/pdf']::text[])
on conflict (id) do update
set name = excluded.name,
    public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

create policy verification_buckets_block_browser_roles
on storage.objects
as restrictive
for all
to anon, authenticated
using (bucket_id not in ('verification-quarantine', 'verification-private'))
with check (bucket_id not in ('verification-quarantine', 'verification-private'));

alter table app_private.verification_evidence
  add column storage_bucket text not null default 'verification-quarantine'
  check (storage_bucket in ('verification-quarantine', 'verification-private')),
  add constraint verification_evidence_finalized_hash
    check (safety_state = 'rejected' or (content_sha256 is not null and finalized_at is not null)),
  add constraint verification_evidence_generated_key
    check (object_key = user_id::text || '/' || submission_id::text || '/' || evidence_id::text || '/source');

create table app_private.verification_upload_intents (
  intent_id uuid primary key default pg_catalog.gen_random_uuid(),
  evidence_id uuid not null unique default pg_catalog.gen_random_uuid(),
  user_id uuid not null references app_private.identity_accounts (user_id) on delete restrict,
  submission_id uuid not null,
  evidence_position smallint not null check (evidence_position between 1 and 3),
  expected_content_type text not null check (expected_content_type in ('image/jpeg', 'image/png', 'application/pdf')),
  expected_size_bytes integer not null check (expected_size_bytes between 1 and 5000000),
  token_hash bytea not null check (octet_length(token_hash) = 32),
  object_key text not null unique check (object_key ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f-]{36}/source$'),
  state text not null default 'issued' check (state in ('issued', 'uploading', 'finalized', 'rejected', 'expired')),
  expires_at timestamptz not null,
  created_at timestamptz not null default pg_catalog.now(),
  claimed_at timestamptz,
  finalized_at timestamptz,
  foreign key (submission_id, user_id)
    references app_private.verification_submissions (submission_id, user_id) on delete restrict,
  check (expires_at > created_at and expires_at <= created_at + interval '5 minutes')
);

create unique index verification_one_live_upload_per_slot
  on app_private.verification_upload_intents (submission_id, evidence_position)
  where state in ('issued', 'uploading');

create table app_private.verification_file_access_events (
  event_id bigint generated always as identity primary key,
  actor_id uuid references auth.users (id) on delete restrict,
  submission_id uuid references app_private.verification_submissions (submission_id) on delete restrict,
  evidence_id uuid,
  intent_id uuid references app_private.verification_upload_intents (intent_id) on delete restrict,
  event_type text not null check (event_type in (
    'upload_intent_issued', 'upload_claimed', 'upload_rejected',
    'upload_quarantined', 'upload_access_denied', 'review_download_issued',
    'review_download_denied', 'orphan_cleanup'
  )),
  reason_code text check (reason_code is null or reason_code in (
    'signature_mismatch', 'active_content_marker', 'size_mismatch',
    'stored_content_mismatch', 'upload_expired', 'invalid_intent',
    'aal_required', 'no_current_grant', 'account_restricted',
    'evidence_not_ready', 'orphan_age_passed'
  )),
  object_key_sha256 bytea check (object_key_sha256 is null or octet_length(object_key_sha256) = 32),
  created_at timestamptz not null default pg_catalog.now()
);

create function app_private.begin_verification_upload_for_actor(
  p_actor uuid,
  p_submission_id uuid,
  p_evidence_position smallint,
  p_content_type text,
  p_size_bytes integer,
  p_token_hash_hex text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_submission app_private.verification_submissions%rowtype;
  v_intent_id uuid := pg_catalog.gen_random_uuid();
  v_evidence_id uuid := pg_catalog.gen_random_uuid();
  v_expires_at timestamptz := pg_catalog.now() + interval '5 minutes';
  v_object_key text;
begin
  if p_actor is null or p_submission_id is null
     or p_evidence_position is null
     or p_evidence_position not between 1 and 3
     or p_content_type is null
     or p_content_type not in ('image/jpeg', 'image/png', 'application/pdf')
     or p_size_bytes is null
     or p_size_bytes not between 1 and 5000000
     or p_token_hash_hex is null
     or p_token_hash_hex !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = '22023', message = 'invalid_request';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_submission_id::text || ':' || p_evidence_position::text, 904021)
  );
  select * into v_submission
  from app_private.verification_submissions
  where submission_id = p_submission_id and user_id = p_actor
  for update;
  if not found or v_submission.status <> 'pending'
     or exists (
       select 1 from app_private.verification_evidence
       where submission_id = p_submission_id and evidence_position = p_evidence_position
     ) then
    raise exception using errcode = '22023', message = 'invalid_submission';
  end if;

  update app_private.verification_upload_intents
  set state = 'expired', token_hash = pg_catalog.decode(pg_catalog.repeat('00', 32), 'hex')
  where submission_id = p_submission_id and evidence_position = p_evidence_position
    and state = 'issued';

  v_object_key := p_actor::text || '/' || p_submission_id::text || '/' || v_evidence_id::text || '/source';
  insert into app_private.verification_upload_intents (
    intent_id, evidence_id, user_id, submission_id, evidence_position,
    expected_content_type, expected_size_bytes, token_hash, object_key, expires_at
  ) values (
    v_intent_id, v_evidence_id, p_actor, p_submission_id, p_evidence_position,
    p_content_type, p_size_bytes, pg_catalog.decode(p_token_hash_hex, 'hex'), v_object_key, v_expires_at
  );
  insert into app_private.verification_file_access_events (
    actor_id, submission_id, evidence_id, intent_id, event_type
  ) values (p_actor, p_submission_id, v_evidence_id, v_intent_id, 'upload_intent_issued');
  return pg_catalog.jsonb_build_object(
    'intent_id', v_intent_id,
    'evidence_id', v_evidence_id,
    'expires_at', v_expires_at
  );
end;
$function$;

create function app_private.claim_verification_upload_for_actor(
  p_actor uuid,
  p_intent_id uuid,
  p_token_hash_hex text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_intent app_private.verification_upload_intents%rowtype;
begin
  select * into v_intent
  from app_private.verification_upload_intents
  where intent_id = p_intent_id and user_id = p_actor
  for update;
  if not found or v_intent.state <> 'issued'
     or v_intent.expires_at <= pg_catalog.now()
     or p_token_hash_hex is null
     or p_token_hash_hex !~ '^[0-9a-f]{64}$'
     or v_intent.token_hash <> pg_catalog.decode(p_token_hash_hex, 'hex') then
    insert into app_private.verification_file_access_events (actor_id, event_type, reason_code)
    values (p_actor, 'upload_access_denied', 'invalid_intent');
    return pg_catalog.jsonb_build_object('claimed', false);
  end if;
  update app_private.verification_upload_intents
  set state = 'uploading', claimed_at = pg_catalog.now()
  where intent_id = v_intent.intent_id;
  insert into app_private.verification_file_access_events (
    actor_id, submission_id, evidence_id, intent_id, event_type
  ) values (p_actor, v_intent.submission_id, v_intent.evidence_id, v_intent.intent_id, 'upload_claimed');
  return pg_catalog.jsonb_build_object(
    'claimed', true,
    'evidence_id', v_intent.evidence_id,
    'object_key', v_intent.object_key,
    'content_type', v_intent.expected_content_type,
    'size_bytes', v_intent.expected_size_bytes
  );
end;
$function$;

create function app_private.finalize_verification_upload_for_actor(
  p_actor uuid,
  p_intent_id uuid,
  p_size_bytes integer,
  p_content_type text,
  p_sha256_hex text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_intent app_private.verification_upload_intents%rowtype;
begin
  select * into v_intent
  from app_private.verification_upload_intents
  where intent_id = p_intent_id and user_id = p_actor
  for update;
  if not found or v_intent.state <> 'uploading'
     or v_intent.expires_at <= pg_catalog.now()
     or v_intent.expected_size_bytes <> p_size_bytes
     or v_intent.expected_content_type <> p_content_type
     or p_sha256_hex is null
     or p_sha256_hex !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = '22023', message = 'invalid_upload_intent';
  end if;

  insert into app_private.verification_evidence (
    evidence_id, submission_id, user_id, evidence_position,
    object_key, storage_bucket, content_type, size_bytes,
    content_sha256, safety_state, finalized_at
  ) values (
    v_intent.evidence_id, v_intent.submission_id, v_intent.user_id, v_intent.evidence_position,
    v_intent.object_key, 'verification-quarantine', v_intent.expected_content_type,
    v_intent.expected_size_bytes, pg_catalog.decode(p_sha256_hex, 'hex'),
    'quarantined', pg_catalog.now()
  );
  update app_private.verification_upload_intents
  set state = 'finalized', finalized_at = pg_catalog.now(),
      token_hash = pg_catalog.decode(pg_catalog.repeat('00', 32), 'hex')
  where intent_id = v_intent.intent_id;
  insert into app_private.verification_file_access_events (
    actor_id, submission_id, evidence_id, intent_id, event_type
  ) values (p_actor, v_intent.submission_id, v_intent.evidence_id, v_intent.intent_id, 'upload_quarantined');
  return pg_catalog.jsonb_build_object(
    'finalized', true,
    'evidence_id', v_intent.evidence_id,
    'safety_state', 'quarantined',
    'reviewable', false
  );
end;
$function$;

create function app_private.reject_verification_upload_for_actor(
  p_actor uuid,
  p_intent_id uuid,
  p_reason_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_intent app_private.verification_upload_intents%rowtype;
begin
  if p_reason_code is null or p_reason_code not in ('signature_mismatch', 'active_content_marker', 'size_mismatch', 'stored_content_mismatch', 'upload_expired') then
    raise exception using errcode = '22023', message = 'invalid_request';
  end if;
  select * into v_intent
  from app_private.verification_upload_intents
  where intent_id = p_intent_id and user_id = p_actor
  for update;
  if not found or v_intent.state not in ('issued', 'uploading') then
    raise exception using errcode = '22023', message = 'invalid_upload_intent';
  end if;
  update app_private.verification_upload_intents
  set state = 'rejected', finalized_at = pg_catalog.now(),
      token_hash = pg_catalog.decode(pg_catalog.repeat('00', 32), 'hex')
  where intent_id = v_intent.intent_id;
  insert into app_private.verification_file_access_events (
    actor_id, submission_id, evidence_id, intent_id, event_type, reason_code
  ) values (p_actor, v_intent.submission_id, v_intent.evidence_id, v_intent.intent_id, 'upload_rejected', p_reason_code);
  return pg_catalog.jsonb_build_object('rejected', true, 'reason_code', p_reason_code);
end;
$function$;

create function app_private.verification_download_target_for_reviewer(
  p_actor uuid,
  p_evidence_id uuid,
  p_auth_aal text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_evidence app_private.verification_evidence%rowtype;
begin
  if p_auth_aal is distinct from 'aal2' then
    insert into app_private.verification_file_access_events (actor_id, evidence_id, event_type, reason_code)
    values (p_actor, p_evidence_id, 'review_download_denied', 'aal_required');
    return pg_catalog.jsonb_build_object('authorized', false);
  end if;
  if not exists (
       select 1 from app_private.identity_accounts
       where user_id = p_actor and account_status = 'active'
     ) then
    insert into app_private.verification_file_access_events (actor_id, evidence_id, event_type, reason_code)
    values (p_actor, p_evidence_id, 'review_download_denied', 'account_restricted');
    return pg_catalog.jsonb_build_object('authorized', false);
  end if;
  if not exists (
    select 1 from app_private.staff_grants
    where user_id = p_actor and capability = 'verification_review' and revoked_at is null
  ) then
    insert into app_private.verification_file_access_events (actor_id, evidence_id, event_type, reason_code)
    values (p_actor, p_evidence_id, 'review_download_denied', 'no_current_grant');
    return pg_catalog.jsonb_build_object('authorized', false);
  end if;
  select * into v_evidence
  from app_private.verification_evidence
  where evidence_id = p_evidence_id and safety_state = 'ready';
  if not found then
    insert into app_private.verification_file_access_events (actor_id, evidence_id, event_type, reason_code)
    values (p_actor, p_evidence_id, 'review_download_denied', 'evidence_not_ready');
    return pg_catalog.jsonb_build_object('authorized', false);
  end if;
  insert into app_private.verification_file_access_events (
    actor_id, submission_id, evidence_id, event_type
  ) values (p_actor, v_evidence.submission_id, v_evidence.evidence_id, 'review_download_issued');
  return pg_catalog.jsonb_build_object(
    'authorized', true,
    'object_key', v_evidence.object_key,
    'storage_bucket', v_evidence.storage_bucket,
    'content_type', v_evidence.content_type,
    'evidence_id', v_evidence.evidence_id
  );
end;
$function$;

create function app_private.list_verification_orphans_for_cleanup(
  p_candidate_keys text[],
  p_before timestamptz
)
returns text[]
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_keys text[];
  v_key text;
begin
  if p_candidate_keys is null or pg_catalog.cardinality(p_candidate_keys) > 1000
     or p_before is null or p_before > pg_catalog.now() - interval '24 hours' then
    raise exception using errcode = '22023', message = 'invalid_cleanup_window';
  end if;
  select coalesce(pg_catalog.array_agg(o.name order by o.name), array[]::text[])
  into v_keys
  from storage.objects o
  join pg_catalog.unnest(p_candidate_keys) candidate(name) on candidate.name = o.name
  where o.bucket_id = 'verification-quarantine'
    and o.created_at < p_before
    and o.name ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f-]{36}/source$'
    and not exists (
      select 1 from app_private.verification_evidence e
      where e.storage_bucket = o.bucket_id and e.object_key = o.name
    )
    and not exists (
      select 1 from app_private.verification_upload_intents i
      where i.object_key = o.name and i.state in ('issued', 'uploading', 'finalized')
    );
  foreach v_key in array v_keys loop
    insert into app_private.verification_file_access_events (
      event_type, reason_code, object_key_sha256
    ) values (
      'orphan_cleanup', 'orphan_age_passed',
      extensions.digest(pg_catalog.convert_to(v_key, 'UTF8'), 'sha256')
    );
  end loop;
  return v_keys;
end;
$function$;

create function app_private.reject_verification_file_access_mutation()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  raise exception using errcode = '55000', message = 'verification file access history is append only';
end;
$function$;
revoke all on function app_private.reject_verification_file_access_mutation() from public, anon, authenticated, service_role;
create trigger verification_file_access_events_append_only
before update or delete on app_private.verification_file_access_events
for each row execute function app_private.reject_verification_file_access_mutation();

create function public.server_begin_verification_upload_for_actor(uuid, uuid, smallint, text, integer, text)
returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.begin_verification_upload_for_actor($1, $2, $3, $4, $5, $6)
$function$;
create function public.server_claim_verification_upload_for_actor(uuid, uuid, text)
returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.claim_verification_upload_for_actor($1, $2, $3)
$function$;
create function public.server_finalize_verification_upload_for_actor(uuid, uuid, integer, text, text)
returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.finalize_verification_upload_for_actor($1, $2, $3, $4, $5)
$function$;
create function public.server_reject_verification_upload_for_actor(uuid, uuid, text)
returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.reject_verification_upload_for_actor($1, $2, $3)
$function$;
create function public.server_get_verification_download_for_actor(uuid, uuid, text)
returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.verification_download_target_for_reviewer($1, $2, $3)
$function$;
create function public.server_list_verification_orphans_for_cleanup(text[], timestamptz)
returns text[] language sql security definer set search_path = '' as $function$
  select app_private.list_verification_orphans_for_cleanup($1, $2)
$function$;

revoke all on table app_private.verification_upload_intents, app_private.verification_file_access_events from public, anon, authenticated, service_role;
revoke all on function app_private.begin_verification_upload_for_actor(uuid, uuid, smallint, text, integer, text) from public, anon, authenticated, service_role;
revoke all on function app_private.claim_verification_upload_for_actor(uuid, uuid, text) from public, anon, authenticated, service_role;
revoke all on function app_private.finalize_verification_upload_for_actor(uuid, uuid, integer, text, text) from public, anon, authenticated, service_role;
revoke all on function app_private.reject_verification_upload_for_actor(uuid, uuid, text) from public, anon, authenticated, service_role;
revoke all on function app_private.verification_download_target_for_reviewer(uuid, uuid, text) from public, anon, authenticated, service_role;
revoke all on function app_private.list_verification_orphans_for_cleanup(text[], timestamptz) from public, anon, authenticated, service_role;
revoke all on function public.server_begin_verification_upload_for_actor(uuid, uuid, smallint, text, integer, text) from public, anon, authenticated, service_role;
revoke all on function public.server_claim_verification_upload_for_actor(uuid, uuid, text) from public, anon, authenticated, service_role;
revoke all on function public.server_finalize_verification_upload_for_actor(uuid, uuid, integer, text, text) from public, anon, authenticated, service_role;
revoke all on function public.server_reject_verification_upload_for_actor(uuid, uuid, text) from public, anon, authenticated, service_role;
revoke all on function public.server_get_verification_download_for_actor(uuid, uuid, text) from public, anon, authenticated, service_role;
revoke all on function public.server_list_verification_orphans_for_cleanup(text[], timestamptz) from public, anon, authenticated, service_role;
grant execute on function public.server_begin_verification_upload_for_actor(uuid, uuid, smallint, text, integer, text) to service_role;
grant execute on function public.server_claim_verification_upload_for_actor(uuid, uuid, text) to service_role;
grant execute on function public.server_finalize_verification_upload_for_actor(uuid, uuid, integer, text, text) to service_role;
grant execute on function public.server_reject_verification_upload_for_actor(uuid, uuid, text) to service_role;
grant execute on function public.server_get_verification_download_for_actor(uuid, uuid, text) to service_role;
grant execute on function public.server_list_verification_orphans_for_cleanup(text[], timestamptz) to service_role;

commit;
