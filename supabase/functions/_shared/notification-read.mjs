const UUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
const MAX_BODY_BYTES = 4096;
const NOTICE_TITLES = Object.freeze({
  application_received: "New application",
  application_accepted: "Application accepted",
  application_rejected: "Application not selected",
  application_withdrawn: "Application withdrawn",
  application_closed: "Application closed",
  new_message: "New message",
  assignment_started: "Work started",
  assignment_submitted: "Work submitted",
  assignment_completed: "Work confirmed",
  assignment_hold_opened: "Review requested",
  assignment_case_updated: "Case status updated",
  assignment_case_decision: "Case decision available",
  assignment_case_finalized: "Case outcome finalized",
  assignment_reminder_24h: "Confirmation reminder",
  assignment_reminder_48h: "Confirmation reminder",
  assignment_dispute_guidance_72h: "Dispute route available",
  slot_refund_authorized: "Refund pending",
  refund_processing: "Refund processing",
  refund_unknown: "Refund status pending",
  refund_settled: "Provider settlement confirmed",
  refund_failed: "Refund needs follow up",
  refund_exception: "Refund needs review",
  refund_reversal_review: "Refund needs review",
  verification_submitted: "Verification received",
  verification_approved: "Verification approved",
  verification_not_approved: "Verification update",
  verification_revoked: "Verification update",
  assignment_cancellation_requested: "Cancellation requested",
  assignment_cancellation_completed: "Cancellation completed",
  assignment_abandoned: "Assignment ended early",
  withdrawal_requested: "Withdrawal requested",
  withdrawal_processing: "Withdrawal processing",
  withdrawal_unknown: "Withdrawal status pending",
  withdrawal_paid: "Withdrawal paid",
  withdrawal_failed: "Withdrawal failed",
  withdrawal_reversed: "Withdrawal reversed",
  withdrawal_exception: "Withdrawal needs review",
});
const DESTINATION_KINDS = new Set([
  "application",
  "thread",
  "assignment",
  "case",
  "wallet_item",
]);

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

function fail(status, code, requestId) {
  return json(status, { error: { code } }, requestId);
}

function verifiedClaims(token) {
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
    typeof cursor.created_at !== "string" ||
    !Number.isFinite(Date.parse(cursor.created_at)) ||
    !UUID.test(cursor.id ?? "")
  )
    throw new Error("invalid_notification_projection");
  return btoa(
    JSON.stringify({
      version: 1,
      created_at: new Date(cursor.created_at).toISOString(),
      id: cursor.id,
    }),
  )
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
}

function decodeCursor(value) {
  if (value === undefined) return { createdAt: null, id: null };
  if (typeof value !== "string" || value.length > 512)
    throw new Error("invalid_notification_cursor");
  let cursor;
  try {
    const normalized = value.replaceAll("-", "+").replaceAll("_", "/");
    cursor = JSON.parse(
      atob(normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=")),
    );
  } catch {
    throw new Error("invalid_notification_cursor");
  }
  if (
    cursor?.version !== 1 ||
    typeof cursor.created_at !== "string" ||
    !Number.isFinite(Date.parse(cursor.created_at)) ||
    !UUID.test(cursor.id ?? "")
  )
    throw new Error("invalid_notification_cursor");
  return {
    createdAt: new Date(cursor.created_at).toISOString(),
    id: cursor.id,
  };
}

function safeNotice(row) {
  const destinationKind = row?.destination_kind ?? null;
  const destinationId = row?.destination_id ?? null;
  if (
    !row ||
    !UUID.test(row.notification_id ?? "") ||
    !Object.hasOwn(NOTICE_TITLES, row.notification_type) ||
    typeof row.created_at !== "string" ||
    !Number.isFinite(Date.parse(row.created_at)) ||
    (row.read_at !== null &&
      (typeof row.read_at !== "string" ||
        !Number.isFinite(Date.parse(row.read_at)))) ||
    (destinationKind === null) !== (destinationId === null) ||
    (destinationKind !== null &&
      (!DESTINATION_KINDS.has(destinationKind) || !UUID.test(destinationId)))
  )
    throw new Error("invalid_notification_projection");
  return {
    notification_id: row.notification_id,
    notification_type: row.notification_type,
    title: NOTICE_TITLES[row.notification_type],
    created_at: new Date(row.created_at).toISOString(),
    read_at: row.read_at === null ? null : new Date(row.read_at).toISOString(),
    destination:
      destinationKind === null
        ? null
        : { kind: destinationKind, id: destinationId },
  };
}

export function createNotificationReadHandler({
  verifyActor,
  rpc,
  requestId = () => crypto.randomUUID(),
}) {
  if (typeof verifyActor !== "function" || typeof rpc !== "function")
    throw new Error("notification read dependencies are not configured");
  return async (request) => {
    const id = requestId();
    if (request.method !== "POST") return fail(405, "method_not_allowed", id);
    const token = request.headers
      .get("authorization")
      ?.replace(/^Bearer\s+/i, "");
    if (!token) return fail(401, "authentication_required", id);
    const actor = await verifyActor(token).catch(() => null);
    const claims = verifiedClaims(token);
    if (!actor || !UUID.test(actor.id ?? "") || claims?.sub !== actor.id)
      return fail(401, "authentication_required", id);

    let input;
    try {
      const body = await request.text();
      if (new TextEncoder().encode(body).byteLength > MAX_BODY_BYTES)
        return fail(413, "request_too_large", id);
      input = JSON.parse(body);
    } catch {
      return fail(400, "invalid_request", id);
    }
    if (!input || typeof input !== "object" || Array.isArray(input))
      return fail(400, "invalid_request", id);

    try {
      if (input.action === "list") {
        if (
          Object.keys(input).some((key) => !["action", "cursor"].includes(key))
        )
          return fail(400, "invalid_request", id);
        const cursor = decodeCursor(input.cursor);
        const result = await rpc("server_list_my_notifications_for_actor", {
          p_actor: actor.id,
          p_before_created_at: cursor.createdAt,
          p_before_id: cursor.id,
        });
        return json(
          200,
          {
            data: {
              notifications: (result?.notifications ?? []).map(safeNotice),
              next_cursor: encodeCursor(result?.next_cursor ?? null),
            },
          },
          id,
        );
      }
      if (
        input.action === "mark_read" &&
        Object.keys(input).every((key) =>
          ["action", "notification_id"].includes(key),
        ) &&
        UUID.test(input.notification_id ?? "")
      ) {
        const result = await rpc("server_mark_my_notification_read_for_actor", {
          p_actor: actor.id,
          p_notification_id: input.notification_id,
        });
        if (!result) return fail(404, "notice_not_found", id);
        return json(200, { data: safeNotice(result) }, id);
      }
      return fail(400, "invalid_request", id);
    } catch (error) {
      if (
        error?.code === "42501" ||
        error?.code === "notification_access_denied"
      )
        return fail(403, "notification_access_denied", id);
      if (error?.code === "invalid_notification_cursor")
        return fail(400, "invalid_cursor", id);
      return fail(503, "notification_read_unavailable", id);
    }
  };
}
