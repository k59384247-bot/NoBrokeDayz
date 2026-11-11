begin;

-- Step 8 wallet data is private. Recipient values are fixed simulator fixtures;
-- they are not bank verification or provider KYC.
create table app_private.wallet_destinations (
  destination_id uuid primary key default pg_catalog.gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete restrict,
  current_version integer not null default 0 check (current_version >= 0),
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  unique(destination_id,owner_id)
);

create table app_private.wallet_destination_versions (
  destination_id uuid not null references app_private.wallet_destinations(destination_id) on delete restrict,
  version integer not null check (version > 0),
  simulated_recipient_code text not null check (simulated_recipient_code in (
    'fake_recipient_alpha','fake_recipient_beta','fake_recipient_gamma'
  )),
  institution_label text not null check (char_length(institution_label) between 1 and 80),
  recipient_label text not null check (char_length(recipient_label) between 1 and 80),
  masked_reference text not null check (char_length(masked_reference) between 1 and 32),
  ownership_verification text not null default 'simulator_only'
    check (ownership_verification='simulator_only'),
  created_at timestamptz not null default pg_catalog.now(),
  primary key(destination_id,version)
);

create function app_private.guard_wallet_destination_change()
returns trigger language plpgsql set search_path = '' as $function$
begin
  if tg_op='DELETE' or new.destination_id is distinct from old.destination_id
     or new.owner_id is distinct from old.owner_id
     or new.created_at is distinct from old.created_at
     or new.current_version not between old.current_version and old.current_version+1 then
    raise exception using errcode='55000',message='wallet_destination_identity_is_immutable';
  end if;
  new.updated_at:=pg_catalog.now();
  return new;
end;
$function$;
create trigger wallet_destinations_guard_change before update or delete
on app_private.wallet_destinations for each row
execute function app_private.guard_wallet_destination_change();
create trigger wallet_destination_versions_immutable before update or delete
on app_private.wallet_destination_versions for each row
execute function app_private.reject_financial_history_mutation();

create table app_private.withdrawal_requests (
  withdrawal_id uuid primary key default pg_catalog.gen_random_uuid(),
  actor_id uuid not null references auth.users(id) on delete restrict,
  operation_id uuid not null unique references app_private.provider_operations(operation_id) on delete restrict,
  destination_id uuid not null,
  destination_version integer not null check (destination_version > 0),
  amount_kobo bigint not null check (amount_kobo between 1 and 1000000000),
  expected_provider_fee_kobo bigint not null default 0
    check (expected_provider_fee_kobo between 0 and 1000000000),
  fee_reserve_transferred_kobo bigint not null default 0 check (fee_reserve_transferred_kobo >= 0),
  institution_label text not null,
  recipient_label text not null,
  masked_reference text not null,
  idempotency_key uuid not null,
  request_sha256 bytea not null check (pg_catalog.octet_length(request_sha256)=32),
  status text not null check (status in (
    'queued_for_liquidity','processing','unknown','paid','failed','reversed','exception'
  )),
  reserve_effect_id uuid not null unique default pg_catalog.gen_random_uuid(),
  payout_effect_id uuid not null unique default pg_catalog.gen_random_uuid(),
  failure_effect_id uuid not null unique default pg_catalog.gen_random_uuid(),
  reversal_effect_id uuid not null unique default pg_catalog.gen_random_uuid(),
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  unique(actor_id,idempotency_key),
  foreign key(destination_id,destination_version)
    references app_private.wallet_destination_versions(destination_id,version) on delete restrict
);
create index withdrawal_requests_actor_history_idx
  on app_private.withdrawal_requests(actor_id,created_at desc,withdrawal_id desc);
create index withdrawal_requests_liquidity_queue_idx
  on app_private.withdrawal_requests(status,created_at,withdrawal_id)
  where status='queued_for_liquidity';

create table app_private.withdrawal_source_allocations (
  withdrawal_id uuid not null references app_private.withdrawal_requests(withdrawal_id) on delete restrict,
  allocation_id uuid not null references app_private.principal_allocations(allocation_id) on delete restrict,
  amount_kobo bigint not null check (amount_kobo > 0),
  created_at timestamptz not null default pg_catalog.now(),
  primary key(withdrawal_id,allocation_id)
);

create table app_private.provider_settlement_records (
  attempt_id uuid primary key references app_private.funding_attempts(attempt_id) on delete restrict,
  settlement_effect_id uuid not null unique default pg_catalog.gen_random_uuid(),
  journal_id uuid not null unique references app_private.ledger_journal_transactions(journal_id) on delete restrict,
  settled_at timestamptz not null default pg_catalog.now()
);

create function app_private.guard_withdrawal_request_change()
returns trigger language plpgsql set search_path = '' as $function$
begin
  if tg_op='DELETE' or new.withdrawal_id is distinct from old.withdrawal_id
     or new.actor_id is distinct from old.actor_id or new.operation_id is distinct from old.operation_id
     or new.destination_id is distinct from old.destination_id
     or new.destination_version is distinct from old.destination_version
     or new.amount_kobo is distinct from old.amount_kobo
     or new.expected_provider_fee_kobo is distinct from old.expected_provider_fee_kobo
     or new.institution_label is distinct from old.institution_label
     or new.recipient_label is distinct from old.recipient_label
     or new.masked_reference is distinct from old.masked_reference
     or new.idempotency_key is distinct from old.idempotency_key
     or new.request_sha256 is distinct from old.request_sha256
     or new.reserve_effect_id is distinct from old.reserve_effect_id
     or new.payout_effect_id is distinct from old.payout_effect_id
     or new.failure_effect_id is distinct from old.failure_effect_id
     or new.reversal_effect_id is distinct from old.reversal_effect_id
     or new.fee_reserve_transferred_kobo < old.fee_reserve_transferred_kobo
     or new.fee_reserve_transferred_kobo > old.fee_reserve_transferred_kobo+
       new.expected_provider_fee_kobo
     or not (
       new.status=old.status or
       (old.status='queued_for_liquidity' and new.status in ('processing','exception')) or
       (old.status='processing' and new.status in ('unknown','paid','failed','exception')) or
       (old.status='unknown' and new.status in ('processing','paid','failed','exception')) or
       (old.status='paid' and new.status in ('reversed','exception'))
     ) then
    raise exception using errcode='55000',message='withdrawal_request_identity_is_immutable';
  end if;
  new.updated_at:=pg_catalog.now();
  return new;
end;
$function$;
create trigger withdrawal_requests_guard_change before update or delete
on app_private.withdrawal_requests for each row
execute function app_private.guard_withdrawal_request_change();
create trigger withdrawal_source_allocations_immutable before update or delete
on app_private.withdrawal_source_allocations for each row
execute function app_private.reject_financial_history_mutation();
create trigger provider_settlement_records_immutable before update or delete
on app_private.provider_settlement_records for each row
execute function app_private.reject_financial_history_mutation();

alter table app_private.financial_audit_events
  drop constraint financial_audit_events_event_type_check;
alter table app_private.financial_audit_events
  add constraint financial_audit_events_event_type_check check (event_type in (
    'financial_journal_posted','financial_inspection','assignment_completion_authorized',
    'assignment_hold_opened','wallet_destination_changed','withdrawal_requested',
    'withdrawal_status_changed'
  ));
