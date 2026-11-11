begin;

create extension if not exists pgtap with schema extensions;
select plan(47);

select set_config('test.file_owner', id::text, true)
from auth.users where email = 'phase2-owner@identity.test';
select set_config('test.file_other', id::text, true)
from auth.users where email = 'phase2-other@identity.test';
select set_config('test.file_submission', pg_catalog.gen_random_uuid()::text, true);

insert into app_private.identity_accounts (user_id, account_type, age_confirmed_at, age_policy_version)
values
  (current_setting('test.file_owner')::uuid, 'student', pg_catalog.now(), 'age-18-v1'),
  (current_setting('test.file_other')::uuid, 'student', pg_catalog.now(), 'age-18-v1')
on conflict (user_id) do nothing;
insert into app_private.verification_submissions (
  submission_id, user_id, submission_version, track, legal_name, narrative
)
values (
  current_setting('test.file_submission')::uuid,
  current_setting('test.file_owner')::uuid,
  1,
  'track_a_manual',
  'Synthetic Student',
  'Synthetic local test submission for evidence upload boundary tests.'
);

select is((select public from storage.buckets where id = 'verification-quarantine'), false, 'quarantine bucket is private');
select is((select public from storage.buckets where id = 'verification-private'), false, 'final evidence bucket is private');
select is((select file_size_limit from storage.buckets where id = 'verification-quarantine'), 5000000::bigint, 'quarantine bucket enforces the approved five megabyte byte limit');
select is((select file_size_limit from storage.buckets where id = 'verification-private'), 5000000::bigint, 'final evidence bucket enforces the approved five megabyte byte limit');
select is((select allowed_mime_types from storage.buckets where id = 'verification-quarantine'), array['image/jpeg', 'image/png', 'application/pdf']::text[], 'quarantine bucket allow-lists only the approved formats');
select is((select allowed_mime_types from storage.buckets where id = 'verification-private'), array['image/jpeg', 'image/png', 'application/pdf']::text[], 'final evidence bucket allow-lists only the approved formats');
select ok(exists (
  select 1 from pg_catalog.pg_policy
  where polrelid = 'storage.objects'::regclass
    and polname = 'verification_buckets_block_browser_roles'
    and polcmd = '*'
    and polpermissive = false
    and polroles @> array[(select oid from pg_catalog.pg_roles where rolname = 'anon')]
    and polroles @> array[(select oid from pg_catalog.pg_roles where rolname = 'authenticated')]
), 'storage object RLS explicitly restricts browser roles from both evidence buckets');
select ok(not has_table_privilege('authenticated', 'app_private.verification_upload_intents', 'SELECT'), 'browser cannot read upload tokens or intents');
select ok(not has_table_privilege('authenticated', 'app_private.verification_file_access_events', 'SELECT'), 'browser cannot read access logs');
select ok(not has_table_privilege('authenticated', 'app_private.verification_evidence', 'SELECT'), 'browser cannot read evidence metadata');
select ok(not has_table_privilege('service_role', 'app_private.verification_upload_intents', 'SELECT'), 'server executor cannot read private intents directly');
select ok(has_function_privilege('service_role', 'public.server_begin_verification_upload_for_actor(uuid,uuid,smallint,text,integer,text,text)', 'EXECUTE'), 'server can begin through narrow upload command');
select ok(has_function_privilege('service_role', 'public.server_claim_verification_upload_for_actor(uuid,uuid,text)', 'EXECUTE'), 'server can claim through narrow upload command');
select ok(has_function_privilege('service_role', 'public.server_finalize_verification_upload_for_actor(uuid,uuid,integer,text,text)', 'EXECUTE'), 'server can finalize checked bytes through narrow upload command');
select ok(has_function_privilege('service_role', 'public.server_reject_verification_upload_for_actor(uuid,uuid,text)', 'EXECUTE'), 'server can reject unsafe bytes through narrow upload command');
select ok(has_function_privilege('service_role', 'public.server_get_verification_download_for_actor(uuid,uuid,text)', 'EXECUTE'), 'server can request a gated reviewer download target');
select ok(has_function_privilege('service_role', 'public.server_record_verification_download_access_for_actor(uuid,uuid,text)', 'EXECUTE'), 'server can record each fetched reviewer download');
select ok(has_function_privilege('service_role', 'public.server_list_verification_orphans_for_cleanup(text[],timestamp with time zone)', 'EXECUTE'), 'server can request narrowly filtered orphan cleanup keys');
select ok(not exists (
  select 1 from (values
    ('server_begin_verification_upload_for_actor', array['p_actor','p_submission_id','p_evidence_position','p_content_type','p_size_bytes','p_token_hash_hex','p_evidence_kind']::text[]),
    ('server_claim_verification_upload_for_actor', array['p_actor','p_intent_id','p_token_hash_hex']::text[]),
    ('server_finalize_verification_upload_for_actor', array['p_actor','p_intent_id','p_size_bytes','p_content_type','p_sha256_hex']::text[]),
    ('server_reject_verification_upload_for_actor', array['p_actor','p_intent_id','p_reason_code']::text[]),
    ('server_get_verification_download_for_actor', array['p_actor','p_evidence_id','p_auth_aal']::text[]),
    ('server_list_verification_orphans_for_cleanup', array['p_candidate_keys','p_before']::text[]),
    ('server_record_verification_download_access_for_actor', array['p_actor','p_evidence_id','p_object_key']::text[])
  ) expected(function_name, argument_names)
  where not exists (
    select 1 from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = expected.function_name
      and p.proargnames = expected.argument_names
  )
), 'all server RPC arguments have stable names for PostgREST calls');
select ok(not has_function_privilege('anon', 'public.server_begin_verification_upload_for_actor(uuid,uuid,smallint,text,integer,text,text)', 'EXECUTE'), 'anonymous cannot issue evidence uploads');
select ok(not has_function_privilege('authenticated', 'public.server_begin_verification_upload_for_actor(uuid,uuid,smallint,text,integer,text,text)', 'EXECUTE'), 'authenticated cannot bypass the evidence upload handler');
select ok(not has_function_privilege('authenticated', 'public.server_finalize_verification_upload_for_actor(uuid,uuid,integer,text,text)', 'EXECUTE'), 'authenticated cannot finalize evidence metadata');
select ok(not has_function_privilege('authenticated', 'public.server_get_verification_download_for_actor(uuid,uuid,text)', 'EXECUTE'), 'authenticated cannot mint reviewer links directly');
select ok(not has_function_privilege('authenticated', 'public.server_record_verification_download_access_for_actor(uuid,uuid,text)', 'EXECUTE'), 'authenticated cannot forge reviewer download access records');
select ok(not has_function_privilege('authenticated', 'public.server_list_verification_orphans_for_cleanup(text[],timestamp with time zone)', 'EXECUTE'), 'authenticated cannot request orphan cleanup');
select ok((select prosecdef and proconfig @> array['search_path=""']::text[] from pg_catalog.pg_proc where oid = 'public.server_begin_verification_upload_for_actor(uuid,uuid,smallint,text,integer,text,text)'::regprocedure), 'upload gateway is security-definer with fixed empty search path');
select ok((select prosecdef and proconfig @> array['search_path=""']::text[] from pg_catalog.pg_proc where oid = 'public.server_get_verification_download_for_actor(uuid,uuid,text)'::regprocedure), 'download gateway is security-definer with fixed empty search path');
select ok((select prosecdef and proconfig @> array['search_path=""']::text[] from pg_catalog.pg_proc where oid = 'public.server_list_verification_orphans_for_cleanup(text[],timestamp with time zone)'::regprocedure), 'orphan cleanup gateway is security-definer with fixed empty search path');
select ok(exists (select 1 from pg_catalog.pg_trigger where tgrelid = 'app_private.verification_file_access_events'::regclass and tgname = 'verification_file_access_events_append_only' and not tgisinternal), 'evidence access history is append-only');

