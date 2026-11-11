begin;

-- Reserve a distinct read-only inspection grant. No staff member receives it
-- here, and no financial outcome or approval command is added by this change.
alter table app_private.staff_grants drop constraint staff_grants_capability_check;
alter table app_private.staff_grants add constraint staff_grants_capability_check
  check (capability in (
    'verification_review', 'identity_suspend', 'identity_unsuspend',
    'identity_correct_user_type', 'identity_staff_admin', 'dispute_review',
    'financial_initiate', 'financial_approve', 'financial_inspect'
  ));

create table app_private.ledger_policy (
  policy_name text primary key check (policy_name = 'ordinary_completion'),
  commission_basis_points smallint not null check (commission_basis_points = 500),
  rounding_rule text not null check (rounding_rule = 'half_up'),
  updated_at timestamptz not null default pg_catalog.now()
);
insert into app_private.ledger_policy(policy_name,commission_basis_points,rounding_rule)
values ('ordinary_completion',500,'half_up');

create table app_private.ledger_accounts (
  account_id uuid primary key default pg_catalog.gen_random_uuid(),
  account_code text not null unique,
  account_class text not null check (account_class in ('asset','liability','equity','income','expense')),
  normal_side text not null check (normal_side in ('debit','credit')),
  dimension_scope text not null check (dimension_scope in ('none','allocation','allocation_owner')),
  created_at timestamptz not null default pg_catalog.now(),
  check (
    (account_class in ('asset','expense') and normal_side='debit') or
    (account_class in ('liability','equity','income') and normal_side='credit')
  )
);
insert into app_private.ledger_accounts(account_code,account_class,normal_side,dimension_scope) values
  ('provider_collection_receivable','asset','debit','none'),
  ('provider_available_cash','asset','debit','none'),
  ('platform_fee_reserve_cash','asset','debit','none'),
  ('job_principal_unassigned','liability','credit','allocation'),
  ('job_principal_assigned','liability','credit','allocation'),
  ('job_principal_dispute_held','liability','credit','allocation'),
  ('worker_earnings_available','liability','credit','allocation_owner'),
  ('worker_withdrawal_reserved','liability','credit','allocation_owner'),
  ('poster_refund_payable','liability','credit','allocation_owner'),
  ('platform_capital_contributed','equity','credit','none'),
  ('platform_commission_revenue','income','credit','allocation'),
  ('provider_processing_fee_expense','expense','debit','none'),
  ('provider_payout_fee_expense','expense','debit','none'),
  ('provider_refund_fee_expense','expense','debit','none'),
  ('provider_delivery_fee_expense','expense','debit','none'),
  ('provider_chargeback_loss_expense','expense','debit','none');

create table app_private.funding_intents (
  intent_id uuid primary key default pg_catalog.gen_random_uuid(),
  poster_id uuid not null references auth.users(id) on delete restrict,
  job_id uuid not null,
  terms_version integer not null check (terms_version > 0),
  gross_per_worker_kobo bigint not null check (gross_per_worker_kobo between 1 and 100000000),
  slot_count smallint not null check (slot_count between 1 and 10),
  gross_total_kobo bigint not null check (gross_total_kobo between 1 and 1000000000),
  currency text not null check (currency = 'NGN'),
  status text not null check (status in ('pending','unknown','succeeded','failed','cancelled','exception')),
  idempotency_key uuid not null,
  request_sha256 bytea not null check (pg_catalog.octet_length(request_sha256)=32),
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  unique (poster_id,idempotency_key),
  unique (job_id,terms_version),
  check (gross_total_kobo::numeric = gross_per_worker_kobo::numeric * slot_count)
);

create table app_private.provider_operations (
  operation_id uuid primary key default pg_catalog.gen_random_uuid(),
  operation_type text not null check (operation_type in ('collection','payout','refund')),
  provider_adapter text,
  provider_operation_reference text,
  provider_idempotency_key uuid not null unique,
  actor_id uuid references auth.users(id) on delete restrict,
  funding_intent_id uuid references app_private.funding_intents(intent_id) on delete restrict,
  allocation_id uuid,
  amount_kobo bigint not null check (amount_kobo > 0),
  fee_kobo bigint not null default 0 check (fee_kobo >= 0),
  currency text not null check (currency = 'NGN'),
  destination_id uuid,
  destination_version integer,
  request_sha256 bytea not null check (pg_catalog.octet_length(request_sha256)=32),
  status text not null check (status in (
    'queued_for_liquidity','pending','processing','unknown','succeeded','settled',
    'failed','cancelled','paid','reversed','exception'
  )),
  safe_error_code text,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  check ((destination_id is null) = (destination_version is null)),
  check (destination_version is null or destination_version > 0),
  check (operation_type <> 'collection' or funding_intent_id is not null),
  check (operation_type <> 'payout' or (destination_id is not null and destination_version is not null)),
  check (safe_error_code is null or safe_error_code in (
    'provider_unavailable','provider_timeout','amount_mismatch','currency_mismatch',
    'reference_mismatch','settlement_pending','destination_unavailable','unknown_result'
  )),
  unique (provider_adapter,provider_operation_reference)
);

