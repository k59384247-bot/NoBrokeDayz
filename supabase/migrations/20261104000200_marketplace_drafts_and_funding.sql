begin;

alter table app_private.funding_intents
  add column terms_sha256 bytea not null
    default extensions.digest('step2_foundation_fixture','sha256')
    check (pg_catalog.octet_length(terms_sha256)=32),
  add column merchant_identity text not null default 'fake_nbd_local_merchant_v1'
    check (merchant_identity ~ '^fake_[a-z0-9_]{8,80}$'),
  add column attempt_number integer not null default 1 check (attempt_number > 0);
alter table app_private.funding_intents
  drop constraint funding_intents_job_id_terms_version_key;
alter table app_private.funding_intents
  add constraint funding_intents_job_terms_attempt_key
    unique(job_id,terms_version,attempt_number);

alter table app_private.provider_operations
  add column merchant_identity text default 'fake_nbd_local_merchant_v1'
    check (merchant_identity is null or merchant_identity ~ '^fake_[a-z0-9_]{8,80}$');
alter table app_private.financial_exceptions
  drop constraint financial_exceptions_exception_type_check;
alter table app_private.financial_exceptions
  add constraint financial_exceptions_exception_type_check check (exception_type in (
    'amount_mismatch','currency_mismatch','reference_mismatch','merchant_mismatch',
    'duplicate_collection','unknown_result','settlement_mismatch','payout_mismatch',
    'provider_unavailable','manual_reconciliation'
  ));
alter table app_private.provider_operations
  drop constraint provider_operations_safe_error_code_check;
alter table app_private.provider_operations
  add constraint provider_operations_safe_error_code_check check (safe_error_code is null or safe_error_code in (
    'provider_unavailable','provider_timeout','amount_mismatch','currency_mismatch',
    'reference_mismatch','merchant_mismatch','duplicate_collection','settlement_pending',
    'destination_unavailable','unknown_result'
  ));
alter table app_private.payment_operation_jobs
  drop constraint payment_operation_jobs_last_safe_error_code_check;
alter table app_private.payment_operation_jobs
  add constraint payment_operation_jobs_last_safe_error_code_check check (last_safe_error_code is null or last_safe_error_code in (
    'provider_timeout','provider_unavailable','amount_mismatch','currency_mismatch',
    'reference_mismatch','merchant_mismatch','duplicate_collection','unknown_result','settlement_pending'
  ));

create table app_private.jobs (
  job_id uuid primary key default pg_catalog.gen_random_uuid(),
  poster_id uuid not null references auth.users(id) on delete restrict,
  listing_state text not null default 'draft'
    check (listing_state in ('draft','awaiting_payment','open','expired')),
  current_terms_version integer not null default 1 check (current_terms_version > 0),
  active_funding_intent_id uuid unique references app_private.funding_intents(intent_id) on delete restrict,
  funded_funding_intent_id uuid unique references app_private.funding_intents(intent_id) on delete restrict,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  check (
    (listing_state='draft' and active_funding_intent_id is null and funded_funding_intent_id is null) or
    (listing_state='awaiting_payment' and active_funding_intent_id is not null and funded_funding_intent_id is null) or
    (listing_state in ('open','expired') and active_funding_intent_id is null and funded_funding_intent_id is not null)
  )
);

create table app_private.job_terms_versions (
  job_id uuid not null references app_private.jobs(job_id) on delete restrict,
  terms_version integer not null check (terms_version > 0),
  title text not null check (char_length(title) between 3 and 100),
  description text not null check (char_length(description) between 20 and 5000),
  category_slug text not null references public.job_categories(slug) on delete restrict,
  location_type text not null check (location_type in ('on_campus','remote','hybrid')),
  location_detail text check (location_detail is null or char_length(location_detail) between 2 and 160),
  gross_per_worker_kobo bigint not null check (gross_per_worker_kobo between 1 and 100000000),
  slot_count smallint not null check (slot_count between 1 and 10),
  gross_total_kobo bigint not null check (gross_total_kobo between 1 and 1000000000),
  application_deadline_at timestamptz not null,
  needed_by_at timestamptz not null,
  start_requirements text not null default '' check (char_length(start_requirements) between 0 and 1000),
  application_note text not null default '' check (char_length(application_note) between 0 and 500),
  terms_sha256 bytea not null check (pg_catalog.octet_length(terms_sha256)=32),
  created_at timestamptz not null default pg_catalog.now(),
  primary key(job_id,terms_version),
  check (gross_total_kobo::numeric=gross_per_worker_kobo::numeric*slot_count),
  check (application_deadline_at <= needed_by_at)
);

create table app_private.marketplace_outbox (
  event_id uuid primary key default pg_catalog.gen_random_uuid(),
  actor_id uuid references auth.users(id) on delete restrict,
  job_id uuid not null references app_private.jobs(job_id) on delete restrict,
  event_type text not null check (event_type in (
    'job.draft_created','job.draft_updated','job.funding_started','job.funded',
    'job.funding_failed','job.funding_exception'
  )),
  terms_version integer not null check (terms_version > 0),
  payload jsonb not null check (pg_catalog.jsonb_typeof(payload)='object'),
  created_at timestamptz not null default pg_catalog.now()
);
create index marketplace_outbox_job_events_idx
  on app_private.marketplace_outbox(job_id,created_at,event_id);

create function app_private.reject_job_terms_mutation()
returns trigger language plpgsql set search_path = '' as $function$
begin
  raise exception using errcode='55000',message='job_terms_are_immutable';
end;
$function$;
create trigger job_terms_versions_immutable before update or delete on app_private.job_terms_versions
for each row execute function app_private.reject_job_terms_mutation();
create trigger marketplace_outbox_immutable before update or delete on app_private.marketplace_outbox
for each row execute function app_private.reject_job_terms_mutation();

create function app_private.guard_job_change()
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
    (old.listing_state='awaiting_payment' and new.listing_state in ('draft','open','expired'))
  ) then
    raise exception using errcode='55000',message='invalid_job_state_transition';
  end if;
  new.updated_at:=pg_catalog.now();
  return new;
end;
$function$;
create trigger jobs_guard_change before update or delete on app_private.jobs
for each row execute function app_private.guard_job_change();

