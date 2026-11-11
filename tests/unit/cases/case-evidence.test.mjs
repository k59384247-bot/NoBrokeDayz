import assert from "node:assert/strict";
import test from "node:test";
import { createCaseEvidenceHandler } from "../../../supabase/functions/_shared/case-evidence.mjs";

const actorId = "11111111-1111-4111-8111-111111111111";
const caseId = "22222222-2222-4222-8222-222222222222";
const intentId = "33333333-3333-4333-8333-333333333333";
const idem = "44444444-4444-4444-8444-444444444444";

function bearer(aal = "aal1") {
  const payload = Buffer.from(JSON.stringify({ sub: actorId, aal })).toString(
    "base64url",
  );
  return `header.${payload}.signature`;
}

function makeHandler({ rpc, storeUpload, readUpload, removeUpload } = {}) {
  return createCaseEvidenceHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: rpc ?? (async () => ({})),
    storeUpload: storeUpload ?? (async () => {}),
    readUpload: readUpload ?? (async () => new Uint8Array()),
    removeUpload: removeUpload ?? (async () => {}),
    uploadSigningKey: "a".repeat(43),
  });
}

test("begin upload returns a scoped expiring token without an object URL", async () => {
  let args;
  const handler = makeHandler({
    rpc: async (name, value) => {
      assert.equal(name, "server_issue_case_file_upload_for_actor");
      args = value;
      return {
        intent_id: intentId,
        object_key: "private/path/source",
        content_type: "image/jpeg",
        size_bytes: 4,
        expires_at: "2026-11-06T12:05:00.000Z",
      };
    },
  });
  const response = await handler(
    new Request("http://local.test/case-evidence", {
      method: "POST",
      headers: { authorization: `Bearer ${bearer()}` },
      body: JSON.stringify({
        action: "begin_upload",
        case_id: caseId,
        request_number: 1,
        content_type: "image/jpeg",
        size_bytes: 4,
        idempotency_key: idem,
      }),
    }),
  );
  const body = await response.json();
  assert.equal(response.status, 200);
  assert.equal(args.p_actor, actorId);
  assert.equal(args.p_case_id, caseId);
  assert.match(args.p_token_hash_hex, /^[0-9a-f]{64}$/);
  assert.equal(body.intent_id, intentId);
  assert.match(body.upload_token, /^[A-Za-z0-9_-]{43}$/);
  assert.equal("object_key" in body, false);
  assert.equal("public_url" in body, false);
});

test("uploaded files are stored privately and remain quarantined", async () => {
  const bytes = new Uint8Array([0xff, 0xd8, 0xff, 0xd9]);
  let storedBucket;
  let finalized;
  const handler = makeHandler({
    rpc: async (name, args) => {
      if (name === "server_claim_case_file_upload_for_actor")
        return {
          already_finalized: false,
          object_key: "case/actor/evidence/source",
          content_type: "image/jpeg",
          size_bytes: 4,
          case_id: caseId,
          evidence_id: intentId,
        };
      if (name === "server_finalize_case_file_upload_for_actor") {
        finalized = args;
        return {
          evidence_number: 1,
          safety_state: "quarantined",
          reviewable: false,
        };
      }
      throw new Error(name);
    },
    storeUpload: async (bucket) => {
      storedBucket = bucket;
    },
    readUpload: async () => bytes,
  });
  const response = await handler(
    new Request("http://local.test/case-evidence", {
      method: "PUT",
      headers: {
        authorization: `Bearer ${bearer()}`,
        "x-upload-intent-id": intentId,
        "x-upload-token": "b".repeat(43),
        "content-type": "image/jpeg",
      },
      body: bytes,
    }),
  );
  const body = await response.json();
  assert.equal(response.status, 200);
  assert.equal(storedBucket, "case-evidence-quarantine");
  assert.match(finalized.p_sha256_hex, /^[0-9a-f]{64}$/);
  assert.equal(body.safety_state, "quarantined");
  assert.equal(body.reviewable, false);
});

test("quarantined case evidence cannot be downloaded, even by a reviewer", async () => {
  let reads = 0;
  const handler = makeHandler({
    rpc: async () => {
      const error = new Error("not ready");
      error.code = "case_evidence_not_ready";
      throw error;
    },
    readUpload: async () => {
      reads += 1;
      return new Uint8Array();
    },
  });
  const response = await handler(
    new Request("http://local.test/case-evidence/download", {
      method: "POST",
      headers: {
        authorization: `Bearer ${bearer("aal2")}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        action: "download",
        case_id: caseId,
        evidence_number: 1,
      }),
    }),
  );
  assert.equal(response.status, 403);
  assert.equal((await response.json()).error, "case_evidence_not_ready");
  assert.equal(reads, 0);
});
