begin;

-- Step 3 adds voluntary cancellation and a current allocation binding history.
-- Assignment and application rows remain durable historical facts.
alter table app_private.assignments
  drop constraint assignments_allocation_id_key;
alter table app_private.principal_allocations
  drop constraint principal_allocations_status_check,
  drop constraint principal_allocations_check,
  drop constraint principal_allocations_assignment_id_key,
  add constraint principal_allocations_status_check check (status in (
    'unassigned','assigned','dispute_held','worker_earnings_allocated','refund_payable'
  )),
  add constraint principal_allocations_assignment_id_key unique (assignment_id),
  add constraint principal_allocations_binding_state_check check (
    (status in ('unassigned','refund_payable') and assignment_id is null) or
    (status in ('assigned','dispute_held','worker_earnings_allocated') and assignment_id is not null)
  );

create table app_private.allocation_assignment_bindings (
  assignment_id uuid primary key references app_private.assignments(assignment_id) on delete restrict,
  allocation_id uuid not null references app_private.principal_allocations(allocation_id) on delete restrict,
  bound_by uuid not null references auth.users(id) on delete restrict,
  bound_at timestamptz not null default pg_catalog.now(),
  unbound_by uuid references auth.users(id) on delete restrict,
  unbound_at timestamptz,
  unbound_reason text check (unbound_reason is null or unbound_reason in (
    'worker_abandonment','mutual_prestart_cancellation'
  )),
  check ((unbound_at is null and unbound_by is null and unbound_reason is null) or
    (unbound_at is not null and unbound_by is not null and unbound_reason is not null))
);
create unique index allocation_assignment_bindings_one_current
  on app_private.allocation_assignment_bindings(allocation_id) where unbound_at is null;
create index allocation_assignment_bindings_allocation_history
  on app_private.allocation_assignment_bindings(allocation_id,bound_at,assignment_id);
insert into app_private.allocation_assignment_bindings(assignment_id,allocation_id,bound_by,bound_at)
select s.assignment_id,s.allocation_id,s.poster_id,s.created_at
from app_private.assignments s;

create function app_private.guard_allocation_assignment_binding()
returns trigger language plpgsql set search_path = '' as $function$
declare v_reason text;
begin
  if tg_op='DELETE' then
    raise exception using errcode='55000',message='allocation_assignment_history_is_immutable';
  end if;
  if tg_op='INSERT' then
    if new.unbound_at is not null or new.unbound_by is not null or new.unbound_reason is not null then
      raise exception using errcode='55000',message='invalid_allocation_assignment_binding';
    end if;
    return new;
  end if;
  v_reason:=pg_catalog.current_setting('app.assignment_unbind_reason',true);
  if new.assignment_id is distinct from old.assignment_id
     or new.allocation_id is distinct from old.allocation_id
     or new.bound_by is distinct from old.bound_by
     or new.bound_at is distinct from old.bound_at
     or old.unbound_at is not null
     or new.unbound_at is null or new.unbound_by is null
     or coalesce(v_reason,'') not in ('worker_abandonment','mutual_prestart_cancellation')
     or new.unbound_reason is distinct from v_reason then
    raise exception using errcode='55000',message='allocation_assignment_history_is_immutable';
  end if;
  return new;
end;
$function$;
create trigger allocation_assignment_bindings_guard
before update or delete on app_private.allocation_assignment_bindings
for each row execute function app_private.guard_allocation_assignment_binding();

create function app_private.record_allocation_assignment_binding()
returns trigger language plpgsql security definer set search_path = '' as $function$
declare
  v_actor uuid;
  v_reason text;
begin
  if old.assignment_id is null and new.assignment_id is not null then
    v_actor:=nullif(pg_catalog.current_setting('app.allocation_actor',true),'')::uuid;
    insert into app_private.allocation_assignment_bindings(assignment_id,allocation_id,bound_by)
    values(new.assignment_id,new.allocation_id,coalesce(v_actor,new.poster_id));
  elsif old.assignment_id is not null and new.assignment_id is null then
    v_actor:=nullif(pg_catalog.current_setting('app.allocation_actor',true),'')::uuid;
    v_reason:=pg_catalog.current_setting('app.assignment_unbind_reason',true);
    if coalesce(v_reason,'') not in ('worker_abandonment','mutual_prestart_cancellation') or v_actor is null then
      raise exception using errcode='55000',message='allocation_assignment_history_is_immutable';
    end if;
    update app_private.allocation_assignment_bindings
    set unbound_at=pg_catalog.now(),unbound_by=v_actor,unbound_reason=v_reason
    where assignment_id=old.assignment_id and allocation_id=old.allocation_id and unbound_at is null;
    if not found then
      raise exception using errcode='55000',message='allocation_assignment_history_is_immutable';
    end if;
  end if;
  return new;
end;
$function$;
create trigger principal_allocations_assignment_binding_history
after update of assignment_id on app_private.principal_allocations
for each row when (old.assignment_id is distinct from new.assignment_id)
execute function app_private.record_allocation_assignment_binding();

create table app_private.assignment_cancellation_rounds (
  cancellation_id uuid primary key default pg_catalog.gen_random_uuid(),
  assignment_id uuid not null unique references app_private.assignments(assignment_id) on delete restrict,
  allocation_id uuid not null references app_private.principal_allocations(allocation_id) on delete restrict,
  job_id uuid not null references app_private.jobs(job_id) on delete restrict,
  terms_version integer not null check (terms_version>0),
  terms_sha256 bytea not null check (pg_catalog.octet_length(terms_sha256)=32),
  gross_principal_kobo bigint not null check (gross_principal_kobo>0),
  cancellation_version integer not null default 1 check (cancellation_version=1),
  requested_by uuid not null references auth.users(id) on delete restrict,
  request_reason text not null check (char_length(request_reason) between 1 and 500),
  created_at timestamptz not null default pg_catalog.now(),
  foreign key(job_id,terms_version,terms_sha256,gross_principal_kobo)
    references app_private.job_terms_versions(job_id,terms_version,terms_sha256,gross_per_worker_kobo) on delete restrict
);
create table app_private.assignment_cancellation_consents (
  consent_id uuid primary key default pg_catalog.gen_random_uuid(),
  cancellation_id uuid not null references app_private.assignment_cancellation_rounds(cancellation_id) on delete restrict,
  assignment_id uuid not null references app_private.assignments(assignment_id) on delete restrict,
  actor_id uuid not null references auth.users(id) on delete restrict,
  consent_reason text not null check (char_length(consent_reason) between 1 and 500),
  cancellation_version integer not null check (cancellation_version=1),
  consented_at timestamptz not null default pg_catalog.now(),
  unique(cancellation_id,actor_id),
  unique(cancellation_id,assignment_id,actor_id)
);
create table app_private.allocation_refund_payables (
  refund_payable_id uuid primary key default pg_catalog.gen_random_uuid(),
  allocation_id uuid not null unique references app_private.principal_allocations(allocation_id) on delete restrict,
  poster_id uuid not null references auth.users(id) on delete restrict,
  amount_kobo bigint not null check (amount_kobo>0),
  source text not null check (source in ('unassigned_slot','mutual_prestart')),
  source_assignment_id uuid references app_private.assignments(assignment_id) on delete restrict,
  cancellation_id uuid unique references app_private.assignment_cancellation_rounds(cancellation_id) on delete restrict,
  reason text not null check (char_length(reason) between 1 and 500),
  status text not null default 'authorized' check (status='authorized'),
  authorized_by uuid not null references auth.users(id) on delete restrict,
  idempotency_key uuid not null,
  created_at timestamptz not null default pg_catalog.now(),
  check ((source='unassigned_slot' and source_assignment_id is null and cancellation_id is null) or
    (source='mutual_prestart' and source_assignment_id is not null and cancellation_id is not null))
);
create index allocation_refund_payables_poster_idx
  on app_private.allocation_refund_payables(poster_id,created_at desc,refund_payable_id desc);

create table app_private.assignment_cancellation_finalizations (
  cancellation_id uuid primary key references app_private.assignment_cancellation_rounds(cancellation_id) on delete restrict,
  assignment_id uuid not null unique references app_private.assignments(assignment_id) on delete restrict,
  refund_payable_id uuid not null unique references app_private.allocation_refund_payables(refund_payable_id) on delete restrict,
  journal_id uuid not null unique references app_private.ledger_journal_transactions(journal_id) on delete restrict,
  finalized_by uuid not null references auth.users(id) on delete restrict,
  finalized_at timestamptz not null default pg_catalog.now()
);

