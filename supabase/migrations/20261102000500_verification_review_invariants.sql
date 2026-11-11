begin;

-- Forward-safe refinements to the Step 7 workflow. Kept separate so a local
-- database that already applied the first Step 7 migration can advance without
-- rewriting recorded migration history.
alter table app_private.verification_submissions
  add column if not exists campus_connection_type text
    check (campus_connection_type is null or campus_connection_type in ('shop_photo','staff_id','student_endorsement'));

create or replace function app_private.guard_verification_submission_update()
returns trigger language plpgsql set search_path = '' as $function$
begin
  if new.submission_id is distinct from old.submission_id or new.user_id is distinct from old.user_id
     or new.submission_version is distinct from old.submission_version or new.track is distinct from old.track
     or new.legal_name is distinct from old.legal_name or new.narrative is distinct from old.narrative
     or new.campus_connection_type is distinct from old.campus_connection_type
     or new.submitted_at is distinct from old.submitted_at or new.created_at is distinct from old.created_at then
    raise exception using errcode='55000',message='verification submission fields are immutable';
  end if;
  if not ((old.status='pending' and new.status in ('needs_information','rejected','approved'))
          or (old.status='approved' and new.status='revoked')) then
    raise exception using errcode='55000',message='verification submission transition not allowed';
  end if;
  new.updated_at:=pg_catalog.now(); return new;
end;$function$;

create or replace function app_private.submit_verification_for_actor(p_actor uuid,p_idempotency_key uuid,p_legal_name text,p_narrative text,p_connection_type text)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare v_account app_private.identity_accounts%rowtype; v_track text; v_hash bytea; v_previous app_private.verification_submission_requests%rowtype; v_version integer; v_submission uuid; v_event uuid;
begin
 if p_actor is null or p_idempotency_key is null then raise exception using errcode='22023',message='invalid_request'; end if;
 select * into v_account from app_private.identity_accounts where user_id=p_actor for update;
 if not found or v_account.account_status<>'active' then raise exception using errcode='22023',message='account_not_eligible'; end if;
 if v_account.account_type='student' then
   if exists(select 1 from app_private.institutional_email_ownerships o join app_private.institutional_email_domains d on d.domain=pg_catalog.split_part(o.normalized_email,'@',2) and d.enabled where o.user_id=p_actor and o.revoked_at is null) then raise exception using errcode='22023',message='manual_review_not_available'; end if;
   v_track:='track_a_manual';
   if p_legal_name is not null or p_connection_type is not null or p_narrative is null or char_length(p_narrative) not between 20 and 1000 then raise exception using errcode='22023',message='invalid_submission'; end if;
 else
   v_track:='track_b_partner';
   if p_legal_name is null or char_length(btrim(p_legal_name)) not between 2 and 120 or p_connection_type not in ('shop_photo','staff_id','student_endorsement') or p_narrative is null or char_length(p_narrative) not between 20 and 1000 then raise exception using errcode='22023',message='invalid_submission'; end if;
 end if;
 v_hash:=extensions.digest(pg_catalog.convert_to(pg_catalog.jsonb_build_array(v_track,p_legal_name,p_narrative,p_connection_type)::text,'UTF8'),'sha256');
 select * into v_previous from app_private.verification_submission_requests where user_id=p_actor and idempotency_key=p_idempotency_key;
 if found then if v_previous.request_sha256<>v_hash then raise exception using errcode='23505',message='idempotency_conflict'; end if; return pg_catalog.jsonb_build_object('submission_id',v_previous.submission_id,'idempotent',true); end if;
 if exists(select 1 from app_private.verification_submissions where user_id=p_actor and track=v_track and status in ('pending','approved')) then raise exception using errcode='23505',message='submission_already_open'; end if;
 select coalesce(max(submission_version),0)+1 into v_version from app_private.verification_submissions where user_id=p_actor and track=v_track;
 insert into app_private.verification_submissions(user_id,submission_version,track,status,legal_name,narrative,campus_connection_type) values(p_actor,v_version,v_track,'pending',p_legal_name,p_narrative,p_connection_type) returning submission_id into v_submission;
 update app_private.identity_accounts set verification_track=v_track,verification_status='pending',updated_at=pg_catalog.now() where user_id=p_actor;
 insert into app_private.verification_submission_requests(user_id,idempotency_key,request_sha256,submission_id) values(p_actor,p_idempotency_key,v_hash,v_submission);
 insert into app_private.identity_audit_events(actor_id,subject_id,event_type,event_data) values(p_actor,p_actor,'verification_submitted',pg_catalog.jsonb_build_object('submission_id',v_submission,'version',v_version,'track',v_track)) returning event_id into v_event;
 insert into app_private.identity_outbox(event_id,subject_id,event_type,payload) values(v_event,p_actor,'verification_result',pg_catalog.jsonb_build_object('submission_id',v_submission,'status','pending'));
 return pg_catalog.jsonb_build_object('submission_id',v_submission,'version',v_version,'status','pending','idempotent',false);
