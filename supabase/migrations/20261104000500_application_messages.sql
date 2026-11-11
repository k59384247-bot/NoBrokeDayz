begin;

create table app_private.thread_messages (
  message_id uuid primary key default pg_catalog.gen_random_uuid(),
  thread_id uuid not null references app_private.application_threads(thread_id) on delete restrict,
  sender_id uuid not null references auth.users(id) on delete restrict,
  client_message_id uuid not null,
  sequence bigint not null check (sequence > 0),
  body text not null check (char_length(body) between 1 and 2000 and body=pg_catalog.btrim(body)),
  created_at timestamptz not null default pg_catalog.now(),
  unique(thread_id,sequence),
  unique(sender_id,client_message_id)
);
create index thread_messages_page_idx on app_private.thread_messages(thread_id,sequence);

create table app_private.thread_read_cursors (
  thread_id uuid not null references app_private.application_threads(thread_id) on delete restrict,
  reader_id uuid not null references auth.users(id) on delete restrict,
  last_read_sequence bigint not null default 0 check (last_read_sequence >= 0),
  updated_at timestamptz not null default pg_catalog.now(),
  primary key(thread_id,reader_id)
);

create function app_private.guard_application_thread_change()
returns trigger language plpgsql set search_path = '' as $function$
begin
  if tg_op='DELETE' or new.thread_id is distinct from old.thread_id
     or new.application_id is distinct from old.application_id
     or new.created_at is distinct from old.created_at
     or new.last_sequence<>old.last_sequence+1 then
    raise exception using errcode='55000',message='application_thread_identity_is_immutable';
  end if;
  new.updated_at:=pg_catalog.now();
  return new;
end;
$function$;
create trigger application_threads_guard_change before update or delete
on app_private.application_threads for each row
execute function app_private.guard_application_thread_change();

create function app_private.reject_thread_message_mutation()
returns trigger language plpgsql set search_path = '' as $function$
begin
  raise exception using errcode='55000',message='thread_message_is_immutable';
end;
$function$;
create trigger thread_messages_immutable before update or delete
on app_private.thread_messages for each row
execute function app_private.reject_thread_message_mutation();

create function app_private.guard_thread_read_cursor_change()
returns trigger language plpgsql set search_path = '' as $function$
begin
  if tg_op='DELETE' or new.thread_id is distinct from old.thread_id
     or new.reader_id is distinct from old.reader_id
     or new.last_read_sequence<old.last_read_sequence then
    raise exception using errcode='55000',message='thread_read_cursor_must_move_forward';
  end if;
  new.updated_at:=pg_catalog.now();
  return new;
end;
$function$;
create trigger thread_read_cursors_guard_change before update or delete
on app_private.thread_read_cursors for each row
execute function app_private.guard_thread_read_cursor_change();

create function app_private.message_command_projection(
  p_message_id uuid,p_actor uuid,p_replayed boolean
) returns jsonb language sql stable security definer set search_path = '' as $function$
  select pg_catalog.jsonb_build_object(
    'message_id',m.message_id,
    'thread_id',m.thread_id,
    'client_message_id',m.client_message_id,
    'sequence',m.sequence::text,
    'sender_is_me',m.sender_id=p_actor,
    'body',m.body,
    'created_at',m.created_at,
    'replayed',p_replayed
  )
  from app_private.thread_messages m
  where m.message_id=p_message_id
$function$;

create function app_private.get_job_applications_for_actor(
  p_actor uuid,p_job_id uuid,p_cursor_applied_at timestamptz,
  p_cursor_application_id uuid,p_limit smallint
) returns jsonb language plpgsql stable security definer set search_path = '' as $function$
declare
  v_caps text[];
  v_result jsonb;
