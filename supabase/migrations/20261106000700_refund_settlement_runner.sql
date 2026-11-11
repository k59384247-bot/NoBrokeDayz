begin;

-- Refund progress is separate from the immutable authorization payable. A
-- refund operation exists only after the runner materializes that authority.
create table app_private.allocation_refund_progress (
  refund_payable_id uuid primary key references app_private.allocation_refund_payables(refund_payable_id) on delete restrict,
  allocation_id uuid not null unique references app_private.principal_allocations(allocation_id) on delete restrict,
  poster_id uuid not null references auth.users(id) on delete restrict,
  amount_kobo bigint not null check (amount_kobo>0),
  operation_id uuid unique references app_private.provider_operations(operation_id) on delete restrict,
  status text not null default 'authorized' check (status in (
    'authorized','queued_for_liquidity','processing','unknown','failed','exception','settled','reversed'
  )),
  fee_reserve_transferred_kobo bigint not null default 0 check (fee_reserve_transferred_kobo>=0),
  safe_error_code text check (safe_error_code is null or safe_error_code in (
    'provider_timeout','provider_unavailable','amount_mismatch','currency_mismatch',
    'reference_mismatch','unknown_result','settlement_pending'
  )),
  settled_at timestamptz,
  updated_at timestamptz not null default pg_catalog.now(),
  check ((status in ('settled','reversed'))=(settled_at is not null)),
  check (operation_id is not null or status in ('authorized','exception'))
);

create table app_private.refund_operation_mappings (
  operation_id uuid primary key references app_private.provider_operations(operation_id) on delete restrict,
  refund_payable_id uuid not null unique references app_private.allocation_refund_payables(refund_payable_id) on delete restrict,
  allocation_id uuid not null unique references app_private.principal_allocations(allocation_id) on delete restrict,
  funding_intent_id uuid not null references app_private.funding_intents(intent_id) on delete restrict,
  funding_attempt_id uuid not null references app_private.funding_attempts(attempt_id) on delete restrict,
  source_collection_operation_id uuid not null references app_private.provider_operations(operation_id) on delete restrict,
  original_provider_reference text not null check (char_length(original_provider_reference) between 1 and 180),
  amount_kobo bigint not null check (amount_kobo>0),
  expected_provider_fee_kobo bigint not null check (expected_provider_fee_kobo between 0 and 1000000000),
  fee_treatment text not null default 'platform_expense' check (fee_treatment='platform_expense'),
  settlement_effect_id uuid not null unique default pg_catalog.gen_random_uuid(),
  failed_fee_effect_id uuid not null unique default pg_catalog.gen_random_uuid(),
  fee_reserve_effect_id uuid not null unique default pg_catalog.gen_random_uuid(),
  request_sha256 bytea not null check (pg_catalog.octet_length(request_sha256)=32),
  created_at timestamptz not null default pg_catalog.now()
);
create unique index provider_operations_one_refund_per_allocation
  on app_private.provider_operations(allocation_id)
  where operation_type='refund';

create table app_private.refund_reversal_incidents (
  incident_id uuid primary key default pg_catalog.gen_random_uuid(),
  operation_id uuid not null unique references app_private.provider_operations(operation_id) on delete restrict,
  refund_payable_id uuid not null unique references app_private.allocation_refund_payables(refund_payable_id) on delete restrict,
  amount_kobo bigint not null check (amount_kobo>0),
  provider_reference text not null check (char_length(provider_reference) between 1 and 180),
  status text not null default 'open' check (status in ('open','resolved')),
  created_at timestamptz not null default pg_catalog.now(),
  resolved_at timestamptz,
  check ((status='open')=(resolved_at is null))
);

create table app_private.local_refund_fee_policy (
  provider_adapter text primary key check (provider_adapter='local_simulator'),
  expected_fee_kobo bigint not null default 0 check (expected_fee_kobo between 0 and 1000000000),
  updated_at timestamptz not null default pg_catalog.now()
);
insert into app_private.local_refund_fee_policy(provider_adapter,expected_fee_kobo)
values('local_simulator',0);

create table app_private.provider_refund_settlement_records (
  operation_id uuid primary key references app_private.provider_operations(operation_id) on delete restrict,
  refund_payable_id uuid not null unique references app_private.allocation_refund_payables(refund_payable_id) on delete restrict,
  settlement_effect_id uuid not null unique,
  journal_id uuid not null unique references app_private.ledger_journal_transactions(journal_id) on delete restrict,
  principal_kobo bigint not null check (principal_kobo>0),
  fee_kobo bigint not null check (fee_kobo>=0),
  original_provider_reference text not null,
  provider_refund_reference text not null,
  settled_at timestamptz not null default pg_catalog.now()
);

insert into app_private.allocation_refund_progress(
  refund_payable_id,allocation_id,poster_id,amount_kobo
)
select r.refund_payable_id,r.allocation_id,r.poster_id,r.amount_kobo
from app_private.allocation_refund_payables r
on conflict(refund_payable_id) do nothing;

create function app_private.guard_refund_progress_change()
returns trigger language plpgsql set search_path = '' as $function$
begin
  if tg_op='DELETE' or new.refund_payable_id is distinct from old.refund_payable_id
     or new.allocation_id is distinct from old.allocation_id
     or new.poster_id is distinct from old.poster_id
     or new.amount_kobo is distinct from old.amount_kobo
     or (old.operation_id is not null and new.operation_id is distinct from old.operation_id)
     or new.fee_reserve_transferred_kobo<old.fee_reserve_transferred_kobo
     or not (
       new.status=old.status or
       (old.status='authorized' and new.status in ('queued_for_liquidity','exception')) or
       (old.status='queued_for_liquidity' and new.status in ('processing','exception')) or
       (old.status='processing' and new.status in ('unknown','failed','exception','settled')) or
       (old.status='unknown' and new.status in ('processing','failed','exception','settled')) or
       (old.status='settled' and new.status='reversed')
     ) then
    raise exception using errcode='55000',message='refund_progress_identity_is_immutable';
  end if;
  new.updated_at:=pg_catalog.now();
  return new;
