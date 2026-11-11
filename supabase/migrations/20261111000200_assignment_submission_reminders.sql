begin;

alter table app_private.notification_email_deliveries
  drop constraint notification_email_deliveries_safe_error_code_check,
  add constraint notification_email_deliveries_safe_error_code_check check (safe_error_code is null or safe_error_code in (
    'recipient_unavailable','capture_rejected','capture_unavailable','ambiguous_result',
    'lease_expired','max_attempts_exhausted','eligibility_check_unavailable'
  ));

alter table app_private.marketplace_outbox
  drop constraint marketplace_outbox_event_type_check,
  add constraint marketplace_outbox_event_type_check check (event_type in (
    'job.draft_created','job.draft_updated','job.funding_started','job.funded',
    'job.funding_failed','job.funding_exception','job.application_created',
    'job.application_accepted','job.application_rejected','job.application_withdrawn',
    'job.application_closed','job.message_created','job.assignment_started',
    'job.assignment_submitted','job.assignment_completed','job.assignment_hold_opened',
    'job.slot_refund_authorized','job.assignment_cancellation_requested',
    'job.assignment_cancellation_completed','job.assignment_abandoned',
    'job.assignment_case_reviewer_assigned','job.assignment_case_investigation_updated',
    'job.assignment_case_decision_notified','job.assignment_case_updated',
    'job.assignment_case_finalized','job.assignment_reminder_dispatched'
  ));

alter table app_private.in_app_notifications
  drop constraint in_app_notifications_notification_type_check,
  add constraint in_app_notifications_notification_type_check check (notification_type in (
    'application_received','application_accepted','application_rejected',
    'application_withdrawn','application_closed','new_message',
    'assignment_started','assignment_submitted','assignment_completed',
    'assignment_hold_opened','assignment_case_updated','assignment_case_decision',
    'withdrawal_requested','withdrawal_processing','withdrawal_unknown','withdrawal_paid',
    'withdrawal_failed','withdrawal_reversed','withdrawal_exception',
    'slot_refund_authorized','assignment_cancellation_requested',
    'assignment_cancellation_completed','assignment_abandoned',
    'assignment_case_finalized','assignment_reminder_24h','assignment_reminder_48h',
    'assignment_dispute_guidance_72h','refund_processing','refund_unknown',
    'refund_settled','refund_failed','refund_exception','refund_reversal_review',
    'verification_submitted','verification_approved','verification_not_approved',
    'verification_revoked'
  ));

create table app_private.assignment_reminder_due (
  reminder_id uuid primary key default pg_catalog.gen_random_uuid(),
  assignment_id uuid not null references app_private.assignments(assignment_id) on delete restrict,
  terms_version integer not null check (terms_version>0),
  generation_event_id uuid not null references app_private.marketplace_outbox(event_id) on delete restrict,
  stage_hours smallint not null check (stage_hours in (24,48,72)),
  reminder_key text not null unique,
  due_at timestamptz not null,
  recipient_id uuid not null references auth.users(id) on delete restrict,
  notification_type text not null check (notification_type in (
    'assignment_reminder_24h','assignment_reminder_48h','assignment_dispute_guidance_72h'
  )),
  status text not null default 'pending' check (status in (
    'pending','leased','retry_wait','dispatched','suppressed','coalesced','exhausted'
  )),
  attempt_count smallint not null default 0 check (attempt_count between 0 and 5),
  available_at timestamptz not null default pg_catalog.clock_timestamp(),
  lease_token uuid,
  lease_expires_at timestamptz,
  notification_id uuid unique references app_private.in_app_notifications(notification_id) on delete restrict,
  safe_error_code text check (safe_error_code is null or safe_error_code in (
    'lease_expired','runner_failure','max_attempts_exhausted'
  )),
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  unique(assignment_id,terms_version,generation_event_id,stage_hours),
  check (reminder_key=assignment_id::text||':v'||terms_version::text||':'||
    generation_event_id::text||':'||stage_hours::text),
  check ((status='leased' and lease_token is not null and lease_expires_at is not null) or
    (status<>'leased' and lease_token is null and lease_expires_at is null)),
  check ((status='dispatched')=(notification_id is not null))
);
create index assignment_reminder_due_claim_idx
  on app_private.assignment_reminder_due(status,due_at,available_at,assignment_id,generation_event_id,stage_hours)
  where status in ('pending','leased','retry_wait');

