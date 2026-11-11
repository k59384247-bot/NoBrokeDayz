begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

select ok(to_regclass('app_private.notification_email_deliveries') is not null,
  'email delivery state is stored in a private durable table');
select ok(not has_table_privilege('anon','app_private.notification_email_deliveries','SELECT')
  and not has_table_privilege('authenticated','app_private.notification_email_deliveries','SELECT')
  and not has_table_privilege('service_role','app_private.notification_email_deliveries','SELECT'),
  'delivery rows cannot be read directly through database roles');
select ok(has_function_privilege('service_role','public.server_claim_notification_email_for_runner(uuid,integer)','EXECUTE')
  and has_function_privilege('service_role','public.server_complete_notification_email_for_runner(uuid,uuid,text,text,uuid)','EXECUTE')
  and has_function_privilege('service_role','public.server_list_notification_delivery_attention_for_actor(uuid,text,timestamp with time zone,uuid)','EXECUTE')
  and not has_function_privilege('authenticated','public.server_claim_notification_email_for_runner(uuid,integer)','EXECUTE')
  and not has_function_privilege('anon','public.server_list_notification_delivery_attention_for_actor(uuid,text,timestamp with time zone,uuid)','EXECUTE'),
  'runner and operations RPCs are restricted to the server gateway');
select ok((select pg_catalog.pg_get_constraintdef(oid) like '%notification_delivery_review%'
  from pg_catalog.pg_constraint where conname='staff_grants_capability_check'),
  'delivery attention uses a dedicated read-only staff grant');

select set_config('test.delivery_actor',(select id::text from auth.users where email='phase2-trackb@identity.test'),true);
insert into app_private.identity_accounts(user_id,account_type,age_confirmed_at,age_policy_version)
values(current_setting('test.delivery_actor')::uuid,'student',pg_catalog.now(),'delivery-test-v1')
on conflict(user_id) do nothing;

with e as (insert into app_private.identity_audit_events(actor_id,subject_id,event_type,event_data)
values(current_setting('test.delivery_actor')::uuid,current_setting('test.delivery_actor')::uuid,
  'verification_submitted',pg_catalog.jsonb_build_object('submission_id','81900000-0000-4000-8000-000000000001'))
returning event_id)
select set_config('test.delivery_identity_event',e.event_id::text,true) from e;
insert into app_private.identity_outbox(event_id,subject_id,event_type,payload)
values(current_setting('test.delivery_identity_event')::uuid,current_setting('test.delivery_actor')::uuid,'verification_result',
  pg_catalog.jsonb_build_object('submission_id','81900000-0000-4000-8000-000000000001','status','pending')
);
select is((select count(*)::integer from app_private.in_app_notifications n
  where n.identity_event_id=current_setting('test.delivery_identity_event')::uuid
    and n.recipient_id=current_setting('test.delivery_actor')::uuid
    and n.notification_type='verification_submitted'),1,
  'verification result becomes an in-app notice in the source transaction');
select is((select count(*)::integer from app_private.notification_email_deliveries d
  join app_private.in_app_notifications n using(notification_id)
  where n.identity_event_id=current_setting('test.delivery_identity_event')::uuid),1,
  'verification notice atomically creates one email intent');
select is((select destination_kind from app_private.in_app_notifications
  where identity_event_id=current_setting('test.delivery_identity_event')::uuid),null::text,
  'verification notice has no unsupported destination route');
select ok((app_private.list_my_notifications_for_actor(current_setting('test.delivery_actor')::uuid,null,null)
  ->'notifications'->0 ? 'destination_kind')
  and (app_private.list_my_notifications_for_actor(current_setting('test.delivery_actor')::uuid,null,null)
  ->'notifications'->0->>'notification_type')='verification_submitted',
  'recipient read projection returns the allow-listed destination fields without identity evidence');