end;
$function$;
create trigger allocation_refund_progress_guard
before update or delete on app_private.allocation_refund_progress
for each row execute function app_private.guard_refund_progress_change();

create function app_private.guard_refund_operation_mapping()
returns trigger language plpgsql set search_path = '' as $function$
begin
  raise exception using errcode='55000',message='refund_operation_mapping_is_immutable';
end;
$function$;
create trigger refund_operation_mappings_immutable
before update or delete on app_private.refund_operation_mappings
for each row execute function app_private.guard_refund_operation_mapping();
create trigger refund_reversal_incidents_immutable
before update or delete on app_private.refund_reversal_incidents
for each row execute function app_private.reject_financial_history_mutation();
create trigger provider_refund_settlement_records_immutable
before update or delete on app_private.provider_refund_settlement_records
for each row execute function app_private.reject_financial_history_mutation();

create function app_private.create_refund_progress_for_payable()
returns trigger language plpgsql set search_path = '' as $function$
begin
  insert into app_private.allocation_refund_progress(
    refund_payable_id,allocation_id,poster_id,amount_kobo
  ) values(new.refund_payable_id,new.allocation_id,new.poster_id,new.amount_kobo);
  return new;
end;
$function$;
create trigger allocation_refund_progress_create
after insert on app_private.allocation_refund_payables
for each row execute function app_private.create_refund_progress_for_payable();

create or replace function app_private.queue_local_payment_operation()
returns trigger language plpgsql set search_path = '' as $function$
begin
  if new.provider_adapter='local_simulator'
     and new.operation_type in ('collection','payout','refund') then
    insert into app_private.payment_operation_jobs(operation_id)
    values(new.operation_id) on conflict(operation_id) do nothing;
  end if;
  return new;
end;
$function$;

alter table app_private.ledger_journal_transactions
  drop constraint ledger_journal_transactions_effect_type_check,
  add constraint ledger_journal_transactions_effect_type_check check (effect_type in (
    'funding_collected','provider_settlement','allocation_assigned','allocation_held',
    'completion_released','withdrawal_reserved','payout_settled','platform_fee_reserve_transfer',
    'provider_refund_settled','provider_refund_fee_charged','compensating_correction',
    'platform_capital_contribution','allocation_reopened','allocation_refund_authorized',
    'case_outcome_finalized','case_hold_restored'
  ));

do $function_patch$
declare v_definition text;
begin
  v_definition:=pg_catalog.pg_get_functiondef(
    'app_private.post_financial_journal(uuid,text,uuid,uuid,jsonb)'::regprocedure);
  if pg_catalog.strpos(v_definition,'''provider_refund_settled'',''compensating_correction''')=0 then
    raise exception 'refund_journal_type_patch_mismatch';
  end if;
  v_definition:=pg_catalog.replace(v_definition,
    '''provider_refund_settled'',''compensating_correction''',
    '''provider_refund_settled'',''provider_refund_fee_charged'',''compensating_correction''');
  execute v_definition;
end;
$function_patch$;

alter table app_private.financial_audit_events
  drop constraint financial_audit_events_event_type_check,
  add constraint financial_audit_events_event_type_check check (event_type in (
    'financial_journal_posted','financial_inspection','assignment_completion_authorized',
    'assignment_hold_opened','wallet_destination_changed','withdrawal_requested',
    'withdrawal_status_changed','financial_authorization_created','provider_operation_authorized',
    'provider_operation_status_changed','financial_reconciliation_completed','refund_status_changed',
    'case_finalization_executed'
  ));
alter table app_private.financial_outbox
  drop constraint financial_outbox_event_type_check,
  add constraint financial_outbox_event_type_check check (event_type in (
    'financial.journal_posted','financial.wallet_destination_changed','financial.withdrawal_requested',
    'financial.withdrawal_status_changed','financial.authorization_created',
    'financial.provider_operation_authorized','financial.provider_operation_status_changed',
    'financial.inspection','financial.reconciliation_completed','financial.refund_status_changed'
  ));
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
    'refund_unknown','refund_settled','refund_failed','refund_exception','refund_reversal_review'
  ));

create function app_private.record_refund_status_event(
  p_payable_id uuid,p_operation_id uuid,p_status text,p_safe_error text default null
) returns uuid language plpgsql security definer set search_path = '' as $function$
declare
  v_payable app_private.allocation_refund_payables%rowtype;
  v_event uuid;
  v_notice text;
begin
  select * into v_payable from app_private.allocation_refund_payables
  where refund_payable_id=p_payable_id;
  if not found then raise exception using errcode='P0002',message='refund_payable_not_found'; end if;
  insert into app_private.financial_audit_events(actor_id,event_type,operation_id,reference_id,event_data)
  values(null,'refund_status_changed',p_operation_id,p_payable_id,
    pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
      'status',p_status,'amount_kobo',v_payable.amount_kobo::text,'safe_error_code',p_safe_error)))
  returning event_id into v_event;
  insert into app_private.financial_outbox(event_id,event_type,payload)
  values(v_event,'financial.refund_status_changed',pg_catalog.jsonb_build_object(
    'event_id',v_event,'refund_payable_id',p_payable_id,'status',p_status));
  v_notice:=case p_status
    when 'processing' then 'refund_processing'
    when 'unknown' then 'refund_unknown'
    when 'settled' then 'refund_settled'
    when 'failed' then 'refund_failed'
    when 'exception' then 'refund_exception'
    when 'reversed' then 'refund_reversal_review'
    else null end;
  if v_notice is not null then
    perform app_private.add_financial_in_app_notification(v_event,v_payable.poster_id,v_notice);
  end if;
  return v_event;
end;
$function$;

create function app_private.prepare_local_refund_operations()
returns integer language plpgsql security definer set search_path = '' as $function$
declare
  v_intent_id uuid;
  v_payable app_private.allocation_refund_payables%rowtype;
  v_allocation app_private.principal_allocations%rowtype;
  v_attempt app_private.funding_attempts%rowtype;
  v_collection app_private.provider_operations%rowtype;
  v_operation_id uuid;
  v_provider_key uuid;
  v_expected_fee bigint;
  v_authorized numeric;
  v_reserved numeric;
  v_allocation_total numeric;
  v_prepared integer:=0;
  v_hash bytea;
