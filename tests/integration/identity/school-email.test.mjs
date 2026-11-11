import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";
import { resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { test } from "node:test";
import { createSchoolEmailHandler } from "../../../supabase/functions/_shared/school-email.mjs";
import { startLocalSchoolEmailCapture } from "../../../scripts/test-support/local-school-email-capture.mjs";
import { localSupabaseEnv } from "../../../scripts/local-supabase-env.mjs";

const status = JSON.parse(process.env.NBD_LOCAL_AUTH_STATUS_JSON ?? "null");
const env = localSupabaseEnv();
const root = resolve(import.meta.dirname, "../../..");
const baseUrl = status?.env?.API_URL;
const anonKey = status?.env?.ANON_KEY;
const serviceKey = status?.env?.SERVICE_ROLE_KEY;
if (status?.runtime !== "native" || !baseUrl || !anonKey || !serviceKey)
  throw new Error(
    "school verification integration requires the local native stack",
  );

const functionFetch = async (path, options = {}, key = anonKey, bearer = key) =>
  fetch(`${baseUrl}${path}`, {
    ...options,
    headers: {
      apikey: key,
      authorization: `Bearer ${bearer}`,
      "content-type": "application/json",
      ...options.headers,
    },
  });

async function safeJson(response) {
  return response.json().catch(() => null);
}

function dbQuery(sql) {
  const cli = resolve(root, "node_modules/.bin/supabase");
  const result = spawnSync(
    cli,
    ["db", "query", "--local", "--output-format", "json", sql],
    {
      cwd: root,
      env,
      encoding: "utf8",
      maxBuffer: 2 * 1024 * 1024,
    },
  );
  if (result.error || result.status !== 0)
    throw new Error("local school test fixture command failed");
  return result.stdout;
}

test("local school email challenge binds ownership and qualifies only current eligible students", async (t) => {
  const capture = await startLocalSchoolEmailCapture({
    token: env.NBD_SCHOOL_EMAIL_ADAPTER_KEY,
  });
  t.after(() => capture.close());

  const accounts = new Map();
  const createdIds = [];
  const handler = createSchoolEmailHandler({
    hmacKey: env.NBD_SCHOOL_CHALLENGE_HMAC_KEY,
    verifyActor: async (token) => {
      const response = await functionFetch("/auth/v1/user", {}, anonKey, token);
      return response.ok ? (await safeJson(response))?.id : null;
    },
    command: async (name, args) => {
      const response = await functionFetch(
        `/rest/v1/rpc/${name}`,
        {
          method: "POST",
          body: JSON.stringify(args),
        },
        serviceKey,
      );
      const result = await safeJson(response);
      if (!response.ok) {
        const error = new Error("local identity command failed");
        error.code = result?.message;
        throw error;
      }
      return result;
    },
    deliver: async (to, code, context) => {
      const response = await fetch(capture.url, {
        method: "POST",
        headers: {
          authorization: `Bearer ${capture.token}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          to,
          template: "institutional-email-ownership",
          variables: { code, expires_minutes: 10 },
          metadata: { challenge_id: context.challengeId },
        }),
      });
      if (!response.ok) throw new Error("local delivery failed");
    },
  });

  async function createStudent({ phone = false, suspended = false } = {}) {
    const suffix = randomUUID();
    const email = `p2step5-${suffix}@identity.test`;
    const password = randomBytes(32).toString("base64url");
    const syntheticPhone = `+2347${Array.from(randomBytes(9), (value) => value % 10).join("")}`;
    const user = await functionFetch(
      "/auth/v1/admin/users",
      {
        method: "POST",
        body: JSON.stringify({
          email,
          password,
          email_confirm: true,
          ...(phone ? { phone: syntheticPhone, phone_confirm: true } : {}),
          app_metadata: { local_fixture_scope: "no-broke-dayz-phase2-step5" },
        }),
      },
      serviceKey,
    );
    const authUser = await safeJson(user);
    assert.ok(
      user.ok && authUser?.id,
      "local Auth creates a synthetic student fixture",
    );
    createdIds.push(authUser.id);
    const signin = await functionFetch("/auth/v1/token?grant_type=password", {
      method: "POST",
      body: JSON.stringify({ email, password }),
    });
    const session = await safeJson(signin);
    assert.ok(
      signin.ok && session?.access_token,
      "synthetic student can sign in to the existing account",
    );
    const register = await functionFetch(
      "/rest/v1/rpc/register_my_identity",
      {
        method: "POST",
        body: JSON.stringify({
          p_account_type: "student",
          p_age_confirmed: true,
          p_age_policy_version: "age-18-v1",
        }),
      },
      anonKey,
      session.access_token,
    );
    assert.ok(
      register.ok,
      "student onboarding stores protected type and age affirmation",
    );
    if (phone) {
      dbQuery(
        `insert into app_private.identity_phone_bindings (user_id, phone_e164, verified_at) select id, '+' || phone, phone_confirmed_at from auth.users where id = '${authUser.id}' and phone_confirmed_at is not null on conflict (user_id) do update set phone_e164 = excluded.phone_e164, verified_at = excluded.verified_at`,
      );
    }
    if (suspended)
      dbQuery(
        `update app_private.identity_accounts set account_status = 'suspended' where user_id = '${authUser.id}'`,
      );
    const account = { email, id: authUser.id, token: session.access_token };
    accounts.set(authUser.id, account);
    return account;
  }

  async function begin(account, email) {
    const response = await handler(
      new Request("http://local.test", {
        method: "POST",
        headers: { authorization: `Bearer ${account.token}` },
        body: JSON.stringify({
          action: "begin",
          email,
          idempotency_key: randomUUID(),
        }),
      }),
    );
    const result = await safeJson(response);
    assert.equal(
      response.status,
      200,
      "begin returns a non-enumerating result",
    );
    assert.equal(
      JSON.stringify(result).includes("code"),
      false,
      "begin response has no challenge code",
    );
    if (!result.challenge_id) return { result };
    const message = await capture.take(email.trim().toLowerCase());
    assert.ok(
      /^\d{6}$/.test(message.code),
      "test capture holds the generated one-time code",
    );
    assert.equal(
      message.challengeId,
      result.challenge_id,
      "captured email belongs to returned challenge reference",
    );
    return { challengeId: result.challenge_id, code: message.code, result };
  }

  async function confirm(account, challenge, code = challenge.code) {
    return handler(
      new Request("http://local.test", {
        method: "POST",
        headers: { authorization: `Bearer ${account.token}` },
        body: JSON.stringify({
          action: "confirm",
          challenge_id: challenge.challengeId,
          code,
        }),
      }),
    );
  }

  async function identityStatus(account) {
    const response = await functionFetch(
      "/rest/v1/rpc/get_my_identity_status",
      { method: "POST" },
      anonKey,
      account.token,
    );
    assert.ok(response.ok, "own identity status command succeeds");
    return safeJson(response);
  }

  const [owner, replay, racedA, racedB, qualified, suspended] =
    await Promise.all([
      createStudent(),
      createStudent(),
      createStudent(),
      createStudent(),
      createStudent({ phone: true }),
      createStudent({ phone: true, suspended: true }),
    ]);

  const suffixAttack = await begin(owner, "student@school.test.attacker.test");
  assert.equal(
    suffixAttack.result.state,
    "unavailable",
    "attacker suffix is not accepted as an allow-listed domain",
  );
  const ownerChallenge = await begin(owner, "Student@School.Test");
  const wrongActor = await confirm(replay, ownerChallenge);
  assert.equal(
    wrongActor.status,
    400,
    "challenge cannot be replayed by another account",
  );
  const ownerResult = await confirm(owner, ownerChallenge);
  assert.equal(
    (await safeJson(ownerResult))?.confirmed,
    true,
    "valid email challenge binds supplementary address",
  );
  const authContact = await functionFetch(
    "/auth/v1/user",
    {},
    anonKey,
    owner.token,
  );
  assert.equal(
    (await safeJson(authContact))?.email,
    owner.email,
    "school email never replaces Supabase login email",
  );
  assert.equal(
    (await identityStatus(owner))?.capabilities?.length,
    0,
    "pending phone keeps the student restricted",
  );

  const conflict = await begin(replay, "student@school.test");
  const conflictResponse = await confirm(replay, conflict);
  const conflictBody = await safeJson(conflictResponse);
  assert.equal(
    conflictBody?.confirmed,
    false,
    "unique address conflict is non-enumerating",
  );
  assert.equal(
    JSON.stringify(conflictBody).includes(owner.id),
    false,
    "ownership conflict does not disclose the owner ID",
  );

  const race = await begin(racedA, "race@school.test");
  const confirmations = await Promise.all([
    confirm(racedA, race),
    confirm(racedA, race),
  ]);
  const raceResults = await Promise.all(
    confirmations.map(async (response) => ({
      status: response.status,
      body: await safeJson(response),
    })),
  );
  assert.equal(
    raceResults.filter(
      (result) => result.status === 200 && result.body?.confirmed === true,
    ).length,
    1,
    "parallel consumption commits one confirmation effect",
  );
  assert.equal(
    raceResults.filter((result) => result.status === 400).length,
    1,
    "parallel replay is rejected after the winner consumes the challenge",
  );

  const addressRaceA = await begin(racedB, "shared@school.test");
  const addressRaceB = await begin(replay, "shared@school.test");
  const addressRaceResults = await Promise.all([
    confirm(racedB, addressRaceA),
    confirm(replay, addressRaceB),
  ]);
  const addressRaceBodies = await Promise.all(addressRaceResults.map(safeJson));
  assert.equal(
    addressRaceBodies.filter((result) => result?.confirmed === true).length,
    1,
    "parallel address claims have one winning owner",
  );
  assert.equal(
    addressRaceBodies.filter((result) => result?.confirmed === false).length,
    1,
    "losing address claim receives no ownership details",
  );

  const qualifiedChallenge = await begin(qualified, "eligible@school.test");
  const qualification = await safeJson(
    await confirm(qualified, qualifiedChallenge),
  );
  assert.equal(
    qualification?.qualified,
    true,
    "student qualifies when school, current phone, confirmed login, and age facts all pass",
  );
  assert.deepEqual(
    (await identityStatus(qualified)).capabilities,
    ["can_hire", "can_work"],
    "Track A grants hire and work capabilities",
  );
  const replacement = await begin(
    qualified,
    "eligible-replacement@school.test",
  );
  const replacementResult = await safeJson(
    await confirm(qualified, replacement),
  );
  assert.equal(
    replacementResult?.qualified,
    true,
    "verified school-address replacement re-derives Track A qualification",
  );
  assert.deepEqual(
    (await identityStatus(qualified)).capabilities,
    ["can_hire", "can_work"],
    "replacement keeps only the freshly qualified Track A capability set",
  );

  const suspendedChallenge = await begin(suspended, "suspended@school.test");
  const suspendedResult = await safeJson(
    await confirm(suspended, suspendedChallenge),
  );
  assert.equal(
    suspendedResult?.qualified,
    false,
    "school verification cannot override suspension",
  );
  const suspendedStatus = await identityStatus(suspended);
  assert.equal(
    suspendedStatus.account_status,
    "suspended",
    "verification never unsuspends the account",
  );
  assert.deepEqual(
    suspendedStatus.capabilities,
    [],
    "suspended account retains no effective marketplace capability",
  );

  assert.equal(
    createdIds.length,
    accounts.size,
    "all synthetic Auth fixtures are marked for the local runner cleanup",
  );
});
