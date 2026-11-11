begin;

-- Refund claims must retain the collection identity needed by the existing runner check.
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
    'merchant_identity',v_operation.merchant_identity,
    'destination_id',v_operation.destination_id,'destination_version',v_operation.destination_version,
    'source_provider_reference',v_refund.original_provider_reference,
    'expected_provider_fee_kobo',v_refund.expected_provider_fee_kobo::text
  ));
end;
$function$;

revoke all on function app_private.claim_payment_operation_job(uuid,smallint)
  from public,anon,authenticated,service_role;
grant execute on function app_private.claim_payment_operation_job(uuid,smallint) to postgres;

commit;
