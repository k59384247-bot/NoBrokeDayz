const UUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
const STATUSES = new Set(["permanent_failure", "unknown", "exhausted"]);
const NOTICE_TYPES = new Set([
  "application_received",
  "application_accepted",
  "application_rejected",
  "application_withdrawn",
  "application_closed",
  "assignment_started",
  "assignment_submitted",
  "assignment_completed",
  "assignment_hold_opened",
  "assignment_case_decision",
  "assignment_case_finalized",
  "assignment_reminder_24h",
  "assignment_reminder_48h",
  "assignment_dispute_guidance_72h",
  "slot_refund_authorized",
  "assignment_cancellation_requested",
  "assignment_cancellation_completed",
  "assignment_abandoned",
  "withdrawal_requested",
  "withdrawal_processing",
  "withdrawal_unknown",
  "withdrawal_paid",
  "withdrawal_failed",
  "withdrawal_reversed",
  "withdrawal_exception",
  "refund_processing",
  "refund_unknown",
  "refund_settled",
  "refund_failed",
  "refund_exception",
  "refund_reversal_review",
  "verification_submitted",
  "verification_approved",
  "verification_not_approved",
  "verification_revoked",
]);
const ERRORS = new Set([
  "recipient_unavailable",
  "capture_rejected",
  "capture_unavailable",
  "ambiguous_result",
  "lease_expired",
  "max_attempts_exhausted",
  "eligibility_check_unavailable",
]);

function json(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "cache-control": "no-store",
      "content-type": "application/json; charset=utf-8",
    },
  });
}

function claims(token) {
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

function encodeCursor(cursor) {
  if (cursor === null) return null;
  if (
    !cursor ||
    typeof cursor.updated_at !== "string" ||
    !Number.isFinite(Date.parse(cursor.updated_at)) ||
    !UUID.test(cursor.id ?? "")
  )
    throw new Error("invalid_delivery_cursor");
  return btoa(
    JSON.stringify({
      version: 1,
      updated_at: new Date(cursor.updated_at).toISOString(),
      id: cursor.id,
    }),
  )
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
}

function decodeCursor(value) {
  if (value === undefined || value === null)
    return { updatedAt: null, id: null };
  if (typeof value !== "string" || value.length > 512)
    throw new Error("invalid_delivery_cursor");
  let cursor;
  try {
    const normalized = value.replaceAll("-", "+").replaceAll("_", "/");
    cursor = JSON.parse(
      atob(normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=")),
    );
  } catch {
    throw new Error("invalid_delivery_cursor");
  }
  if (
    cursor?.version !== 1 ||
    typeof cursor.updated_at !== "string" ||
    !Number.isFinite(Date.parse(cursor.updated_at)) ||
    !UUID.test(cursor.id ?? "")
  )
    throw new Error("invalid_delivery_cursor");
  return {
    updatedAt: new Date(cursor.updated_at).toISOString(),
    id: cursor.id,
  };
}

function safeItem(row) {
  if (
    !row ||
    !UUID.test(row.delivery_id ?? "") ||
    !UUID.test(row.recipient_id ?? "") ||
    !NOTICE_TYPES.has(row.notification_type) ||
    !STATUSES.has(row.status) ||
    !Number.isInteger(row.attempt_count) ||
    row.attempt_count < 0 ||
    row.attempt_count > 5 ||
    (row.safe_error_code !== null &&
      (typeof row.safe_error_code !== "string" ||
        !ERRORS.has(row.safe_error_code))) ||
    !Number.isFinite(Date.parse(row.created_at ?? "")) ||
    !Number.isFinite(Date.parse(row.updated_at ?? ""))
  )
    throw new Error("invalid_delivery_projection");
  return {
    delivery_id: row.delivery_id,
    recipient_id: row.recipient_id,
    notification_type: row.notification_type,
    status: row.status,
    attempt_count: row.attempt_count,
    safe_error_code: row.safe_error_code,
    created_at: new Date(row.created_at).toISOString(),
    updated_at: new Date(row.updated_at).toISOString(),
  };
}

export function createNotificationDeliveryOpsHandler({ verifyActor, rpc }) {
  if (typeof verifyActor !== "function" || typeof rpc !== "function")
    throw new Error(
      "notification delivery ops dependencies are not configured",
    );
  return async (request) => {
    if (request.method !== "POST")
      return json(405, { error: "method_not_allowed" });
    const token = request.headers
      .get("authorization")
      ?.match(/^Bearer\s+([^\s]+)$/i)?.[1];
    if (!token) return json(401, { error: "authentication_required" });
    const actor = await verifyActor(token).catch(() => null);
    const tokenClaims = claims(token);
    if (
      !actor ||
      !UUID.test(actor.id ?? "") ||
      tokenClaims?.sub !== actor.id ||
      !["aal1", "aal2"].includes(tokenClaims?.aal)
    )
      return json(401, { error: "authentication_required" });
    if (tokenClaims.aal !== "aal2")
      return json(403, { error: "delivery_access_denied" });
    let input;
    try {
      const body = await request.text();
      if (new TextEncoder().encode(body).byteLength > 4096)
        return json(413, { error: "request_too_large" });
      input = JSON.parse(body);
    } catch {
      return json(400, { error: "invalid_request" });
    }
    if (
      !input ||
      typeof input !== "object" ||
      Array.isArray(input) ||
      input.action !== "list" ||
      Object.keys(input).some((key) => !["action", "cursor"].includes(key))
    )
      return json(400, { error: "invalid_request" });
    try {
      const cursor = decodeCursor(input.cursor);
      const result = await rpc(
        "server_list_notification_delivery_attention_for_actor",
        {
          p_actor: actor.id,
          p_auth_aal: tokenClaims.aal,
          p_before_updated_at: cursor.updatedAt,
          p_before_delivery_id: cursor.id,
        },
      );
      const items = result?.items;
      if (!Array.isArray(items) || items.length > 50)
        throw new Error("invalid_delivery_projection");
      return json(200, {
        data: {
          items: items.map(safeItem),
          next_cursor: encodeCursor(result?.next_cursor ?? null),
        },
      });
    } catch (error) {
      if (error?.message === "invalid_delivery_cursor")
        return json(400, { error: "invalid_cursor" });
      if (error?.code === "42501" || error?.code === "staff_access_denied")
        return json(403, { error: "delivery_access_denied" });
      return json(503, { error: "delivery_status_unavailable" });
    }
  };
}