create function app_private.normalize_job_terms(p_terms jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $function$
declare
  v_allowed text[]:=array[
    'title','description','category_slug','location_type','location_detail',
    'gross_per_worker_kobo','slot_count','application_deadline_at','needed_by_at',
    'start_requirements','application_note'
  ];
  v_key text;
  v_title text;
  v_description text;
  v_category text;
  v_location text;
  v_location_detail text;
  v_start_requirements text;
  v_application_note text;
  v_gross_text text;
  v_gross bigint;
  v_slots smallint;
  v_total numeric;
  v_deadline timestamptz;
  v_needed_by timestamptz;
begin
  if p_terms is null or pg_catalog.jsonb_typeof(p_terms)<>'object' then
    raise exception using errcode='22023',message='invalid_job_terms';
  end if;
  for v_key in select key from pg_catalog.jsonb_each(p_terms) loop
    if not v_key=any(v_allowed) then
      raise exception using errcode='22023',message='invalid_job_terms';
    end if;
  end loop;
  if not (p_terms ?& array[
      'title','description','category_slug','location_type','gross_per_worker_kobo',
      'slot_count','application_deadline_at','needed_by_at'
    ]) then
    raise exception using errcode='22023',message='invalid_job_terms';
  end if;
  if exists(select 1 from pg_catalog.jsonb_each(p_terms) e
    where e.key in ('title','description','category_slug','location_type',
      'gross_per_worker_kobo','slot_count','application_deadline_at','needed_by_at')
      and e.value='null'::jsonb) then
    raise exception using errcode='22023',message='invalid_job_terms';
  end if;
  if pg_catalog.jsonb_typeof(p_terms->'title')<>'string'
     or pg_catalog.jsonb_typeof(p_terms->'description')<>'string'
     or pg_catalog.jsonb_typeof(p_terms->'category_slug')<>'string'
     or pg_catalog.jsonb_typeof(p_terms->'location_type')<>'string'
     or pg_catalog.jsonb_typeof(p_terms->'gross_per_worker_kobo')<>'string'
     or pg_catalog.jsonb_typeof(p_terms->'slot_count')<>'number'
     or pg_catalog.jsonb_typeof(p_terms->'application_deadline_at')<>'string'
     or pg_catalog.jsonb_typeof(p_terms->'needed_by_at')<>'string' then
    raise exception using errcode='22023',message='invalid_job_terms';
  end if;
  v_title:=pg_catalog.btrim(p_terms->>'title');
  v_description:=pg_catalog.btrim(p_terms->>'description');
  v_category:=p_terms->>'category_slug';
  v_location:=p_terms->>'location_type';
  v_gross_text:=p_terms->>'gross_per_worker_kobo';
  if pg_catalog.char_length(v_title) not between 3 and 100
     or pg_catalog.char_length(v_description) not between 20 and 5000
     or v_gross_text !~ '^[1-9][0-9]{0,8}$'
     or not exists(select 1 from public.job_categories c where c.slug=v_category and c.enabled)
     or v_location not in ('on_campus','remote','hybrid') then
    raise exception using errcode='22023',message='invalid_job_terms';
  end if;
  v_gross:=v_gross_text::bigint;
  if v_gross>100000000 or (p_terms->>'slot_count') !~ '^(?:[1-9]|10)$' then
    raise exception using errcode='22023',message='invalid_job_terms';
  end if;
  v_slots:=(p_terms->>'slot_count')::smallint;
  v_total:=v_gross::numeric*v_slots;
  if v_total<1 or v_total>1000000000 then
    raise exception using errcode='22023',message='invalid_job_terms';
  end if;

  if pg_catalog.jsonb_typeof(p_terms->'location_detail') not in ('string','null')
     or pg_catalog.jsonb_typeof(p_terms->'start_requirements') not in ('string','null')
     or pg_catalog.jsonb_typeof(p_terms->'application_note') not in ('string','null') then
    raise exception using errcode='22023',message='invalid_job_terms';
  end if;
  v_location_detail:=nullif(pg_catalog.btrim(p_terms->>'location_detail'),'');
  v_start_requirements:=coalesce(pg_catalog.btrim(p_terms->>'start_requirements'),'');
  v_application_note:=coalesce(pg_catalog.btrim(p_terms->>'application_note'),'');
  if v_location_detail is not null and pg_catalog.char_length(v_location_detail) not between 2 and 160
     or pg_catalog.char_length(v_start_requirements)>1000
     or pg_catalog.char_length(v_application_note)>500 then
    raise exception using errcode='22023',message='invalid_job_terms';
  end if;
  if (p_terms->>'application_deadline_at') !~ '([zZ]|[+-][0-9]{2}:[0-9]{2})$'
     or (p_terms->>'needed_by_at') !~ '([zZ]|[+-][0-9]{2}:[0-9]{2})$' then
    raise exception using errcode='22023',message='invalid_job_terms';
  end if;
  begin
    v_deadline:=(p_terms->>'application_deadline_at')::timestamptz;
    v_needed_by:=(p_terms->>'needed_by_at')::timestamptz;
  exception when others then
    raise exception using errcode='22023',message='invalid_job_terms';
  end;
  if v_deadline<=pg_catalog.now() or v_needed_by<v_deadline
     or v_needed_by>pg_catalog.now()+interval '180 days' then
    raise exception using errcode='22023',message='invalid_job_terms';
  end if;
  return pg_catalog.jsonb_build_object(
    'title',v_title,'description',v_description,'category_slug',v_category,
    'location_type',v_location,'location_detail',v_location_detail,
    'gross_per_worker_kobo',v_gross::text,'slot_count',v_slots,
    'gross_total_kobo',v_total::bigint::text,
    'application_deadline_at',v_deadline,'needed_by_at',v_needed_by,
    'start_requirements',v_start_requirements,'application_note',v_application_note
  );
end;
$function$;

create function app_private.get_job_terms_projection(p_job_id uuid,p_terms_version integer)
returns jsonb language sql stable security definer set search_path = '' as $function$
  select pg_catalog.jsonb_build_object(
    'job_id',j.job_id,'listing_state',j.listing_state,
    'terms_version',t.terms_version,'title',t.title,'description',t.description,
    'category_slug',t.category_slug,'location_type',t.location_type,
    'location_detail',t.location_detail,'gross_per_worker_kobo',t.gross_per_worker_kobo::text,
    'gross_total_kobo',t.gross_total_kobo::text,'slot_count',t.slot_count,
    'application_deadline_at',t.application_deadline_at,
    'needed_by_at',t.needed_by_at,'start_requirements',t.start_requirements,
    'application_note',t.application_note
  )
  from app_private.jobs j join app_private.job_terms_versions t using(job_id)
  where j.job_id=p_job_id and t.terms_version=p_terms_version
$function$;

create function app_private.append_marketplace_event(
  p_actor uuid,p_job_id uuid,p_event_type text,p_terms_version integer,p_payload jsonb
) returns uuid language plpgsql security definer set search_path = '' as $function$
declare v_event_id uuid;
begin
  insert into app_private.marketplace_outbox(actor_id,job_id,event_type,terms_version,payload)
  values(p_actor,p_job_id,p_event_type,p_terms_version,p_payload) returning event_id into v_event_id;
  return v_event_id;
end;
$function$;

create function app_private.create_job_draft_for_actor(p_actor uuid,p_terms jsonb,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_terms jsonb;
  v_hash bytea;
  v_existing app_private.financial_command_idempotency%rowtype;
  v_job_id uuid;
  v_total bigint;
  v_event_id uuid;
begin
  if p_actor is null or p_idempotency_key is null
     or not ('can_hire'=any(app_private.current_profile_capabilities(p_actor))) then
    raise exception using errcode='42501',message='marketplace_access_denied';
  end if;
  v_terms:=app_private.normalize_job_terms(p_terms);
  v_hash:=extensions.digest(v_terms::text,'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    p_actor::text||':create_job_draft:'||p_idempotency_key::text,428118));
  select * into v_existing from app_private.financial_command_idempotency
  where actor_id=p_actor and command_name='create_job_draft' and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.request_sha256<>v_hash then
      raise exception using errcode='23505',message='idempotency_conflict';
    end if;
    return app_private.get_job_terms_projection(v_existing.response_reference_id,
      pg_catalog.split_part(v_existing.response_code,':',2)::integer);
  end if;
  v_total:=(v_terms->>'gross_total_kobo')::bigint;
  insert into app_private.jobs(poster_id) values(p_actor) returning job_id into v_job_id;
  insert into app_private.job_terms_versions(
    job_id,terms_version,title,description,category_slug,location_type,location_detail,
    gross_per_worker_kobo,slot_count,gross_total_kobo,application_deadline_at,needed_by_at,
    start_requirements,application_note,terms_sha256
  ) values(
    v_job_id,1,v_terms->>'title',v_terms->>'description',v_terms->>'category_slug',
    v_terms->>'location_type',v_terms->>'location_detail',
    (v_terms->>'gross_per_worker_kobo')::bigint,(v_terms->>'slot_count')::smallint,v_total,
    (v_terms->>'application_deadline_at')::timestamptz,(v_terms->>'needed_by_at')::timestamptz,
    v_terms->>'start_requirements',v_terms->>'application_note',v_hash
  );
  insert into app_private.financial_command_idempotency(
    actor_id,command_name,idempotency_key,request_sha256,response_reference_id,response_code
  ) values(p_actor,'create_job_draft',p_idempotency_key,v_hash,v_job_id,'terms:1');
  v_event_id:=app_private.append_marketplace_event(p_actor,v_job_id,'job.draft_created',1,
    pg_catalog.jsonb_build_object('terms_version',1));
  return app_private.get_job_terms_projection(v_job_id,1);
end;
$function$;

create function app_private.update_job_draft_for_actor(
  p_actor uuid,p_job_id uuid,p_expected_terms_version integer,p_terms jsonb,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_terms jsonb;
  v_request jsonb;
  v_hash bytea;
  v_existing app_private.financial_command_idempotency%rowtype;
  v_job app_private.jobs%rowtype;
  v_new_version integer;
  v_total bigint;
begin
  if p_actor is null or p_job_id is null or p_idempotency_key is null
     or p_expected_terms_version is null or p_expected_terms_version<1
     or not ('can_hire'=any(app_private.current_profile_capabilities(p_actor))) then
    raise exception using errcode='42501',message='marketplace_access_denied';
  end if;
  v_terms:=app_private.normalize_job_terms(p_terms);
  v_request:=pg_catalog.jsonb_build_object('job_id',p_job_id,
    'expected_terms_version',p_expected_terms_version,'terms',v_terms);
  v_hash:=extensions.digest(v_request::text,'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    p_actor::text||':update_job_draft:'||p_idempotency_key::text,428118));
  select * into v_job from app_private.jobs where job_id=p_job_id for update;
  if not found or v_job.poster_id<>p_actor then
    raise exception using errcode='P0002',message='job_not_found';
  end if;
  select * into v_existing from app_private.financial_command_idempotency
  where actor_id=p_actor and command_name='update_job_draft' and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.request_sha256<>v_hash or v_existing.response_reference_id<>p_job_id then
      raise exception using errcode='23505',message='idempotency_conflict';
    end if;
    return app_private.get_job_terms_projection(p_job_id,
      pg_catalog.split_part(v_existing.response_code,':',2)::integer);
  end if;
  if v_job.listing_state<>'draft' or v_job.active_funding_intent_id is not null
     or v_job.funded_funding_intent_id is not null
     or v_job.current_terms_version<>p_expected_terms_version then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  v_new_version:=v_job.current_terms_version+1;
  v_total:=(v_terms->>'gross_total_kobo')::bigint;
  insert into app_private.job_terms_versions(
    job_id,terms_version,title,description,category_slug,location_type,location_detail,
    gross_per_worker_kobo,slot_count,gross_total_kobo,application_deadline_at,needed_by_at,
    start_requirements,application_note,terms_sha256
  ) values(
    p_job_id,v_new_version,v_terms->>'title',v_terms->>'description',v_terms->>'category_slug',
    v_terms->>'location_type',v_terms->>'location_detail',
    (v_terms->>'gross_per_worker_kobo')::bigint,(v_terms->>'slot_count')::smallint,v_total,
    (v_terms->>'application_deadline_at')::timestamptz,(v_terms->>'needed_by_at')::timestamptz,
    v_terms->>'start_requirements',v_terms->>'application_note',v_hash
  );
  update app_private.jobs set current_terms_version=v_new_version where job_id=p_job_id;
  insert into app_private.financial_command_idempotency(
    actor_id,command_name,idempotency_key,request_sha256,response_reference_id,response_code
  ) values(p_actor,'update_job_draft',p_idempotency_key,v_hash,p_job_id,'terms:'||v_new_version::text);
  perform app_private.append_marketplace_event(p_actor,p_job_id,'job.draft_updated',v_new_version,
    pg_catalog.jsonb_build_object('terms_version',v_new_version));
  return app_private.get_job_terms_projection(p_job_id,v_new_version);
end;
$function$;

create function app_private.funding_operation_projection(p_intent_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $function$
  select pg_catalog.jsonb_build_object(
    'job_id',j.job_id,'funding_intent_id',i.intent_id,
    'operation_id',o.operation_id,'provider_idempotency_key',o.provider_idempotency_key,
    'provider_reference',o.provider_operation_reference,
    'amount_kobo',i.gross_total_kobo::text,'currency',i.currency,
    'merchant_identity',i.merchant_identity,'status',i.status,
    'operation_status',o.status,'listing_state',j.listing_state,
    'terms_version',i.terms_version
  )
  from app_private.funding_intents i
  join app_private.provider_operations o on o.funding_intent_id=i.intent_id
  join app_private.jobs j on j.job_id=i.job_id
  where i.intent_id=p_intent_id
$function$;

create function app_private.start_job_funding_for_actor(
  p_actor uuid,p_job_id uuid,p_expected_terms_version integer,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_job app_private.jobs%rowtype;
  v_terms app_private.job_terms_versions%rowtype;
  v_existing app_private.financial_command_idempotency%rowtype;
  v_intent app_private.funding_intents%rowtype;
  v_hash bytea;
  v_terms_hash bytea;
  v_request jsonb;
  v_intent_id uuid;
  v_operation_id uuid:=pg_catalog.gen_random_uuid();
  v_provider_key uuid:=pg_catalog.gen_random_uuid();
  v_attempt_number integer;
  v_merchant text:='fake_nbd_local_merchant_v1';
begin
  if p_actor is null or p_job_id is null or p_idempotency_key is null
     or p_expected_terms_version is null or p_expected_terms_version<1
     or not ('can_hire'=any(app_private.current_profile_capabilities(p_actor))) then
    raise exception using errcode='42501',message='marketplace_access_denied';
  end if;
  v_request:=pg_catalog.jsonb_build_object('job_id',p_job_id,
    'expected_terms_version',p_expected_terms_version);
  v_hash:=extensions.digest(v_request::text,'sha256');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    p_actor::text||':fund_job:'||p_idempotency_key::text,428118));
  select * into v_existing from app_private.financial_command_idempotency
  where actor_id=p_actor and command_name='fund_job' and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.request_sha256<>v_hash or v_existing.response_reference_id is null then
      raise exception using errcode='23505',message='idempotency_conflict';
    end if;
    return app_private.funding_operation_projection(v_existing.response_reference_id);
  end if;
  select * into v_job from app_private.jobs where job_id=p_job_id for update;
  if not found or v_job.poster_id<>p_actor then
    raise exception using errcode='P0002',message='job_not_found';
  end if;
  if v_job.listing_state<>'draft' or v_job.active_funding_intent_id is not null
     or v_job.funded_funding_intent_id is not null
     or v_job.current_terms_version<>p_expected_terms_version then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  select * into v_terms from app_private.job_terms_versions
    where job_id=p_job_id and terms_version=v_job.current_terms_version;
  if not found or not exists(select 1 from public.job_categories c
    where c.slug=v_terms.category_slug and c.enabled) then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  if v_terms.application_deadline_at<=pg_catalog.now() then
    raise exception using errcode='P0001',message='stale_state';
  end if;
  if v_terms.gross_total_kobo::numeric<>v_terms.gross_per_worker_kobo::numeric*v_terms.slot_count
     or v_terms.terms_sha256 is null then
    raise exception using errcode='22023',message='invalid_job_terms';
  end if;
  v_terms_hash:=v_terms.terms_sha256;
  select coalesce(pg_catalog.max(i.attempt_number),0)+1 into v_attempt_number
    from app_private.funding_intents i
    where i.job_id=p_job_id and i.terms_version=v_terms.terms_version;
  insert into app_private.funding_intents(
    poster_id,job_id,terms_version,gross_per_worker_kobo,slot_count,gross_total_kobo,
    currency,status,idempotency_key,request_sha256,terms_sha256,merchant_identity,attempt_number
  ) values(
    p_actor,p_job_id,v_terms.terms_version,v_terms.gross_per_worker_kobo,v_terms.slot_count,
    v_terms.gross_total_kobo,'NGN','pending',p_idempotency_key,v_hash,
    v_terms_hash,v_merchant,v_attempt_number
  ) returning intent_id into v_intent_id;
  insert into app_private.provider_operations(
    operation_id,operation_type,provider_adapter,provider_idempotency_key,actor_id,
    funding_intent_id,amount_kobo,merchant_identity,currency,request_sha256,status
  ) values(
    v_operation_id,'collection','local_simulator',v_provider_key,p_actor,v_intent_id,
    v_terms.gross_total_kobo,v_merchant,'NGN',
    extensions.digest(pg_catalog.jsonb_build_object(
      'operation_id',v_operation_id,'provider_idempotency_key',v_provider_key,
      'amount_kobo',v_terms.gross_total_kobo::text,'currency','NGN',
      'merchant_identity',v_merchant,'terms_sha256',pg_catalog.encode(v_terms_hash,'hex')
    )::text,'sha256'),'pending'
  );
  insert into app_private.funding_attempts(
    funding_intent_id,operation_id,attempt_number,status
  ) values(v_intent_id,v_operation_id,v_attempt_number,'pending');
  update app_private.jobs set listing_state='awaiting_payment',
    active_funding_intent_id=v_intent_id where job_id=p_job_id;
  insert into app_private.financial_command_idempotency(
    actor_id,command_name,idempotency_key,request_sha256,response_reference_id,response_code
  ) values(p_actor,'fund_job',p_idempotency_key,v_hash,v_intent_id,'funding_started');
  perform app_private.append_marketplace_event(p_actor,p_job_id,'job.funding_started',
    v_terms.terms_version,pg_catalog.jsonb_build_object(
      'funding_intent_id',v_intent_id,'expected_gross_kobo',v_terms.gross_total_kobo::text,
      'currency','NGN','attempt_number',v_attempt_number
    ));
  return app_private.funding_operation_projection(v_intent_id);
end;
$function$;

create function app_private.get_job_funding_status_for_actor(p_actor uuid,p_job_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $function$
declare
  v_job app_private.jobs%rowtype;
  v_intent_id uuid;
  v_status jsonb;
begin
  if p_actor is null or p_job_id is null then
    raise exception using errcode='22023',message='job_not_found';
  end if;
  select * into v_job from app_private.jobs where job_id=p_job_id and poster_id=p_actor;
  if not found then raise exception using errcode='P0002',message='job_not_found'; end if;
  v_intent_id:=coalesce(v_job.active_funding_intent_id,v_job.funded_funding_intent_id);
  if v_intent_id is null then
    return pg_catalog.jsonb_build_object('job_id',p_job_id,'listing_state',v_job.listing_state,
      'status',null,'funding_intent_id',null,'expected_gross_kobo',null,'currency','NGN');
  end if;
  v_status:=app_private.funding_operation_projection(v_intent_id);
  return pg_catalog.jsonb_build_object(
    'job_id',p_job_id,'listing_state',v_job.listing_state,
    'funding_intent_id',v_status->'funding_intent_id','status',v_status->'status',
    'expected_gross_kobo',v_status->'amount_kobo','currency','NGN',
    'provider_reference',v_status->'provider_reference',
    'terms_version',v_status->'terms_version'
  );
end;
$function$;

create function app_private.record_job_funding_initialization(p_operation_id uuid,p_provider_reference text)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_operation app_private.provider_operations%rowtype;
  v_expected text;
begin
  select * into v_operation from app_private.provider_operations
  where operation_id=p_operation_id and operation_type='collection'
    and provider_adapter='local_simulator' for update;
  if not found then raise exception using errcode='P0002',message='funding_operation_not_found'; end if;
  v_expected:='sim-'||v_operation.provider_idempotency_key::text;
  if p_provider_reference is distinct from v_expected then
    update app_private.provider_operations set status='exception',safe_error_code='reference_mismatch'
      where operation_id=p_operation_id and status in ('pending','processing','unknown');
    update app_private.funding_attempts set status='exception'
      where operation_id=p_operation_id and status in ('pending','unknown');
    update app_private.funding_intents set status='exception'
      where intent_id=v_operation.funding_intent_id and status in ('pending','unknown');
    insert into app_private.financial_exceptions(operation_id,funding_intent_id,
      exception_type,safe_reference)
    values(p_operation_id,v_operation.funding_intent_id,'reference_mismatch',
      left(coalesce(p_provider_reference,''),180));
    perform app_private.append_marketplace_event(v_operation.actor_id,
      (select job_id from app_private.funding_intents where intent_id=v_operation.funding_intent_id),
      'job.funding_exception',
      (select terms_version from app_private.funding_intents where intent_id=v_operation.funding_intent_id),
      pg_catalog.jsonb_build_object('reason','reference_mismatch'));
    return pg_catalog.jsonb_build_object('status','exception','provider_reference',null);
  end if;
  if v_operation.provider_operation_reference is null then
    update app_private.provider_operations set provider_operation_reference=v_expected
      where operation_id=p_operation_id;
  elsif v_operation.provider_operation_reference<>v_expected then
    raise exception using errcode='22023',message='funding_result_mismatch';
  end if;
  return pg_catalog.jsonb_build_object('status',v_operation.status,'provider_reference',v_expected);
end;
$function$;

create function app_private.record_job_funding_unknown_for_actor(p_actor uuid,p_operation_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_operation app_private.provider_operations%rowtype;
  v_intent app_private.funding_intents%rowtype;
  v_job app_private.jobs%rowtype;
begin
  select * into v_operation from app_private.provider_operations
    where operation_id=p_operation_id and operation_type='collection' for update;
  if not found or v_operation.actor_id<>p_actor then
    raise exception using errcode='P0002',message='funding_operation_not_found';
  end if;
  select * into v_intent from app_private.funding_intents
    where intent_id=v_operation.funding_intent_id for update;
  select * into v_job from app_private.jobs where job_id=v_intent.job_id for update;
  if v_operation.status in ('succeeded','settled','failed','cancelled','reversed','exception') then
    return pg_catalog.jsonb_build_object('status',v_intent.status,
      'provider_reference',v_operation.provider_operation_reference);
  end if;
  update app_private.provider_operations set status='unknown',safe_error_code='provider_timeout'
    where operation_id=p_operation_id;
  update app_private.funding_attempts set status='unknown'
    where operation_id=p_operation_id and status='pending';
  update app_private.funding_intents set status='unknown'
    where intent_id=v_intent.intent_id and status='pending';
  if not exists(select 1 from app_private.financial_exceptions e
    where e.operation_id=p_operation_id and e.exception_type='unknown_result') then
    insert into app_private.financial_exceptions(operation_id,funding_intent_id,
      exception_type,safe_reference)
    values(p_operation_id,v_intent.intent_id,'unknown_result',
      left(coalesce(v_operation.provider_operation_reference,''),180));
  end if;
  if v_intent.status='pending' and v_job.active_funding_intent_id=v_intent.intent_id then
    perform app_private.append_marketplace_event(v_intent.poster_id,v_intent.job_id,
      'job.funding_exception',v_intent.terms_version,
      pg_catalog.jsonb_build_object('reason','unknown_result',
        'funding_intent_id',v_intent.intent_id));
  end if;
  return pg_catalog.jsonb_build_object('status','unknown',
    'provider_reference',v_operation.provider_operation_reference);
end;
$function$;

create or replace function app_private.claim_payment_operation_job(
  p_worker_id uuid,p_lease_seconds smallint default 30
) returns jsonb language plpgsql security definer set search_path = '' as $function$
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
  select j.* into v_job from app_private.payment_operation_jobs j
  join app_private.provider_operations o using(operation_id)
  where ((j.state in ('queued','retry') and j.available_at<=pg_catalog.now()) or
    (j.state='leased' and j.lease_expires_at<=pg_catalog.now() and j.attempt_count<j.max_attempts))
    and o.provider_adapter='local_simulator'
    and o.operation_type in ('collection','payout')
    and o.status<>'queued_for_liquidity'
  order by j.available_at,j.created_at,j.job_id
  for update of j skip locked limit 1;
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
    'merchant_identity',v_operation.merchant_identity,
    'destination_id',v_operation.destination_id,'destination_version',v_operation.destination_version
  );
end;
$function$;

create or replace function app_private.guard_funding_intent_change()
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
     or new.terms_sha256 is distinct from old.terms_sha256
     or new.merchant_identity is distinct from old.merchant_identity
     or new.attempt_number is distinct from old.attempt_number
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

create or replace function app_private.guard_provider_operation_change()
returns trigger language plpgsql set search_path = '' as $function$
declare v_intent app_private.funding_intents%rowtype;
begin
  if tg_op='INSERT' then
    if new.status not in ('queued_for_liquidity','pending') then
      raise exception using errcode='55000',message='provider_operation_must_start_pending';
    end if;
    if new.operation_type='collection' then
      select * into v_intent from app_private.funding_intents where intent_id=new.funding_intent_id;
      if not found or new.actor_id is distinct from v_intent.poster_id
         or new.amount_kobo is distinct from v_intent.gross_total_kobo
         or new.currency is distinct from v_intent.currency
         or new.merchant_identity is distinct from v_intent.merchant_identity then
        raise exception using errcode='22023',message='funding_result_mismatch';
      end if;
    end if;
    return new;
  end if;
  if tg_op='DELETE' then
    raise exception using errcode='55000',message='provider_operation_is_immutable';
  end if;
  if new.operation_id is distinct from old.operation_id
     or new.operation_type is distinct from old.operation_type
     or new.provider_adapter is distinct from old.provider_adapter
     or (old.provider_operation_reference is not null and new.provider_operation_reference is distinct from old.provider_operation_reference)
     or new.provider_idempotency_key is distinct from old.provider_idempotency_key
     or new.actor_id is distinct from old.actor_id
     or new.funding_intent_id is distinct from old.funding_intent_id
     or new.allocation_id is distinct from old.allocation_id
     or new.amount_kobo is distinct from old.amount_kobo
     or new.merchant_identity is distinct from old.merchant_identity
     or new.currency is distinct from old.currency
     or new.destination_id is distinct from old.destination_id
     or new.destination_version is distinct from old.destination_version
     or new.request_sha256 is distinct from old.request_sha256
     or new.created_at is distinct from old.created_at
     or new.fee_kobo<old.fee_kobo
     or (old.fee_kobo>0 and new.fee_kobo is distinct from old.fee_kobo)
     or not (
       new.status=old.status or
       (old.status='queued_for_liquidity' and new.status in ('processing','unknown','exception')) or
       (old.status='pending' and new.status in ('processing','unknown','succeeded','settled','failed','cancelled','exception')) or
       (old.status='processing' and new.status in ('unknown','succeeded','settled','paid','failed','reversed','exception')) or
       (old.status='unknown' and new.status in ('processing','succeeded','settled','paid','failed','reversed','exception')) or
       (old.status in ('succeeded','settled','paid') and new.status in ('reversed','exception')) or
       (old.status in ('failed','cancelled') and new.status='exception')
     ) then
    raise exception using errcode='55000',message='provider_operation_identity_is_immutable';
  end if;
  new.updated_at:=pg_catalog.now();
  return new;
end;
$function$;

create or replace function app_private.complete_payment_operation_job(
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
       'reference_mismatch','merchant_mismatch','duplicate_collection','unknown_result','settlement_pending'
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
  if coalesce(p_safe_error_code,'')<>'duplicate_collection'
     and p_provider_reference is not null and v_operation.provider_operation_reference is not null
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
  else
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
        when 'merchant_mismatch' then 'merchant_mismatch'
        when 'duplicate_collection' then 'duplicate_collection'
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
  update app_private.payment_operation_jobs set state=v_final_state,
    available_at=case when v_final_state='retry' then pg_catalog.now()+
      pg_catalog.make_interval(secs=>least(60,power(2,v_job.attempt_count)::integer)) else available_at end,
    lease_token=null,lease_owner=null,lease_expires_at=null,last_safe_error_code=v_error
  where job_id=v_job.job_id returning * into v_job;
  return pg_catalog.jsonb_build_object('operation_id',p_operation_id,
    'operation_status',v_status,'job_state',v_job.state,
    'attempt_count',v_job.attempt_count,'reconcile_required',v_final_state='exhausted');
end;
$function$;

create function app_private.complete_job_funding_operation(
  p_operation_id uuid,p_lease_token uuid,p_status text,p_provider_reference text,
  p_amount_kobo text,p_currency text,p_merchant_identity text,p_client_reference uuid,
  p_fee_kobo text,p_safe_error_code text,p_retry boolean,p_result_sha256_hex text
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_operation app_private.provider_operations%rowtype;
  v_intent app_private.funding_intents%rowtype;
  v_attempt app_private.funding_attempts%rowtype;
  v_job app_private.jobs%rowtype;
  v_status text:=p_status;
  v_error text:=p_safe_error_code;
  v_exception text;
  v_fee bigint;
  v_net bigint;
  v_result jsonb;
  v_was_succeeded boolean;
begin
  if p_status not in ('processing','unknown','succeeded','failed','reversed','exception')
     or p_retry is null
     or (p_status in ('processing','unknown') and not p_retry)
     or (p_status in ('succeeded','failed','reversed','exception') and p_retry)
     or p_safe_error_code not in ('provider_timeout','provider_unavailable','amount_mismatch',
       'currency_mismatch','reference_mismatch','unknown_result','settlement_pending',
       'merchant_mismatch','duplicate_collection') and p_safe_error_code is not null
     or p_status='exception' and p_safe_error_code is null then
    raise exception using errcode='22023',message='invalid_payment_operation_result';
  end if;
  if p_fee_kobo is null or p_fee_kobo !~ '^(0|[1-9][0-9]{0,11})$' then
    raise exception using errcode='22023',message='invalid_provider_fee';
  end if;
  v_fee:=p_fee_kobo::bigint;
  select * into v_operation from app_private.provider_operations
    where operation_id=p_operation_id and operation_type='collection'
      and provider_adapter='local_simulator' for update;
  if not found then raise exception using errcode='22023',message='payment_operation_not_simulated'; end if;
  select * into v_intent from app_private.funding_intents
    where intent_id=v_operation.funding_intent_id for update;
  select * into v_attempt from app_private.funding_attempts
    where operation_id=p_operation_id for update;
  select * into v_job from app_private.jobs where job_id=v_intent.job_id for update;
  if not found or v_attempt.attempt_id is null then
    raise exception using errcode='22023',message='funding_result_mismatch';
  end if;
  v_was_succeeded:=v_intent.status='succeeded';

  if p_status in ('succeeded','failed') then
    if p_status='succeeded' and v_was_succeeded
       and p_provider_reference is distinct from v_operation.provider_operation_reference then
      v_status:='exception';v_error:='duplicate_collection';v_exception:='duplicate_collection';
    elsif p_client_reference is distinct from v_operation.provider_idempotency_key
       or p_provider_reference is distinct from 'sim-'||v_operation.provider_idempotency_key::text then
      v_status:='exception';v_error:='reference_mismatch';v_exception:='reference_mismatch';
    elsif p_currency is distinct from v_intent.currency then
      v_status:='exception';v_error:='currency_mismatch';v_exception:='currency_mismatch';
    elsif p_amount_kobo is null or p_amount_kobo !~ '^(0|[1-9][0-9]{0,11})$'
       or p_amount_kobo::numeric<>v_intent.gross_total_kobo::numeric then
      v_status:='exception';v_error:='amount_mismatch';v_exception:='amount_mismatch';
    elsif p_merchant_identity is distinct from v_intent.merchant_identity then
      v_status:='exception';v_error:='merchant_mismatch';v_exception:='merchant_mismatch';
    elsif v_fee>v_intent.gross_total_kobo or p_result_sha256_hex is null
       or p_result_sha256_hex !~ '^[0-9a-f]{64}$' then
      v_status:='exception';v_error:='amount_mismatch';v_exception:='amount_mismatch';
    elsif p_status='succeeded' and (v_job.active_funding_intent_id is distinct from v_intent.intent_id
       or v_job.current_terms_version<>v_intent.terms_version
       or v_intent.terms_sha256 is distinct from (
         select t.terms_sha256 from app_private.job_terms_versions t
         where t.job_id=v_intent.job_id and t.terms_version=v_intent.terms_version
       )) then
      v_status:='exception';v_error:='reference_mismatch';v_exception:='manual_reconciliation';
    elsif v_intent.status in ('failed','cancelled','exception') then
      v_status:='exception';v_error:='reference_mismatch';v_exception:='manual_reconciliation';
    end if;
  elsif p_status='reversed' and not v_was_succeeded then
    v_status:='exception';v_error:='unknown_result';v_exception:='unknown_result';
  elsif p_status='exception' then
    v_error:=p_safe_error_code;
    v_exception:=case p_safe_error_code
      when 'amount_mismatch' then 'amount_mismatch'
      when 'currency_mismatch' then 'currency_mismatch'
      when 'reference_mismatch' then 'reference_mismatch'
      when 'merchant_mismatch' then 'merchant_mismatch'
      when 'provider_unavailable' then 'provider_unavailable'
      else 'unknown_result' end;
  end if;

  if v_status='exception' and v_error is null then v_error:='unknown_result'; end if;
  v_result:=app_private.complete_payment_operation_job(
    p_operation_id,p_lease_token,v_status,p_provider_reference,p_fee_kobo,
    v_error,p_retry
  );
  if v_exception='manual_reconciliation' then
    insert into app_private.financial_exceptions(operation_id,funding_intent_id,
      exception_type,safe_reference)
    values(p_operation_id,v_intent.intent_id,v_exception,
      left(coalesce(p_provider_reference,''),180));
    if v_intent.status in ('pending','unknown') then
      update app_private.funding_attempts set status='exception'
        where attempt_id=v_attempt.attempt_id and status in ('pending','unknown');
      update app_private.funding_intents set status='exception'
        where intent_id=v_intent.intent_id and status in ('pending','unknown');
    end if;
    if v_job.active_funding_intent_id=v_intent.intent_id then
      perform app_private.append_marketplace_event(v_intent.poster_id,v_intent.job_id,
        'job.funding_exception',v_intent.terms_version,
        pg_catalog.jsonb_build_object('reason',v_exception));
    end if;
    return v_result||pg_catalog.jsonb_build_object('funding_status',
      case when v_intent.status in ('pending','unknown') then 'exception' else v_intent.status end);
  end if;

  if v_status='unknown' then
    update app_private.funding_attempts set status='unknown'
      where attempt_id=v_attempt.attempt_id and status='pending';
    update app_private.funding_intents set status='unknown'
      where intent_id=v_intent.intent_id and status='pending';
    if not exists(select 1 from app_private.financial_exceptions e
      where e.operation_id=p_operation_id and e.exception_type='unknown_result') then
      insert into app_private.financial_exceptions(operation_id,funding_intent_id,
        exception_type,safe_reference)
      values(p_operation_id,v_intent.intent_id,'unknown_result',
        left(coalesce(p_provider_reference,''),180));
    end if;
    if v_intent.status='pending' and v_job.active_funding_intent_id=v_intent.intent_id then
      perform app_private.append_marketplace_event(v_intent.poster_id,v_intent.job_id,
        'job.funding_exception',v_intent.terms_version,
        pg_catalog.jsonb_build_object('reason','unknown_result',
          'funding_intent_id',v_intent.intent_id));
    end if;
  elsif v_status='succeeded' and not v_was_succeeded then
    v_net:=v_intent.gross_total_kobo-v_fee;
    update app_private.funding_attempts set status='succeeded',
      collected_gross_kobo=v_intent.gross_total_kobo,provider_fee_kobo=v_fee,
      provider_net_kobo=v_net,currency=v_intent.currency,settlement_status='pending',
      provider_event_reference=p_provider_reference,
      result_sha256=pg_catalog.decode(p_result_sha256_hex,'hex')
      where attempt_id=v_attempt.attempt_id;
    perform app_private.record_exact_funding(v_intent.intent_id,v_attempt.attempt_number);
    update app_private.jobs set listing_state=case
      when pg_catalog.now()>=(select t.application_deadline_at from app_private.job_terms_versions t
        where t.job_id=v_intent.job_id and t.terms_version=v_intent.terms_version)
      then 'expired' else 'open' end,
      active_funding_intent_id=null,funded_funding_intent_id=v_intent.intent_id
      where job_id=v_intent.job_id and active_funding_intent_id=v_intent.intent_id;
    perform app_private.append_marketplace_event(v_intent.poster_id,v_intent.job_id,'job.funded',
      v_intent.terms_version,pg_catalog.jsonb_build_object(
        'funding_intent_id',v_intent.intent_id,'gross_total_kobo',v_intent.gross_total_kobo::text,
        'allocation_count',v_intent.slot_count));
  elsif v_status='succeeded' and v_was_succeeded then
    perform app_private.record_exact_funding(v_intent.intent_id,v_attempt.attempt_number);
  elsif v_status='failed' then
    update app_private.funding_attempts set status='failed'
      where attempt_id=v_attempt.attempt_id and status in ('pending','unknown');
    update app_private.funding_intents set status='failed'
      where intent_id=v_intent.intent_id and status in ('pending','unknown');
    if v_job.active_funding_intent_id=v_intent.intent_id then
      update app_private.jobs set listing_state='draft',active_funding_intent_id=null
        where job_id=v_intent.job_id;
      perform app_private.append_marketplace_event(v_intent.poster_id,v_intent.job_id,
        'job.funding_failed',v_intent.terms_version,
        pg_catalog.jsonb_build_object('funding_intent_id',v_intent.intent_id));
    end if;
  elsif v_status='reversed' and v_was_succeeded then
    insert into app_private.financial_exceptions(operation_id,funding_intent_id,
      exception_type,safe_reference)
    values(p_operation_id,v_intent.intent_id,'manual_reconciliation',
      left(coalesce(p_provider_reference,''),180));
  end if;
  return v_result||pg_catalog.jsonb_build_object('funding_status',
    case when v_status='unknown' then 'unknown'
      when v_status='succeeded' then 'succeeded'
      when v_status='failed' then 'failed'
      when v_status='reversed' then v_intent.status
      else v_intent.status end);
end;
$function$;

create function public.server_create_job_draft_for_actor(
  p_actor uuid,p_terms jsonb,p_idempotency_key uuid
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.create_job_draft_for_actor(p_actor,p_terms,p_idempotency_key)
$function$;
create function public.server_update_job_draft_for_actor(
  p_actor uuid,p_job_id uuid,p_expected_terms_version integer,p_terms jsonb,p_idempotency_key uuid
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.update_job_draft_for_actor(
    p_actor,p_job_id,p_expected_terms_version,p_terms,p_idempotency_key
  )
$function$;
create function public.server_start_job_funding_for_actor(
  p_actor uuid,p_job_id uuid,p_expected_terms_version integer,p_idempotency_key uuid
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.start_job_funding_for_actor(
    p_actor,p_job_id,p_expected_terms_version,p_idempotency_key
  )
$function$;
create function public.server_get_job_funding_status_for_actor(p_actor uuid,p_job_id uuid)
returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.get_job_funding_status_for_actor(p_actor,p_job_id)
$function$;
create function public.server_record_job_funding_initialization(
  p_operation_id uuid,p_provider_reference text
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.record_job_funding_initialization(p_operation_id,p_provider_reference)
$function$;
create function public.server_record_job_funding_unknown_for_actor(p_actor uuid,p_operation_id uuid)
returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.record_job_funding_unknown_for_actor(p_actor,p_operation_id)
$function$;
create function public.server_complete_job_funding_operation_for_runner(
  p_operation_id uuid,p_lease_token uuid,p_status text,p_provider_reference text,
  p_amount_kobo text,p_currency text,p_merchant_identity text,p_client_reference uuid,
  p_fee_kobo text,p_safe_error_code text,p_retry boolean,p_result_sha256_hex text
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.complete_job_funding_operation(
    p_operation_id,p_lease_token,p_status,p_provider_reference,p_amount_kobo,p_currency,
    p_merchant_identity,p_client_reference,p_fee_kobo,p_safe_error_code,p_retry,p_result_sha256_hex
  )
$function$;

revoke all on table app_private.jobs,app_private.job_terms_versions,app_private.marketplace_outbox
  from public,anon,authenticated,service_role;
revoke all on function app_private.reject_job_terms_mutation(),app_private.guard_job_change(),
  app_private.normalize_job_terms(jsonb),app_private.get_job_terms_projection(uuid,integer),
  app_private.append_marketplace_event(uuid,uuid,text,integer,jsonb),
  app_private.create_job_draft_for_actor(uuid,jsonb,uuid),
  app_private.update_job_draft_for_actor(uuid,uuid,integer,jsonb,uuid),
  app_private.funding_operation_projection(uuid),
  app_private.start_job_funding_for_actor(uuid,uuid,integer,uuid),
  app_private.get_job_funding_status_for_actor(uuid,uuid),
  app_private.record_job_funding_initialization(uuid,text),
  app_private.record_job_funding_unknown_for_actor(uuid,uuid),
  app_private.complete_job_funding_operation(uuid,uuid,text,text,text,text,text,uuid,text,text,boolean,text)
  from public,anon,authenticated,service_role;
revoke all on function public.server_create_job_draft_for_actor(uuid,jsonb,uuid),
  public.server_update_job_draft_for_actor(uuid,uuid,integer,jsonb,uuid),
  public.server_start_job_funding_for_actor(uuid,uuid,integer,uuid),
  public.server_get_job_funding_status_for_actor(uuid,uuid),
  public.server_record_job_funding_initialization(uuid,text),
  public.server_record_job_funding_unknown_for_actor(uuid,uuid),
  public.server_complete_job_funding_operation_for_runner(uuid,uuid,text,text,text,text,text,uuid,text,text,boolean,text)
  from public,anon,authenticated,service_role;
grant execute on function public.server_create_job_draft_for_actor(uuid,jsonb,uuid),
  public.server_update_job_draft_for_actor(uuid,uuid,integer,jsonb,uuid),
  public.server_start_job_funding_for_actor(uuid,uuid,integer,uuid),
  public.server_get_job_funding_status_for_actor(uuid,uuid),
  public.server_record_job_funding_initialization(uuid,text),
  public.server_record_job_funding_unknown_for_actor(uuid,uuid),
  public.server_complete_job_funding_operation_for_runner(uuid,uuid,text,text,text,text,text,uuid,text,text,boolean,text)
  to service_role;

commit;