begin
  for v_intent_id in
    select distinct a.funding_intent_id
    from app_private.allocation_refund_payables r
    join app_private.principal_allocations a using(allocation_id)
    join app_private.allocation_refund_progress p using(refund_payable_id)
    where p.status='authorized' and p.operation_id is null
    order by a.funding_intent_id
  loop
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('nbd:refund-source:'||v_intent_id::text,0));
    select coalesce(sum(r.amount_kobo),0)::numeric into v_authorized
    from app_private.allocation_refund_payables r
    join app_private.principal_allocations a using(allocation_id)
    where a.funding_intent_id=v_intent_id and r.status='authorized';
    select coalesce(sum(m.amount_kobo),0)::numeric into v_reserved
    from app_private.refund_operation_mappings m where m.funding_intent_id=v_intent_id;
    select coalesce(sum(a.gross_principal_kobo),0)::numeric into v_allocation_total
    from app_private.principal_allocations a where a.funding_intent_id=v_intent_id;
    select * into v_attempt from app_private.funding_attempts
    where funding_intent_id=v_intent_id and status='succeeded' for update;
    if not found then
      update app_private.allocation_refund_progress p
      set status='exception',safe_error_code='reference_mismatch'
      from app_private.allocation_refund_payables r
      join app_private.principal_allocations a using(allocation_id)
      where p.refund_payable_id=r.refund_payable_id and a.funding_intent_id=v_intent_id
        and p.status='authorized' and p.operation_id is null;
      continue;
    end if;
    select * into v_collection from app_private.provider_operations
    where operation_id=v_attempt.operation_id and operation_type='collection'
      and provider_adapter='local_simulator' for update;
    if not found or v_collection.provider_operation_reference is null
       or v_allocation_total<>v_attempt.collected_gross_kobo::numeric then
      update app_private.allocation_refund_progress p
      set status='exception',safe_error_code='reference_mismatch'
      from app_private.allocation_refund_payables r
      join app_private.principal_allocations a using(allocation_id)
      where p.refund_payable_id=r.refund_payable_id and a.funding_intent_id=v_intent_id
        and p.status='authorized' and p.operation_id is null;
      insert into app_private.financial_exceptions(operation_id,funding_intent_id,exception_type,safe_reference)
      values(v_attempt.operation_id,v_intent_id,'reference_mismatch',
        left(coalesce(v_collection.provider_operation_reference,''),180));
      continue;
    end if;
    if v_authorized>v_attempt.collected_gross_kobo::numeric or v_reserved>v_authorized then
      update app_private.allocation_refund_progress p
      set status='exception',safe_error_code='amount_mismatch'
      from app_private.allocation_refund_payables r
      join app_private.principal_allocations a using(allocation_id)
      where p.refund_payable_id=r.refund_payable_id and a.funding_intent_id=v_intent_id
        and p.status='authorized' and p.operation_id is null;
      insert into app_private.financial_exceptions(operation_id,funding_intent_id,exception_type,safe_reference)
      values(v_attempt.operation_id,v_intent_id,'amount_mismatch',v_collection.provider_operation_reference);
      continue;
    end if;
    select expected_fee_kobo into v_expected_fee
    from app_private.local_refund_fee_policy where provider_adapter='local_simulator';
    for v_payable in
      select r.* from app_private.allocation_refund_payables r
      join app_private.principal_allocations a using(allocation_id)
      join app_private.allocation_refund_progress p using(refund_payable_id)
      where a.funding_intent_id=v_intent_id and p.status='authorized' and p.operation_id is null
      order by a.slot_number,r.refund_payable_id for update of r,p skip locked
    loop
      select * into v_allocation from app_private.principal_allocations
        where allocation_id=v_payable.allocation_id;
      v_operation_id:=pg_catalog.gen_random_uuid();
      v_provider_key:=pg_catalog.gen_random_uuid();
      v_hash:=extensions.digest(pg_catalog.convert_to(pg_catalog.jsonb_build_object(
        'operation_id',v_operation_id,'refund_payable_id',v_payable.refund_payable_id,
        'allocation_id',v_allocation.allocation_id,'source_operation_id',v_attempt.operation_id,
        'source_provider_reference',v_collection.provider_operation_reference,
        'amount_kobo',v_payable.amount_kobo::text,'expected_fee_kobo',v_expected_fee::text
      )::text,'UTF8'),'sha256');
      insert into app_private.provider_operations(
        operation_id,operation_type,provider_adapter,provider_idempotency_key,actor_id,
        funding_intent_id,allocation_id,amount_kobo,currency,request_sha256,status
      ) values(v_operation_id,'refund','local_simulator',v_provider_key,v_payable.authorized_by,
        v_intent_id,v_allocation.allocation_id,v_payable.amount_kobo,'NGN',v_hash,'queued_for_liquidity');
      insert into app_private.refund_operation_mappings(
        operation_id,refund_payable_id,allocation_id,funding_intent_id,funding_attempt_id,
        source_collection_operation_id,original_provider_reference,amount_kobo,
        expected_provider_fee_kobo,request_sha256
      ) values(v_operation_id,v_payable.refund_payable_id,v_allocation.allocation_id,
        v_intent_id,v_attempt.attempt_id,v_collection.operation_id,
        v_collection.provider_operation_reference,v_payable.amount_kobo,v_expected_fee,v_hash);
      update app_private.allocation_refund_progress set operation_id=v_operation_id,
        status='queued_for_liquidity' where refund_payable_id=v_payable.refund_payable_id;
      v_reserved:=v_reserved+v_payable.amount_kobo;
      v_prepared:=v_prepared+1;
    end loop;
  end loop;
  return v_prepared;
end;
$function$;

