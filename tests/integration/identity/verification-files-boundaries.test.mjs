import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { createVerificationFilesHandler } from "../../../supabase/functions/_shared/verification-files.mjs";

const actor = "8c5de580-8d71-4f00-a44e-859cba363e54";
const otherActor = "0bfc5c8c-d39b-4412-a466-a1a507974b64";
const accessToken = "synthetic-access-token";
const submissionId = "c3efefbd-8c73-47cf-98ba-307416f654a3";
const intentId = "1d6ec202-609d-4c5a-aead-94165ca4dfb7";
const evidenceId = "b14fd2bf-dc09-468c-8d52-664f04a67024";
const uploadToken = "A".repeat(43);
const downloadBaseUrl = "http://local.test/verification-evidence";
const png = Uint8Array.from(
  readFileSync(
    new URL("../../fixtures/verification/synthetic.png", import.meta.url),
  ),
);
const pdf = Uint8Array.from(
  readFileSync(
    new URL("../../fixtures/verification/synthetic.pdf", import.meta.url),
  ),
);
const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");

function jsonRequest(body, token = accessToken) {
  return new Request("http://local.test/verification-evidence", {
    method: "POST",
    headers: {
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

function uploadRequest(
  bytes,
  token = accessToken,
  uploadAccessToken = uploadToken,
) {
  return new Request("http://local.test/verification-evidence/upload", {
    method: "PUT",
    headers: {
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      "content-type": "image/png",
      "x-upload-intent-id": intentId,
      "x-upload-token": uploadAccessToken,
    },
    body: bytes,
  });
}

function makeHandler(overrides = {}) {
  const calls = [];
  const handler = createVerificationFilesHandler({
    verifyActor: async (token) => {
      calls.push(["verify", token]);
      return token === "other-token" ? otherActor : actor;
    },
    command: async (name, input) => {
      calls.push(["command", name, input]);
      if (name === "server_begin_verification_upload_for_actor")
        return {
          intent_id: intentId,
          evidence_id: evidenceId,
          expires_at: "later",
        };
      if (name === "server_claim_verification_upload_for_actor")
        return {
          claimed: true,
          evidence_id: evidenceId,
          object_key: `${actor}/${submissionId}/${evidenceId}/source`,
          content_type: "image/png",
          size_bytes: png.byteLength,
        };
      if (name === "server_finalize_verification_upload_for_actor")
        return {
          finalized: true,
          evidence_id: evidenceId,
          safety_state: "quarantined",
          reviewable: false,
        };
      return { failed: true };
    },
    storeUpload: async (bucket, key, bytes, options) => {
      calls.push(["store", bucket, key, bytes, options]);
    },
    readUpload: async () => png,
    removeUpload: async (key) => calls.push(["remove", key]),
    downloadSigningKey: Buffer.alloc(32, 19).toString("base64url"),
    downloadBaseUrl,
    randomToken: () => uploadToken,
    ...overrides,
  });
  return { handler, calls };
}

test("upload ticket is bound to Auth actor, submission, purpose, and short expiry", async () => {
  const { handler, calls } = makeHandler();
  const response = await handler(
    jsonRequest({
      action: "begin_upload",
      submission_id: submissionId,
      evidence_position: 1,
      content_type: "image/png",
      size_bytes: png.byteLength,
      evidence_kind: "student_id",
    }),
  );
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    upload_intent_id: intentId,
    upload_token: uploadToken,
    expires_at: "later",
  });
  const command = calls.find((call) => call[0] === "command");
  assert.equal(command[1], "server_begin_verification_upload_for_actor");
  assert.equal(command[2].p_actor, actor);
  assert.equal(command[2].p_submission_id, submissionId);
  assert.equal(command[2].p_token_hash_hex, sha256(Buffer.from(uploadToken)));
  assert.equal(JSON.stringify(command).includes(uploadToken), false);
});

test("only the account-bound intent token can upload once and bytes stay quarantined", async () => {
  const { handler, calls } = makeHandler();
  const response = await handler(uploadRequest(png));
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    evidence_id: evidenceId,
    safety_state: "quarantined",
    reviewable: false,
  });
  const claim = calls.find(
    (call) => call[1] === "server_claim_verification_upload_for_actor",
  );
  assert.equal(claim[2].p_actor, actor);
  assert.equal(claim[2].p_token_hash_hex, sha256(Buffer.from(uploadToken)));
  const finalization = calls.find(
    (call) => call[1] === "server_finalize_verification_upload_for_actor",
  );
  assert.equal(finalization[2].p_sha256_hex, sha256(png));
  assert.equal(finalization[2].p_actor, actor);
  assert.equal(calls.find((call) => call[0] === "store")[4].upsert, false);
});

