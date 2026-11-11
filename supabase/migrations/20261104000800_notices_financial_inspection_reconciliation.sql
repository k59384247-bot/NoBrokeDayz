begin;

-- Existing marketplace events already create notices inside their business
-- transactions. This extends the same recipient table to financial events.
alter table app_private.in_app_notifications
  alter column event_id drop not null,
  add column financial_event_id uuid references app_private.financial_audit_events(event_id) on delete restrict;
alter table app_private.in_app_notifications
  drop constraint in_app_notifications_notification_type_check,
  add constraint in_app_notifications_notification_type_check check (notification_type in (
    'application_received','application_accepted','application_rejected',
    'application_withdrawn','application_closed','new_message',
    'assignment_started','assignment_submitted','assignment_completed',
    'assignment_hold_opened','withdrawal_requested','withdrawal_processing',
    'withdrawal_unknown','withdrawal_paid','withdrawal_failed','withdrawal_reversed',
    'withdrawal_exception'
  )),
  add constraint in_app_notifications_one_event_source check (
    (event_id is not null and financial_event_id is null) or
    (event_id is null and financial_event_id is not null)
  );
create unique index in_app_notifications_financial_event_key
  on app_private.in_app_notifications(recipient_id,financial_event_id,notification_type)
  where financial_event_id is not null;

create function app_private.guard_in_app_notification_change()
returns trigger language plpgsql set search_path = '' as $function$
begin
  if tg_op='DELETE' or new.notification_id is distinct from old.notification_id
     or new.event_id is distinct from old.event_id
     or new.financial_event_id is distinct from old.financial_event_id
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
create trigger in_app_notifications_guard_change
before update or delete on app_private.in_app_notifications
for each row execute function app_private.guard_in_app_notification_change();

create or replace function app_private.add_in_app_notification(
  p_event_id uuid,p_recipient uuid,p_notification_type text
) returns void language sql security definer set search_path = '' as $function$
  insert into app_private.in_app_notifications(event_id,recipient_id,notification_type)
  values(p_event_id,p_recipient,p_notification_type)
  on conflict(recipient_id,event_id,notification_type) do nothing
$function$;

create function app_private.add_financial_in_app_notification(
  p_event_id uuid,p_recipient uuid,p_notification_type text
) returns void language sql security definer set search_path = '' as $function$
  insert into app_private.in_app_notifications(financial_event_id,recipient_id,notification_type)
  values(p_event_id,p_recipient,p_notification_type)
  on conflict(recipient_id,financial_event_id,notification_type)
    where financial_event_id is not null do nothing
$function$;