create function app_private.try_start_queued_refunds_for_liquidity()
returns integer language plpgsql security definer set search_path = '' as $function$
declare
  v_progress app_private.allocation_refund_progress%rowtype;
  v_mapping app_private.refund_operation_mappings%rowtype;
  v_operation app_private.provider_operations%rowtype;
  v_cash bigint; v_reserve bigint; v_protected numeric; v_unsettled_protected numeric;
  v_secured_protected numeric; v_active_fees numeric; v_fee_allowance numeric;
  v_gap numeric; v_started integer:=0;
begin
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('nbd:payment-liquidity',0));
  perform app_private.prepare_local_refund_operations();
  for v_progress in
    select p.* from app_private.allocation_refund_progress p
    join app_private.refund_operation_mappings m on m.refund_payable_id=p.refund_payable_id
    where p.status='queued_for_liquidity' order by p.updated_at,p.refund_payable_id
    for update of p skip locked
  loop
    select * into v_mapping from app_private.refund_operation_mappings
      where refund_payable_id=v_progress.refund_payable_id;
    if not exists(select 1 from app_private.funding_attempts a
      where a.attempt_id=v_mapping.funding_attempt_id and a.status='succeeded'
        and a.settlement_status='available') then
      continue;
    end if;
    select * into v_operation from app_private.provider_operations
      where operation_id=v_mapping.operation_id for update;
    select coalesce(sum(b.balance_kobo) filter(where a.account_code='provider_available_cash'),0)::bigint,
      coalesce(sum(b.balance_kobo) filter(where a.account_code='platform_fee_reserve_cash'),0)::bigint,
      coalesce(-sum(b.balance_kobo) filter(where a.account_code in (
        'job_principal_unassigned','job_principal_assigned','job_principal_dispute_held',
        'worker_earnings_available','worker_withdrawal_reserved','poster_refund_payable'
      )),0)::numeric
    into v_cash,v_reserve,v_protected
    from app_private.ledger_accounts a left join app_private.ledger_account_balances b using(account_id);
    select coalesce(sum(-b.balance_kobo),0)::numeric into v_unsettled_protected
    from app_private.ledger_account_balances b
    join app_private.ledger_accounts la using(account_id)
    join app_private.principal_allocations pa on pa.allocation_id=b.allocation_id
    join app_private.funding_attempts fa using(funding_intent_id)
    where la.account_code in (
      'job_principal_unassigned','job_principal_assigned','job_principal_dispute_held',
      'worker_earnings_available','worker_withdrawal_reserved','poster_refund_payable'
    ) and b.balance_kobo<0 and fa.status='succeeded'
      and fa.settlement_status is distinct from 'available';
    v_secured_protected:=greatest(0,v_protected-v_unsettled_protected);
    select coalesce((select sum(w.fee_reserve_transferred_kobo)::numeric
      from app_private.withdrawal_requests w where w.status in ('processing','unknown','exception')),0)
      +coalesce((select sum(m.expected_provider_fee_kobo)::numeric
        from app_private.allocation_refund_progress p
        join app_private.refund_operation_mappings m on m.operation_id=p.operation_id
        where p.status in ('processing','unknown','exception')),0)
    into v_active_fees;
    select coalesce(sum(b.balance_kobo) filter(where a.account_code in (
      'provider_processing_fee_expense','provider_payout_fee_expense','provider_refund_fee_expense'
    )),0)::numeric into v_fee_allowance
    from app_private.ledger_accounts a left join app_private.ledger_account_balances b using(account_id);
    v_gap:=greatest(0,v_secured_protected+
      v_mapping.expected_provider_fee_kobo::numeric+v_active_fees-v_cash::numeric);
    -- Only recorded platform provider fees and unresolved provider fee
    -- obligations can justify drawing reserves; reserves cannot fill a
    -- principal shortage from an unsettled or unrelated source.
    if v_gap>v_reserve or
       v_gap>v_fee_allowance+v_active_fees+v_mapping.expected_provider_fee_kobo::numeric then
      continue;
    end if;
    if v_gap>0 then
      perform app_private.post_financial_journal(
        v_mapping.fee_reserve_effect_id,'platform_fee_reserve_transfer',v_progress.refund_payable_id,null,
        pg_catalog.jsonb_build_array(
          pg_catalog.jsonb_build_object('account_code','provider_available_cash','direction','debit','amount_kobo',v_gap::text),
          pg_catalog.jsonb_build_object('account_code','platform_fee_reserve_cash','direction','credit','amount_kobo',v_gap::text)
        ));
    end if;
    update app_private.allocation_refund_progress set status='processing',
      fee_reserve_transferred_kobo=v_gap::bigint,safe_error_code=null
    where refund_payable_id=v_progress.refund_payable_id;
    update app_private.provider_operations set status='processing'
      where operation_id=v_mapping.operation_id and status='queued_for_liquidity';
    perform app_private.record_refund_status_event(v_progress.refund_payable_id,v_mapping.operation_id,'processing');
    v_started:=v_started+1;
  end loop;
  return v_started;
end;
$function$;

-- Payouts and refunds share the same cash protection lock. Refund payables and
-- already reserved refund fees remain unavailable to worker withdrawals.
create or replace function app_private.try_start_queued_payouts_for_liquidity()
returns integer language plpgsql security definer set search_path = '' as $function$
declare
  v_request app_private.withdrawal_requests%rowtype;
  v_operation app_private.provider_operations%rowtype;
  v_cash bigint; v_reserve bigint; v_other_protected bigint; v_available bigint; v_gap bigint;
  v_active_refund_fees bigint; v_started integer:=0;