set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('test.file_owner'), true);
select throws_ok(
  $$insert into storage.objects (bucket_id, name) values ('verification-quarantine', current_setting('test.file_owner') || '/fake/source')$$,
  '42501', null, 'authenticated user cannot write evidence objects directly'
);
select throws_ok(
  $$select public.server_begin_verification_upload_for_actor(current_setting('test.file_owner')::uuid, current_setting('test.file_submission')::uuid, 1::smallint, 'image/png', 100, repeat('a',64), 'student_id')$$,
  '42501', null, 'authenticated user cannot mint upload intent through the server gateway'
);
reset role;

set local role service_role;
select set_config('test.file_begin_result', public.server_begin_verification_upload_for_actor(
  current_setting('test.file_owner')::uuid,
  current_setting('test.file_submission')::uuid,
  1::smallint,
  'image/png',
  68,
  repeat('a', 64),
  'student_id'
 )::text, true);
select set_config('test.file_intent', (current_setting('test.file_begin_result')::jsonb->>'intent_id'), true);
select set_config('test.file_evidence', (current_setting('test.file_begin_result')::jsonb->>'evidence_id'), true);
reset role;
select is((select state from app_private.verification_upload_intents where intent_id = current_setting('test.file_intent')::uuid), 'issued', 'upload starts with a private, short-lived intent');

set local role service_role;
select is(public.server_claim_verification_upload_for_actor(
  current_setting('test.file_other')::uuid,
  current_setting('test.file_intent')::uuid,
  repeat('a', 64)
)->>'claimed', 'false', 'another account cannot claim the upload intent');
select is(public.server_claim_verification_upload_for_actor(
  current_setting('test.file_owner')::uuid,
  current_setting('test.file_intent')::uuid,
  repeat('a', 64)
)->>'claimed', 'true', 'the owner can claim the matching upload token once');
select is(public.server_claim_verification_upload_for_actor(
  current_setting('test.file_owner')::uuid,
  current_setting('test.file_intent')::uuid,
  repeat('a', 64)
)->>'claimed', 'false', 'a claimed upload token cannot be replayed');
reset role;
select is((select count(*)::integer from app_private.verification_file_access_events where actor_id = current_setting('test.file_other')::uuid and event_type = 'upload_access_denied'), 1, 'cross-account upload denial is retained in the private access log');