create function app_private.list_my_notifications_for_actor(
  p_actor uuid,p_before_created_at timestamptz default null,p_before_id uuid default null
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare v_result jsonb;
begin
  if p_actor is null or ((p_before_created_at is null)<>(p_before_id is null)) then
    raise exception using errcode='22023',message='invalid_notification_cursor';
  end if;
  with page as (
    select n.notification_id,n.notification_type,n.created_at,n.read_at
    from app_private.in_app_notifications n
    where n.recipient_id=p_actor
      and (p_before_created_at is null or (n.created_at,n.notification_id)<(p_before_created_at,p_before_id))
    order by n.created_at desc,n.notification_id desc limit 21
  )
  select pg_catalog.jsonb_build_object(
    'notifications',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'notification_id',p.notification_id,'notification_type',p.notification_type,
      'created_at',p.created_at,'read_at',p.read_at
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

create function app_private.mark_my_notification_read_for_actor(
  p_actor uuid,p_notification_id uuid
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare v_notice app_private.in_app_notifications%rowtype;
begin
  if p_actor is null or p_notification_id is null then
    raise exception using errcode='22023',message='invalid_notification_request';
  end if;
  update app_private.in_app_notifications n
  set read_at=coalesce(n.read_at,pg_catalog.now())
  where n.notification_id=p_notification_id and n.recipient_id=p_actor
  returning * into v_notice;
  if not found then return null; end if;
  return pg_catalog.jsonb_build_object(
    'notification_id',v_notice.notification_id,
    'notification_type',v_notice.notification_type,
    'created_at',v_notice.created_at,'read_at',v_notice.read_at
  );
end;
$function$;

-- Each financial audit event gets a row in this internal hash chain. The chain
-- detects later database-level edits; it is not an independent signed checkpoint.
create table app_private.financial_audit_integrity (
  chain_position bigint generated always as identity primary key,
  event_id uuid not null unique references app_private.financial_audit_events(event_id) on delete restrict,
  previous_hash bytea check (previous_hash is null or pg_catalog.octet_length(previous_hash)=32),
  event_hash bytea not null check (pg_catalog.octet_length(event_hash)=32),
  created_at timestamptz not null default pg_catalog.now()
);

create function app_private.financial_audit_event_hash(
  p_event_id uuid,p_actor_id uuid,p_event_type text,p_journal_id uuid,
  p_operation_id uuid,p_reference_id uuid,p_event_data jsonb,p_created_at timestamptz,
  p_previous_hash bytea
) returns bytea language sql immutable set search_path = '' as $function$
  select extensions.digest(
    coalesce(p_previous_hash,pg_catalog.decode(pg_catalog.repeat('00',32),'hex')) ||
    pg_catalog.convert_to(pg_catalog.jsonb_build_array(
      p_event_id,p_actor_id,p_event_type,p_journal_id,p_operation_id,p_reference_id,
      p_event_data,pg_catalog.to_char(p_created_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
    )::text,'UTF8'),'sha256')
$function$;

do $backfill_financial_audit_chain$
declare
  v_event record;
  v_previous bytea;
  v_hash bytea;
begin
  for v_event in select * from app_private.financial_audit_events order by created_at,event_id loop
    v_hash:=app_private.financial_audit_event_hash(
      v_event.event_id,v_event.actor_id,v_event.event_type,v_event.journal_id,
      v_event.operation_id,v_event.reference_id,v_event.event_data,v_event.created_at,v_previous);
    insert into app_private.financial_audit_integrity(event_id,previous_hash,event_hash)
      values(v_event.event_id,v_previous,v_hash);
    v_previous:=v_hash;
  end loop;
end;
$backfill_financial_audit_chain$;

create function app_private.append_financial_audit_integrity()
returns trigger language plpgsql security definer set search_path = '' as $function$
declare v_previous bytea; v_hash bytea;
begin
  perform pg_catalog.pg_advisory_xact_lock(87012,1);
  select event_hash into v_previous from app_private.financial_audit_integrity
  order by chain_position desc limit 1;
  v_hash:=app_private.financial_audit_event_hash(
    new.event_id,new.actor_id,new.event_type,new.journal_id,new.operation_id,
    new.reference_id,new.event_data,new.created_at,v_previous);
  insert into app_private.financial_audit_integrity(event_id,previous_hash,event_hash)
    values(new.event_id,v_previous,v_hash);
  return new;
end;
$function$;
create trigger financial_audit_integrity_append
after insert on app_private.financial_audit_events
for each row execute function app_private.append_financial_audit_integrity();
create trigger financial_audit_integrity_immutable
before update or delete on app_private.financial_audit_integrity
for each row execute function app_private.reject_financial_history_mutation();

create function app_private.financial_audit_integrity_valid()
returns boolean language plpgsql stable security definer set search_path = '' as $function$
declare
  v_row record;
  v_previous bytea;
  v_expected bytea;
  v_count bigint:=0;
begin
  if (select count(*) from app_private.financial_audit_events)<>
     (select count(*) from app_private.financial_audit_integrity) then return false; end if;
  for v_row in
    select e.*,h.chain_position,h.previous_hash,h.event_hash
    from app_private.financial_audit_integrity h
    join app_private.financial_audit_events e using(event_id)
    order by h.chain_position
  loop
    if v_row.previous_hash is distinct from v_previous then return false; end if;
    v_expected:=app_private.financial_audit_event_hash(
      v_row.event_id,v_row.actor_id,v_row.event_type,v_row.journal_id,
      v_row.operation_id,v_row.reference_id,v_row.event_data,v_row.created_at,v_previous);
    if v_expected is distinct from v_row.event_hash then return false; end if;
    v_previous:=v_expected;
    v_count:=v_count+1;
  end loop;
  return v_count=(select count(*) from app_private.financial_audit_events);
end;
$function$;

alter table app_private.financial_audit_events
  drop constraint financial_audit_events_event_type_check,
  add constraint financial_audit_events_event_type_check check (event_type in (
    'financial_journal_posted','financial_inspection','assignment_completion_authorized',
    'assignment_hold_opened','wallet_destination_changed','withdrawal_requested',
    'withdrawal_status_changed','financial_authorization_created',
    'provider_operation_authorized','provider_operation_status_changed',
    'financial_reconciliation_completed'
  ));
alter table app_private.financial_outbox
  drop constraint financial_outbox_event_type_check,
  add constraint financial_outbox_event_type_check check (event_type in (
    'financial.journal_posted','financial.wallet_destination_changed',
    'financial.withdrawal_requested','financial.withdrawal_status_changed',
    'financial.authorization_created','financial.provider_operation_authorized',
    'financial.provider_operation_status_changed','financial.inspection',
    'financial.reconciliation_completed'
  ));

create function app_private.audit_financial_authorization_created()
returns trigger language plpgsql security definer set search_path = '' as $function$
declare v_event uuid;
begin
  insert into app_private.financial_audit_events(actor_id,event_type,reference_id,event_data)
  values(new.actor_id,'financial_authorization_created',new.authorization_id,
    pg_catalog.jsonb_build_object('action',new.action,'amount_kobo',new.amount_kobo::text,
      'destination_id',new.destination_id,'destination_version',new.destination_version,
      'expires_at',new.expires_at)) returning event_id into v_event;
  insert into app_private.financial_outbox(event_id,event_type,payload)
  values(v_event,'financial.authorization_created',pg_catalog.jsonb_build_object(
    'event_id',v_event,'reference_id',new.authorization_id,'action',new.action));
  return new;
end;
$function$;
create trigger financial_authorizations_audit_insert
after insert on app_private.financial_authorizations
for each row execute function app_private.audit_financial_authorization_created();

create function app_private.audit_provider_operation_change()
returns trigger language plpgsql security definer set search_path = '' as $function$
declare
  v_event uuid;
  v_type text;
  v_outbox_type text;
  v_data jsonb;
begin
  if tg_op='UPDATE' and new.status is not distinct from old.status then return new; end if;
  if tg_op='INSERT' then
    v_type:='provider_operation_authorized';
    v_outbox_type:='financial.provider_operation_authorized';
    v_data:=pg_catalog.jsonb_build_object('operation_type',new.operation_type,
      'status',new.status,'amount_kobo',new.amount_kobo::text,'currency',new.currency,
      'result_source','local_simulator');
  else
    v_type:='provider_operation_status_changed';
    v_outbox_type:='financial.provider_operation_status_changed';
    v_data:=pg_catalog.jsonb_build_object('operation_type',new.operation_type,
      'previous_status',old.status,'status',new.status,'safe_error_code',new.safe_error_code,
      'result_source','local_simulator');
  end if;
  insert into app_private.financial_audit_events(
    actor_id,event_type,operation_id,reference_id,event_data
  ) values(new.actor_id,v_type,new.operation_id,new.operation_id,v_data)
  returning event_id into v_event;
  insert into app_private.financial_outbox(event_id,event_type,payload)
  values(v_event,v_outbox_type,pg_catalog.jsonb_build_object(
    'event_id',v_event,'operation_id',new.operation_id,'status',new.status));
  return new;
end;
$function$;
create trigger provider_operations_audit_insert
after insert on app_private.provider_operations
for each row execute function app_private.audit_provider_operation_change();
create trigger provider_operations_audit_status
after update of status on app_private.provider_operations
for each row execute function app_private.audit_provider_operation_change();

create or replace function app_private.audit_wallet_event(
  p_actor uuid,p_event_type text,p_reference uuid,p_event_data jsonb
) returns uuid language plpgsql security definer set search_path = '' as $function$
declare
  v_event uuid;
  v_recipient uuid;
  v_status text;
  v_notice text;
begin
  insert into app_private.financial_audit_events(actor_id,event_type,reference_id,event_data)
  values(p_actor,p_event_type,p_reference,coalesce(p_event_data,'{}'::jsonb))
  returning event_id into v_event;
  insert into app_private.financial_outbox(event_id,event_type,payload)
  values(v_event,case p_event_type
    when 'wallet_destination_changed' then 'financial.wallet_destination_changed'
    when 'withdrawal_requested' then 'financial.withdrawal_requested'
    else 'financial.withdrawal_status_changed' end,
    pg_catalog.jsonb_build_object('event_id',v_event,'reference_id',p_reference,
      'event_type',p_event_type));

  if p_event_type in ('withdrawal_requested','withdrawal_status_changed') then
    select w.actor_id into v_recipient from app_private.withdrawal_requests w
    where w.withdrawal_id=p_reference;
    v_status:=p_event_data->>'status';
    v_notice:=case
      when p_event_type='withdrawal_requested' then 'withdrawal_requested'
      when v_status='processing' then 'withdrawal_processing'
      when v_status='unknown' then 'withdrawal_unknown'
      when v_status='paid' then 'withdrawal_paid'
      when v_status='failed' then 'withdrawal_failed'
      when v_status='reversed' then 'withdrawal_reversed'
      when v_status='exception' then 'withdrawal_exception'
      else null end;
    if v_recipient is not null and v_notice is not null then
      perform app_private.add_financial_in_app_notification(v_event,v_recipient,v_notice);
    end if;
  end if;
  return v_event;
end;
$function$;

create table app_private.financial_reconciliation_runs (
  run_id uuid primary key,
  actor_id uuid not null references auth.users(id) on delete restrict,
  audit_event_id uuid not null unique references app_private.financial_audit_events(event_id) on delete restrict,
  status text not null check (status in ('balanced','mismatch')),
  simulator_cash_kobo bigint not null check (simulator_cash_kobo>=0),
  simulator_receivable_kobo bigint not null check (simulator_receivable_kobo>=0),
  finding_count integer not null check (finding_count>=0),
  result_sha256 bytea not null check (pg_catalog.octet_length(result_sha256)=32),
  created_at timestamptz not null default pg_catalog.now()
);
create table app_private.financial_reconciliation_findings (
  finding_id uuid primary key default pg_catalog.gen_random_uuid(),
  run_id uuid not null references app_private.financial_reconciliation_runs(run_id) on delete restrict,
  finding_code text not null check (finding_code in (
    'projection_balance_mismatch','simulator_cash_mismatch',
    'simulator_receivable_mismatch','unresolved_operation',
    'held_liability_mismatch','audit_chain_mismatch'
  )),
  reference_id uuid,
  expected_value text,
  observed_value text,
  safe_data jsonb not null default '{}'::jsonb check (pg_catalog.jsonb_typeof(safe_data)='object'),
  created_at timestamptz not null default pg_catalog.now()
);
create index financial_reconciliation_findings_run_idx
  on app_private.financial_reconciliation_findings(run_id,created_at,finding_id);
create trigger financial_reconciliation_runs_immutable
before update or delete on app_private.financial_reconciliation_runs
for each row execute function app_private.reject_financial_history_mutation();
create trigger financial_reconciliation_findings_immutable
before update or delete on app_private.financial_reconciliation_findings
for each row execute function app_private.reject_financial_history_mutation();

create function app_private.inspect_financial_reference_for_actor(
  p_actor uuid,p_auth_aal text,p_reference_type text,p_reference_value text
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_ref uuid;
  v_exists boolean:=false;
  v_ops uuid[]:=array[]::uuid[];
  v_fundings uuid[]:=array[]::uuid[];
  v_withdrawals uuid[]:=array[]::uuid[];
  v_jobs uuid[]:=array[]::uuid[];
  v_allocations uuid[]:=array[]::uuid[];
  v_assignments uuid[]:=array[]::uuid[];
  v_journals uuid[]:=array[]::uuid[];
  v_result jsonb;
  v_audit uuid;
begin
  if not app_private.staff_actor_has_current_capability(p_actor,'financial_inspect',p_auth_aal) then
    raise exception using errcode='42501',message='financial_inspection_denied';
  end if;
  if p_reference_type not in ('operation','provider_reference','funding_intent','withdrawal','journal','job','reconciliation_run')
     or p_reference_value is null or pg_catalog.char_length(p_reference_value)>180 then
    raise exception using errcode='22023',message='invalid_financial_reference';
  end if;
  if p_reference_type='provider_reference' then
    if p_reference_value !~ '^sim-[0-9a-fA-F-]{36}$' then
      raise exception using errcode='22023',message='invalid_financial_reference';
    end if;
    select o.operation_id into v_ref from app_private.provider_operations o
    where o.provider_adapter='local_simulator' and o.provider_operation_reference=p_reference_value;
    v_exists:=found;
  else
    if p_reference_value !~ '^[0-9a-fA-F-]{36}$' then
      raise exception using errcode='22023',message='invalid_financial_reference';
    end if;
    v_ref:=p_reference_value::uuid;
    v_exists:=case p_reference_type
      when 'operation' then exists(select 1 from app_private.provider_operations where operation_id=v_ref)
      when 'funding_intent' then exists(select 1 from app_private.funding_intents where intent_id=v_ref)
      when 'withdrawal' then exists(select 1 from app_private.withdrawal_requests where withdrawal_id=v_ref)
      when 'journal' then exists(select 1 from app_private.ledger_journal_transactions where journal_id=v_ref)
      when 'job' then exists(select 1 from app_private.jobs where job_id=v_ref)
      when 'reconciliation_run' then exists(select 1 from app_private.financial_reconciliation_runs where run_id=v_ref)
      else false end;
  end if;
  if not v_exists then raise exception using errcode='P0002',message='reference_not_found'; end if;

  if p_reference_type='operation' or p_reference_type='provider_reference' then
    v_ops:=array[v_ref];
  elsif p_reference_type='funding_intent' then
    select coalesce(array_agg(o.operation_id order by o.created_at,o.operation_id),array[]::uuid[])
      into v_ops from app_private.provider_operations o where o.funding_intent_id=v_ref;
  elsif p_reference_type='withdrawal' then
    select coalesce(array_agg(w.operation_id),array[]::uuid[]) into v_ops
      from app_private.withdrawal_requests w where w.withdrawal_id=v_ref;
  elsif p_reference_type='job' then
    select coalesce(array_agg(q.operation_id order by q.created_at,q.operation_id),array[]::uuid[])
      into v_ops from (select o.operation_id,o.created_at
        from app_private.provider_operations o
        join app_private.funding_intents f on f.intent_id=o.funding_intent_id
        where f.job_id=v_ref order by o.created_at,o.operation_id limit 20) q;
  elsif p_reference_type='journal' then
    select coalesce(array_agg(o.operation_id),array[]::uuid[]) into v_ops
      from app_private.provider_operations o
      where o.operation_id=(select j.reference_id from app_private.ledger_journal_transactions j where j.journal_id=v_ref)
        or o.operation_id=(select j.effect_key from app_private.ledger_journal_transactions j where j.journal_id=v_ref)
        or o.operation_id in (select f.operation_id from app_private.funding_attempts f
          where f.attempt_id=(select j.effect_key from app_private.ledger_journal_transactions j where j.journal_id=v_ref));
  end if;

  select coalesce(array_agg(distinct f.intent_id),array[]::uuid[]) into v_fundings
  from app_private.funding_intents f
  where f.intent_id=v_ref and p_reference_type='funding_intent'
     or f.job_id=v_ref and p_reference_type='job'
     or f.intent_id in (select o.funding_intent_id from app_private.provider_operations o where o.operation_id=any(v_ops));
  select coalesce(array_agg(w.withdrawal_id),array[]::uuid[]) into v_withdrawals
  from app_private.withdrawal_requests w
  where (w.withdrawal_id=v_ref and p_reference_type='withdrawal')
     or w.operation_id=any(v_ops);
  select coalesce(array_agg(distinct j.job_id),array[]::uuid[]) into v_jobs
  from app_private.jobs j
  where j.job_id=v_ref and p_reference_type='job'
     or j.job_id in (select f.job_id from app_private.funding_intents f where f.intent_id=any(v_fundings));
  select coalesce(array_agg(distinct a.allocation_id),array[]::uuid[]) into v_allocations
  from app_private.principal_allocations a
  where a.job_id=any(v_jobs) or a.funding_intent_id=any(v_fundings)
     or a.allocation_id in (select o.allocation_id from app_private.provider_operations o where o.operation_id=any(v_ops))
     or a.allocation_id in (select s.allocation_id from app_private.withdrawal_source_allocations s where s.withdrawal_id=any(v_withdrawals));
  select coalesce(array_agg(distinct q.job_id),array[]::uuid[]) into v_jobs
  from (select unnest(v_jobs) job_id
    union all select a.job_id from app_private.principal_allocations a where a.allocation_id=any(v_allocations)) q;
  select coalesce(array_agg(a.assignment_id) filter(where a.assignment_id is not null),array[]::uuid[])
    into v_assignments from app_private.assignments a where a.allocation_id=any(v_allocations);
  select coalesce(array_agg(j.journal_id),array[]::uuid[]) into v_journals
  from app_private.ledger_journal_transactions j
  where j.journal_id=v_ref and p_reference_type='journal'
     or j.effect_key=v_ref
     or j.reference_id=v_ref
     or j.effect_key in (select f.attempt_id from app_private.funding_attempts f where f.operation_id=any(v_ops))
     or j.reference_id=any(v_withdrawals) or j.reference_id=any(v_jobs)
     or j.reference_id=any(v_assignments) or j.reference_id=any(v_fundings);

  select pg_catalog.jsonb_build_object(
    'reference_type',p_reference_type,'reference',p_reference_value,
    'reconciliation',case when p_reference_type='reconciliation_run' then (
      select pg_catalog.jsonb_build_object(
        'run_id',r.run_id,'status',r.status,
        'simulator_cash_kobo',r.simulator_cash_kobo::text,
        'simulator_receivable_kobo',r.simulator_receivable_kobo::text,
        'finding_count',r.finding_count,'created_at',r.created_at
      ) from app_private.financial_reconciliation_runs r where r.run_id=v_ref
    ) else null end,
    'operations',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'operation_id',o.operation_id,'operation_type',o.operation_type,'status',o.status,
      'amount_kobo',o.amount_kobo::text,'fee_kobo',o.fee_kobo::text,'currency',o.currency,
      'provider_adapter',o.provider_adapter,'provider_reference',o.provider_operation_reference,
      'safe_error_code',o.safe_error_code,'created_at',o.created_at
    ) order by o.created_at,o.operation_id) from (
      select * from app_private.provider_operations where operation_id=any(v_ops)
      order by created_at,operation_id limit 20
    ) o),'[]'::jsonb),
    'payment_jobs',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'operation_id',j.operation_id,'state',j.state,'attempt_count',j.attempt_count,
      'max_attempts',j.max_attempts,'available_at',j.available_at,
      'lease_expires_at',j.lease_expires_at,'last_safe_error_code',j.last_safe_error_code
    ) order by j.created_at,j.job_id) from app_private.payment_operation_jobs j
      where j.operation_id=any(v_ops)),'[]'::jsonb),
    'funding',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'intent_id',f.intent_id,'job_id',f.job_id,'poster_id',f.poster_id,'status',f.status,
      'gross_total_kobo',f.gross_total_kobo::text,'currency',f.currency,
      'terms_version',f.terms_version,'created_at',f.created_at,
      'attempts',(select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'attempt_id',a.attempt_id,'status',a.status,'collected_gross_kobo',a.collected_gross_kobo::text,
        'provider_fee_kobo',a.provider_fee_kobo::text,'provider_net_kobo',a.provider_net_kobo::text,
        'settlement_status',a.settlement_status,
        'settlement',(select pg_catalog.jsonb_build_object('settlement_effect_id',s.settlement_effect_id,
          'journal_id',s.journal_id) from app_private.provider_settlement_records s where s.attempt_id=a.attempt_id)
      ) order by a.attempt_number),'[]'::jsonb) from (
        select * from app_private.funding_attempts where funding_intent_id=f.intent_id
        order by attempt_number limit 20
      ) a)
    ) order by f.created_at,f.intent_id) from app_private.funding_intents f where f.intent_id=any(v_fundings)),'[]'::jsonb),
    'withdrawals',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'withdrawal_id',w.withdrawal_id,'actor_id',w.actor_id,'status',w.status,
      'amount_kobo',w.amount_kobo::text,'destination_version',w.destination_version,
      'created_at',w.created_at,'updated_at',w.updated_at
    ) order by w.created_at,w.withdrawal_id) from app_private.withdrawal_requests w where w.withdrawal_id=any(v_withdrawals)),'[]'::jsonb),
    'jobs',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'job_id',j.job_id,'poster_id',j.poster_id,'listing_state',j.listing_state,
      'terms_version',j.current_terms_version,'created_at',j.created_at
    ) order by j.created_at,j.job_id) from app_private.jobs j where j.job_id=any(v_jobs)),'[]'::jsonb),
    'allocations',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'allocation_id',a.allocation_id,'job_id',a.job_id,'slot_number',a.slot_number,
      'gross_principal_kobo',a.gross_principal_kobo::text,'commission_basis_points',a.commission_basis_points,
      'status',a.status,'assignment_id',a.assignment_id,'worker_id',s.worker_id
    ) order by a.job_id,a.slot_number) from app_private.principal_allocations a
      left join app_private.assignments s on s.assignment_id=a.assignment_id where a.allocation_id=any(v_allocations)),'[]'::jsonb),
    'journals',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'journal_id',j.journal_id,'effect_type',j.effect_type,'effect_key',j.effect_key,
      'reference_id',j.reference_id,'created_at',j.created_at,
      'entries',(select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'account_code',a.account_code,'direction',e.direction,'amount_kobo',e.amount_kobo::text,
        'allocation_id',e.allocation_id,'owner_id',e.owner_id
      ) order by e.line_number),'[]'::jsonb) from app_private.ledger_journal_entries e
        join app_private.ledger_accounts a using(account_id) where e.journal_id=j.journal_id)
    ) order by j.created_at,j.journal_id) from (
      select * from app_private.ledger_journal_transactions where journal_id=any(v_journals)
      order by created_at,journal_id limit 20
    ) j),'[]'::jsonb),
    'exceptions',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'exception_id',e.exception_id,'exception_type',e.exception_type,
      'safe_reference',e.safe_reference,'created_at',e.created_at
    ) order by e.created_at,e.exception_id) from (
      select * from app_private.financial_exceptions
      where operation_id=any(v_ops) or funding_intent_id=any(v_fundings)
      order by created_at desc,exception_id desc limit 40
    ) e),'[]'::jsonb),
    'reconciliation_findings',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'run_id',f.run_id,'finding_code',f.finding_code,'expected_value',f.expected_value,
      'observed_value',f.observed_value,'safe_data',f.safe_data,'created_at',f.created_at
    ) order by f.created_at desc,f.finding_id desc) from (
      select f.* from app_private.financial_reconciliation_findings f
      where (p_reference_type='reconciliation_run' and f.run_id=v_ref)
         or f.reference_id=v_ref or f.reference_id=any(v_ops) or f.reference_id=any(v_fundings)
      order by f.created_at desc,f.finding_id desc limit 40
    ) f),'[]'::jsonb),
    'marketplace_outbox',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'event_id',m.event_id,'event_type',m.event_type,'created_at',m.created_at
    ) order by m.created_at,m.event_id) from (
      select * from app_private.marketplace_outbox where job_id=any(v_jobs)
      order by created_at desc,event_id desc limit 40
    ) m),'[]'::jsonb),
    'financial_outbox',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'event_id',z.event_id,'event_type',z.event_type,'delivery_state',z.delivery_state,
      'attempt_count',z.attempt_count,'created_at',z.created_at
    ) order by z.created_at,z.event_id) from (
      select o.event_id,o.event_type,o.delivery_state,o.attempt_count,e.created_at
      from app_private.financial_outbox o join app_private.financial_audit_events e using(event_id)
      where e.operation_id=any(v_ops) or e.reference_id=any(v_ops)
        or e.journal_id=any(v_journals) or e.reference_id=any(v_withdrawals)
        or e.reference_id=any(v_fundings) or e.reference_id=any(v_jobs)
        or e.reference_id=any(v_assignments)
        or (p_reference_type='reconciliation_run' and e.reference_id=v_ref)
      order by e.created_at desc,e.event_id desc limit 40
    ) z),'[]'::jsonb),
    'audit_events',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'event_id',z.event_id,'actor_id',z.actor_id,'event_type',z.event_type,
      'operation_id',z.operation_id,'journal_id',z.journal_id,'reference_id',z.reference_id,
      'event_data',pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
        'status',z.event_data->'status','previous_status',z.event_data->'previous_status',
        'amount_kobo',z.event_data->'amount_kobo','safe_error_code',z.event_data->'safe_error_code',
        'safe_reason',z.event_data->'safe_reason','action',z.event_data->'action',
        'destination_version',z.event_data->'destination_version','terms_version',z.event_data->'terms_version',
        'effect_type',z.event_data->'effect_type','entry_count',z.event_data->'entry_count',
        'result_source',z.event_data->'result_source')),
      'integrity_hash',pg_catalog.encode(z.event_hash,'hex'),'created_at',z.created_at
    ) order by z.created_at,z.event_id) from (
      select e.event_id,e.actor_id,e.event_type,e.operation_id,e.journal_id,e.reference_id,
        e.event_data,h.event_hash,e.created_at
      from app_private.financial_audit_events e join app_private.financial_audit_integrity h using(event_id)
      where e.operation_id=any(v_ops) or e.journal_id=any(v_journals)
        or e.reference_id=any(v_ops) or e.reference_id=any(v_withdrawals)
        or e.reference_id=any(v_fundings) or e.reference_id=any(v_jobs)
        or e.reference_id=any(v_assignments)
        or (p_reference_type='reconciliation_run' and e.reference_id=v_ref)
      order by e.created_at desc,e.event_id desc limit 40
    ) z),'[]'::jsonb),
    'audit_integrity_valid',app_private.financial_audit_integrity_valid()
  ) into v_result;

  insert into app_private.financial_audit_events(actor_id,event_type,reference_id,event_data)
  values(p_actor,'financial_inspection',v_ref,pg_catalog.jsonb_build_object(
    'reference_type',p_reference_type,'reference',p_reference_value,
    'result_sha256',pg_catalog.encode(extensions.digest(v_result::text,'sha256'),'hex')))
  returning event_id into v_audit;
  insert into app_private.financial_outbox(event_id,event_type,payload)
  values(v_audit,'financial.inspection',pg_catalog.jsonb_build_object(
    'event_id',v_audit,'reference_type',p_reference_type,'reference_id',v_ref));
  return v_result||pg_catalog.jsonb_build_object('inspection_event_id',v_audit);