begin
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('nbd:payment-liquidity',0));
  for v_request in select * from app_private.withdrawal_requests
    where status='queued_for_liquidity' order by created_at,withdrawal_id for update skip locked
  loop
    select * into v_operation from app_private.provider_operations
      where operation_id=v_request.operation_id for update;
    select coalesce(sum(b.balance_kobo) filter(where a.account_code='provider_available_cash'),0)::bigint,
      coalesce(sum(b.balance_kobo) filter(where a.account_code='platform_fee_reserve_cash'),0)::bigint,
      coalesce(-sum(b.balance_kobo) filter(where a.account_code in (
        'job_principal_unassigned','job_principal_assigned','job_principal_dispute_held',
        'worker_earnings_available','worker_withdrawal_reserved','poster_refund_payable'
      )),0)::bigint into v_cash,v_reserve,v_other_protected
    from app_private.ledger_accounts a left join app_private.ledger_account_balances b using(account_id);
    v_other_protected:=greatest(0,v_other_protected-v_request.amount_kobo);
    v_other_protected:=v_other_protected+coalesce((select sum(w.fee_reserve_transferred_kobo)::bigint
      from app_private.withdrawal_requests w where w.status in ('processing','unknown','exception')
        and w.withdrawal_id<>v_request.withdrawal_id),0);
    select coalesce(sum(m.expected_provider_fee_kobo),0)::bigint into v_active_refund_fees
      from app_private.allocation_refund_progress p
      join app_private.refund_operation_mappings m on m.operation_id=p.operation_id
      where p.status in ('processing','unknown','exception');
    v_other_protected:=v_other_protected+v_active_refund_fees;
    v_available:=v_cash-v_other_protected;
    if v_available<v_request.amount_kobo
       or v_available+v_reserve<v_request.amount_kobo+v_request.expected_provider_fee_kobo then continue; end if;
    v_gap:=greatest(0,v_request.amount_kobo+v_request.expected_provider_fee_kobo-v_available);
    if v_gap>v_reserve then continue; end if;
    if v_gap>0 then
      perform app_private.post_financial_journal(v_operation.operation_id,
        'platform_fee_reserve_transfer',v_request.withdrawal_id,null,pg_catalog.jsonb_build_array(
          pg_catalog.jsonb_build_object('account_code','provider_available_cash','direction','debit','amount_kobo',v_gap::text),
          pg_catalog.jsonb_build_object('account_code','platform_fee_reserve_cash','direction','credit','amount_kobo',v_gap::text)));
    end if;
    update app_private.withdrawal_requests set status='processing',fee_reserve_transferred_kobo=v_gap
      where withdrawal_id=v_request.withdrawal_id;
    update app_private.provider_operations set status='processing' where operation_id=v_operation.operation_id;
    perform app_private.audit_wallet_event(null,'withdrawal_status_changed',v_request.withdrawal_id,
      pg_catalog.jsonb_build_object('status','processing'));
    v_started:=v_started+1;
  end loop;
  return v_started;
end;
$function$;

create or replace function app_private.claim_payment_operation_job(
  p_worker_id uuid,p_lease_seconds smallint default 30
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_job app_private.payment_operation_jobs%rowtype;
  v_operation app_private.provider_operations%rowtype;
  v_refund app_private.refund_operation_mappings%rowtype;
begin
  if p_worker_id is null or p_lease_seconds not between 5 and 120 then
    raise exception using errcode='22023',message='invalid_payment_job_claim';
  end if;
  update app_private.payment_operation_jobs
  set state='exhausted',lease_token=null,lease_owner=null,lease_expires_at=null,
      last_safe_error_code=coalesce(last_safe_error_code,'provider_timeout')
  where state='leased' and lease_expires_at<=pg_catalog.now() and attempt_count>=max_attempts;
  update app_private.provider_operations o set status='unknown',safe_error_code='provider_timeout'
  where o.operation_id in (select j.operation_id from app_private.payment_operation_jobs j
    where j.state='exhausted' and j.last_safe_error_code='provider_timeout')
    and o.status in ('pending','processing','unknown');
  select j.* into v_job from app_private.payment_operation_jobs j
  join app_private.provider_operations o using(operation_id)
  where ((j.state in ('queued','retry') and j.available_at<=pg_catalog.now()) or
    (j.state='leased' and j.lease_expires_at<=pg_catalog.now() and j.attempt_count<j.max_attempts))
    and o.provider_adapter='local_simulator'
    and o.operation_type in ('collection','payout','refund')
    and o.status<>'queued_for_liquidity'
  order by j.available_at,j.created_at,j.job_id for update of j skip locked limit 1;
  if not found then return null; end if;
  update app_private.payment_operation_jobs
  set state='leased',attempt_count=attempt_count+1,lease_token=pg_catalog.gen_random_uuid(),
    lease_owner=p_worker_id,lease_expires_at=pg_catalog.now()+pg_catalog.make_interval(secs=>p_lease_seconds)
  where job_id=v_job.job_id returning * into v_job;
  select * into v_operation from app_private.provider_operations where operation_id=v_job.operation_id;
  if v_operation.operation_type='refund' then
    select * into v_refund from app_private.refund_operation_mappings where operation_id=v_operation.operation_id;
    if not found then raise exception using errcode='23514',message='refund_authorization_mapping_missing'; end if;
  end if;
  return pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
    'job_id',v_job.job_id,'lease_token',v_job.lease_token,'attempt_count',v_job.attempt_count,
    'operation_id',v_operation.operation_id,'operation_type',v_operation.operation_type,
    'provider_operation_reference',v_operation.provider_operation_reference,
    'provider_idempotency_key',v_operation.provider_idempotency_key,
    'amount_kobo',v_operation.amount_kobo::text,'currency',v_operation.currency,
    'destination_id',v_operation.destination_id,'destination_version',v_operation.destination_version,
    'source_provider_reference',v_refund.original_provider_reference,
    'expected_provider_fee_kobo',v_refund.expected_provider_fee_kobo::text
  ));
end;
$function$;

create or replace function public.server_claim_payment_operation_for_runner(
  p_worker_id uuid,p_lease_seconds smallint default 30
) returns jsonb language plpgsql security definer set search_path = '' as $function$
begin
  perform app_private.try_start_queued_payouts_for_liquidity();
  perform app_private.try_start_queued_refunds_for_liquidity();
  return app_private.claim_payment_operation_job(p_worker_id,p_lease_seconds);
end;
$function$;