create table app_private.funding_attempts (
  attempt_id uuid primary key default pg_catalog.gen_random_uuid(),
  funding_intent_id uuid not null references app_private.funding_intents(intent_id) on delete restrict,
  operation_id uuid unique references app_private.provider_operations(operation_id) on delete restrict,
  attempt_number smallint not null check (attempt_number > 0),
  status text not null check (status in ('pending','unknown','succeeded','failed','cancelled','exception')),
  collected_gross_kobo bigint check (collected_gross_kobo > 0),
  provider_fee_kobo bigint check (provider_fee_kobo >= 0),
  provider_net_kobo bigint check (provider_net_kobo >= 0),
  currency text check (currency = 'NGN'),
  settlement_status text check (settlement_status in ('pending','available','unknown')),
  provider_event_reference text,
  result_sha256 bytea check (result_sha256 is null or pg_catalog.octet_length(result_sha256)=32),
  created_at timestamptz not null default pg_catalog.now(),
  unique (funding_intent_id,attempt_number),
  check (
    status <> 'succeeded' or
    (collected_gross_kobo is not null and provider_fee_kobo is not null and
     provider_net_kobo is not null and collected_gross_kobo::numeric = provider_fee_kobo::numeric + provider_net_kobo::numeric and
     currency is not null and settlement_status is not null and result_sha256 is not null)
  )
);
create unique index funding_attempts_one_success_per_intent
  on app_private.funding_attempts(funding_intent_id) where status='succeeded';

create table app_private.principal_allocations (
  allocation_id uuid primary key default pg_catalog.gen_random_uuid(),
  funding_intent_id uuid not null references app_private.funding_intents(intent_id) on delete restrict,
  job_id uuid not null,
  poster_id uuid not null references auth.users(id) on delete restrict,
  slot_number smallint not null check (slot_number between 1 and 10),
  gross_principal_kobo bigint not null check (gross_principal_kobo between 1 and 100000000),
  commission_basis_points smallint not null check (commission_basis_points = 500),
  assignment_id uuid,
  status text not null check (status in ('unassigned','assigned','dispute_held','worker_earnings_allocated')),
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  unique (funding_intent_id,slot_number),
  unique (job_id,slot_number),
  unique (assignment_id),
  check ((status='unassigned' and assignment_id is null) or (status<>'unassigned' and assignment_id is not null))
);

alter table app_private.provider_operations
  add constraint provider_operations_allocation_fk
  foreign key (allocation_id) references app_private.principal_allocations(allocation_id) on delete restrict;

create table app_private.ledger_journal_transactions (
  journal_id uuid primary key default pg_catalog.gen_random_uuid(),
  effect_key uuid not null unique,
  effect_type text not null check (effect_type in (
    'funding_collected','provider_settlement','allocation_assigned','allocation_held',
    'completion_released','withdrawal_reserved','payout_settled','platform_fee_reserve_transfer',
    'provider_refund_settled','compensating_correction','platform_capital_contribution'
  )),
  reference_id uuid,
  actor_id uuid references auth.users(id) on delete restrict,
  request_sha256 bytea not null check (pg_catalog.octet_length(request_sha256)=32),
  entry_count smallint not null check (entry_count between 2 and 100),
  created_at timestamptz not null default pg_catalog.now()
);

create table app_private.ledger_journal_entries (
  entry_id uuid primary key default pg_catalog.gen_random_uuid(),
  journal_id uuid not null references app_private.ledger_journal_transactions(journal_id) on delete restrict,
  line_number smallint not null check (line_number > 0),
  account_id uuid not null references app_private.ledger_accounts(account_id) on delete restrict,
  direction text not null check (direction in ('debit','credit')),
  amount_kobo bigint not null check (amount_kobo > 0),
  allocation_id uuid references app_private.principal_allocations(allocation_id) on delete restrict,
  owner_id uuid references auth.users(id) on delete restrict,
  created_at timestamptz not null default pg_catalog.now(),
  unique (journal_id,line_number)
);

create table app_private.ledger_account_balances (
  account_id uuid not null references app_private.ledger_accounts(account_id) on delete restrict,
  owner_id uuid references auth.users(id) on delete restrict,
  allocation_id uuid references app_private.principal_allocations(allocation_id) on delete restrict,
  debit_kobo bigint not null default 0 check (debit_kobo >= 0),
  credit_kobo bigint not null default 0 check (credit_kobo >= 0),
  balance_kobo bigint generated always as (debit_kobo - credit_kobo) stored,
  updated_at timestamptz not null default pg_catalog.now(),
  unique nulls not distinct (account_id,owner_id,allocation_id)
);

