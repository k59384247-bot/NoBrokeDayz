begin;

alter table app_private.staff_grants drop constraint staff_grants_capability_check;
alter table app_private.staff_grants add constraint staff_grants_capability_check check (capability in (
  'verification_review','identity_suspend','identity_unsuspend','identity_correct_user_type',
  'identity_staff_admin','dispute_review','financial_initiate','financial_approve',
  'financial_inspect','case_senior_signoff','case_appeal_review','notification_delivery_review'
));

alter table app_private.in_app_notifications
  add column identity_event_id uuid references app_private.identity_audit_events(event_id) on delete restrict,
  add column destination_kind text,
  add column destination_id uuid,
  drop constraint in_app_notifications_one_event_source,
  add constraint in_app_notifications_one_event_source check (
    num_nonnulls(event_id,financial_event_id,identity_event_id)=1
  ),
  add constraint in_app_notifications_destination_check check (
    (destination_kind is null and destination_id is null) or
    (destination_kind in ('application','thread','assignment','case','wallet_item') and destination_id is not null)
  );

alter table app_private.in_app_notifications
  drop constraint in_app_notifications_notification_type_check,
  add constraint in_app_notifications_notification_type_check check (notification_type in (
    'application_received','application_accepted','application_rejected','application_withdrawn',
    'application_closed','new_message','assignment_started','assignment_submitted',
    'assignment_completed','assignment_hold_opened','assignment_case_updated',
    'assignment_case_decision','assignment_case_finalized','slot_refund_authorized',
    'assignment_cancellation_requested','assignment_cancellation_completed','assignment_abandoned',
    'withdrawal_requested','withdrawal_processing','withdrawal_unknown','withdrawal_paid',
    'withdrawal_failed','withdrawal_reversed','withdrawal_exception','refund_processing',
    'refund_unknown','refund_settled','refund_failed','refund_exception','refund_reversal_review',
    'verification_submitted','verification_approved','verification_not_approved','verification_revoked'
  ));

create unique index in_app_notifications_identity_event_key
  on app_private.in_app_notifications(recipient_id,identity_event_id,notification_type)
  where identity_event_id is not null;

create function app_private.set_notification_destination()
returns trigger language plpgsql set search_path = '' as $function$
declare
  v_payload jsonb;
  v_reference uuid;
  v_target text;
begin
  if new.event_id is not null then
    select e.payload into v_payload from app_private.marketplace_outbox e where e.event_id=new.event_id;
    v_target:=case
      when new.notification_type like 'application_%' then 'application'
      when new.notification_type='new_message' then 'thread'
      when new.notification_type in ('assignment_case_updated','assignment_case_decision','assignment_case_finalized') then 'case'
      when new.notification_type like 'assignment_%' or new.notification_type='slot_refund_authorized' then 'assignment'
      else null end;
    if v_target='application' and (v_payload->>'application_id') ~* '^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$' then
      new.destination_id:=(v_payload->>'application_id')::uuid;
    elsif v_target='thread' and (v_payload->>'thread_id') ~* '^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$' then
      new.destination_id:=(v_payload->>'thread_id')::uuid;
    elsif v_target='case' and (v_payload->>'case_id') ~* '^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$' then
      new.destination_id:=(v_payload->>'case_id')::uuid;
    elsif v_target='assignment' and (v_payload->>'assignment_id') ~* '^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$' then
      new.destination_id:=(v_payload->>'assignment_id')::uuid;
    end if;
    if new.destination_id is not null then new.destination_kind:=v_target; end if;
  elsif new.financial_event_id is not null then
    select e.reference_id into v_reference from app_private.financial_audit_events e
    where e.event_id=new.financial_event_id;
    if v_reference is not null then
      new.destination_kind:='wallet_item';
      new.destination_id:=v_reference;
    end if;
  end if;
  return new;
end;
$function$;
create trigger in_app_notifications_set_destination
before insert on app_private.in_app_notifications
for each row execute function app_private.set_notification_destination();