create function app_private.complete_local_refund_for_runner(
  p_operation_id uuid,p_lease_token uuid,p_status text,p_provider_reference text,
  p_amount_kobo text,p_currency text,p_client_reference uuid,p_source_provider_reference text,
  p_fee_kobo text,p_settlement_status text,p_safe_error_code text,p_retry boolean,
  p_result_sha256_hex text
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_operation app_private.provider_operations%rowtype;
  v_mapping app_private.refund_operation_mappings%rowtype;
  v_progress app_private.allocation_refund_progress%rowtype;
  v_payable app_private.allocation_refund_payables%rowtype;
  v_job app_private.payment_operation_jobs%rowtype;
  v_status text:=p_status; v_error text:=p_safe_error_code;
  v_final_state text; v_journal uuid; v_entries jsonb:='[]'::jsonb;
  v_status_changed boolean:=false; v_fee bigint;
begin
  select * into v_job from app_private.payment_operation_jobs
  where operation_id=p_operation_id for update;
  if not found or v_job.state<>'leased' or v_job.lease_token is distinct from p_lease_token
     or v_job.lease_expires_at<=pg_catalog.now() then
    raise exception using errcode='40001',message='payment_job_lease_lost';
  end if;
  select * into v_operation from app_private.provider_operations
  where operation_id=p_operation_id and operation_type='refund'
    and provider_adapter='local_simulator' for update;
  if not found then raise exception using errcode='22023',message='refund_operation_not_found'; end if;
  select * into v_mapping from app_private.refund_operation_mappings
  where operation_id=p_operation_id for update;
  if not found then raise exception using errcode='23514',message='refund_authorization_mapping_missing'; end if;
  select * into v_progress from app_private.allocation_refund_progress
  where refund_payable_id=v_mapping.refund_payable_id for update;
  select * into v_payable from app_private.allocation_refund_payables
  where refund_payable_id=v_mapping.refund_payable_id;
  if p_status not in ('processing','unknown','settled','failed','reversed','exception')
     or p_retry is null or (p_status in ('processing','unknown') and not p_retry)
     or (p_status in ('settled','failed','reversed','exception') and p_retry)
     or (p_safe_error_code is not null and p_safe_error_code not in (
       'provider_timeout','provider_unavailable','amount_mismatch','currency_mismatch',
       'reference_mismatch','unknown_result','settlement_pending')) then
    raise exception using errcode='22023',message='invalid_refund_operation_result';
  end if;

  if p_status in ('processing','settled','failed','reversed') or
     (p_status='unknown' and p_provider_reference is not null) then
    if p_provider_reference is distinct from 'sim-'||v_operation.provider_idempotency_key::text
       or p_client_reference is distinct from v_operation.provider_idempotency_key
       or p_source_provider_reference is distinct from v_mapping.original_provider_reference then
      v_status:='exception';v_error:='reference_mismatch';
    elsif p_amount_kobo is null or p_amount_kobo !~ '^[1-9][0-9]{0,11}$'
       or p_amount_kobo::numeric<>v_mapping.amount_kobo::numeric then
      v_status:='exception';v_error:='amount_mismatch';
    elsif p_currency is distinct from 'NGN' then
      v_status:='exception';v_error:='currency_mismatch';
    elsif p_fee_kobo is null or p_fee_kobo !~ '^(0|[1-9][0-9]{0,11})$'
       or p_fee_kobo::numeric<>v_mapping.expected_provider_fee_kobo::numeric then
      v_status:='exception';v_error:='amount_mismatch';
    elsif p_result_sha256_hex is null or p_result_sha256_hex !~ '^[0-9a-f]{64}$' then
      v_status:='exception';v_error:='unknown_result';
    elsif p_status='settled' and p_settlement_status is distinct from 'available' then
      v_status:='exception';v_error:='settlement_pending';
    end if;
  end if;
  if v_status='reversed' and v_progress.status not in ('settled','reversed') then
    v_status:='exception';v_error:='unknown_result';
  end if;
  if v_status='exception' then p_retry:=false; end if;
  if v_status in ('processing','unknown') and not p_retry then
    raise exception using errcode='22023',message='invalid_refund_operation_result';
  end if;
  if p_fee_kobo is not null and p_fee_kobo ~ '^(0|[1-9][0-9]{0,11})$'
     and p_fee_kobo::numeric<=1000000000 then v_fee:=p_fee_kobo::bigint; end if;

  if (v_progress.status='settled' and v_status not in ('settled','reversed')) or
     (v_progress.status='reversed' and v_status<>'reversed') then
    if not exists(select 1 from app_private.financial_exceptions
      where operation_id=p_operation_id and exception_type='unknown_result') then
      insert into app_private.financial_exceptions(operation_id,exception_type,safe_reference)
      values(p_operation_id,'unknown_result',left(coalesce(p_provider_reference,''),180));
    end if;
    update app_private.payment_operation_jobs set state='complete',lease_token=null,
      lease_owner=null,lease_expires_at=null,last_safe_error_code='unknown_result'
      where job_id=v_job.job_id;
    perform app_private.record_refund_status_event(
      v_payable.refund_payable_id,p_operation_id,'exception','unknown_result');
    return pg_catalog.jsonb_build_object('operation_id',p_operation_id,'operation_status','exception',
      'refund_status',v_progress.status,'safe_error_code','unknown_result',
      'conflicting_result',true,'amount_kobo',v_mapping.amount_kobo::text,
      'fee_treatment','platform_expense','settlement_confirmed',v_progress.status='settled',
      'bank_receipt_confirmed',false,'reversal_review_required',v_progress.status='reversed');
  end if;

  if v_status='exception' then
    insert into app_private.financial_exceptions(operation_id,exception_type,safe_reference)
    values(p_operation_id,case v_error
      when 'amount_mismatch' then 'amount_mismatch'
      when 'currency_mismatch' then 'currency_mismatch'
      when 'reference_mismatch' then 'reference_mismatch'
      else 'unknown_result' end,left(coalesce(p_provider_reference,''),180));
  elsif p_provider_reference is not null
    and p_provider_reference='sim-'||v_operation.provider_idempotency_key::text then
    update app_private.provider_operations set provider_operation_reference=p_provider_reference,
      fee_kobo=case when v_fee is null then fee_kobo else v_fee end,
      status=v_status,safe_error_code=v_error where operation_id=p_operation_id;
  else
    update app_private.provider_operations set status=v_status,safe_error_code=v_error
      where operation_id=p_operation_id;
  end if;

  if p_retry and v_job.attempt_count<v_job.max_attempts then v_final_state:='retry';
  elsif p_retry then v_final_state:='exhausted'; else v_final_state:='complete'; end if;
  update app_private.payment_operation_jobs set state=v_final_state,
    available_at=case when v_final_state='retry' then pg_catalog.now()+
      pg_catalog.make_interval(secs=>least(60,power(2,v_job.attempt_count)::integer)) else available_at end,
    lease_token=null,lease_owner=null,lease_expires_at=null,last_safe_error_code=v_error
  where job_id=v_job.job_id;

  if v_status in ('processing','unknown','failed','exception') then
    if v_progress.status is distinct from v_status then
      update app_private.allocation_refund_progress set status=v_status,safe_error_code=v_error
        where refund_payable_id=v_progress.refund_payable_id;
      v_status_changed:=true;
    end if;
    if v_status='failed' and coalesce(v_fee,0)>0
       and not exists(select 1 from app_private.ledger_journal_transactions
         where effect_key=v_mapping.failed_fee_effect_id) then
      perform app_private.post_financial_journal(v_mapping.failed_fee_effect_id,
        'provider_refund_fee_charged',v_payable.refund_payable_id,null,pg_catalog.jsonb_build_array(
          pg_catalog.jsonb_build_object('account_code','provider_refund_fee_expense','direction','debit','amount_kobo',v_fee::text),
          pg_catalog.jsonb_build_object('account_code','provider_available_cash','direction','credit','amount_kobo',v_fee::text)));
    end if;
  elsif v_status='settled' and v_progress.status<>'settled' then
    v_entries:=pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('account_code','poster_refund_payable','direction','debit',
        'amount_kobo',v_mapping.amount_kobo::text,'allocation_id',v_mapping.allocation_id::text,'owner_id',v_payable.poster_id::text));
    if v_mapping.expected_provider_fee_kobo>0 then
      v_entries:=v_entries||pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
        'account_code','provider_refund_fee_expense','direction','debit',
        'amount_kobo',v_mapping.expected_provider_fee_kobo::text));
    end if;
    v_entries:=v_entries||pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'account_code','provider_available_cash','direction','credit',
      'amount_kobo',(v_mapping.amount_kobo::numeric+v_mapping.expected_provider_fee_kobo::numeric)::text));
    v_journal:=app_private.post_financial_journal(v_mapping.settlement_effect_id,
      'provider_refund_settled',v_payable.refund_payable_id,null,v_entries);
    insert into app_private.provider_refund_settlement_records(
      operation_id,refund_payable_id,settlement_effect_id,journal_id,principal_kobo,fee_kobo,
      original_provider_reference,provider_refund_reference
    ) values(p_operation_id,v_payable.refund_payable_id,v_mapping.settlement_effect_id,
      v_journal,v_mapping.amount_kobo,v_mapping.expected_provider_fee_kobo,
      v_mapping.original_provider_reference,p_provider_reference);
    update app_private.allocation_refund_progress set status='settled',safe_error_code=null,
      settled_at=pg_catalog.now() where refund_payable_id=v_progress.refund_payable_id;
    v_status_changed:=true;
  elsif v_status='reversed' then
    insert into app_private.refund_reversal_incidents(
      operation_id,refund_payable_id,amount_kobo,provider_reference
    ) values(p_operation_id,v_payable.refund_payable_id,v_mapping.amount_kobo,
      coalesce(p_provider_reference,v_operation.provider_operation_reference))
    on conflict(operation_id) do nothing;
    if v_progress.status<>'reversed' then
      update app_private.allocation_refund_progress set status='reversed',safe_error_code=null
        where refund_payable_id=v_progress.refund_payable_id;
      v_status_changed:=true;
    end if;
  end if;
  if v_status_changed then
    perform app_private.record_refund_status_event(v_payable.refund_payable_id,p_operation_id,v_status,v_error);
  end if;
  return pg_catalog.jsonb_build_object('operation_id',p_operation_id,'operation_status',v_status,
    'refund_status',v_status,'job_state',v_final_state,'amount_kobo',v_mapping.amount_kobo::text,
    'fee_treatment','platform_expense','settlement_confirmed',v_status='settled',
    'bank_receipt_confirmed',false,'reversal_review_required',v_status='reversed');
