begin;

-- Keep all objects used by the staff queue helpers schema-qualified while the
-- fixed empty search_path is in force.
create or replace function app_private.list_verification_candidates(
  p_actor uuid,
  p_aal text
) returns jsonb
language plpgsql stable security definer set search_path = '' as $function$
declare
  v_result jsonb;
begin
  if not app_private.reviewer_is_current(p_actor,p_aal) then
    raise exception using errcode='42501',message='reviewer_not_authorized';
  end if;
  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'submission_id',s.submission_id,
        'track',s.track,
        'submitted_at',s.submitted_at,
        'status',s.status
      )
    ),
    '[]'::jsonb
  ) into v_result
  from app_private.verification_submissions s
  where s.status='pending'
    and not exists(
      select 1 from app_private.verification_review_assignments x
      where x.submission_id=s.submission_id and x.ended_at is null
    );
  return v_result;
end;$function$;

create or replace function app_private.list_verification_queue(
  p_actor uuid,
  p_aal text
) returns jsonb
language plpgsql stable security definer set search_path = '' as $function$
declare
  v_result jsonb;
begin
  if not app_private.reviewer_is_current(p_actor,p_aal) then
    raise exception using errcode='42501',message='reviewer_not_authorized';
  end if;
  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'submission_id',s.submission_id,
        'user_id',s.user_id,
        'version',s.submission_version,
        'track',s.track,
        'legal_name',s.legal_name,
        'narrative',s.narrative,
        'submitted_at',s.submitted_at,
        'evidence',coalesce(
          (
            select pg_catalog.jsonb_agg(
              pg_catalog.jsonb_build_object(
                'evidence_id',e.evidence_id,
                'kind',e.evidence_kind,
                'content_type',e.content_type,
                'size_bytes',e.size_bytes,
                'safety_state',e.safety_state
              )
            )
            from app_private.verification_evidence e
            where e.submission_id=s.submission_id
          ),
          '[]'::jsonb
        )
      )
    ),
    '[]'::jsonb
  ) into v_result
  from app_private.verification_submissions s
  join app_private.verification_review_assignments a
    on a.submission_id=s.submission_id
   and a.reviewer_id=p_actor
   and a.ended_at is null
  where s.status='pending';
  return v_result;
end;$function$;

revoke all on function app_private.list_verification_candidates(uuid,text),
  app_private.list_verification_queue(uuid,text)
from public,anon,authenticated,service_role;
grant execute on function app_private.list_verification_candidates(uuid,text),
  app_private.list_verification_queue(uuid,text)
to postgres;

commit;