test("client cannot choose object keys, file types, actors, or unsafe request fields", async () => {
  let commands = 0;
  const { handler } = makeHandler({
    command: async () => {
      commands++;
      return {};
    },
  });
  for (const input of [
    {
      action: "begin_upload",
      submission_id: submissionId,
      evidence_position: 1,
      content_type: "image/svg+xml",
      size_bytes: 100,
      evidence_kind: "student_id",
    },
    {
      action: "begin_upload",
      submission_id: submissionId,
      evidence_position: 1,
      content_type: "image/png",
      size_bytes: 5_000_001,
      evidence_kind: "student_id",
    },
    {
      action: "begin_upload",
      submission_id: submissionId,
      evidence_position: 1,
      content_type: "image/png",
      size_bytes: 10,
      evidence_kind: "student_id",
      object_key: "../private",
    },
    {
      action: "begin_upload",
      actor_id: actor,
      submission_id: submissionId,
      evidence_position: 1,
      content_type: "image/png",
      size_bytes: 10,
      evidence_kind: "student_id",
    },
  ]) {
    assert.equal((await handler(jsonRequest(input))).status, 400);
  }
  assert.equal(commands, 0);
});

test("authentication and cross-account upload tokens fail without storage access", async () => {
  const { handler, calls } = makeHandler();
  const otherIntentHandler = makeHandler({
    command: async (_name, input) => {
      if (input.p_actor !== actor) {
        const error = new Error("invalid_upload_intent");
        error.code = "invalid_upload_intent";
        throw error;
      }
      return {
        claimed: true,
        evidence_id: evidenceId,
        object_key: `${actor}/${submissionId}/${evidenceId}/source`,
        content_type: "image/png",
        size_bytes: png.byteLength,
      };
    },
  });
  assert.equal(
    (
      await handler(
        jsonRequest(
          {
            action: "begin_upload",
            submission_id: submissionId,
            evidence_position: 1,
            content_type: "image/png",
            size_bytes: png.byteLength,
            evidence_kind: "student_id",
          },
          null,
        ),
      )
    ).status,
    401,
  );
  assert.equal(
    (await otherIntentHandler.handler(uploadRequest(png, "other-token")))
      .status,
    403,
  );
  assert.equal(
    calls.some((call) => call[0] === "store"),
    false,
  );
});

test("forged MIME, unsafe signatures, and changed finalized bytes never become reviewable", async () => {
  let removed = false;
  const { handler } = makeHandler({
    storeUpload: async () => {},
    readUpload: async () => Uint8Array.from([0x3c, 0x73, 0x76, 0x67, 0x3e]),
    removeUpload: async () => {
      removed = true;
    },
  });
  const response = await handler(uploadRequest(png));
  assert.equal(response.status, 409);
  assert.equal(removed, true);
});

