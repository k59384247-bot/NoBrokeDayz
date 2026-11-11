begin;

alter table app_private.school_email_challenges
  add column idempotency_key uuid not null default pg_catalog.gen_random_uuid();
create unique index school_email_challenges_actor_request_key
  on app_private.school_email_challenges (user_id, idempotency_key);

create function app_private.begin_school_challenge_with_key(
  p_actor uuid,
  p_email text,
  p_code_digest text,
  p_request_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_email text := app_private.school_email_normalize(p_email);
  v_existing app_private.school_email_challenges%rowtype;
  v_result jsonb;
  v_challenge_id uuid;
begin
  if p_request_key is null or v_email is null then
    raise exception using errcode = '22023', message = 'invalid_request';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_actor::text || ':school-request:' || p_request_key::text, 916205));
  select * into v_existing
  from app_private.school_email_challenges
  where user_id = p_actor and idempotency_key = p_request_key
  for update;
  if found then
    if v_existing.normalized_email <> v_email then
      raise exception using errcode = '22023', message = 'invalid_request';
    end if;
    return pg_catalog.jsonb_build_object(
      'issued', false,
      'challenge_id', v_existing.challenge_id,
      'state', case
        when v_existing.consumed_at is not null then 'confirmed'
        when v_existing.invalidated_at is not null or v_existing.expires_at <= pg_catalog.now() then 'expired'
        else 'pending'
      end
    );
  end if;

  v_result := app_private.begin_school_challenge_for_actor(p_actor, v_email, p_code_digest);
  if v_result->>'issued' <> 'true' then return v_result; end if;
  v_challenge_id := (v_result->>'challenge_id')::uuid;
  update app_private.school_email_challenges
  set idempotency_key = p_request_key
  where challenge_id = v_challenge_id and user_id = p_actor;
  return v_result;
end;
$function$;
revoke all on function app_private.begin_school_challenge_with_key(uuid, text, text, uuid) from public, anon, authenticated, service_role;

drop function public.server_begin_school_challenge_for_actor(uuid, text, text);
create function public.server_begin_school_challenge_for_actor(
  p_actor uuid,
  p_email text,
  p_code_digest text,
  p_request_key uuid
)
returns jsonb
language sql
security definer
set search_path = ''
as $function$
  select app_private.begin_school_challenge_with_key(p_actor, p_email, p_code_digest, p_request_key)
$function$;
revoke all on function public.server_begin_school_challenge_for_actor(uuid, text, text, uuid) from public, anon, authenticated, service_role;
grant execute on function public.server_begin_school_challenge_for_actor(uuid, text, text, uuid) to service_role;

commit;