begin
  v_caps:=app_private.current_profile_capabilities(p_actor);
  if p_actor is null or p_job_id is null or p_limit<>21
     or ((p_cursor_applied_at is null)<>(p_cursor_application_id is null)) then
    raise exception using errcode='22023',message='invalid_application_query';
  end if;
  if not ('can_hire'=any(v_caps)) then
    raise exception using errcode='42501',message='verification_required';
  end if;
  if not exists(select 1 from app_private.jobs j
      where j.job_id=p_job_id and j.poster_id=p_actor and j.funded_funding_intent_id is not null) then
    raise exception using errcode='P0002',message='application_not_found';
  end if;
  with page as (
    select a.application_id,a.job_id,a.state,a.note,a.applied_terms_version as terms_version,
      a.applied_at,t.thread_id,s.assignment_id,p.display_name,ia.account_type
    from app_private.job_applications a
    join app_private.application_threads t using(application_id)
    left join app_private.assignments s using(application_id)
    left join public.profiles p on p.user_id=a.worker_id
    left join app_private.identity_accounts ia on ia.user_id=a.worker_id
    where a.job_id=p_job_id
      and (p_cursor_applied_at is null or (a.applied_at,a.application_id)<
        (p_cursor_applied_at,p_cursor_application_id))
    order by a.applied_at desc,a.application_id desc
    limit p_limit
  )
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'application_id',application_id,'thread_id',thread_id,'job_id',job_id,
    'state',state,'note',note,'terms_version',terms_version,'applied_at',applied_at,
    'assignment_id',assignment_id,
    'applicant_summary',case when display_name is null and account_type is null then null
      else pg_catalog.jsonb_build_object('display_name',display_name,'account_type',account_type) end
  ) order by applied_at desc,application_id desc),'[]'::jsonb)
  into v_result from page;
  return v_result;
end;
$function$;

create function app_private.get_my_applications_for_actor(
  p_actor uuid,p_cursor_applied_at timestamptz,p_cursor_application_id uuid,p_limit smallint
) returns jsonb language plpgsql stable security definer set search_path = '' as $function$
declare
  v_caps text[];
  v_result jsonb;
begin
  v_caps:=app_private.current_profile_capabilities(p_actor);
  if p_actor is null or p_limit<>21
     or ((p_cursor_applied_at is null)<>(p_cursor_application_id is null)) then
    raise exception using errcode='22023',message='invalid_application_query';
  end if;
  if not ('can_work'=any(v_caps)) then
    raise exception using errcode='42501',message='verification_required';
  end if;
  with page as (
    select a.application_id,a.job_id,a.state,a.note,a.applied_terms_version as terms_version,
      a.applied_at,t.thread_id,s.assignment_id,j.poster_id,terms.title,
      terms.gross_per_worker_kobo,poster.display_name,ia.account_type
    from app_private.job_applications a
    join app_private.jobs j using(job_id)
    join app_private.job_terms_versions terms
      on terms.job_id=a.job_id and terms.terms_version=a.applied_terms_version
    join app_private.application_threads t using(application_id)
    left join app_private.assignments s using(application_id)
    left join public.profiles poster on poster.user_id=j.poster_id
    left join app_private.identity_accounts ia on ia.user_id=j.poster_id
    where a.worker_id=p_actor
      and (p_cursor_applied_at is null or (a.applied_at,a.application_id)<
        (p_cursor_applied_at,p_cursor_application_id))
    order by a.applied_at desc,a.application_id desc
    limit p_limit
  )
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'application_id',application_id,'thread_id',thread_id,'job_id',job_id,
    'state',state,'note',note,'terms_version',terms_version,'applied_at',applied_at,
    'assignment_id',assignment_id,'job_title',title,
    'gross_per_worker_kobo',gross_per_worker_kobo::text,
    'poster_summary',case when display_name is null and account_type is null then null
      else pg_catalog.jsonb_build_object('display_name',display_name,'account_type',account_type) end
  ) order by applied_at desc,application_id desc),'[]'::jsonb)
  into v_result from page;
  return v_result;
end;
$function$;

create function app_private.get_application_thread_for_actor(
  p_actor uuid,p_application_id uuid,p_after_sequence bigint,p_limit smallint
) returns jsonb language plpgsql stable security definer set search_path = '' as $function$
declare
  v_caps text[];
  v_application app_private.job_applications%rowtype;
  v_job app_private.jobs%rowtype;
  v_thread app_private.application_threads%rowtype;
  v_terms app_private.job_terms_versions%rowtype;
  v_assignment app_private.assignments%rowtype;
  v_result jsonb;
  v_other_party jsonb;
  v_read_cursor bigint:=0;
