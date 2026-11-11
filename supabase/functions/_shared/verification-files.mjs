const MAX_FILE_BYTES = 5_000_000;
const UPLOAD_TTL_SECONDS = 300;
const DOWNLOAD_TTL_SECONDS = 600;
const ALLOWED_TYPES = new Set(["image/jpeg", "image/png", "application/pdf"]);
const uuidPattern = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
const headers = {
  "cache-control": "no-store",
  "content-type": "application/json; charset=utf-8",
};

function json(status, body) {
  return new Response(JSON.stringify(body), { status, headers });
}

function digestHex(bytes) {
  return crypto.subtle
    .digest("SHA-256", bytes)
    .then((hash) =>
      [...new Uint8Array(hash)]
        .map((value) => value.toString(16).padStart(2, "0"))
        .join(""),
    );
}

function base64Url(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
}

function decodeBase64Url(value) {
  const base64 = value.replaceAll("-", "+").replaceAll("_", "/");
  return Uint8Array.from(
    atob(base64.padEnd(Math.ceil(base64.length / 4) * 4, "=")),
    (character) => character.charCodeAt(0),
  );
}

function validDownloadTarget(payload) {
  return (
    payload &&
    payload.bucket === "verification-private" &&
    ALLOWED_TYPES.has(payload.content_type) &&
    uuidPattern.test(payload.actor_id ?? "") &&
    uuidPattern.test(payload.evidence_id ?? "") &&
    typeof payload.object_key === "string" &&
    /^[0-9a-f-]{36}\/[0-9a-f-]{36}\/[0-9a-f-]{36}\/source$/i.test(
      payload.object_key,
    ) &&
    Number.isSafeInteger(payload.issued_at) &&
    Number.isSafeInteger(payload.expires_at) &&
    payload.expires_at > payload.issued_at &&
    payload.expires_at - payload.issued_at <= DOWNLOAD_TTL_SECONDS * 1000
  );
}

export function signatureCheck(bytes, contentType) {
  if (contentType === "image/png") {
    const signature = [137, 80, 78, 71, 13, 10, 26, 10];
    if (
      bytes.length < 45 ||
      signature.some((value, index) => bytes[index] !== value)
    )
      return "signature_mismatch";
    let offset = 8;
    let sawHeader = false;
    let sawData = false;
    while (offset + 12 <= bytes.length) {
      const length = new DataView(
        bytes.buffer,
        bytes.byteOffset + offset,
        4,
      ).getUint32(0);
      const chunkType = String.fromCharCode(
        ...bytes.subarray(offset + 4, offset + 8),
      );
      const next = offset + 12 + length;
      if (next > bytes.length) return "signature_mismatch";
      if (!sawHeader && chunkType !== "IHDR") return "signature_mismatch";
      if (chunkType === "IHDR") {
        if (sawHeader || length !== 13) return "signature_mismatch";
        sawHeader = true;
      }
      if (chunkType === "IDAT") sawData = true;
      if (chunkType === "IEND")
        return sawHeader && sawData && length === 0 && next === bytes.length
          ? null
          : "signature_mismatch";
      offset = next;
    }
    return "signature_mismatch";
  }
  if (contentType === "image/jpeg") {
    return bytes.length >= 4 &&
      bytes[0] === 0xff &&
      bytes[1] === 0xd8 &&
      bytes[2] === 0xff &&
      bytes.at(-2) === 0xff &&
      bytes.at(-1) === 0xd9
      ? null
      : "signature_mismatch";
  }
  if (contentType === "application/pdf") {
    const text = new TextDecoder("latin1").decode(bytes);
    if (!text.startsWith("%PDF-") || !/%%EOF\s*$/.test(text))
      return "signature_mismatch";
    if (/\/(?:JavaScript|JS|Launch|EmbeddedFiles|OpenAction|AA)\b/i.test(text))
      return "active_content_marker";
    return null;
  }
  return "signature_mismatch";
}

