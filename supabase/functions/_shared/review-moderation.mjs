const UUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
const MAX_BODY_BYTES = 8192;

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
    const normalized = part.replaceAll("-", "+").replaceAll("_", "/");
    return JSON.parse(
      atob(normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=")),
    );
  } catch {
    return null;
  }
}

function validTimestamp(value) {
  return (
    typeof value === "string" &&
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(
      value,
    ) &&
    Number.isFinite(Date.parse(value)) &&
    value.length <= 40
  );
}

function fail(status, code, requestId) {
  return json(status, { error: { code } }, requestId);
}

function errorResponse(error, requestId) {
  if (error?.code === "42501")
    return fail(403, "review_moderation_denied", requestId);
  if (error?.code === "P0002") return fail(404, "review_not_found", requestId);
  if (error?.message === "review_moderation_requires_report")
    return fail(409, "review_moderation_requires_report", requestId);
  if (error?.message === "idempotency_conflict")
    return fail(409, "idempotency_conflict", requestId);
  if (error?.message === "review_already_hidden")
    return fail(409, "review_already_hidden", requestId);
  if (error?.code === "P0001")
    return fail(409, "review_moderation_conflict", requestId);
  if (["22023", "22P02", "23514"].includes(error?.code))
    return fail(400, "invalid_review_moderation_request", requestId);
  return fail(503, "review_moderation_unavailable", requestId);
}

export function createReviewModerationHandler({
  verifyActor,
  rpc,
  requestId = () => crypto.randomUUID(),
}) {
  if (typeof verifyActor !== "function" || typeof rpc !== "function")
    throw new Error("review moderation dependencies are not configured");

  return async (request) => {
    const id = requestId();
    if (request.method !== "POST") return fail(405, "invalid_request", id);
    const token = request.headers
      .get("authorization")
      ?.replace(/^Bearer\s+/i, "");
    if (!token) return fail(401, "authentication_required", id);
    const actor = await verifyActor(token).catch(() => null);
    if (!actor || !UUID.test(actor.id ?? ""))
      return fail(401, "authentication_required", id);
    const authAal = claimsFrom(token)?.aal;
    if (authAal !== "aal2") return fail(403, "review_moderation_denied", id);

    let input;
    try {
      if (
        !request.headers
          .get("content-type")
          ?.toLowerCase()
          .startsWith("application/json")
      )
        return fail(400, "invalid_request", id);
      const body = await request.text();
      if (new TextEncoder().encode(body).byteLength > MAX_BODY_BYTES)
        return fail(413, "request_too_large", id);
      input = JSON.parse(body);
    } catch {
      return fail(400, "invalid_request", id);
    }
    if (!input || typeof input !== "object" || Array.isArray(input))
      return fail(400, "invalid_request", id);

    let name;
    let args;
    if (
      input.action === "list_reported" &&
      Object.keys(input).every((key) =>
        ["action", "before_reported_at", "before_review_id"].includes(key),
      ) &&
      ((input.before_reported_at === undefined &&
        input.before_review_id === undefined) ||
        (validTimestamp(input.before_reported_at) &&
          UUID.test(input.before_review_id ?? "")))
    ) {
      name = "server_list_review_moderation_queue_for_actor";
      args = {
        p_actor: actor.id,
        p_auth_aal: authAal,
        p_before_reported_at: input.before_reported_at ?? null,
        p_before_review_id: input.before_review_id ?? null,
        p_limit: 21,
      };
    } else if (
      input.action === "hide" &&
      Object.keys(input).every((key) =>
        ["action", "review_id", "reason", "idempotency_key"].includes(key),
      ) &&
      UUID.test(input.review_id ?? "") &&
      typeof input.reason === "string" &&
      input.reason.trim().length >= 20 &&
      input.reason.trim().length <= 500 &&
      UUID.test(input.idempotency_key ?? "")
    ) {
      name = "server_hide_assignment_review_for_actor";
      args = {
        p_actor: actor.id,
        p_review_id: input.review_id,
        p_reason: input.reason.trim(),
        p_auth_aal: authAal,
        p_idempotency_key: input.idempotency_key,
      };
    } else {
      return fail(400, "invalid_review_moderation_request", id);
    }

    try {
      const result = await rpc(name, args);
      return json(200, { result }, id);
    } catch (error) {
      return errorResponse(error, id);
    }
  };
}
