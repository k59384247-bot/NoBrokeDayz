begin;
create extension if not exists pgtap with schema extensions;
select plan(47);
select set_config('test.profile_owner',(select id::text from auth.users where email='phase2-owner@identity.test'),true);
select set_config('test.profile_other',(select id::text from auth.users where email='phase2-other@identity.test'),true);
select set_config('test.profile_partner',(select id::text from auth.users where email='phase2-trackb@identity.test'),true);
select set_config('test.profile_viewer',(select id::text from auth.users where email='phase2-profileviewer@identity.test'),true);

select ok(to_regprocedure('public.server_update_profile_for_actor(uuid,jsonb)') is not null,'own profile edits have a narrow Edge-only database command');
select ok(to_regprocedure('public.server_get_safe_profile_for_viewer(uuid,uuid)') is not null,'safe profile projection has a narrow Edge-only database command');
select ok(not has_function_privilege('authenticated','public.server_update_profile_for_actor(uuid,jsonb)','EXECUTE'),'authenticated clients cannot call the profile write gateway');
select ok(not has_function_privilege('authenticated','public.server_get_safe_profile_for_viewer(uuid,uuid)','EXECUTE'),'authenticated clients cannot call the safe-profile gateway');
select ok(has_function_privilege('service_role','public.server_update_profile_for_actor(uuid,jsonb)','EXECUTE'),'Edge server has an explicit profile write gateway grant');
select ok(has_function_privilege('service_role','public.server_get_safe_profile_for_viewer(uuid,uuid)','EXECUTE'),'Edge server has an explicit safe-profile gateway grant');
select ok(has_function_privilege('postgres','app_private.update_profile_for_actor(uuid,jsonb)','EXECUTE'),'private profile writer is available to its controlled gateway owner');
select ok(not has_function_privilege('service_role','app_private.update_profile_for_actor(uuid,jsonb)','EXECUTE'),'service role has no direct private writer access');
select ok(not has_schema_privilege('authenticated','app_private','USAGE'),'private identity schema stays unavailable to clients');
select ok(not has_table_privilege('authenticated','public.profiles','UPDATE'),'generic client writes to profile rows are revoked');
select ok(not exists(select 1 from pg_policies where schemaname='public' and tablename='profiles' and policyname='profiles_update_own'),'generic owner update policy is removed');
select ok((select proconfig @> array['search_path=""'] from pg_proc where oid='app_private.current_profile_capabilities(uuid)'::regprocedure),'capability helper fixes an empty search path');
select ok((select proconfig @> array['search_path=""'] from pg_proc where oid='app_private.update_profile_for_actor(uuid,jsonb)'::regprocedure),'profile writer fixes an empty search path');
select ok((select proconfig @> array['search_path=""'] from pg_proc where oid='app_private.get_safe_profile_for_viewer(uuid,uuid)'::regprocedure),'profile projection fixes an empty search path');
select ok(not has_function_privilege('authenticated','app_private.current_profile_capabilities(uuid)','EXECUTE'),'clients cannot call the protected capability helper');
select ok(not has_table_privilege('authenticated','app_private.profile_campuses','SELECT'),'campus catalog is not directly readable by clients');
select ok(not has_table_privilege('service_role','app_private.profile_campuses','SELECT'),'server role cannot read campus catalog outside its command');
select ok(not exists(select 1 from information_schema.columns where table_schema='public' and table_name='profiles' and column_name in ('legal_name','phone','account_type','verified_badge','can_work','rating','completed_work_count')),'profile storage contains no private identity or system-owned fields');

set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.profile_owner'),true);
select set_config('request.jwt.claim.role','authenticated',true);
select lives_ok($$select public.register_my_identity('student',true,'age-18-v1')$$,'synthetic owner is registered through the supported identity command');
select is((public.get_my_identity_status()->>'verified')::boolean,false,'unverified account does not receive a verified badge');
select is((public.get_my_identity_status()->>'can_post')::boolean,false,'unverified student cannot post');
select is((public.get_my_identity_status()->>'can_work')::boolean,false,'unverified student cannot work');
select is((select count(*)::integer from public.profiles),1,'unverified owner retains access to their onboarding profile');
select throws_ok($$update public.profiles set display_name='Forged name' where user_id=auth.uid()$$,'42501','permission denied for table profiles','ordinary profile updates cannot bypass the profile command');
select throws_ok($$select public.server_update_profile_for_actor(auth.uid(),'{}'::jsonb)$$,'42501','permission denied for function server_update_profile_for_actor','browser cannot execute the server-only profile command');
select set_config('request.jwt.claim.sub',current_setting('test.profile_other'),true);
select is((select count(*)::integer from public.profiles),0,'unrelated user cannot read another onboarding profile');
reset role;

set local role service_role;
select throws_ok($$select public.server_update_profile_for_actor(current_setting('test.profile_owner')::uuid,'{"display_name":"Forged","can_work":true}'::jsonb)$$,'22023','invalid profile','protected fields are rejected by the database command');
select throws_ok(pg_catalog.format('select public.server_update_profile_for_actor(%L::uuid,%L::jsonb)',current_setting('test.profile_owner'),pg_catalog.jsonb_build_object('bio',pg_catalog.repeat('x',501))::text),'23514',null,'database limits reject an overlong profile field');
select is(public.server_update_profile_for_actor(current_setting('test.profile_owner')::uuid,'{"display_name":" Synthetic Student ","skills":["Research"]}'::jsonb)->>'display_name','Synthetic Student','profile command trims and returns the owner safe profile fields');
select throws_ok($$select public.server_update_profile_for_actor(current_setting('test.profile_owner')::uuid,'{"business_name":"Not a partner"}'::jsonb)$$,'22023','invalid profile','student cannot set partner attribution');
select throws_ok($$select public.server_update_profile_for_actor(current_setting('test.profile_owner')::uuid,'{"campus_id":"00000000-0000-0000-0000-000000000001"}'::jsonb)$$,'22023','invalid profile','profile cannot invent a campus outside the configured catalog');
reset role;
insert into app_private.profile_campuses(campus_id,display_label) values('00000000-0000-0000-0000-000000000001','Synthetic Test Campus');
set local role service_role;
select is(public.server_update_profile_for_actor(current_setting('test.profile_owner')::uuid,'{"campus_id":"00000000-0000-0000-0000-000000000001"}'::jsonb)->>'campus_label','Synthetic Test Campus','profile may select only a configured campus ID');
reset role;

