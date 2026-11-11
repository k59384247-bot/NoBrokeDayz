begin;

-- Serialize duplicate decision keys before reading the idempotency row. This
-- makes two concurrent copies return the same committed result instead of the
-- later copy falling through to a stale-state response.
create or replace function app_private.review_verification(p_actor uuid,p_submission uuid,p_expected_version integer,p_expected_status text,p_expected_decision integer,p_decision text,p_reason text,p_key uuid,p_aal text)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare v_s app_private.verification_submissions%rowtype; v_hash bytea; v_old app_private.verification_decision_requests%rowtype; v_event uuid; v_result jsonb; v_dv integer;
begin
 if p_actor is null or p_submission is null or p_key is null or not app_private.reviewer_is_current(p_actor,p_aal) or p_reason is null or char_length(btrim(p_reason)) not between 20 and 500 or p_decision not in ('needs_information','rejected','approved','revoked') then raise exception using errcode='42501',message='reviewer_not_authorized'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('verification-decision:'||p_actor::text||':'||p_key::text,702071));
 v_hash:=extensions.digest(pg_catalog.convert_to(pg_catalog.jsonb_build_array(p_submission,p_expected_version,p_expected_status,p_expected_decision,p_decision,p_reason)::text,'UTF8'),'sha256');
 select * into v_old from app_private.verification_decision_requests where reviewer_id=p_actor and idempotency_key=p_key;
 if found then if v_old.request_sha256<>v_hash then raise exception using errcode='23505',message='idempotency_conflict'; end if; return v_old.result; end if;
 select * into v_s from app_private.verification_submissions where submission_id=p_submission for update;
 if not found or v_s.submission_version<>p_expected_version or v_s.status<>p_expected_status or v_s.status not in ('pending','approved') or not exists(select 1 from app_private.verification_review_assignments a where a.submission_id=p_submission and a.reviewer_id=p_actor and a.ended_at is null) then return pg_catalog.jsonb_build_object('error','stale_state'); end if;
 select coalesce(max(decision_version),0) into v_dv from app_private.verification_reviews where submission_id=p_submission;
 if v_dv<>p_expected_decision or (p_decision='revoked' and v_s.status<>'approved') or (p_decision<>'revoked' and v_s.status<>'pending') then return pg_catalog.jsonb_build_object('error','stale_state'); end if;
 if p_decision='approved' and not app_private.verification_submission_evidence_complete(p_submission) then raise exception using errcode='22023',message='evidence_not_ready'; end if;
 insert into app_private.verification_reviews(submission_id,reviewer_id,decision,reason,decision_version) values(p_submission,p_actor,p_decision,p_reason,v_dv+1);
 if p_decision='revoked' then update app_private.verification_submissions set status='revoked' where submission_id=p_submission; else update app_private.verification_submissions set status=p_decision where submission_id=p_submission; end if;
 update app_private.identity_accounts set verification_status=case when p_decision='revoked' then 'rejected' else p_decision end,updated_at=pg_catalog.now() where user_id=v_s.user_id;
 if p_decision='revoked' then update app_private.identity_capabilities set revoked_at=pg_catalog.now() where user_id=v_s.user_id and source in ('track_a_manual','track_b_partner') and revoked_at is null; elsif p_decision='approved' then perform app_private.reconcile_manual_partner_capabilities(v_s.user_id); end if;
 insert into app_private.identity_audit_events(actor_id,subject_id,event_type,event_data) values(p_actor,v_s.user_id,'verification_reviewed',pg_catalog.jsonb_build_object('submission_id',p_submission,'decision',p_decision,'version',v_s.submission_version,'decision_version',v_dv+1)) returning event_id into v_event;
 insert into app_private.identity_outbox(event_id,subject_id,event_type,payload) values(v_event,v_s.user_id,'verification_result',pg_catalog.jsonb_build_object('submission_id',p_submission,'status',p_decision,'reason',p_reason));
 v_result:=pg_catalog.jsonb_build_object('submission_id',p_submission,'status',p_decision,'decision_version',v_dv+1);
 insert into app_private.verification_decision_requests(reviewer_id,idempotency_key,request_sha256,result) values(p_actor,p_key,v_hash,v_result);
 return v_result;
end;$function$;
revoke all on function app_private.review_verification(uuid,uuid,integer,text,integer,text,text,uuid,text) from public,anon,authenticated,service_role;
grant execute on function app_private.review_verification(uuid,uuid,integer,text,integer,text,text,uuid,text) to postgres;
commit;
