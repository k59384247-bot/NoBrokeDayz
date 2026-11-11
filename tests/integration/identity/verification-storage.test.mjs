import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { after, before, test } from "node:test";
import { createClient } from "@supabase/supabase-js";
import { createVerificationFilesHandler } from "../../../supabase/functions/_shared/verification-files.mjs";

const state = JSON.parse(process.env.NBD_LOCAL_AUTH_STATUS_JSON ?? "null");
if (!state?.env?.API_URL || !state.env.ANON_KEY || !state.env.SERVICE_ROLE_KEY)
  throw new Error("verification Storage test requires local stack status");
const apiUrl = state.env.API_URL;
const anonKey = state.env.ANON_KEY;
const serviceKey = state.env.SERVICE_ROLE_KEY;
const localAdmin = createClient(apiUrl, serviceKey, {
  auth: {
    persistSession: false,
    autoRefreshToken: false,
    detectSessionInUrl: false,
  },
});
const ownerMail = `p2step6-owner-${randomBytes(6).toString("hex")}@identity.test`;
const otherMail = `p2step6-other-${randomBytes(6).toString("hex")}@identity.test`;
const syntheticPassword = randomBytes(32).toString("base64url");
const submissionId = "c3efefbd-8c73-47cf-98ba-307416f654a3";
const evidenceId = "b14fd2bf-dc09-468c-8d52-664f04a67024";
const uploadIntentId = "1d6ec202-609d-4c5a-aead-94165ca4dfb7";
const uploadToken = randomBytes(32).toString("base64url");
const png = Uint8Array.from(
  readFileSync(
    new URL("../../fixtures/verification/synthetic.png", import.meta.url),
  ),
);
let owner;
let other;
let ownerSession;
let otherSession;
let handler;
let objectPath;
let privateObjectPath;
let downloadClock = Date.now();
let permitDownload = false;
const downloadSigningKey = randomBytes(32).toString("base64url");