set local role service_role;
select is(public.server_finalize_verification_upload_for_actor(
  current_setting('test.file_owner')::uuid,
  current_setting('test.file_intent')::uuid,
  68,
  'image/png',
  repeat('b', 64)
)->>'reviewable', 'false', 'finalized bytes remain unavailable in quarantine without a scanner');
reset role;

select is((select safety_state from app_private.verification_evidence where evidence_id = (select evidence_id from app_private.verification_upload_intents where intent_id = current_setting('test.file_intent')::uuid)), 'quarantined', 'finalized unscanned evidence cannot become reviewable');
select is((select octet_length(content_sha256) from app_private.verification_evidence where evidence_id = (select evidence_id from app_private.verification_upload_intents where intent_id = current_setting('test.file_intent')::uuid)), 32, 'finalization stores only a 32-byte SHA-256 digest');
update app_private.verification_evidence
set storage_bucket = 'verification-private', safety_state = 'ready'
where evidence_id = current_setting('test.file_evidence')::uuid;
select set_config('test.file_object_key', (select object_key from app_private.verification_evidence where evidence_id = current_setting('test.file_evidence')::uuid), true);
set local role service_role;
select is(public.server_record_verification_download_access_for_actor(
  current_setting('test.file_owner')::uuid,
  current_setting('test.file_evidence')::uuid,
  current_setting('test.file_object_key')
)->>'recorded', 'true', 'download fetch is recorded only for its finalized private object');
select is(public.server_record_verification_download_access_for_actor(
  current_setting('test.file_owner')::uuid,
  current_setting('test.file_evidence')::uuid,
  '00000000-0000-0000-0000-000000000000/00000000-0000-0000-0000-000000000000/00000000-0000-0000-0000-000000000000/source'
)->>'recorded', 'false', 'download access log rejects a mismatched object key');
reset role;
select is((select count(*)::integer from app_private.verification_file_access_events where actor_id = current_setting('test.file_owner')::uuid and evidence_id = current_setting('test.file_evidence')::uuid and event_type = 'review_download_accessed'), 1, 'successful reviewer byte fetch is retained in the append-only access log');
set local role service_role;
select throws_ok(
  $$select public.server_begin_verification_upload_for_actor(current_setting('test.file_owner')::uuid, current_setting('test.file_submission')::uuid, 1::smallint, 'image/png', 68, repeat('c',64), 'student_id')$$,
  '23505', 'evidence_kind_already_used', 'finalized evidence cannot be overwritten by requesting a new upload for the same slot'
);
reset role;
select set_config('test.file_resubmission', pg_catalog.gen_random_uuid()::text, true);
insert into app_private.verification_submissions (
  submission_id, user_id, submission_version, track, legal_name, narrative
) values (
  current_setting('test.file_resubmission')::uuid,
  current_setting('test.file_owner')::uuid,
  2,
  'track_a_manual',
  'Synthetic Student',
  'Synthetic resubmission keeps the prior finalized evidence version unchanged.'
);
set local role service_role;
select set_config('test.file_resubmission_intent', public.server_begin_verification_upload_for_actor(
  current_setting('test.file_owner')::uuid,
  current_setting('test.file_resubmission')::uuid,
  1::smallint,
  'image/png',
  68,
  repeat('c', 64),
  'student_id'
)->>'intent_id', true);
reset role;
select isnt(
  (select object_key from app_private.verification_upload_intents where intent_id = current_setting('test.file_resubmission_intent')::uuid),
  (select object_key from app_private.verification_evidence where evidence_id = current_setting('test.file_evidence')::uuid),
  'resubmission gets a new object key and preserves prior evidence history'
);
set local role service_role;
select is(public.server_get_verification_download_for_actor(
  current_setting('test.file_other')::uuid,
  current_setting('test.file_evidence')::uuid,
  'aal2'
)->>'authorized', 'false', 'reviewer without an active grant cannot get a download target');
reset role;
select is((select count(*)::integer from app_private.verification_file_access_events where actor_id = current_setting('test.file_other')::uuid and event_type = 'review_download_denied'), 1, 'denied review link request is retained in the private access log');
set local role service_role;
select throws_ok(
  $$select public.server_list_verification_orphans_for_cleanup(array[]::text[], pg_catalog.now())$$,
  '22023', 'invalid_cleanup_window', 'orphan cleanup cannot use a cutoff newer than the 24-hour quarantine threshold'
);
reset role;

select * from finish();
rollback;