alter table app_private.financial_outbox
  drop constraint financial_outbox_event_type_check;
alter table app_private.financial_outbox
  add constraint financial_outbox_event_type_check check (event_type in (
    'financial.journal_posted','financial.wallet_destination_changed',
    'financial.withdrawal_requested','financial.withdrawal_status_changed'
  ));

create function app_private.wallet_destination_projection(p_destination_id uuid,p_version integer)
returns jsonb language sql stable security definer set search_path = '' as $function$
  select pg_catalog.jsonb_build_object(
    'destination_id',v.destination_id,'destination_version',v.version,
    'institution_label',v.institution_label,'recipient_label',v.recipient_label,
    'masked_reference',v.masked_reference,'ownership_verification','simulator_only',
    'created_at',v.created_at
  ) from app_private.wallet_destination_versions v
  where v.destination_id=p_destination_id and v.version=p_version
$function$;

create function app_private.simulated_destination_labels(p_code text)
returns jsonb language sql immutable set search_path = '' as $function$
  select case p_code
    when 'fake_recipient_alpha' then pg_catalog.jsonb_build_object(
      'institution_label','Fake NBD Bank Alpha','recipient_label','Synthetic Recipient Alpha',
      'masked_reference','SIM-ALPHA','ownership_verification','simulator_only')
    when 'fake_recipient_beta' then pg_catalog.jsonb_build_object(
      'institution_label','Fake NBD Bank Beta','recipient_label','Synthetic Recipient Beta',
      'masked_reference','SIM-BETA','ownership_verification','simulator_only')
    when 'fake_recipient_gamma' then pg_catalog.jsonb_build_object(
      'institution_label','Fake NBD Bank Gamma','recipient_label','Synthetic Recipient Gamma',
      'masked_reference','SIM-GAMMA','ownership_verification','simulator_only')
    else null end
$function$;

create function app_private.wallet_actor_is_active_worker(p_actor uuid)
returns boolean language sql stable security definer set search_path = '' as $function$
  select 'can_work'=any(app_private.current_profile_capabilities(p_actor))
$function$;

create function app_private.audit_wallet_event(
  p_actor uuid,p_event_type text,p_reference uuid,p_event_data jsonb
) returns uuid language plpgsql security definer set search_path = '' as $function$
declare v_event uuid;
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
  return v_event;
end;
$function$;

