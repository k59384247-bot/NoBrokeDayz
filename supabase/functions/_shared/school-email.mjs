const headers = {
  "cache-control": "no-store",
  "content-type": "application/json; charset=utf-8",
};
const uuidPattern = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;

function json(status, body) {
  return new Response(JSON.stringify(body), { status, headers });
}

function validInput(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const allowed =
    value.action === "begin"
      ? ["action", "email", "idempotency_key"]
      : ["action", "challenge_id", "code"];
  if (Object.keys(value).some((key) => !allowed.includes(key))) return false;
  if (value.action === "begin")
    return (
      typeof value.email === "string" &&
      value.email.length <= 254 &&
      uuidPattern.test(value.idempotency_key ?? "")
    );
  return (
    value.action === "confirm" &&
    uuidPattern.test(value.challenge_id ?? "") &&
    /^\d{6}$/.test(value.code ?? "")
  );
}

function decodeBase64Url(value) {
  const base64 = value.replaceAll("-", "+").replaceAll("_", "/");
  return Uint8Array.from(
    atob(base64.padEnd(Math.ceil(base64.length / 4) * 4, "=")),
    (char) => char.charCodeAt(0),
  );
}

function randomSixDigitCode() {
  const limit = Math.floor(0x1_0000_0000 / 1_000_000) * 1_000_000;
  const bytes = new Uint32Array(1);
  do crypto.getRandomValues(bytes);
  while (bytes[0] >= limit);
  return String(bytes[0] % 1_000_000).padStart(6, "0");
}

export function createSchoolEmailHandler({
  hmacKey,
  verifyActor,
  command,
  deliver,
  randomCode = randomSixDigitCode,
}) {
  const key = typeof hmacKey === "string" ? decodeBase64Url(hmacKey) : hmacKey;
  if (!key || key.byteLength < 32)
    throw new Error("school challenge key is not configured");
  if (
    typeof verifyActor !== "function" ||
    typeof command !== "function" ||
    typeof deliver !== "function"
  )
    throw new Error("school challenge server dependencies are not configured");

  async function keyedDigest(code) {
    const keyObject = await crypto.subtle.importKey(
      "raw",
      key,
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"],
    );
    const bytes = await crypto.subtle.sign(
      "HMAC",
      keyObject,
      new TextEncoder().encode(code),
    );
    return [...new Uint8Array(bytes)]
      .map((value) => value.toString(16).padStart(2, "0"))
      .join("");
  }

  return async function schoolEmail(request) {
    if (request.method !== "POST")
      return json(405, { error: "method_not_allowed" });
    const bearer = request.headers
      .get("authorization")
      ?.match(/^Bearer\s+([^\s]+)$/i)?.[1];
    if (!bearer) return json(401, { error: "authentication_required" });
    let raw;
    try {
      raw = await request.text();
      if (new TextEncoder().encode(raw).byteLength > 2048)
        return json(413, { error: "request_too_large" });
      const input = JSON.parse(raw);
      if (!validInput(input)) return json(400, { error: "invalid_request" });
      const actor = await verifyActor(bearer);
      if (!uuidPattern.test(actor ?? ""))
        return json(401, { error: "authentication_required" });

      if (input.action === "begin") {
        const email = input.email.trim().toLowerCase();
        const code = randomCode();
        if (!/^\d{6}$/.test(code))
          return json(503, { error: "identity_unavailable" });
        const result = await command(
          "server_begin_school_challenge_for_actor",
          {
            p_actor: actor,
            p_email: email,
            p_code_digest: await keyedDigest(code),
            p_request_key: input.idempotency_key,
          },
        );
        if (!result?.issued)
          return json(200, {
            ...(result?.challenge_id
              ? { challenge_id: result.challenge_id }
              : {}),
            state: result?.state ?? "unavailable",
          });
        try {
          await deliver(email, code, {
            challengeId: result.challenge_id,
            actorId: actor,
          });
        } catch {
          await command("server_fail_school_challenge_for_actor", {
            p_actor: actor,
            p_challenge_id: result.challenge_id,
          }).catch(() => null);
          return json(503, { error: "delivery_unavailable" });
        }
        return json(200, {
          challenge_id: result.challenge_id,
          state: "pending",
        });
      }

      const result = await command(
        "server_confirm_school_challenge_for_actor",
        {
          p_actor: actor,
          p_challenge_id: input.challenge_id,
          p_code_digest: await keyedDigest(input.code),
        },
      );
      return json(200, result);
    } catch (error) {
      if (error?.code === "invalid_challenge")
        return json(400, { error: "invalid_challenge" });
      if (error?.code === "rate_limited")
        return json(429, { error: "rate_limited" });
      if (error?.code === "invalid_request")
        return json(400, { error: "invalid_request" });
      return json(503, { error: "identity_unavailable" });
    }
  };
}
