begin;

-- Reserve separate capability names for future case and money workflows. No
-- command in this migration implements those workflows or moves money.
alter table app_private.staff_grants drop constraint staff_grants_capability_check;
alter table app_private.staff_grants add constraint staff_grants_capability_check
  check (capability in (
    'verification_review', 'identity_suspend', 'identity_unsuspend',
    'identity_correct_user_type', 'identity_staff_admin', 'dispute_review',
    'financial_initiate', 'financial_approve'
  ));

create function app_private.guard_staff_grant_change()
returns trigger language plpgsql set search_path = '' as $function$
begin
  if tg_op = 'DELETE' then
    raise exception using errcode='55000',message='staff grant history cannot be deleted';
  end if;
  if new.grant_id is distinct from old.grant_id
     or new.user_id is distinct from old.user_id
     or new.capability is distinct from old.capability
     or new.granted_by is distinct from old.granted_by
     or new.reason is distinct from old.reason
     or new.granted_at is distinct from old.granted_at
     or old.revoked_at is not null
     or new.revoked_at is null
     or new.revoked_by is null then
    raise exception using errcode='55000',message='staff grant can only be revoked once';
  end if;
  return new;
end;$function$;
revoke all on function app_private.guard_staff_grant_change() from public,anon,authenticated,service_role;
create trigger staff_grants_guard_change
before update or delete on app_private.staff_grants
for each row execute function app_private.guard_staff_grant_change();

create function app_private.audit_staff_grant_change()
returns trigger language plpgsql security definer set search_path = '' as $function$
begin
  if tg_op='INSERT' then
    insert into app_private.identity_audit_events(actor_id,subject_id,event_type,event_data)
    values(new.granted_by,new.user_id,'staff_grant_created',pg_catalog.jsonb_build_object('grant_id',new.grant_id,'capability',new.capability,'reason',new.reason));
  else
    insert into app_private.identity_audit_events(actor_id,subject_id,event_type,event_data)
    values(new.revoked_by,new.user_id,'staff_grant_revoked',pg_catalog.jsonb_build_object('grant_id',new.grant_id,'capability',new.capability,'reason',new.reason));
  end if;
  return new;
end;$function$;
revoke all on function app_private.audit_staff_grant_change() from public,anon,authenticated,service_role;
create trigger staff_grants_audit_insert after insert on app_private.staff_grants
for each row execute function app_private.audit_staff_grant_change();
create trigger staff_grants_audit_revoke after update of revoked_at on app_private.staff_grants
for each row when (old.revoked_at is null and new.revoked_at is not null)
execute function app_private.audit_staff_grant_change();

create table app_private.identity_suspension_events (
  event_id uuid primary key default pg_catalog.gen_random_uuid(),
  subject_id uuid not null references app_private.identity_accounts(user_id) on delete restrict,
  actor_id uuid not null references auth.users(id) on delete restrict,
  action text not null check(action in ('suspended','unsuspended')),
  reason text not null check(char_length(btrim(reason)) between 20 and 500),
  idempotency_key uuid not null,
  created_at timestamptz not null default pg_catalog.now(),
  unique(actor_id,idempotency_key)
);
create trigger identity_suspension_events_append_only
before update or delete on app_private.identity_suspension_events
for each row execute function app_private.reject_identity_history_mutation();

create table app_private.staff_action_requests (
  actor_id uuid not null references auth.users(id) on delete restrict,
  idempotency_key uuid not null,
  request_sha256 bytea not null check(octet_length(request_sha256)=32),
  result jsonb not null check(pg_catalog.jsonb_typeof(result)='object'),
  created_at timestamptz not null default pg_catalog.now(),
  primary key(actor_id,idempotency_key)
);
revoke all on table app_private.identity_suspension_events,app_private.staff_action_requests from public,anon,authenticated,service_role;

create function public.current_user_account_active()
returns boolean language sql stable security definer set search_path = '' as $function$
  select exists(select 1 from app_private.identity_accounts a where a.user_id=auth.uid() and a.account_status='active')
$function$;
revoke all on function public.current_user_account_active() from public,anon,authenticated,service_role;
grant execute on function public.current_user_account_active() to authenticated;

drop policy profiles_select_own on public.profiles;
create policy profiles_select_own on public.profiles for select to authenticated
using(user_id=(select auth.uid()) and (select public.current_user_account_active()));
drop policy profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles for update to authenticated
using(user_id=(select auth.uid()) and (select public.current_user_account_active()))
with check(user_id=(select auth.uid()) and (select public.current_user_account_active()));