function storageRequest(path, token = "") {
  return fetch(`${apiUrl}/storage/v1/${path}`, {
    headers: {
      apikey: anonKey,
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
  });
}

before(async () => {
  for (const email of [ownerMail, otherMail]) {
    const { data, error } = await localAdmin.auth.admin.createUser({
      email,
      password: syntheticPassword,
      email_confirm: true,
      app_metadata: { local_fixture_scope: "phase2-step6" },
    });
    if (error || !data.user)
      throw new Error("local synthetic Auth fixture creation failed");
    if (email === ownerMail) owner = data.user;
    else other = data.user;
  }
  const ownerClient = createClient(apiUrl, anonKey, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
  });
  const otherClient = createClient(apiUrl, anonKey, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
  });
  const ownerLogin = await ownerClient.auth.signInWithPassword({
    email: ownerMail,
    password: syntheticPassword,
  });
  const otherLogin = await otherClient.auth.signInWithPassword({
    email: otherMail,
    password: syntheticPassword,
  });
  if (ownerLogin.error || otherLogin.error)
    throw new Error("local synthetic Auth signin failed");
  ownerSession = ownerLogin.data.session;
  otherSession = otherLogin.data.session;
  objectPath = `${owner.id}/${submissionId}/${evidenceId}/source`;
  privateObjectPath = `${owner.id}/${submissionId}/${evidenceId}/source`;

  handler = createVerificationFilesHandler({
    verifyActor: async (token) => {
      const response = await fetch(`${apiUrl}/auth/v1/user`, {
        headers: { apikey: anonKey, authorization: `Bearer ${token}` },
      });
      if (!response.ok) return null;
      const user = await response.json();
      // Auth /user validates the token. The reviewer command's authorization
      // decision is injected here; SQL tests cover real AAL2/grant denials.
      return { actor: user.id, aal: "aal2" };
    },
    command: async (name, args) => {
      if (name === "server_begin_verification_upload_for_actor") {
        if (args.p_actor !== owner.id || args.p_submission_id !== submissionId)
          throw new Error("submission unavailable");
        return {
          intent_id: uploadIntentId,
          evidence_id: evidenceId,
          expires_at: new Date(Date.now() + 300_000).toISOString(),
        };
      }
      if (name === "server_claim_verification_upload_for_actor") {
        if (args.p_actor !== owner.id || args.p_intent_id !== uploadIntentId)
          throw Object.assign(new Error("invalid upload"), {
            code: "invalid_upload_intent",
          });
        return {
          claimed: true,
          evidence_id: evidenceId,
          object_key: objectPath,
          content_type: "image/png",
          size_bytes: png.byteLength,
        };
      }
      if (name === "server_finalize_verification_upload_for_actor")
        return {
          evidence_id: evidenceId,
          safety_state: "quarantined",
          reviewable: false,
        };
      if (name === "server_get_verification_download_for_actor") {
        if (!permitDownload)
          throw Object.assign(new Error("denied"), {
            code: "review_access_denied",
          });
        return {
          authorized: true,
          storage_bucket: "verification-private",
          object_key: privateObjectPath,
          content_type: "image/png",
          evidence_id: evidenceId,
        };
      }
      if (name === "server_record_verification_download_access_for_actor")
        return { recorded: true };
      throw new Error("unsupported verification command");
    },
    storeUpload: async (bucket, key, bytes, options) => {
      const { error } = await localAdmin.storage
        .from(bucket)
        .upload(key, bytes, options);
      if (error) throw new Error("local private Storage upload failed");
    },
    readUpload: async (bucket, key) => {
      const { data, error } = await localAdmin.storage
        .from(bucket)
        .download(key);
      if (error || !data)
        throw new Error("local private Storage readback failed");
      return new Uint8Array(await data.arrayBuffer());
    },
    removeUpload: async (bucket, key) => {
      const { error } = await localAdmin.storage.from(bucket).remove([key]);
      if (error) throw new Error("local private Storage cleanup failed");
    },
    downloadSigningKey,
    downloadBaseUrl: `${apiUrl}/functions/v1/verification-evidence`,
    now: () => downloadClock,
    randomToken: () => uploadToken,
  });
});

after(async () => {
  for (const [bucket, key] of [
    ["verification-quarantine", objectPath],
    ["verification-private", privateObjectPath],
  ]) {
    if (key)
      await localAdmin.storage
        .from(bucket)
        .remove([key])
        .catch(() => null);
  }
  for (const user of [owner, other]) {
    if (user?.id)
      await localAdmin.auth.admin.deleteUser(user.id).catch(() => null);
  }
});

test("real local Auth upload writes only a quarantined private object", async () => {
  const response = await handler(
    new Request(`${apiUrl}/functions/v1/verification-evidence`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${ownerSession.access_token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        action: "begin_upload",
        submission_id: submissionId,
        evidence_position: 1,
        content_type: "image/png",
        size_bytes: png.byteLength,
        evidence_kind: "student_id",
      }),
    }),
  );
  assert.equal(response.status, 200);
  const ticket = await response.json();
  assert.equal(ticket.upload_token, uploadToken);
  const upload = await handler(
    new Request(`${apiUrl}/functions/v1/verification-evidence/upload`, {
      method: "PUT",
      headers: {
        authorization: `Bearer ${ownerSession.access_token}`,
        "content-type": "image/png",
        "x-upload-intent-id": ticket.upload_intent_id,
        "x-upload-token": ticket.upload_token,
      },
      body: png,
    }),
  );
  assert.equal(upload.status, 200);
  assert.deepEqual(await upload.json(), {
    evidence_id: evidenceId,
    safety_state: "quarantined",
    reviewable: false,
  });
  for (const [token, label] of [
    ["", "anonymous"],
    [ownerSession.access_token, "owner"],
    [otherSession.access_token, "unrelated account"],
  ]) {
    const read = await storageRequest(
      `object/authenticated/verification-quarantine/${objectPath}`,
      token,
    );
    assert.equal(
      read.ok,
      false,
      `${label} cannot read quarantined evidence directly`,
    );
  }
  const publicRead = await storageRequest(
    `object/public/verification-quarantine/${objectPath}`,
  );
  assert.equal(
    publicRead.ok,
    false,
    "public URLs cannot read evidence objects",
  );
  const substituted = await handler(
    new Request(`${apiUrl}/functions/v1/verification-evidence/upload`, {
      method: "PUT",
      headers: {
        authorization: `Bearer ${otherSession.access_token}`,
        "content-type": "image/png",
        "x-upload-intent-id": ticket.upload_intent_id,
        "x-upload-token": ticket.upload_token,
      },
      body: png,
    }),
  );
  assert.equal(
    substituted.status,
    403,
    "another account cannot use the owner's upload token",
  );
});

