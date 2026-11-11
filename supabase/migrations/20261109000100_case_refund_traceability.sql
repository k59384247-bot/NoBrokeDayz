begin;

-- A currently assigned reviewer may retain read-only access to a closed case
-- so the outcome and its simulated refund can be traced after execution.
create function app_private.case_staff_trace_projection(
  p_actor uuid,p_case_id uuid,p_auth_aal text
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_case app_private.assignment_cases%rowtype;
  v_assignment app_private.assignments%rowtype;
  v_decision app_private.assignment_case_decision_versions%rowtype;
  v_finalization app_private.assignment_case_finalizations%rowtype;
  v_summary jsonb;
  v_trace jsonb;
  v_approvals jsonb;
  v_signoff jsonb;
  v_refund jsonb;
  v_refund_status text;
  v_refund_settled_at timestamptz;
begin
  if not app_private.lock_case_reviewer_scope(p_actor,p_auth_aal) then
    raise exception using errcode='42501',message='case_access_denied';
  end if;
  select * into v_case from app_private.assignment_cases
    where case_id=p_case_id;
  if not found then raise exception using errcode='P0002',message='case_not_found'; end if;
  select * into v_assignment from app_private.assignments
    where assignment_id=v_case.assignment_id;
  if v_case.reviewer_id is distinct from p_actor
     or p_actor in (v_assignment.worker_id,v_assignment.poster_id) then
    raise exception using errcode='42501',message='case_access_denied';
  end if;

  select * into v_finalization from app_private.assignment_case_finalizations
    where case_id=p_case_id;
  if found then
    select * into v_decision from app_private.assignment_case_decision_versions
      where decision_id=v_finalization.decision_id
        and decision_version=v_finalization.decision_version;
  else
    select * into v_decision from app_private.assignment_case_decision_versions
      where case_id=p_case_id order by decision_version desc limit 1;
  end if;

  if v_decision.decision_id is null then
    v_trace:=pg_catalog.jsonb_build_object('decision',null,'finalization',null);
    return pg_catalog.jsonb_build_object('traceability',v_trace);
  end if;

  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'approval_number',a.approval_number,'actor_id',a.approver_id,
      'approved_at',a.created_at) order by a.approval_number),'[]'::jsonb)
    into v_approvals
    from app_private.assignment_case_decision_approvals a
    where a.decision_id=v_decision.decision_id
      and a.decision_version=v_decision.decision_version
      and a.decision_sha256=v_decision.decision_sha256;
  select pg_catalog.jsonb_build_object('actor_id',s.senior_id,'signed_at',s.created_at)
    into v_signoff
    from app_private.assignment_case_decision_nonresponse_signoffs s
    where s.decision_id=v_decision.decision_id
      and s.decision_version=v_decision.decision_version
      and s.decision_sha256=v_decision.decision_sha256;

  if v_finalization.finalization_id is not null then
    v_refund:=null;
    v_refund_status:='not_applicable';
    if v_finalization.refund_payable_id is not null then
      select pg_catalog.jsonb_build_object(
          'status',coalesce(progress.status,'authorized'),
          'amount_kobo',payable.amount_kobo::text,
          'operation_id',mapping.operation_id,
          'operation_reference',operation.provider_operation_reference,
          'provider_refund_reference',settlement.provider_refund_reference,
          'source_collection_reference',mapping.original_provider_reference
        ),coalesce(progress.status,'authorized'),progress.settled_at
        into v_refund,v_refund_status,v_refund_settled_at
        from app_private.allocation_refund_payables payable
        left join app_private.allocation_refund_progress progress
          using(refund_payable_id)
        left join app_private.refund_operation_mappings mapping
          using(refund_payable_id)
        left join app_private.provider_operations operation
          on operation.operation_id=mapping.operation_id
        left join app_private.provider_refund_settlement_records settlement
          on settlement.operation_id=mapping.operation_id
        where payable.refund_payable_id=v_finalization.refund_payable_id;
      v_refund_status:=coalesce(v_refund_status,'authorized');
    end if;
    v_summary:=pg_catalog.jsonb_build_object(
      'status','executed','decision_version',v_finalization.decision_version,
      'outcome',v_finalization.outcome,
      'gross_principal_kobo',v_finalization.gross_principal_kobo::text,
      'worker_award_gross_kobo',v_finalization.worker_award_gross_kobo::text,
      'poster_refund_gross_kobo',v_finalization.poster_refund_gross_kobo::text,
      'retained_hold_gross_kobo',v_finalization.retained_hold_gross_kobo::text,
      'commission_kobo',v_finalization.commission_kobo::text,
      'worker_net_kobo',v_finalization.worker_net_kobo::text,
      'refund_status',v_refund_status,'refund_settled_at',v_refund_settled_at,
      'executed_at',v_finalization.executed_at);
    v_trace:=pg_catalog.jsonb_build_object(
      'decision',pg_catalog.jsonb_build_object(
        'decision_id',v_decision.decision_id,
        'decision_version',v_decision.decision_version,
        'decision_sha256',pg_catalog.encode(v_decision.decision_sha256,'hex'),
        'proposed_by',v_decision.proposed_by,'proposed_at',v_decision.created_at,
        'approvals',v_approvals,'senior_signoff',v_signoff),
      'finalization',pg_catalog.jsonb_build_object(
        'finalization_id',v_finalization.finalization_id,
        'decision_version',v_finalization.decision_version,
        'finalized_by',v_finalization.finalized_by,
        'finalized_at',v_finalization.executed_at,
        'refund',v_refund));
  else
    v_summary:=null;
    v_trace:=pg_catalog.jsonb_build_object(
      'decision',pg_catalog.jsonb_build_object(
        'decision_id',v_decision.decision_id,
        'decision_version',v_decision.decision_version,
        'decision_sha256',pg_catalog.encode(v_decision.decision_sha256,'hex'),
        'proposed_by',v_decision.proposed_by,'proposed_at',v_decision.created_at,
        'approvals',v_approvals,'senior_signoff',v_signoff),
      'finalization',null);
  end if;
  return pg_catalog.jsonb_build_object('finalization',v_summary,'traceability',v_trace);
end;
$function$;

create or replace function app_private.get_assignment_case_for_reviewer(
  p_actor uuid,p_case_id uuid,p_auth_aal text
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_case app_private.assignment_cases%rowtype;
  v_result jsonb;
begin
  if p_case_id is null or not app_private.lock_case_reviewer_scope(p_actor,p_auth_aal) then
    raise exception using errcode='42501',message='case_access_denied';
  end if;
  select * into v_case from app_private.assignment_cases
    where case_id=p_case_id and reviewer_id=p_actor;
  if not found or v_case.lifecycle_status not in (
      'open','under_review','contacting_other_party','verifying','decision_made','closed'
    ) then
    raise exception using errcode='42501',message='case_access_denied';
  end if;
  v_result:=app_private.get_assignment_case_for_reviewer_base(p_actor,p_case_id,p_auth_aal);
  v_result:=v_result||app_private.case_investigation_projection(p_case_id,p_actor,true);
  return v_result||app_private.case_staff_trace_projection(p_actor,p_case_id,p_auth_aal);
end;
$function$;

revoke all on function app_private.case_staff_trace_projection(uuid,uuid,text)
  from public,anon,authenticated,service_role;
revoke all on function app_private.get_assignment_case_for_reviewer(uuid,uuid,text)
  from public,anon,authenticated,service_role;
grant execute on function app_private.get_assignment_case_for_reviewer(uuid,uuid,text)
  to service_role;

commit;