with resolved as (
  select n.notification_id,
    case
      when n.event_id is null then 'wallet_item'
      when n.notification_type like 'application_%' then 'application'
      when n.notification_type='new_message' then 'thread'
      when n.notification_type in ('assignment_case_updated','assignment_case_decision','assignment_case_finalized') then 'case'
      when n.notification_type like 'assignment_%' or n.notification_type='slot_refund_authorized' then 'assignment'
      else null end as kind,
    case
      when n.event_id is null then f.reference_id
      when n.notification_type like 'application_%' and (m.payload->>'application_id') ~* '^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$' then (m.payload->>'application_id')::uuid
      when n.notification_type='new_message' and (m.payload->>'thread_id') ~* '^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$' then (m.payload->>'thread_id')::uuid
      when n.notification_type in ('assignment_case_updated','assignment_case_decision','assignment_case_finalized') and (m.payload->>'case_id') ~* '^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$' then (m.payload->>'case_id')::uuid
      when (n.notification_type like 'assignment_%' or n.notification_type='slot_refund_authorized') and (m.payload->>'assignment_id') ~* '^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$' then (m.payload->>'assignment_id')::uuid
      else null end as target_id
  from app_private.in_app_notifications n
  left join app_private.marketplace_outbox m on m.event_id=n.event_id
  left join app_private.financial_audit_events f on f.event_id=n.financial_event_id
  where n.destination_id is null
)
update app_private.in_app_notifications n
set destination_kind=case when r.target_id is null then null else r.kind end,
    destination_id=r.target_id
from resolved r where r.notification_id=n.notification_id;

create function app_private.add_identity_in_app_notification(
  p_event_id uuid,p_recipient uuid,p_notification_type text
) returns void language sql security definer set search_path = '' as $function$
  insert into app_private.in_app_notifications(identity_event_id,recipient_id,notification_type)
  values(p_event_id,p_recipient,p_notification_type)
  on conflict(recipient_id,identity_event_id,notification_type)
    where identity_event_id is not null do nothing
$function$;

create function app_private.create_verification_result_notice()
returns trigger language plpgsql security definer set search_path = '' as $function$
declare v_type text;
begin
  if new.event_type<>'verification_result' then return new; end if;
  v_type:=case new.payload->>'status'
    when 'pending' then 'verification_submitted'
    when 'approved' then 'verification_approved'
    when 'rejected' then 'verification_not_approved'
    when 'revoked' then 'verification_revoked'
    else null end;
  if v_type is not null then
    perform app_private.add_identity_in_app_notification(new.event_id,new.subject_id,v_type);
  end if;
  return new;
end;
$function$;
create trigger identity_outbox_verification_notice
after insert on app_private.identity_outbox
for each row execute function app_private.create_verification_result_notice();

insert into app_private.in_app_notifications(identity_event_id,recipient_id,notification_type)
select io.event_id,io.subject_id,
  case io.payload->>'status'
    when 'pending' then 'verification_submitted'
    when 'approved' then 'verification_approved'
    when 'rejected' then 'verification_not_approved'
    when 'revoked' then 'verification_revoked'
  end
from app_private.identity_outbox io
where io.event_type='verification_result'
  and io.payload->>'status' in ('pending','approved','rejected','revoked')
on conflict(recipient_id,identity_event_id,notification_type)
  where identity_event_id is not null do nothing;

create table app_private.notification_email_deliveries (
  delivery_id uuid primary key default pg_catalog.gen_random_uuid(),
  notification_id uuid not null references app_private.in_app_notifications(notification_id) on delete restrict,
  source_kind text not null check (source_kind in ('marketplace','financial','identity')),
  source_event_id uuid not null,
  recipient_id uuid not null references auth.users(id) on delete restrict,
  channel text not null default 'email' check (channel='email'),
  notification_type text not null,
  template_key text not null default 'transactional_notice_v1'
    check (template_key='transactional_notice_v1'),
  status text not null default 'pending' check (status in (
    'pending','leased','retry_wait','provider_accepted','delivered','permanent_failure',
    'unknown','exhausted','suppressed'
  )),
  attempt_count smallint not null default 0 check (attempt_count between 0 and 5),
  available_at timestamptz not null default pg_catalog.now(),
  lease_token uuid,
  lease_expires_at timestamptz,
  safe_error_code text check (safe_error_code is null or safe_error_code in (
    'recipient_unavailable','capture_rejected','capture_unavailable','ambiguous_result',
    'lease_expired','max_attempts_exhausted'
  )),
  provider_capture_id uuid,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  unique(notification_id,channel),
  check ((status='leased' and lease_token is not null and lease_expires_at is not null) or
    (status<>'leased' and lease_token is null and lease_expires_at is null))
);
create unique index notification_email_deliveries_source_key
  on app_private.notification_email_deliveries(recipient_id,source_kind,source_event_id,channel,notification_type);