test("application download link proxies private bytes with safe headers and expires", async () => {
  permitDownload = true;
  const { error: uploadError } = await localAdmin.storage
    .from("verification-private")
    .upload(privateObjectPath, png, {
      contentType: "image/png",
      cacheControl: "0",
      upsert: false,
    });
  if (uploadError) throw new Error("signed URL fixture upload failed");
  const issued = await handler(
    new Request(`${apiUrl}/functions/v1/verification-evidence`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${ownerSession.access_token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        action: "signed_download",
        evidence_id: evidenceId,
      }),
    }),
  );
  assert.equal(issued.status, 200);
  const link = (await issued.json()).signed_url;
  const first = await handler(new Request(link));
  assert.equal(first.status, 200);
  assert.equal(
    first.headers.get("content-disposition"),
    'attachment; filename="verification-evidence"',
  );
  assert.equal(first.headers.get("x-content-type-options"), "nosniff");
  assert.equal(first.headers.get("content-security-policy"), "sandbox");
  assert.equal(first.headers.get("x-frame-options"), "DENY");
  assert.deepEqual(new Uint8Array(await first.arrayBuffer()), png);
  downloadClock += 600_001;
  const expired = await handler(new Request(link));
  assert.equal(
    expired.status,
    403,
    "signed URL stops working after its bounded lifetime",
  );
});

test("direct client writes and signed-link requests stay blocked", async () => {
  permitDownload = false;
  const directUpload = await fetch(
    `${apiUrl}/storage/v1/object/verification-quarantine/${owner.id}/${submissionId}/client/source`,
    {
      method: "POST",
      headers: {
        apikey: anonKey,
        authorization: `Bearer ${ownerSession.access_token}`,
        "content-type": "image/png",
        "x-upsert": "false",
      },
      body: png,
    },
  );
  assert.equal(
    directUpload.ok,
    false,
    "authenticated clients cannot bypass the upload command",
  );
  const logArgs = {
    p_actor: owner.id,
    p_evidence_id: evidenceId,
    p_object_key: `${owner.id}/${submissionId}/${evidenceId}/source`,
  };
  const serverLog = await localAdmin.rpc(
    "server_record_verification_download_access_for_actor",
    logArgs,
  );
  assert.equal(
    serverLog.error,
    null,
    "narrow server RPC accepts named arguments",
  );
  assert.deepEqual(serverLog.data, { recorded: false });
  const ownerClient = createClient(apiUrl, anonKey, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
    global: {
      headers: { authorization: `Bearer ${ownerSession.access_token}` },
    },
  });
  const browserLog = await ownerClient.rpc(
    "server_record_verification_download_access_for_actor",
    logArgs,
  );
  assert.ok(
    browserLog.error,
    "authenticated user cannot call the server-only access logger",
  );
  const requestDownload = await handler(
    new Request(`${apiUrl}/functions/v1/verification-evidence`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${ownerSession.access_token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        action: "signed_download",
        evidence_id: evidenceId,
      }),
    }),
  );
  assert.equal(
    requestDownload.status,
    403,
    "the command denies reviewers without current authorization",
  );
});