create function public.get_my_identity_help_context()
returns jsonb language plpgsql stable security definer set search_path = '' as $function$
declare v_actor uuid:=auth.uid(); v_status text; v_event app_private.identity_suspension_events%rowtype;
begin
  if v_actor is null then raise exception using errcode='28000',message='authentication required'; end if;
  select account_status into v_status from app_private.identity_accounts where user_id=v_actor;
  if not found then return pg_catalog.jsonb_build_object('registered',false,'support_route_available',true); end if;
  select * into v_event from app_private.identity_suspension_events where subject_id=v_actor order by created_at desc,event_id desc limit 1;
  return pg_catalog.jsonb_build_object(
    'registered',true,'account_status',v_status,
    'suspended',v_status='suspended',
    'reason',case when v_status='suspended' and v_event.action='suspended' then v_event.reason else null end,
    'support_route_available',true
  );
end;$function$;
revoke all on function public.get_my_identity_help_context() from public,anon,authenticated,service_role;
grant execute on function public.get_my_identity_help_context() to authenticated;

create function app_private.staff_actor_has_current_capability(p_actor uuid,p_capability text,p_aal text)
returns boolean language sql stable security definer set search_path = '' as $function$
 select p_aal='aal2' and exists(
   select 1 from app_private.identity_accounts a
   join app_private.staff_grants g on g.user_id=a.user_id
   where a.user_id=p_actor and a.account_status='active'
     and g.capability=p_capability and g.revoked_at is null
 )
$function$;
revoke all on function app_private.staff_actor_has_current_capability(uuid,text,text) from public,anon,authenticated,service_role;

create function app_private.set_identity_suspension_for_actor(
  p_actor uuid,p_subject uuid,p_suspended boolean,p_reason text,p_idempotency_key uuid,p_auth_aal text
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_capability text;
  v_account app_private.identity_accounts%rowtype;
  v_request app_private.staff_action_requests%rowtype;
  v_hash bytea;
  v_result jsonb;
  v_action text;
  v_event uuid;
begin
  if p_actor is null or p_subject is null or p_actor=p_subject or p_idempotency_key is null
     or p_reason is null or char_length(btrim(p_reason)) not between 20 and 500 then
    raise exception using errcode='22023',message='invalid_request';
  end if;
  v_capability:=case when p_suspended then 'identity_suspend' else 'identity_unsuspend' end;
  if not app_private.staff_actor_has_current_capability(p_actor,v_capability,p_auth_aal) then
    raise exception using errcode='42501',message='staff_access_denied';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('staff-action:'||p_actor::text||':'||p_idempotency_key::text,808021));
  v_hash:=extensions.digest(pg_catalog.convert_to(pg_catalog.jsonb_build_array(p_subject,p_suspended,p_reason)::text,'UTF8'),'sha256');
  select * into v_request from app_private.staff_action_requests where actor_id=p_actor and idempotency_key=p_idempotency_key;
  if found then
    if v_request.request_sha256<>v_hash then raise exception using errcode='23505',message='idempotency_conflict'; end if;
    return v_request.result;
  end if;
  select * into v_account from app_private.identity_accounts where user_id=p_subject for update;
  if not found then raise exception using errcode='22023',message='identity_unavailable'; end if;
  if (v_account.account_status='suspended')=p_suspended then
    v_result:=pg_catalog.jsonb_build_object('changed',false,'account_status',v_account.account_status);
  else
    v_action:=case when p_suspended then 'suspended' else 'unsuspended' end;
    update app_private.identity_accounts set account_status=case when p_suspended then 'suspended' else 'active' end,updated_at=pg_catalog.now() where user_id=p_subject;
    insert into app_private.identity_suspension_events(subject_id,actor_id,action,reason,idempotency_key)
    values(p_subject,p_actor,v_action,p_reason,p_idempotency_key);
    if p_suspended then
      update app_private.identity_capabilities set revoked_at=pg_catalog.now() where user_id=p_subject and revoked_at is null;
    else
      if v_account.account_type='student' and v_account.verification_track='track_a_school_email' then perform app_private.maybe_qualify_track_a(p_subject); end if;
      perform app_private.reconcile_manual_partner_capabilities(p_subject);
    end if;
    insert into app_private.identity_audit_events(actor_id,subject_id,event_type,event_data)
    values(p_actor,p_subject,'identity_'||v_action,pg_catalog.jsonb_build_object('reason',p_reason,'idempotency_key',p_idempotency_key)) returning event_id into v_event;
    v_result:=pg_catalog.jsonb_build_object('changed',true,'account_status',case when p_suspended then 'suspended' else 'active' end,'event_id',v_event);
  end if;
  insert into app_private.staff_action_requests(actor_id,idempotency_key,request_sha256,result) values(p_actor,p_idempotency_key,v_hash,v_result);
  return v_result;