create function app_private.authorize_simulated_destination_change_for_actor(
  p_actor uuid,p_destination_id uuid,p_expected_version integer,
  p_simulated_recipient_code text,p_proof_sha256_hex text
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_destination app_private.wallet_destinations%rowtype;
  v_destination_id uuid:=p_destination_id;
  v_target_version integer;
  v_fingerprint bytea;
  v_authorization uuid;
  v_labels jsonb;
  v_expiry timestamptz;
begin
  if p_actor is null or not app_private.wallet_actor_is_active_worker(p_actor) then
    raise exception using errcode='42501',message='verification_required';
  end if;
  if p_expected_version is null or p_expected_version<0
     or p_simulated_recipient_code is null
     or p_simulated_recipient_code not in ('fake_recipient_alpha','fake_recipient_beta','fake_recipient_gamma')
     or p_proof_sha256_hex is null or p_proof_sha256_hex !~ '^[0-9a-f]{64}$' then
    raise exception using errcode='22023',message='invalid_wallet_request';
  end if;
  if p_destination_id is null then
    if p_expected_version<>0 then raise exception using errcode='22023',message='invalid_wallet_request'; end if;
    insert into app_private.wallet_destinations(owner_id) values(p_actor)
    returning * into v_destination;
    v_destination_id:=v_destination.destination_id;
    v_target_version:=1;
  else
    select * into v_destination from app_private.wallet_destinations
      where destination_id=p_destination_id and owner_id=p_actor for update;
    if not found then raise exception using errcode='P0002',message='destination_not_found'; end if;
    if v_destination.current_version<>p_expected_version or p_expected_version<1 then
      raise exception using errcode='P0001',message='stale_state';
    end if;
    v_target_version:=p_expected_version+1;
  end if;
  v_fingerprint:=extensions.digest(pg_catalog.convert_to(
    v_destination_id::text||':'||v_target_version::text||':'||p_simulated_recipient_code,'UTF8'),'sha256');
  v_expiry:=pg_catalog.now()+interval '5 minutes';
  insert into app_private.financial_authorizations(
    actor_id,action,destination_id,destination_version,candidate_fingerprint_sha256,
    confirmation_method,proof_sha256,expires_at
  ) values(p_actor,'change_bank_destination',v_destination_id,v_target_version,v_fingerprint,
    'fresh_password',pg_catalog.decode(p_proof_sha256_hex,'hex'),v_expiry)
  returning authorization_id into v_authorization;
  v_labels:=app_private.simulated_destination_labels(p_simulated_recipient_code);
  return pg_catalog.jsonb_build_object(
    'authorization_id',v_authorization,'destination_id',v_destination_id,
    'destination_version',v_target_version,'amount_kobo',null,'expires_at',v_expiry,
    'destination_summary',v_labels
  );
end;
$function$;

create function app_private.confirm_simulated_destination_change_for_actor(
  p_actor uuid,p_proof_sha256_hex text,p_simulated_recipient_code text,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_auth app_private.financial_authorizations%rowtype;
  v_existing app_private.financial_command_idempotency%rowtype;
  v_destination app_private.wallet_destinations%rowtype;
  v_labels jsonb;
  v_hash bytea;
  v_version integer;
begin
  if p_actor is null or not app_private.wallet_actor_is_active_worker(p_actor) then
    raise exception using errcode='42501',message='verification_required';
  end if;
  if p_proof_sha256_hex is null or p_proof_sha256_hex !~ '^[0-9a-f]{64}$' or p_idempotency_key is null
     or p_simulated_recipient_code is null
     or p_simulated_recipient_code not in ('fake_recipient_alpha','fake_recipient_beta','fake_recipient_gamma') then
    raise exception using errcode='22023',message='invalid_wallet_request';
  end if;
  v_hash:=extensions.digest(pg_catalog.convert_to(p_simulated_recipient_code,'UTF8'),'sha256');
  select * into v_existing from app_private.financial_command_idempotency
  where actor_id=p_actor and command_name='change_bank_destination' and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.request_sha256<>v_hash then
      raise exception using errcode='23505',message='idempotency_conflict';
    end if;
    return app_private.wallet_destination_projection(
      v_existing.response_reference_id,pg_catalog.split_part(v_existing.response_code,':',2)::integer);
  end if;
  select * into v_auth from app_private.financial_authorizations
  where proof_sha256=pg_catalog.decode(p_proof_sha256_hex,'hex')
    and actor_id=p_actor and action='change_bank_destination' for update;
  if not found or v_auth.consumed_at is not null then
    raise exception using errcode='P0001',message='confirmation_required';
  end if;
  if v_auth.expires_at<=pg_catalog.now() then
    raise exception using errcode='P0001',message='confirmation_expired';
  end if;
  if v_auth.candidate_fingerprint_sha256<>extensions.digest(pg_catalog.convert_to(
    v_auth.destination_id::text||':'||v_auth.destination_version::text||':'||p_simulated_recipient_code,'UTF8'),'sha256') then
    raise exception using errcode='P0001',message='confirmation_required';
  end if;
  select * into v_destination from app_private.wallet_destinations
  where destination_id=v_auth.destination_id and owner_id=p_actor for update;
  if not found or v_destination.current_version<>v_auth.destination_version-1 then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  update app_private.financial_authorizations set consumed_at=pg_catalog.now()
    where authorization_id=v_auth.authorization_id;
  v_labels:=app_private.simulated_destination_labels(p_simulated_recipient_code);
  insert into app_private.wallet_destination_versions(
    destination_id,version,simulated_recipient_code,institution_label,recipient_label,masked_reference
  ) values(v_auth.destination_id,v_auth.destination_version,p_simulated_recipient_code,
    v_labels->>'institution_label',v_labels->>'recipient_label',v_labels->>'masked_reference');
  update app_private.wallet_destinations set current_version=v_auth.destination_version
    where destination_id=v_auth.destination_id;
  v_version:=v_auth.destination_version;
  insert into app_private.financial_command_idempotency(
    actor_id,command_name,idempotency_key,request_sha256,response_reference_id,response_code
  ) values(p_actor,'change_bank_destination',p_idempotency_key,v_hash,v_auth.destination_id,'version:'||v_version::text);
  perform app_private.audit_wallet_event(p_actor,'wallet_destination_changed',v_auth.destination_id,
    pg_catalog.jsonb_build_object('destination_version',v_version,'ownership_verification','simulator_only'));
  return app_private.wallet_destination_projection(v_auth.destination_id,v_version);
end;
$function$;

create function app_private.authorize_withdrawal_for_actor(
  p_actor uuid,p_amount_kobo text,p_destination_id uuid,p_destination_version integer,
  p_proof_sha256_hex text
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_amount bigint;
  v_destination app_private.wallet_destinations%rowtype;
  v_available bigint;
  v_authorization uuid;
  v_expiry timestamptz;
  v_summary jsonb;
begin
  if p_actor is null or not app_private.wallet_actor_is_active_worker(p_actor) then
    raise exception using errcode='42501',message='verification_required';
  end if;
  if p_amount_kobo is null or p_amount_kobo !~ '^[1-9][0-9]{0,9}$'
     or p_amount_kobo::numeric>1000000000 or p_destination_version is null
     or p_destination_version<1 or p_destination_id is null
     or p_proof_sha256_hex is null or p_proof_sha256_hex !~ '^[0-9a-f]{64}$' then
    raise exception using errcode='22023',message='invalid_wallet_request';
  end if;
  v_amount:=p_amount_kobo::bigint;
  select * into v_destination from app_private.wallet_destinations
  where destination_id=p_destination_id and owner_id=p_actor for update;
  if not found or v_destination.current_version<>p_destination_version then
    raise exception using errcode='P0002',message='destination_not_found';
  end if;
  select coalesce(-sum(b.balance_kobo),0)::bigint into v_available
  from app_private.ledger_account_balances b
  join app_private.ledger_accounts a using(account_id)
  where a.account_code='worker_earnings_available' and b.owner_id=p_actor;
  if v_available<v_amount then
    raise exception using errcode='P0001',message='insufficient_available_balance';
  end if;
  v_expiry:=pg_catalog.now()+interval '5 minutes';
  insert into app_private.financial_authorizations(
    actor_id,action,amount_kobo,destination_id,destination_version,
    confirmation_method,proof_sha256,expires_at
  ) values(p_actor,'request_withdrawal',v_amount,p_destination_id,p_destination_version,
    'fresh_password',pg_catalog.decode(p_proof_sha256_hex,'hex'),v_expiry)
  returning authorization_id into v_authorization;
  v_summary:=app_private.wallet_destination_projection(p_destination_id,p_destination_version);
  return pg_catalog.jsonb_build_object(
    'authorization_id',v_authorization,'destination_id',p_destination_id,
    'destination_version',p_destination_version,'amount_kobo',v_amount::text,
    'expires_at',v_expiry,'destination_summary',v_summary
  );
end;
$function$;

create function app_private.try_start_queued_payouts_for_liquidity()
returns integer language plpgsql security definer set search_path = '' as $function$
declare
  v_request app_private.withdrawal_requests%rowtype;
  v_operation app_private.provider_operations%rowtype;
  v_cash bigint;
  v_reserve bigint;
  v_other_protected bigint;
  v_available bigint;
  v_gap bigint;
  v_started integer:=0;
begin
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('nbd:payout-liquidity',0));
  for v_request in
    select * from app_private.withdrawal_requests
    where status='queued_for_liquidity'
    order by created_at,withdrawal_id for update skip locked
  loop
    select * into v_operation from app_private.provider_operations
      where operation_id=v_request.operation_id for update;
    select coalesce(sum(b.balance_kobo) filter(where a.account_code='provider_available_cash'),0)::bigint,
      coalesce(sum(b.balance_kobo) filter(where a.account_code='platform_fee_reserve_cash'),0)::bigint,
      coalesce(-sum(b.balance_kobo) filter(where a.account_code in (
        'job_principal_unassigned','job_principal_assigned','job_principal_dispute_held',
        'worker_earnings_available','worker_withdrawal_reserved'
      )),0)::bigint
    into v_cash,v_reserve,v_other_protected
    from app_private.ledger_accounts a
    left join app_private.ledger_account_balances b using(account_id);
    v_other_protected:=greatest(0,v_other_protected-v_request.amount_kobo);
    v_other_protected:=v_other_protected+coalesce((
      select sum(w.fee_reserve_transferred_kobo)::bigint from app_private.withdrawal_requests w
      where w.status in ('processing','unknown','exception')
        and w.withdrawal_id<>v_request.withdrawal_id
    ),0);
    v_available:=v_cash-v_other_protected;
    if v_available<v_request.amount_kobo
       or v_available+v_reserve<v_request.amount_kobo+v_request.expected_provider_fee_kobo then
      continue;
    end if;
    v_gap:=greatest(0,v_request.amount_kobo+v_request.expected_provider_fee_kobo-v_available);
    if v_gap>v_reserve then continue; end if;
    if v_gap>0 then
      perform app_private.post_financial_journal(
        v_operation.operation_id,'platform_fee_reserve_transfer',v_request.withdrawal_id,null,
        pg_catalog.jsonb_build_array(
          pg_catalog.jsonb_build_object('account_code','provider_available_cash','direction','debit','amount_kobo',v_gap::text),
          pg_catalog.jsonb_build_object('account_code','platform_fee_reserve_cash','direction','credit','amount_kobo',v_gap::text)
        )
      );
    end if;
    update app_private.withdrawal_requests set status='processing',
      fee_reserve_transferred_kobo=v_gap where withdrawal_id=v_request.withdrawal_id;
    update app_private.provider_operations set status='processing'
      where operation_id=v_operation.operation_id;
    perform app_private.audit_wallet_event(null,'withdrawal_status_changed',v_request.withdrawal_id,
      pg_catalog.jsonb_build_object('status','processing'));
    v_started:=v_started+1;
  end loop;
  return v_started;
end;
$function$;

create or replace function public.server_claim_payment_operation_for_runner(
  p_worker_id uuid,p_lease_seconds smallint default 30
) returns jsonb language plpgsql security definer set search_path = '' as $function$
begin
  perform app_private.try_start_queued_payouts_for_liquidity();
  return app_private.claim_payment_operation_job(p_worker_id,p_lease_seconds);
end;
$function$;

create function app_private.request_withdrawal_for_actor(
  p_actor uuid,p_amount_kobo text,p_destination_id uuid,p_destination_version integer,
  p_proof_sha256_hex text,p_expected_provider_fee_kobo text,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_existing app_private.withdrawal_requests%rowtype;
  v_idem app_private.financial_command_idempotency%rowtype;
  v_auth app_private.financial_authorizations%rowtype;
  v_destination app_private.wallet_destinations%rowtype;
  v_request_id uuid:=pg_catalog.gen_random_uuid();
  v_operation_id uuid:=pg_catalog.gen_random_uuid();
  v_provider_key uuid:=pg_catalog.gen_random_uuid();
  v_amount bigint;
  v_fee bigint;
  v_hash bytea;
  v_available bigint;
  v_remaining bigint;
  v_take bigint;
  v_source record;
  v_entries jsonb:='[]'::jsonb;
  v_request app_private.withdrawal_requests%rowtype;
  v_summary jsonb;
begin
  if p_actor is null or not app_private.wallet_actor_is_active_worker(p_actor) then
    raise exception using errcode='42501',message='verification_required';
  end if;
  if p_amount_kobo is null or p_amount_kobo !~ '^[1-9][0-9]{0,9}$'
     or p_amount_kobo::numeric>1000000000 or p_destination_version is null
     or p_destination_version<1 or p_destination_id is null
     or p_proof_sha256_hex is null or p_proof_sha256_hex !~ '^[0-9a-f]{64}$'
     or p_expected_provider_fee_kobo is null
     or p_expected_provider_fee_kobo !~ '^(0|[1-9][0-9]{0,9})$'
     or p_expected_provider_fee_kobo::numeric>1000000000 or p_idempotency_key is null then
    raise exception using errcode='22023',message='invalid_wallet_request';
  end if;
  v_amount:=p_amount_kobo::bigint;
  v_fee:=p_expected_provider_fee_kobo::bigint;
  v_hash:=extensions.digest(pg_catalog.convert_to(
    v_amount::text||':'||p_destination_id::text||':'||p_destination_version::text,'UTF8'),'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('nbd:withdrawal:'||p_actor::text,0));
  select * into v_existing from app_private.withdrawal_requests
  where actor_id=p_actor and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.request_sha256<>v_hash then
      raise exception using errcode='23505',message='idempotency_conflict';
    end if;
    return pg_catalog.jsonb_build_object(
      'withdrawal_id',v_existing.withdrawal_id,'status',v_existing.status,
      'amount_kobo',v_existing.amount_kobo::text,'destination_id',v_existing.destination_id,
      'destination_version',v_existing.destination_version,
      'destination_summary',pg_catalog.jsonb_build_object(
        'institution_label',v_existing.institution_label,'recipient_label',v_existing.recipient_label,
        'masked_reference',v_existing.masked_reference,'ownership_verification','simulator_only')
    );
  end if;
  select * into v_destination from app_private.wallet_destinations
  where destination_id=p_destination_id and owner_id=p_actor for update;
  if not found or v_destination.current_version<>p_destination_version then
    raise exception using errcode='P0002',message='destination_not_found';
  end if;
  select * into v_auth from app_private.financial_authorizations
  where proof_sha256=pg_catalog.decode(p_proof_sha256_hex,'hex')
    and actor_id=p_actor and action='request_withdrawal'
    and amount_kobo=v_amount and destination_id=p_destination_id
    and destination_version=p_destination_version for update;
  if not found or v_auth.consumed_at is not null then
    raise exception using errcode='P0001',message='confirmation_required';
  end if;
  if v_auth.expires_at<=pg_catalog.now() then
    raise exception using errcode='P0001',message='confirmation_expired';
  end if;
  select coalesce(-sum(b.balance_kobo),0)::bigint into v_available
  from app_private.ledger_account_balances b
  join app_private.ledger_accounts a using(account_id)
  where a.account_code='worker_earnings_available' and b.owner_id=p_actor;
  if v_available<v_amount then
    raise exception using errcode='P0001',message='insufficient_available_balance';
  end if;
  update app_private.financial_authorizations set consumed_at=pg_catalog.now()
    where authorization_id=v_auth.authorization_id;
  v_summary:=app_private.wallet_destination_projection(p_destination_id,p_destination_version);
  insert into app_private.provider_operations(
    operation_id,operation_type,provider_adapter,provider_idempotency_key,actor_id,
    amount_kobo,fee_kobo,currency,destination_id,destination_version,request_sha256,status
  ) values(v_operation_id,'payout','local_simulator',v_provider_key,p_actor,
    v_amount,0,'NGN',p_destination_id,p_destination_version,v_hash,'queued_for_liquidity');
  insert into app_private.withdrawal_requests(
    withdrawal_id,actor_id,operation_id,destination_id,destination_version,amount_kobo,
    expected_provider_fee_kobo,institution_label,recipient_label,masked_reference,
    idempotency_key,request_sha256,status
  ) values(v_request_id,p_actor,v_operation_id,p_destination_id,p_destination_version,v_amount,
    v_fee,v_summary->>'institution_label',v_summary->>'recipient_label',v_summary->>'masked_reference',
    p_idempotency_key,v_hash,'queued_for_liquidity') returning * into v_request;

  v_remaining:=v_amount;
  for v_source in
    select b.allocation_id,(-b.balance_kobo)::bigint as available_kobo
    from app_private.ledger_account_balances b
    join app_private.ledger_accounts a using(account_id)
    join app_private.principal_allocations p using(allocation_id)
    where a.account_code='worker_earnings_available' and b.owner_id=p_actor
      and b.allocation_id is not null and b.balance_kobo<0
      and p.status='worker_earnings_allocated'
    order by p.created_at,p.allocation_id for update of b
  loop
    exit when v_remaining=0;
    v_take:=least(v_remaining,v_source.available_kobo);
    insert into app_private.withdrawal_source_allocations(withdrawal_id,allocation_id,amount_kobo)
      values(v_request_id,v_source.allocation_id,v_take);
    v_entries:=v_entries||pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('account_code','worker_earnings_available','direction','debit',
        'amount_kobo',v_take::text,'allocation_id',v_source.allocation_id::text,'owner_id',p_actor::text),
      pg_catalog.jsonb_build_object('account_code','worker_withdrawal_reserved','direction','credit',
        'amount_kobo',v_take::text,'allocation_id',v_source.allocation_id::text,'owner_id',p_actor::text)
    );
    v_remaining:=v_remaining-v_take;
  end loop;
  if v_remaining<>0 then
    raise exception using errcode='P0001',message='insufficient_available_balance';
  end if;
  perform app_private.post_financial_journal(
    v_request.reserve_effect_id,'withdrawal_reserved',v_request_id,p_actor,v_entries
  );
  insert into app_private.financial_command_idempotency(
    actor_id,command_name,idempotency_key,request_sha256,response_reference_id,response_code
  ) values(p_actor,'request_withdrawal',p_idempotency_key,v_hash,v_request_id,'withdrawal:'||v_request_id::text);
  perform app_private.audit_wallet_event(p_actor,'withdrawal_requested',v_request_id,
    pg_catalog.jsonb_build_object('amount_kobo',v_amount::text,'destination_id',p_destination_id,
      'destination_version',p_destination_version,'status','queued_for_liquidity'));
  perform app_private.try_start_queued_payouts_for_liquidity();
  select * into v_request from app_private.withdrawal_requests where withdrawal_id=v_request_id;
  return pg_catalog.jsonb_build_object(
    'withdrawal_id',v_request.withdrawal_id,'status',v_request.status,
    'amount_kobo',v_request.amount_kobo::text,'destination_id',v_request.destination_id,
    'destination_version',v_request.destination_version,
    'destination_summary',pg_catalog.jsonb_build_object(
      'institution_label',v_request.institution_label,'recipient_label',v_request.recipient_label,
      'masked_reference',v_request.masked_reference,'ownership_verification','simulator_only')
  );
end;
$function$;

create function app_private.complete_worker_payout_for_runner(
  p_operation_id uuid,p_lease_token uuid,p_status text,p_provider_reference text,
  p_amount_kobo text,p_currency text,p_client_reference uuid,p_destination_id uuid,
  p_destination_version integer,p_fee_kobo text,p_safe_error_code text,p_retry boolean,
  p_result_sha256_hex text
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_operation app_private.provider_operations%rowtype;
  v_request app_private.withdrawal_requests%rowtype;
  v_job app_private.payment_operation_jobs%rowtype;
  v_hash bytea;
  v_status text:=p_status;
  v_error text:=p_safe_error_code;
  v_fee bigint;
  v_result jsonb;
  v_entries jsonb:='[]'::jsonb;
  v_source record;
begin
  select * into v_operation from app_private.provider_operations
  where operation_id=p_operation_id and operation_type='payout'
    and provider_adapter='local_simulator' for update;
  if not found then raise exception using errcode='22023',message='payment_operation_not_simulated'; end if;
  select * into v_request from app_private.withdrawal_requests
  where operation_id=p_operation_id for update;
  if not found then raise exception using errcode='22023',message='payout_request_not_found'; end if;
  select * into v_job from app_private.payment_operation_jobs
  where operation_id=p_operation_id for update;
  if not found or v_job.state<>'leased' or v_job.lease_token is distinct from p_lease_token
     or v_job.lease_expires_at<=pg_catalog.now() then
    raise exception using errcode='40001',message='payment_job_lease_lost';
  end if;
  if p_status not in ('processing','unknown','succeeded','failed','reversed','exception')
     or p_retry is null or (p_status in ('processing','unknown') and not p_retry)
     or (p_status in ('succeeded','failed','reversed','exception') and p_retry)
     or p_safe_error_code is not null and p_safe_error_code not in (
       'provider_timeout','provider_unavailable','amount_mismatch','currency_mismatch',
       'reference_mismatch','destination_mismatch','unknown_result','settlement_pending'
     ) then
    raise exception using errcode='22023',message='invalid_payment_operation_result';
  end if;
  if p_fee_kobo is null or p_fee_kobo !~ '^(0|[1-9][0-9]{0,11})$'
     or p_fee_kobo::numeric>1000000000 then
    raise exception using errcode='22023',message='invalid_provider_fee';
  end if;
  v_fee:=p_fee_kobo::bigint;
  if p_status in ('succeeded','failed','reversed','processing') then
    if p_client_reference is distinct from v_operation.provider_idempotency_key
       or p_provider_reference is distinct from 'sim-'||v_operation.provider_idempotency_key::text then
      v_status:='exception';v_error:='reference_mismatch';
    elsif p_amount_kobo is null or p_amount_kobo !~ '^[1-9][0-9]{0,11}$'
       or p_amount_kobo::numeric<>v_request.amount_kobo::numeric then
      v_status:='exception';v_error:='amount_mismatch';
    elsif p_currency is distinct from 'NGN' then
      v_status:='exception';v_error:='currency_mismatch';
    elsif p_destination_id is distinct from v_request.destination_id
       or p_destination_version is distinct from v_request.destination_version then
      v_status:='exception';v_error:='reference_mismatch';
    elsif v_fee<>v_request.expected_provider_fee_kobo then
      v_status:='exception';v_error:='amount_mismatch';
    elsif p_result_sha256_hex is null or p_result_sha256_hex !~ '^[0-9a-f]{64}$' then
      v_status:='exception';v_error:='unknown_result';
    end if;
  end if;
  if v_status='reversed' and v_request.status not in ('paid','reversed') then
    v_status:='exception';v_error:='unknown_result';
  end if;
  if v_error='destination_mismatch' then v_error:='reference_mismatch'; end if;
  if v_status='exception' then p_retry:=false; end if;
  if v_status in ('processing','unknown') and not p_retry then
    raise exception using errcode='22023',message='invalid_payment_operation_result';
  end if;
  v_result:=app_private.complete_payment_operation_job(
    p_operation_id,p_lease_token,v_status,p_provider_reference,
    case when p_provider_reference is null and v_operation.fee_kobo>0
      then v_operation.fee_kobo::text else v_fee::text end,
    v_error,p_retry
  );
  if v_status='processing' then
    if v_request.status='unknown' then
      update app_private.withdrawal_requests set status='processing'
      where withdrawal_id=v_request.withdrawal_id;
      perform app_private.audit_wallet_event(v_request.actor_id,'withdrawal_status_changed',v_request.withdrawal_id,
        pg_catalog.jsonb_build_object('status','processing'));
    end if;
    return v_result||pg_catalog.jsonb_build_object('withdrawal_status',v_request.status);
  elsif v_status='unknown' then
    if v_request.status in ('processing','unknown') then
      update app_private.withdrawal_requests set status='unknown' where withdrawal_id=v_request.withdrawal_id;
      if v_request.status<>'unknown' then
        perform app_private.audit_wallet_event(v_request.actor_id,'withdrawal_status_changed',v_request.withdrawal_id,
          pg_catalog.jsonb_build_object('status','unknown'));
      end if;
    end if;
    return v_result||pg_catalog.jsonb_build_object('withdrawal_status','unknown');
  elsif v_status='exception' then
    update app_private.withdrawal_requests set status='exception' where withdrawal_id=v_request.withdrawal_id
      and status not in ('paid','failed','reversed','exception');
    insert into app_private.financial_exceptions(operation_id,exception_type,safe_reference)
    values(p_operation_id,case v_error
      when 'amount_mismatch' then 'payout_mismatch'
      when 'destination_mismatch' then 'payout_mismatch'
      when 'currency_mismatch' then 'currency_mismatch'
      when 'reference_mismatch' then 'reference_mismatch'
      else 'unknown_result' end,left(coalesce(p_provider_reference,''),180));
    perform app_private.audit_wallet_event(v_request.actor_id,'withdrawal_status_changed',v_request.withdrawal_id,
      pg_catalog.jsonb_build_object('status','exception','safe_reason',v_error));
    return v_result||pg_catalog.jsonb_build_object('withdrawal_status','exception');
  end if;

  if v_status='succeeded' and v_request.status in ('processing','unknown') then
    for v_source in select allocation_id,amount_kobo from app_private.withdrawal_source_allocations
      where withdrawal_id=v_request.withdrawal_id order by allocation_id loop
      v_entries:=v_entries||pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
        'account_code','worker_withdrawal_reserved','direction','debit',
        'amount_kobo',v_source.amount_kobo::text,'allocation_id',v_source.allocation_id::text,'owner_id',v_request.actor_id::text));
    end loop;
    if v_fee>0 then
      v_entries:=v_entries||pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
        'account_code','provider_payout_fee_expense','direction','debit','amount_kobo',v_fee::text));
    end if;
    v_entries:=v_entries||pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'account_code','provider_available_cash','direction','credit',
      'amount_kobo',(v_request.amount_kobo+v_fee)::text));
    perform app_private.post_financial_journal(v_request.payout_effect_id,'payout_settled',
      v_request.withdrawal_id,v_request.actor_id,v_entries);
    update app_private.withdrawal_requests set status='paid' where withdrawal_id=v_request.withdrawal_id;
    perform app_private.audit_wallet_event(v_request.actor_id,'withdrawal_status_changed',v_request.withdrawal_id,
      pg_catalog.jsonb_build_object('status','paid','amount_kobo',v_request.amount_kobo::text,
        'destination_version',v_request.destination_version));
  elsif v_status='failed' and v_request.status in ('processing','unknown') then
    for v_source in select allocation_id,amount_kobo from app_private.withdrawal_source_allocations
      where withdrawal_id=v_request.withdrawal_id order by allocation_id loop
      v_entries:=v_entries||pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('account_code','worker_withdrawal_reserved','direction','debit',
          'amount_kobo',v_source.amount_kobo::text,'allocation_id',v_source.allocation_id::text,'owner_id',v_request.actor_id::text),
        pg_catalog.jsonb_build_object('account_code','worker_earnings_available','direction','credit',
          'amount_kobo',v_source.amount_kobo::text,'allocation_id',v_source.allocation_id::text,'owner_id',v_request.actor_id::text));
    end loop;
    if v_fee>0 then
      v_entries:=v_entries||pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('account_code','provider_payout_fee_expense','direction','debit','amount_kobo',v_fee::text),
        pg_catalog.jsonb_build_object('account_code','provider_available_cash','direction','credit','amount_kobo',v_fee::text));
    end if;
    perform app_private.post_financial_journal(v_request.failure_effect_id,'compensating_correction',
      v_request.withdrawal_id,v_request.actor_id,v_entries);
    update app_private.withdrawal_requests set status='failed' where withdrawal_id=v_request.withdrawal_id;
    perform app_private.audit_wallet_event(v_request.actor_id,'withdrawal_status_changed',v_request.withdrawal_id,
      pg_catalog.jsonb_build_object('status','failed','amount_kobo',v_request.amount_kobo::text));
  elsif v_status='reversed' and v_request.status='paid' then
    v_entries:=pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'account_code','provider_available_cash','direction','debit',
      'amount_kobo',v_request.amount_kobo::text));
    for v_source in select allocation_id,amount_kobo from app_private.withdrawal_source_allocations
      where withdrawal_id=v_request.withdrawal_id order by allocation_id loop
      v_entries:=v_entries||pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
        'account_code','worker_earnings_available','direction','credit',
        'amount_kobo',v_source.amount_kobo::text,'allocation_id',v_source.allocation_id::text,
        'owner_id',v_request.actor_id::text));
    end loop;
    perform app_private.post_financial_journal(v_request.reversal_effect_id,'compensating_correction',
      v_request.withdrawal_id,v_request.actor_id,v_entries);
    update app_private.withdrawal_requests set status='reversed' where withdrawal_id=v_request.withdrawal_id;
    perform app_private.audit_wallet_event(v_request.actor_id,'withdrawal_status_changed',v_request.withdrawal_id,
      pg_catalog.jsonb_build_object('status','reversed','amount_kobo',v_request.amount_kobo::text));
  end if;
  select * into v_request from app_private.withdrawal_requests where withdrawal_id=v_request.withdrawal_id;
  return v_result||pg_catalog.jsonb_build_object('withdrawal_status',v_request.status);
