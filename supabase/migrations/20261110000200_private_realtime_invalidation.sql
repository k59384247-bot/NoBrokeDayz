begin;

create table app_private.realtime_actor_generations (
  actor_id uuid primary key references auth.users(id) on delete cascade,
  generation bigint not null default 1 check (generation > 0),
  updated_at timestamptz not null default pg_catalog.now()
);
revoke all on app_private.realtime_actor_generations from public,anon,authenticated,service_role;

create function app_private.advance_realtime_actor_generation(p_actor uuid)
returns void language sql security definer set search_path = '' as $function$
  insert into app_private.realtime_actor_generations(actor_id,generation)
  values(p_actor,2)
  on conflict(actor_id) do update
    set generation=app_private.realtime_actor_generations.generation+1,
        updated_at=pg_catalog.now()
$function$;

create function app_private.emit_thread_invalidation(p_thread uuid,p_event text)
returns void language plpgsql security definer set search_path = '' as $function$
declare v_actor uuid; v_generation bigint;
begin
  for v_actor in
    select distinct u.actor_id from (
      select a.worker_id as actor_id from app_private.application_threads t
        join app_private.job_applications a using(application_id) where t.thread_id=p_thread
      union
      select j.poster_id as actor_id from app_private.application_threads t
        join app_private.job_applications a using(application_id)
        join app_private.jobs j using(job_id) where t.thread_id=p_thread
    ) u where app_private.realtime_actor_can_read_thread(u.actor_id,p_thread)
  loop
    v_generation:=app_private.current_realtime_actor_generation(v_actor);
    perform realtime.send(pg_catalog.jsonb_build_object('kind','invalidate'),p_event,
      app_private.realtime_hint_topic('thread',p_thread,v_actor,v_generation),true);
  end loop;
end;
$function$;

create function app_private.emit_notification_invalidation()
returns trigger language plpgsql security definer set search_path = '' as $function$
declare v_generation bigint;
begin
  if tg_op='UPDATE' and new.read_at is not distinct from old.read_at then
    return new;
  end if;
  if app_private.realtime_actor_can_read_notifications(new.recipient_id) then
    v_generation:=app_private.current_realtime_actor_generation(new.recipient_id);
    perform realtime.send(pg_catalog.jsonb_build_object('kind','invalidate'),
      'notifications.changed',
      app_private.realtime_hint_topic('notifications',null,new.recipient_id,v_generation),true);
  end if;
  return new;
end;
$function$;
create trigger in_app_notifications_realtime_hint
  after insert or update of read_at on app_private.in_app_notifications
  for each row execute function app_private.emit_notification_invalidation();

create function app_private.emit_thread_message_invalidation()
returns trigger language plpgsql security definer set search_path = '' as $function$
begin
  perform app_private.emit_thread_invalidation(new.thread_id,'thread.changed');
  return new;
end;
$function$;
create trigger thread_messages_realtime_hint
  after insert on app_private.thread_messages
  for each row execute function app_private.emit_thread_message_invalidation();

create function app_private.emit_thread_read_invalidation()
returns trigger language plpgsql security definer set search_path = '' as $function$
begin
  if tg_op='INSERT' or new.last_read_sequence is distinct from old.last_read_sequence then
    perform app_private.emit_thread_invalidation(new.thread_id,'thread.read_changed');
  end if;
  return new;
end;
$function$;
create trigger thread_read_cursors_realtime_hint
  after insert or update on app_private.thread_read_cursors
  for each row execute function app_private.emit_thread_read_invalidation();

create function app_private.current_realtime_actor_generation(p_actor uuid)
returns bigint language plpgsql security definer set search_path = '' as $function$
declare v_generation bigint;
begin
  if p_actor is null then return null; end if;
  insert into app_private.realtime_actor_generations(actor_id)
  values(p_actor) on conflict(actor_id) do nothing;
  select generation into v_generation from app_private.realtime_actor_generations
    where actor_id=p_actor;
  return v_generation;
end;
$function$;

create function app_private.bump_realtime_generation_for_identity()
returns trigger language plpgsql security definer set search_path = '' as $function$
begin
  if tg_op='INSERT' then
    perform app_private.advance_realtime_actor_generation(new.user_id);
  elsif tg_op='DELETE' then
    perform app_private.advance_realtime_actor_generation(old.user_id);
  elsif new.user_id is distinct from old.user_id then
    perform app_private.advance_realtime_actor_generation(old.user_id);
    perform app_private.advance_realtime_actor_generation(new.user_id);
  elsif new is distinct from old then
    perform app_private.advance_realtime_actor_generation(new.user_id);
  end if;
  return null;