insert into app_private.identity_accounts(user_id,account_type,age_confirmed_at,age_policy_version,verification_track,verification_status)
values(current_setting('test.profile_partner')::uuid,'partner',pg_catalog.now(),'age-18-v1','track_b_partner','approved');
insert into app_private.identity_accounts(user_id,account_type,age_confirmed_at,age_policy_version,verification_track,verification_status)
values(current_setting('test.profile_viewer')::uuid,'student',pg_catalog.now(),'age-18-v1','track_a_manual','approved');
insert into app_private.identity_phone_bindings(user_id,phone_e164,verified_at)
select u.id,'+'||u.phone,u.phone_confirmed_at from auth.users u where u.id=current_setting('test.profile_partner')::uuid;
insert into app_private.identity_phone_bindings(user_id,phone_e164,verified_at)
select u.id,'+'||u.phone,u.phone_confirmed_at from auth.users u where u.id=current_setting('test.profile_viewer')::uuid;
insert into app_private.identity_capabilities(user_id,capability,source)
values(current_setting('test.profile_partner')::uuid,'can_hire','track_b_partner');
insert into app_private.identity_capabilities(user_id,capability,source)
values(current_setting('test.profile_viewer')::uuid,'can_hire','track_a_manual'),(current_setting('test.profile_viewer')::uuid,'can_work','track_a_manual');
insert into public.profiles(user_id,display_name,business_name,business_location)
values(current_setting('test.profile_partner')::uuid,'Synthetic Shop Owner','Synthetic Campus Shop','Synthetic Campus');
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.profile_partner'),true);
select is((public.get_my_identity_status()->>'can_post')::boolean,true,'qualified Track B partner can post');
select is((public.get_my_identity_status()->>'can_work')::boolean,false,'Track B partner never gains student work capability');
select set_config('request.jwt.claim.sub',current_setting('test.profile_viewer'),true);
select is((public.get_my_identity_status()->>'can_post')::boolean,true,'approved Track A student can post');
select is((public.get_my_identity_status()->>'can_work')::boolean,true,'approved Track A student can work when current shared facts pass');
reset role;
set local role service_role;
select is(public.server_update_profile_for_actor(current_setting('test.profile_partner')::uuid,'{"campus_id":"00000000-0000-0000-0000-000000000001"}'::jsonb)->>'campus_label','Synthetic Test Campus','partner campus projection uses the configured label');
select is(public.server_get_safe_profile_for_viewer(current_setting('test.profile_partner')::uuid,current_setting('test.profile_partner')::uuid)->>'account_type','partner','qualified partner sees safe profile projection');
select is((public.server_get_safe_profile_for_viewer(current_setting('test.profile_partner')::uuid,current_setting('test.profile_partner')::uuid)->>'verified_badge')::boolean,true,'verified badge is derived from protected current facts');
select ok(not (public.server_get_safe_profile_for_viewer(current_setting('test.profile_partner')::uuid,current_setting('test.profile_partner')::uuid) ?| array['phone','school_email','legal_name','bank_account','evidence','capabilities','staff_grants']),'safe profile omits private identity and staff fields');
select is(public.server_get_safe_profile_for_viewer(current_setting('test.profile_partner')::uuid,current_setting('test.profile_partner')::uuid)->>'completed_work_count','0','completed work remains system-owned zero before workflow exists');
select is(public.server_get_safe_profile_for_viewer(current_setting('test.profile_partner')::uuid,current_setting('test.profile_partner')::uuid)->>'worker_rating',null,'ratings remain honestly unrated');
select is(public.server_get_safe_profile_for_viewer(current_setting('test.profile_partner')::uuid,current_setting('test.profile_partner')::uuid)->>'campus_label','Synthetic Test Campus','safe profile shows only configured campus labels');
select is(public.server_get_safe_profile_for_viewer(current_setting('test.profile_viewer')::uuid,current_setting('test.profile_partner')::uuid)->>'profile_id',current_setting('test.profile_partner'),'qualified viewer can view another qualified account through the safe projection');
select throws_ok($$select public.server_get_safe_profile_for_viewer(current_setting('test.profile_owner')::uuid,current_setting('test.profile_partner')::uuid)$$,'P0002','profile_not_found','unqualified viewers cannot use guessed IDs to view profiles');
reset role;
update app_private.identity_accounts set account_status='suspended' where user_id=current_setting('test.profile_owner')::uuid;
select throws_ok($$select public.server_update_profile_for_actor(current_setting('test.profile_owner')::uuid,'{"bio":"blocked after suspension"}'::jsonb)$$,'42501','profile unavailable','current suspension overrides stale access tokens on profile edits');
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.profile_partner'),true);
select is((select count(*)::integer from public.profiles where user_id=current_setting('test.profile_owner')::uuid),0,'authenticated row-level access hides another profile even for a qualified viewer');
reset role;
select * from finish();
rollback;