end;
$function$;

create function app_private.complete_funding_settlement_for_runner(
  p_operation_id uuid,p_settlement_status text
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_attempt app_private.funding_attempts%rowtype;
  v_operation app_private.provider_operations%rowtype;
  v_settlement_id uuid;
  v_journal uuid;
begin
  if p_settlement_status not in ('pending','available','unknown') then
    raise exception using errcode='22023',message='invalid_settlement_status';
  end if;
  select * into v_operation from app_private.provider_operations
    where operation_id=p_operation_id and operation_type='collection'
      and provider_adapter='local_simulator' for update;
  if not found then raise exception using errcode='22023',message='payment_operation_not_simulated'; end if;
  select * into v_attempt from app_private.funding_attempts where operation_id=p_operation_id for update;
  if not found or v_attempt.status<>'succeeded' then return pg_catalog.jsonb_build_object('settlement_status',null); end if;
  if p_settlement_status<>'available' or v_attempt.settlement_status='available' then
    return pg_catalog.jsonb_build_object('settlement_status',v_attempt.settlement_status);
  end if;
  if v_attempt.settlement_status not in ('pending','unknown') then
    raise exception using errcode='22023',message='settlement_mismatch';
  end if;
  v_settlement_id:=pg_catalog.gen_random_uuid();
  v_journal:=app_private.post_financial_journal(v_settlement_id,'provider_settlement',
    v_attempt.attempt_id,null,pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('account_code','provider_available_cash','direction','debit',
        'amount_kobo',v_attempt.provider_net_kobo::text),
      pg_catalog.jsonb_build_object('account_code','provider_collection_receivable','direction','credit',
        'amount_kobo',v_attempt.provider_net_kobo::text)
    ));
  insert into app_private.provider_settlement_records(attempt_id,settlement_effect_id,journal_id)
    values(v_attempt.attempt_id,v_settlement_id,v_journal);
  update app_private.funding_attempts set settlement_status='available'
    where attempt_id=v_attempt.attempt_id;
  return pg_catalog.jsonb_build_object('settlement_status','available','journal_id',v_journal);
