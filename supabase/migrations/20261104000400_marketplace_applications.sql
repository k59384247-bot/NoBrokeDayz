begin;

alter table app_private.jobs drop constraint jobs_listing_state_check;
alter table app_private.jobs drop constraint jobs_check;
alter table app_private.jobs
  add constraint jobs_listing_state_check
    check (listing_state in ('draft','awaiting_payment','open','filled','expired')),
  add constraint jobs_funded_state_check check (
    (listing_state='draft' and active_funding_intent_id is null and funded_funding_intent_id is null) or
    (listing_state='awaiting_payment' and active_funding_intent_id is not null and funded_funding_intent_id is null) or
    (listing_state in ('open','filled','expired') and active_funding_intent_id is null and funded_funding_intent_id is not null)
  ),
  add constraint jobs_identity_poster_key unique(job_id,poster_id);

alter table app_private.job_terms_versions
  add constraint job_terms_assignment_snapshot_key
    unique(job_id,terms_version,terms_sha256,gross_per_worker_kobo);

alter table app_private.principal_allocations
  add constraint principal_allocations_assignment_snapshot_key
    unique(allocation_id,job_id,poster_id,funding_intent_id,gross_principal_kobo,commission_basis_points);

alter table app_private.marketplace_outbox drop constraint marketplace_outbox_event_type_check;
alter table app_private.marketplace_outbox
  add constraint marketplace_outbox_event_type_check check (event_type in (
    'job.draft_created','job.draft_updated','job.funding_started','job.funded',
    'job.funding_failed','job.funding_exception','job.application_created',
    'job.application_accepted','job.application_rejected','job.application_withdrawn',
    'job.application_closed','job.message_created'
  ));

alter table app_private.financial_command_idempotency
  drop constraint financial_command_idempotency_command_name_check;
alter table app_private.financial_command_idempotency
  add constraint financial_command_idempotency_command_name_check check (command_name in (
    'create_job_draft','update_job_draft','fund_job','apply_to_job','accept_application',
    'reject_application','withdraw_application','start_assignment','submit_assignment',
    'confirm_completion','open_assignment_hold','prepare_withdrawal_confirmation',
    'request_withdrawal','prepare_bank_destination_change','change_bank_destination'
  ));

create table app_private.job_applications (
  application_id uuid primary key default pg_catalog.gen_random_uuid(),
  job_id uuid not null references app_private.jobs(job_id) on delete restrict,
  worker_id uuid not null references auth.users(id) on delete restrict,
  applied_terms_version integer not null,
  note text check (note is null or char_length(note) between 1 and 500),
  state text not null default 'applied'
    check (state in ('applied','accepted','rejected','withdrawn','closed')),
  applied_at timestamptz not null default pg_catalog.now(),
  decided_at timestamptz,
  decided_by uuid references auth.users(id) on delete restrict,
  unique(job_id,worker_id),
  unique(application_id,job_id,worker_id,applied_terms_version),
  foreign key(job_id,applied_terms_version)
    references app_private.job_terms_versions(job_id,terms_version) on delete restrict,
  check ((state='applied' and decided_at is null and decided_by is null) or
    (state<>'applied' and decided_at is not null and decided_by is not null))
);
create index job_applications_job_inbox_idx
  on app_private.job_applications(job_id,applied_at desc,application_id desc);
create index job_applications_worker_history_idx
  on app_private.job_applications(worker_id,applied_at desc,application_id desc);

create table app_private.application_threads (
  thread_id uuid primary key default pg_catalog.gen_random_uuid(),
  application_id uuid not null unique
    references app_private.job_applications(application_id) on delete restrict,
  last_sequence bigint not null default 0 check (last_sequence >= 0),
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now()
);