begin
  if p_actor is null or p_application_id is null or p_after_sequence is null
     or p_after_sequence<0 or p_limit<>51 then
    raise exception using errcode='22023',message='invalid_application_query';
  end if;
  select * into v_application from app_private.job_applications
  where application_id=p_application_id;
  if not found then
    raise exception using errcode='P0002',message='application_not_found';
  end if;
  select * into v_job from app_private.jobs where job_id=v_application.job_id;
  if p_actor not in (v_application.worker_id,v_job.poster_id) then
    raise exception using errcode='P0002',message='application_not_found';
  end if;
  v_caps:=app_private.current_profile_capabilities(p_actor);
  if (p_actor=v_application.worker_id and not ('can_work'=any(v_caps))) or
     (p_actor=v_job.poster_id and not ('can_hire'=any(v_caps))) then
    raise exception using errcode='42501',message='verification_required';
  end if;
  select * into v_thread from app_private.application_threads
  where application_id=p_application_id;
  select * into v_terms from app_private.job_terms_versions
  where job_id=v_application.job_id and terms_version=v_application.applied_terms_version;
  select * into v_assignment from app_private.assignments
  where application_id=p_application_id;
  if p_after_sequence>v_thread.last_sequence then
    raise exception using errcode='22023',message='invalid_application_query';
  end if;
  select coalesce(last_read_sequence,0) into v_read_cursor
  from app_private.thread_read_cursors
  where thread_id=v_thread.thread_id and reader_id=p_actor;
  if not found then v_read_cursor:=0; end if;
  if p_actor=v_application.worker_id then
    select pg_catalog.jsonb_build_object('display_name',p.display_name,'account_type',ia.account_type)
    into v_other_party from app_private.identity_accounts ia
    left join public.profiles p on p.user_id=ia.user_id
    where ia.user_id=v_job.poster_id;
  else
    select pg_catalog.jsonb_build_object('display_name',p.display_name,'account_type',ia.account_type)
    into v_other_party from app_private.identity_accounts ia
    left join public.profiles p on p.user_id=ia.user_id
    where ia.user_id=v_application.worker_id;
  end if;
  select pg_catalog.jsonb_build_object(
    'application_id',v_application.application_id,
    'thread_id',v_thread.thread_id,
    'job_id',v_application.job_id,
    'job_title',v_terms.title,
    'application_state',v_application.state,
    'thread_state',case when v_application.state in ('rejected','withdrawn','closed')
      then 'read_only' else 'open' end,
    'terms_version',v_application.applied_terms_version,
    'note',v_application.note,
    'applied_at',v_application.applied_at,
    'assignment_id',v_assignment.assignment_id,
    'assignment_state',v_assignment.work_state,
    'gross_per_worker_kobo',v_terms.gross_per_worker_kobo::text,
    'other_party',v_other_party,
    'last_sequence',v_thread.last_sequence::text,
    'read_cursor',v_read_cursor::text,
    'messages',coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'message_id',m.message_id,'client_message_id',m.client_message_id,
        'sequence',m.sequence::text,'sender_is_me',m.sender_id=p_actor,
        'body',m.body,'created_at',m.created_at
      ) order by m.sequence)
      from (
        select message_id,client_message_id,sequence,sender_id,body,created_at
        from app_private.thread_messages
        where thread_id=v_thread.thread_id and sequence>p_after_sequence
        order by sequence limit p_limit
      ) m
    ),'[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$function$;