test("synthetic PDF passes the local format check but remains quarantined", async () => {
  const commands = [];
  const handler = createVerificationFilesHandler({
    verifyActor: async () => actor,
    command: async (name, input) => {
      commands.push([name, input]);
      if (name === "server_claim_verification_upload_for_actor")
        return {
          claimed: true,
          evidence_id: evidenceId,
          object_key: `${actor}/${submissionId}/${evidenceId}/source`,
          content_type: "application/pdf",
          size_bytes: pdf.byteLength,
        };
      return {
        evidence_id: evidenceId,
        safety_state: "quarantined",
        reviewable: false,
      };
    },
    storeUpload: async () => {},
    readUpload: async () => pdf,
    removeUpload: async () => {},
    downloadSigningKey: Buffer.alloc(32, 19).toString("base64url"),
    downloadBaseUrl,
    randomToken: () => uploadToken,
  });
  const response = await handler(
    new Request("http://local.test/upload", {
      method: "PUT",
      headers: {
        authorization: `Bearer ${accessToken}`,
        "content-type": "application/pdf",
        "x-upload-intent-id": intentId,
        "x-upload-token": uploadToken,
      },
      body: pdf,
    }),
  );
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    evidence_id: evidenceId,
    safety_state: "quarantined",
    reviewable: false,
  });
  assert.equal(commands.at(-1)[1].p_size_bytes, pdf.byteLength);
  assert.equal(commands.at(-1)[1].p_sha256_hex, sha256(pdf));
});

test("forged PNG MIME and PDF active-content markers are rejected before storage", async () => {
  let stored = false;
  const handlerFor = (contentType, body) =>
    createVerificationFilesHandler({
      verifyActor: async () => actor,
      command: async (name) =>
        name === "server_claim_verification_upload_for_actor"
          ? {
              claimed: true,
              evidence_id: evidenceId,
              object_key: `${actor}/${submissionId}/${evidenceId}/source`,
              content_type: contentType,
              size_bytes: body.byteLength,
            }
          : { rejected: true },
      storeUpload: async () => {
        stored = true;
      },
      readUpload: async () => body,
      removeUpload: async () => {},
      downloadSigningKey: Buffer.alloc(32, 19).toString("base64url"),
      downloadBaseUrl,
    });
  const svg = new TextEncoder().encode(
    "<svg xmlns='http://www.w3.org/2000/svg'></svg>",
  );
  const forged = await handlerFor(
    "image/png",
    svg,
  )(
    new Request("http://local.test/upload", {
      method: "PUT",
      headers: {
        authorization: `Bearer ${accessToken}`,
        "content-type": "image/png",
        "x-upload-intent-id": intentId,
        "x-upload-token": uploadToken,
      },
      body: svg,
    }),
  );
  assert.equal(forged.status, 415);
  const activePdf = new TextEncoder().encode(
    new TextDecoder().decode(pdf).replace("no personal data", "/JavaScript"),
  );
  const active = await handlerFor(
    "application/pdf",
    activePdf,
  )(
    new Request("http://local.test/upload", {
      method: "PUT",
      headers: {
        authorization: `Bearer ${accessToken}`,
        "content-type": "application/pdf",
        "x-upload-intent-id": intentId,
        "x-upload-token": uploadToken,
      },
      body: activePdf,
    }),
  );
  assert.equal(active.status, 415);
  assert.equal(stored, false);
});

test("upload body size is bounded before storage is called", async () => {
  let stored = false;
  const { handler } = makeHandler({
    storeUpload: async () => {
      stored = true;
    },
  });
  const response = await handler(uploadRequest(new Uint8Array(5_000_001)));
  assert.equal(response.status, 413);
  assert.equal(stored, false);
});