create table app_private.assignments (
  assignment_id uuid primary key default pg_catalog.gen_random_uuid(),
  application_id uuid not null unique,
  job_id uuid not null,
  worker_id uuid not null references auth.users(id) on delete restrict,
  poster_id uuid not null references auth.users(id) on delete restrict,
  allocation_id uuid not null unique,
  funding_intent_id uuid not null references app_private.funding_intents(intent_id) on delete restrict,
  terms_version integer not null,
  terms_sha256 bytea not null check (pg_catalog.octet_length(terms_sha256)=32),
  gross_principal_kobo bigint not null check (gross_principal_kobo > 0),
  commission_basis_points smallint not null check (commission_basis_points=500),
  work_state text not null default 'assigned'
    check (work_state in ('assigned','in_progress','submitted','completed','cancelled')),
  created_at timestamptz not null default pg_catalog.now(),
  foreign key(application_id,job_id,worker_id,terms_version)
    references app_private.job_applications(application_id,job_id,worker_id,applied_terms_version)
    on delete restrict,
  foreign key(job_id,poster_id)
    references app_private.jobs(job_id,poster_id) on delete restrict,
  foreign key(allocation_id,job_id,poster_id,funding_intent_id,
      gross_principal_kobo,commission_basis_points)
    references app_private.principal_allocations(allocation_id,job_id,poster_id,
      funding_intent_id,gross_principal_kobo,commission_basis_points) on delete restrict,
  foreign key(job_id,terms_version,terms_sha256,gross_principal_kobo)
    references app_private.job_terms_versions(job_id,terms_version,terms_sha256,gross_per_worker_kobo)
    on delete restrict
);
create index assignments_worker_history_idx
  on app_private.assignments(worker_id,created_at desc,assignment_id desc);
alter table app_private.principal_allocations
  add constraint principal_allocations_assignment_id_fk
    foreign key(assignment_id) references app_private.assignments(assignment_id) on delete restrict;

create table app_private.in_app_notifications (
  notification_id uuid primary key default pg_catalog.gen_random_uuid(),
  event_id uuid not null references app_private.marketplace_outbox(event_id) on delete restrict,
  recipient_id uuid not null references auth.users(id) on delete restrict,
  notification_type text not null check (notification_type in (
    'application_received','application_accepted','application_rejected',
    'application_withdrawn','application_closed','new_message'
  )),
  read_at timestamptz,
  created_at timestamptz not null default pg_catalog.now(),
  unique(recipient_id,event_id,notification_type)
);
create index in_app_notifications_recipient_unread_idx
  on app_private.in_app_notifications(recipient_id,created_at desc)
  where read_at is null;

create or replace function app_private.guard_job_change()
returns trigger language plpgsql set search_path = '' as $function$
begin
  if tg_op='DELETE' then
    raise exception using errcode='55000',message='job_record_is_immutable';
  end if;
  if new.job_id is distinct from old.job_id or new.poster_id is distinct from old.poster_id
     or new.created_at is distinct from old.created_at
     or new.current_terms_version < old.current_terms_version
     or new.current_terms_version > old.current_terms_version+1 then
    raise exception using errcode='55000',message='job_identity_is_immutable';
  end if;
  if new.current_terms_version<>old.current_terms_version and
     (old.listing_state<>'draft' or new.listing_state<>'draft'
      or old.active_funding_intent_id is not null or old.funded_funding_intent_id is not null) then
    raise exception using errcode='55000',message='job_terms_are_immutable';
  end if;
  if new.active_funding_intent_id is distinct from old.active_funding_intent_id then
    if not (
      (old.active_funding_intent_id is null and new.active_funding_intent_id is not null
        and new.listing_state='awaiting_payment' and old.listing_state='draft') or
      (old.active_funding_intent_id is not null and new.active_funding_intent_id is null
        and new.listing_state in ('draft','open','expired') and old.listing_state='awaiting_payment')
    ) then
      raise exception using errcode='55000',message='job_funding_state_is_immutable';
    end if;
  end if;
  if new.funded_funding_intent_id is distinct from old.funded_funding_intent_id and
     not (old.funded_funding_intent_id is null and new.funded_funding_intent_id is not null
       and old.listing_state='awaiting_payment' and new.listing_state in ('open','expired')) then
    raise exception using errcode='55000',message='job_funding_state_is_immutable';
  end if;
  if new.listing_state is distinct from old.listing_state and not (
    (old.listing_state='draft' and new.listing_state='awaiting_payment') or
    (old.listing_state='awaiting_payment' and new.listing_state in ('draft','open','expired')) or
    (old.listing_state='open' and new.listing_state in ('filled','expired')) or
    (old.listing_state='expired' and new.listing_state='filled')
  ) then
    raise exception using errcode='55000',message='invalid_job_state_transition';
  end if;
  new.updated_at:=pg_catalog.now();
  return new;