create table app_private.financial_authorizations (
  authorization_id uuid primary key default pg_catalog.gen_random_uuid(),
  actor_id uuid not null references auth.users(id) on delete restrict,
  action text not null check (action in ('change_bank_destination','request_withdrawal')),
  amount_kobo bigint check (amount_kobo > 0),
  destination_id uuid not null,
  destination_version integer not null check (destination_version > 0),
  candidate_fingerprint_sha256 bytea check (
    candidate_fingerprint_sha256 is null or pg_catalog.octet_length(candidate_fingerprint_sha256)=32
  ),
  confirmation_method text not null check (confirmation_method='fresh_password'),
  proof_sha256 bytea not null check (pg_catalog.octet_length(proof_sha256)=32),
  created_at timestamptz not null default pg_catalog.now(),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  check (expires_at > created_at and expires_at <= created_at + interval '5 minutes'),
  check (consumed_at is null or (consumed_at >= created_at and consumed_at <= expires_at)),
  check (
    (action='request_withdrawal' and amount_kobo is not null and candidate_fingerprint_sha256 is null) or
    (action='change_bank_destination' and amount_kobo is null and candidate_fingerprint_sha256 is not null)
  ),
  unique (proof_sha256)
);

create table app_private.financial_command_idempotency (
  actor_id uuid not null references auth.users(id) on delete restrict,
  command_name text not null check (command_name in (
    'create_job_draft','update_job_draft','fund_job','apply_to_job','accept_application',
    'start_assignment','submit_assignment','confirm_completion','open_assignment_hold',
    'prepare_withdrawal_confirmation','request_withdrawal','prepare_bank_destination_change',
    'change_bank_destination'
  )),
  idempotency_key uuid not null,
  request_sha256 bytea not null check (pg_catalog.octet_length(request_sha256)=32),
  response_reference_id uuid,
  response_code text not null check (char_length(response_code) between 1 and 80),
  created_at timestamptz not null default pg_catalog.now(),
  primary key (actor_id,command_name,idempotency_key)
);

create table app_private.provider_webhook_receipts (
  receipt_id uuid primary key default pg_catalog.gen_random_uuid(),
  provider_adapter text not null,
  provider_event_reference text not null,
  operation_id uuid references app_private.provider_operations(operation_id) on delete restrict,
  payload_sha256 bytea not null check (pg_catalog.octet_length(payload_sha256)=32),
  received_at timestamptz not null default pg_catalog.now(),
  unique (provider_adapter,provider_event_reference)
);

create table app_private.financial_exceptions (
  exception_id uuid primary key default pg_catalog.gen_random_uuid(),
  operation_id uuid references app_private.provider_operations(operation_id) on delete restrict,
  funding_intent_id uuid references app_private.funding_intents(intent_id) on delete restrict,
  exception_type text not null check (exception_type in (
    'amount_mismatch','currency_mismatch','reference_mismatch','duplicate_collection',
    'unknown_result','settlement_mismatch','payout_mismatch','provider_unavailable','manual_reconciliation'
  )),
  safe_reference text,
  created_at timestamptz not null default pg_catalog.now(),
  check (operation_id is not null or funding_intent_id is not null)
);

create table app_private.financial_audit_events (
  event_id uuid primary key default pg_catalog.gen_random_uuid(),
  actor_id uuid references auth.users(id) on delete restrict,
  event_type text not null check (event_type in ('financial_journal_posted','financial_inspection')),
  journal_id uuid references app_private.ledger_journal_transactions(journal_id) on delete restrict,
  operation_id uuid references app_private.provider_operations(operation_id) on delete restrict,
  reference_id uuid,
  event_data jsonb not null default '{}'::jsonb check (pg_catalog.jsonb_typeof(event_data)='object'),
  created_at timestamptz not null default pg_catalog.now(),
  check (event_type <> 'financial_journal_posted' or journal_id is not null)
);

create table app_private.financial_outbox (
  event_id uuid primary key references app_private.financial_audit_events(event_id) on delete restrict,
  event_type text not null check (event_type in ('financial.journal_posted')),
  payload jsonb not null check (pg_catalog.jsonb_typeof(payload)='object'),
  delivery_state text not null default 'pending' check (delivery_state in ('pending','processing','delivered','failed')),
  attempt_count smallint not null default 0 check (attempt_count >= 0),
  available_at timestamptz not null default pg_catalog.now(),
  delivered_at timestamptz
);

create view app_private.provider_liquidity_snapshot as
select
  coalesce(sum(b.balance_kobo) filter (where a.account_code='provider_available_cash'),0)::numeric as cleared_cash_kobo,
  coalesce(sum(b.balance_kobo) filter (where a.account_code='platform_fee_reserve_cash'),0)::numeric as fee_reserve_kobo,
  coalesce(sum(b.balance_kobo) filter (where a.account_code='provider_collection_receivable'),0)::numeric as collection_receivable_kobo