create function app_private.assignment_reminder_is_eligible(p_assignment_id uuid)
returns boolean language sql stable security definer set search_path = '' as $function$
  select exists(
    select 1 from app_private.assignments a
    join app_private.principal_allocations p on p.allocation_id=a.allocation_id
      and p.assignment_id=a.assignment_id and p.status='assigned'
    where a.assignment_id=p_assignment_id and a.work_state='submitted'
      and a.submitted_at is not null
      and not exists(select 1 from app_private.assignment_cases c
        where c.assignment_id=a.assignment_id and c.lifecycle_status<>'closed')
  )
$function$;

create function app_private.suppress_assignment_reminders(
  p_assignment_id uuid,p_keep_generation_event_id uuid default null
) returns void language plpgsql security definer set search_path = '' as $function$
begin
  update app_private.assignment_reminder_due r
  set status='suppressed',lease_token=null,lease_expires_at=null,
      safe_error_code=null,updated_at=pg_catalog.clock_timestamp()
  where r.assignment_id=p_assignment_id
    and (p_keep_generation_event_id is null or r.generation_event_id<>p_keep_generation_event_id)
    and r.status in ('pending','retry_wait','leased');

  update app_private.notification_email_deliveries d
  set status='suppressed',lease_token=null,lease_expires_at=null,
      safe_error_code=null,updated_at=pg_catalog.clock_timestamp()
  where d.notification_id in (
    select r.notification_id from app_private.assignment_reminder_due r
    where r.assignment_id=p_assignment_id
      and (p_keep_generation_event_id is null or r.generation_event_id<>p_keep_generation_event_id)
      and r.notification_id is not null
  ) and d.status in ('pending','retry_wait');
end;
$function$;

create function app_private.create_assignment_reminder_generation(
  p_event_id uuid,p_assignment_id uuid,p_anchor_at timestamptz
) returns void language plpgsql security definer set search_path = '' as $function$
declare v_assignment app_private.assignments%rowtype; v_stage smallint; v_type text; v_recipient uuid;
begin
  select * into v_assignment from app_private.assignments where assignment_id=p_assignment_id;
  if not found or p_anchor_at is null or not app_private.assignment_reminder_is_eligible(p_assignment_id) then
    return;
  end if;
  for v_stage in select unnest(array[24,48,72]::smallint[]) loop
    v_type:=case v_stage when 24 then 'assignment_reminder_24h'
      when 48 then 'assignment_reminder_48h' else 'assignment_dispute_guidance_72h' end;
    v_recipient:=case when v_stage=72 then v_assignment.worker_id else v_assignment.poster_id end;
    insert into app_private.assignment_reminder_due(
      assignment_id,terms_version,generation_event_id,stage_hours,reminder_key,
      due_at,recipient_id,notification_type
    ) values(
      p_assignment_id,v_assignment.terms_version,p_event_id,v_stage,
      p_assignment_id::text||':v'||v_assignment.terms_version::text||':'||p_event_id::text||':'||v_stage::text,
      p_anchor_at+pg_catalog.make_interval(hours=>v_stage),v_recipient,v_type
    ) on conflict(assignment_id,terms_version,generation_event_id,stage_hours) do nothing;
  end loop;
end;
$function$;

create function app_private.handle_assignment_reminder_source_event()
returns trigger language plpgsql security definer set search_path = '' as $function$
declare
  v_assignment_id uuid;
  v_anchor_at timestamptz;
  v_generation_created boolean:=false;
  v_case_id uuid;
  v_finalization app_private.assignment_case_finalizations%rowtype;
