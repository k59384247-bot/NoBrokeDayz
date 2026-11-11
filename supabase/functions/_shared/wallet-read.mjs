const UUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
const KOBO = /^(0|[1-9][0-9]{0,18})$/;
const MAX_BIGINT = 9223372036854775807n;
const WALLET_STATUSES = new Set([
  "queued_for_liquidity",
  "processing",
  "unknown",
  "paid",
  "failed",
  "reversed",
  "exception",
]);
const ACTIVITY_TYPES = new Set([
  "earnings_released",
  "assignment_held",
  "withdrawal_requested",
  "withdrawal_paid",
  "withdrawal_failed",
  "withdrawal_reversed",
  "poster_principal_funded",
]);
const REFUND_PAYABLE_SOURCES = new Set(["unassigned_slot", "mutual_prestart"]);
const MAX_BODY_BYTES = 4096;

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

function fail(status, code, requestId, message) {
  return json(
    status,
    {
      error: {
        code,
        message: message ?? "This wallet request could not be completed.",
      },
    },
    requestId,
  );
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function validKobo(value) {
  return (
    typeof value === "string" && KOBO.test(value) && BigInt(value) <= MAX_BIGINT
  );
}

function isTimestamp(value) {
  return typeof value === "string" && Number.isFinite(Date.parse(value));
}

function cursorValues(cursor) {
  if (cursor === undefined) return { createdAt: null, id: null };
  if (typeof cursor !== "string" || cursor.length > 512)
    throw new Error("invalid_wallet_cursor");
  let value;
  try {
    const normalized = cursor.replaceAll("-", "+").replaceAll("_", "/");
    value = JSON.parse(
      atob(normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=")),
    );
  } catch {
    throw new Error("invalid_wallet_cursor");
  }
  if (
    !isObject(value) ||
    value.version !== 1 ||
    !isTimestamp(value.created_at) ||
    !UUID.test(value.id ?? "")
  )
    throw new Error("invalid_wallet_cursor");
  return { createdAt: new Date(value.created_at).toISOString(), id: value.id };
}

function safeDestination(row) {
  if (row === null) return null;
  if (
    !isObject(row) ||
    !UUID.test(row.destination_id ?? "") ||
    !Number.isInteger(row.destination_version) ||
    row.destination_version < 1 ||
    typeof row.institution_label !== "string" ||
    row.institution_label.length > 80 ||
    typeof row.recipient_label !== "string" ||
    row.recipient_label.length > 80 ||
    typeof row.masked_reference !== "string" ||
    row.masked_reference.length > 32 ||
    row.ownership_verification !== "simulator_only"
  )
    throw new Error("invalid_wallet_projection");
  return {
    destination_id: row.destination_id,
    destination_version: row.destination_version,
    institution_label: row.institution_label,
    recipient_label: row.recipient_label,
    masked_reference: row.masked_reference,
    ownership_verification: "simulator_only",
  };
}

function safeWithdrawal(row) {
  if (
    !isObject(row) ||
    !UUID.test(row.withdrawal_id ?? "") ||
    !WALLET_STATUSES.has(row.status) ||
    !validKobo(row.amount_kobo) ||
    !UUID.test(row.destination_id ?? "") ||
    !Number.isInteger(row.destination_version) ||
    row.destination_version < 1 ||
    typeof row.institution_label !== "string" ||
    typeof row.recipient_label !== "string" ||
    typeof row.masked_reference !== "string" ||
    !isTimestamp(row.created_at) ||
    !isTimestamp(row.updated_at)
  )
    throw new Error("invalid_wallet_projection");
  return {
    withdrawal_id: row.withdrawal_id,
    status: row.status,
    amount_kobo: row.amount_kobo,
    currency: "NGN",
    destination_id: row.destination_id,
    destination_version: row.destination_version,
    destination: {
      institution_label: row.institution_label,
      recipient_label: row.recipient_label,
      masked_reference: row.masked_reference,
      ownership_verification: "simulator_only",
    },
    created_at: new Date(row.created_at).toISOString(),
    updated_at: new Date(row.updated_at).toISOString(),
  };
}

function safeActivity(row) {
  if (
    !isObject(row) ||
    !UUID.test(row.activity_id ?? "") ||
    !ACTIVITY_TYPES.has(row.activity_type) ||
    !validKobo(row.amount_kobo) ||
    (row.commission_kobo !== null && !validKobo(row.commission_kobo)) ||
    (row.status !== null && !WALLET_STATUSES.has(row.status)) ||
    !isTimestamp(row.created_at)
  )
    throw new Error("invalid_wallet_projection");
  return {
    activity_id: row.activity_id,
    activity_type: row.activity_type,
    amount_kobo: row.amount_kobo,
    commission_kobo: row.commission_kobo,
    status: row.status,
    created_at: new Date(row.created_at).toISOString(),
  };
}

function safeRefundPayable(row) {
  if (
    !isObject(row) ||
    !UUID.test(row.refund_payable_id ?? "") ||
    !UUID.test(row.allocation_id ?? "") ||
    !validKobo(row.amount_kobo) ||
    row.status !== "authorized" ||
    !REFUND_PAYABLE_SOURCES.has(row.source) ||
    !isTimestamp(row.created_at)
  )
    throw new Error("invalid_wallet_projection");
  return {
    refund_payable_id: row.refund_payable_id,
    allocation_id: row.allocation_id,
    amount_kobo: row.amount_kobo,
    status: "authorized",
    source: row.source,
    created_at: new Date(row.created_at).toISOString(),
  };
}

function safeWallet(row) {
  const balanceKeys = [
    "available_earnings_kobo",
    "held_allocations_kobo",
    "case_held_kobo",
    "withdrawal_reserved_kobo",
    "withdrawal_queued_kobo",
    "withdrawal_processing_kobo",
    "withdrawal_unknown_kobo",
    "poster_held_principal_kobo",
    "poster_refund_payable_kobo",
  ];
  if (
    !isObject(row) ||
    row.currency !== "NGN" ||
    !isObject(row.balances) ||
    balanceKeys.some((key) => !validKobo(row.balances[key])) ||
    !Array.isArray(row.withdrawals) ||
    row.withdrawals.length > 20 ||
    !Array.isArray(row.refund_payables) ||
    row.refund_payables.length > 20 ||
    !Array.isArray(row.activity) ||
    row.activity.length > 20 ||
    (row.next_cursor !== null && typeof row.next_cursor !== "string")
  )
    throw new Error("invalid_wallet_projection");

  return {
    currency: "NGN",
    balances: Object.fromEntries(
      balanceKeys.map((key) => [key, row.balances[key]]),
    ),
    destination: safeDestination(row.destination),
    withdrawals: row.withdrawals.map(safeWithdrawal),
    refund_payables: row.refund_payables.map(safeRefundPayable),
    activity: row.activity.map(safeActivity),
    next_cursor: row.next_cursor,
    refunds_available: false,
  };
}

function databaseStatus(error) {
  if (error?.message === "wallet_access_denied" || error?.code === "42501")
    return [403, "permission_denied"];
  if (error?.message === "invalid_wallet_cursor" || error?.code === "22023")
    return [400, "invalid_request"];
  if (error?.message === "wallet_not_found" || error?.code === "P0002")
    return [404, "not_found"];
  return [503, "wallet_unavailable"];
}

export function createWalletReadHandler({
  verifyActor,
  rpc,
  requestId = () => crypto.randomUUID(),
}) {
  if (typeof verifyActor !== "function" || typeof rpc !== "function")
    throw new Error("wallet read dependencies are not configured");

  return async (request) => {
    const id = requestId();
    if (request.method !== "POST") return fail(405, "invalid_request", id);
    const bearer = request.headers
      .get("authorization")
      ?.match(/^Bearer\s+([^\s]+)$/i)?.[1];
    if (!bearer) return fail(401, "authentication_required", id);
    const actor = await verifyActor(bearer).catch(() => null);
    if (!actor || !UUID.test(actor.id ?? ""))
      return fail(401, "authentication_required", id);

    let input;
    try {
      if (
        !request.headers
          .get("content-type")
          ?.toLowerCase()
          .startsWith("application/json")
      )
        return fail(400, "invalid_request", id);
      const raw = await request.text();
      if (new TextEncoder().encode(raw).byteLength > MAX_BODY_BYTES)
        return fail(413, "invalid_request", id);
      input = JSON.parse(raw);
    } catch {
      return fail(400, "invalid_request", id);
    }
    if (
      !isObject(input) ||
      Object.keys(input).some((key) => !["action", "cursor"].includes(key)) ||
      input.action !== "get_my_wallet"
    )
      return fail(400, "invalid_request", id);

    let cursor;
    try {
      cursor = cursorValues(input.cursor);
    } catch {
      return fail(400, "invalid_request", id);
    }
    try {
      const projection = await rpc("server_get_my_wallet_for_actor", {
        p_actor: actor.id,
        p_before_created_at: cursor.createdAt,
        p_before_id: cursor.id,
      });
      return json(200, { data: safeWallet(projection) }, id);
    } catch (error) {
      const [status, code] = databaseStatus(error);
      return fail(status, code, id);
    }
  };
}
