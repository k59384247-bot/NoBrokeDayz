begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

select ok((select relrowsecurity from pg_catalog.pg_class
  where oid='realtime.messages'::regclass),
  'Realtime authorization uses the managed messages table RLS boundary');
select ok(exists(select 1 from pg_catalog.pg_policies
    where schemaname='realtime' and tablename='messages'
      and policyname='nbd_private_realtime_hint_read' and cmd='SELECT'
      and roles @> array['authenticated']::name[])
  and not exists(select 1 from pg_catalog.pg_policies
    where schemaname='realtime' and tablename='messages' and cmd in ('INSERT','ALL')),
  'authenticated clients may receive scoped hints and have no Broadcast write policy');
select ok(has_function_privilege('authenticated','public.can_receive_realtime_hint(text)','EXECUTE')
  and not has_function_privilege('anon','public.can_receive_realtime_hint(text)','EXECUTE')
  and not has_function_privilege('service_role','public.can_receive_realtime_hint(text)','EXECUTE'),
  'only authenticated Realtime joins can invoke the narrow authorization predicate');
select ok(has_function_privilege('service_role',
    'public.server_get_realtime_topic_for_actor(uuid,text,uuid,text)','EXECUTE')
  and not has_function_privilege('authenticated',
    'public.server_get_realtime_topic_for_actor(uuid,text,uuid,text)','EXECUTE')
  and not has_function_privilege('anon',
    'public.server_get_realtime_topic_for_actor(uuid,text,uuid,text)','EXECUTE'),
  'topic names are issued only through the verified server gateway');
select ok(not has_table_privilege('anon','app_private.realtime_actor_generations','SELECT')
  and not has_table_privilege('authenticated','app_private.realtime_actor_generations','SELECT')
  and not has_table_privilege('service_role','app_private.realtime_actor_generations','SELECT'),
  'authorization generations are private database state');
select ok((select confdeltype='c' from pg_catalog.pg_constraint
    where conrelid='app_private.realtime_actor_generations'::regclass
      and conname='realtime_actor_generations_actor_id_fkey'),
  'actor generation state is removed with its synthetic or deleted Auth actor');
select ok(pg_catalog.strpos(pg_catalog.pg_get_functiondef(
    'app_private.emit_thread_invalidation(uuid,text)'::regprocedure),
    $$'kind','invalidate'$$)>0
  and pg_catalog.strpos(pg_catalog.pg_get_functiondef(
    'app_private.emit_thread_invalidation(uuid,text)'::regprocedure),'body')=0
  and pg_catalog.strpos(pg_catalog.pg_get_functiondef(
    'app_private.emit_notification_invalidation()'::regprocedure),
    $$'kind','invalidate'$$)>0,
  'database publishers emit generic invalidations without message or notice rows');
select ok((select pg_catalog.strpos(pg_catalog.pg_get_triggerdef(t.oid),'UPDATE OF read_at')>0
  from pg_catalog.pg_trigger t
  where t.tgrelid='app_private.in_app_notifications'::regclass
    and t.tgname='in_app_notifications_realtime_hint'),
  'first notice-read changes also publish generic invalidations');
select ok(pg_catalog.strpos(pg_catalog.pg_get_functiondef(
    'public.can_receive_realtime_hint(text)'::regprocedure),'auth.uid()')>0
  and pg_catalog.strpos(pg_catalog.pg_get_functiondef(
    'public.can_receive_realtime_hint(text)'::regprocedure),'realtime_actor_generations')>0
  and pg_catalog.strpos(pg_catalog.pg_get_functiondef(
    'public.can_receive_realtime_hint(text)'::regprocedure),'realtime_actor_can_read_case')>0,
  'join authorization binds topic actor, current generation and case access');

select * from finish();
rollback;