end;
$function$;

create trigger realtime_identity_account_generation
after insert or update of account_status,account_type,age_confirmed_at,verification_track,verification_status
on app_private.identity_accounts
for each row execute function app_private.bump_realtime_generation_for_identity();
create trigger realtime_identity_capability_generation
after insert or update or delete on app_private.identity_capabilities
for each row execute function app_private.bump_realtime_generation_for_identity();
create trigger realtime_staff_grant_generation
after insert or update or delete on app_private.staff_grants
for each row execute function app_private.bump_realtime_generation_for_identity();
create trigger realtime_phone_binding_generation
after insert or update or delete on app_private.identity_phone_bindings
for each row execute function app_private.bump_realtime_generation_for_identity();
create trigger realtime_school_ownership_generation
after insert or update or delete on app_private.institutional_email_ownerships
for each row execute function app_private.bump_realtime_generation_for_identity();

create function app_private.bump_realtime_generation_for_auth_user()
returns trigger language plpgsql security definer set search_path = '' as $function$
begin
  if new.email is distinct from old.email
     or new.email_confirmed_at is distinct from old.email_confirmed_at
     or new.phone is distinct from old.phone
     or new.phone_confirmed_at is distinct from old.phone_confirmed_at
     or new.phone_change is distinct from old.phone_change then
    perform app_private.advance_realtime_actor_generation(new.id);
  end if;
  return null;
end;
$function$;
create trigger realtime_auth_user_generation
after update of email,email_confirmed_at,phone,phone_confirmed_at,phone_change on auth.users
for each row execute function app_private.bump_realtime_generation_for_auth_user();

create function app_private.bump_realtime_generation_for_school_domain()
returns trigger language plpgsql security definer set search_path = '' as $function$
begin
  if new.enabled is distinct from old.enabled then
    update app_private.realtime_actor_generations g
      set generation=g.generation+1,updated_at=pg_catalog.now()
      where g.actor_id in (
        select o.user_id from app_private.institutional_email_ownerships o
        where pg_catalog.split_part(o.normalized_email,'@',2)=new.domain and o.revoked_at is null
      );
  end if;
  return null;
end;
$function$;
create trigger realtime_school_domain_generation
after update of enabled on app_private.institutional_email_domains
for each row execute function app_private.bump_realtime_generation_for_school_domain();

create function app_private.realtime_actor_can_read_thread(p_actor uuid,p_thread uuid)
returns boolean language sql stable security definer set search_path = '' as $function$
  select exists(
    select 1 from app_private.application_threads t
    join app_private.job_applications a using(application_id)
    join app_private.jobs j using(job_id)
    where t.thread_id=p_thread and p_actor in (a.worker_id,j.poster_id)
      and ((p_actor=a.worker_id and 'can_work'=any(app_private.current_profile_capabilities(p_actor)))
        or (p_actor=j.poster_id and 'can_hire'=any(app_private.current_profile_capabilities(p_actor))))
  )
$function$;

create function app_private.realtime_actor_can_read_notifications(p_actor uuid)
returns boolean language sql stable security definer set search_path = '' as $function$
  select exists(select 1 from app_private.identity_accounts a
    where a.user_id=p_actor and a.account_status='active')
$function$;

create function app_private.realtime_actor_can_read_case(
  p_actor uuid,p_case uuid,p_auth_aal text
) returns boolean language sql stable security definer set search_path = '' as $function$
  select exists(
    select 1 from app_private.assignment_cases c
    join app_private.assignments a using(assignment_id)
    where c.case_id=p_case and (
      (p_actor in (a.worker_id,a.poster_id) and exists(
        select 1 from app_private.identity_accounts ia
        where ia.user_id=p_actor and ia.account_status='active'))
      or (c.reviewer_id=p_actor and p_actor not in (a.worker_id,a.poster_id)
        and app_private.staff_actor_has_current_capability(p_actor,'dispute_review',p_auth_aal))
    )
  )
$function$;

create function app_private.realtime_hint_topic(
  p_scope text,p_resource uuid,p_actor uuid,p_generation bigint
) returns text language sql immutable set search_path = '' as $function$
  select case p_scope
    when 'thread' then 'nbd:thread:'||p_resource::text||':actor:'||p_actor::text||':g:'||p_generation::text
    when 'notifications' then 'nbd:notifications:actor:'||p_actor::text||':g:'||p_generation::text
    when 'case' then 'nbd:case:'||p_resource::text||':actor:'||p_actor::text||':g:'||p_generation::text
    else null end