create table app_private.assignment_cancellation_audit (
  audit_id uuid primary key default pg_catalog.gen_random_uuid(),
  actor_id uuid not null references auth.users(id) on delete restrict,
  action text not null check (action in (
    'unassigned_slot_refund_authorized','cancellation_requested','cancellation_consented',
    'mutual_cancellation_finalized','worker_prestart_abandoned'
  )),
  assignment_id uuid references app_private.assignments(assignment_id) on delete restrict,
  allocation_id uuid references app_private.principal_allocations(allocation_id) on delete restrict,
  cancellation_id uuid references app_private.assignment_cancellation_rounds(cancellation_id) on delete restrict,
  reason text not null check (char_length(reason) between 1 and 500),
  created_at timestamptz not null default pg_catalog.now()
);

create table app_private.assignment_cancellation_command_idempotency (
  actor_id uuid not null references auth.users(id) on delete restrict,
  command_name text not null check (command_name in (
    'cancel_unassigned_slots','request_prestart_cancellation',
    'consent_prestart_cancellation','abandon_prestart_assignment'
  )),
  idempotency_key uuid not null,
  request_sha256 bytea not null check (pg_catalog.octet_length(request_sha256)=32),
  response jsonb not null check (pg_catalog.jsonb_typeof(response)='object'),
  created_at timestamptz not null default pg_catalog.now(),
  primary key(actor_id,command_name,idempotency_key)
);

create function app_private.reject_cancellation_record_mutation()
returns trigger language plpgsql set search_path = '' as $function$
begin
  raise exception using errcode='55000',message='cancellation_record_is_immutable';
end;
$function$;
create trigger assignment_cancellation_rounds_immutable before update or delete
on app_private.assignment_cancellation_rounds for each row
execute function app_private.reject_cancellation_record_mutation();
create trigger assignment_cancellation_consents_immutable before update or delete
on app_private.assignment_cancellation_consents for each row
execute function app_private.reject_cancellation_record_mutation();
create trigger allocation_refund_payables_immutable before update or delete
on app_private.allocation_refund_payables for each row
execute function app_private.reject_cancellation_record_mutation();
create trigger assignment_cancellation_finalizations_immutable before update or delete
on app_private.assignment_cancellation_finalizations for each row
execute function app_private.reject_cancellation_record_mutation();
create trigger assignment_cancellation_audit_immutable before update or delete
on app_private.assignment_cancellation_audit for each row
execute function app_private.reject_cancellation_record_mutation();

alter table app_private.marketplace_outbox drop constraint marketplace_outbox_event_type_check;
alter table app_private.marketplace_outbox add constraint marketplace_outbox_event_type_check check (event_type in (
  'job.draft_created','job.draft_updated','job.funding_started','job.funded',
  'job.funding_failed','job.funding_exception','job.application_created',
  'job.application_accepted','job.application_rejected','job.application_withdrawn',
  'job.application_closed','job.message_created','job.assignment_started',
  'job.assignment_submitted','job.assignment_completed','job.assignment_hold_opened',
  'job.slot_refund_authorized','job.assignment_cancellation_requested',
  'job.assignment_cancellation_completed','job.assignment_abandoned',
  'job.assignment_case_reviewer_assigned'
));
alter table app_private.in_app_notifications drop constraint in_app_notifications_notification_type_check;
alter table app_private.in_app_notifications add constraint in_app_notifications_notification_type_check check (notification_type in (
  'application_received','application_accepted','application_rejected',
  'application_withdrawn','application_closed','new_message',
  'assignment_started','assignment_submitted','assignment_completed',
  'assignment_hold_opened','assignment_case_updated','withdrawal_requested',
  'withdrawal_processing','withdrawal_unknown','withdrawal_paid','withdrawal_failed',
  'withdrawal_reversed','withdrawal_exception',
  'slot_refund_authorized','assignment_cancellation_requested',
  'assignment_cancellation_completed','assignment_abandoned'
));

alter table app_private.ledger_journal_transactions
  drop constraint ledger_journal_transactions_effect_type_check,
  add constraint ledger_journal_transactions_effect_type_check check (effect_type in (
    'funding_collected','provider_settlement','allocation_assigned','allocation_held',
    'completion_released','withdrawal_reserved','payout_settled','platform_fee_reserve_transfer',
    'provider_refund_settled','compensating_correction','platform_capital_contribution',
    'allocation_reopened','allocation_refund_authorized'
  ));
create or replace function app_private.post_financial_journal(
  p_effect_key uuid,p_effect_type text,p_reference_id uuid,p_actor_id uuid,p_entries jsonb
) returns uuid language plpgsql security definer set search_path = '' as $function$
declare
  v_fingerprint bytea;
  v_existing app_private.ledger_journal_transactions%rowtype;
  v_journal_id uuid;
  v_event_id uuid;
  v_line record;
  v_item jsonb;
  v_account app_private.ledger_accounts%rowtype;
  v_allocation_id uuid;
  v_owner_id uuid;
  v_amount numeric;
  v_debits numeric:=0;
  v_credits numeric:=0;
  v_balance bigint;
  v_event_data jsonb;
