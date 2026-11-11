const UUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
const SCOPES = new Set(["thread", "notifications", "case"]);

function json(status, body, requestId) {
  return new Response(JSON.stringify({ ...body, request_id: requestId }), {
    status,
    headers: {
      "cache-control": "no-store",
      "content-type": "application/json; charset=utf-8",
      "x-request-id": requestId,
    },
  });
}

function claimsFrom(token) {
  const part = token?.split(".")[1];
  if (!part || !/^[A-Za-z0-9_-]+$/.test(part)) return null;
  try {
    return JSON.parse(
      atob(
        part
          .replaceAll("-", "+")
          .replaceAll("_", "/")
          .padEnd(Math.ceil(part.length / 4) * 4, "="),
      ),
    );
  } catch {
    return null;
  }
}

export function createRealtimeTopicHandler({
  verifyActor,
  rpc,
  requestId = () => crypto.randomUUID(),
}) {
  if (typeof verifyActor !== "function" || typeof rpc !== "function")
    throw new Error("realtime topic dependencies are not configured");

  return async (request) => {
    const id = requestId();
    if (request.method !== "POST")
      return json(405, { error: { code: "method_not_allowed" } }, id);
    const token = request.headers
      .get("authorization")
      ?.replace(/^Bearer\s+/i, "");
    if (!token)
      return json(401, { error: { code: "authentication_required" } }, id);
    const actor = await verifyActor(token).catch(() => null);
    const claims = claimsFrom(token);
    if (!UUID.test(actor?.id ?? "") || claims?.sub !== actor.id)
      return json(401, { error: { code: "authentication_required" } }, id);

    let input;
    try {
      const body = await request.text();
      if (new TextEncoder().encode(body).byteLength > 2048)
        return json(413, { error: { code: "request_too_large" } }, id);
      input = JSON.parse(body);
    } catch {
      return json(400, { error: { code: "invalid_request" } }, id);
    }
    if (
      !input ||
      typeof input !== "object" ||
      Array.isArray(input) ||
      Object.keys(input).some(
        (key) => !["scope", "resource_id"].includes(key),
      ) ||
      !SCOPES.has(input.scope)
    )
      return json(400, { error: { code: "invalid_request" } }, id);
    if (
      (input.scope === "notifications" && input.resource_id !== undefined) ||
      (input.scope !== "notifications" && !UUID.test(input.resource_id ?? ""))
    )
      return json(400, { error: { code: "invalid_request" } }, id);

    try {
      const result = await rpc("server_get_realtime_topic_for_actor", {
        p_actor: actor.id,
        p_scope: input.scope,
        p_resource: input.resource_id ?? null,
        p_auth_aal: claims.aal === "aal2" ? "aal2" : "aal1",
      });
      if (
        typeof result?.topic !== "string" ||
        !result.topic.startsWith("nbd:") ||
        typeof result.event !== "string" ||
        result.private !== true
      )
        throw new Error("invalid_realtime_topic_projection");
      return json(200, { data: result }, id);
    } catch (error) {
      if (error?.code === "P0002" || error?.code === "realtime_topic_not_found")
        return json(404, { error: { code: "not_found" } }, id);
      if (
        error?.code === "22023" ||
        error?.code === "invalid_realtime_topic_request"
      )
        return json(400, { error: { code: "invalid_request" } }, id);
      return json(503, { error: { code: "realtime_topic_unavailable" } }, id);
    }
  };
}