end;
$function$;

create function app_private.guard_job_application_change()
returns trigger language plpgsql set search_path = '' as $function$
begin
  if tg_op='DELETE' or new.application_id is distinct from old.application_id
     or new.job_id is distinct from old.job_id or new.worker_id is distinct from old.worker_id
     or new.applied_terms_version is distinct from old.applied_terms_version
     or new.note is distinct from old.note or new.applied_at is distinct from old.applied_at then
    raise exception using errcode='55000',message='application_record_is_immutable';
  end if;
  if new.state is distinct from old.state and not (
    (old.state='applied' and new.state in ('accepted','rejected','withdrawn','closed')) or
    (old.state='accepted' and new.state='closed')
  ) then
    raise exception using errcode='55000',message='invalid_application_state_transition';
  end if;
  if new.state=old.state and
     (new.decided_at is distinct from old.decided_at or new.decided_by is distinct from old.decided_by) then
    raise exception using errcode='55000',message='application_record_is_immutable';
  end if;
  return new;
end;
$function$;
create trigger job_applications_guard_change before update or delete on app_private.job_applications
for each row execute function app_private.guard_job_application_change();

create function app_private.reject_assignment_mutation()
returns trigger language plpgsql set search_path = '' as $function$
begin
  if tg_op='DELETE' then
    raise exception using errcode='55000',message='assignment_record_is_immutable';
  end if;
  if new.assignment_id is distinct from old.assignment_id
     or new.application_id is distinct from old.application_id
     or new.job_id is distinct from old.job_id
     or new.worker_id is distinct from old.worker_id
     or new.poster_id is distinct from old.poster_id
     or new.allocation_id is distinct from old.allocation_id
     or new.funding_intent_id is distinct from old.funding_intent_id
     or new.terms_version is distinct from old.terms_version
     or new.terms_sha256 is distinct from old.terms_sha256
     or new.gross_principal_kobo is distinct from old.gross_principal_kobo
     or new.commission_basis_points is distinct from old.commission_basis_points
     or new.work_state is distinct from old.work_state
     or new.created_at is distinct from old.created_at then
    raise exception using errcode='55000',message='assignment_record_is_immutable';
  end if;
  return new;
end;
$function$;
create trigger assignments_immutable before update or delete on app_private.assignments
for each row execute function app_private.reject_assignment_mutation();

create function app_private.validate_assignment_allocation_pair()
returns trigger language plpgsql security definer set search_path = '' as $function$
begin
  if tg_table_name='principal_allocations' then
    if new.status='assigned' and not exists (
      select 1 from app_private.assignments a
      where a.assignment_id=new.assignment_id and a.allocation_id=new.allocation_id
        and a.job_id=new.job_id and a.poster_id=new.poster_id
        and a.funding_intent_id=new.funding_intent_id
        and a.gross_principal_kobo=new.gross_principal_kobo
        and a.commission_basis_points=new.commission_basis_points
    ) then
      raise exception using errcode='22023',message='invalid_assignment_allocation_binding';
    end if;
  else
    if not exists (
      select 1 from app_private.principal_allocations p
      where p.allocation_id=new.allocation_id and p.assignment_id=new.assignment_id
        and p.status='assigned' and p.job_id=new.job_id and p.poster_id=new.poster_id
        and p.funding_intent_id=new.funding_intent_id
        and p.gross_principal_kobo=new.gross_principal_kobo
        and p.commission_basis_points=new.commission_basis_points
    ) then
      raise exception using errcode='22023',message='invalid_assignment_allocation_binding';
    end if;
  end if;
  return null;
end;
$function$;
create constraint trigger principal_allocation_assignment_binding
after insert or update on app_private.principal_allocations
deferrable initially deferred for each row
execute function app_private.validate_assignment_allocation_pair();
create constraint trigger assignment_principal_allocation_binding
after insert or update on app_private.assignments
deferrable initially deferred for each row
execute function app_private.validate_assignment_allocation_pair();

