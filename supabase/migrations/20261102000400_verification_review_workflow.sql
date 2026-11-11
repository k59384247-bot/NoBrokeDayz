begin;

-- Step 7: purpose-labelled evidence and versioned manual review. All original
-- files remain quarantined until a future, explicitly approved scanner exists.
alter table app_private.verification_evidence
  add column evidence_kind text not null default 'student_id'
    check (evidence_kind in ('student_id', 'government_id', 'campus_shop_location', 'campus_staff_id'));
alter table app_private.verification_upload_intents
  add column evidence_kind text not null default 'student_id'
    check (evidence_kind in ('student_id', 'government_id', 'campus_shop_location', 'campus_staff_id'));
alter table app_private.verification_submissions
  drop constraint verification_submissions_status_check;
alter table app_private.verification_submissions
  add constraint verification_submissions_status_check
    check (status in ('pending', 'needs_information', 'rejected', 'approved', 'revoked'));
alter table app_private.verification_submissions
  add column campus_connection_type text
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
alter table app_private.verification_reviews
  drop constraint verification_reviews_decision_check;
alter table app_private.verification_reviews
  add constraint verification_reviews_decision_check
    check (decision in ('needs_information', 'rejected', 'approved', 'revoked'));

create table app_private.verification_submission_requests (
  user_id uuid not null references auth.users(id) on delete restrict,
  idempotency_key uuid not null,
  request_sha256 bytea not null check (octet_length(request_sha256)=32),
  submission_id uuid not null references app_private.verification_submissions(submission_id) on delete restrict,
  created_at timestamptz not null default pg_catalog.now(),
  primary key(user_id,idempotency_key)
);
create table app_private.verification_endorsements (
  endorsement_id uuid primary key default pg_catalog.gen_random_uuid(),
  submission_id uuid not null references app_private.verification_submissions(submission_id) on delete restrict,
  endorser_id uuid not null references auth.users(id) on delete restrict,
  statement text not null check (char_length(btrim(statement)) between 20 and 500),
  created_at timestamptz not null default pg_catalog.now(),
  unique(submission_id,endorser_id)
);
create table app_private.verification_review_assignments (
  assignment_id uuid primary key default pg_catalog.gen_random_uuid(),
  submission_id uuid not null references app_private.verification_submissions(submission_id) on delete restrict,
  reviewer_id uuid not null references auth.users(id) on delete restrict,
  assigned_by uuid not null references auth.users(id) on delete restrict,
  reason text not null check(char_length(btrim(reason)) between 20 and 500),
  assigned_at timestamptz not null default pg_catalog.now(),
  ended_at timestamptz,
  ended_by uuid references auth.users(id) on delete restrict,
  check ((ended_at is null)=(ended_by is null))
);
create unique index verification_one_active_assignment
  on app_private.verification_review_assignments(submission_id) where ended_at is null;
create table app_private.verification_decision_requests (
  reviewer_id uuid not null references auth.users(id) on delete restrict,
  idempotency_key uuid not null,
  request_sha256 bytea not null check(octet_length(request_sha256)=32),
  result jsonb not null,
  created_at timestamptz not null default pg_catalog.now(),
  primary key(reviewer_id,idempotency_key)
);
revoke all on all tables in schema app_private from public, anon, authenticated, service_role;