end;
$function$;

create function public.server_complete_job_funding_settlement_for_runner(
  p_operation_id uuid,p_settlement_status text
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare v_result jsonb;
begin
  v_result:=app_private.complete_funding_settlement_for_runner(p_operation_id,p_settlement_status);
  return v_result;
end;
$function$;

create function public.server_complete_worker_payout_for_runner(
  p_operation_id uuid,p_lease_token uuid,p_status text,p_provider_reference text,
  p_amount_kobo text,p_currency text,p_client_reference uuid,p_destination_id uuid,
  p_destination_version integer,p_fee_kobo text,p_safe_error_code text,p_retry boolean,
  p_result_sha256_hex text
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.complete_worker_payout_for_runner(
    p_operation_id,p_lease_token,p_status,p_provider_reference,p_amount_kobo,p_currency,
    p_client_reference,p_destination_id,p_destination_version,p_fee_kobo,p_safe_error_code,
    p_retry,p_result_sha256_hex
  )
$function$;

create function app_private.get_my_wallet_for_actor(
  p_actor uuid,p_before_created_at timestamptz,p_before_id uuid
) returns jsonb language plpgsql stable security definer set search_path = '' as $function$
declare
  v_identity app_private.identity_accounts%rowtype;
  v_suspended boolean;
  v_caps text[];
  v_destination jsonb;
  v_balances jsonb;
  v_withdrawals jsonb;
  v_activity jsonb;
  v_next_cursor text;
  v_activity_count integer;
begin
  select * into v_identity from app_private.identity_accounts where user_id=p_actor;
  if not found or v_identity.verification_status<>'approved'
     or v_identity.account_type not in ('student','partner') then
    raise exception using errcode='42501',message='wallet_access_denied';
  end if;
  v_caps:=app_private.current_profile_capabilities(p_actor);
  v_suspended:=v_identity.account_status='suspended';
  if not v_suspended and pg_catalog.cardinality(v_caps)=0 then
    raise exception using errcode='42501',message='wallet_access_denied';
  end if;
  if p_before_created_at is null <> (p_before_id is null) then
    raise exception using errcode='22023',message='invalid_wallet_cursor';
  end if;

  select pg_catalog.jsonb_build_object(
    'available_earnings_kobo',coalesce((select -sum(b.balance_kobo) from app_private.ledger_account_balances b
      join app_private.ledger_accounts a using(account_id)
      where a.account_code='worker_earnings_available' and b.owner_id=p_actor),0)::text,
    'held_allocations_kobo',coalesce((select sum(p.gross_principal_kobo) from app_private.principal_allocations p
      join app_private.assignments s on s.assignment_id=p.assignment_id
      where s.worker_id=p_actor and p.status='assigned'),0)::text,
    'case_held_kobo',coalesce((select sum(p.gross_principal_kobo) from app_private.principal_allocations p
      join app_private.assignments s on s.assignment_id=p.assignment_id
      where s.worker_id=p_actor and p.status='dispute_held'),0)::text,
    'withdrawal_reserved_kobo',coalesce((select -sum(b.balance_kobo) from app_private.ledger_account_balances b
      join app_private.ledger_accounts a using(account_id)
      where a.account_code='worker_withdrawal_reserved' and b.owner_id=p_actor),0)::text,
    'withdrawal_queued_kobo',coalesce((select sum(w.amount_kobo) from app_private.withdrawal_requests w
      where w.actor_id=p_actor and w.status='queued_for_liquidity'),0)::text,
    'withdrawal_processing_kobo',coalesce((select sum(w.amount_kobo) from app_private.withdrawal_requests w
      where w.actor_id=p_actor and w.status='processing'),0)::text,
    'withdrawal_unknown_kobo',coalesce((select sum(w.amount_kobo) from app_private.withdrawal_requests w
      where w.actor_id=p_actor and w.status in ('unknown','exception')),0)::text,
    'poster_held_principal_kobo',coalesce((select sum(p.gross_principal_kobo) from app_private.principal_allocations p
      where p.poster_id=p_actor and p.status in ('unassigned','assigned','dispute_held')),0)::text
  ) into v_balances;

  select app_private.wallet_destination_projection(d.destination_id,d.current_version)
  into v_destination from app_private.wallet_destinations d
  where d.owner_id=p_actor and d.current_version>0 order by d.updated_at desc limit 1;

  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'withdrawal_id',q.withdrawal_id,'status',q.status,'amount_kobo',q.amount_kobo::text,
    'destination_id',q.destination_id,'destination_version',q.destination_version,
    'institution_label',q.institution_label,'recipient_label',q.recipient_label,
    'masked_reference',q.masked_reference,'ownership_verification','simulator_only',
    'created_at',q.created_at,'updated_at',q.updated_at
  ) order by q.created_at desc,q.withdrawal_id desc),'[]'::jsonb)
  into v_withdrawals from (
    select w.* from app_private.withdrawal_requests w
    where w.actor_id=p_actor and (not v_suspended or w.status in (
      'queued_for_liquidity','processing','unknown','exception'))
    order by w.created_at desc,w.withdrawal_id desc limit 20
  ) q;

  with activity as (
    select e.event_id as activity_id,'earnings_released'::text as activity_type,
      sum(le.amount_kobo) filter(where a.account_code='worker_earnings_available'
        and le.owner_id=p_actor and le.direction='credit')::bigint as amount_kobo,
      sum(le.amount_kobo) filter(where a.account_code='platform_commission_revenue'
        and le.direction='credit')::bigint as commission_kobo,
      null::text as status,e.created_at
    from app_private.financial_audit_events e
    join app_private.ledger_journal_transactions j on j.journal_id=e.journal_id
    join app_private.ledger_journal_entries le on le.journal_id=j.journal_id
    join app_private.ledger_accounts a on a.account_id=le.account_id
    where e.event_type='financial_journal_posted' and j.effect_type='completion_released'
      and exists(select 1 from app_private.ledger_journal_entries owned
        join app_private.ledger_accounts owned_account on owned_account.account_id=owned.account_id
        where owned.journal_id=j.journal_id and owned.owner_id=p_actor
          and owned.direction='credit' and owned_account.account_code='worker_earnings_available')
    group by e.event_id,e.created_at
    union all
    select e.event_id,'poster_principal_funded',
      sum(le.amount_kobo) filter(where a.account_code='job_principal_unassigned')::bigint,
      null::bigint,null::text,e.created_at
    from app_private.financial_audit_events e
    join app_private.ledger_journal_transactions j on j.journal_id=e.journal_id
    join app_private.ledger_journal_entries le on le.journal_id=j.journal_id
    join app_private.ledger_accounts a on a.account_id=le.account_id
    join app_private.principal_allocations p on p.allocation_id=le.allocation_id
    where e.event_type='financial_journal_posted' and j.effect_type='funding_collected'
      and p.poster_id=p_actor and le.direction='credit'
    group by e.event_id,e.created_at
    union all
    select e.event_id,
      case e.event_data->>'status' when 'paid' then 'withdrawal_paid'
        when 'failed' then 'withdrawal_failed' when 'reversed' then 'withdrawal_reversed'
        else 'withdrawal_requested' end,
      w.amount_kobo,null::bigint,e.event_data->>'status',e.created_at
    from app_private.financial_audit_events e
    join app_private.withdrawal_requests w on w.withdrawal_id=e.reference_id
    where e.event_type in ('withdrawal_requested','withdrawal_status_changed')
      and w.actor_id=p_actor
    group by e.event_id,w.withdrawal_id,w.amount_kobo,e.event_data,e.created_at
  ), page as (
    select * from activity
    where (p_before_created_at is null or (created_at,activity_id)<(p_before_created_at,p_before_id))
    order by created_at desc,activity_id desc limit 21
  ), numbered as (
    select page.*,row_number() over(order by created_at desc,activity_id desc) as rn,
      count(*) over() as total_rows from page
  )
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'activity_id',activity_id,'activity_type',activity_type,
      'amount_kobo',coalesce(amount_kobo,0)::text,
      'commission_kobo',case when commission_kobo is null then null else commission_kobo::text end,
      'status',status,'created_at',created_at
    ) order by created_at desc,activity_id desc) filter(where rn<=20),'[]'::jsonb),
    max(total_rows)::integer
  into v_activity,v_activity_count from numbered;
  if v_activity_count>20 then
    select rtrim(translate(pg_catalog.encode(pg_catalog.convert_to(
      pg_catalog.jsonb_build_object('version',1,'created_at',created_at,'id',activity_id)::text,'UTF8'),'base64'),E'\n',''),'=')
    into v_next_cursor from (
      select created_at,activity_id from activity
      where (p_before_created_at is null or (created_at,activity_id)<(p_before_created_at,p_before_id))
      order by created_at desc,activity_id desc offset 19 limit 1
    ) cursor_row;
    v_next_cursor:=pg_catalog.translate(v_next_cursor,'+/','-_');
  end if;
  return pg_catalog.jsonb_build_object(
    'currency','NGN','balances',v_balances,'destination',case when v_suspended then null else v_destination end,
    'withdrawals',v_withdrawals,'activity',v_activity,'next_cursor',v_next_cursor,
    'refunds_available',false
  );