begin
  if new.event_type='job.assignment_submitted' and
     (new.payload->>'assignment_id') ~* '^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$' then
    v_assignment_id:=(new.payload->>'assignment_id')::uuid;
    select a.submitted_at into v_anchor_at from app_private.assignments a
      where a.assignment_id=v_assignment_id and a.job_id=new.job_id
        and a.terms_version=new.terms_version and a.work_state='submitted';
    if v_anchor_at is not null then
      perform app_private.create_assignment_reminder_generation(new.event_id,v_assignment_id,v_anchor_at);
      v_generation_created:=true;
    end if;
  elsif new.event_type='job.assignment_case_finalized' and
        (new.payload->>'case_id') ~* '^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$' then
    v_case_id:=(new.payload->>'case_id')::uuid;
    select * into v_finalization from app_private.assignment_case_finalizations f
      where f.case_id=v_case_id and f.outcome='no_action' and f.prior_work_state='submitted';
    if found then
      v_assignment_id:=v_finalization.assignment_id;
      v_anchor_at:=v_finalization.executed_at;
      if exists(select 1 from app_private.assignment_cases c
          where c.case_id=v_case_id and c.lifecycle_status='closed' and c.closed_at is not null)
         and exists(select 1 from app_private.assignments a
          where a.assignment_id=v_assignment_id and a.job_id=new.job_id
            and a.terms_version=new.terms_version and a.work_state='submitted') then
        perform app_private.create_assignment_reminder_generation(new.event_id,v_assignment_id,v_anchor_at);
        v_generation_created:=true;
      end if;
    end if;
  elsif new.event_type in (
    'job.assignment_completed','job.assignment_hold_opened',
    'job.assignment_cancellation_completed','job.assignment_abandoned'
  ) and (new.payload->>'assignment_id') ~* '^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$' then
    v_assignment_id:=(new.payload->>'assignment_id')::uuid;
  end if;

  if v_assignment_id is not null then
    if v_generation_created then
      perform app_private.suppress_assignment_reminders(v_assignment_id,new.event_id);
    elsif not app_private.assignment_reminder_is_eligible(v_assignment_id) then
      perform app_private.suppress_assignment_reminders(v_assignment_id,null);
    end if;
  end if;
  return new;
end;
$function$;
create trigger marketplace_outbox_assignment_reminders
after insert on app_private.marketplace_outbox
for each row execute function app_private.handle_assignment_reminder_source_event();

create function app_private.reject_assignment_reminder_identity_change()
returns trigger language plpgsql set search_path = '' as $function$
begin
  if tg_op='DELETE' or new.reminder_id is distinct from old.reminder_id
     or new.assignment_id is distinct from old.assignment_id
     or new.terms_version is distinct from old.terms_version
     or new.generation_event_id is distinct from old.generation_event_id
     or new.stage_hours is distinct from old.stage_hours
     or new.reminder_key is distinct from old.reminder_key
     or new.due_at is distinct from old.due_at
     or new.recipient_id is distinct from old.recipient_id
     or new.notification_type is distinct from old.notification_type
     or new.created_at is distinct from old.created_at
     or (old.notification_id is not null and new.notification_id is distinct from old.notification_id)
     or not (
       (old.status in ('pending','retry_wait') and new.status in ('leased','suppressed','coalesced')) or
       (old.status='leased' and new.status in ('retry_wait','dispatched','suppressed','coalesced','exhausted')) or
       (old.status= new.status and old.status in ('pending','retry_wait','leased'))
     ) then
    raise exception using errcode='55000',message='assignment_reminder_identity_is_immutable';
  end if;
  return new;
end;
$function$;

create function app_private.validate_assignment_reminder_insert()
returns trigger language plpgsql security definer set search_path = '' as $function$
declare v_assignment app_private.assignments%rowtype;
begin
  select * into v_assignment from app_private.assignments where assignment_id=new.assignment_id;
  if not found or v_assignment.terms_version<>new.terms_version or
     (new.stage_hours in (24,48) and (new.notification_type not in (
        'assignment_reminder_24h','assignment_reminder_48h') or new.recipient_id<>v_assignment.poster_id)) or
     (new.stage_hours=72 and (new.notification_type<>'assignment_dispute_guidance_72h'
        or new.recipient_id<>v_assignment.worker_id)) or
     (new.stage_hours=24 and new.notification_type<>'assignment_reminder_24h') or
     (new.stage_hours=48 and new.notification_type<>'assignment_reminder_48h') then
    raise exception using errcode='22023',message='invalid_assignment_reminder';
  end if;
  return new;