from app_private.ledger_accounts a
left join app_private.ledger_account_balances b using(account_id);

create function app_private.reject_financial_history_mutation()
returns trigger language plpgsql set search_path = '' as $function$
begin
  raise exception using errcode='55000',message='financial_record_is_immutable';
end;
$function$;
revoke all on function app_private.reject_financial_history_mutation() from public,anon,authenticated,service_role;

create trigger ledger_accounts_immutable before update or delete on app_private.ledger_accounts
for each row execute function app_private.reject_financial_history_mutation();
create trigger ledger_policy_immutable before update or delete on app_private.ledger_policy
for each row execute function app_private.reject_financial_history_mutation();
create trigger ledger_journal_transactions_immutable before update or delete on app_private.ledger_journal_transactions
for each row execute function app_private.reject_financial_history_mutation();
create trigger ledger_journal_entries_immutable before update or delete on app_private.ledger_journal_entries
for each row execute function app_private.reject_financial_history_mutation();
create trigger provider_webhook_receipts_immutable before update or delete on app_private.provider_webhook_receipts
for each row execute function app_private.reject_financial_history_mutation();
create trigger financial_command_idempotency_immutable before update or delete on app_private.financial_command_idempotency
for each row execute function app_private.reject_financial_history_mutation();
create trigger financial_exceptions_immutable before update or delete on app_private.financial_exceptions
for each row execute function app_private.reject_financial_history_mutation();
create trigger financial_audit_events_immutable before update or delete on app_private.financial_audit_events
for each row execute function app_private.reject_financial_history_mutation();

create function app_private.guard_funding_attempt_change()
returns trigger language plpgsql set search_path = '' as $function$
declare
  v_operation app_private.provider_operations%rowtype;
begin
  if tg_op='DELETE' then
    raise exception using errcode='55000',message='funding_attempt_is_immutable';
  end if;
  if new.attempt_id is distinct from old.attempt_id
     or new.funding_intent_id is distinct from old.funding_intent_id
     or new.operation_id is distinct from old.operation_id
     or new.attempt_number is distinct from old.attempt_number
     or new.created_at is distinct from old.created_at
     or (old.collected_gross_kobo is not null and new.collected_gross_kobo is distinct from old.collected_gross_kobo)
     or (old.provider_fee_kobo is not null and new.provider_fee_kobo is distinct from old.provider_fee_kobo)
     or (old.provider_net_kobo is not null and new.provider_net_kobo is distinct from old.provider_net_kobo)
     or (old.currency is not null and new.currency is distinct from old.currency)
     or (old.provider_event_reference is not null and new.provider_event_reference is distinct from old.provider_event_reference)
     or (old.result_sha256 is not null and new.result_sha256 is distinct from old.result_sha256)
     or not (
       new.status=old.status or
       (old.status='pending' and new.status in ('unknown','succeeded','failed','cancelled','exception')) or
       (old.status='unknown' and new.status in ('succeeded','failed','cancelled','exception'))
     )
     or not (
       new.settlement_status is not distinct from old.settlement_status or
       (old.settlement_status is null and new.settlement_status in ('pending','unknown','available')) or
       (old.settlement_status='pending' and new.settlement_status in ('unknown','available')) or
       (old.settlement_status='unknown' and new.settlement_status='available')
     ) then
    raise exception using errcode='55000',message='funding_attempt_is_immutable';
  end if;
  if new.status='succeeded' then
    if new.operation_id is null or new.collected_gross_kobo is null
       or new.provider_fee_kobo is null or new.provider_net_kobo is null
       or new.currency is null or new.settlement_status is null or new.result_sha256 is null then
      raise exception using errcode='22023',message='funding_result_mismatch';
    end if;
    select * into v_operation from app_private.provider_operations where operation_id=new.operation_id;
    if not found or v_operation.funding_intent_id<>new.funding_intent_id
       or v_operation.amount_kobo<>new.collected_gross_kobo
       or v_operation.fee_kobo<>new.provider_fee_kobo
       or v_operation.currency<>new.currency
       or v_operation.status not in ('succeeded','settled') then
      raise exception using errcode='22023',message='funding_result_mismatch';
    end if;
  end if;
  return new;
end;
$function$;
revoke all on function app_private.guard_funding_attempt_change() from public,anon,authenticated,service_role;
create trigger funding_attempts_guard_change before update or delete on app_private.funding_attempts
for each row execute function app_private.guard_funding_attempt_change();

