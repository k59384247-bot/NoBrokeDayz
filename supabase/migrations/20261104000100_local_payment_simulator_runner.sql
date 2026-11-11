begin;

create table app_private.payment_operation_jobs (
  job_id uuid primary key default pg_catalog.gen_random_uuid(),
  operation_id uuid not null unique references app_private.provider_operations(operation_id) on delete restrict,
  state text not null default 'queued' check (state in ('queued','leased','retry','complete','exhausted')),
  attempt_count smallint not null default 0 check (attempt_count between 0 and 5),
  max_attempts smallint not null default 5 check (max_attempts between 1 and 5),
  available_at timestamptz not null default pg_catalog.now(),
  lease_token uuid,
  lease_owner uuid,
  lease_expires_at timestamptz,
  last_safe_error_code text check (last_safe_error_code is null or last_safe_error_code in (
    'provider_timeout','provider_unavailable','amount_mismatch','currency_mismatch',
    'reference_mismatch','unknown_result','settlement_pending'
  )),
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  check ((state='leased')=(lease_token is not null)),
  check ((state='leased')=(lease_owner is not null)),
  check ((state='leased')=(lease_expires_at is not null))
);
create index payment_operation_jobs_ready_idx
  on app_private.payment_operation_jobs(state,available_at,created_at);

create function app_private.queue_local_payment_operation()
returns trigger language plpgsql set search_path = '' as $function$
begin
  if new.provider_adapter='local_simulator'
     and new.operation_type in ('collection','payout') then
    insert into app_private.payment_operation_jobs(operation_id)
    values(new.operation_id)
    on conflict(operation_id) do nothing;
  end if;
  return new;
end;
$function$;
revoke all on function app_private.queue_local_payment_operation() from public,anon,authenticated,service_role;
create trigger provider_operation_local_queue after insert on app_private.provider_operations
for each row execute function app_private.queue_local_payment_operation();

create function app_private.guard_payment_operation_job()
returns trigger language plpgsql set search_path = '' as $function$
begin
  if tg_op='DELETE' then
    raise exception using errcode='55000',message='payment_operation_job_is_immutable';
  end if;
  if new.job_id is distinct from old.job_id
     or new.operation_id is distinct from old.operation_id
     or new.max_attempts is distinct from old.max_attempts
     or new.created_at is distinct from old.created_at
     or (new.attempt_count<old.attempt_count
       and not (old.state in ('retry','complete','exhausted') and new.state='queued' and new.attempt_count=0))
     or (new.attempt_count>old.attempt_count and new.attempt_count<>old.attempt_count+1
       and not (old.state in ('retry','complete','exhausted') and new.state='queued' and new.attempt_count=0)) then
    raise exception using errcode='55000',message='payment_operation_job_identity_is_immutable';
  end if;
  new.updated_at:=pg_catalog.now();
  return new;
end;
$function$;
revoke all on function app_private.guard_payment_operation_job() from public,anon,authenticated,service_role;
create trigger payment_operation_jobs_guard_change before update or delete on app_private.payment_operation_jobs
for each row execute function app_private.guard_payment_operation_job();

create function app_private.claim_payment_operation_job(p_worker_id uuid,p_lease_seconds smallint default 30)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_job app_private.payment_operation_jobs%rowtype;
  v_operation app_private.provider_operations%rowtype;
begin
  if p_worker_id is null or p_lease_seconds not between 5 and 120 then
    raise exception using errcode='22023',message='invalid_payment_job_claim';
  end if;
  update app_private.payment_operation_jobs
  set state='exhausted',lease_token=null,lease_owner=null,lease_expires_at=null,
      last_safe_error_code=coalesce(last_safe_error_code,'provider_timeout')
  where state='leased' and lease_expires_at<=pg_catalog.now() and attempt_count>=max_attempts;
  update app_private.provider_operations o
  set status='unknown',safe_error_code='provider_timeout'
  where o.operation_id in (
    select j.operation_id from app_private.payment_operation_jobs j
    where j.state='exhausted' and j.last_safe_error_code='provider_timeout'
  ) and o.status in ('pending','processing','unknown');

  select j.* into v_job
  from app_private.payment_operation_jobs j
  join app_private.provider_operations o using(operation_id)
  where (
    (j.state in ('queued','retry') and j.available_at<=pg_catalog.now()) or
    (j.state='leased' and j.lease_expires_at<=pg_catalog.now() and j.attempt_count<j.max_attempts)
  ) and o.provider_adapter='local_simulator'
    and o.operation_type in ('collection','payout')
    and o.status<>'queued_for_liquidity'
  order by j.available_at,j.created_at,j.job_id
  for update of j skip locked
  limit 1;
  if not found then return null; end if;

  update app_private.payment_operation_jobs
  set state='leased',attempt_count=attempt_count+1,lease_token=pg_catalog.gen_random_uuid(),
      lease_owner=p_worker_id,lease_expires_at=pg_catalog.now()+pg_catalog.make_interval(secs=>p_lease_seconds)
  where job_id=v_job.job_id returning * into v_job;
  select * into v_operation from app_private.provider_operations where operation_id=v_job.operation_id;
  return pg_catalog.jsonb_build_object(
    'job_id',v_job.job_id,'lease_token',v_job.lease_token,'attempt_count',v_job.attempt_count,
    'operation_id',v_operation.operation_id,'operation_type',v_operation.operation_type,
    'provider_operation_reference',v_operation.provider_operation_reference,
    'provider_idempotency_key',v_operation.provider_idempotency_key,
    'amount_kobo',v_operation.amount_kobo::text,'currency',v_operation.currency,
    'destination_id',v_operation.destination_id,'destination_version',v_operation.destination_version
  );