test("review downloads require verified AAL2 and receive a bounded attachment URL", async () => {
  const calls = [];
  const handler = createVerificationFilesHandler({
    verifyActor: async () => ({ actor, aal: "aal2" }),
    command: async (name, args) => {
      calls.push([name, args]);
      if (name === "server_record_verification_download_access_for_actor")
        return { recorded: true };
      return {
        authorized: true,
        storage_bucket: "verification-private",
        object_key: `${actor}/${submissionId}/${evidenceId}/source`,
        content_type: "image/png",
        evidence_id: evidenceId,
      };
    },
    storeUpload: async () => {},
    readUpload: async () => png,
    removeUpload: async () => {},
    downloadSigningKey: Buffer.alloc(32, 19).toString("base64url"),
    downloadBaseUrl,
  });
  const response = await handler(
    new Request("https://attacker.test/verification-evidence", {
      method: "POST",
      headers: {
        authorization: `Bearer ${accessToken}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        action: "signed_download",
        evidence_id: evidenceId,
      }),
    }),
  );
  assert.equal(response.status, 200);
  const result = await response.json();
  assert.equal(result.expires_in_seconds, 600);
  const link = new URL(result.signed_url);
  assert.equal(link.origin, new URL(downloadBaseUrl).origin);
  assert.match(link.pathname, /\/download$/);
  assert.match(link.searchParams.get("token") ?? "", /^[A-Za-z0-9_.-]+$/);
  const download = await handler(new Request(result.signed_url));
  assert.equal(download.status, 200);
  assert.equal(
    download.headers.get("content-disposition"),
    'attachment; filename="verification-evidence"',
  );
  assert.equal(download.headers.get("x-content-type-options"), "nosniff");
  assert.equal(download.headers.get("cache-control"), "private, no-store");
  assert.deepEqual(new Uint8Array(await download.arrayBuffer()), png);
  assert.deepEqual(calls[0], [
    "server_get_verification_download_for_actor",
    {
      p_actor: actor,
      p_evidence_id: evidenceId,
      p_auth_aal: "aal2",
    },
  ]);
  assert.deepEqual(calls[1], [
    "server_record_verification_download_access_for_actor",
    {
      p_actor: actor,
      p_evidence_id: evidenceId,
      p_object_key: `${actor}/${submissionId}/${evidenceId}/source`,
    },
  ]);
});

test("signed download links expire and cannot be changed to fetch another object", async () => {
  let clock = 50_000;
  let reads = 0;
  const handler = createVerificationFilesHandler({
    verifyActor: async () => ({ actor, aal: "aal2" }),
    command: async (name) =>
      name === "server_record_verification_download_access_for_actor"
        ? { recorded: true }
        : {
            authorized: true,
            storage_bucket: "verification-private",
            object_key: `${actor}/${submissionId}/${evidenceId}/source`,
            content_type: "image/png",
            evidence_id: evidenceId,
          },
    storeUpload: async () => {},
    readUpload: async () => {
      reads++;
      return png;
    },
    removeUpload: async () => {},
    downloadSigningKey: Buffer.alloc(32, 19).toString("base64url"),
    downloadBaseUrl,
    now: () => clock,
  });
  const response = await handler(
    jsonRequest({ action: "signed_download", evidence_id: evidenceId }),
  );
  const link = new URL((await response.json()).signed_url);
  const token = link.searchParams.get("token");
  const tampered = new URL(link);
  tampered.searchParams.set("token", `${token}x`);
  assert.equal((await handler(new Request(tampered))).status, 403);
  clock += 600_001;
  assert.equal((await handler(new Request(link))).status, 403);
  assert.equal(reads, 0);
});

test("reviewer download is denied before the database command when Auth assurance is not aal2", async () => {
  let commands = 0;
  const handler = createVerificationFilesHandler({
    verifyActor: async () => ({ actor, aal: "aal1" }),
    command: async () => {
      commands++;
      return {};
    },
    storeUpload: async () => {},
    readUpload: async () => png,
    removeUpload: async () => {},
    downloadSigningKey: Buffer.alloc(32, 19).toString("base64url"),
    downloadBaseUrl,
  });
  const response = await handler(
    jsonRequest({ action: "signed_download", evidence_id: evidenceId }),
  );
  assert.equal(response.status, 403);
  assert.deepEqual(await response.json(), { error: "review_access_denied" });
  assert.equal(commands, 0);
});