create function app_private.guard_funding_intent_change()
returns trigger language plpgsql set search_path = '' as $function$
begin
  if tg_op='INSERT' then
    if new.status<>'pending' then
      raise exception using errcode='55000',message='funding_intent_must_start_pending';
    end if;
    return new;
  end if;
  if tg_op='DELETE' then
    raise exception using errcode='55000',message='funding_intent_is_immutable';
  end if;
  if new.intent_id is distinct from old.intent_id
     or new.poster_id is distinct from old.poster_id
     or new.job_id is distinct from old.job_id
     or new.terms_version is distinct from old.terms_version
     or new.gross_per_worker_kobo is distinct from old.gross_per_worker_kobo
     or new.slot_count is distinct from old.slot_count
     or new.gross_total_kobo is distinct from old.gross_total_kobo
     or new.currency is distinct from old.currency
     or new.idempotency_key is distinct from old.idempotency_key
     or new.request_sha256 is distinct from old.request_sha256
     or new.created_at is distinct from old.created_at
     or not (
       (old.status='pending' and new.status in ('unknown','succeeded','failed','cancelled','exception')) or
       (old.status='unknown' and new.status in ('succeeded','failed','cancelled','exception'))
     ) then
    raise exception using errcode='55000',message='funding_intent_is_immutable';
  end if;
  if new.status='succeeded' and not exists(
    select 1 from app_private.funding_attempts a
    where a.funding_intent_id=old.intent_id and a.status='succeeded'
      and a.collected_gross_kobo=old.gross_total_kobo and a.currency=old.currency
      and exists(select 1 from app_private.ledger_journal_transactions j
        where j.effect_key=a.attempt_id and j.effect_type='funding_collected')
  ) then
    raise exception using errcode='22023',message='funding_result_mismatch';
  end if;
  if new.status='succeeded' and (
    (select count(*) from app_private.principal_allocations p where p.funding_intent_id=old.intent_id)<>old.slot_count or
    coalesce((select sum(p.gross_principal_kobo) from app_private.principal_allocations p
      where p.funding_intent_id=old.intent_id),0)<>old.gross_total_kobo
  ) then
    raise exception using errcode='22023',message='funding_result_mismatch';
  end if;
  new.updated_at:=pg_catalog.now();
  return new;
end;
$function$;
revoke all on function app_private.guard_funding_intent_change() from public,anon,authenticated,service_role;
create trigger funding_intents_guard_change before insert or update or delete on app_private.funding_intents
for each row execute function app_private.guard_funding_intent_change();

create function app_private.guard_funding_attempt_insert()
returns trigger language plpgsql set search_path = '' as $function$
declare
  v_intent app_private.funding_intents%rowtype;
  v_operation app_private.provider_operations%rowtype;
begin
  select * into v_intent from app_private.funding_intents where intent_id=new.funding_intent_id;
  if not found then raise exception using errcode='22023',message='funding_result_mismatch'; end if;
  if new.status='succeeded' then
    if new.operation_id is null or new.collected_gross_kobo is distinct from v_intent.gross_total_kobo
       or new.currency is distinct from v_intent.currency
       or new.provider_fee_kobo is null or new.provider_net_kobo is null
       or new.provider_fee_kobo::numeric+new.provider_net_kobo::numeric<>new.collected_gross_kobo::numeric
       or new.result_sha256 is null then
      raise exception using errcode='22023',message='funding_result_mismatch';
    end if;
    select * into v_operation from app_private.provider_operations where operation_id=new.operation_id;
    if not found or v_operation.operation_type<>'collection'
       or v_operation.funding_intent_id<>new.funding_intent_id
       or v_operation.amount_kobo<>new.collected_gross_kobo
       or v_operation.fee_kobo<>new.provider_fee_kobo
       or v_operation.currency<>new.currency
       or v_operation.status not in ('succeeded','settled') then
      raise exception using errcode='22023',message='funding_result_mismatch';
    end if;
  end if;
  return new;
end;
$function$;
revoke all on function app_private.guard_funding_attempt_insert() from public,anon,authenticated,service_role;
create trigger funding_attempts_guard_insert before insert on app_private.funding_attempts
for each row execute function app_private.guard_funding_attempt_insert();

create function app_private.guard_allocation_change()
returns trigger language plpgsql set search_path = '' as $function$
declare
  v_intent app_private.funding_intents%rowtype;
begin
  if tg_op='INSERT' then
    select * into v_intent from app_private.funding_intents where intent_id=new.funding_intent_id for key share;
    if not found or v_intent.status not in ('pending','unknown') or new.job_id<>v_intent.job_id
       or new.poster_id<>v_intent.poster_id or new.gross_principal_kobo<>v_intent.gross_per_worker_kobo
       or new.slot_number>v_intent.slot_count or new.status<>'unassigned' or new.assignment_id is not null
       or new.commission_basis_points<>500 or not exists(
         select 1 from app_private.funding_attempts a where a.funding_intent_id=v_intent.intent_id
           and a.status='succeeded' and a.collected_gross_kobo=v_intent.gross_total_kobo
           and a.currency=v_intent.currency
       ) then
      raise exception using errcode='22023',message='invalid_principal_allocation';
    end if;
    return new;
  end if;
  if tg_op='DELETE' then
    raise exception using errcode='55000',message='principal_allocation_is_immutable';
  end if;
  if new.allocation_id is distinct from old.allocation_id
     or new.funding_intent_id is distinct from old.funding_intent_id
     or new.job_id is distinct from old.job_id
     or new.poster_id is distinct from old.poster_id
     or new.slot_number is distinct from old.slot_number
     or new.gross_principal_kobo is distinct from old.gross_principal_kobo
     or new.commission_basis_points is distinct from old.commission_basis_points
     or new.created_at is distinct from old.created_at
     or not (
       (old.status='unassigned' and new.status='assigned' and old.assignment_id is null and new.assignment_id is not null) or
       (old.status='assigned' and new.status in ('dispute_held','worker_earnings_allocated') and new.assignment_id=old.assignment_id)
     ) then
    raise exception using errcode='55000',message='principal_allocation_is_immutable';
  end if;
  new.updated_at:=pg_catalog.now();
  return new;