$function$;

create function app_private.emit_case_invalidation(p_case uuid,p_participants boolean)
returns void language plpgsql security definer set search_path = '' as $function$
declare
  v_assignment app_private.assignments%rowtype;
  v_case app_private.assignment_cases%rowtype;
  v_actor uuid;
  v_generation bigint;
begin
  select * into v_case from app_private.assignment_cases where case_id=p_case;
  if not found then return; end if;
  select * into v_assignment from app_private.assignments where assignment_id=v_case.assignment_id;
  if p_participants then
    for v_actor in select unnest(array[v_assignment.worker_id,v_assignment.poster_id]) loop
      if app_private.realtime_actor_can_read_case(v_actor,p_case,null) then
        v_generation:=app_private.current_realtime_actor_generation(v_actor);
        perform realtime.send(pg_catalog.jsonb_build_object('kind','invalidate'),'case.changed',
          app_private.realtime_hint_topic('case',p_case,v_actor,v_generation),true);
      end if;
    end loop;
  end if;
  if v_case.reviewer_id is not null and v_case.reviewer_id not in (v_assignment.worker_id,v_assignment.poster_id)
     and app_private.realtime_actor_can_read_case(v_case.reviewer_id,p_case,'aal2') then
    v_generation:=app_private.current_realtime_actor_generation(v_case.reviewer_id);
    perform realtime.send(pg_catalog.jsonb_build_object('kind','invalidate'),'case.changed',
      app_private.realtime_hint_topic('case',p_case,v_case.reviewer_id,v_generation),true);
  end if;
end;
$function$;

create function app_private.emit_case_event_invalidation()
returns trigger language plpgsql security definer set search_path = '' as $function$
begin
  perform app_private.emit_case_invalidation(new.case_id,new.audience='participants');
  return new;
end;
$function$;
create trigger assignment_case_events_realtime_hint
  after insert on app_private.assignment_case_events
  for each row execute function app_private.emit_case_event_invalidation();

create function app_private.rotate_case_reviewer_generation()
returns trigger language plpgsql security definer set search_path = '' as $function$
begin
  if new.reviewer_id is distinct from old.reviewer_id then
    if old.reviewer_id is not null then
      perform app_private.advance_realtime_actor_generation(old.reviewer_id);
    end if;
    if new.reviewer_id is not null then
      perform app_private.advance_realtime_actor_generation(new.reviewer_id);
    end if;
    perform app_private.emit_case_invalidation(new.case_id,true);
  end if;
  return new;
end;
$function$;
create trigger assignment_cases_realtime_reviewer_rotation
  after update of reviewer_id on app_private.assignment_cases
  for each row execute function app_private.rotate_case_reviewer_generation();

create function public.can_receive_realtime_hint(p_topic text)
returns boolean language plpgsql stable security definer set search_path = '' as $function$
declare
  v_actor uuid:=auth.uid();
  v_scope text;
  v_resource uuid;
  v_topic_actor uuid;
  v_generation bigint;
  v_current_generation bigint;
begin
  if v_actor is null or p_topic is null then return false; end if;
  begin
    if pg_catalog.split_part(p_topic,':',1)<>'nbd' then return false; end if;
    v_scope:=pg_catalog.split_part(p_topic,':',2);
    if v_scope='notifications' and pg_catalog.array_length(pg_catalog.string_to_array(p_topic,':'),1)=6 then
      v_topic_actor:=pg_catalog.split_part(p_topic,':',4)::uuid;
      v_generation:=pg_catalog.split_part(p_topic,':',6)::bigint;
    elsif v_scope in ('thread','case') and pg_catalog.array_length(pg_catalog.string_to_array(p_topic,':'),1)=7 then
      v_resource:=pg_catalog.split_part(p_topic,':',3)::uuid;
      v_topic_actor:=pg_catalog.split_part(p_topic,':',5)::uuid;
      v_generation:=pg_catalog.split_part(p_topic,':',7)::bigint;
    else
      return false;
    end if;
  exception when invalid_text_representation or numeric_value_out_of_range then
    return false;
  end;
  if v_topic_actor<>v_actor or v_generation is null or v_generation<1
     or app_private.realtime_hint_topic(v_scope,v_resource,v_topic_actor,v_generation)<>p_topic then
    return false;
  end if;
  select generation into v_current_generation
    from app_private.realtime_actor_generations where actor_id=v_actor;
  if v_current_generation is distinct from v_generation then return false; end if;
  if v_scope='thread' then
    return app_private.realtime_actor_can_read_thread(v_actor,v_resource);
  elsif v_scope='notifications' then
    return app_private.realtime_actor_can_read_notifications(v_actor);
  end if;
  return app_private.realtime_actor_can_read_case(v_actor,v_resource,auth.jwt()->>'aal');
