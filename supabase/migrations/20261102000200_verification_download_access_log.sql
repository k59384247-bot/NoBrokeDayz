alter table app_private.verification_file_access_events
  drop constraint verification_file_access_events_event_type_check;

alter table app_private.verification_file_access_events
  add constraint verification_file_access_events_event_type_check check (event_type in (
    'upload_intent_issued', 'upload_claimed', 'upload_rejected',
    'upload_quarantined', 'upload_access_denied', 'review_download_issued',
    'review_download_denied', 'review_download_accessed', 'orphan_cleanup'
  ));

create function app_private.record_verification_download_access_for_actor(
  p_actor uuid,
  p_evidence_id uuid,
  p_object_key text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_submission_id uuid;
begin
  if p_actor is null or p_evidence_id is null or p_object_key is null
     or p_object_key !~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f-]{36}/source$' then
    return pg_catalog.jsonb_build_object('recorded', false);
  end if;

  select submission_id into v_submission_id
  from app_private.verification_evidence
  where evidence_id = p_evidence_id
    and storage_bucket = 'verification-private'
    and object_key = p_object_key;
  if not found then
    return pg_catalog.jsonb_build_object('recorded', false);
  end if;

  insert into app_private.verification_file_access_events (
    actor_id, submission_id, evidence_id, event_type, object_key_sha256
  ) values (
    p_actor, v_submission_id, p_evidence_id, 'review_download_accessed',
    extensions.digest(pg_catalog.convert_to(p_object_key, 'UTF8'), 'sha256')
  );
  return pg_catalog.jsonb_build_object('recorded', true);
end;
$function$;

create function public.server_record_verification_download_access_for_actor(uuid, uuid, text)
returns jsonb
language sql
security definer
set search_path = ''
as $function$
  select app_private.record_verification_download_access_for_actor($1, $2, $3)
$function$;

revoke all on function app_private.record_verification_download_access_for_actor(uuid, uuid, text) from public, anon, authenticated, service_role;
revoke all on function public.server_record_verification_download_access_for_actor(uuid, uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.server_record_verification_download_access_for_actor(uuid, uuid, text) to service_role;