end;
$function$;
revoke all on function app_private.guard_allocation_change() from public,anon,authenticated,service_role;
create trigger principal_allocations_guard_change before insert or update or delete on app_private.principal_allocations
for each row execute function app_private.guard_allocation_change();

create function app_private.guard_financial_authorization_change()
returns trigger language plpgsql set search_path = '' as $function$
begin
  if tg_op='INSERT' then
    if new.consumed_at is not null then
      raise exception using errcode='55000',message='financial_authorization_must_start_unused';
    end if;
    return new;
  end if;
  if tg_op='DELETE' then
    raise exception using errcode='55000',message='financial_authorization_is_immutable';
  end if;
  if new.authorization_id is distinct from old.authorization_id
     or new.actor_id is distinct from old.actor_id
     or new.action is distinct from old.action
     or new.amount_kobo is distinct from old.amount_kobo
     or new.destination_id is distinct from old.destination_id
     or new.destination_version is distinct from old.destination_version
     or new.candidate_fingerprint_sha256 is distinct from old.candidate_fingerprint_sha256
     or new.confirmation_method is distinct from old.confirmation_method
     or new.proof_sha256 is distinct from old.proof_sha256
     or new.created_at is distinct from old.created_at
     or new.expires_at is distinct from old.expires_at
     or old.consumed_at is not null or new.consumed_at is null then
    raise exception using errcode='55000',message='financial_authorization_is_immutable';
  end if;
  return new;
end;
$function$;
revoke all on function app_private.guard_financial_authorization_change() from public,anon,authenticated,service_role;
create trigger financial_authorizations_guard_change before insert or update or delete on app_private.financial_authorizations
for each row execute function app_private.guard_financial_authorization_change();

create function app_private.guard_provider_operation_change()
returns trigger language plpgsql set search_path = '' as $function$
begin
  if tg_op='INSERT' then
    if new.status not in ('queued_for_liquidity','pending') then
      raise exception using errcode='55000',message='provider_operation_must_start_pending';
    end if;
    return new;
  end if;
  if tg_op='DELETE' then
    raise exception using errcode='55000',message='provider_operation_is_immutable';
  end if;
  if new.operation_id is distinct from old.operation_id
     or new.operation_type is distinct from old.operation_type
     or new.provider_adapter is distinct from old.provider_adapter
     or (old.provider_adapter is not null and new.provider_adapter is distinct from old.provider_adapter)
     or (old.provider_operation_reference is not null and new.provider_operation_reference is distinct from old.provider_operation_reference)
     or new.provider_idempotency_key is distinct from old.provider_idempotency_key
     or new.actor_id is distinct from old.actor_id
     or new.funding_intent_id is distinct from old.funding_intent_id
     or new.allocation_id is distinct from old.allocation_id
     or new.amount_kobo is distinct from old.amount_kobo
     or new.currency is distinct from old.currency
     or new.destination_id is distinct from old.destination_id
     or new.destination_version is distinct from old.destination_version
     or new.request_sha256 is distinct from old.request_sha256
     or new.created_at is distinct from old.created_at
     or new.fee_kobo < old.fee_kobo
     or (old.fee_kobo>0 and new.fee_kobo is distinct from old.fee_kobo)
     or not (
       new.status=old.status or
       (old.status='queued_for_liquidity' and new.status in ('processing','unknown','exception')) or
       (old.status='pending' and new.status in ('processing','unknown','succeeded','settled','failed','cancelled','exception')) or
       (old.status='processing' and new.status in ('unknown','succeeded','settled','paid','failed','reversed','exception')) or
       (old.status='unknown' and new.status in ('processing','succeeded','settled','paid','failed','reversed','exception')) or
       (old.status in ('succeeded','settled','paid') and new.status in ('reversed','exception'))
     ) then
    raise exception using errcode='55000',message='provider_operation_identity_is_immutable';
  end if;
  new.updated_at:=pg_catalog.now();
  return new;
end;
$function$;
revoke all on function app_private.guard_provider_operation_change() from public,anon,authenticated,service_role;
create trigger provider_operations_guard_change before insert or update or delete on app_private.provider_operations
for each row execute function app_private.guard_provider_operation_change();