create index notification_email_deliveries_claim_idx
  on app_private.notification_email_deliveries(status,available_at,created_at)
  where status in ('pending','retry_wait','leased','unknown');

create function app_private.enqueue_transactional_notice_email()
returns trigger language plpgsql security definer set search_path = '' as $function$
declare
  v_source_kind text;
  v_source_id uuid;
begin
  if new.notification_type in ('new_message','assignment_case_updated') then return new; end if;
  if new.event_id is not null then v_source_kind:='marketplace'; v_source_id:=new.event_id;
  elsif new.financial_event_id is not null then v_source_kind:='financial'; v_source_id:=new.financial_event_id;
  else v_source_kind:='identity'; v_source_id:=new.identity_event_id; end if;
  insert into app_private.notification_email_deliveries(
    notification_id,source_kind,source_event_id,recipient_id,notification_type
  ) values(new.notification_id,v_source_kind,v_source_id,new.recipient_id,new.notification_type)
  on conflict(recipient_id,source_kind,source_event_id,channel,notification_type) do nothing;
  return new;
end;
$function$;
create trigger in_app_notifications_email_intent
after insert on app_private.in_app_notifications
for each row execute function app_private.enqueue_transactional_notice_email();

create or replace function app_private.guard_in_app_notification_change()
returns trigger language plpgsql set search_path = '' as $function$
begin
  if tg_op='DELETE' or new.notification_id is distinct from old.notification_id
     or new.event_id is distinct from old.event_id
     or new.financial_event_id is distinct from old.financial_event_id
     or new.identity_event_id is distinct from old.identity_event_id
     or new.destination_kind is distinct from old.destination_kind
     or new.destination_id is distinct from old.destination_id
     or new.recipient_id is distinct from old.recipient_id
     or new.notification_type is distinct from old.notification_type
     or new.created_at is distinct from old.created_at
     or (old.read_at is not null and new.read_at is distinct from old.read_at)
     or new.read_at is null then
    raise exception using errcode='55000',message='notification_is_immutable_except_first_read';
  end if;
  return new;
end;
$function$;

create or replace function app_private.list_my_notifications_for_actor(
  p_actor uuid,p_before_created_at timestamptz default null,p_before_id uuid default null
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare v_result jsonb;
begin
  if p_actor is null or ((p_before_created_at is null)<>(p_before_id is null)) then
    raise exception using errcode='22023',message='invalid_notification_cursor';
  end if;
  with page as (
    select n.notification_id,n.notification_type,n.created_at,n.read_at,n.destination_kind,n.destination_id
    from app_private.in_app_notifications n where n.recipient_id=p_actor
      and (p_before_created_at is null or (n.created_at,n.notification_id)<(p_before_created_at,p_before_id))
    order by n.created_at desc,n.notification_id desc limit 21
  )
  select pg_catalog.jsonb_build_object(
    'notifications',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'notification_id',p.notification_id,'notification_type',p.notification_type,
      'created_at',p.created_at,'read_at',p.read_at,
      'destination_kind',p.destination_kind,'destination_id',p.destination_id
    ) order by p.created_at desc,p.notification_id desc) from (
      select * from page order by created_at desc,notification_id desc limit 20
    ) p),'[]'::jsonb),
    'next_cursor',case when (select count(*) from page)>20 then (
      select pg_catalog.jsonb_build_object('created_at',p.created_at,'id',p.notification_id)
      from page p order by p.created_at desc,p.notification_id desc offset 19 limit 1
    ) else null end
  ) into v_result;
  return v_result;
end;
$function$;