end;
$function$;

create function public.server_complete_refund_operation_for_runner(
  p_operation_id uuid,p_lease_token uuid,p_status text,p_provider_reference text,
  p_amount_kobo text,p_currency text,p_client_reference uuid,p_source_provider_reference text,
  p_fee_kobo text,p_settlement_status text,p_safe_error_code text,p_retry boolean,
  p_result_sha256_hex text
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.complete_local_refund_for_runner($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)
$function$;

create or replace function app_private.get_my_wallet_for_actor(
  p_actor uuid,p_before_created_at timestamptz,p_before_id uuid
) returns jsonb language plpgsql stable security definer set search_path = '' as $function$
declare v_result jsonb; v_total numeric; v_refunds jsonb;
begin
  v_result:=app_private.get_my_wallet_for_actor_before_refund_payables(
    p_actor,p_before_created_at,p_before_id);
  select coalesce(sum(p.amount_kobo) filter(where p.status not in ('settled','reversed')),0)::numeric
    into v_total from app_private.allocation_refund_progress p where p.poster_id=p_actor;
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'refund_payable_id',q.refund_payable_id,'allocation_id',q.allocation_id,
    'amount_kobo',q.amount_kobo::text,'status',q.status,'source',q.source,
    'updated_at',q.updated_at,'simulator_only',true,
    'reversal_review_required',q.status='reversed'
  ) order by q.created_at desc,q.refund_payable_id desc),'[]'::jsonb)
  into v_refunds from (
    select r.refund_payable_id,r.allocation_id,r.amount_kobo,r.source,p.status,p.updated_at,r.created_at
    from app_private.allocation_refund_payables r
    join app_private.allocation_refund_progress p using(refund_payable_id)
    where r.poster_id=p_actor order by r.created_at desc,r.refund_payable_id desc limit 20
  ) q;
  return v_result||pg_catalog.jsonb_build_object(
    'balances',(v_result->'balances')||pg_catalog.jsonb_build_object('poster_refund_payable_kobo',v_total::text),
    'refunds',v_refunds,'refund_payables',v_refunds
  );