end;
$function$;
revoke all on function public.can_receive_realtime_hint(text) from public,anon,service_role;
grant execute on function public.can_receive_realtime_hint(text) to authenticated;

drop policy if exists nbd_private_realtime_hint_read on realtime.messages;
create policy nbd_private_realtime_hint_read on realtime.messages
  for select to authenticated using (
    realtime.messages.extension='broadcast'
    and public.can_receive_realtime_hint(realtime.topic())
  );

create function app_private.get_realtime_topic_for_actor(
  p_actor uuid,p_scope text,p_resource uuid,p_auth_aal text
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  v_thread uuid;
  v_topic text;
  v_event text;
begin
  if p_actor is null or p_scope is null then
    raise exception using errcode='22023',message='invalid_realtime_topic_request';
  end if;
  if p_scope='thread' then
    select thread_id into v_thread from app_private.application_threads
      where application_id=p_resource;
    if v_thread is null or not app_private.realtime_actor_can_read_thread(p_actor,v_thread) then
      raise exception using errcode='P0002',message='realtime_topic_not_found';
    end if;
    v_topic:=app_private.realtime_hint_topic('thread',v_thread,p_actor,
      app_private.current_realtime_actor_generation(p_actor));
    v_event:='thread.changed,thread.read_changed';
  elsif p_scope='notifications' and p_resource is null then
    if not app_private.realtime_actor_can_read_notifications(p_actor) then
      raise exception using errcode='P0002',message='realtime_topic_not_found';
    end if;
    v_topic:=app_private.realtime_hint_topic('notifications',null,p_actor,
      app_private.current_realtime_actor_generation(p_actor));
    v_event:='notifications.changed';
  elsif p_scope='case' and p_resource is not null then
    if not app_private.realtime_actor_can_read_case(p_actor,p_resource,p_auth_aal) then
      raise exception using errcode='P0002',message='realtime_topic_not_found';
    end if;
    v_topic:=app_private.realtime_hint_topic('case',p_resource,p_actor,
      app_private.current_realtime_actor_generation(p_actor));
    v_event:='case.changed';
  else
    raise exception using errcode='22023',message='invalid_realtime_topic_request';
  end if;
  return pg_catalog.jsonb_build_object('topic',v_topic,'event',v_event,'private',true);
end;
$function$;
revoke all on function app_private.get_realtime_topic_for_actor(uuid,text,uuid,text)
  from public,anon,authenticated,service_role;

create function public.server_get_realtime_topic_for_actor(
  p_actor uuid,p_scope text,p_resource uuid,p_auth_aal text
) returns jsonb language sql security definer set search_path = '' as $function$
  select app_private.get_realtime_topic_for_actor($1,$2,$3,$4)
$function$;
revoke all on function public.server_get_realtime_topic_for_actor(uuid,text,uuid,text)
  from public,anon,authenticated,service_role;
grant execute on function public.server_get_realtime_topic_for_actor(uuid,text,uuid,text)
  to service_role;

revoke all on function app_private.advance_realtime_actor_generation(uuid),
  app_private.current_realtime_actor_generation(uuid),
  app_private.bump_realtime_generation_for_identity(),
  app_private.bump_realtime_generation_for_auth_user(),
  app_private.bump_realtime_generation_for_school_domain(),
  app_private.realtime_actor_can_read_thread(uuid,uuid),
  app_private.realtime_actor_can_read_notifications(uuid),
  app_private.realtime_actor_can_read_case(uuid,uuid,text),
  app_private.realtime_hint_topic(text,uuid,uuid,bigint),
  app_private.emit_thread_invalidation(uuid,text),
  app_private.emit_notification_invalidation(),
  app_private.emit_thread_message_invalidation(),
  app_private.emit_thread_read_invalidation(),
  app_private.emit_case_invalidation(uuid,boolean),
  app_private.emit_case_event_invalidation(),
  app_private.rotate_case_reviewer_generation()
  from public,anon,authenticated,service_role;

commit;