create or replace function app_private.mark_my_notification_read_for_actor(
  p_actor uuid,p_notification_id uuid
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare v_notice app_private.in_app_notifications%rowtype;
begin
  if p_actor is null or p_notification_id is null then
    raise exception using errcode='22023',message='invalid_notification_request';
  end if;
  update app_private.in_app_notifications n set read_at=coalesce(n.read_at,pg_catalog.now())
  where n.notification_id=p_notification_id and n.recipient_id=p_actor returning * into v_notice;
  if not found then return null; end if;
  return pg_catalog.jsonb_build_object(
    'notification_id',v_notice.notification_id,'notification_type',v_notice.notification_type,
    'created_at',v_notice.created_at,'read_at',v_notice.read_at,
    'destination_kind',v_notice.destination_kind,'destination_id',v_notice.destination_id
  );
end;
$function$;

create function app_private.claim_notification_email_for_runner(
  p_worker_id uuid,p_lease_seconds integer default 60
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare v_delivery app_private.notification_email_deliveries%rowtype; v_prior_status text;
begin
  if p_worker_id is null or p_lease_seconds not between 1 and 300 then
    raise exception using errcode='22023',message='invalid_delivery_claim';
  end if;
  update app_private.notification_email_deliveries d
  set status='unknown',safe_error_code='lease_expired',lease_token=null,lease_expires_at=null,
      available_at=pg_catalog.now(),updated_at=pg_catalog.now()
  where d.status='leased' and d.lease_expires_at<=pg_catalog.now();
  select d.* into v_delivery from app_private.notification_email_deliveries d
  where d.status in ('pending','retry_wait','unknown') and d.available_at<=pg_catalog.now()
    and d.attempt_count<5
  order by d.available_at,d.created_at,d.delivery_id
  for update skip locked limit 1;
  if not found then return null; end if;
  v_prior_status:=v_delivery.status;
  update app_private.notification_email_deliveries d
  set status='leased',attempt_count=d.attempt_count+1,lease_token=pg_catalog.gen_random_uuid(),
      lease_expires_at=pg_catalog.now()+pg_catalog.make_interval(secs=>p_lease_seconds),
      safe_error_code=null,updated_at=pg_catalog.now()
  where d.delivery_id=v_delivery.delivery_id
  returning d.* into v_delivery;
  if not found then return null; end if;
  return pg_catalog.jsonb_build_object(
    'delivery_id',v_delivery.delivery_id,'lease_token',v_delivery.lease_token,
    'recipient_id',v_delivery.recipient_id,'notification_type',v_delivery.notification_type,
    'attempt_count',v_delivery.attempt_count,'previous_status',v_prior_status
  );
end;
$function$;

create function app_private.complete_notification_email_for_runner(
  p_delivery_id uuid,p_lease_token uuid,p_status text,p_safe_error_code text default null,
  p_provider_capture_id uuid default null
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare v_delivery app_private.notification_email_deliveries%rowtype; v_status text; v_available timestamptz;
begin
  if p_delivery_id is null or p_lease_token is null or p_status not in ('provider_accepted','retry_wait','unknown','permanent_failure') then
    raise exception using errcode='22023',message='invalid_delivery_result';
  end if;
  select * into v_delivery from app_private.notification_email_deliveries d
  where d.delivery_id=p_delivery_id and d.status='leased' and d.lease_token=p_lease_token
    and d.lease_expires_at>pg_catalog.now() for update;
  if not found then raise exception using errcode='55000',message='delivery_lease_lost'; end if;
  v_status:=p_status;
  v_available:=pg_catalog.now();
  if p_status='retry_wait' then
    if v_delivery.attempt_count>=5 then
      v_status:='exhausted';
    else
      v_available:=pg_catalog.now()+pg_catalog.make_interval(secs=>least(3600,
        (30 * (2 ^ greatest(0,v_delivery.attempt_count-1)))::integer + floor(random()*15)::integer));
    end if;
  elsif p_status='unknown' then
    v_available:=pg_catalog.now()+pg_catalog.make_interval(secs=>60);
  end if;
  update app_private.notification_email_deliveries d
  set status=v_status,lease_token=null,lease_expires_at=null,available_at=v_available,
      safe_error_code=case when v_status='exhausted' then 'max_attempts_exhausted' else p_safe_error_code end,
      provider_capture_id=coalesce(p_provider_capture_id,d.provider_capture_id),updated_at=pg_catalog.now()
  where d.delivery_id=p_delivery_id returning * into v_delivery;
  return pg_catalog.jsonb_build_object('delivery_id',v_delivery.delivery_id,'status',v_delivery.status);
end;
$function$;

create function app_private.list_notification_delivery_attention_for_actor(
  p_actor uuid,p_auth_aal text,p_before_updated_at timestamptz default null,
  p_before_delivery_id uuid default null
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare v_items jsonb; v_cursor jsonb;
begin
  if (p_before_updated_at is null)<>(p_before_delivery_id is null) then
    raise exception using errcode='22023',message='invalid_delivery_cursor';
  end if;
  if not app_private.staff_actor_has_current_capability(p_actor,'notification_delivery_review',p_auth_aal) then
    raise exception using errcode='42501',message='staff_access_denied';
  end if;
  with page as (
    select d.* from app_private.notification_email_deliveries d
    where d.status in ('permanent_failure','unknown','exhausted')
      and (p_before_updated_at is null or (d.updated_at,d.delivery_id)<(p_before_updated_at,p_before_delivery_id))
    order by d.updated_at desc,d.delivery_id desc limit 51
  )
  select coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'delivery_id',p.delivery_id,'recipient_id',p.recipient_id,'notification_type',p.notification_type,
      'status',p.status,'attempt_count',p.attempt_count,'safe_error_code',p.safe_error_code,
      'created_at',p.created_at,'updated_at',p.updated_at
    ) order by p.updated_at desc,p.delivery_id desc) from (
      select * from page order by updated_at desc,delivery_id desc limit 50
    ) p),'[]'::jsonb),
    case when (select count(*) from page)>50 then (
      select pg_catalog.jsonb_build_object('updated_at',p.updated_at,'id',p.delivery_id)
      from page p order by p.updated_at desc,p.delivery_id desc offset 49 limit 1
    ) else null end
  into v_items,v_cursor;
  return pg_catalog.jsonb_build_object('items',v_items,'next_cursor',v_cursor);