end;
$function$;
create trigger assignment_reminder_due_validate_insert
before insert on app_private.assignment_reminder_due
for each row execute function app_private.validate_assignment_reminder_insert();
create trigger assignment_reminder_due_guard
before update or delete on app_private.assignment_reminder_due
for each row execute function app_private.reject_assignment_reminder_identity_change();

create function app_private.claim_assignment_reminder_for_runner_at(
  p_worker_id uuid,p_lease_seconds integer,p_now timestamptz
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare v_reminder app_private.assignment_reminder_due%rowtype; v_token uuid;
begin
  if p_worker_id is null or p_now is null or p_lease_seconds not between 1 and 300 then
    raise exception using errcode='22023',message='invalid_reminder_claim';
  end if;

  update app_private.assignment_reminder_due r
  set status=case when r.attempt_count>=5 then 'exhausted' else 'retry_wait' end,
      safe_error_code=case when r.attempt_count>=5 then 'max_attempts_exhausted' else 'lease_expired' end,
      available_at=case when r.attempt_count>=5 then p_now else p_now+pg_catalog.make_interval(secs=>least(3600,
        30*(2^greatest(0,r.attempt_count-1))::integer)) end,
      lease_token=null,lease_expires_at=null,updated_at=p_now
  where r.status='leased' and r.lease_expires_at<=p_now;

  update app_private.assignment_reminder_due earlier
  set status='coalesced',lease_token=null,lease_expires_at=null,
      safe_error_code=null,updated_at=p_now
  where earlier.due_at<=p_now and earlier.status in ('pending','retry_wait','leased')
    and exists(select 1 from app_private.assignment_reminder_due later
      where later.assignment_id=earlier.assignment_id
        and later.generation_event_id=earlier.generation_event_id
        and later.stage_hours>earlier.stage_hours and later.due_at<=p_now
        and later.status in ('dispatched','suppressed','coalesced','exhausted'));

  select r.* into v_reminder from app_private.assignment_reminder_due r
  where r.due_at<=p_now and r.available_at<=p_now and r.status in ('pending','retry_wait')
    and r.stage_hours=(select max(later.stage_hours) from app_private.assignment_reminder_due later
      where later.assignment_id=r.assignment_id and later.generation_event_id=r.generation_event_id
        and later.due_at<=p_now)
  order by r.due_at,r.reminder_id
  for update skip locked limit 1;
  if not found then return null; end if;

  update app_private.assignment_reminder_due prior
  set status='coalesced',lease_token=null,lease_expires_at=null,
      safe_error_code=null,updated_at=p_now
  where prior.assignment_id=v_reminder.assignment_id
    and prior.generation_event_id=v_reminder.generation_event_id
    and prior.stage_hours<v_reminder.stage_hours and prior.due_at<=p_now
    and prior.status in ('pending','retry_wait','leased');

  v_token:=pg_catalog.gen_random_uuid();
  update app_private.assignment_reminder_due r
  set status='leased',attempt_count=r.attempt_count+1,lease_token=v_token,
      lease_expires_at=p_now+pg_catalog.make_interval(secs=>p_lease_seconds),
      safe_error_code=null,updated_at=p_now
  where r.reminder_id=v_reminder.reminder_id
  returning * into v_reminder;
  return pg_catalog.jsonb_build_object(
    'reminder_id',v_reminder.reminder_id,'lease_token',v_token,
    'stage_hours',v_reminder.stage_hours,'notification_type',v_reminder.notification_type
  );
end;
$function$;

create function app_private.dispatch_assignment_reminder_for_runner_at(
  p_reminder_id uuid,p_lease_token uuid,p_now timestamptz
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_initial app_private.assignment_reminder_due%rowtype;
  v_reminder app_private.assignment_reminder_due%rowtype;
  v_assignment app_private.assignments%rowtype;
  v_allocation app_private.principal_allocations%rowtype;
  v_event_id uuid;
  v_notification_id uuid;
begin
  if p_reminder_id is null or p_lease_token is null or p_now is null then
    raise exception using errcode='22023',message='invalid_reminder_dispatch';
  end if;
  select * into v_initial from app_private.assignment_reminder_due
    where reminder_id=p_reminder_id;
  if not found then raise exception using errcode='P0002',message='reminder_not_found'; end if;
  select * into v_assignment from app_private.assignments where assignment_id=v_initial.assignment_id;
  if not found then raise exception using errcode='P0002',message='reminder_not_found'; end if;
  select * into v_assignment from app_private.assignments
    where assignment_id=v_initial.assignment_id for update;
  if not found then raise exception using errcode='P0002',message='reminder_not_found'; end if;
  select * into v_allocation from app_private.principal_allocations
    where allocation_id=v_assignment.allocation_id;
  if not found then raise exception using errcode='P0002',message='reminder_not_found'; end if;
  select * into v_reminder from app_private.assignment_reminder_due
    where reminder_id=p_reminder_id and status='leased' and lease_token=p_lease_token
      and lease_expires_at>p_now for update;
  if not found then raise exception using errcode='55000',message='reminder_lease_lost'; end if;
  if v_reminder.due_at>p_now then
    raise exception using errcode='55000',message='reminder_not_due';
  end if;

  if v_allocation.assignment_id<>v_assignment.assignment_id or
     not app_private.assignment_reminder_is_eligible(v_assignment.assignment_id) then
    update app_private.assignment_reminder_due set status='suppressed',lease_token=null,
      lease_expires_at=null,updated_at=p_now where reminder_id=p_reminder_id;
    return pg_catalog.jsonb_build_object('status','suppressed');
  end if;

  insert into app_private.marketplace_outbox(actor_id,job_id,event_type,terms_version,payload)
  values(null,v_assignment.job_id,'job.assignment_reminder_dispatched',v_reminder.terms_version,
    pg_catalog.jsonb_build_object('assignment_id',v_assignment.assignment_id,
      'reminder_key',v_reminder.reminder_key,'stage_hours',v_reminder.stage_hours))
  returning event_id into v_event_id;
  perform app_private.add_in_app_notification(
    v_event_id,v_reminder.recipient_id,v_reminder.notification_type);
  select n.notification_id into v_notification_id from app_private.in_app_notifications n
    where n.event_id=v_event_id and n.recipient_id=v_reminder.recipient_id
      and n.notification_type=v_reminder.notification_type;
  update app_private.assignment_reminder_due set status='dispatched',notification_id=v_notification_id,
    lease_token=null,lease_expires_at=null,safe_error_code=null,updated_at=p_now
  where reminder_id=p_reminder_id;
  return pg_catalog.jsonb_build_object('status','dispatched',
    'stage_hours',v_reminder.stage_hours,'notification_type',v_reminder.notification_type);
end;
$function$;

create function app_private.fail_assignment_reminder_for_runner_at(
  p_reminder_id uuid,p_lease_token uuid,p_safe_error_code text,p_now timestamptz
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare v_reminder app_private.assignment_reminder_due%rowtype; v_status text;
begin
  if p_reminder_id is null or p_lease_token is null or p_now is null or p_safe_error_code<>'runner_failure' then
    raise exception using errcode='22023',message='invalid_reminder_failure';
  end if;
  select * into v_reminder from app_private.assignment_reminder_due r
    where r.reminder_id=p_reminder_id and r.status='leased' and r.lease_token=p_lease_token
      and r.lease_expires_at>p_now for update;
  if not found then raise exception using errcode='55000',message='reminder_lease_lost'; end if;
  v_status:=case when v_reminder.attempt_count>=5 then 'exhausted' else 'retry_wait' end;
  update app_private.assignment_reminder_due set status=v_status,
    available_at=case when v_status='exhausted' then p_now else p_now+pg_catalog.make_interval(secs=>least(3600,
      (30*(2^greatest(0,v_reminder.attempt_count-1)))::integer+floor(random()*15)::integer)) end,
    lease_token=null,lease_expires_at=null,
    safe_error_code=case when v_status='exhausted' then 'max_attempts_exhausted' else p_safe_error_code end,
    updated_at=p_now where reminder_id=p_reminder_id returning * into v_reminder;
  return pg_catalog.jsonb_build_object('status',v_reminder.status,
    'attempt_count',v_reminder.attempt_count);
end;
$function$;

create function app_private.authorize_notification_email_dispatch_for_runner(
  p_delivery_id uuid,p_lease_token uuid
) returns boolean language plpgsql security definer set search_path = '' as $function$
declare v_delivery app_private.notification_email_deliveries%rowtype; v_assignment_id uuid;
begin
  if p_delivery_id is null or p_lease_token is null then
    raise exception using errcode='22023',message='invalid_delivery_dispatch_check';
  end if;
  select * into v_delivery from app_private.notification_email_deliveries d
    where d.delivery_id=p_delivery_id and d.status='leased' and d.lease_token=p_lease_token
      and d.lease_expires_at>pg_catalog.clock_timestamp();
  if not found then return false; end if;
  if v_delivery.notification_type not in (
    'assignment_reminder_24h','assignment_reminder_48h','assignment_dispute_guidance_72h'
  ) then return true; end if;
  select r.assignment_id into v_assignment_id from app_private.assignment_reminder_due r
    where r.notification_id=v_delivery.notification_id and r.status='dispatched';
  if v_assignment_id is not null and app_private.assignment_reminder_is_eligible(v_assignment_id) then
    return true;
  end if;
  update app_private.notification_email_deliveries d set status='suppressed',
    lease_token=null,lease_expires_at=null,safe_error_code=null,updated_at=pg_catalog.clock_timestamp()
  where d.delivery_id=p_delivery_id and d.status='leased' and d.lease_token=p_lease_token;
  return false;
end;
$function$;

create function public.server_claim_assignment_reminder_for_runner(
  p_worker_id uuid,p_lease_seconds integer default 60
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.claim_assignment_reminder_for_runner_at($1,$2,pg_catalog.clock_timestamp())
$function$;
create function public.server_dispatch_assignment_reminder_for_runner(
  p_reminder_id uuid,p_lease_token uuid
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.dispatch_assignment_reminder_for_runner_at($1,$2,pg_catalog.clock_timestamp())
$function$;
create function public.server_fail_assignment_reminder_for_runner(
  p_reminder_id uuid,p_lease_token uuid,p_safe_error_code text
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.fail_assignment_reminder_for_runner_at($1,$2,$3,pg_catalog.clock_timestamp())
$function$;
create function public.server_authorize_notification_email_dispatch_for_runner(
  p_delivery_id uuid,p_lease_token uuid
) returns boolean language sql security definer set search_path = '' as $function$
  select app_private.authorize_notification_email_dispatch_for_runner($1,$2)
$function$;

revoke all on table app_private.assignment_reminder_due from public,anon,authenticated,service_role;
revoke all on function app_private.assignment_reminder_is_eligible(uuid),
  app_private.suppress_assignment_reminders(uuid,uuid),
  app_private.create_assignment_reminder_generation(uuid,uuid,timestamptz),
  app_private.handle_assignment_reminder_source_event(),
  app_private.reject_assignment_reminder_identity_change(),
  app_private.validate_assignment_reminder_insert(),
  app_private.claim_assignment_reminder_for_runner_at(uuid,integer,timestamptz),
  app_private.dispatch_assignment_reminder_for_runner_at(uuid,uuid,timestamptz),
  app_private.fail_assignment_reminder_for_runner_at(uuid,uuid,text,timestamptz),
  app_private.authorize_notification_email_dispatch_for_runner(uuid,uuid)
from public,anon,authenticated,service_role;
revoke all on function public.server_claim_assignment_reminder_for_runner(uuid,integer),
  public.server_dispatch_assignment_reminder_for_runner(uuid,uuid),
  public.server_fail_assignment_reminder_for_runner(uuid,uuid,text),
  public.server_authorize_notification_email_dispatch_for_runner(uuid,uuid)
from public,anon,authenticated,service_role;
grant execute on function app_private.claim_assignment_reminder_for_runner_at(uuid,integer,timestamptz),
  app_private.dispatch_assignment_reminder_for_runner_at(uuid,uuid,timestamptz),
  app_private.fail_assignment_reminder_for_runner_at(uuid,uuid,text,timestamptz)
to postgres;
grant execute on function public.server_claim_assignment_reminder_for_runner(uuid,integer),
  public.server_dispatch_assignment_reminder_for_runner(uuid,uuid),
  public.server_fail_assignment_reminder_for_runner(uuid,uuid,text),
  public.server_authorize_notification_email_dispatch_for_runner(uuid,uuid)
to service_role;

commit;