end;
$function$;

create function app_private.reconcile_financial_state_for_actor(
  p_actor uuid,p_auth_aal text,p_simulator_cash_kobo text,p_simulator_receivable_kobo text
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_cash numeric;
  v_receivable numeric;
  v_run uuid:=pg_catalog.gen_random_uuid();
  v_findings jsonb:='[]'::jsonb;
  v_finding_count integer;
  v_integrity_valid boolean;
  v_audit uuid;
  v_row record;
  v_code text;
  v_expected numeric;
  v_observed numeric;
begin
  if not app_private.staff_actor_has_current_capability(p_actor,'financial_inspect',p_auth_aal) then
    raise exception using errcode='42501',message='financial_inspection_denied';
  end if;
  if p_simulator_cash_kobo is null or p_simulator_cash_kobo !~ '^(0|[1-9][0-9]{0,18})$'
     or p_simulator_receivable_kobo is null or p_simulator_receivable_kobo !~ '^(0|[1-9][0-9]{0,18})$'
     or p_simulator_cash_kobo::numeric>9223372036854775807
     or p_simulator_receivable_kobo::numeric>9223372036854775807 then
    raise exception using errcode='22023',message='invalid_simulator_snapshot';
  end if;
  v_cash:=p_simulator_cash_kobo::numeric;
  v_receivable:=p_simulator_receivable_kobo::numeric;

  for v_row in
    with derived as (
      select e.account_id,e.owner_id,e.allocation_id,
        sum(case e.direction when 'debit' then e.amount_kobo::numeric else -e.amount_kobo::numeric end) balance
      from app_private.ledger_journal_entries e group by e.account_id,e.owner_id,e.allocation_id
    )
    select coalesce(d.account_id,b.account_id) account_id,
      coalesce(d.owner_id,b.owner_id) owner_id,coalesce(d.allocation_id,b.allocation_id) allocation_id,
      coalesce(d.balance,0) expected,coalesce(b.balance_kobo,0)::numeric observed
    from derived d full join app_private.ledger_account_balances b
      on b.account_id=d.account_id and b.owner_id is not distinct from d.owner_id
      and b.allocation_id is not distinct from d.allocation_id
    where coalesce(d.balance,0)<>coalesce(b.balance_kobo,0)::numeric
  loop
    v_findings:=v_findings||pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'code','projection_balance_mismatch','reference_id',v_row.account_id,
      'expected',v_row.expected::text,'observed',v_row.observed::text,
      'data',pg_catalog.jsonb_build_object('owner_id',v_row.owner_id,'allocation_id',v_row.allocation_id)));
  end loop;

  select coalesce(sum(b.balance_kobo),0)::numeric into v_expected
  from app_private.ledger_account_balances b join app_private.ledger_accounts a using(account_id)
  where a.account_code in ('provider_available_cash','platform_fee_reserve_cash');
  if v_expected<>v_cash then
    v_findings:=v_findings||pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'code','simulator_cash_mismatch','reference_id',null,'expected',v_expected::text,
      'observed',v_cash::text,'data','{}'::jsonb));
  end if;
  select coalesce(sum(b.balance_kobo),0)::numeric into v_expected
  from app_private.ledger_account_balances b join app_private.ledger_accounts a using(account_id)
  where a.account_code='provider_collection_receivable';
  if v_expected<>v_receivable then
    v_findings:=v_findings||pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'code','simulator_receivable_mismatch','reference_id',null,'expected',v_expected::text,
      'observed',v_receivable::text,'data','{}'::jsonb));
  end if;

  for v_row in
    select a.account_code,
      case a.account_code
        when 'job_principal_unassigned' then -coalesce(sum(p.gross_principal_kobo) filter(where p.status='unassigned'),0)::numeric
        when 'job_principal_assigned' then -coalesce(sum(p.gross_principal_kobo) filter(where p.status='assigned'),0)::numeric
        else -coalesce(sum(p.gross_principal_kobo) filter(where p.status='dispute_held'),0)::numeric
      end expected,
      coalesce((select sum(b.balance_kobo)::numeric from app_private.ledger_account_balances b
        where b.account_id=a.account_id),0)::numeric observed
    from app_private.ledger_accounts a
    left join app_private.principal_allocations p on true
    where a.account_code in ('job_principal_unassigned','job_principal_assigned','job_principal_dispute_held')
    group by a.account_code,a.account_id
  loop
    if v_row.expected<>v_row.observed then
      v_findings:=v_findings||pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
        'code','held_liability_mismatch','reference_id',null,'expected',v_row.expected::text,
        'observed',v_row.observed::text,'data',pg_catalog.jsonb_build_object('account_code',v_row.account_code)));
    end if;
  end loop;

  for v_row in
    select o.operation_id,o.status,o.operation_type,o.safe_error_code
    from app_private.provider_operations o
    where o.status in ('pending','processing','unknown','exception','queued_for_liquidity')
    order by o.created_at,o.operation_id limit 100
  loop
    v_findings:=v_findings||pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'code','unresolved_operation','reference_id',v_row.operation_id,
      'expected','authoritative_terminal_result','observed',v_row.status,
      'data',pg_catalog.jsonb_build_object('operation_type',v_row.operation_type,'safe_error_code',v_row.safe_error_code)));
  end loop;

  v_integrity_valid:=app_private.financial_audit_integrity_valid();
  if not v_integrity_valid then
    v_findings:=v_findings||pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'code','audit_chain_mismatch','reference_id',null,'expected','valid','observed','invalid','data','{}'::jsonb));
  end if;

  v_finding_count:=pg_catalog.jsonb_array_length(v_findings);
  insert into app_private.financial_audit_events(actor_id,event_type,reference_id,event_data)
  values(p_actor,'financial_reconciliation_completed',v_run,pg_catalog.jsonb_build_object(
    'status',case when v_finding_count=0 then 'balanced' else 'mismatch' end,
    'finding_count',v_finding_count,'simulator_cash_kobo',v_cash::text,
    'simulator_receivable_kobo',v_receivable::text,'audit_chain_valid_before_run',v_integrity_valid))
  returning event_id into v_audit;
  insert into app_private.financial_outbox(event_id,event_type,payload)
  values(v_audit,'financial.reconciliation_completed',pg_catalog.jsonb_build_object(
    'event_id',v_audit,'run_id',v_run,'finding_count',v_finding_count));
  insert into app_private.financial_reconciliation_runs(
    run_id,actor_id,audit_event_id,status,simulator_cash_kobo,simulator_receivable_kobo,
    finding_count,result_sha256
  ) values(v_run,p_actor,v_audit,case when v_finding_count=0 then 'balanced' else 'mismatch' end,
    v_cash::bigint,v_receivable::bigint,v_finding_count,
    extensions.digest(pg_catalog.convert_to(v_findings::text,'UTF8'),'sha256'));
  insert into app_private.financial_reconciliation_findings(
    run_id,finding_code,reference_id,expected_value,observed_value,safe_data
  ) select v_run,x->>'code',nullif(x->>'reference_id','')::uuid,
      x->>'expected',x->>'observed',coalesce(x->'data','{}'::jsonb)
    from pg_catalog.jsonb_array_elements(v_findings) x;
  return pg_catalog.jsonb_build_object(
    'run_id',v_run,'status',case when v_finding_count=0 then 'balanced' else 'mismatch' end,
    'finding_count',v_finding_count,'findings',v_findings,'audit_chain_valid',v_integrity_valid,
    'money_movement_authorized',false,'signed_checkpoint_proven',false
  );