begin
  if p_effect_key is null or p_effect_type not in (
    'funding_collected','provider_settlement','allocation_assigned','allocation_held',
    'completion_released','withdrawal_reserved','payout_settled','platform_fee_reserve_transfer',
    'provider_refund_settled','compensating_correction','platform_capital_contribution',
    'allocation_reopened','allocation_refund_authorized'
  ) or p_entries is null or pg_catalog.jsonb_typeof(p_entries)<>'array' then
    raise exception using errcode='22023',message='invalid_journal_entry';
  end if;
  if pg_catalog.jsonb_array_length(p_entries) not between 2 and 100 then
    raise exception using errcode='22023',message='invalid_journal_entry';
  end if;
  if p_actor_id is not null and not exists(select 1 from auth.users where id=p_actor_id) then
    raise exception using errcode='22023',message='invalid_journal_entry';
  end if;
  for v_item in select value from pg_catalog.jsonb_array_elements(p_entries) loop
    if pg_catalog.jsonb_typeof(v_item)<>'object'
       or exists(select 1 from pg_catalog.jsonb_object_keys(v_item) as keys(key)
         where key not in ('account_code','direction','amount_kobo','allocation_id','owner_id'))
       or pg_catalog.jsonb_typeof(v_item->'account_code')<>'string'
       or pg_catalog.jsonb_typeof(v_item->'direction')<>'string'
       or pg_catalog.jsonb_typeof(v_item->'amount_kobo')<>'string'
       or (v_item->>'amount_kobo') !~ '^[1-9][0-9]{0,18}$'
       or v_item->>'direction' not in ('debit','credit') then
      raise exception using errcode='22023',message='invalid_journal_entry';
    end if;
    v_amount:=(v_item->>'amount_kobo')::numeric;
    if v_amount>9223372036854775807 then
      raise exception using errcode='22023',message='invalid_journal_entry';
    end if;
    select * into v_account from app_private.ledger_accounts where account_code=v_item->>'account_code';
    if not found then raise exception using errcode='22023',message='invalid_journal_entry'; end if;
    if v_item ? 'allocation_id' and pg_catalog.jsonb_typeof(v_item->'allocation_id') not in ('string','null') then
      raise exception using errcode='22023',message='invalid_journal_entry';
    end if;
    if v_item ? 'owner_id' and pg_catalog.jsonb_typeof(v_item->'owner_id') not in ('string','null') then
      raise exception using errcode='22023',message='invalid_journal_entry';
    end if;
    if nullif(v_item->>'allocation_id','') is not null and (v_item->>'allocation_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception using errcode='22023',message='invalid_journal_entry';
    end if;
    if nullif(v_item->>'owner_id','') is not null and (v_item->>'owner_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception using errcode='22023',message='invalid_journal_entry';
    end if;
    v_allocation_id:=nullif(v_item->>'allocation_id','')::uuid;
    v_owner_id:=nullif(v_item->>'owner_id','')::uuid;
    if (v_account.dimension_scope='none' and (v_allocation_id is not null or v_owner_id is not null))
       or (v_account.dimension_scope='allocation' and (v_allocation_id is null or v_owner_id is not null))
       or (v_account.dimension_scope='allocation_owner' and (v_allocation_id is null or v_owner_id is null)) then
      raise exception using errcode='22023',message='invalid_journal_entry';
    end if;
    if v_item->>'direction'='debit' then v_debits:=v_debits+v_amount; else v_credits:=v_credits+v_amount; end if;
  end loop;
  if v_debits=0 or v_debits<>v_credits then
    raise exception using errcode='22023',message='unbalanced_journal';
  end if;
  v_fingerprint:=extensions.digest(pg_catalog.convert_to(pg_catalog.jsonb_build_object(
    'effect_type',p_effect_type,'reference_id',p_reference_id,'actor_id',p_actor_id,'entries',p_entries
  )::text,'UTF8'),'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('financial-effect:'||p_effect_key::text,808021));
  select * into v_existing from app_private.ledger_journal_transactions where effect_key=p_effect_key;
  if found then
    if v_existing.request_sha256<>v_fingerprint then
      raise exception using errcode='23505',message='idempotency_conflict';
    end if;
    return v_existing.journal_id;
  end if;
  insert into app_private.ledger_journal_transactions(effect_key,effect_type,reference_id,actor_id,request_sha256,entry_count)
  values(p_effect_key,p_effect_type,p_reference_id,p_actor_id,v_fingerprint,pg_catalog.jsonb_array_length(p_entries))
  returning journal_id into v_journal_id;
  for v_line in select value,ordinality::smallint as line_number from pg_catalog.jsonb_array_elements(p_entries) with ordinality loop
    v_item:=v_line.value;
    select * into v_account from app_private.ledger_accounts where account_code=v_item->>'account_code';
    v_amount:=(v_item->>'amount_kobo')::numeric;
    v_allocation_id:=nullif(v_item->>'allocation_id','')::uuid;
    v_owner_id:=nullif(v_item->>'owner_id','')::uuid;
    insert into app_private.ledger_journal_entries(journal_id,line_number,account_id,direction,amount_kobo,allocation_id,owner_id)
    values(v_journal_id,v_line.line_number,v_account.account_id,v_item->>'direction',v_amount::bigint,v_allocation_id,v_owner_id);
    insert into app_private.ledger_account_balances(account_id,owner_id,allocation_id,debit_kobo,credit_kobo)
    values(v_account.account_id,v_owner_id,v_allocation_id,
      case when v_item->>'direction'='debit' then v_amount::bigint else 0 end,
      case when v_item->>'direction'='credit' then v_amount::bigint else 0 end)
    on conflict (account_id,owner_id,allocation_id) do update set
      debit_kobo=app_private.ledger_account_balances.debit_kobo+excluded.debit_kobo,
      credit_kobo=app_private.ledger_account_balances.credit_kobo+excluded.credit_kobo,
      updated_at=pg_catalog.now()
    returning balance_kobo into v_balance;
    if (v_account.normal_side='debit' and v_balance<0)
       or (v_account.normal_side='credit' and v_balance>0) then
      raise exception using errcode='22023',message='account_balance_would_be_negative';
    end if;
  end loop;
  v_event_data:=pg_catalog.jsonb_build_object('journal_id',v_journal_id,'effect_type',p_effect_type,
    'reference_id',p_reference_id,'entry_count',pg_catalog.jsonb_array_length(p_entries));
  insert into app_private.financial_audit_events(actor_id,event_type,journal_id,reference_id,event_data)
  values(p_actor_id,'financial_journal_posted',v_journal_id,p_reference_id,v_event_data)
  returning event_id into v_event_id;
  insert into app_private.financial_outbox(event_id,event_type,payload)
  values(v_event_id,'financial.journal_posted',pg_catalog.jsonb_build_object(
    'event_id',v_event_id,'journal_id',v_journal_id,'effect_type',p_effect_type));
  return v_journal_id;
end;
$function$;
revoke all on function app_private.post_financial_journal(uuid,text,uuid,uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function app_private.post_financial_journal(uuid,text,uuid,uuid,jsonb) to postgres;

create or replace function app_private.guard_allocation_change()
returns trigger language plpgsql security definer set search_path = '' as $function$
declare
  v_intent app_private.funding_intents%rowtype;
  v_transition text;
begin
  if tg_op='INSERT' then
    select * into v_intent from app_private.funding_intents where intent_id=new.funding_intent_id for key share;
    if not found or v_intent.status not in ('pending','unknown') or new.job_id<>v_intent.job_id
       or new.poster_id<>v_intent.poster_id or new.gross_principal_kobo<>v_intent.gross_per_worker_kobo
       or new.slot_number>v_intent.slot_count or new.status<>'unassigned' or new.assignment_id is not null
       or new.commission_basis_points<>500 or not exists(select 1 from app_private.funding_attempts a
         where a.funding_intent_id=v_intent.intent_id and a.status='succeeded'
           and a.collected_gross_kobo=v_intent.gross_total_kobo and a.currency=v_intent.currency) then
      raise exception using errcode='22023',message='invalid_principal_allocation';
    end if;
    return new;
  end if;
  if tg_op='DELETE' then
    raise exception using errcode='55000',message='principal_allocation_is_immutable';
  end if;
  v_transition:=pg_catalog.current_setting('app.allocation_transition',true);
  if new.allocation_id is distinct from old.allocation_id
     or new.funding_intent_id is distinct from old.funding_intent_id
     or new.job_id is distinct from old.job_id or new.poster_id is distinct from old.poster_id
     or new.slot_number is distinct from old.slot_number
     or new.gross_principal_kobo is distinct from old.gross_principal_kobo
     or new.commission_basis_points is distinct from old.commission_basis_points
     or new.created_at is distinct from old.created_at
     or not (
       (old.status='unassigned' and new.status='assigned' and old.assignment_id is null and new.assignment_id is not null) or
       (old.status='assigned' and new.status in ('dispute_held','worker_earnings_allocated') and new.assignment_id=old.assignment_id) or
       (old.status='assigned' and new.status='unassigned' and old.assignment_id is not null and new.assignment_id is null and coalesce(v_transition,'')='worker_abandonment') or
       (old.status='assigned' and new.status='refund_payable' and old.assignment_id is not null and new.assignment_id is null and coalesce(v_transition,'')='mutual_prestart_cancellation') or
       (old.status='unassigned' and new.status='refund_payable' and old.assignment_id is null and new.assignment_id is null and coalesce(v_transition,'')='poster_unassigned_cancellation')
     ) then
    raise exception using errcode='55000',message='principal_allocation_is_immutable';
  end if;
  new.updated_at:=pg_catalog.now();
  return new;
end;
$function$;

drop function app_private.post_allocation_status_journal(uuid,text,text);
create function app_private.post_allocation_status_journal(
  p_allocation_id uuid,p_from_status text,p_to_status text,
  p_old_assignment_id uuid default null,p_new_assignment_id uuid default null
) returns uuid language plpgsql security definer set search_path = '' as $function$
declare
  v_allocation app_private.principal_allocations%rowtype;
  v_actor uuid;
  v_effect_type text;
  v_debit_account text;
  v_credit_account text;
  v_reference uuid;
  v_effect_label text;
  v_payable app_private.allocation_refund_payables%rowtype;
  v_case_id uuid;
  v_count integer;
begin
  if not ((p_from_status='unassigned' and p_to_status in ('assigned','refund_payable')) or
          (p_from_status='assigned' and p_to_status in ('dispute_held','unassigned','refund_payable'))) then
    raise exception using errcode='22023',message='invalid_allocation_transition';
  end if;
  select * into v_allocation from app_private.principal_allocations where allocation_id=p_allocation_id;
  if not found then raise exception using errcode='22023',message='invalid_allocation_transition'; end if;
  v_actor:=nullif(pg_catalog.current_setting('app.allocation_actor',true),'')::uuid;
  v_actor:=coalesce(v_actor,v_allocation.poster_id);
  v_reference:=coalesce(p_old_assignment_id,p_new_assignment_id,p_allocation_id);
  if p_to_status='assigned' then
    select count(*)::integer into v_count from app_private.assignments where allocation_id=p_allocation_id;
    v_effect_type:='allocation_assigned';
    v_effect_label:='nbd:allocation_assigned:'||p_allocation_id::text||
      case when v_count<=1 then '' else ':'||p_new_assignment_id::text end;
    v_debit_account:='job_principal_unassigned';v_credit_account:='job_principal_assigned';
    v_reference:=p_allocation_id;
  elsif p_to_status='dispute_held' then
    select c.case_id into v_case_id from app_private.assignment_cases c
    where c.allocation_id=p_allocation_id and c.lifecycle_status<>'closed'
    order by c.opened_at desc limit 1;
    v_effect_type:='allocation_held';
    if exists(select 1 from app_private.ledger_journal_transactions j where j.effect_key=
      app_private.stable_financial_effect_key('nbd:allocation_held:'||p_allocation_id::text)) then
      v_effect_label:='nbd:allocation_held:'||p_allocation_id::text||':'||coalesce(v_case_id::text,'legacy');
    else
      v_effect_label:='nbd:allocation_held:'||p_allocation_id::text;
    end if;
    v_debit_account:='job_principal_assigned';v_credit_account:='job_principal_dispute_held';
    v_reference:=coalesce(v_case_id,p_allocation_id);
  elsif p_to_status='unassigned' then
    v_effect_type:='allocation_reopened';
    v_effect_label:='nbd:allocation_reopened:'||p_allocation_id::text||':'||p_old_assignment_id::text;
    v_debit_account:='job_principal_assigned';v_credit_account:='job_principal_unassigned';
    v_reference:=p_old_assignment_id;
  else
    select * into v_payable from app_private.allocation_refund_payables
    where allocation_id=p_allocation_id and status='authorized';
    if not found or v_payable.amount_kobo<>v_allocation.gross_principal_kobo then
      raise exception using errcode='22023',message='invalid_allocation_refund_payable';
    end if;
    v_effect_type:='allocation_refund_authorized';
    v_effect_label:='nbd:allocation_refund_authorized:'||p_allocation_id::text;
    v_debit_account:=case when p_from_status='unassigned' then 'job_principal_unassigned' else 'job_principal_assigned' end;
    v_credit_account:='poster_refund_payable';
    v_reference:=v_payable.refund_payable_id;
  end if;
  return app_private.post_financial_journal(
    app_private.stable_financial_effect_key(v_effect_label),v_effect_type,v_reference,v_actor,
    pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('account_code',v_debit_account,'direction','debit',
        'amount_kobo',v_allocation.gross_principal_kobo::text,'allocation_id',p_allocation_id::text),
      pg_catalog.jsonb_build_object('account_code',v_credit_account,'direction','credit',
        'amount_kobo',v_allocation.gross_principal_kobo::text,'allocation_id',p_allocation_id::text,
        'owner_id',case when v_credit_account='poster_refund_payable' then v_allocation.poster_id::text else null end)
    ));
end;
$function$;
create or replace function app_private.journal_allocation_status_transition()
returns trigger language plpgsql security definer set search_path = '' as $function$
begin
  perform app_private.post_allocation_status_journal(
    new.allocation_id,old.status,new.status,old.assignment_id,new.assignment_id);
  return new;
end;
$function$;
drop trigger principal_allocations_accounting_transition on app_private.principal_allocations;
create trigger principal_allocations_accounting_transition
after update of status on app_private.principal_allocations
for each row when (old.status is distinct from new.status and
  ((old.status='unassigned' and new.status in ('assigned','refund_payable')) or
   (old.status='assigned' and new.status in ('dispute_held','unassigned','refund_payable'))))
execute function app_private.journal_allocation_status_transition();

create or replace function app_private.reject_assignment_mutation()
returns trigger language plpgsql set search_path = '' as $function$
declare v_transition text;
begin
  if tg_op='DELETE' then raise exception using errcode='55000',message='assignment_record_is_immutable'; end if;
  v_transition:=pg_catalog.current_setting('app.assignment_cancellation_transition',true);
  if new.assignment_id is distinct from old.assignment_id
     or new.application_id is distinct from old.application_id
     or new.job_id is distinct from old.job_id or new.worker_id is distinct from old.worker_id
     or new.poster_id is distinct from old.poster_id or new.allocation_id is distinct from old.allocation_id
     or new.funding_intent_id is distinct from old.funding_intent_id
     or new.terms_version is distinct from old.terms_version
     or new.terms_sha256 is distinct from old.terms_sha256
     or new.gross_principal_kobo is distinct from old.gross_principal_kobo
     or new.commission_basis_points is distinct from old.commission_basis_points
     or new.created_at is distinct from old.created_at
     or not (
       (old.work_state='assigned' and new.work_state='in_progress' and old.started_at is null
         and new.started_at is not null and new.submitted_at is null and new.completed_at is null) or
       (old.work_state='in_progress' and new.work_state='submitted' and new.started_at=old.started_at
         and old.submitted_at is null and new.submitted_at is not null and new.completed_at is null) or
       (old.work_state='submitted' and new.work_state='completed' and new.started_at=old.started_at
         and new.submitted_at=old.submitted_at and old.completed_at is null and new.completed_at is not null) or
       (old.work_state='assigned' and new.work_state='cancelled' and old.started_at is null
         and new.started_at is null and old.submitted_at is null and new.submitted_at is null
         and old.completed_at is null and new.completed_at is null
         and coalesce(v_transition,'') in ('worker_abandonment','mutual_prestart_cancellation'))
     ) then
    raise exception using errcode='55000',message='assignment_record_is_immutable';
  end if;
  return new;
end;
$function$;

create or replace function app_private.validate_assignment_allocation_pair()
returns trigger language plpgsql security definer set search_path = '' as $function$
begin
  if tg_table_name='principal_allocations' then
    if new.status in ('unassigned','refund_payable') then
      if new.assignment_id is not null then raise exception using errcode='22023',message='invalid_assignment_allocation_binding'; end if;
    elsif not exists(select 1 from app_private.assignments a
      where a.assignment_id=new.assignment_id and a.allocation_id=new.allocation_id
        and a.job_id=new.job_id and a.poster_id=new.poster_id
        and a.funding_intent_id=new.funding_intent_id
        and a.gross_principal_kobo=new.gross_principal_kobo
        and a.commission_basis_points=new.commission_basis_points
        and ((new.status='assigned' and a.work_state in ('assigned','in_progress','submitted')
              and not exists(select 1 from app_private.assignment_cases c where c.allocation_id=new.allocation_id and c.lifecycle_status<>'closed'))
          or (new.status='dispute_held' and a.work_state in ('assigned','in_progress','submitted')
              and exists(select 1 from app_private.assignment_cases c where c.assignment_id=a.assignment_id and c.allocation_id=new.allocation_id and c.lifecycle_status<>'closed'))
          or (new.status='worker_earnings_allocated' and a.work_state='completed'
              and exists(select 1 from app_private.assignment_completion_authorizations c where c.assignment_id=a.assignment_id and c.allocation_id=new.allocation_id)))
        and exists(select 1 from app_private.allocation_assignment_bindings b where b.assignment_id=a.assignment_id and b.allocation_id=a.allocation_id and b.unbound_at is null)) then
      raise exception using errcode='22023',message='invalid_assignment_allocation_binding';
    end if;
  elsif new.work_state='cancelled' then
    if not exists(select 1 from app_private.allocation_assignment_bindings b
      where b.assignment_id=new.assignment_id and b.allocation_id=new.allocation_id and b.unbound_at is not null)
       or exists(select 1 from app_private.principal_allocations p where p.allocation_id=new.allocation_id and p.assignment_id=new.assignment_id) then
      raise exception using errcode='22023',message='invalid_assignment_allocation_binding';
    end if;
  elsif not exists(select 1 from app_private.principal_allocations p
    join app_private.allocation_assignment_bindings b on b.assignment_id=p.assignment_id and b.allocation_id=p.allocation_id and b.unbound_at is null
    where p.allocation_id=new.allocation_id and p.assignment_id=new.assignment_id
      and p.job_id=new.job_id and p.poster_id=new.poster_id
      and p.funding_intent_id=new.funding_intent_id
      and p.gross_principal_kobo=new.gross_principal_kobo
      and p.commission_basis_points=new.commission_basis_points
      and ((p.status='assigned' and new.work_state in ('assigned','in_progress','submitted')
            and not exists(select 1 from app_private.assignment_cases c where c.allocation_id=p.allocation_id and c.lifecycle_status<>'closed'))
        or (p.status='dispute_held' and new.work_state in ('assigned','in_progress','submitted')
            and exists(select 1 from app_private.assignment_cases c where c.assignment_id=new.assignment_id and c.allocation_id=p.allocation_id and c.lifecycle_status<>'closed'))
        or (p.status='worker_earnings_allocated' and new.work_state='completed'
            and exists(select 1 from app_private.assignment_completion_authorizations c where c.assignment_id=new.assignment_id and c.allocation_id=p.allocation_id)))) then
    raise exception using errcode='22023',message='invalid_assignment_allocation_binding';
  end if;
  return null;
end;
$function$;

create or replace function app_private.guard_job_change()
returns trigger language plpgsql set search_path = '' as $function$
begin
  if tg_op='DELETE' then raise exception using errcode='55000',message='job_record_is_immutable'; end if;
  if new.job_id is distinct from old.job_id or new.poster_id is distinct from old.poster_id
     or new.created_at is distinct from old.created_at
     or new.current_terms_version < old.current_terms_version
     or new.current_terms_version > old.current_terms_version+1 then
    raise exception using errcode='55000',message='job_identity_is_immutable';
  end if;
  if new.current_terms_version<>old.current_terms_version and
     (old.listing_state<>'draft' or new.listing_state<>'draft' or old.active_funding_intent_id is not null or old.funded_funding_intent_id is not null) then
    raise exception using errcode='55000',message='job_terms_are_immutable';
  end if;
  if new.active_funding_intent_id is distinct from old.active_funding_intent_id and not (
    (old.active_funding_intent_id is null and new.active_funding_intent_id is not null and new.listing_state='awaiting_payment' and old.listing_state='draft') or
    (old.active_funding_intent_id is not null and new.active_funding_intent_id is null and new.listing_state in ('draft','open','expired') and old.listing_state='awaiting_payment')) then
    raise exception using errcode='55000',message='job_funding_state_is_immutable';
  end if;
  if new.funded_funding_intent_id is distinct from old.funded_funding_intent_id and not
    (old.funded_funding_intent_id is null and new.funded_funding_intent_id is not null and old.listing_state='awaiting_payment' and new.listing_state in ('open','expired')) then
    raise exception using errcode='55000',message='job_funding_state_is_immutable';
  end if;
  if new.listing_state is distinct from old.listing_state and not (
    (old.listing_state='draft' and new.listing_state='awaiting_payment') or
    (old.listing_state='awaiting_payment' and new.listing_state in ('draft','open','expired')) or
    (old.listing_state='open' and new.listing_state in ('filled','expired')) or
    (old.listing_state='expired' and new.listing_state='filled') or
    (old.listing_state='filled' and new.listing_state in ('open','expired'))
  ) then raise exception using errcode='55000',message='invalid_job_state_transition'; end if;
  new.updated_at:=pg_catalog.now();
  return new;
end;
$function$;

create or replace function app_private.assignment_command_projection(p_application_id uuid,p_assignment_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $function$
  select pg_catalog.jsonb_build_object(
    'assignment_id',s.assignment_id,'application_id',s.application_id,'thread_id',t.thread_id,
    'job_id',s.job_id,'assignment_state',s.work_state,'started_at',s.started_at,
    'submitted_at',s.submitted_at,'completed_at',s.completed_at,
    'hold_status',case when p.status='dispute_held' and p.assignment_id=s.assignment_id then 'open' else null end,
    'earnings_status',case when p.assignment_id<>s.assignment_id or p.assignment_id is null then 'not_released'
      when p.status='dispute_held' then 'on_hold' when p.status='worker_earnings_allocated' then 'available'
      else 'not_released' end,
    'terms_version',s.terms_version,'gross_principal_kobo',s.gross_principal_kobo::text,
    'commission_kobo',app_private.calculate_commission_kobo(s.gross_principal_kobo)::text,
    'worker_net_kobo',(s.gross_principal_kobo-app_private.calculate_commission_kobo(s.gross_principal_kobo))::text,
    'commission_basis_points',s.commission_basis_points
  )
  from app_private.assignments s join app_private.application_threads t using(application_id)
  left join app_private.principal_allocations p on p.allocation_id=s.allocation_id
  where s.application_id=p_application_id and s.assignment_id=p_assignment_id
$function$;

-- Idempotency helper. It stores participant-safe responses, including mixed batch outcomes.
create function app_private.cancellation_command_replay(
  p_actor uuid,p_command text,p_key uuid,p_hash bytea
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare v_saved app_private.assignment_cancellation_command_idempotency%rowtype;
begin
  select * into v_saved from app_private.assignment_cancellation_command_idempotency
  where actor_id=p_actor and command_name=p_command and idempotency_key=p_key;
  if not found then return null; end if;
  if v_saved.request_sha256<>p_hash then raise exception using errcode='23505',message='idempotency_conflict'; end if;
  return v_saved.response;
end;
$function$;

create function app_private.cancel_unassigned_slots_for_actor(
  p_actor uuid,p_job_id uuid,p_allocation_ids uuid[],p_reason text,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_job app_private.jobs%rowtype;
  v_caps text[];
  v_hash bytea;
  v_replay jsonb;
  v_rows jsonb:='[]'::jsonb;
  v_item record;
  v_allocation app_private.principal_allocations%rowtype;
  v_payable_id uuid;
  v_event uuid;
  v_remaining integer;
  v_state text;
  v_result jsonb;
begin
  p_reason:=pg_catalog.btrim(p_reason);
  if p_actor is null or p_job_id is null or p_allocation_ids is null or pg_catalog.cardinality(p_allocation_ids) not between 1 and 10
     or p_reason is null or char_length(p_reason) not between 1 and 500 or p_idempotency_key is null
     or (select count(distinct x) from pg_catalog.unnest(p_allocation_ids) x)<>pg_catalog.cardinality(p_allocation_ids) then
    raise exception using errcode='22023',message='invalid_cancellation_request';
  end if;
  v_hash:=extensions.digest(pg_catalog.convert_to(pg_catalog.jsonb_build_object(
    'job_id',p_job_id,'allocation_ids',p_allocation_ids,'reason',p_reason)::text,'UTF8'),'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_actor::text||':cancel_unassigned_slots:'||p_idempotency_key::text,428118));
  v_replay:=app_private.cancellation_command_replay(p_actor,'cancel_unassigned_slots',p_idempotency_key,v_hash);
  if v_replay is not null then return v_replay; end if;
  select * into v_job from app_private.jobs where job_id=p_job_id and poster_id=p_actor for update;
  if not found then raise exception using errcode='P0002',message='job_not_found'; end if;
  v_caps:=app_private.current_profile_capabilities(p_actor);
  if not ('can_hire'=any(v_caps)) then raise exception using errcode='42501',message='verification_required'; end if;
  for v_item in select x as allocation_id,ord from pg_catalog.unnest(p_allocation_ids) with ordinality as q(x,ord) order by ord loop
    select * into v_allocation from app_private.principal_allocations where allocation_id=v_item.allocation_id for update;
    if not found or v_allocation.job_id<>p_job_id or v_allocation.poster_id<>p_actor
       or v_allocation.status<>'unassigned' or v_allocation.assignment_id is not null then
      v_rows:=v_rows||pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('allocation_id',v_item.allocation_id,'result','ineligible'));
      continue;
    end if;
    v_payable_id:=pg_catalog.gen_random_uuid();
    insert into app_private.allocation_refund_payables(
      refund_payable_id,allocation_id,poster_id,amount_kobo,source,reason,authorized_by,idempotency_key
    ) values(v_payable_id,v_allocation.allocation_id,p_actor,v_allocation.gross_principal_kobo,
      'unassigned_slot',p_reason,p_actor,p_idempotency_key);
    perform pg_catalog.set_config('app.allocation_transition','poster_unassigned_cancellation',true);
    perform pg_catalog.set_config('app.allocation_actor',p_actor::text,true);
    update app_private.principal_allocations set status='refund_payable'
      where allocation_id=v_allocation.allocation_id and status='unassigned';
    if not found then raise exception using errcode='P0001',message='stale_state'; end if;
    insert into app_private.assignment_cancellation_audit(actor_id,action,allocation_id,reason)
    values(p_actor,'unassigned_slot_refund_authorized',v_allocation.allocation_id,p_reason);
    v_event:=app_private.append_marketplace_event(p_actor,p_job_id,'job.slot_refund_authorized',v_job.current_terms_version,
      pg_catalog.jsonb_build_object('allocation_id',v_allocation.allocation_id,'refund_payable_id',v_payable_id,'amount_kobo',v_allocation.gross_principal_kobo::text));
    perform app_private.add_in_app_notification(v_event,p_actor,'slot_refund_authorized');
    v_rows:=v_rows||pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'allocation_id',v_allocation.allocation_id,'result','refund_payable_authorized',
      'refund_payable_id',v_payable_id,'amount_kobo',v_allocation.gross_principal_kobo::text));
  end loop;
  select count(*)::integer into v_remaining from app_private.principal_allocations
  where job_id=p_job_id and funding_intent_id=v_job.funded_funding_intent_id and status='unassigned';
  v_state:=case when v_remaining>0 and (select t.application_deadline_at from app_private.job_terms_versions t where t.job_id=p_job_id and t.terms_version=v_job.current_terms_version)>pg_catalog.now() then 'open'
    when v_remaining>0 then 'expired' else case when (select t.application_deadline_at from app_private.job_terms_versions t where t.job_id=p_job_id and t.terms_version=v_job.current_terms_version)<=pg_catalog.now() then 'expired' else 'filled' end end;
  if v_state<>v_job.listing_state then update app_private.jobs set listing_state=v_state where job_id=p_job_id; end if;
  v_result:=pg_catalog.jsonb_build_object('results',v_rows);
  insert into app_private.assignment_cancellation_command_idempotency(actor_id,command_name,idempotency_key,request_sha256,response)
  values(p_actor,'cancel_unassigned_slots',p_idempotency_key,v_hash,v_result);
  return v_result;
end;
$function$;

create function app_private.cancellation_projection(p_cancellation_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $function$
  select pg_catalog.jsonb_build_object(
    'cancellation_id',r.cancellation_id,'assignment_id',r.assignment_id,
    'cancellation_version',r.cancellation_version,
    'status',case when f.cancellation_id is not null then 'completed' else 'awaiting_other_party' end,
    'consent_count',(select count(*)::integer from app_private.assignment_cancellation_consents c where c.cancellation_id=r.cancellation_id),
    'refund_payable_id',f.refund_payable_id
  )
  from app_private.assignment_cancellation_rounds r
  left join app_private.assignment_cancellation_finalizations f using(cancellation_id)
  where r.cancellation_id=p_cancellation_id
$function$;

create function app_private.request_prestart_cancellation_for_actor(
  p_actor uuid,p_assignment_id uuid,p_reason text,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_assignment app_private.assignments%rowtype;
  v_allocation app_private.principal_allocations%rowtype;
  v_job app_private.jobs%rowtype;
  v_caps text[];
  v_hash bytea;
  v_replay jsonb;
  v_account_status text;
  v_cancellation uuid;
  v_role text;
  v_result jsonb;
  v_event uuid;
begin
  p_reason:=pg_catalog.btrim(p_reason);
  if p_actor is null or p_assignment_id is null or p_reason is null or char_length(p_reason) not between 1 and 500 or p_idempotency_key is null then
    raise exception using errcode='22023',message='invalid_cancellation_request';
  end if;
  select * into v_assignment from app_private.assignments where assignment_id=p_assignment_id;
  if not found or p_actor not in (v_assignment.worker_id,v_assignment.poster_id) then raise exception using errcode='P0002',message='assignment_not_found'; end if;
  v_role:=case when p_actor=v_assignment.worker_id then 'worker' else 'poster' end;
  v_hash:=extensions.digest(pg_catalog.convert_to(pg_catalog.jsonb_build_object('assignment_id',p_assignment_id,'reason',p_reason)::text,'UTF8'),'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_actor::text||':request_prestart_cancellation:'||p_idempotency_key::text,428118));
  v_replay:=app_private.cancellation_command_replay(p_actor,'request_prestart_cancellation',p_idempotency_key,v_hash);
  if v_replay is not null then return v_replay; end if;
  select * into v_job from app_private.jobs where job_id=v_assignment.job_id for update;
  select * into v_allocation from app_private.principal_allocations where allocation_id=v_assignment.allocation_id for update;
  select * into v_assignment from app_private.assignments where assignment_id=p_assignment_id for update;
  select account_status into v_account_status from app_private.identity_accounts where user_id=p_actor;
  v_caps:=app_private.current_profile_capabilities(p_actor);
  if v_account_status<>'active' or (v_role='worker' and not ('can_work'=any(v_caps))) or (v_role='poster' and not ('can_hire'=any(v_caps))) then
    raise exception using errcode='42501',message='verification_required';
  end if;
  if v_allocation.assignment_id<>p_assignment_id or v_allocation.status<>'assigned' or v_assignment.work_state<>'assigned'
     or exists(select 1 from app_private.assignment_cases c where c.allocation_id=v_allocation.allocation_id and c.lifecycle_status<>'closed') then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  if exists(select 1 from app_private.assignment_cancellation_rounds where assignment_id=p_assignment_id) then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  v_cancellation:=pg_catalog.gen_random_uuid();
  insert into app_private.assignment_cancellation_rounds(
    cancellation_id,assignment_id,allocation_id,job_id,terms_version,terms_sha256,gross_principal_kobo,requested_by,request_reason
  ) values(v_cancellation,p_assignment_id,v_allocation.allocation_id,v_assignment.job_id,
    v_assignment.terms_version,v_assignment.terms_sha256,v_assignment.gross_principal_kobo,p_actor,p_reason);
  insert into app_private.assignment_cancellation_consents(cancellation_id,assignment_id,actor_id,consent_reason,cancellation_version)
  values(v_cancellation,p_assignment_id,p_actor,p_reason,1);
  insert into app_private.assignment_cancellation_audit(actor_id,action,assignment_id,allocation_id,cancellation_id,reason)
  values(p_actor,'cancellation_requested',p_assignment_id,v_allocation.allocation_id,v_cancellation,p_reason);
  v_event:=app_private.append_marketplace_event(p_actor,v_job.job_id,'job.assignment_cancellation_requested',v_assignment.terms_version,
    pg_catalog.jsonb_build_object('assignment_id',p_assignment_id,'cancellation_id',v_cancellation,'version',1));
  perform app_private.add_in_app_notification(v_event,v_assignment.worker_id,'assignment_cancellation_requested');
  perform app_private.add_in_app_notification(v_event,v_assignment.poster_id,'assignment_cancellation_requested');
  v_result:=app_private.cancellation_projection(v_cancellation);
  insert into app_private.assignment_cancellation_command_idempotency(actor_id,command_name,idempotency_key,request_sha256,response)
  values(p_actor,'request_prestart_cancellation',p_idempotency_key,v_hash,v_result);
  return v_result;
end;
$function$;

create function app_private.consent_prestart_cancellation_for_actor(
  p_actor uuid,p_cancellation_id uuid,p_cancellation_version integer,p_reason text,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_round app_private.assignment_cancellation_rounds%rowtype;
  v_assignment app_private.assignments%rowtype;
  v_allocation app_private.principal_allocations%rowtype;
  v_job app_private.jobs%rowtype;
  v_caps text[];
  v_hash bytea;
  v_replay jsonb;
  v_account_status text;
  v_role text;
  v_payable_id uuid;
  v_journal uuid;
  v_existing app_private.assignment_cancellation_consents%rowtype;
  v_result jsonb;
  v_event uuid;
begin
  p_reason:=pg_catalog.btrim(p_reason);
  if p_actor is null or p_cancellation_id is null or p_cancellation_version is null or p_cancellation_version<1
     or p_reason is null or char_length(p_reason) not between 1 and 500 or p_idempotency_key is null then
    raise exception using errcode='22023',message='invalid_cancellation_request';
  end if;
  select * into v_round from app_private.assignment_cancellation_rounds where cancellation_id=p_cancellation_id;
  if not found then raise exception using errcode='P0002',message='assignment_not_found'; end if;
  select * into v_assignment from app_private.assignments where assignment_id=v_round.assignment_id;
  if p_actor not in (v_assignment.worker_id,v_assignment.poster_id) then raise exception using errcode='P0002',message='assignment_not_found'; end if;
  v_role:=case when p_actor=v_assignment.worker_id then 'worker' else 'poster' end;
  v_hash:=extensions.digest(pg_catalog.convert_to(pg_catalog.jsonb_build_object('cancellation_id',p_cancellation_id,
    'cancellation_version',p_cancellation_version,'reason',p_reason)::text,'UTF8'),'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_actor::text||':consent_prestart_cancellation:'||p_idempotency_key::text,428118));
  v_replay:=app_private.cancellation_command_replay(p_actor,'consent_prestart_cancellation',p_idempotency_key,v_hash);
  if v_replay is not null then return v_replay; end if;
  select * into v_job from app_private.jobs where job_id=v_assignment.job_id for update;
  select * into v_allocation from app_private.principal_allocations where allocation_id=v_round.allocation_id for update;
  select * into v_assignment from app_private.assignments where assignment_id=v_round.assignment_id for update;
  select * into v_round from app_private.assignment_cancellation_rounds where cancellation_id=p_cancellation_id;
  select account_status into v_account_status from app_private.identity_accounts where user_id=p_actor;
  v_caps:=app_private.current_profile_capabilities(p_actor);
  if v_account_status<>'active' or (v_role='worker' and not ('can_work'=any(v_caps))) or (v_role='poster' and not ('can_hire'=any(v_caps))) then
    raise exception using errcode='42501',message='verification_required';
  end if;
  if p_cancellation_version<>v_round.cancellation_version or v_round.terms_version<>v_assignment.terms_version
     or v_round.terms_sha256<>v_assignment.terms_sha256 or v_allocation.assignment_id<>v_assignment.assignment_id
     or v_allocation.status<>'assigned' or v_assignment.work_state<>'assigned'
     or exists(select 1 from app_private.assignment_cases c where c.allocation_id=v_allocation.allocation_id and c.lifecycle_status<>'closed') then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  select * into v_existing from app_private.assignment_cancellation_consents
  where cancellation_id=p_cancellation_id and actor_id=p_actor;
  if found then
    if v_existing.consent_reason<>p_reason then raise exception using errcode='P0001',message='stale_state'; end if;
    v_result:=app_private.cancellation_projection(p_cancellation_id);
    insert into app_private.assignment_cancellation_command_idempotency(actor_id,command_name,idempotency_key,request_sha256,response)
    values(p_actor,'consent_prestart_cancellation',p_idempotency_key,v_hash,v_result);
    return v_result;
  end if;
  if v_round.requested_by=p_actor then raise exception using errcode='P0001',message='stale_state'; end if;
  insert into app_private.assignment_cancellation_consents(cancellation_id,assignment_id,actor_id,consent_reason,cancellation_version)
  values(p_cancellation_id,v_assignment.assignment_id,p_actor,p_reason,v_round.cancellation_version);
  insert into app_private.assignment_cancellation_audit(actor_id,action,assignment_id,allocation_id,cancellation_id,reason)
  values(p_actor,'cancellation_consented',v_assignment.assignment_id,v_allocation.allocation_id,p_cancellation_id,p_reason);
  if (select count(*) from app_private.assignment_cancellation_consents where cancellation_id=p_cancellation_id)<>2 then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  v_payable_id:=pg_catalog.gen_random_uuid();
  insert into app_private.allocation_refund_payables(
    refund_payable_id,allocation_id,poster_id,amount_kobo,source,source_assignment_id,cancellation_id,
    reason,authorized_by,idempotency_key
  ) values(v_payable_id,v_allocation.allocation_id,v_assignment.poster_id,v_allocation.gross_principal_kobo,
    'mutual_prestart',v_assignment.assignment_id,p_cancellation_id,
    'Mutual pre-start cancellation',p_actor,p_idempotency_key);
  perform pg_catalog.set_config('app.assignment_cancellation_transition','mutual_prestart_cancellation',true);
  update app_private.assignments set work_state='cancelled' where assignment_id=v_assignment.assignment_id and work_state='assigned';
  if not found then raise exception using errcode='P0001',message='stale_state'; end if;
  update app_private.job_applications set state='closed',decided_at=pg_catalog.now(),decided_by=p_actor
  where application_id=v_assignment.application_id and state='accepted';
  perform pg_catalog.set_config('app.allocation_transition','mutual_prestart_cancellation',true);
  perform pg_catalog.set_config('app.assignment_unbind_reason','mutual_prestart_cancellation',true);
  perform pg_catalog.set_config('app.allocation_actor',p_actor::text,true);
  update app_private.principal_allocations set status='refund_payable',assignment_id=null
  where allocation_id=v_allocation.allocation_id and assignment_id=v_assignment.assignment_id and status='assigned';
  if not found then raise exception using errcode='P0001',message='stale_state'; end if;
  select journal_id into v_journal from app_private.ledger_journal_transactions
  where effect_key=app_private.stable_financial_effect_key('nbd:allocation_refund_authorized:'||v_allocation.allocation_id::text);
  insert into app_private.assignment_cancellation_finalizations(cancellation_id,assignment_id,refund_payable_id,journal_id,finalized_by)
  values(p_cancellation_id,v_assignment.assignment_id,v_payable_id,v_journal,p_actor);
  insert into app_private.assignment_cancellation_audit(actor_id,action,assignment_id,allocation_id,cancellation_id,reason)
  values(p_actor,'mutual_cancellation_finalized',v_assignment.assignment_id,v_allocation.allocation_id,p_cancellation_id,p_reason);
  v_event:=app_private.append_marketplace_event(p_actor,v_job.job_id,'job.assignment_cancellation_completed',v_assignment.terms_version,
    pg_catalog.jsonb_build_object('assignment_id',v_assignment.assignment_id,'cancellation_id',p_cancellation_id,'refund_payable_id',v_payable_id));
  perform app_private.add_in_app_notification(v_event,v_assignment.worker_id,'assignment_cancellation_completed');
  perform app_private.add_in_app_notification(v_event,v_assignment.poster_id,'assignment_cancellation_completed');
  v_result:=app_private.cancellation_projection(p_cancellation_id);
  insert into app_private.assignment_cancellation_command_idempotency(actor_id,command_name,idempotency_key,request_sha256,response)
  values(p_actor,'consent_prestart_cancellation',p_idempotency_key,v_hash,v_result);
  return v_result;
end;
$function$;

create function app_private.abandon_prestart_assignment_for_actor(
  p_actor uuid,p_assignment_id uuid,p_reason text,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_assignment app_private.assignments%rowtype;
  v_allocation app_private.principal_allocations%rowtype;
  v_job app_private.jobs%rowtype;
  v_terms app_private.job_terms_versions%rowtype;
  v_caps text[];
  v_hash bytea;
  v_replay jsonb;
  v_result jsonb;
  v_event uuid;
  v_remaining integer;
  v_next text;
begin
  p_reason:=pg_catalog.btrim(p_reason);
  if p_actor is null or p_assignment_id is null or p_reason is null or char_length(p_reason) not between 1 and 500 or p_idempotency_key is null then
    raise exception using errcode='22023',message='invalid_cancellation_request';
  end if;
  select * into v_assignment from app_private.assignments where assignment_id=p_assignment_id;
  if not found or v_assignment.worker_id<>p_actor then raise exception using errcode='P0002',message='assignment_not_found'; end if;
  v_hash:=extensions.digest(pg_catalog.convert_to(pg_catalog.jsonb_build_object('assignment_id',p_assignment_id,'reason',p_reason)::text,'UTF8'),'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_actor::text||':abandon_prestart_assignment:'||p_idempotency_key::text,428118));
  v_replay:=app_private.cancellation_command_replay(p_actor,'abandon_prestart_assignment',p_idempotency_key,v_hash);
  if v_replay is not null then return v_replay; end if;
  select * into v_job from app_private.jobs where job_id=v_assignment.job_id for update;
  select * into v_allocation from app_private.principal_allocations where allocation_id=v_assignment.allocation_id for update;
  select * into v_assignment from app_private.assignments where assignment_id=p_assignment_id for update;
  v_caps:=app_private.current_profile_capabilities(p_actor);
  if not ('can_work'=any(v_caps)) then raise exception using errcode='42501',message='verification_required'; end if;
  if v_allocation.assignment_id<>p_assignment_id or v_allocation.status<>'assigned' or v_assignment.work_state<>'assigned'
     or exists(select 1 from app_private.assignment_cases c where c.allocation_id=v_allocation.allocation_id and c.lifecycle_status<>'closed') then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  select * into v_terms from app_private.job_terms_versions where job_id=v_assignment.job_id and terms_version=v_assignment.terms_version;
  if not found or v_terms.terms_sha256<>v_assignment.terms_sha256 then raise exception using errcode='P0001',message='stale_state'; end if;
  perform pg_catalog.set_config('app.assignment_cancellation_transition','worker_abandonment',true);
  update app_private.assignments set work_state='cancelled' where assignment_id=p_assignment_id and work_state='assigned';
  if not found then raise exception using errcode='P0001',message='stale_state'; end if;
  update app_private.job_applications set state='closed',decided_at=pg_catalog.now(),decided_by=p_actor
  where application_id=v_assignment.application_id and state='accepted';
  perform pg_catalog.set_config('app.allocation_transition','worker_abandonment',true);
  perform pg_catalog.set_config('app.assignment_unbind_reason','worker_abandonment',true);
  perform pg_catalog.set_config('app.allocation_actor',p_actor::text,true);
  update app_private.principal_allocations set status='unassigned',assignment_id=null
  where allocation_id=v_allocation.allocation_id and assignment_id=p_assignment_id and status='assigned';
  if not found then raise exception using errcode='P0001',message='stale_state'; end if;
  insert into app_private.assignment_cancellation_audit(actor_id,action,assignment_id,allocation_id,reason)
  values(p_actor,'worker_prestart_abandoned',p_assignment_id,v_allocation.allocation_id,p_reason);
  select count(*)::integer into v_remaining from app_private.principal_allocations
  where job_id=v_job.job_id and funding_intent_id=v_job.funded_funding_intent_id and status='unassigned';
  v_next:=case when v_terms.application_deadline_at<=pg_catalog.now() then 'expired'
    when v_remaining>0 then 'open' else 'filled' end;
  if v_job.listing_state<>v_next then update app_private.jobs set listing_state=v_next where job_id=v_job.job_id; end if;
  v_event:=app_private.append_marketplace_event(p_actor,v_job.job_id,'job.assignment_abandoned',v_assignment.terms_version,
    pg_catalog.jsonb_build_object('assignment_id',p_assignment_id,'allocation_id',v_allocation.allocation_id,'listing_state',v_next));
  perform app_private.add_in_app_notification(v_event,v_assignment.worker_id,'assignment_abandoned');
  perform app_private.add_in_app_notification(v_event,v_assignment.poster_id,'assignment_abandoned');
  v_result:=pg_catalog.jsonb_build_object('assignment',app_private.assignment_command_projection(v_assignment.application_id,p_assignment_id),
    'allocation',pg_catalog.jsonb_build_object('allocation_id',v_allocation.allocation_id,'status','unassigned'),
    'listing_state',v_next);
  insert into app_private.assignment_cancellation_command_idempotency(actor_id,command_name,idempotency_key,request_sha256,response)
  values(p_actor,'abandon_prestart_assignment',p_idempotency_key,v_hash,v_result);
  return v_result;
end;
$function$;

-- Check that an authorized refund is represented exactly once in the immutable ledger.
create function app_private.assert_refund_payable_journal()
returns trigger language plpgsql security definer set search_path = '' as $function$
declare v_journal app_private.ledger_journal_transactions%rowtype;
begin
  select j.* into v_journal from app_private.ledger_journal_transactions j
  where j.effect_key=app_private.stable_financial_effect_key('nbd:allocation_refund_authorized:'||new.allocation_id::text);
  if not found or v_journal.effect_type<>'allocation_refund_authorized'
     or (select coalesce(sum(e.amount_kobo) filter(where a.account_code='poster_refund_payable' and e.direction='credit'),0)
       from app_private.ledger_journal_entries e join app_private.ledger_accounts a using(account_id)
       where e.journal_id=v_journal.journal_id and e.allocation_id=new.allocation_id and e.owner_id=new.poster_id)<>new.amount_kobo then
    raise exception using errcode='23514',message='refund_payable_journal_mismatch';
  end if;
  return null;
end;
$function$;
create constraint trigger allocation_refund_payables_journal_check
after insert on app_private.allocation_refund_payables
deferrable initially deferred for each row execute function app_private.assert_refund_payable_journal();

-- Extend the safe wallet response without changing Phase 3 activity semantics.
alter function app_private.get_my_wallet_for_actor(uuid,timestamptz,uuid)
  rename to get_my_wallet_for_actor_before_refund_payables;
create function app_private.get_my_wallet_for_actor(
  p_actor uuid,p_before_created_at timestamptz,p_before_id uuid
) returns jsonb language plpgsql stable security definer set search_path = '' as $function$
declare
  v_result jsonb;
  v_payables jsonb;
  v_payable_total numeric;
begin
  v_result:=app_private.get_my_wallet_for_actor_before_refund_payables(p_actor,p_before_created_at,p_before_id);
  select coalesce(sum(r.amount_kobo),0)::numeric into v_payable_total
  from app_private.allocation_refund_payables r where r.poster_id=p_actor and r.status='authorized';
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'refund_payable_id',q.refund_payable_id,'allocation_id',q.allocation_id,
      'amount_kobo',q.amount_kobo::text,'status',q.status,'source',q.source,'created_at',q.created_at
    ) order by q.created_at desc,q.refund_payable_id desc),'[]'::jsonb)
  into v_payables from (
    select r.refund_payable_id,r.allocation_id,r.amount_kobo,r.status,r.source,r.created_at
    from app_private.allocation_refund_payables r
    where r.poster_id=p_actor and r.status='authorized'
    order by r.created_at desc,r.refund_payable_id desc limit 20
  ) q;
  return v_result||pg_catalog.jsonb_build_object(
    'balances',(v_result->'balances')||pg_catalog.jsonb_build_object('poster_refund_payable_kobo',v_payable_total::text),
    'refund_payables',v_payables
  );
end;
$function$;
create or replace function public.server_get_my_wallet_for_actor(
  p_actor uuid,p_before_created_at timestamptz,p_before_id uuid
) returns jsonb language sql stable security definer set search_path = '' as $function$
  select app_private.get_my_wallet_for_actor(p_actor,p_before_created_at,p_before_id)
$function$;
revoke all on function app_private.get_my_wallet_for_actor_before_refund_payables(uuid,timestamptz,uuid),
  app_private.get_my_wallet_for_actor(uuid,timestamptz,uuid) from public,anon,authenticated,service_role;
grant execute on function app_private.get_my_wallet_for_actor(uuid,timestamptz,uuid) to postgres;
revoke all on function public.server_get_my_wallet_for_actor(uuid,timestamptz,uuid) from public,anon,authenticated;
grant execute on function public.server_get_my_wallet_for_actor(uuid,timestamptz,uuid) to service_role;

create function public.server_cancel_unassigned_slots_for_actor(
  p_actor uuid,p_job_id uuid,p_allocation_ids uuid[],p_reason text,p_idempotency_key uuid
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.cancel_unassigned_slots_for_actor($1,$2,$3,$4,$5)
$function$;
create function public.server_request_prestart_cancellation_for_actor(
  p_actor uuid,p_assignment_id uuid,p_reason text,p_idempotency_key uuid
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.request_prestart_cancellation_for_actor($1,$2,$3,$4)
$function$;
create function public.server_consent_prestart_cancellation_for_actor(
  p_actor uuid,p_cancellation_id uuid,p_cancellation_version integer,p_reason text,p_idempotency_key uuid
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.consent_prestart_cancellation_for_actor($1,$2,$3,$4,$5)
$function$;
create function public.server_abandon_prestart_assignment_for_actor(
  p_actor uuid,p_assignment_id uuid,p_reason text,p_idempotency_key uuid
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.abandon_prestart_assignment_for_actor($1,$2,$3,$4)
$function$;

revoke all on table app_private.allocation_assignment_bindings,app_private.assignment_cancellation_rounds,
  app_private.assignment_cancellation_consents,app_private.allocation_refund_payables,
  app_private.assignment_cancellation_finalizations,app_private.assignment_cancellation_audit,
  app_private.assignment_cancellation_command_idempotency from public,anon,authenticated,service_role;
revoke all on function app_private.guard_allocation_assignment_binding(),app_private.record_allocation_assignment_binding(),
  app_private.reject_cancellation_record_mutation(),app_private.cancellation_command_replay(uuid,text,uuid,bytea),
  app_private.cancel_unassigned_slots_for_actor(uuid,uuid,uuid[],text,uuid),
  app_private.cancellation_projection(uuid),
  app_private.request_prestart_cancellation_for_actor(uuid,uuid,text,uuid),
  app_private.consent_prestart_cancellation_for_actor(uuid,uuid,integer,text,uuid),
  app_private.abandon_prestart_assignment_for_actor(uuid,uuid,text,uuid),
  app_private.assert_refund_payable_journal(),
  app_private.post_allocation_status_journal(uuid,text,text,uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function public.server_cancel_unassigned_slots_for_actor(uuid,uuid,uuid[],text,uuid),
  public.server_request_prestart_cancellation_for_actor(uuid,uuid,text,uuid),
  public.server_consent_prestart_cancellation_for_actor(uuid,uuid,integer,text,uuid),
  public.server_abandon_prestart_assignment_for_actor(uuid,uuid,text,uuid) to service_role;
revoke all on function public.server_cancel_unassigned_slots_for_actor(uuid,uuid,uuid[],text,uuid),
  public.server_request_prestart_cancellation_for_actor(uuid,uuid,text,uuid),
  public.server_consent_prestart_cancellation_for_actor(uuid,uuid,integer,text,uuid),
  public.server_abandon_prestart_assignment_for_actor(uuid,uuid,text,uuid) from public,anon,authenticated;

commit;