create function app_private.send_application_message_for_actor(
  p_actor uuid,p_thread_id uuid,p_client_message_id uuid,p_body text
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_application app_private.job_applications%rowtype;
  v_job app_private.jobs%rowtype;
  v_thread app_private.application_threads%rowtype;
  v_existing app_private.thread_messages%rowtype;
  v_caps text[];
  v_body text;
  v_sequence bigint;
  v_message_id uuid:=pg_catalog.gen_random_uuid();
  v_recipient uuid;
  v_event_id uuid;
begin
  if p_actor is null or p_thread_id is null or p_client_message_id is null or p_body is null then
    raise exception using errcode='22023',message='invalid_message';
  end if;
  v_body:=pg_catalog.btrim(pg_catalog.replace(p_body,E'\r\n',E'\n'));
  if pg_catalog.char_length(v_body)<1 or pg_catalog.char_length(v_body)>2000 then
    raise exception using errcode='22023',message='invalid_message';
  end if;
  select a.* into v_application
  from app_private.job_applications a
  join app_private.application_threads t using(application_id)
  where t.thread_id=p_thread_id
  for update of a;
  if not found then raise exception using errcode='P0002',message='application_not_found'; end if;
  select * into v_job from app_private.jobs where job_id=v_application.job_id;
  if p_actor not in (v_application.worker_id,v_job.poster_id) then
    raise exception using errcode='P0002',message='application_not_found';
  end if;
  v_caps:=app_private.current_profile_capabilities(p_actor);
  if (p_actor=v_application.worker_id and not ('can_work'=any(v_caps))) or
     (p_actor=v_job.poster_id and not ('can_hire'=any(v_caps))) then
    raise exception using errcode='42501',message='verification_required';
  end if;
  if v_application.state not in ('applied','accepted') then
    raise exception using errcode='P0001',message='thread_read_only';
  end if;
  select * into v_thread from app_private.application_threads
  where thread_id=p_thread_id for update;
  select * into v_existing from app_private.thread_messages
  where sender_id=p_actor and client_message_id=p_client_message_id;
  if found then
    if v_existing.thread_id<>p_thread_id or v_existing.body<>v_body then
      raise exception using errcode='23505',message='idempotency_conflict';
    end if;
    return app_private.message_command_projection(v_existing.message_id,p_actor,true);
  end if;
  update app_private.application_threads
  set last_sequence=last_sequence+1
  where thread_id=p_thread_id
  returning last_sequence into v_sequence;
  insert into app_private.thread_messages(
    message_id,thread_id,sender_id,client_message_id,sequence,body
  ) values(v_message_id,p_thread_id,p_actor,p_client_message_id,v_sequence,v_body);
  v_recipient:=case when p_actor=v_application.worker_id then v_job.poster_id else v_application.worker_id end;
  v_event_id:=app_private.append_marketplace_event(
    p_actor,v_job.job_id,'job.message_created',v_application.applied_terms_version,
    pg_catalog.jsonb_build_object(
      'application_id',v_application.application_id,'thread_id',p_thread_id,
      'message_id',v_message_id,'sequence',v_sequence::text
    )
  );
  perform app_private.add_in_app_notification(v_event_id,v_recipient,'new_message');
  return app_private.message_command_projection(v_message_id,p_actor,false);
end;
$function$;

create function app_private.mark_application_thread_read_for_actor(
  p_actor uuid,p_thread_id uuid,p_last_read_sequence bigint
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_application app_private.job_applications%rowtype;
  v_job app_private.jobs%rowtype;
  v_thread app_private.application_threads%rowtype;
  v_caps text[];
  v_last_read bigint;
begin
  if p_actor is null or p_thread_id is null or p_last_read_sequence is null or p_last_read_sequence<0 then
    raise exception using errcode='22023',message='invalid_application_query';
  end if;
  select a.* into v_application
  from app_private.job_applications a
  join app_private.application_threads t using(application_id)
  where t.thread_id=p_thread_id;
  if not found then raise exception using errcode='P0002',message='application_not_found'; end if;
  select * into v_job from app_private.jobs where job_id=v_application.job_id;
  if p_actor not in (v_application.worker_id,v_job.poster_id) then
    raise exception using errcode='P0002',message='application_not_found';
  end if;
  v_caps:=app_private.current_profile_capabilities(p_actor);
  if (p_actor=v_application.worker_id and not ('can_work'=any(v_caps))) or
     (p_actor=v_job.poster_id and not ('can_hire'=any(v_caps))) then
    raise exception using errcode='42501',message='verification_required';
  end if;
  select * into v_thread from app_private.application_threads
  where thread_id=p_thread_id for update;
  if p_last_read_sequence>v_thread.last_sequence then
    raise exception using errcode='22023',message='invalid_application_query';
  end if;
  insert into app_private.thread_read_cursors(thread_id,reader_id,last_read_sequence)
  values(p_thread_id,p_actor,p_last_read_sequence)
  on conflict(thread_id,reader_id) do update set
    last_read_sequence=greatest(app_private.thread_read_cursors.last_read_sequence,
      excluded.last_read_sequence)
  returning last_read_sequence into v_last_read;
  return pg_catalog.jsonb_build_object(
    'thread_id',p_thread_id,'last_read_sequence',v_last_read::text
  );
end;
$function$;

create function public.server_get_job_applications_for_actor(
  p_actor uuid,p_job_id uuid,p_cursor_applied_at timestamptz,
  p_cursor_application_id uuid,p_limit smallint
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.get_job_applications_for_actor(
    p_actor,p_job_id,p_cursor_applied_at,p_cursor_application_id,p_limit
  )
$function$;
create function public.server_get_my_applications_for_actor(
  p_actor uuid,p_cursor_applied_at timestamptz,p_cursor_application_id uuid,p_limit smallint
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.get_my_applications_for_actor(
    p_actor,p_cursor_applied_at,p_cursor_application_id,p_limit
  )
$function$;
create function public.server_get_application_thread_for_actor(
  p_actor uuid,p_application_id uuid,p_after_sequence bigint,p_limit smallint
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.get_application_thread_for_actor(
    p_actor,p_application_id,p_after_sequence,p_limit
  )
$function$;
create function public.server_send_application_message_for_actor(
  p_actor uuid,p_thread_id uuid,p_client_message_id uuid,p_body text
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.send_application_message_for_actor(
    p_actor,p_thread_id,p_client_message_id,p_body
  )
$function$;
create function public.server_mark_application_thread_read_for_actor(
  p_actor uuid,p_thread_id uuid,p_last_read_sequence bigint
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.mark_application_thread_read_for_actor(
    p_actor,p_thread_id,p_last_read_sequence
  )
$function$;

revoke all on table app_private.thread_messages,app_private.thread_read_cursors
  from public,anon,authenticated,service_role;
revoke all on function app_private.guard_application_thread_change(),
  app_private.reject_thread_message_mutation(),app_private.guard_thread_read_cursor_change(),
  app_private.message_command_projection(uuid,uuid,boolean),
  app_private.get_job_applications_for_actor(uuid,uuid,timestamptz,uuid,smallint),
  app_private.get_my_applications_for_actor(uuid,timestamptz,uuid,smallint),
  app_private.get_application_thread_for_actor(uuid,uuid,bigint,smallint),
  app_private.send_application_message_for_actor(uuid,uuid,uuid,text),
  app_private.mark_application_thread_read_for_actor(uuid,uuid,bigint)
  from public,anon,authenticated,service_role;
revoke all on function public.server_get_job_applications_for_actor(uuid,uuid,timestamptz,uuid,smallint),
  public.server_get_my_applications_for_actor(uuid,timestamptz,uuid,smallint),
  public.server_get_application_thread_for_actor(uuid,uuid,bigint,smallint),
  public.server_send_application_message_for_actor(uuid,uuid,uuid,text),
  public.server_mark_application_thread_read_for_actor(uuid,uuid,bigint)
  from public,anon,authenticated,service_role;
grant execute on function public.server_get_job_applications_for_actor(uuid,uuid,timestamptz,uuid,smallint),
  public.server_get_my_applications_for_actor(uuid,timestamptz,uuid,smallint),
  public.server_get_application_thread_for_actor(uuid,uuid,bigint,smallint),
  public.server_send_application_message_for_actor(uuid,uuid,uuid,text),
  public.server_mark_application_thread_read_for_actor(uuid,uuid,bigint)
  to service_role;

commit;