create function app_private.guard_financial_outbox_update()
returns trigger language plpgsql set search_path = '' as $function$
begin
  if tg_op='DELETE' or new.event_id is distinct from old.event_id
     or new.event_type is distinct from old.event_type or new.payload is distinct from old.payload
     or new.attempt_count < old.attempt_count
     or not (
       new.delivery_state=old.delivery_state or
       (old.delivery_state='pending' and new.delivery_state in ('processing','failed')) or
       (old.delivery_state='processing' and new.delivery_state in ('pending','delivered','failed')) or
       (old.delivery_state='failed' and new.delivery_state in ('pending','processing'))
     ) then
    raise exception using errcode='55000',message='financial_outbox_event_is_immutable';
  end if;
  return new;
end;
$function$;
revoke all on function app_private.guard_financial_outbox_update() from public,anon,authenticated,service_role;
create trigger financial_outbox_guard_change before update or delete on app_private.financial_outbox
for each row execute function app_private.guard_financial_outbox_update();

create function app_private.calculate_commission_kobo(p_gross_awarded_kobo bigint)
returns bigint language plpgsql immutable strict set search_path = '' as $function$
begin
  if p_gross_awarded_kobo < 1 or p_gross_awarded_kobo > 100000000 then
    raise exception using errcode='22023',message='invalid_amount';
  end if;
  return pg_catalog.floor((p_gross_awarded_kobo::numeric * 500 + 5000) / 10000)::bigint;
end;
$function$;
revoke all on function app_private.calculate_commission_kobo(bigint) from public,anon,authenticated,service_role;
grant execute on function app_private.calculate_commission_kobo(bigint) to postgres;

create function app_private.post_financial_journal(
  p_effect_key uuid,
  p_effect_type text,
  p_reference_id uuid,
  p_actor_id uuid,
  p_entries jsonb
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
    'provider_refund_settled','compensating_correction','platform_capital_contribution'
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

  insert into app_private.ledger_journal_transactions(
    effect_key,effect_type,reference_id,actor_id,request_sha256,entry_count
  ) values(p_effect_key,p_effect_type,p_reference_id,p_actor_id,v_fingerprint,pg_catalog.jsonb_array_length(p_entries))
  returning journal_id into v_journal_id;

  for v_line in select value,ordinality::smallint as line_number
    from pg_catalog.jsonb_array_elements(p_entries) with ordinality loop
    v_item:=v_line.value;
    select * into v_account from app_private.ledger_accounts where account_code=v_item->>'account_code';
    v_amount:=(v_item->>'amount_kobo')::numeric;
    v_allocation_id:=nullif(v_item->>'allocation_id','')::uuid;
    v_owner_id:=nullif(v_item->>'owner_id','')::uuid;
    insert into app_private.ledger_journal_entries(
      journal_id,line_number,account_id,direction,amount_kobo,allocation_id,owner_id
    ) values(v_journal_id,v_line.line_number,v_account.account_id,v_item->>'direction',v_amount::bigint,v_allocation_id,v_owner_id);
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

  v_event_data:=pg_catalog.jsonb_build_object(
    'journal_id',v_journal_id,'effect_type',p_effect_type,'reference_id',p_reference_id,
    'entry_count',pg_catalog.jsonb_array_length(p_entries)
  );
  insert into app_private.financial_audit_events(actor_id,event_type,journal_id,reference_id,event_data)
  values(p_actor_id,'financial_journal_posted',v_journal_id,p_reference_id,v_event_data)
  returning event_id into v_event_id;
  insert into app_private.financial_outbox(event_id,event_type,payload)
  values(v_event_id,'financial.journal_posted',pg_catalog.jsonb_build_object(
    'event_id',v_event_id,'journal_id',v_journal_id,'effect_type',p_effect_type
  ));
  return v_journal_id;
end;
$function$;
revoke all on function app_private.post_financial_journal(uuid,text,uuid,uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function app_private.post_financial_journal(uuid,text,uuid,uuid,jsonb) to postgres;

create function app_private.record_exact_funding(p_intent_id uuid,p_attempt_number smallint)
returns uuid language plpgsql security definer set search_path = '' as $function$
declare
  v_intent app_private.funding_intents%rowtype;
  v_attempt app_private.funding_attempts%rowtype;
  v_entries jsonb:='[]'::jsonb;
  v_allocation_entries jsonb;
  v_asset_code text;
  v_journal_id uuid;
begin
  if p_intent_id is null or p_attempt_number is null or p_attempt_number<1 then
    raise exception using errcode='22023',message='funding_result_mismatch';
  end if;
  select * into v_intent from app_private.funding_intents where intent_id=p_intent_id for update;
  if not found then raise exception using errcode='22023',message='funding_result_mismatch'; end if;
  select * into v_attempt from app_private.funding_attempts
    where funding_intent_id=p_intent_id and attempt_number=p_attempt_number for update;
  if not found or v_attempt.status<>'succeeded'
     or v_attempt.collected_gross_kobo is distinct from v_intent.gross_total_kobo
     or v_attempt.currency is distinct from v_intent.currency
     or v_attempt.provider_fee_kobo is null or v_attempt.provider_net_kobo is null
     or v_attempt.provider_fee_kobo::numeric+v_attempt.provider_net_kobo::numeric<>v_intent.gross_total_kobo::numeric then
    raise exception using errcode='22023',message='funding_result_mismatch';
  end if;
  if v_intent.status='succeeded' then
    select journal_id into v_journal_id from app_private.ledger_journal_transactions
      where effect_key=v_attempt.attempt_id and effect_type='funding_collected';
    if v_journal_id is null then raise exception using errcode='22023',message='funding_result_mismatch'; end if;
    return v_journal_id;
  end if;
  if v_intent.status not in ('pending','unknown') then
    raise exception using errcode='22023',message='funding_result_mismatch';
  end if;
  if exists(select 1 from app_private.principal_allocations where funding_intent_id=p_intent_id) then
    raise exception using errcode='22023',message='funding_result_mismatch';
  end if;

  insert into app_private.principal_allocations(
    funding_intent_id,job_id,poster_id,slot_number,gross_principal_kobo,commission_basis_points,status
  )
  select v_intent.intent_id,v_intent.job_id,v_intent.poster_id,slot,
    v_intent.gross_per_worker_kobo,500,'unassigned'
  from pg_catalog.generate_series(1,v_intent.slot_count) as slots(slot);

  v_asset_code:=case when v_attempt.settlement_status='available'
    then 'provider_available_cash' else 'provider_collection_receivable' end;
  if v_attempt.provider_net_kobo>0 then
    v_entries:=v_entries||pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'account_code',v_asset_code,'direction','debit','amount_kobo',v_attempt.provider_net_kobo::text
    ));
  end if;
  if v_attempt.provider_fee_kobo>0 then
    v_entries:=v_entries||pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'account_code','provider_processing_fee_expense','direction','debit',
      'amount_kobo',v_attempt.provider_fee_kobo::text
    ));
  end if;
  select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'account_code','job_principal_unassigned','direction','credit',
    'amount_kobo',p.gross_principal_kobo::text,'allocation_id',p.allocation_id::text
  ) order by p.slot_number) into v_allocation_entries
  from app_private.principal_allocations p where p.funding_intent_id=p_intent_id;
  v_entries:=v_entries||coalesce(v_allocation_entries,'[]'::jsonb);
  v_journal_id:=app_private.post_financial_journal(
    v_attempt.attempt_id,'funding_collected',v_intent.intent_id,v_intent.poster_id,v_entries
  );
  update app_private.funding_intents set status='succeeded' where intent_id=p_intent_id;
  return v_journal_id;