create function app_private.application_command_projection(p_application_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $function$
  select pg_catalog.jsonb_build_object(
    'application_id',a.application_id,
    'thread_id',t.thread_id,
    'job_id',a.job_id,
    'state',a.state,
    'note',a.note,
    'terms_version',a.applied_terms_version,
    'applied_at',a.applied_at,
    'assignment_id',s.assignment_id
  )
  from app_private.job_applications a
  join app_private.application_threads t using(application_id)
  left join app_private.assignments s using(application_id)
  where a.application_id=p_application_id
$function$;

create function app_private.add_in_app_notification(
  p_event_id uuid,p_recipient uuid,p_notification_type text
) returns void language sql security definer set search_path = '' as $function$
  insert into app_private.in_app_notifications(event_id,recipient_id,notification_type)
  values(p_event_id,p_recipient,p_notification_type)
$function$;

create function app_private.normalize_application_note(p_note text)
returns text language plpgsql immutable set search_path = '' as $function$
declare v_note text;
begin
  if p_note is null then return null; end if;
  v_note:=pg_catalog.regexp_replace(pg_catalog.btrim(p_note),'[[:space:]]+',' ','g');
  if v_note='' then return null; end if;
  if pg_catalog.char_length(v_note)>500 then
    raise exception using errcode='22023',message='invalid_application_note';
  end if;
  return v_note;
end;
$function$;

create function app_private.apply_to_job_for_actor(
  p_actor uuid,p_job_id uuid,p_note text,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_caps text[];
  v_note text;
  v_hash bytea;
  v_existing app_private.financial_command_idempotency%rowtype;
  v_job record;
  v_allocation_count integer;
  v_slots_remaining integer;
  v_application_id uuid;
  v_thread_id uuid;
  v_event_id uuid;
begin
  v_caps:=app_private.current_profile_capabilities(p_actor);
  if p_actor is null or p_job_id is null or p_idempotency_key is null then
    raise exception using errcode='22023',message='invalid_application_request';
  end if;
  if not ('can_work'=any(v_caps)) then
    raise exception using errcode='42501',message='verification_required';
  end if;
  v_note:=app_private.normalize_application_note(p_note);
  v_hash:=extensions.digest(pg_catalog.jsonb_build_object(
    'job_id',p_job_id,'note',v_note
  )::text,'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    p_actor::text||':apply_to_job:'||p_idempotency_key::text,428118));
  select * into v_existing from app_private.financial_command_idempotency
  where actor_id=p_actor and command_name='apply_to_job' and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.request_sha256<>v_hash then
      raise exception using errcode='23505',message='idempotency_conflict';
    end if;
    return app_private.application_command_projection(v_existing.response_reference_id);
  end if;

  select j.poster_id,j.listing_state,j.current_terms_version,j.funded_funding_intent_id,
    t.terms_version,t.terms_sha256,t.gross_per_worker_kobo,t.slot_count,t.gross_total_kobo,
    t.application_deadline_at,i.status,i.terms_version as intent_terms_version,
    i.gross_per_worker_kobo as intent_gross_per_worker_kobo,
    i.slot_count as intent_slot_count,i.gross_total_kobo as intent_gross_total_kobo,
    i.currency,i.terms_sha256 as intent_terms_sha256
  into v_job
  from app_private.jobs j
  join app_private.job_terms_versions t
    on t.job_id=j.job_id and t.terms_version=j.current_terms_version
  join app_private.funding_intents i
    on i.intent_id=j.funded_funding_intent_id
  where j.job_id=p_job_id
    and i.status='succeeded'
    and i.terms_version=t.terms_version
    and i.gross_per_worker_kobo=t.gross_per_worker_kobo
    and i.slot_count=t.slot_count and i.gross_total_kobo=t.gross_total_kobo
    and i.currency='NGN' and i.terms_sha256=t.terms_sha256
  for update of j;
  if not found then
    raise exception using errcode='P0002',message='job_not_found';
  end if;
  if v_job.poster_id=p_actor then
    raise exception using errcode='P0001',message='self_application_not_allowed';
  end if;
  if v_job.listing_state<>'open' or v_job.application_deadline_at<=pg_catalog.now() then
    raise exception using errcode='P0001',message='slot_unavailable';
  end if;

  select count(*)::integer,
    count(*) filter(where status='unassigned')::integer
  into v_allocation_count,v_slots_remaining
  from app_private.principal_allocations
  where job_id=p_job_id and funding_intent_id=v_job.funded_funding_intent_id;
  if v_allocation_count<>v_job.slot_count or v_slots_remaining=0 then
    raise exception using errcode='P0001',message='slot_unavailable';
  end if;
  if exists(select 1 from app_private.job_applications
      where job_id=p_job_id and worker_id=p_actor) then
    raise exception using errcode='P0001',message='application_already_exists';
  end if;

  insert into app_private.job_applications(job_id,worker_id,applied_terms_version,note)
  values(p_job_id,p_actor,v_job.terms_version,v_note)
  returning application_id into v_application_id;
  insert into app_private.application_threads(application_id)
  values(v_application_id) returning thread_id into v_thread_id;
  insert into app_private.financial_command_idempotency(
    actor_id,command_name,idempotency_key,request_sha256,response_reference_id,response_code
  ) values(p_actor,'apply_to_job',p_idempotency_key,v_hash,v_application_id,'applied');
  v_event_id:=app_private.append_marketplace_event(
    p_actor,p_job_id,'job.application_created',v_job.terms_version,
    pg_catalog.jsonb_build_object('application_id',v_application_id,'thread_id',v_thread_id)
  );
  perform app_private.add_in_app_notification(v_event_id,v_job.poster_id,'application_received');
  return app_private.application_command_projection(v_application_id);
end;
$function$;

create function public.server_apply_to_job_for_actor(
  p_actor uuid,p_job_id uuid,p_note text,p_idempotency_key uuid
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.apply_to_job_for_actor(p_actor,p_job_id,p_note,p_idempotency_key)
$function$;

create function app_private.assignment_command_projection(
  p_application_id uuid,p_assignment_id uuid
) returns jsonb language sql stable security definer set search_path = '' as $function$
  select pg_catalog.jsonb_build_object(
    'assignment_id',s.assignment_id,
    'application_id',s.application_id,
    'thread_id',t.thread_id,
    'job_id',s.job_id,
    'assignment_state',s.work_state,
    'terms_version',s.terms_version,
    'gross_principal_kobo',s.gross_principal_kobo::text,
    'commission_basis_points',s.commission_basis_points
  )
  from app_private.assignments s
  join app_private.application_threads t using(application_id)
  where s.application_id=p_application_id and s.assignment_id=p_assignment_id
$function$;

create function app_private.accept_application_for_actor(
  p_actor uuid,p_application_id uuid,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_caps text[];
  v_hash bytea;
  v_existing app_private.financial_command_idempotency%rowtype;
  v_job_id uuid;
  v_job app_private.jobs%rowtype;
  v_application app_private.job_applications%rowtype;
  v_terms app_private.job_terms_versions%rowtype;
  v_allocation app_private.principal_allocations%rowtype;
  v_allocation_count integer;
  v_slots_remaining integer;
  v_assignment_id uuid:=pg_catalog.gen_random_uuid();
  v_assignment jsonb;
  v_event_id uuid;
  v_next_state text;
begin
  v_caps:=app_private.current_profile_capabilities(p_actor);
  if p_actor is null or p_application_id is null or p_idempotency_key is null then
    raise exception using errcode='22023',message='invalid_application_request';
  end if;
  if not ('can_hire'=any(v_caps)) then
    raise exception using errcode='42501',message='marketplace_access_denied';
  end if;
  v_hash:=extensions.digest(pg_catalog.jsonb_build_object(
    'application_id',p_application_id
  )::text,'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    p_actor::text||':accept_application:'||p_idempotency_key::text,428118));
  select * into v_existing from app_private.financial_command_idempotency
  where actor_id=p_actor and command_name='accept_application' and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.request_sha256<>v_hash then
      raise exception using errcode='23505',message='idempotency_conflict';
    end if;
    return app_private.assignment_command_projection(
      v_existing.response_reference_id,
      pg_catalog.split_part(v_existing.response_code,':',2)::uuid
    );
  end if;

  select job_id into v_job_id from app_private.job_applications
  where application_id=p_application_id;
  if not found then
    raise exception using errcode='P0002',message='application_not_found';
  end if;
  select * into v_job from app_private.jobs
  where job_id=v_job_id for update;
  if not found then
    raise exception using errcode='P0002',message='application_not_found';
  end if;
  if v_job.poster_id<>p_actor then
    raise exception using errcode='P0002',message='application_not_found';
  end if;
  select * into v_application from app_private.job_applications
  where application_id=p_application_id for update;
  if not found then
    raise exception using errcode='P0002',message='application_not_found';
  end if;
  if v_application.state<>'applied' then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  if v_job.listing_state not in ('open','expired') or v_job.funded_funding_intent_id is null then
    raise exception using errcode='P0001',message='slot_unavailable';
  end if;
  select t.* into v_terms
  from app_private.job_terms_versions t
  join app_private.funding_intents i
    on i.intent_id=v_job.funded_funding_intent_id
   and i.status='succeeded' and i.terms_version=t.terms_version
   and i.gross_per_worker_kobo=t.gross_per_worker_kobo
   and i.slot_count=t.slot_count and i.gross_total_kobo=t.gross_total_kobo
   and i.currency='NGN' and i.terms_sha256=t.terms_sha256
  where t.job_id=v_job.job_id and t.terms_version=v_job.current_terms_version;
  if not found or v_application.applied_terms_version<>v_terms.terms_version
     or v_application.applied_at>=v_terms.application_deadline_at then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  if not ('can_work'=any(app_private.current_profile_capabilities(v_application.worker_id))) then
    raise exception using errcode='42501',message='verification_required';
  end if;

  select count(*)::integer,
    count(*) filter(where status='unassigned')::integer
  into v_allocation_count,v_slots_remaining
  from app_private.principal_allocations
  where job_id=v_job.job_id and funding_intent_id=v_job.funded_funding_intent_id;
  if v_allocation_count<>v_terms.slot_count then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  select * into v_allocation
  from app_private.principal_allocations
  where job_id=v_job.job_id and funding_intent_id=v_job.funded_funding_intent_id
    and status='unassigned'
  order by slot_number
  limit 1 for update;
  if not found then
    raise exception using errcode='P0001',message='slot_unavailable';
  end if;

  insert into app_private.assignments(
    assignment_id,application_id,job_id,worker_id,poster_id,allocation_id,
    funding_intent_id,terms_version,terms_sha256,gross_principal_kobo,commission_basis_points
  ) values(
    v_assignment_id,v_application.application_id,v_job.job_id,v_application.worker_id,
    v_job.poster_id,v_allocation.allocation_id,v_allocation.funding_intent_id,
    v_terms.terms_version,v_terms.terms_sha256,v_allocation.gross_principal_kobo,
    v_allocation.commission_basis_points
  );
  update app_private.principal_allocations
  set status='assigned',assignment_id=v_assignment_id
  where allocation_id=v_allocation.allocation_id and status='unassigned';
  if not found then
    raise exception using errcode='P0001',message='slot_unavailable';
  end if;
  update app_private.job_applications
  set state='accepted',decided_at=pg_catalog.now(),decided_by=p_actor
  where application_id=v_application.application_id;

  select count(*) filter(where status='unassigned')::integer into v_slots_remaining
  from app_private.principal_allocations
  where job_id=v_job.job_id and funding_intent_id=v_job.funded_funding_intent_id;
  if v_slots_remaining=0 then
    v_next_state:='filled';
  elsif v_terms.application_deadline_at<=pg_catalog.now() then
    v_next_state:='expired';
  elsif v_job.listing_state='open' then
    v_next_state:='open';
  else
    v_next_state:='expired';
  end if;
  if v_next_state<>v_job.listing_state then
    update app_private.jobs set listing_state=v_next_state where job_id=v_job.job_id;
  end if;

  v_event_id:=app_private.append_marketplace_event(
    p_actor,v_job.job_id,'job.application_accepted',v_terms.terms_version,
    pg_catalog.jsonb_build_object(
      'application_id',v_application.application_id,'assignment_id',v_assignment_id,
      'thread_id',(select thread_id from app_private.application_threads
        where application_id=v_application.application_id),
      'terms_version',v_terms.terms_version,
      'gross_principal_kobo',v_allocation.gross_principal_kobo::text
    )
  );
  perform app_private.add_in_app_notification(v_event_id,v_job.poster_id,'application_accepted');
  perform app_private.add_in_app_notification(v_event_id,v_application.worker_id,'application_accepted');
  v_assignment:=app_private.assignment_command_projection(v_application.application_id,v_assignment_id);
  insert into app_private.financial_command_idempotency(
    actor_id,command_name,idempotency_key,request_sha256,response_reference_id,response_code
  ) values(p_actor,'accept_application',p_idempotency_key,v_hash,
    v_application.application_id,'assignment:'||v_assignment_id::text);
  return v_assignment;
end;
$function$;

create function app_private.reject_application_for_actor(
  p_actor uuid,p_application_id uuid,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_caps text[];
  v_hash bytea;
  v_existing app_private.financial_command_idempotency%rowtype;
  v_job_id uuid;
  v_job app_private.jobs%rowtype;
  v_application app_private.job_applications%rowtype;
  v_terms_version integer;
  v_event_id uuid;
begin
  v_caps:=app_private.current_profile_capabilities(p_actor);
  if p_actor is null or p_application_id is null or p_idempotency_key is null then
    raise exception using errcode='22023',message='invalid_application_request';
  end if;
  if not ('can_hire'=any(v_caps)) then
    raise exception using errcode='42501',message='marketplace_access_denied';
  end if;
  v_hash:=extensions.digest(pg_catalog.jsonb_build_object(
    'application_id',p_application_id
  )::text,'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    p_actor::text||':reject_application:'||p_idempotency_key::text,428118));
  select * into v_existing from app_private.financial_command_idempotency
  where actor_id=p_actor and command_name='reject_application' and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.request_sha256<>v_hash then
      raise exception using errcode='23505',message='idempotency_conflict';
    end if;
    return app_private.application_command_projection(v_existing.response_reference_id);
  end if;
  select job_id into v_job_id from app_private.job_applications where application_id=p_application_id;
  if not found then raise exception using errcode='P0002',message='application_not_found'; end if;
  select * into v_job from app_private.jobs where job_id=v_job_id for update;
  select * into v_application from app_private.job_applications
  where application_id=p_application_id for update;
  if v_job.poster_id<>p_actor then
    raise exception using errcode='P0002',message='application_not_found';
  end if;
  if v_application.state<>'applied' then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  select terms_version into v_terms_version from app_private.job_terms_versions
  where job_id=v_job.job_id and terms_version=v_application.applied_terms_version;
  update app_private.job_applications set state='rejected',decided_at=pg_catalog.now(),decided_by=p_actor
  where application_id=p_application_id;
  v_event_id:=app_private.append_marketplace_event(
    p_actor,v_job.job_id,'job.application_rejected',v_terms_version,
    pg_catalog.jsonb_build_object('application_id',p_application_id)
  );
  perform app_private.add_in_app_notification(v_event_id,v_application.worker_id,'application_rejected');
  insert into app_private.financial_command_idempotency(
    actor_id,command_name,idempotency_key,request_sha256,response_reference_id,response_code
  ) values(p_actor,'reject_application',p_idempotency_key,v_hash,p_application_id,'rejected');
  return app_private.application_command_projection(p_application_id);
end;
$function$;

create function app_private.withdraw_application_for_actor(
  p_actor uuid,p_application_id uuid,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_caps text[];
  v_hash bytea;
  v_existing app_private.financial_command_idempotency%rowtype;
  v_job_id uuid;
  v_job app_private.jobs%rowtype;
  v_application app_private.job_applications%rowtype;
  v_event_id uuid;
begin
  v_caps:=app_private.current_profile_capabilities(p_actor);
  if p_actor is null or p_application_id is null or p_idempotency_key is null then
    raise exception using errcode='22023',message='invalid_application_request';
  end if;
  if not ('can_work'=any(v_caps)) then
    raise exception using errcode='42501',message='verification_required';
  end if;
  v_hash:=extensions.digest(pg_catalog.jsonb_build_object(
    'application_id',p_application_id
  )::text,'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    p_actor::text||':withdraw_application:'||p_idempotency_key::text,428118));
  select * into v_existing from app_private.financial_command_idempotency
  where actor_id=p_actor and command_name='withdraw_application' and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.request_sha256<>v_hash then
      raise exception using errcode='23505',message='idempotency_conflict';
    end if;
    return app_private.application_command_projection(v_existing.response_reference_id);
  end if;
  select job_id into v_job_id from app_private.job_applications where application_id=p_application_id;
  if not found then raise exception using errcode='P0002',message='application_not_found'; end if;
  select * into v_job from app_private.jobs where job_id=v_job_id for update;
  select * into v_application from app_private.job_applications
  where application_id=p_application_id for update;
  if v_application.worker_id<>p_actor then
    raise exception using errcode='P0002',message='application_not_found';
  end if;
  if v_application.state<>'applied' then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  update app_private.job_applications set state='withdrawn',decided_at=pg_catalog.now(),decided_by=p_actor
  where application_id=p_application_id;
  v_event_id:=app_private.append_marketplace_event(
    p_actor,v_job.job_id,'job.application_withdrawn',v_application.applied_terms_version,
    pg_catalog.jsonb_build_object('application_id',p_application_id)
  );
  perform app_private.add_in_app_notification(v_event_id,v_job.poster_id,'application_withdrawn');
  insert into app_private.financial_command_idempotency(
    actor_id,command_name,idempotency_key,request_sha256,response_reference_id,response_code
  ) values(p_actor,'withdraw_application',p_idempotency_key,v_hash,p_application_id,'withdrawn');
  return app_private.application_command_projection(p_application_id);
end;
$function$;

create function public.server_accept_application_for_actor(
  p_actor uuid,p_application_id uuid,p_idempotency_key uuid
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.accept_application_for_actor(p_actor,p_application_id,p_idempotency_key)
$function$;
create function public.server_reject_application_for_actor(
  p_actor uuid,p_application_id uuid,p_idempotency_key uuid
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.reject_application_for_actor(p_actor,p_application_id,p_idempotency_key)
$function$;
create function public.server_withdraw_application_for_actor(
  p_actor uuid,p_application_id uuid,p_idempotency_key uuid
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.withdraw_application_for_actor(p_actor,p_application_id,p_idempotency_key)
$function$;

revoke all on table app_private.job_applications,app_private.application_threads,
  app_private.assignments,app_private.in_app_notifications
  from public,anon,authenticated,service_role;
revoke all on function app_private.guard_job_application_change(),
  app_private.reject_assignment_mutation(),app_private.validate_assignment_allocation_pair(),
  app_private.application_command_projection(uuid),app_private.add_in_app_notification(uuid,uuid,text),
  app_private.normalize_application_note(text),app_private.apply_to_job_for_actor(uuid,uuid,text,uuid),
  app_private.assignment_command_projection(uuid,uuid),
  app_private.accept_application_for_actor(uuid,uuid,uuid),
  app_private.reject_application_for_actor(uuid,uuid,uuid),
  app_private.withdraw_application_for_actor(uuid,uuid,uuid)
  from public,anon,authenticated,service_role;
revoke all on function public.server_apply_to_job_for_actor(uuid,uuid,text,uuid),
  public.server_accept_application_for_actor(uuid,uuid,uuid),
  public.server_reject_application_for_actor(uuid,uuid,uuid),
  public.server_withdraw_application_for_actor(uuid,uuid,uuid)
  from public,anon,authenticated,service_role;
grant execute on function public.server_apply_to_job_for_actor(uuid,uuid,text,uuid),
  public.server_accept_application_for_actor(uuid,uuid,uuid),
  public.server_reject_application_for_actor(uuid,uuid,uuid),
  public.server_withdraw_application_for_actor(uuid,uuid,uuid)
  to service_role;

commit;