create function app_private.submit_verification_for_actor(
  p_actor uuid,p_idempotency_key uuid,p_legal_name text,p_narrative text,p_connection_type text
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_account app_private.identity_accounts%rowtype;
  v_track text;
  v_hash bytea;
  v_previous app_private.verification_submission_requests%rowtype;
  v_version integer;
  v_submission uuid;
  v_event uuid;
begin
  if p_actor is null or p_idempotency_key is null then raise exception using errcode='22023',message='invalid_request'; end if;
  select * into v_account from app_private.identity_accounts where user_id=p_actor for update;
  if not found or v_account.account_status <> 'active' then raise exception using errcode='22023',message='account_not_eligible'; end if;
  if v_account.account_type='student' then
    if exists(select 1 from app_private.institutional_email_ownerships o join app_private.institutional_email_domains d on d.domain=pg_catalog.split_part(o.normalized_email,'@',2) and d.enabled where o.user_id=p_actor and o.revoked_at is null) then
      raise exception using errcode='22023',message='manual_review_not_available';
    end if;
    v_track := 'track_a_manual';
    if p_legal_name is not null or p_connection_type is not null or p_narrative is null or char_length(p_narrative) not between 20 and 1000 then raise exception using errcode='22023',message='invalid_submission'; end if;
  else
    v_track := 'track_b_partner';
    if p_legal_name is null or char_length(btrim(p_legal_name)) not between 2 and 120 or p_connection_type not in ('shop_photo','staff_id','student_endorsement') or p_narrative is null or char_length(p_narrative) not between 20 and 1000 then raise exception using errcode='22023',message='invalid_submission'; end if;
  end if;
  v_hash := extensions.digest(pg_catalog.convert_to(pg_catalog.jsonb_build_array(v_track,p_legal_name,p_narrative,p_connection_type)::text,'UTF8'),'sha256');
  select * into v_previous from app_private.verification_submission_requests where user_id=p_actor and idempotency_key=p_idempotency_key;
  if found then
    if v_previous.request_sha256<>v_hash then raise exception using errcode='23505',message='idempotency_conflict'; end if;
    return pg_catalog.jsonb_build_object('submission_id',v_previous.submission_id,'idempotent',true);
  end if;
  if exists(select 1 from app_private.verification_submissions where user_id=p_actor and track=v_track and status in ('pending','approved')) then raise exception using errcode='23505',message='submission_already_open'; end if;
  select coalesce(max(submission_version),0)+1 into v_version from app_private.verification_submissions where user_id=p_actor and track=v_track;
  insert into app_private.verification_submissions(user_id,submission_version,track,status,legal_name,narrative,campus_connection_type)
    values(p_actor,v_version,v_track,'pending',p_legal_name,p_narrative,p_connection_type) returning submission_id into v_submission;
  update app_private.identity_accounts set verification_track=v_track,verification_status='pending',updated_at=pg_catalog.now() where user_id=p_actor;
  insert into app_private.verification_submission_requests(user_id,idempotency_key,request_sha256,submission_id) values(p_actor,p_idempotency_key,v_hash,v_submission);
  insert into app_private.identity_audit_events(actor_id,subject_id,event_type,event_data) values(p_actor,p_actor,'verification_submitted',pg_catalog.jsonb_build_object('submission_id',v_submission,'version',v_version,'track',v_track)) returning event_id into v_event;
  insert into app_private.identity_outbox(event_id,subject_id,event_type,payload) values(v_event,p_actor,'verification_result',pg_catalog.jsonb_build_object('submission_id',v_submission,'status','pending'));
  return pg_catalog.jsonb_build_object('submission_id',v_submission,'version',v_version,'status','pending','idempotent',false);
end;$function$;

create function public.submit_my_verification(p_idempotency_key uuid,p_legal_name text,p_narrative text,p_connection_type text)
returns jsonb language plpgsql security definer set search_path = '' as $function$
begin if auth.uid() is null then raise exception using errcode='28000',message='authentication required'; end if; return app_private.submit_verification_for_actor(auth.uid(),p_idempotency_key,p_legal_name,p_narrative,p_connection_type); end;$function$;

create function public.get_my_verification_history() returns jsonb
language sql stable security definer set search_path = '' as $function$
  select coalesce(jsonb_agg(jsonb_build_object('submission_id',s.submission_id,'version',s.submission_version,'track',s.track,'status',s.status,'submitted_at',s.submitted_at,'legal_name',s.legal_name,'narrative',s.narrative,'reviews',coalesce((select jsonb_agg(jsonb_build_object('decision',r.decision,'reason',r.reason,'version',r.decision_version,'created_at',r.created_at) order by r.decision_version) from app_private.verification_reviews r where r.submission_id=s.submission_id),'[]'::jsonb)) order by s.submission_version),'[]'::jsonb)
  from app_private.verification_submissions s where s.user_id=auth.uid()
$function$;

create function public.endorse_partner_verification(p_submission_id uuid,p_statement text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare v_actor uuid:=auth.uid(); v_event uuid;
begin
  if v_actor is null then raise exception using errcode='28000',message='authentication required'; end if;
  if p_statement is null or char_length(btrim(p_statement)) not between 20 and 500 then raise exception using errcode='22023',message='invalid_request'; end if;
  if not exists(select 1 from app_private.identity_accounts a join auth.users u on u.id=a.user_id where a.user_id=v_actor and a.account_type='student' and a.account_status='active' and a.verification_status='approved' and a.verification_track in ('track_a_school_email','track_a_manual') and a.age_confirmed_at is not null and u.email_confirmed_at is not null and u.phone_confirmed_at is not null and exists(select 1 from app_private.identity_capabilities c where c.user_id=v_actor and c.capability='can_work' and c.revoked_at is null)) then raise exception using errcode='42501',message='endorser_not_eligible'; end if;
  if not exists(select 1 from app_private.verification_submissions s where s.submission_id=p_submission_id and s.track='track_b_partner' and s.status='pending' and s.user_id<>v_actor) then raise exception using errcode='22023',message='invalid_submission'; end if;
  insert into app_private.verification_endorsements(submission_id,endorser_id,statement) values(p_submission_id,v_actor,p_statement);
  insert into app_private.identity_audit_events(actor_id,subject_id,event_type,event_data) select v_actor,s.user_id,'partner_endorsement_submitted',jsonb_build_object('submission_id',p_submission_id) from app_private.verification_submissions s where s.submission_id=p_submission_id returning event_id into v_event;
  return jsonb_build_object('recorded',true);
end;$function$;

create function app_private.reviewer_is_current(p_actor uuid,p_aal text) returns boolean
language sql stable security definer set search_path = '' as $function$
 select p_aal='aal2' and exists(select 1 from app_private.identity_accounts a join app_private.staff_grants g on g.user_id=a.user_id where a.user_id=p_actor and a.account_status='active' and g.capability='verification_review' and g.revoked_at is null)
$function$;
create function app_private.list_verification_candidates(p_actor uuid,p_aal text) returns jsonb
language sql stable security definer set search_path = '' as $function$
 select case when app_private.reviewer_is_current(p_actor,p_aal) then coalesce(jsonb_agg(jsonb_build_object('submission_id',s.submission_id,'track',s.track,'submitted_at',s.submitted_at,'status',s.status)),'[]'::jsonb) else '[]'::jsonb end from app_private.verification_submissions s where s.status='pending' and not exists(select 1 from app_private.verification_review_assignments x where x.submission_id=s.submission_id and x.ended_at is null)
$function$;
create function app_private.list_verification_queue(p_actor uuid,p_aal text) returns jsonb
language sql stable security definer set search_path = '' as $function$
 select case when app_private.reviewer_is_current(p_actor,p_aal) then coalesce(jsonb_agg(jsonb_build_object('submission_id',s.submission_id,'user_id',s.user_id,'version',s.submission_version,'track',s.track,'legal_name',s.legal_name,'narrative',s.narrative,'submitted_at',s.submitted_at,'evidence',coalesce((select jsonb_agg(jsonb_build_object('evidence_id',e.evidence_id,'kind',e.evidence_kind,'content_type',e.content_type,'size_bytes',e.size_bytes,'safety_state',e.safety_state)) from app_private.verification_evidence e where e.submission_id=s.submission_id),'[]'::jsonb))) ,'[]'::jsonb) else '[]'::jsonb end from app_private.verification_submissions s join app_private.verification_review_assignments a on a.submission_id=s.submission_id and a.reviewer_id=p_actor and a.ended_at is null where s.status='pending'
$function$;
create function app_private.assign_verification(p_actor uuid,p_target uuid,p_submission uuid,p_expected uuid,p_reason text,p_aal text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare v_current uuid; v_id uuid;
begin
 if not app_private.reviewer_is_current(p_actor,p_aal) or p_reason is null or char_length(btrim(p_reason)) not between 20 and 500 then raise exception using errcode='42501',message='reviewer_not_authorized'; end if;
 if not exists(select 1 from app_private.identity_accounts a join app_private.staff_grants g on g.user_id=a.user_id where a.user_id=p_target and a.account_status='active' and g.capability='verification_review' and g.revoked_at is null) then raise exception using errcode='42501',message='reviewer_not_authorized'; end if;
 perform 1 from app_private.verification_submissions where submission_id=p_submission and status='pending' for update;
 if not found then return jsonb_build_object('error','stale_state'); end if;
 select assignment_id into v_current from app_private.verification_review_assignments where submission_id=p_submission and ended_at is null for update;
 if v_current is distinct from p_expected then return jsonb_build_object('error','stale_state'); end if;
 if v_current is not null then update app_private.verification_review_assignments set ended_at=now(),ended_by=p_actor where assignment_id=v_current; end if;
 insert into app_private.verification_review_assignments(submission_id,reviewer_id,assigned_by,reason) values(p_submission,p_target,p_actor,p_reason) returning assignment_id into v_id;
 insert into app_private.identity_audit_events(actor_id,subject_id,event_type,event_data) select p_actor,s.user_id,'verification_assigned',jsonb_build_object('submission_id',p_submission,'reviewer_id',p_target,'assignment_id',v_id) from app_private.verification_submissions s where s.submission_id=p_submission;
 return jsonb_build_object('assignment_id',v_id,'assigned',true);
end;$function$;
create function app_private.review_verification(p_actor uuid,p_submission uuid,p_expected_version integer,p_expected_status text,p_expected_decision integer,p_decision text,p_reason text,p_key uuid,p_aal text) returns jsonb
language plpgsql security definer set search_path = '' as $function$
declare v_s app_private.verification_submissions%rowtype; v_hash bytea; v_old app_private.verification_decision_requests%rowtype; v_event uuid; v_result jsonb; v_dv integer;
begin
 if p_actor is null or p_submission is null or p_key is null or not app_private.reviewer_is_current(p_actor,p_aal) or p_reason is null or char_length(btrim(p_reason)) not between 20 and 500 or p_decision not in ('needs_information','rejected','approved','revoked') then raise exception using errcode='42501',message='reviewer_not_authorized'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('verification-decision:'||p_actor::text||':'||p_key::text, 702071));
 v_hash:=extensions.digest(convert_to(jsonb_build_array(p_submission,p_expected_version,p_expected_status,p_expected_decision,p_decision,p_reason)::text,'UTF8'),'sha256');
 select * into v_old from app_private.verification_decision_requests where reviewer_id=p_actor and idempotency_key=p_key;
 if found then if v_old.request_sha256<>v_hash then raise exception using errcode='23505',message='idempotency_conflict'; end if; return v_old.result; end if;
 select * into v_s from app_private.verification_submissions where submission_id=p_submission for update;
 if not found or v_s.submission_version<>p_expected_version or v_s.status<>p_expected_status or v_s.status not in ('pending','approved') or not exists(select 1 from app_private.verification_review_assignments a where a.submission_id=p_submission and a.reviewer_id=p_actor and a.ended_at is null) then return jsonb_build_object('error','stale_state'); end if;
 select coalesce(max(decision_version),0) into v_dv from app_private.verification_reviews where submission_id=p_submission;
 if v_dv<>p_expected_decision then return jsonb_build_object('error','stale_state'); end if;
 if p_decision='revoked' and v_s.status<>'approved' then return jsonb_build_object('error','stale_state'); end if;
 if p_decision<>'revoked' and v_s.status<>'pending' then return jsonb_build_object('error','stale_state'); end if;
 if p_decision='approved' and not app_private.verification_submission_evidence_complete(p_submission) then raise exception using errcode='22023',message='evidence_not_ready'; end if;
 insert into app_private.verification_reviews(submission_id,reviewer_id,decision,reason,decision_version) values(p_submission,p_actor,p_decision,p_reason,v_dv+1);
 if p_decision='revoked' then update app_private.verification_submissions set status='revoked' where submission_id=p_submission; else update app_private.verification_submissions set status=p_decision where submission_id=p_submission; end if;
 update app_private.identity_accounts set verification_status=case when p_decision='revoked' then 'rejected' else p_decision end,updated_at=now() where user_id=v_s.user_id;
 if p_decision in ('approved','revoked') then
   if p_decision='revoked' then update app_private.identity_capabilities set revoked_at=now() where user_id=v_s.user_id and source in ('track_a_manual','track_b_partner') and revoked_at is null;
   else perform app_private.reconcile_manual_partner_capabilities(v_s.user_id); end if;
 end if;
 insert into app_private.identity_audit_events(actor_id,subject_id,event_type,event_data) values(p_actor,v_s.user_id,'verification_reviewed',jsonb_build_object('submission_id',p_submission,'decision',p_decision,'version',v_s.submission_version,'decision_version',v_dv+1)) returning event_id into v_event;
 insert into app_private.identity_outbox(event_id,subject_id,event_type,payload) values(v_event,v_s.user_id,'verification_result',jsonb_build_object('submission_id',p_submission,'status',p_decision,'reason',p_reason));
 v_result:=jsonb_build_object('submission_id',p_submission,'status',p_decision,'decision_version',v_dv+1);
 insert into app_private.verification_decision_requests(reviewer_id,idempotency_key,request_sha256,result) values(p_actor,p_key,v_hash,v_result);
 return v_result;
end;$function$;

create function app_private.verification_submission_evidence_complete(p_submission uuid) returns boolean
language sql stable security definer set search_path = '' as $function$
 select case when s.track='track_a_manual' then exists(select 1 from app_private.verification_evidence e where e.submission_id=s.submission_id and e.evidence_kind='student_id' and e.safety_state='ready' and e.storage_bucket='verification-private')
 when s.track='track_b_partner' then exists(select 1 from app_private.verification_evidence e where e.submission_id=s.submission_id and e.evidence_kind='government_id' and e.safety_state='ready' and e.storage_bucket='verification-private') and (case s.campus_connection_type when 'shop_photo' then exists(select 1 from app_private.verification_evidence e where e.submission_id=s.submission_id and e.evidence_kind='campus_shop_location' and e.safety_state='ready' and e.storage_bucket='verification-private') when 'staff_id' then exists(select 1 from app_private.verification_evidence e where e.submission_id=s.submission_id and e.evidence_kind='campus_staff_id' and e.safety_state='ready' and e.storage_bucket='verification-private') when 'student_endorsement' then exists(select 1 from app_private.verification_endorsements e join app_private.identity_accounts a on a.user_id=e.endorser_id and a.account_status='active' and a.account_type='student' and a.verification_status='approved' join app_private.identity_capabilities c on c.user_id=e.endorser_id and c.capability='can_work' and c.revoked_at is null where e.submission_id=s.submission_id) else false end) else false end
 from app_private.verification_submissions s where s.submission_id=p_submission
$function$;
create function app_private.reconcile_manual_partner_capabilities(p_actor uuid) returns void
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

create function public.server_list_verification_assignment_candidates_for_actor(p_actor uuid,p_auth_aal text) returns jsonb language sql security definer set search_path = '' as $function$ select app_private.list_verification_candidates($1,$2) $function$;
create function public.server_list_verification_queue_for_actor(p_actor uuid,p_auth_aal text) returns jsonb language sql security definer set search_path = '' as $function$ select app_private.list_verification_queue($1,$2) $function$;
create function public.server_assign_verification_for_actor(p_actor uuid,p_target_reviewer uuid,p_submission_id uuid,p_expected_assignment_id uuid,p_reason text,p_auth_aal text) returns jsonb language sql security definer set search_path = '' as $function$ select app_private.assign_verification($1,$2,$3,$4,$5,$6) $function$;
create function public.server_review_verification_for_actor(p_actor uuid,p_submission_id uuid,p_expected_version integer,p_expected_status text,p_expected_decision_version integer,p_decision text,p_reason text,p_idempotency_key uuid,p_auth_aal text) returns jsonb language sql security definer set search_path = '' as $function$ select app_private.review_verification($1,$2,$3,$4,$5,$6,$7,$8,$9) $function$;

revoke all on function app_private.submit_verification_for_actor(uuid,uuid,text,text,text),app_private.reviewer_is_current(uuid,text),app_private.list_verification_candidates(uuid,text),app_private.list_verification_queue(uuid,text),app_private.assign_verification(uuid,uuid,uuid,uuid,text,text),app_private.review_verification(uuid,uuid,integer,text,integer,text,text,uuid,text),app_private.verification_submission_evidence_complete(uuid),app_private.reconcile_manual_partner_capabilities(uuid) from public,anon,authenticated,service_role;
revoke all on function public.submit_my_verification(uuid,text,text,text),public.get_my_verification_history(),public.endorse_partner_verification(uuid,text) from public,anon,authenticated,service_role;
grant execute on function public.submit_my_verification(uuid,text,text,text),public.get_my_verification_history(),public.endorse_partner_verification(uuid,text) to authenticated;
revoke all on function public.server_list_verification_assignment_candidates_for_actor(uuid,text),public.server_list_verification_queue_for_actor(uuid,text),public.server_assign_verification_for_actor(uuid,uuid,uuid,uuid,text,text),public.server_review_verification_for_actor(uuid,uuid,integer,text,integer,text,text,uuid,text) from public,anon,authenticated,service_role;
grant execute on function public.server_list_verification_assignment_candidates_for_actor(uuid,text),public.server_list_verification_queue_for_actor(uuid,text),public.server_assign_verification_for_actor(uuid,uuid,uuid,uuid,text,text),public.server_review_verification_for_actor(uuid,uuid,integer,text,integer,text,text,uuid,text) to service_role;
grant execute on function app_private.submit_verification_for_actor(uuid,uuid,text,text,text),app_private.reviewer_is_current(uuid,text),app_private.list_verification_candidates(uuid,text),app_private.list_verification_queue(uuid,text),app_private.assign_verification(uuid,uuid,uuid,uuid,text,text),app_private.review_verification(uuid,uuid,integer,text,integer,text,text,uuid,text),app_private.verification_submission_evidence_complete(uuid),app_private.reconcile_manual_partner_capabilities(uuid) to postgres;

-- The server upload intent must bind the purpose before bytes are accepted.
drop function public.server_begin_verification_upload_for_actor(uuid,uuid,smallint,text,integer,text);
drop function app_private.begin_verification_upload_for_actor(uuid,uuid,smallint,text,integer,text);
create function app_private.begin_verification_upload_for_actor(p_actor uuid,p_submission_id uuid,p_evidence_position smallint,p_content_type text,p_size_bytes integer,p_token_hash_hex text,p_evidence_kind text)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare v_submission app_private.verification_submissions%rowtype; v_intent uuid:=gen_random_uuid(); v_evidence uuid:=gen_random_uuid(); v_key text; v_expires timestamptz:=now()+interval '5 minutes';
begin
 if p_actor is null or p_evidence_position not between 1 and 3 or p_size_bytes not between 1 and 5000000 or p_content_type not in ('image/jpeg','image/png','application/pdf') or p_evidence_kind not in ('student_id','government_id','campus_shop_location','campus_staff_id') or p_token_hash_hex !~ '^[0-9a-f]{64}$' then raise exception using errcode='22023',message='invalid_request'; end if;
 select * into v_submission from app_private.verification_submissions where submission_id=p_submission_id and user_id=p_actor and status='pending' for update;
 if not found then raise exception using errcode='22023',message='invalid_submission'; end if;
 if (v_submission.track='track_a_manual' and p_evidence_kind<>'student_id') or (v_submission.track='track_b_partner' and p_evidence_kind='student_id') then raise exception using errcode='22023',message='invalid_evidence_kind'; end if;
 if exists(select 1 from app_private.verification_evidence where submission_id=p_submission_id and evidence_kind=p_evidence_kind) or exists(select 1 from app_private.verification_upload_intents where submission_id=p_submission_id and evidence_kind=p_evidence_kind and state in ('issued','uploading','finalized')) then raise exception using errcode='23505',message='evidence_kind_already_used'; end if;
 v_key:=p_actor::text||'/'||p_submission_id::text||'/'||v_evidence::text||'/source';
 insert into app_private.verification_upload_intents(intent_id,evidence_id,user_id,submission_id,evidence_position,evidence_kind,expected_content_type,expected_size_bytes,token_hash,object_key,expires_at) values(v_intent,v_evidence,p_actor,p_submission_id,p_evidence_position,p_evidence_kind,p_content_type,p_size_bytes,decode(p_token_hash_hex,'hex'),v_key,v_expires);
 insert into app_private.verification_file_access_events(actor_id,submission_id,evidence_id,intent_id,event_type) values(p_actor,p_submission_id,v_evidence,v_intent,'upload_intent_issued');
 return jsonb_build_object('intent_id',v_intent,'evidence_id',v_evidence,'expires_at',v_expires);
end;$function$;
create function public.server_begin_verification_upload_for_actor(p_actor uuid,p_submission_id uuid,p_evidence_position smallint,p_content_type text,p_size_bytes integer,p_token_hash_hex text,p_evidence_kind text) returns jsonb language sql security definer set search_path = '' as $function$ select app_private.begin_verification_upload_for_actor($1,$2,$3,$4,$5,$6,$7) $function$;
revoke all on function app_private.begin_verification_upload_for_actor(uuid,uuid,smallint,text,integer,text,text),public.server_begin_verification_upload_for_actor(uuid,uuid,smallint,text,integer,text,text) from public,anon,authenticated,service_role;
grant execute on function app_private.begin_verification_upload_for_actor(uuid,uuid,smallint,text,integer,text,text) to postgres;
grant execute on function public.server_begin_verification_upload_for_actor(uuid,uuid,smallint,text,integer,text,text) to service_role;

create or replace function app_private.finalize_verification_upload_for_actor(p_actor uuid,p_intent_id uuid,p_size_bytes integer,p_content_type text,p_sha256_hex text)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare v_intent app_private.verification_upload_intents%rowtype;
begin
 select * into v_intent from app_private.verification_upload_intents where intent_id=p_intent_id and user_id=p_actor for update;
 if not found or v_intent.state<>'uploading' or v_intent.expires_at<=now() or v_intent.expected_size_bytes<>p_size_bytes or v_intent.expected_content_type<>p_content_type or p_sha256_hex !~ '^[0-9a-f]{64}$' then raise exception using errcode='22023',message='invalid_upload_intent'; end if;
 insert into app_private.verification_evidence(evidence_id,submission_id,user_id,evidence_position,evidence_kind,object_key,storage_bucket,content_type,size_bytes,content_sha256,safety_state,finalized_at)
 values(v_intent.evidence_id,v_intent.submission_id,v_intent.user_id,v_intent.evidence_position,v_intent.evidence_kind,v_intent.object_key,'verification-quarantine',v_intent.expected_content_type,v_intent.expected_size_bytes,decode(p_sha256_hex,'hex'),'quarantined',now());
 update app_private.verification_upload_intents set state='finalized',finalized_at=now(),token_hash=decode(repeat('00',32),'hex') where intent_id=v_intent.intent_id;
 insert into app_private.verification_file_access_events(actor_id,submission_id,evidence_id,intent_id,event_type) values(p_actor,v_intent.submission_id,v_intent.evidence_id,v_intent.intent_id,'upload_quarantined');
 return jsonb_build_object('finalized',true,'evidence_id',v_intent.evidence_id,'safety_state','quarantined','reviewable',false);
end;$function$;
revoke all on function app_private.finalize_verification_upload_for_actor(uuid,uuid,integer,text,text) from public,anon,authenticated,service_role;
grant execute on function app_private.finalize_verification_upload_for_actor(uuid,uuid,integer,text,text) to postgres;

-- Assignment is part of every subsequent queue and evidence authorization check.
create or replace function app_private.verification_download_target_for_reviewer(p_actor uuid,p_evidence_id uuid,p_auth_aal text)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare v_e app_private.verification_evidence%rowtype;
begin
 if p_auth_aal is distinct from 'aal2' or not app_private.reviewer_is_current(p_actor,p_auth_aal) then
   insert into app_private.verification_file_access_events(actor_id,evidence_id,event_type,reason_code) values(p_actor,p_evidence_id,'review_download_denied','no_current_grant'); return jsonb_build_object('authorized',false);
 end if;
 select e.* into v_e from app_private.verification_evidence e join app_private.verification_review_assignments a on a.submission_id=e.submission_id and a.reviewer_id=p_actor and a.ended_at is null where e.evidence_id=p_evidence_id and e.safety_state='ready' and e.storage_bucket='verification-private';
 if not found then insert into app_private.verification_file_access_events(actor_id,evidence_id,event_type,reason_code) values(p_actor,p_evidence_id,'review_download_denied','evidence_not_ready'); return jsonb_build_object('authorized',false); end if;
 insert into app_private.verification_file_access_events(actor_id,submission_id,evidence_id,event_type) values(p_actor,v_e.submission_id,v_e.evidence_id,'review_download_issued');
 return jsonb_build_object('authorized',true,'object_key',v_e.object_key,'storage_bucket',v_e.storage_bucket,'content_type',v_e.content_type,'evidence_id',v_e.evidence_id);
end;$function$;
revoke all on function app_private.verification_download_target_for_reviewer(uuid,uuid,text) from public,anon,authenticated,service_role;
grant execute on function app_private.verification_download_target_for_reviewer(uuid,uuid,text) to postgres;

create function app_private.reconcile_reviewed_identity_after_auth_change() returns trigger
language plpgsql security definer set search_path = '' as $function$
begin
  if old.email_confirmed_at is distinct from new.email_confirmed_at or old.phone is distinct from new.phone or old.phone_change is distinct from new.phone_change or old.phone_confirmed_at is distinct from new.phone_confirmed_at then
    perform app_private.reconcile_manual_partner_capabilities(new.id);
  end if;
  return new;
end;$function$;
revoke all on function app_private.reconcile_reviewed_identity_after_auth_change() from public,anon,authenticated,service_role;
create trigger auth_users_reconcile_reviewed_identity
after update of email_confirmed_at,phone,phone_change,phone_confirmed_at on auth.users
for each row execute function app_private.reconcile_reviewed_identity_after_auth_change();

commit;
