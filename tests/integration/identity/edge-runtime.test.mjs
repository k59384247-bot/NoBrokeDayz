import assert from "node:assert/strict";
import { createHmac, randomUUID } from "node:crypto";
import { chmodSync, readFileSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { test } from "node:test";
import { createClient } from "@supabase/supabase-js";
import { localSupabaseEnv } from "../../../scripts/local-supabase-env.mjs";

const root = resolve(import.meta.dirname, "../../..");
const credentialFile = resolve(root, ".supabase-home/step8-staff.json");
const credentials = JSON.parse(readFileSync(credentialFile, "utf8"));
const status = JSON.parse(process.env.NBD_LOCAL_AUTH_STATUS_JSON ?? "null");
assert.equal(status?.runtime, "native");
const apiUrl = new URL(status.env.API_URL).origin;
assert.ok(["127.0.0.1", "localhost"].includes(new URL(apiUrl).hostname));
const anonKey = status.env.ANON_KEY;
const staff = credentials.users.reviewer;
const applicant = credentials.users.applicant;
const credentialsEnv = localSupabaseEnv();

function base32Decode(value) {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let bits = "";
  for (const character of value.toUpperCase().replace(/=+$/, "")) {
    const number = alphabet.indexOf(character);
    if (number < 0) throw new Error("invalid local TOTP seed");
    bits += number.toString(2).padStart(5, "0");
  }
  const bytes = [];
  for (let offset = 0; offset + 8 <= bits.length; offset += 8)
    bytes.push(Number.parseInt(bits.slice(offset, offset + 8), 2));
  return Buffer.from(bytes);
}

function totp(secret) {
  const counter = Math.floor(Date.now() / 30_000);
  const message = Buffer.alloc(8);
  message.writeBigUInt64BE(BigInt(counter));
  const digest = createHmac("sha1", base32Decode(secret))
    .update(message)
    .digest();
  const offset = digest[digest.length - 1] & 15;
  return String(
    (digest.readUInt32BE(offset) & 0x7fffffff) % 1_000_000,
  ).padStart(6, "0");
}

function client() {
  return createClient(apiUrl, anonKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}

async function signInAtAal2(role) {
  const user = credentials.users[role];
  const supabase = client();
  const { data, error } = await supabase.auth.signInWithPassword({
    email: user.email,
    password: user.password,
  });
  assert.ifError(error);
  assert.ok(data.session);
  const { data: factors, error: factorsError } =
    await supabase.auth.mfa.listFactors();
  assert.ifError(factorsError);
  let factor = factors.totp.find((item) => item.status === "verified");
  let seed = user.totp_secret;
  if (!factor) {
    const { data: enrolled, error: enrollError } =
      await supabase.auth.mfa.enroll({
        factorType: "totp",
        friendlyName: `synthetic-edge-${role}-${randomUUID()}`,
      });
    assert.ifError(enrollError);
    factor = { id: enrolled.id };
    seed = enrolled.totp.secret;
    user.totp_secret = seed;
    writeFileSync(credentialFile, `${JSON.stringify(credentials, null, 2)}\n`, {
      mode: 0o600,
    });
    chmodSync(credentialFile, 0o600);
  }
  assert.ok(seed);
  const verified = await supabase.auth.mfa.challengeAndVerify({
    factorId: factor.id,
    code: totp(seed),
  });
  assert.ifError(verified.error);
  const { data: assurance, error: assuranceError } =
    await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
  assert.ifError(assuranceError);
  assert.equal(assurance.currentLevel, "aal2");
  const { data: session, error: sessionError } =
    await supabase.auth.getSession();
  assert.ifError(sessionError);
  return { client: supabase, token: session.session.access_token };
}

async function signInAtAal1(user) {
  const { data, error } = await client().auth.signInWithPassword({
    email: user.email,
    password: user.password,
  });
  assert.ifError(error);
  return data.session.access_token;
}

async function edge(functionName, token, body) {
  const response = await fetch(`${apiUrl}/functions/v1/${functionName}`, {
    method: "POST",
    headers: {
      apikey: anonKey,
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
  return {
    status: response.status,
    body: await response.json().catch(() => null),
  };
}

async function rpc(token, name, args) {
  const response = await fetch(`${apiUrl}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      apikey: anonKey,
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(args),
  });
  return {
    status: response.status,
    body: await response.json().catch(() => null),
  };
}

async function closePriorPendingRequests(reviewToken, applicantClient) {
  const { data: history, error } = await applicantClient.rpc(
    "get_my_verification_history",
  );
  assert.ifError(error);
  for (const item of history.filter((entry) => entry.status === "pending")) {
    const candidates = await edge("verification-review", reviewToken, {
      action: "candidates",
    });
    assert.equal(candidates.status, 200);
    const queue = await edge("verification-review", reviewToken, {
      action: "queue",
    });
    assert.equal(queue.status, 200);
    if (
      candidates.body.result.some(
        (candidate) => candidate.submission_id === item.submission_id,
      )
    ) {
      const assignment = await edge("verification-review", reviewToken, {
        action: "assign",
        submission_id: item.submission_id,
        target_reviewer_id: staff.id,
        reason: "Synthetic cleanup of an interrupted local Edge test request.",
      });
      assert.equal(assignment.status, 200);
    } else {
      assert.ok(
        queue.body.result.some(
          (row) => row.submission_id === item.submission_id,
        ),
        "prior pending synthetic request remains within this reviewer scope",
      );
    }
    const closed = await edge("verification-review", reviewToken, {
      action: "review",
      submission_id: item.submission_id,
      idempotency_key: randomUUID(),
      expected_version: item.version,
      expected_status: "pending",
      expected_decision_version: item.reviews.length,
      decision: "needs_information",
      reason: "Synthetic cleanup of an interrupted local Edge test request.",
    });
    assert.equal(closed.status, 200);
  }
}

function revokeGrant(userId, operatorId) {
  const sql = `update app_private.staff_grants set revoked_at=pg_catalog.now(), revoked_by='${operatorId}' where user_id='${userId}' and capability='identity_suspend' and revoked_at is null`;
  const result = spawnSync(
    process.execPath,
    [
      "scripts/supabase-local.mjs",
      "db",
      "query",
      "--local",
      "--output-format",
      "json",
      sql,
    ],
    {
      cwd: root,
      env: credentialsEnv,
      encoding: "utf8",
      maxBuffer: 1024 * 1024,
    },
  );
  assert.equal(result.status, 0, "local SQL revokes the synthetic test grant");
}

async function pollForQueueResult(token, action, submissionId, startedAt) {
  const deadline = Date.now() + 60_000;
  while (Date.now() < deadline) {
    const result = await edge("verification-review", token, { action });
    assert.equal(result.status, 200, `authorized ${action} query reaches Edge`);
    if (
      result.body?.result?.some((item) => item.submission_id === submissionId)
    ) {
      return performance.now() - startedAt;
    }
    await delay(100);
  }
  assert.fail(`submission did not appear in ${action} within 60 seconds`);
}

test("real local Edge HTTP routes verify sessions, current grants, and reviewer visibility", async (t) => {
  const review = await signInAtAal2("reviewer");
  const invalid = await edge("identity-staff", "not-a-valid-session", {
    action: "suspend",
    subject_id: applicant.id,
    reason: "Synthetic invalid-token denial through local Edge HTTP.",
    idempotency_key: randomUUID(),
  });
  assert.equal(invalid.status, 401);

  const aal1 = await signInAtAal1(staff);
  const insufficientMfa = await edge("identity-staff", aal1, {
    action: "suspend",
    subject_id: applicant.id,
    reason: "Synthetic AAL1 denial through the local Edge server.",
    idempotency_key: randomUUID(),
  });
  assert.equal(insufficientMfa.status, 403);

  const unrelatedSession = await signInAtAal2("unrelated");
  const unrelatedDenied = await edge("identity-staff", unrelatedSession.token, {
    action: "suspend",
    subject_id: applicant.id,
    reason: "Synthetic unrelated-user denial through local Edge HTTP.",
    idempotency_key: randomUUID(),
  });
  assert.equal(unrelatedDenied.status, 403);

  const authorizedQueue = await edge("verification-review", review.token, {
    action: "queue",
  });
  assert.equal(authorizedQueue.status, 200);
  assert.ok(Array.isArray(authorizedQueue.body.result));

  const applicantClient = client();
  const { data: applicantLogin, error: applicantLoginError } =
    await applicantClient.auth.signInWithPassword({
      email: applicant.email,
      password: applicant.password,
    });
  assert.ifError(applicantLoginError);
  await closePriorPendingRequests(review.token, applicantClient);
  const submitted = await rpc(
    applicantLogin.session.access_token,
    "submit_my_verification",
    {
      p_idempotency_key: randomUUID(),
      p_legal_name: null,
      p_narrative:
        "Synthetic local Edge queue visibility request for a student fallback.",
      p_connection_type: null,
    },
  );
  assert.equal(
    submitted.status,
    200,
    "local test applicant commits submission",
  );
  const submissionId = submitted.body.submission_id;
  const committedAt = performance.now();

  const unrelatedCandidates = await edge(
    "verification-review",
    unrelatedSession.token,
    { action: "candidates" },
  );
  assert.equal(unrelatedCandidates.status, 403);

  const candidateMs = await pollForQueueResult(
    review.token,
    "candidates",
    submissionId,
    committedAt,
  );
  const assignment = await edge("verification-review", review.token, {
    action: "assign",
    submission_id: submissionId,
    target_reviewer_id: staff.id,
    reason: "Synthetic assignment to measure local reviewer queue visibility.",
  });
  assert.equal(assignment.status, 200);
  const queueMs = await pollForQueueResult(
    review.token,
    "queue",
    submissionId,
    committedAt,
  );
  assert.ok(candidateMs <= 60_000);
  assert.ok(queueMs <= 60_000);
  console.log(
    `QUEUE_LATENCY submission_to_candidate_ms=${Math.round(candidateMs)} submission_to_assigned_queue_ms=${Math.round(queueMs)}`,
  );

  const decision = await edge("verification-review", review.token, {
    action: "review",
    submission_id: submissionId,
    idempotency_key: randomUUID(),
    expected_version: submitted.body.version,
    expected_status: "pending",
    expected_decision_version: 0,
    decision: "needs_information",
    reason:
      "Synthetic measurement cleanup requests a second evidence submission.",
  });
  assert.equal(decision.status, 200);

  let grantRevoked = false;
  t.after(() => {
    if (!grantRevoked) return;
    const restored = spawnSync(
      process.execPath,
      ["scripts/bootstrap-local-staff.mjs"],
      { cwd: root, env: credentialsEnv, encoding: "utf8" },
    );
    assert.equal(
      restored.status,
      0,
      "local synthetic staff grants are restored",
    );
  });
  revokeGrant(staff.id, credentials.users.operator.id);
  grantRevoked = true;
  const revoked = await edge("identity-staff", review.token, {
    action: "suspend",
    subject_id: applicant.id,
    reason: "Synthetic revoked-grant denial through local Edge HTTP.",
    idempotency_key: randomUUID(),
  });
  assert.equal(revoked.status, 403);
});