end;
$function$;

create or replace function public.server_get_my_wallet_for_actor(
  p_actor uuid,p_before_created_at timestamptz,p_before_id uuid
) returns jsonb language sql stable security definer set search_path = '' as $function$
  select app_private.get_my_wallet_for_actor($1,$2,$3)
$function$;

create or replace function app_private.get_assignment_case_for_actor(p_actor uuid,p_case_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare v_result jsonb; v_appeal jsonb; v_role text; v_finalization jsonb;
begin
  if p_actor is null or p_case_id is null then
    raise exception using errcode='22023',message='invalid_case_query';
  end if;
  v_result:=app_private.case_participant_projection(p_case_id,p_actor);
  if v_result is null then raise exception using errcode='P0002',message='case_not_found'; end if;
  select case when a.worker_id=p_actor then 'worker' else 'poster' end into v_role
    from app_private.assignment_cases c join app_private.assignments a using(assignment_id)
    where c.case_id=p_case_id;
  v_result:=v_result||app_private.case_investigation_projection(p_case_id,p_actor,false)||
    pg_catalog.jsonb_build_object('participant_role',v_role);
  v_appeal:=app_private.case_appeal_participant_projection(p_case_id,p_actor);
  if v_appeal is not null then
    v_result:=v_result||pg_catalog.jsonb_build_object('appeal',v_appeal);
    if v_appeal->>'status'='under_review' then
      v_result:=v_result||pg_catalog.jsonb_build_object('status','appeal');
    end if;
  end if;
  select pg_catalog.jsonb_build_object(
    'status','executed','decision_version',f.decision_version,'outcome',f.outcome,
    'gross_principal_kobo',f.gross_principal_kobo::text,
    'worker_award_gross_kobo',f.worker_award_gross_kobo::text,
    'poster_refund_gross_kobo',f.poster_refund_gross_kobo::text,
    'retained_hold_gross_kobo',f.retained_hold_gross_kobo::text,
    'commission_kobo',f.commission_kobo::text,'worker_net_kobo',f.worker_net_kobo::text,
    'refund_status',case when f.refund_payable_id is null then 'not_applicable'
      else coalesce((select p.status from app_private.allocation_refund_progress p
        where p.refund_payable_id=f.refund_payable_id),'authorized') end,
    'refund_settled_at',(select p.settled_at::text from app_private.allocation_refund_progress p
      where p.refund_payable_id=f.refund_payable_id),
    'executed_at',f.executed_at
  ) into v_finalization from app_private.assignment_case_finalizations f where f.case_id=p_case_id;
  v_result:=v_result||pg_catalog.jsonb_build_object('finalization',v_finalization);
  return v_result;
end;
$function$;

do $reconciliation_patch$
declare
  v_definition text;
  v_old text:='v_finding_count:=pg_catalog.jsonb_array_length(v_findings);';
  v_new text;
begin
  v_definition:=pg_catalog.pg_get_functiondef(
    'app_private.reconcile_financial_state_for_actor(uuid,text,text,text)'::regprocedure);
  if pg_catalog.strpos(v_definition,v_old)=0 then
    raise exception 'refund_incident_reconciliation_patch_mismatch';
  end if;
  v_new:='for v_row in select i.operation_id,i.amount_kobo,i.status from app_private.refund_reversal_incidents i where i.status=''open'' order by i.created_at limit 100 loop v_findings:=v_findings||pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(''code'',''refund_reversal_open'',''reference_id'',v_row.operation_id,''expected'',''compensating_incident_review'',''observed'',v_row.status,''data'',pg_catalog.jsonb_build_object(''amount_kobo'',v_row.amount_kobo::text))); end loop; v_finding_count:=pg_catalog.jsonb_array_length(v_findings);';
  execute pg_catalog.replace(v_definition,v_old,v_new);
end;
$reconciliation_patch$;

alter table app_private.financial_reconciliation_findings
  drop constraint financial_reconciliation_findings_finding_code_check,
  add constraint financial_reconciliation_findings_finding_code_check check (finding_code in (
    'projection_balance_mismatch','simulator_cash_mismatch','simulator_receivable_mismatch',
    'unresolved_operation','held_liability_mismatch','audit_chain_mismatch','refund_reversal_open'
  ));

revoke all on table app_private.allocation_refund_progress,app_private.refund_operation_mappings,
  app_private.refund_reversal_incidents,app_private.local_refund_fee_policy,
  app_private.provider_refund_settlement_records from public,anon,authenticated,service_role;
revoke all on function app_private.guard_refund_progress_change(),
  app_private.guard_refund_operation_mapping(),app_private.create_refund_progress_for_payable(),
  app_private.record_refund_status_event(uuid,uuid,text,text),
  app_private.prepare_local_refund_operations(),app_private.try_start_queued_refunds_for_liquidity(),
  app_private.complete_local_refund_for_runner(uuid,uuid,text,text,text,text,uuid,text,text,text,text,boolean,text),
  app_private.get_my_wallet_for_actor(uuid,timestamptz,uuid) from public,anon,authenticated,service_role;
revoke all on function app_private.claim_payment_operation_job(uuid,smallint) from public,anon,authenticated,service_role;
grant execute on function app_private.claim_payment_operation_job(uuid,smallint) to postgres;
revoke all on function public.server_complete_refund_operation_for_runner(
  uuid,uuid,text,text,text,text,uuid,text,text,text,text,boolean,text
) from public,anon,authenticated,service_role;
grant execute on function public.server_complete_refund_operation_for_runner(
  uuid,uuid,text,text,text,text,uuid,text,text,text,text,boolean,text
) to service_role;
grant execute on function app_private.prepare_local_refund_operations(),
  app_private.try_start_queued_refunds_for_liquidity() to postgres;

commit;