with e as (insert into app_private.financial_audit_events(actor_id,event_type,reference_id,event_data)
values(current_setting('test.delivery_actor')::uuid,'withdrawal_status_changed',
  '81900000-0000-4000-8000-000000000020',pg_catalog.jsonb_build_object('status','paid'))
returning event_id)
select set_config('test.delivery_financial_event',e.event_id::text,true) from e;
select app_private.add_financial_in_app_notification(
  current_setting('test.delivery_financial_event')::uuid,current_setting('test.delivery_actor')::uuid,'withdrawal_paid');
select app_private.add_financial_in_app_notification(
  current_setting('test.delivery_financial_event')::uuid,current_setting('test.delivery_actor')::uuid,'withdrawal_paid');
select is((select count(*)::integer from app_private.in_app_notifications
  where financial_event_id=current_setting('test.delivery_financial_event')::uuid
    and recipient_id=current_setting('test.delivery_actor')::uuid),1,
  'repeated source event cannot duplicate its in-app notice');
select is((select count(*)::integer from app_private.notification_email_deliveries
  where source_kind='financial' and source_event_id=current_setting('test.delivery_financial_event')::uuid
    and recipient_id=current_setting('test.delivery_actor')::uuid and channel='email'
    and notification_type='withdrawal_paid'),1,
  'delivery intent is deduplicated by recipient, source event, channel and type');
select is((select destination_kind from app_private.in_app_notifications
  where financial_event_id=current_setting('test.delivery_financial_event')::uuid),'wallet_item',
  'financial notice destination is the opaque wallet item identifier');

with e as (insert into app_private.financial_audit_events(actor_id,event_type,reference_id,event_data)
values(current_setting('test.delivery_actor')::uuid,'withdrawal_status_changed',
  '81900000-0000-4000-8000-000000000021',pg_catalog.jsonb_build_object('status','paid'))
returning event_id)
select set_config('test.delivery_chat_event',e.event_id::text,true) from e;
select app_private.add_financial_in_app_notification(
  current_setting('test.delivery_chat_event')::uuid,current_setting('test.delivery_actor')::uuid,'new_message');
select is((select count(*)::integer from app_private.notification_email_deliveries
  where source_event_id=current_setting('test.delivery_chat_event')::uuid),0,
  'chat notices do not create transactional email requests');

select set_config('test.delivery_id',(select d.delivery_id::text from app_private.notification_email_deliveries d
  where d.status='pending' order by d.available_at,d.created_at,d.delivery_id limit 1),true);
select set_config('test.delivery_claim',app_private.claim_notification_email_for_runner(
  '81900000-0000-4000-8000-000000000030',1)::text,true);
select is(current_setting('test.delivery_claim')::jsonb->>'delivery_id',current_setting('test.delivery_id'),
  'runner claims a durable delivery with a stable identity');
select is(current_setting('test.delivery_claim')::jsonb->>'previous_status','pending',
  'first delivery claim starts from pending');
update app_private.notification_email_deliveries
set lease_expires_at=pg_catalog.now()-interval '1 second'
where delivery_id=current_setting('test.delivery_id')::uuid;
select set_config('test.delivery_reclaim',app_private.claim_notification_email_for_runner(
  '81900000-0000-4000-8000-000000000031',1)::text,true);
select is(current_setting('test.delivery_reclaim')::jsonb->>'delivery_id',current_setting('test.delivery_id'),
  'expired lease is reclaimed under the original delivery identity');
select is(current_setting('test.delivery_reclaim')::jsonb->>'previous_status','unknown',
  'expired lease is treated as ambiguous and must be reconciled before sending');
select throws_ok(format($sql$select app_private.complete_notification_email_for_runner(%L::uuid,%L::uuid,'provider_accepted',null,null)$sql$,
  current_setting('test.delivery_id'),current_setting('test.delivery_claim')::jsonb->>'lease_token'),
  '55000','delivery_lease_lost','a stale worker cannot complete after lease reclaim');
