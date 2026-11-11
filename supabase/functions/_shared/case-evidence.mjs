import { readLimited, signatureCheck } from "./verification-files.mjs";

const UUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
const MAX_BODY_BYTES = 4096;
const HARD_FILE_LIMIT = 100_000_000;
const TYPES = new Set(["image/jpeg", "image/png", "application/pdf"]);

function json(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "cache-control": "no-store",
      "content-type": "application/json; charset=utf-8",
    },
  });
}

function errorCode(error) {
  return error?.code;
}

function base64Url(bytes) {
  let value = "";
  for (const byte of bytes) value += String.fromCharCode(byte);
  return btoa(value)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
}

async function digestHex(bytes) {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return [...digest].map((part) => part.toString(16).padStart(2, "0")).join("");
}

function claims(token) {
  const part = token?.split(".")[1];
  if (!part || !/^[A-Za-z0-9_-]+$/.test(part)) return null;
  try {
    const normalized = part.replaceAll("-", "+").replaceAll("_", "/");
    return JSON.parse(
      atob(normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=")),
    );
  } catch {
    return null;
  }
}

export function createCaseEvidenceHandler({
  verifyActor,
  rpc,
  storeUpload,
  readUpload,
  removeUpload,
  uploadSigningKey,
}) {
  if (
    [verifyActor, rpc, storeUpload, readUpload, removeUpload].some(
      (item) => typeof item !== "function",
    ) ||
    typeof uploadSigningKey !== "string"
  )
    throw new Error("case evidence dependencies are not configured");
  const keyBytes = new TextEncoder().encode(uploadSigningKey);
  if (keyBytes.byteLength < 32)
    throw new Error("case evidence signing key is not configured");
  const keyPromise = crypto.subtle.importKey(
    "raw",
    keyBytes,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );

  async function tokenFor(actor, caseId, idempotencyKey) {
    const signature = await crypto.subtle.sign(
      "HMAC",
      await keyPromise,
      new TextEncoder().encode(`${actor}:${caseId}:${idempotencyKey}`),
    );
    return base64Url(new Uint8Array(signature));
  }

  async function authenticate(request) {
    const bearer = request.headers
      .get("authorization")
      ?.match(/^Bearer\s+([^\s]+)$/i)?.[1];
    if (!bearer) return null;
    const [actor, tokenClaims] = await Promise.all([
      verifyActor(bearer).catch(() => null),
      Promise.resolve(claims(bearer)),
    ]);
    if (
      !actor ||
      !UUID.test(actor.id ?? "") ||
      tokenClaims?.sub !== actor.id ||
      !["aal1", "aal2"].includes(tokenClaims.aal)
    )
      return null;
    return { actor, aal: tokenClaims.aal };
  }

  async function parseJson(request) {
    const text = await request.text();
    if (new TextEncoder().encode(text).byteLength > MAX_BODY_BYTES)
      return { large: true };
    try {
      return { body: JSON.parse(text) };
    } catch {
      return { invalid: true };
    }
  }

  return async function caseEvidence(request) {
    if (!["POST", "PUT"].includes(request.method))
      return json(405, { error: "method_not_allowed" });
    const auth = await authenticate(request);
    if (!auth) return json(401, { error: "authentication_required" });

    if (
      request.method === "POST" &&
      new URL(request.url).pathname.endsWith("/download")
    ) {
      const parsed = await parseJson(request).catch(() => ({ invalid: true }));
      const body = parsed.body;
      if (parsed.large) return json(413, { error: "request_too_large" });
      if (
        !body ||
        typeof body !== "object" ||
        Array.isArray(body) ||
        Object.keys(body).length !== 3 ||
        body.action !== "download" ||
        !UUID.test(body.case_id ?? "") ||
        !Number.isInteger(body.evidence_number) ||
        body.evidence_number < 1 ||
        body.evidence_number > 25
      )
        return json(400, { error: "invalid_request" });
      if (auth.aal !== "aal2")
        return json(403, { error: "case_access_denied" });
      try {
        const target = await rpc(
          "server_authorize_case_file_download_for_actor",
          {
            p_actor: auth.actor.id,
            p_case_id: body.case_id,
            p_evidence_number: body.evidence_number,
            p_auth_aal: auth.aal,
          },
        );
        if (target?.denied)
          return target.reason === "case_evidence_not_ready"
            ? json(403, { error: "case_evidence_not_ready" })
            : json(403, { error: "case_access_denied" });
        const bytes = await readUpload(target.bucket, target.object_key);
        if (
          bytes.byteLength !== target.size_bytes ||
          (await digestHex(bytes)) !== target.sha256_hex ||
          signatureCheck(bytes, target.content_type)
        )
          return json(503, { error: "case_evidence_unavailable" });
        return new Response(bytes, {
          status: 200,
          headers: {
            "cache-control": "private, no-store",
            "content-disposition": 'attachment; filename="case-evidence"',
            "content-length": String(bytes.byteLength),
            "content-security-policy": "sandbox",
            "content-type": target.content_type,
            "referrer-policy": "no-referrer",
            "x-content-type-options": "nosniff",
            "x-frame-options": "DENY",
          },
        });
      } catch (error) {
        return errorCode(error) === "case_evidence_not_ready"
          ? json(403, { error: "case_evidence_not_ready" })
          : errorCode(error) === "case_access_denied" ||
              errorCode(error) === "42501"
            ? json(403, { error: "case_access_denied" })
            : json(404, { error: "case_evidence_unavailable" });
      }
    }

    if (request.method === "POST") {
      const parsed = await parseJson(request).catch(() => ({ invalid: true }));
      const body = parsed.body;
      if (parsed.large) return json(413, { error: "request_too_large" });
      if (
        !body ||
        typeof body !== "object" ||
        Array.isArray(body) ||
        Object.keys(body).length !== 6 ||
        Object.keys(body).some(
          (key) =>
            ![
              "action",
              "case_id",
              "request_number",
              "content_type",
              "size_bytes",
              "idempotency_key",
            ].includes(key),
        ) ||
        body.action !== "begin_upload" ||
        !UUID.test(body.case_id ?? "") ||
        !Number.isInteger(body.request_number) ||
        body.request_number < 1 ||
        body.request_number > 100 ||
        !TYPES.has(body.content_type) ||
        !Number.isInteger(body.size_bytes) ||
        body.size_bytes < 1 ||
        body.size_bytes > HARD_FILE_LIMIT ||
        !UUID.test(body.idempotency_key ?? "")
      )
        return json(400, { error: "invalid_request" });
      try {
        const uploadToken = await tokenFor(
          auth.actor.id,
          body.case_id,
          body.idempotency_key,
        );
        const result = await rpc("server_issue_case_file_upload_for_actor", {
          p_actor: auth.actor.id,
          p_case_id: body.case_id,
          p_request_number: body.request_number,
          p_content_type: body.content_type,
          p_size_bytes: body.size_bytes,
          p_token_hash_hex: await digestHex(
            new TextEncoder().encode(uploadToken),
          ),
          p_idempotency_key: body.idempotency_key,
        });
        return json(200, {
          intent_id: result.intent_id,
          upload_token: uploadToken,
          content_type: result.content_type,
          size_bytes: result.size_bytes,
          expires_at: result.expires_at,
        });
      } catch (error) {
        return errorCode(error) === "case_file_limit_reached"
          ? json(409, { error: "case_file_limit_reached" })
          : errorCode(error) === "42501" ||
              errorCode(error) === "case_access_denied"
            ? json(403, { error: "case_access_denied" })
            : json(409, { error: "upload_not_allowed" });
      }
    }

    const intentId = request.headers.get("x-upload-intent-id");
    const uploadToken = request.headers.get("x-upload-token");
    if (
      !UUID.test(intentId ?? "") ||
      !/^[A-Za-z0-9_-]{43}$/.test(uploadToken ?? "")
    )
      return json(400, { error: "invalid_request" });
    const bytes = await readLimited(request, HARD_FILE_LIMIT);
    if (!bytes) return json(413, { error: "file_too_large" });
    const tokenHash = await digestHex(new TextEncoder().encode(uploadToken));
    let claim;
    try {
      claim = await rpc("server_claim_case_file_upload_for_actor", {
        p_actor: auth.actor.id,
        p_intent_id: intentId,
        p_token_hash_hex: tokenHash,
      });
    } catch (error) {
      return errorCode(error) === "42501" ||
        errorCode(error) === "invalid_upload_intent"
        ? json(403, { error: "upload_not_allowed" })
        : json(503, { error: "case_evidence_unavailable" });
    }
    const contentType = request.headers
      .get("content-type")
      ?.split(";", 1)[0]
      ?.trim()
      .toLowerCase();
    const problem =
      bytes.byteLength !== claim.size_bytes
        ? "size_mismatch"
        : contentType !== claim.content_type
          ? "content_type_mismatch"
          : signatureCheck(bytes, claim.content_type);
    if (claim.already_finalized) {
      return (await digestHex(bytes)) === claim.sha256_hex && !problem
        ? json(200, {
            evidence_number: claim.evidence_number,
            safety_state: claim.safety_state,
            reviewable: false,
          })
        : json(409, { error: "upload_replay_conflict" });
    }
    if (problem) {
      await rpc("server_reject_case_file_upload_for_actor", {
        p_actor: auth.actor.id,
        p_intent_id: intentId,
        p_reason_code:
          problem === "active_content_marker" ? "signature_mismatch" : problem,
      }).catch(() => null);
      return json(problem === "size_mismatch" ? 400 : 415, {
        error: "file_rejected",
      });
    }
    try {
      await storeUpload("case-evidence-quarantine", claim.object_key, bytes, {
        contentType: claim.content_type,
        cacheControl: "0",
        upsert: false,
      });
      const stored = await readUpload(
        "case-evidence-quarantine",
        claim.object_key,
      );
      if (
        stored.byteLength !== claim.size_bytes ||
        signatureCheck(stored, claim.content_type) ||
        (await digestHex(stored)) !== (await digestHex(bytes))
      )
        throw new Error("stored_content_mismatch");
      const result = await rpc("server_finalize_case_file_upload_for_actor", {
        p_actor: auth.actor.id,
        p_intent_id: intentId,
        p_size_bytes: stored.byteLength,
        p_content_type: claim.content_type,
        p_sha256_hex: await digestHex(stored),
      });
      return json(200, result);
    } catch {
      const finalized = await rpc("server_claim_case_file_upload_for_actor", {
        p_actor: auth.actor.id,
        p_intent_id: intentId,
        p_token_hash_hex: tokenHash,
      }).catch(() => null);
      if (
        finalized?.already_finalized &&
        finalized.sha256_hex === (await digestHex(bytes)) &&
        !problem
      )
        return json(200, {
          evidence_number: finalized.evidence_number,
          safety_state: finalized.safety_state,
          reviewable: false,
        });
      await removeUpload("case-evidence-quarantine", claim.object_key).catch(
        () => null,
      );
      await rpc("server_reject_case_file_upload_for_actor", {
        p_actor: auth.actor.id,
        p_intent_id: intentId,
        p_reason_code: "stored_content_mismatch",
      }).catch(() => null);
      return json(503, { error: "case_evidence_unavailable" });
    }
  };
}