end;
$function$;
revoke all on function app_private.claim_payment_operation_job(uuid,smallint) from public,anon,authenticated,service_role;
grant execute on function app_private.claim_payment_operation_job(uuid,smallint) to postgres;

create function app_private.complete_payment_operation_job(
  p_operation_id uuid,p_lease_token uuid,p_status text,p_provider_reference text,
  p_fee_kobo text,p_safe_error_code text,p_retry boolean
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_job app_private.payment_operation_jobs%rowtype;
  v_operation app_private.provider_operations%rowtype;
  v_fee bigint;
  v_status text:=p_status;
  v_error text:=p_safe_error_code;
  v_retry boolean:=p_retry;
  v_final_state text;
begin
  if p_status not in ('processing','unknown','succeeded','failed','reversed','exception')
     or p_safe_error_code is not null and p_safe_error_code not in (
       'provider_timeout','provider_unavailable','amount_mismatch','currency_mismatch',
       'reference_mismatch','unknown_result','settlement_pending'
     ) or p_retry is null
     or (p_status in ('processing','unknown') and not p_retry)
     or (p_status in ('succeeded','failed','reversed','exception') and p_retry)
     or (p_status='exception' and p_safe_error_code is null) then
    raise exception using errcode='22023',message='invalid_payment_operation_result';
  end if;
  if p_fee_kobo is null or p_fee_kobo !~ '^(0|[1-9][0-9]{0,11})$' then
    raise exception using errcode='22023',message='invalid_provider_fee';
  end if;
  v_fee:=p_fee_kobo::bigint;
  if v_fee>1000000000 then raise exception using errcode='22023',message='invalid_provider_fee'; end if;

  select * into v_job from app_private.payment_operation_jobs
  where operation_id=p_operation_id for update;
  if not found or v_job.state<>'leased' or v_job.lease_token is distinct from p_lease_token
     or v_job.lease_expires_at<=pg_catalog.now() then
    raise exception using errcode='40001',message='payment_job_lease_lost';
  end if;
  select * into v_operation from app_private.provider_operations
  where operation_id=p_operation_id for update;
  if not found or v_operation.provider_adapter<>'local_simulator' then
    raise exception using errcode='22023',message='payment_operation_not_simulated';
  end if;
  if p_provider_reference is not null and v_operation.provider_operation_reference is not null
     and p_provider_reference<>v_operation.provider_operation_reference then
    v_status:='exception';v_error:='reference_mismatch';v_retry:=false;p_provider_reference:=null;
  end if;
  if v_status='reversed' and v_operation.status not in ('succeeded','settled','paid','reversed') then
    v_status:='exception';v_error:='unknown_result';v_retry:=false;
  end if;
  if p_provider_reference is not null and v_operation.provider_operation_reference is null then
    update app_private.provider_operations set provider_operation_reference=p_provider_reference
    where operation_id=p_operation_id;
  end if;
  if v_operation.fee_kobo=0 or v_operation.fee_kobo=v_fee then
    update app_private.provider_operations set status=v_status,fee_kobo=v_fee,
      safe_error_code=v_error where operation_id=p_operation_id;
  elsif v_operation.fee_kobo<>v_fee then
    v_status:='exception';v_error:='amount_mismatch';v_retry:=false;
    update app_private.provider_operations set status=v_status,safe_error_code=v_error
    where operation_id=p_operation_id;
  end if;

  if v_status='exception' then
    insert into app_private.financial_exceptions(operation_id,exception_type,safe_reference)
    values(p_operation_id,
      case v_error when 'amount_mismatch' then 'amount_mismatch'
        when 'currency_mismatch' then 'currency_mismatch'
        when 'reference_mismatch' then 'reference_mismatch'
        when 'provider_unavailable' then 'provider_unavailable'
        else 'unknown_result' end,
      p_provider_reference);
  end if;
  if v_retry and v_job.attempt_count<v_job.max_attempts then
    v_final_state:='retry';
  elsif v_retry then
    v_final_state:='exhausted';
  else
    v_final_state:='complete';
  end if;
  update app_private.payment_operation_jobs
  set state=v_final_state,
      available_at=case when v_final_state='retry' then pg_catalog.now()+
        pg_catalog.make_interval(secs=>least(60,power(2,v_job.attempt_count)::integer)) else available_at end,
      lease_token=null,lease_owner=null,lease_expires_at=null,last_safe_error_code=v_error
  where job_id=v_job.job_id returning * into v_job;
  return pg_catalog.jsonb_build_object(
    'operation_id',p_operation_id,'operation_status',v_status,'job_state',v_job.state,
    'attempt_count',v_job.attempt_count,'reconcile_required',v_final_state='exhausted'
  );
end;
$function$;
revoke all on function app_private.complete_payment_operation_job(uuid,uuid,text,text,text,text,boolean) from public,anon,authenticated,service_role;
grant execute on function app_private.complete_payment_operation_job(uuid,uuid,text,text,text,text,boolean) to postgres;

create function app_private.record_local_simulator_receipt(
  p_event_reference text,p_client_reference uuid,p_provider_reference text,p_payload_sha256_hex text
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_operation app_private.provider_operations%rowtype;
  v_receipt app_private.provider_webhook_receipts%rowtype;
  v_digest bytea;
  v_matched boolean:=false;
  v_candidate_operation_id uuid;
begin
  if p_event_reference !~ '^[A-Za-z0-9_-]{8,120}$' or p_client_reference is null
     or p_provider_reference is null or char_length(p_provider_reference)>180
     or p_payload_sha256_hex !~ '^[0-9a-f]{64}$' then
    raise exception using errcode='22023',message='invalid_simulator_receipt';
  end if;
  v_digest:=pg_catalog.decode(p_payload_sha256_hex,'hex');
  select * into v_operation from app_private.provider_operations
  where provider_idempotency_key=p_client_reference and provider_adapter='local_simulator';
  if found then v_candidate_operation_id:=v_operation.operation_id; end if;
  if v_candidate_operation_id is not null and p_provider_reference='sim-'||p_client_reference::text then
    v_matched:=true;
  else
    v_operation.operation_id:=null;
  end if;
  insert into app_private.provider_webhook_receipts(
    provider_adapter,provider_event_reference,operation_id,payload_sha256
  ) values('local_simulator',p_event_reference,v_operation.operation_id,v_digest)
  on conflict(provider_adapter,provider_event_reference) do nothing;
  if not found then
    select * into v_receipt from app_private.provider_webhook_receipts
    where provider_adapter='local_simulator' and provider_event_reference=p_event_reference;
    if v_receipt.payload_sha256<>v_digest then
      raise exception using errcode='23505',message='simulator_event_reference_conflict';
    end if;
    return pg_catalog.jsonb_build_object('duplicate',true,'matched',v_receipt.operation_id is not null);
  end if;
  if v_matched then
    update app_private.payment_operation_jobs
    set state='queued',attempt_count=0,available_at=pg_catalog.now(),lease_token=null,
      lease_owner=null,lease_expires_at=null,last_safe_error_code=null
    where operation_id=v_operation.operation_id and state in ('retry','complete','exhausted');
  elsif v_candidate_operation_id is not null then
    insert into app_private.financial_exceptions(operation_id,exception_type,safe_reference)
    values(v_candidate_operation_id,'reference_mismatch',p_event_reference);
  end if;
  return pg_catalog.jsonb_build_object('duplicate',false,'matched',v_matched);
end;
$function$;
revoke all on function app_private.record_local_simulator_receipt(text,uuid,text,text) from public,anon,authenticated,service_role;
grant execute on function app_private.record_local_simulator_receipt(text,uuid,text,text) to postgres;

create function public.server_claim_payment_operation_for_runner(p_worker_id uuid,p_lease_seconds smallint default 30)
returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.claim_payment_operation_job(p_worker_id,p_lease_seconds)
$function$;
revoke all on function public.server_claim_payment_operation_for_runner(uuid,smallint) from public,anon,authenticated,service_role;
grant execute on function public.server_claim_payment_operation_for_runner(uuid,smallint) to service_role;

create function public.server_complete_payment_operation_for_runner(
  p_operation_id uuid,p_lease_token uuid,p_status text,p_provider_reference text,
  p_fee_kobo text,p_safe_error_code text,p_retry boolean
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.complete_payment_operation_job(
    p_operation_id,p_lease_token,p_status,p_provider_reference,p_fee_kobo,p_safe_error_code,p_retry
  )
$function$;
revoke all on function public.server_complete_payment_operation_for_runner(uuid,uuid,text,text,text,text,boolean) from public,anon,authenticated,service_role;
grant execute on function public.server_complete_payment_operation_for_runner(uuid,uuid,text,text,text,text,boolean) to service_role;

create function public.server_record_payment_simulator_receipt(
  p_event_reference text,p_client_reference uuid,p_provider_reference text,p_payload_sha256_hex text
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.record_local_simulator_receipt(
    p_event_reference,p_client_reference,p_provider_reference,p_payload_sha256_hex
  )
$function$;
revoke all on function public.server_record_payment_simulator_receipt(text,uuid,text,text) from public,anon,authenticated,service_role;
grant execute on function public.server_record_payment_simulator_receipt(text,uuid,text,text) to service_role;

revoke all on table app_private.payment_operation_jobs from public,anon,authenticated,service_role;
revoke all on function app_private.queue_local_payment_operation(),app_private.guard_payment_operation_job() from public,anon,authenticated,service_role;

commit;