end;
$function$;
revoke all on function app_private.record_exact_funding(uuid,smallint) from public,anon,authenticated,service_role;
grant execute on function app_private.record_exact_funding(uuid,smallint) to postgres;

create function app_private.rebuild_ledger_account_balances()
returns void language plpgsql security definer set search_path = '' as $function$
begin
  lock table app_private.ledger_journal_entries in share mode;
  truncate table app_private.ledger_account_balances;
  insert into app_private.ledger_account_balances(account_id,owner_id,allocation_id,debit_kobo,credit_kobo)
  select account_id,owner_id,allocation_id,
    coalesce(sum(amount_kobo) filter (where direction='debit'),0),
    coalesce(sum(amount_kobo) filter (where direction='credit'),0)
  from app_private.ledger_journal_entries
  group by account_id,owner_id,allocation_id;
end;
$function$;
revoke all on function app_private.rebuild_ledger_account_balances() from public,anon,authenticated,service_role;
grant execute on function app_private.rebuild_ledger_account_balances() to postgres;

revoke all on table
  app_private.ledger_policy,app_private.ledger_accounts,app_private.funding_intents,
  app_private.provider_operations,app_private.funding_attempts,app_private.principal_allocations,
  app_private.ledger_journal_transactions,app_private.ledger_journal_entries,
  app_private.ledger_account_balances,app_private.financial_authorizations,
  app_private.financial_command_idempotency,app_private.provider_webhook_receipts,
  app_private.financial_exceptions,app_private.financial_audit_events,app_private.financial_outbox
from public,anon,authenticated,service_role;
revoke all on app_private.provider_liquidity_snapshot from public,anon,authenticated,service_role;
revoke all on function app_private.guard_funding_intent_change(),app_private.guard_funding_attempt_insert(),
  app_private.guard_funding_attempt_change(),app_private.guard_allocation_change(),
  app_private.guard_financial_authorization_change(),app_private.guard_provider_operation_change(),
  app_private.guard_financial_outbox_update() from public,anon,authenticated,service_role;

commit;
