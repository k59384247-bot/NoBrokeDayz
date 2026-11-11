const UUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
const HEADERS = {
  "cache-control": "no-store",
  "content-type": "application/json; charset=utf-8",
};
const json = (status, body) =>
  new Response(JSON.stringify(body), { status, headers: HEADERS });

function verifiedClaims(token) {
  const part = token.split(".")[1];
  if (!part || !/^[A-Za-z0-9_-]+$/.test(part)) return null;
  try {
    const base64 = part.replaceAll("-", "+").replaceAll("_", "/");
    const claims = JSON.parse(
      atob(base64.padEnd(Math.ceil(base64.length / 4) * 4, "=")),
    );
    return { sub: claims.sub, aal: claims.aal };
  } catch {
    return null;
  }
}

export function createIdentityStaffHandler({ verifyActor, command }) {
  if (typeof verifyActor !== "function" || typeof command !== "function")
    throw new Error("identity staff dependencies are not configured");
  return async (request) => {
    if (request.method !== "POST")
      return json(405, { error: "method_not_allowed" });
    const token = request.headers
      .get("authorization")
      ?.replace(/^Bearer\s+/i, "");
    if (!token) return json(401, { error: "authentication_required" });
    const actor = await verifyActor(token).catch(() => null);
    const claims = verifiedClaims(token);
    if (
      !actor ||
      !UUID.test(actor.id ?? "") ||
      !claims ||
      claims.sub !== actor.id ||
      !["aal1", "aal2"].includes(claims.aal)
    )
      return json(401, { error: "authentication_required" });
    if (claims.aal !== "aal2")
      return json(403, { error: "staff_access_denied" });
    let input;
    try {
      const body = await request.text();
      if (new TextEncoder().encode(body).byteLength > 4096)
        return json(413, { error: "request_too_large" });
      input = JSON.parse(body);
    } catch {
      return json(400, { error: "invalid_request" });
    }
    const allowed = ["action", "subject_id", "reason", "idempotency_key"];
    if (
      !input ||
      typeof input !== "object" ||
      Array.isArray(input) ||
      Object.keys(input).some((key) => !allowed.includes(key)) ||
      !["suspend", "unsuspend"].includes(input.action) ||
      !UUID.test(input.subject_id ?? "") ||
      !UUID.test(input.idempotency_key ?? "") ||
      typeof input.reason !== "string" ||
      input.reason.trim().length < 20 ||
      input.reason.trim().length > 500
    )
      return json(400, { error: "invalid_request" });
    try {
      const result = await command("server_set_identity_suspension_for_actor", {
        p_actor: actor.id,
        p_subject: input.subject_id,
        p_suspended: input.action === "suspend",
        p_reason: input.reason.trim(),
        p_idempotency_key: input.idempotency_key,
        p_auth_aal: claims.aal,
      });
      if (result?.error === "idempotency_conflict")
        return json(409, { error: "stale_state" });
      return json(200, { result });
    } catch (error) {
      if (error?.code === "42501" || error?.code === "staff_access_denied")
        return json(403, { error: "staff_access_denied" });
      if (error?.code === "identity_unavailable")
        return json(404, { error: "identity_unavailable" });
      if (error?.code === "idempotency_conflict")
        return json(409, { error: "stale_state" });
      return json(503, { error: "identity_command_unavailable" });
    }
  };
}
