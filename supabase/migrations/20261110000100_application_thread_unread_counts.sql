begin;

create or replace function app_private.get_application_thread_for_actor(
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
    'unread_count',(select count(*)::text from app_private.thread_messages m
      where m.thread_id=v_thread.thread_id and m.sequence>v_read_cursor and m.sender_id<>p_actor),
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

commit;