end;
$function$;

create function public.server_authorize_simulated_destination_change_for_actor(
  p_actor uuid,p_destination_id uuid,p_expected_version integer,p_simulated_recipient_code text,p_proof_sha256_hex text
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.authorize_simulated_destination_change_for_actor(
    p_actor,p_destination_id,p_expected_version,p_simulated_recipient_code,p_proof_sha256_hex)
$function$;
create function public.server_confirm_simulated_destination_change_for_actor(
  p_actor uuid,p_proof_sha256_hex text,p_simulated_recipient_code text,p_idempotency_key uuid
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.confirm_simulated_destination_change_for_actor(
    p_actor,p_proof_sha256_hex,p_simulated_recipient_code,p_idempotency_key)
$function$;
create function public.server_authorize_withdrawal_for_actor(
  p_actor uuid,p_amount_kobo text,p_destination_id uuid,p_destination_version integer,p_proof_sha256_hex text
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.authorize_withdrawal_for_actor(
    p_actor,p_amount_kobo,p_destination_id,p_destination_version,p_proof_sha256_hex)
$function$;
create function public.server_request_withdrawal_for_actor(
  p_actor uuid,p_amount_kobo text,p_destination_id uuid,p_destination_version integer,
  p_proof_sha256_hex text,p_expected_provider_fee_kobo text,p_idempotency_key uuid
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.request_withdrawal_for_actor(
    p_actor,p_amount_kobo,p_destination_id,p_destination_version,p_proof_sha256_hex,
    p_expected_provider_fee_kobo,p_idempotency_key)
$function$;
create function public.server_get_my_wallet_for_actor(
  p_actor uuid,p_before_created_at timestamptz,p_before_id uuid
) returns jsonb language sql stable security definer set search_path = '' as $function$
  select app_private.get_my_wallet_for_actor(p_actor,p_before_created_at,p_before_id)
$function$;
create function public.server_complete_job_funding_with_settlement_for_runner(
  p_operation_id uuid,p_lease_token uuid,p_status text,p_provider_reference text,
  p_amount_kobo text,p_currency text,p_merchant_identity text,p_client_reference uuid,
  p_fee_kobo text,p_safe_error_code text,p_retry boolean,p_result_sha256_hex text,
  p_settlement_status text
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare v_result jsonb; v_settlement jsonb;
begin
  v_result:=public.server_complete_job_funding_operation_for_runner(
    p_operation_id,p_lease_token,p_status,p_provider_reference,p_amount_kobo,p_currency,
    p_merchant_identity,p_client_reference,p_fee_kobo,p_safe_error_code,p_retry,p_result_sha256_hex);
  v_settlement:=app_private.complete_funding_settlement_for_runner(p_operation_id,p_settlement_status);
  return v_result||v_settlement;
end;
$function$;

revoke all on table app_private.wallet_destinations,app_private.wallet_destination_versions,
  app_private.withdrawal_requests,app_private.withdrawal_source_allocations,
  app_private.provider_settlement_records from public,anon,authenticated,service_role;
revoke all on function app_private.guard_wallet_destination_change(),
  app_private.wallet_destination_projection(uuid,integer),app_private.simulated_destination_labels(text),
  app_private.wallet_actor_is_active_worker(uuid),app_private.audit_wallet_event(uuid,text,uuid,jsonb),
  app_private.authorize_simulated_destination_change_for_actor(uuid,uuid,integer,text,text),
  app_private.confirm_simulated_destination_change_for_actor(uuid,text,text,uuid),
  app_private.authorize_withdrawal_for_actor(uuid,text,uuid,integer,text),
  app_private.try_start_queued_payouts_for_liquidity(),
  app_private.request_withdrawal_for_actor(uuid,text,uuid,integer,text,text,uuid),
  app_private.complete_worker_payout_for_runner(uuid,uuid,text,text,text,text,uuid,uuid,integer,text,text,boolean,text),
  app_private.complete_funding_settlement_for_runner(uuid,text),
  app_private.get_my_wallet_for_actor(uuid,timestamptz,uuid) from public,anon,authenticated,service_role;
revoke all on function public.server_authorize_simulated_destination_change_for_actor(uuid,uuid,integer,text,text),
  public.server_confirm_simulated_destination_change_for_actor(uuid,text,text,uuid),
  public.server_authorize_withdrawal_for_actor(uuid,text,uuid,integer,text),
  public.server_request_withdrawal_for_actor(uuid,text,uuid,integer,text,text,uuid),
  public.server_get_my_wallet_for_actor(uuid,timestamptz,uuid),
  public.server_complete_worker_payout_for_runner(uuid,uuid,text,text,text,text,uuid,uuid,integer,text,text,boolean,text),
  public.server_complete_job_funding_settlement_for_runner(uuid,text),
  public.server_complete_job_funding_with_settlement_for_runner(uuid,uuid,text,text,text,text,text,uuid,text,text,boolean,text,text)
  from public,anon,authenticated,service_role;
grant execute on function public.server_authorize_simulated_destination_change_for_actor(uuid,uuid,integer,text,text),
  public.server_confirm_simulated_destination_change_for_actor(uuid,text,text,uuid),
  public.server_authorize_withdrawal_for_actor(uuid,text,uuid,integer,text),
  public.server_request_withdrawal_for_actor(uuid,text,uuid,integer,text,text,uuid),
  public.server_get_my_wallet_for_actor(uuid,timestamptz,uuid),
  public.server_complete_worker_payout_for_runner(uuid,uuid,text,text,text,text,uuid,uuid,integer,text,text,boolean,text),
  public.server_complete_job_funding_settlement_for_runner(uuid,text),
  public.server_complete_job_funding_with_settlement_for_runner(uuid,uuid,text,text,text,text,text,uuid,text,text,boolean,text,text)
  to service_role;

commit;
