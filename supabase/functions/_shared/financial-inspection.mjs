const UUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
const MAX_BODY_BYTES = 4096;
const MAX_KOBO = 9223372036854775807n;
const REFERENCE_TYPES = new Set([
  "operation",
  "provider_reference",
  "funding_intent",
  "withdrawal",
  "journal",
  "job",
  "reconciliation_run",
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

function validKobo(value) {
  return (
    typeof value === "string" &&
    /^(0|[1-9][0-9]{0,18})$/.test(value) &&
    BigInt(value) <= MAX_KOBO
  );
}

export function createFinancialInspectionHandler({
  verifyActor,
  rpc,
  inspectSimulatorLiquidity,
  requestId = () => crypto.randomUUID(),
}) {
  if (
    typeof verifyActor !== "function" ||
    typeof rpc !== "function" ||
    typeof inspectSimulatorLiquidity !== "function"
  )
    throw new Error("financial inspection dependencies are not configured");

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
    if (claims.aal !== "aal2") return fail(403, "staff_access_denied", id);

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
      if (
        input.action === "trace" &&
        REFERENCE_TYPES.has(input.reference_type) &&
        (input.reference_type === "provider_reference"
          ? Object.keys(input).every((key) =>
              ["action", "reference_type", "reference"].includes(key),
            ) && /^sim-[0-9a-f-]{36}$/i.test(input.reference ?? "")
          : Object.keys(input).every((key) =>
              ["action", "reference_type", "reference_id"].includes(key),
            ) && UUID.test(input.reference_id ?? ""))
      ) {
        const data = await rpc("server_inspect_financial_reference_for_actor", {
          p_actor: actor.id,
          p_auth_aal: claims.aal,
          p_reference_type: input.reference_type,
          p_reference_value:
            input.reference_type === "provider_reference"
              ? input.reference
              : input.reference_id,
        });
        return json(200, { data }, id);
      }
      if (input.action === "reconcile" && Object.keys(input).length === 1) {
        const snapshot = await inspectSimulatorLiquidity();
        if (
          !validKobo(snapshot?.cashKobo) ||
          !validKobo(snapshot?.receivableKobo)
        )
          return fail(503, "simulator_reconciliation_unavailable", id);
        const data = await rpc("server_reconcile_financial_state_for_actor", {
          p_actor: actor.id,
          p_auth_aal: claims.aal,
          p_simulator_cash_kobo: snapshot.cashKobo,
          p_simulator_receivable_kobo: snapshot.receivableKobo,
        });
        return json(200, { data }, id);
      }
      return fail(400, "invalid_request", id);
    } catch (error) {
      if (
        error?.code === "42501" ||
        error?.code === "financial_inspection_denied"
      )
        return fail(403, "staff_access_denied", id);
      if (error?.code === "reference_not_found")
        return fail(404, "reference_not_found", id);
      return fail(503, "financial_inspection_unavailable", id);
    }
  };
}