end;$function$;
revoke all on function app_private.set_identity_suspension_for_actor(uuid,uuid,boolean,text,uuid,text) from public,anon,authenticated,service_role;

create function public.server_set_identity_suspension_for_actor(
 p_actor uuid,p_subject uuid,p_suspended boolean,p_reason text,p_idempotency_key uuid,p_auth_aal text
) returns jsonb language sql security definer set search_path = '' as $function$
 select app_private.set_identity_suspension_for_actor($1,$2,$3,$4,$5,$6)
$function$;
revoke all on function public.server_set_identity_suspension_for_actor(uuid,uuid,boolean,text,uuid,text) from public,anon,authenticated,service_role;
grant execute on function public.server_set_identity_suspension_for_actor(uuid,uuid,boolean,text,uuid,text) to service_role;

create or replace function app_private.list_verification_candidates(p_actor uuid,p_aal text)
returns jsonb language plpgsql stable security definer set search_path = '' as $function$
declare v_result jsonb;
begin
 if not app_private.reviewer_is_current(p_actor,p_aal) then raise exception using errcode='42501',message='reviewer_not_authorized'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('submission_id',s.submission_id,'track',s.track,'submitted_at',s.submitted_at,'status',s.status)),'[]'::jsonb) into v_result
 from app_private.verification_submissions s where s.status='pending'
 and not exists(select 1 from app_private.verification_review_assignments x where x.submission_id=s.submission_id and x.ended_at is null);
 return v_result;
end;$function$;
create or replace function app_private.list_verification_queue(p_actor uuid,p_aal text)
returns jsonb language plpgsql stable security definer set search_path = '' as $function$
declare v_result jsonb;
begin
 if not app_private.reviewer_is_current(p_actor,p_aal) then raise exception using errcode='42501',message='reviewer_not_authorized'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('submission_id',s.submission_id,'user_id',s.user_id,'version',s.submission_version,'track',s.track,'legal_name',s.legal_name,'narrative',s.narrative,'submitted_at',s.submitted_at,'evidence',coalesce((select jsonb_agg(jsonb_build_object('evidence_id',e.evidence_id,'kind',e.evidence_kind,'content_type',e.content_type,'size_bytes',e.size_bytes,'safety_state',e.safety_state)) from app_private.verification_evidence e where e.submission_id=s.submission_id),'[]'::jsonb))),'[]'::jsonb) into v_result
 from app_private.verification_submissions s join app_private.verification_review_assignments a on a.submission_id=s.submission_id and a.reviewer_id=p_actor and a.ended_at is null where s.status='pending';
 return v_result;
end;$function$;
revoke all on function app_private.list_verification_candidates(uuid,text),app_private.list_verification_queue(uuid,text) from public,anon,authenticated,service_role;
grant execute on function app_private.staff_actor_has_current_capability(uuid,text,text),app_private.set_identity_suspension_for_actor(uuid,uuid,boolean,text,uuid,text) to postgres;

create function app_private.reconcile_staff_access_after_auth_change()
returns trigger language plpgsql security definer set search_path = '' as $function$
declare v_phone_verified boolean; v_login_confirmed boolean; v_account app_private.identity_accounts%rowtype;
begin
  if old.email is not distinct from new.email and old.email_confirmed_at is not distinct from new.email_confirmed_at
     and old.phone is not distinct from new.phone and old.phone_change is not distinct from new.phone_change
     and old.phone_confirmed_at is not distinct from new.phone_confirmed_at then return new; end if;
  select exists(select 1 from app_private.identity_phone_bindings b where b.user_id=new.id and b.phone_e164='+'||new.phone and b.verified_at=new.phone_confirmed_at and new.phone_confirmed_at is not null and nullif(new.phone_change,'') is null) into v_phone_verified;
  v_login_confirmed:=new.email is not null and new.email_confirmed_at is not null;
  select * into v_account from app_private.identity_accounts where user_id=new.id;
  if not found then return new; end if;
  if not v_phone_verified or not v_login_confirmed or v_account.account_status<>'active' then
    update app_private.identity_capabilities set revoked_at=pg_catalog.now() where user_id=new.id and revoked_at is null;
    return new;
  end if;
  if v_account.account_type='student' and v_account.verification_track='track_a_school_email' then
    perform app_private.maybe_qualify_track_a(new.id);
  else
    perform app_private.reconcile_manual_partner_capabilities(new.id);
  end if;
  return new;
end;$function$;
revoke all on function app_private.reconcile_staff_access_after_auth_change() from public,anon,authenticated,service_role;
create trigger auth_users_z_reconcile_staff_access
after update of email,email_confirmed_at,phone,phone_change,phone_confirmed_at on auth.users
for each row execute function app_private.reconcile_staff_access_after_auth_change();

commit;
