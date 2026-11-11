begin;

drop function public.server_begin_verification_upload_for_actor(uuid, uuid, smallint, text, integer, text);
drop function public.server_claim_verification_upload_for_actor(uuid, uuid, text);
drop function public.server_finalize_verification_upload_for_actor(uuid, uuid, integer, text, text);
drop function public.server_reject_verification_upload_for_actor(uuid, uuid, text);
drop function public.server_get_verification_download_for_actor(uuid, uuid, text);
drop function public.server_list_verification_orphans_for_cleanup(text[], timestamptz);
drop function public.server_record_verification_download_access_for_actor(uuid, uuid, text);

create function public.server_begin_verification_upload_for_actor(
  p_actor uuid, p_submission_id uuid, p_evidence_position smallint,
  p_content_type text, p_size_bytes integer, p_token_hash_hex text
)
returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.begin_verification_upload_for_actor($1, $2, $3, $4, $5, $6)
$function$;
create function public.server_claim_verification_upload_for_actor(
  p_actor uuid, p_intent_id uuid, p_token_hash_hex text
)
returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.claim_verification_upload_for_actor($1, $2, $3)
$function$;
create function public.server_finalize_verification_upload_for_actor(
  p_actor uuid, p_intent_id uuid, p_size_bytes integer,
  p_content_type text, p_sha256_hex text
)
returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.finalize_verification_upload_for_actor($1, $2, $3, $4, $5)
$function$;
create function public.server_reject_verification_upload_for_actor(
  p_actor uuid, p_intent_id uuid, p_reason_code text
)
returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.reject_verification_upload_for_actor($1, $2, $3)
$function$;
create function public.server_get_verification_download_for_actor(
  p_actor uuid, p_evidence_id uuid, p_auth_aal text
)
returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.verification_download_target_for_reviewer($1, $2, $3)
$function$;
create function public.server_list_verification_orphans_for_cleanup(
  p_candidate_keys text[], p_before timestamptz
)
returns text[] language sql security definer set search_path = '' as $function$
  select app_private.list_verification_orphans_for_cleanup($1, $2)
$function$;
create function public.server_record_verification_download_access_for_actor(
  p_actor uuid, p_evidence_id uuid, p_object_key text
)
returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.record_verification_download_access_for_actor($1, $2, $3)
$function$;

revoke all on function public.server_begin_verification_upload_for_actor(uuid, uuid, smallint, text, integer, text) from public, anon, authenticated, service_role;
revoke all on function public.server_claim_verification_upload_for_actor(uuid, uuid, text) from public, anon, authenticated, service_role;
revoke all on function public.server_finalize_verification_upload_for_actor(uuid, uuid, integer, text, text) from public, anon, authenticated, service_role;
revoke all on function public.server_reject_verification_upload_for_actor(uuid, uuid, text) from public, anon, authenticated, service_role;
revoke all on function public.server_get_verification_download_for_actor(uuid, uuid, text) from public, anon, authenticated, service_role;
revoke all on function public.server_list_verification_orphans_for_cleanup(text[], timestamptz) from public, anon, authenticated, service_role;
revoke all on function public.server_record_verification_download_access_for_actor(uuid, uuid, text) from public, anon, authenticated, service_role;

grant execute on function public.server_begin_verification_upload_for_actor(uuid, uuid, smallint, text, integer, text) to service_role;
grant execute on function public.server_claim_verification_upload_for_actor(uuid, uuid, text) to service_role;
grant execute on function public.server_finalize_verification_upload_for_actor(uuid, uuid, integer, text, text) to service_role;
grant execute on function public.server_reject_verification_upload_for_actor(uuid, uuid, text) to service_role;
grant execute on function public.server_get_verification_download_for_actor(uuid, uuid, text) to service_role;
grant execute on function public.server_list_verification_orphans_for_cleanup(text[], timestamptz) to service_role;
grant execute on function public.server_record_verification_download_access_for_actor(uuid, uuid, text) to service_role;

commit;