end;$function$;

create or replace function app_private.review_verification(p_actor uuid,p_submission uuid,p_expected_version integer,p_expected_status text,p_expected_decision integer,p_decision text,p_reason text,p_key uuid,p_aal text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
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

create or replace function app_private.verification_submission_evidence_complete(p_submission uuid) returns boolean
language sql stable security definer set search_path = '' as $function$
 select case when s.track='track_a_manual' then exists(select 1 from app_private.verification_evidence e where e.submission_id=s.submission_id and e.evidence_kind='student_id' and e.safety_state='ready' and e.storage_bucket='verification-private')
 when s.track='track_b_partner' then exists(select 1 from app_private.verification_evidence e where e.submission_id=s.submission_id and e.evidence_kind='government_id' and e.safety_state='ready' and e.storage_bucket='verification-private') and (case s.campus_connection_type when 'shop_photo' then exists(select 1 from app_private.verification_evidence e where e.submission_id=s.submission_id and e.evidence_kind='campus_shop_location' and e.safety_state='ready' and e.storage_bucket='verification-private') when 'staff_id' then exists(select 1 from app_private.verification_evidence e where e.submission_id=s.submission_id and e.evidence_kind='campus_staff_id' and e.safety_state='ready' and e.storage_bucket='verification-private') when 'student_endorsement' then exists(select 1 from app_private.verification_endorsements e join app_private.identity_accounts a on a.user_id=e.endorser_id and a.account_status='active' and a.account_type='student' and a.verification_status='approved' join app_private.identity_capabilities c on c.user_id=e.endorser_id and c.capability='can_work' and c.revoked_at is null where e.submission_id=s.submission_id) else false end) else false end
 from app_private.verification_submissions s where s.submission_id=p_submission
$function$;

create or replace function app_private.reconcile_manual_partner_capabilities(p_actor uuid) returns void
language plpgsql security definer set search_path = '' as $function$
declare v app_private.identity_accounts%rowtype;
begin
 select * into v from app_private.identity_accounts where user_id=p_actor;
 if not found then return; end if;
 if v.account_status<>'active' or v.verification_status<>'approved' or v.age_confirmed_at is null or not exists(select 1 from auth.users u join app_private.identity_phone_bindings b on b.user_id=u.id and b.phone_e164='+'||u.phone and b.verified_at=u.phone_confirmed_at where u.id=p_actor and u.email_confirmed_at is not null and u.phone_confirmed_at is not null and nullif(u.phone_change,'') is null) then
   update app_private.identity_capabilities set revoked_at=now() where user_id=p_actor and source in ('track_a_manual','track_b_partner') and revoked_at is null; return;
 end if;
 if v.account_type='student' and v.verification_track='track_a_manual' then
   insert into app_private.identity_capabilities(user_id,capability,source) values(p_actor,'can_hire','track_a_manual'),(p_actor,'can_work','track_a_manual') on conflict(user_id,capability) do update set source=excluded.source,granted_at=now(),revoked_at=null;
 elsif v.account_type='partner' and v.verification_track='track_b_partner' then
   update app_private.identity_capabilities set revoked_at=now() where user_id=p_actor and capability='can_work' and source='track_b_partner' and revoked_at is null;
   insert into app_private.identity_capabilities(user_id,capability,source) values(p_actor,'can_hire','track_b_partner') on conflict(user_id,capability) do update set source=excluded.source,granted_at=now(),revoked_at=null;
 end if;
end;$function$;

create or replace function app_private.verification_download_target_for_reviewer(p_actor uuid,p_evidence_id uuid,p_auth_aal text)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare v_e app_private.verification_evidence%rowtype;
begin
 if p_auth_aal is distinct from 'aal2' or not app_private.reviewer_is_current(p_actor,p_auth_aal) then insert into app_private.verification_file_access_events(actor_id,evidence_id,event_type,reason_code) values(p_actor,p_evidence_id,'review_download_denied','no_current_grant'); return jsonb_build_object('authorized',false); end if;
 select e.* into v_e from app_private.verification_evidence e join app_private.verification_review_assignments a on a.submission_id=e.submission_id and a.reviewer_id=p_actor and a.ended_at is null where e.evidence_id=p_evidence_id and e.safety_state='ready' and e.storage_bucket='verification-private';
 if not found then insert into app_private.verification_file_access_events(actor_id,evidence_id,event_type,reason_code) values(p_actor,p_evidence_id,'review_download_denied','evidence_not_ready'); return jsonb_build_object('authorized',false); end if;
 insert into app_private.verification_file_access_events(actor_id,submission_id,evidence_id,event_type) values(p_actor,v_e.submission_id,v_e.evidence_id,'review_download_issued');
 return jsonb_build_object('authorized',true,'object_key',v_e.object_key,'storage_bucket',v_e.storage_bucket,'content_type',v_e.content_type,'evidence_id',v_e.evidence_id);
end;$function$;

drop trigger if exists auth_users_reconcile_reviewed_identity on auth.users;
drop function if exists app_private.reconcile_reviewed_identity_after_auth_change();
create function app_private.reconcile_reviewed_identity_after_auth_change() returns trigger
language plpgsql security definer set search_path = '' as $function$
begin
 if old.email_confirmed_at is distinct from new.email_confirmed_at or old.phone is distinct from new.phone or old.phone_change is distinct from new.phone_change or old.phone_confirmed_at is distinct from new.phone_confirmed_at then perform app_private.reconcile_manual_partner_capabilities(new.id); end if;
 return new;
end;$function$;
create trigger auth_users_reconcile_reviewed_identity after update of email_confirmed_at,phone,phone_change,phone_confirmed_at on auth.users for each row execute function app_private.reconcile_reviewed_identity_after_auth_change();

revoke all on function app_private.guard_verification_submission_update(),app_private.submit_verification_for_actor(uuid,uuid,text,text,text),app_private.review_verification(uuid,uuid,integer,text,integer,text,text,uuid,text),app_private.verification_submission_evidence_complete(uuid),app_private.reconcile_manual_partner_capabilities(uuid),app_private.verification_download_target_for_reviewer(uuid,uuid,text),app_private.reconcile_reviewed_identity_after_auth_change() from public,anon,authenticated,service_role;
grant execute on function app_private.submit_verification_for_actor(uuid,uuid,text,text,text),app_private.review_verification(uuid,uuid,integer,text,integer,text,text,uuid,text),app_private.verification_submission_evidence_complete(uuid),app_private.reconcile_manual_partner_capabilities(uuid),app_private.verification_download_target_for_reviewer(uuid,uuid,text) to postgres;
commit;