select app_private.complete_notification_email_for_runner(
  current_setting('test.delivery_id')::uuid,
  (current_setting('test.delivery_reclaim')::jsonb->>'lease_token')::uuid,
  'provider_accepted',null,'81900000-0000-4000-8000-000000000032');
select is((select status from app_private.notification_email_deliveries
  where delivery_id=current_setting('test.delivery_id')::uuid),'provider_accepted',
  'capture acceptance is recorded only after the current lease completes');
select lives_ok(format($sql$select app_private.mark_my_notification_read_for_actor(%L::uuid,%L::uuid)$sql$,
  current_setting('test.delivery_actor'),(select notification_id::text from app_private.notification_email_deliveries
    where delivery_id=current_setting('test.delivery_id')::uuid)),
  'recipient read state can change independently of delivery state');
select is((select read_at is not null from app_private.in_app_notifications n
  join app_private.notification_email_deliveries d using(notification_id)
  where d.delivery_id=current_setting('test.delivery_id')::uuid),true,
  'email capture does not clear or control the in-app read state');

select set_config('test.retry_delivery_id',(select d.delivery_id::text
  from app_private.notification_email_deliveries d where d.status='pending'
  order by d.available_at,d.created_at,d.delivery_id limit 1),true);
select set_config('test.retry_claim',app_private.claim_notification_email_for_runner(
  '81900000-0000-4000-8000-000000000040',1)::text,true);
select app_private.complete_notification_email_for_runner(
  current_setting('test.retry_delivery_id')::uuid,
  (current_setting('test.retry_claim')::jsonb->>'lease_token')::uuid,
  'retry_wait','recipient_unavailable',null);
select is((select status from app_private.notification_email_deliveries
  where delivery_id=current_setting('test.retry_delivery_id')::uuid),'retry_wait',
  'a known pre-send failure enters bounded retry wait');
select ok((select available_at>pg_catalog.now() from app_private.notification_email_deliveries
  where delivery_id=current_setting('test.retry_delivery_id')::uuid),
  'retry wait applies a future backoff time');
update app_private.notification_email_deliveries
set available_at=pg_catalog.now(),attempt_count=4
where delivery_id=current_setting('test.retry_delivery_id')::uuid;
select set_config('test.retry_final_claim',app_private.claim_notification_email_for_runner(
  '81900000-0000-4000-8000-000000000041',1)::text,true);
select app_private.complete_notification_email_for_runner(
  current_setting('test.retry_delivery_id')::uuid,
  (current_setting('test.retry_final_claim')::jsonb->>'lease_token')::uuid,
  'retry_wait','recipient_unavailable',null);
select is((select status from app_private.notification_email_deliveries
  where delivery_id=current_setting('test.retry_delivery_id')::uuid),'exhausted',
  'fifth failed claim exhausts automatic retries');

with e as (insert into app_private.identity_audit_events(actor_id,subject_id,event_type,event_data)
values(current_setting('test.delivery_actor')::uuid,current_setting('test.delivery_actor')::uuid,
  'verification_reviewed',pg_catalog.jsonb_build_object('submission_id','81900000-0000-4000-8000-000000000002'))
returning event_id)
select set_config('test.unknown_identity_event',e.event_id::text,true) from e;
insert into app_private.identity_outbox(event_id,subject_id,event_type,payload)
values(current_setting('test.unknown_identity_event')::uuid,current_setting('test.delivery_actor')::uuid,
  'verification_result',pg_catalog.jsonb_build_object('submission_id','81900000-0000-4000-8000-000000000002',
    'status','approved','reason','Synthetic internal reason must not enter the notice.'));
select set_config('test.unknown_delivery_id',(select d.delivery_id::text
  from app_private.notification_email_deliveries d where d.source_event_id=current_setting('test.unknown_identity_event')::uuid),true);
select set_config('test.unknown_claim',app_private.claim_notification_email_for_runner(
  '81900000-0000-4000-8000-000000000042',1)::text,true);