end;
$function$;

create function public.server_list_my_notifications_for_actor(
  p_actor uuid,p_before_created_at timestamptz default null,p_before_id uuid default null
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.list_my_notifications_for_actor($1,$2,$3)
$function$;
create function public.server_mark_my_notification_read_for_actor(
  p_actor uuid,p_notification_id uuid
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.mark_my_notification_read_for_actor($1,$2)
$function$;
create function public.server_inspect_financial_reference_for_actor(
  p_actor uuid,p_auth_aal text,p_reference_type text,p_reference_value text
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.inspect_financial_reference_for_actor($1,$2,$3,$4)
$function$;
create function public.server_reconcile_financial_state_for_actor(
  p_actor uuid,p_auth_aal text,p_simulator_cash_kobo text,p_simulator_receivable_kobo text
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.reconcile_financial_state_for_actor($1,$2,$3,$4)
$function$;

revoke all on table app_private.in_app_notifications,app_private.financial_audit_integrity,
  app_private.financial_reconciliation_runs,app_private.financial_reconciliation_findings
from public,anon,authenticated,service_role;
revoke all on function app_private.guard_in_app_notification_change(),
  app_private.add_in_app_notification(uuid,uuid,text),app_private.add_financial_in_app_notification(uuid,uuid,text),
  app_private.list_my_notifications_for_actor(uuid,timestamptz,uuid),
  app_private.mark_my_notification_read_for_actor(uuid,uuid),
  app_private.financial_audit_event_hash(uuid,uuid,text,uuid,uuid,uuid,jsonb,timestamptz,bytea),
  app_private.append_financial_audit_integrity(),app_private.financial_audit_integrity_valid(),
  app_private.audit_financial_authorization_created(),app_private.audit_provider_operation_change(),
  app_private.audit_wallet_event(uuid,text,uuid,jsonb),
  app_private.inspect_financial_reference_for_actor(uuid,text,text,text),
  app_private.reconcile_financial_state_for_actor(uuid,text,text,text)
from public,anon,authenticated,service_role;
revoke all on function public.server_list_my_notifications_for_actor(uuid,timestamptz,uuid),
  public.server_mark_my_notification_read_for_actor(uuid,uuid),
  public.server_inspect_financial_reference_for_actor(uuid,text,text,text),
  public.server_reconcile_financial_state_for_actor(uuid,text,text,text)
from public,anon,authenticated,service_role;
grant execute on function public.server_list_my_notifications_for_actor(uuid,timestamptz,uuid),
  public.server_mark_my_notification_read_for_actor(uuid,uuid),
  public.server_inspect_financial_reference_for_actor(uuid,text,text,text),
  public.server_reconcile_financial_state_for_actor(uuid,text,text,text)
to service_role;

commit;
