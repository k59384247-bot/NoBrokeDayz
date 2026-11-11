import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { chmodSync, readFileSync, writeFileSync } from "node:fs";
import { setTimeout as delay } from "node:timers/promises";
import { test } from "node:test";
import { resolve } from "node:path";
import { createClient } from "@supabase/supabase-js";
import { createIdentityStaffHandler } from "../../../supabase/functions/_shared/identity-staff.mjs";
import { createVerificationReviewHandler } from "../../../supabase/functions/_shared/verification-review.mjs";

const root = resolve(import.meta.dirname, "../../..");
const credentialFile = resolve(root, ".supabase-home/step8-staff.json");
const creds = JSON.parse(readFileSync(credentialFile, "utf8"));
const status = JSON.parse(process.env.NBD_LOCAL_AUTH_STATUS_JSON ?? "null");
assert.equal(status?.runtime, "native", "test requires local native Supabase");
const apiUrl = new URL(status.env.API_URL).origin;
assert.ok(["127.0.0.1", "localhost"].includes(new URL(apiUrl).hostname));
const mailpitUrl = new URL(status.env.MAILPIT_URL);
assert.ok(["127.0.0.1", "localhost"].includes(mailpitUrl.hostname));
const anonKey = status.env.ANON_KEY;
const serviceKey = status.env.SERVICE_ROLE_KEY;
const staff = creds.users.reviewer;
const subject = creds.users.applicant;
const unrelated = creds.users.unrelated;
const localClient = () =>
  createClient(apiUrl, anonKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

function base32Decode(value) {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let bits = "";
  for (const character of value.toUpperCase().replace(/=+$/, "")) {
    const number = alphabet.indexOf(character);
    if (number < 0) throw new Error("invalid local TOTP secret");
    bits += number.toString(2).padStart(5, "0");
  }
  const bytes = [];
  for (let offset = 0; offset + 8 <= bits.length; offset += 8)
    bytes.push(Number.parseInt(bits.slice(offset, offset + 8), 2));
  return Buffer.from(bytes);
}

function totp(secret, now = Date.now()) {
  const counter = Math.floor(now / 30_000);
  const message = Buffer.alloc(8);
  message.writeBigUInt64BE(BigInt(counter));
  const digest = createHmac("sha1", base32Decode(secret))
    .update(message)
    .digest();
  const offset = digest[digest.length - 1] & 15;
  const value = (digest.readUInt32BE(offset) & 0x7fffffff) % 1_000_000;
  return String(value).padStart(6, "0");
}

async function run(command, args, label) {
  const response = await fetch(`${apiUrl}/rest/v1/rpc/${command}`, {
    method: "POST",
    headers: {
      apikey: serviceKey,
      authorization: `Bearer ${serviceKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(args),
  });
  const body = await response.json().catch(() => null);
  if (!response.ok) {
    const error = new Error(label);
    error.code = body?.message;
    throw error;
  }
  return body;
}

async function authVerify(token) {
  const response = await fetch(`${apiUrl}/auth/v1/user`, {
    headers: { apikey: anonKey, authorization: `Bearer ${token}` },
  });
  return response.ok ? response.json() : null;
}

function command() {
  return async (name, args) => run(name, args, "local staff RPC failed");
}

async function signInAtAal2(role) {
  const user = creds.users[role];
  const client = localClient();
  const { data: signedIn, error: signInError } =
    await client.auth.signInWithPassword({
      email: user.email,
      password: user.password,
    });
  assert.ifError(signInError);
  assert.ok(signedIn.session);
  const { data: level1 } =
    await client.auth.mfa.getAuthenticatorAssuranceLevel();
  assert.equal(level1.currentLevel, "aal1", "password alone is only AAL1");
  const { data: listed, error: listError } =
    await client.auth.mfa.listFactors();
  assert.ifError(listError);
  let factor = listed.totp.find((item) => item.status === "verified");
  let seed = user.totp_secret;
  const extraFactorIds = listed.totp
    .filter((item) => item.id !== factor?.id)
    .map((item) => item.id);
  let orphanedFactorId = null;
  if (factor && !seed) {
    // A factor created by an interrupted earlier run may exist while its seed
    // was not saved. Add and verify a replacement factor, then remove the old
    // one after the session reaches AAL2; never guess or extract Auth's seed.
    orphanedFactorId = factor.id;
    factor = null;
  }
  if (!factor) {
    const { data, error } = await client.auth.mfa.enroll({
      factorType: "totp",
      friendlyName: `synthetic-step8-${role}-${crypto.randomUUID()}`,
    });
    assert.ifError(error);
    assert.ok(data.totp.secret);
    factor = { id: data.id };
    seed = data.totp.secret;
    user.totp_secret = seed;
    writeFileSync(credentialFile, `${JSON.stringify(creds, null, 2)}\n`, {
      mode: 0o600,
    });
    chmodSync(credentialFile, 0o600);
  }
  assert.ok(seed, "local TOTP seed remains only in ignored test tooling");
  const verified = await client.auth.mfa.challengeAndVerify({
    factorId: factor.id,
    code: totp(seed),
  });
  assert.ifError(verified.error);
  const staleFactors = new Set(extraFactorIds);
  if (orphanedFactorId) staleFactors.add(orphanedFactorId);
  for (const factorId of staleFactors) {
    const { error } = await client.auth.mfa.unenroll({ factorId });
    assert.ifError(error);
  }
  const { data: assurance, error: assuranceError } =
    await client.auth.mfa.getAuthenticatorAssuranceLevel();
  assert.ifError(assuranceError);
  assert.equal(assurance.currentLevel, "aal2");
  const { data: sessionData } = await client.auth.getSession();
  return { client, token: sessionData.session.access_token, assurance };
}

function request(handler, token, body) {
  return handler(
    new Request(`${apiUrl}/functions/v1/local-test`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify(body),
    }),
  );
}

async function findNewRecoveryLink(email, previousIds) {
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    const listingResponse = await fetch(
      new URL("/api/v1/messages?start=0&limit=100", mailpitUrl),
    );
    assert.equal(listingResponse.status, 200);
    const listing = await listingResponse.json();
    for (const summary of listing.messages ?? listing.Messages ?? []) {
      const id = summary.ID ?? summary.Id ?? summary.id;
      if (!id || previousIds.has(id)) continue;
      const detailResponse = await fetch(
        new URL(`/api/v1/message/${encodeURIComponent(id)}`, mailpitUrl),
      );
      if (!detailResponse.ok) continue;
      const detail = await detailResponse.json();
      if (!JSON.stringify(detail).toLowerCase().includes(email.toLowerCase()))
        continue;
      const body = [detail.Text, detail.HTML, detail.Message, detail.Snippet]
        .filter((value) => typeof value === "string")
        .join("\n")
        .replaceAll("&amp;", "&")
        .replaceAll("&#x3D;", "=");
      const links = body.match(/https?:\/\/[^\s"'<>]+/g) ?? [];
      for (const raw of links) {
        try {
          const link = new URL(raw.replace(/[),.;]+$/, ""));
          if (link.searchParams.get("type") === "recovery") return link;
        } catch {}
      }
    }
    await delay(250);
  }
  assert.fail("local Mailpit did not capture the synthetic recovery message");
}

test("real local TOTP AAL2 gates current grants, review scope and suspension immediately", async (t) => {
  assert.equal(creds.fixture_scope, "no-broke-dayz-phase2-step8-local-fixture");
  const {
    client: staffClient,
    token: staffToken,
    assurance,
  } = await signInAtAal2("reviewer");
  assert.ok(await authVerify(staffToken), "Auth accepts the issued AAL2 token");

  const staffHandler = createIdentityStaffHandler({
    verifyActor: authVerify,
    command: command(),
  });
  const reviewHandler = createVerificationReviewHandler({
    verifyActor: authVerify,
    command: command(),
  });
  assert.equal(
    (
      await request(staffHandler, staffToken, {
        action: "unsuspend",
        subject_id: subject.id,
        reason:
          "Synthetic setup recovery for any interrupted local staff test.",
        idempotency_key: crypto.randomUUID(),
      })
    ).status,
    200,
    "test repairs an interrupted prior suspension through the audited command",
  );
  const aal1Client = localClient();
  const { data: aal1SignIn, error: aal1Error } =
    await aal1Client.auth.signInWithPassword({
      email: staff.email,
      password: staff.password,
    });
  assert.ifError(aal1Error);
  const aal1Token = aal1SignIn.session.access_token;
  assert.equal(
    (await request(reviewHandler, aal1Token, { action: "candidates" })).status,
    403,
  );
  assert.equal(
    (
      await request(staffHandler, aal1Token, {
        action: "suspend",
        subject_id: subject.id,
        reason: "Synthetic AAL1 denial test reason for local staff.",
        idempotency_key: crypto.randomUUID(),
      })
    ).status,
    403,
  );

  const { token: noGrantAal2 } = await signInAtAal2("unrelated");
  assert.equal(
    (await request(reviewHandler, noGrantAal2, { action: "candidates" }))
      .status,
    403,
    "verified AAL2 without the review grant is denied",
  );
  assert.equal(
    (
      await request(staffHandler, noGrantAal2, {
        action: "suspend",
        subject_id: subject.id,
        reason:
          "Synthetic wrong-grant denial test for the local staff command.",
        idempotency_key: crypto.randomUUID(),
      })
    ).status,
    403,
    "verified AAL2 without the suspension grant is denied",
  );

  // Untrusted Auth metadata deliberately claims staff privileges; no command reads it.
  const subjectClient = localClient();
  const { data: subjectSignIn, error: subjectSignInError } =
    await subjectClient.auth.signInWithPassword({
      email: subject.email,
      password: subject.password,
    });
  assert.ifError(subjectSignInError);
  const subjectToken = subjectSignIn.session.access_token;
  const status = await fetch(`${apiUrl}/rest/v1/rpc/get_my_identity_status`, {
    method: "POST",
    headers: {
      apikey: anonKey,
      authorization: `Bearer ${subjectToken}`,
      "content-type": "application/json",
    },
    body: "{}",
  });
  assert.equal(status.status, 200);
  const initialProfile = await fetch(
    `${apiUrl}/rest/v1/profiles?user_id=eq.${subject.id}&select=user_id,display_name`,
    {
      headers: { apikey: anonKey, authorization: `Bearer ${subjectToken}` },
    },
  );
  assert.equal(initialProfile.status, 200);
  assert.equal((await initialProfile.json()).length, 1);

  const historyResponse = await fetch(
    `${apiUrl}/rest/v1/rpc/get_my_verification_history`,
    {
      method: "POST",
      headers: {
        apikey: anonKey,
        authorization: `Bearer ${subjectToken}`,
        "content-type": "application/json",
      },
      body: "{}",
    },
  );
  assert.equal(historyResponse.status, 200);
  const pendingHistory = (await historyResponse.json()).filter(
    (item) => item.status === "pending",
  );
  if (pendingHistory.length) {
    let currentQueue = await request(reviewHandler, staffToken, {
      action: "queue",
    });
    assert.equal(currentQueue.status, 200);
    let rows = (await currentQueue.json()).result;
    const assignedIds = new Set(rows.map((item) => item.submission_id));
    const existingCandidates = await request(reviewHandler, staffToken, {
      action: "candidates",
    });
    assert.equal(existingCandidates.status, 200);
    const candidateIds = new Set(
      (await existingCandidates.json()).result.map(
        (item) => item.submission_id,
      ),
    );
    for (const item of pendingHistory) {
      if (assignedIds.has(item.submission_id)) continue;
      if (!candidateIds.has(item.submission_id)) continue;
      const assigned = await request(reviewHandler, staffToken, {
        action: "assign",
        submission_id: item.submission_id,
        target_reviewer_id: staff.id,
        reason: "Synthetic cleanup of a prior interrupted local test request.",
      });
      assert.equal(assigned.status, 200);
    }
    currentQueue = await request(reviewHandler, staffToken, {
      action: "queue",
    });
    assert.equal(currentQueue.status, 200);
    rows = (await currentQueue.json()).result;
    for (const item of pendingHistory) {
      const queued = rows.find(
        (row) => row.submission_id === item.submission_id,
      );
      if (!queued) continue;
      const closed = await request(reviewHandler, staffToken, {
        action: "review",
        submission_id: item.submission_id,
        idempotency_key: crypto.randomUUID(),
        expected_version: item.version,
        expected_status: "pending",
        expected_decision_version: item.reviews.length,
        decision: "needs_information",
        reason:
          "Synthetic cleanup decision for an interrupted local test request.",
      });
      assert.equal(closed.status, 200);
    }
  }

  const submit = await fetch(`${apiUrl}/rest/v1/rpc/submit_my_verification`, {
    method: "POST",
    headers: {
      apikey: anonKey,
      authorization: `Bearer ${subjectToken}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      p_idempotency_key: crypto.randomUUID(),
      p_legal_name: null,
      p_narrative:
        "Synthetic student fallback submission for scoped staff review tests.",
      p_connection_type: null,
    }),
  });
  assert.equal(
    submit.status,
    200,
    "synthetic applicant can create a pending review item",
  );
  const submission = await submit.json();
  const candidates = await request(reviewHandler, staffToken, {
    action: "candidates",
  });
  assert.equal(candidates.status, 200);
  const candidateRows = (await candidates.json()).result;
  assert.ok(
    candidateRows.some((row) => row.submission_id === submission.submission_id),
  );
  const assignment = await request(reviewHandler, staffToken, {
    action: "assign",
    submission_id: submission.submission_id,
    target_reviewer_id: staff.id,
    reason: "Synthetic local assignment for reviewer scope validation.",
  });
  assert.equal(assignment.status, 200);
  const queue = await request(reviewHandler, staffToken, { action: "queue" });
  assert.equal(queue.status, 200);
  const queueRows = (await queue.json()).result;
  assert.ok(
    queueRows.some((row) => row.submission_id === submission.submission_id),
  );
  assert.ok(!queueRows.some((row) => row.user_id === unrelated.id));
  const decision = await request(reviewHandler, staffToken, {
    action: "review",
    submission_id: submission.submission_id,
    idempotency_key: crypto.randomUUID(),
    expected_version: submission.version,
    expected_status: "pending",
    expected_decision_version: 0,
    decision: "needs_information",
    reason: "Synthetic review requests a clearer sample evidence file.",
  });
  assert.equal(decision.status, 200);

  const suspensionKey = crypto.randomUUID();
  const suspended = await request(staffHandler, staffToken, {
    action: "suspend",
    subject_id: subject.id,
    reason: "Synthetic reason to validate immediate local suspension.",
    idempotency_key: suspensionKey,
  });
  assert.equal(suspended.status, 200);
  assert.equal(
    (await authVerify(subjectToken)).id,
    subject.id,
    "old subject token remains a valid Auth token",
  );
  const suspendedProfile = await fetch(
    `${apiUrl}/rest/v1/profiles?user_id=eq.${subject.id}&select=user_id`,
    {
      headers: { apikey: anonKey, authorization: `Bearer ${subjectToken}` },
    },
  );
  assert.equal(suspendedProfile.status, 200);
  assert.deepEqual(
    await suspendedProfile.json(),
    [],
    "old token loses profile access immediately",
  );
  const help = await fetch(
    `${apiUrl}/rest/v1/rpc/get_my_identity_help_context`,
    {
      method: "POST",
      headers: {
        apikey: anonKey,
        authorization: `Bearer ${subjectToken}`,
        "content-type": "application/json",
      },
      body: "{}",
    },
  );
  assert.equal(help.status, 200);
  assert.equal(
    (await help.json()).suspended,
    true,
    "suspended owner retains own help status",
  );
  const blockedEdit = await fetch(
    `${apiUrl}/rest/v1/profiles?user_id=eq.${subject.id}`,
    {
      method: "PATCH",
      headers: {
        apikey: anonKey,
        authorization: `Bearer ${subjectToken}`,
        "content-type": "application/json",
        prefer: "return=representation",
      },
      body: JSON.stringify({ display_name: "Changed during suspension" }),
    },
  );
  assert.equal(
    blockedEdit.status,
    403,
    "old token cannot bypass the controlled profile command after suspension",
  );

  const previousMail = await fetch(
    new URL("/api/v1/messages?start=0&limit=100", mailpitUrl),
  );
  assert.equal(previousMail.status, 200);
  const previousMessages = await previousMail.json();
  const previousIds = new Set(
    (previousMessages.messages ?? previousMessages.Messages ?? []).map(
      (item) => item.ID ?? item.Id ?? item.id,
    ),
  );
  const recoveryRequest = await subjectClient.auth.resetPasswordForEmail(
    subject.email,
    { redirectTo: "http://127.0.0.1:3000/auth/recovery" },
  );
  assert.ifError(recoveryRequest.error);
  const recoveryLink = await findNewRecoveryLink(subject.email, previousIds);
  assert.equal(
    recoveryLink.searchParams.get("redirect_to"),
    "http://127.0.0.1:3000/auth/recovery",
  );
  const recoveryResponse = await fetch(recoveryLink, { redirect: "manual" });
  assert.ok([301, 302, 303, 307, 308].includes(recoveryResponse.status));
  const recoveryLocation = recoveryResponse.headers.get("location");
  assert.ok(recoveryLocation);
  const recoveryCallback = new URL(recoveryLocation);
  assert.equal(
    `${recoveryCallback.origin}${recoveryCallback.pathname}`,
    "http://127.0.0.1:3000/auth/recovery",
  );
  const recoveryTokens = new URLSearchParams(recoveryCallback.hash.slice(1));
  const recoveryAccess = recoveryTokens.get("access_token");
  const recoveryRefresh = recoveryTokens.get("refresh_token");
  assert.ok(recoveryAccess && recoveryRefresh);
  const recoverySession = await subjectClient.auth.setSession({
    access_token: recoveryAccess,
    refresh_token: recoveryRefresh,
  });
  assert.ifError(recoverySession.error);
  const newPassword = `local-recovery-${crypto.randomUUID()}-A9!`;
  const passwordChange = await subjectClient.auth.updateUser({
    password: newPassword,
  });
  assert.ifError(passwordChange.error);
  subject.password = newPassword;
  writeFileSync(credentialFile, `${JSON.stringify(creds, null, 2)}\n`, {
    mode: 0o600,
  });
  chmodSync(credentialFile, 0o600);
  const afterRecovery = await fetch(
    `${apiUrl}/rest/v1/rpc/get_my_identity_status`,
    {
      method: "POST",
      headers: {
        apikey: anonKey,
        authorization: `Bearer ${recoveryAccess}`,
        "content-type": "application/json",
      },
      body: "{}",
    },
  );
  assert.equal(afterRecovery.status, 200);
  assert.equal(
    (await afterRecovery.json()).account_status,
    "suspended",
    "password recovery cannot unsuspend or grant app access",
  );
  const recoveredProfile = await fetch(
    `${apiUrl}/rest/v1/profiles?user_id=eq.${subject.id}&select=user_id`,
    {
      headers: { apikey: anonKey, authorization: `Bearer ${recoveryAccess}` },
    },
  );
  assert.deepEqual(await recoveredProfile.json(), []);

  const unsuspended = await request(staffHandler, staffToken, {
    action: "unsuspend",
    subject_id: subject.id,
    reason: "Synthetic reason to validate audited local unsuspension.",
    idempotency_key: crypto.randomUUID(),
  });
  assert.equal(unsuspended.status, 200);
  const restoredProfile = await fetch(
    `${apiUrl}/rest/v1/profiles?user_id=eq.${subject.id}&select=user_id`,
    {
      headers: { apikey: anonKey, authorization: `Bearer ${subjectToken}` },
    },
  );
  assert.equal(
    (await restoredProfile.json()).length,
    1,
    "same token regains access after unsuspension",
  );

  // Revoke the reviewer capability through local postgres; the same unexpired AAL2 token must fail.
  const { spawnSync } = await import("node:child_process");
  const cli = resolve(root, "node_modules/.bin/supabase");
  const revokeSql = `update app_private.staff_grants set revoked_at=pg_catalog.now(),revoked_by='${creds.users.operator.id}' where user_id='${staff.id}' and capability='verification_review' and revoked_at is null;`;
  const env = (
    await import("../../../scripts/local-supabase-env.mjs")
  ).localSupabaseEnv();
  const revoked = spawnSync(cli, ["db", "query", "--local", revokeSql], {
    cwd: root,
    env,
    encoding: "utf8",
  });
  assert.equal(
    revoked.status,
    0,
    "local bootstrap operator can revoke a synthetic grant",
  );
  assert.equal(
    (await request(reviewHandler, staffToken, { action: "candidates" })).status,
    403,
    "grant revocation denies the still-valid AAL2 token immediately",
  );

  // Wait for natural expiry of this real Auth token; no fabricated JWT claims are used.
  const expiresAt =
    assurance.currentLevel === "aal2"
      ? (await staffClient.auth.getSession()).data.session.expires_at
      : 0;
  const waitMs = Math.max(0, expiresAt * 1000 - Date.now() + 1500);
  if (waitMs > 0) await delay(waitMs);
  assert.equal(
    (
      await request(staffHandler, staffToken, {
        action: "unsuspend",
        subject_id: subject.id,
        reason: "Synthetic expired token check after local TOTP access.",
        idempotency_key: crypto.randomUUID(),
      })
    ).status,
    401,
    "Auth rejects the naturally expired access token",
  );
  assert.equal((await request(staffHandler, "not-a-token", {})).status, 401);
  t.diagnostic(
    "local Auth issued AAL2 via TOTP and rejected the same token after its configured 60-second expiry",
  );
});