export async function readLimited(request, maxBytes) {
  const declared = Number(request.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > maxBytes) return null;
  const reader = request.body?.getReader();
  if (!reader) return new Uint8Array();
  const chunks = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > maxBytes) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

function parseBeginBody(value) {
  return (
    value &&
    typeof value === "object" &&
    !Array.isArray(value) &&
    Object.keys(value).length === 6 &&
    Object.keys(value).every((key) =>
      [
        "action",
        "submission_id",
        "evidence_position",
        "content_type",
        "size_bytes",
        "evidence_kind",
      ].includes(key),
    ) &&
    value.action === "begin_upload" &&
    uuidPattern.test(value.submission_id ?? "") &&
    Number.isInteger(value.evidence_position) &&
    value.evidence_position >= 1 &&
    value.evidence_position <= 3 &&
    ALLOWED_TYPES.has(value.content_type) &&
    [
      "student_id",
      "government_id",
      "campus_shop_location",
      "campus_staff_id",
    ].includes(value.evidence_kind) &&
    Number.isInteger(value.size_bytes) &&
    value.size_bytes >= 1 &&
    value.size_bytes <= MAX_FILE_BYTES
  );
}

export function createVerificationFilesHandler({
  verifyActor,
  command,
  storeUpload,
  readUpload,
  removeUpload,
  downloadSigningKey,
  downloadBaseUrl,
  now = () => Date.now(),
  randomToken = () => {
    const bytes = crypto.getRandomValues(new Uint8Array(32));
    return base64Url(bytes);
  },
}) {
  if (
    [verifyActor, command, storeUpload, readUpload, removeUpload].some(
      (item) => typeof item !== "function",
    )
  )
    throw new Error(
      "verification evidence server dependencies are not configured",
    );
  let downloadOrigin;
  try {
    const parsed = new URL(downloadBaseUrl);
    if (
      !/^https?:$/.test(parsed.protocol) ||
      parsed.username ||
      parsed.password
    )
      throw new Error("invalid URL");
    downloadOrigin = parsed.href.replace(/\/$/, "");
  } catch {
    throw new Error("verification download base URL is not configured");
  }

  const signingKeyBytes =
    typeof downloadSigningKey === "string"
      ? decodeBase64Url(downloadSigningKey)
      : downloadSigningKey;
  if (!signingKeyBytes || signingKeyBytes.byteLength < 32)
    throw new Error("verification download signing key is not configured");
  const signingKeyPromise = crypto.subtle.importKey(
    "raw",
    signingKeyBytes,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );

  async function makeDownloadToken(target) {
    const issuedAt = now();
    const payload = {
      bucket: target.storage_bucket,
      object_key: target.object_key,
      content_type: target.content_type,
      actor_id: target.actor_id,
      evidence_id: target.evidence_id,
      issued_at: issuedAt,
      expires_at: issuedAt + DOWNLOAD_TTL_SECONDS * 1000,
    };
    const encoded = base64Url(
      new TextEncoder().encode(JSON.stringify(payload)),
    );
    const signature = await crypto.subtle.sign(
      "HMAC",
      await signingKeyPromise,
      new TextEncoder().encode(encoded),
    );
    return `${encoded}.${base64Url(new Uint8Array(signature))}`;
  }

  async function verifyDownloadToken(token) {
    if (typeof token !== "string" || token.length > 2048) return null;
    const [encoded, signature, extra] = token.split(".");
    if (
      !encoded ||
      !signature ||
      extra ||
      !/^[A-Za-z0-9_-]+$/.test(encoded) ||
      !/^[A-Za-z0-9_-]{43}$/.test(signature)
    )
      return null;
    let payload;
    let verified = false;
    try {
      verified = await crypto.subtle.verify(
        "HMAC",
        await signingKeyPromise,
        decodeBase64Url(signature),
        new TextEncoder().encode(encoded),
      );
      payload = JSON.parse(new TextDecoder().decode(decodeBase64Url(encoded)));
    } catch {
      return null;
    }
    return verified &&
      validDownloadTarget(payload) &&
      payload.expires_at > now()
      ? payload
      : null;
  }

  return async function verificationEvidence(request) {
    if (
      request.method === "GET" &&
      new URL(request.url).pathname.endsWith("/download")
    ) {
      const payload = await verifyDownloadToken(
        new URL(request.url).searchParams.get("token"),
      );
      if (!payload) return json(403, { error: "download_unavailable" });
      try {
        const bytes = await readUpload(payload.bucket, payload.object_key);
        const recorded = await command(
          "server_record_verification_download_access_for_actor",
          {
            p_actor: payload.actor_id,
            p_evidence_id: payload.evidence_id,
            p_object_key: payload.object_key,
          },
        );
        if (recorded?.recorded !== true)
          return json(404, { error: "download_unavailable" });
        return new Response(bytes, {
          status: 200,
          headers: {
            "cache-control": "private, no-store",
            "content-disposition":
              'attachment; filename="verification-evidence"',
            "content-length": String(bytes.byteLength),
            "content-security-policy": "sandbox",
            "content-type": payload.content_type,
            "referrer-policy": "no-referrer",
            "x-content-type-options": "nosniff",
            "x-frame-options": "DENY",
          },
        });
      } catch {
        return json(404, { error: "download_unavailable" });
      }
    }
    if (request.method !== "POST" && request.method !== "PUT")
      return json(405, { error: "method_not_allowed" });
    const bearer = request.headers
      .get("authorization")
      ?.match(/^Bearer\s+([^\s]+)$/i)?.[1];
    if (!bearer) return json(401, { error: "authentication_required" });
    const auth = await verifyActor(bearer).catch(() => null);
    const actor = typeof auth === "string" ? auth : auth?.actor;
    const aal = typeof auth === "object" ? auth?.aal : null;
    if (!uuidPattern.test(actor ?? ""))
      return json(401, { error: "authentication_required" });

    if (request.method === "PUT") {
      const intentId = request.headers.get("x-upload-intent-id");
      const token = request.headers.get("x-upload-token");
      if (
        !uuidPattern.test(intentId ?? "") ||
        !/^[A-Za-z0-9_-]{43}$/.test(token ?? "")
      )
        return json(400, { error: "invalid_request" });
      const bytes = await readLimited(request, MAX_FILE_BYTES);
      if (!bytes) return json(413, { error: "file_too_large" });
      const tokenHash = await digestHex(new TextEncoder().encode(token));
      let claim;
      try {
        claim = await command("server_claim_verification_upload_for_actor", {
          p_actor: actor,
          p_intent_id: intentId,
          p_token_hash_hex: tokenHash,
        });
      } catch (error) {
        return error?.code === "invalid_upload_intent"
          ? json(403, { error: "upload_not_allowed" })
          : json(503, { error: "verification_unavailable" });
      }
      if (claim?.claimed !== true)
        return json(403, { error: "upload_not_allowed" });
      const declaredType = request.headers
        .get("content-type")
        ?.split(";", 1)[0]
        ?.trim()
        .toLowerCase();
      const reason =
        bytes.byteLength !== claim.size_bytes
          ? "size_mismatch"
          : declaredType !== claim.content_type
            ? "signature_mismatch"
            : signatureCheck(bytes, claim.content_type);
      if (reason) {
        await command("server_reject_verification_upload_for_actor", {
          p_actor: actor,
          p_intent_id: intentId,
          p_reason_code: reason,
        }).catch(() => null);
        return json(reason === "size_mismatch" ? 400 : 415, {
          error: "file_rejected",
        });
      }

      const bucket = "verification-quarantine";
      try {
        await storeUpload(bucket, claim.object_key, bytes, {
          contentType: claim.content_type,
          cacheControl: "0",
          upsert: false,
        });
        const stored = await readUpload(bucket, claim.object_key);
        if (
          stored.byteLength !== claim.size_bytes ||
          signatureCheck(stored, claim.content_type)
        ) {
          await removeUpload(bucket, claim.object_key).catch(() => null);
          await command("server_reject_verification_upload_for_actor", {
            p_actor: actor,
            p_intent_id: intentId,
            p_reason_code: "stored_content_mismatch",
          }).catch(() => null);
          return json(409, { error: "file_rejected" });
        }
        const result = await command(
          "server_finalize_verification_upload_for_actor",
          {
            p_actor: actor,
            p_intent_id: intentId,
            p_size_bytes: stored.byteLength,
            p_content_type: claim.content_type,
            p_sha256_hex: await digestHex(stored),
          },
        );
        return json(200, {
          evidence_id: result.evidence_id,
          safety_state: result.safety_state,
          reviewable: result.reviewable === true,
        });
      } catch {
        await removeUpload(bucket, claim.object_key).catch(() => null);
        await command("server_reject_verification_upload_for_actor", {
          p_actor: actor,
          p_intent_id: intentId,
          p_reason_code: "stored_content_mismatch",
        }).catch(() => null);
        return json(503, { error: "verification_unavailable" });
      }
    }

    let input;
    try {
      const raw = await request.text();
      if (new TextEncoder().encode(raw).byteLength > 2048)
        return json(413, { error: "request_too_large" });
      input = JSON.parse(raw);
    } catch {
      return json(400, { error: "invalid_request" });
    }
    if (parseBeginBody(input)) {
      const token = randomToken();
      if (!/^[A-Za-z0-9_-]{43}$/.test(token))
        return json(503, { error: "verification_unavailable" });
      try {
        const result = await command(
          "server_begin_verification_upload_for_actor",
          {
            p_actor: actor,
            p_submission_id: input.submission_id,
            p_evidence_position: input.evidence_position,
            p_content_type: input.content_type,
            p_size_bytes: input.size_bytes,
            p_token_hash_hex: await digestHex(new TextEncoder().encode(token)),
            p_evidence_kind: input.evidence_kind,
          },
        );
        return json(200, {
          upload_intent_id: result.intent_id,
          upload_token: token,
          expires_at: result.expires_at,
        });
      } catch (error) {
        return error?.code === "invalid_submission"
          ? json(404, { error: "submission_unavailable" })
          : json(503, { error: "verification_unavailable" });
      }
    }
    if (
      input &&
      typeof input === "object" &&
      !Array.isArray(input) &&
      Object.keys(input).length === 2 &&
      input.action === "signed_download" &&
      uuidPattern.test(input.evidence_id ?? "")
    ) {
      try {
        if (aal !== "aal2") return json(403, { error: "review_access_denied" });
        const target = await command(
          "server_get_verification_download_for_actor",
          {
            p_actor: actor,
            p_evidence_id: input.evidence_id,
            p_auth_aal: aal,
          },
        );
        if (target?.authorized !== true)
          return json(403, { error: "review_access_denied" });
        const token = await makeDownloadToken({ ...target, actor_id: actor });
        const link = new URL(`${downloadOrigin}/download`);
        link.searchParams.set("token", token);
        return json(200, {
          signed_url: link.href,
          expires_in_seconds: DOWNLOAD_TTL_SECONDS,
        });
      } catch (error) {
        return error?.code === "review_access_denied"
          ? json(403, { error: "review_access_denied" })
          : json(503, { error: "verification_unavailable" });
      }
    }
    return json(400, { error: "invalid_request" });
  };
}

export const verificationFilePolicy = Object.freeze({
  maxBytes: MAX_FILE_BYTES,
  uploadTtlSeconds: UPLOAD_TTL_SECONDS,
  downloadTtlSeconds: DOWNLOAD_TTL_SECONDS,
  allowedTypes: [...ALLOWED_TYPES],
});