end;
$function$;

create function public.server_claim_notification_email_for_runner(p_worker_id uuid,p_lease_seconds integer default 60)
returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.claim_notification_email_for_runner($1,$2)
$function$;
create function public.server_complete_notification_email_for_runner(
  p_delivery_id uuid,p_lease_token uuid,p_status text,p_safe_error_code text default null,
  p_provider_capture_id uuid default null
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.complete_notification_email_for_runner($1,$2,$3,$4,$5)
$function$;
create function public.server_list_notification_delivery_attention_for_actor(
  p_actor uuid,p_auth_aal text,p_before_updated_at timestamptz default null,
  p_before_delivery_id uuid default null
)
returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.list_notification_delivery_attention_for_actor($1,$2,$3,$4)
$function$;

revoke all on table app_private.notification_email_deliveries from public,anon,authenticated,service_role;
revoke all on function app_private.set_notification_destination(),app_private.add_identity_in_app_notification(uuid,uuid,text),
  app_private.create_verification_result_notice(),app_private.enqueue_transactional_notice_email(),
  app_private.claim_notification_email_for_runner(uuid,integer),
  app_private.complete_notification_email_for_runner(uuid,uuid,text,text,uuid),
  app_private.list_notification_delivery_attention_for_actor(uuid,text,timestamptz,uuid)
from public,anon,authenticated,service_role;
revoke all on function public.server_claim_notification_email_for_runner(uuid,integer),
  public.server_complete_notification_email_for_runner(uuid,uuid,text,text,uuid),
  public.server_list_notification_delivery_attention_for_actor(uuid,text,timestamptz,uuid)
from public,anon,authenticated,service_role;
grant execute on function public.server_claim_notification_email_for_runner(uuid,integer),
  public.server_complete_notification_email_for_runner(uuid,uuid,text,text,uuid),
  public.server_list_notification_delivery_attention_for_actor(uuid,text,timestamptz,uuid)
to service_role;

commit;