select app_private.complete_notification_email_for_runner(
  current_setting('test.unknown_delivery_id')::uuid,
  (current_setting('test.unknown_claim')::jsonb->>'lease_token')::uuid,
  'unknown','ambiguous_result',null);
select is((select status from app_private.notification_email_deliveries
  where delivery_id=current_setting('test.unknown_delivery_id')::uuid),'unknown',
  'ambiguous external result remains visible for reconciliation');
select ok(not (app_private.list_my_notifications_for_actor(current_setting('test.delivery_actor')::uuid,null,null)
  ->'notifications'->0 ? 'reason'),
  'verification reason is not copied into the ordinary notice projection');

with e as (insert into app_private.identity_audit_events(actor_id,subject_id,event_type,event_data)
values(current_setting('test.delivery_actor')::uuid,current_setting('test.delivery_actor')::uuid,
  'verification_reviewed',pg_catalog.jsonb_build_object('submission_id','81900000-0000-4000-8000-000000000003'))
returning event_id)
select set_config('test.failure_identity_event',e.event_id::text,true) from e;
insert into app_private.identity_outbox(event_id,subject_id,event_type,payload)
values(current_setting('test.failure_identity_event')::uuid,current_setting('test.delivery_actor')::uuid,
  'verification_result',pg_catalog.jsonb_build_object('submission_id','81900000-0000-4000-8000-000000000003','status','rejected'));
select set_config('test.failure_delivery_id',(select d.delivery_id::text
  from app_private.notification_email_deliveries d where d.source_event_id=current_setting('test.failure_identity_event')::uuid),true);
select set_config('test.failure_claim',app_private.claim_notification_email_for_runner(
  '81900000-0000-4000-8000-000000000043',1)::text,true);
select app_private.complete_notification_email_for_runner(
  current_setting('test.failure_delivery_id')::uuid,
  (current_setting('test.failure_claim')::jsonb->>'lease_token')::uuid,
  'permanent_failure','capture_rejected',null);
select ok(exists(select 1 from app_private.notification_email_deliveries d
  join app_private.in_app_notifications n using(notification_id)
  where d.delivery_id=current_setting('test.failure_delivery_id')::uuid
    and d.status='permanent_failure' and n.notification_type='verification_not_approved'),
  'permanent email failure leaves the in-app notice intact');

select throws_ok(format($sql$select app_private.list_notification_delivery_attention_for_actor(%L::uuid,'aal1')$sql$,
  current_setting('test.delivery_actor')),'42501','staff_access_denied',
  'delivery operations deny AAL1');
select throws_ok(format($sql$select app_private.list_notification_delivery_attention_for_actor(%L::uuid,'aal2')$sql$,
  current_setting('test.delivery_actor')),'42501','staff_access_denied',
  'delivery operations deny AAL2 without the dedicated grant');
insert into app_private.staff_grants(user_id,capability,granted_by,reason)
values(current_setting('test.delivery_actor')::uuid,'notification_delivery_review',
  current_setting('test.delivery_actor')::uuid,'Synthetic delivery review grant for local tests.');
select lives_ok(format($sql$select app_private.list_notification_delivery_attention_for_actor(%L::uuid,'aal2')$sql$,
  current_setting('test.delivery_actor')),
  'AAL2 delivery reviewer can inspect safe delivery statuses');
select ok((app_private.list_notification_delivery_attention_for_actor(
  current_setting('test.delivery_actor')::uuid,'aal2')->'items') @> '[{"status":"unknown"}]'::jsonb
  and (app_private.list_notification_delivery_attention_for_actor(
  current_setting('test.delivery_actor')::uuid,'aal2')->'items') @> '[{"status":"exhausted"}]'::jsonb
  and (app_private.list_notification_delivery_attention_for_actor(
  current_setting('test.delivery_actor')::uuid,'aal2')->'items') @> '[{"status":"permanent_failure"}]'::jsonb,
  'operations view includes unknown, exhausted and permanent failure outcomes');

select * from finish();
rollback;
