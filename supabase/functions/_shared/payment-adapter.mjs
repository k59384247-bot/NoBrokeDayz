const ALLOWED_STATUS = new Set([
  "pending",
  "processing",
  "unknown",
  "succeeded",
  "settled",
  "failed",
  "reversed",
]);
const UUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
const encoder = new TextEncoder();
export const DEFAULT_FAKE_MERCHANT_ID = "fake_nbd_local_merchant_v1";

function loopbackUrl(value, label) {
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new Error(`${label} is invalid`);
  }
  if (
    url.protocol !== "http:" ||
    !["127.0.0.1", "localhost", "[::1]"].includes(url.hostname) ||
    url.username ||
    url.password ||
    url.search ||
    url.hash
  )
    throw new Error(`${label} must use a plain loopback URL`);
  return url;
}

async function hmacHex(secret, value) {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, encoder.encode(value)),
  );
  return [...signature]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function safeAmount(value) {
  if (typeof value !== "string" || !/^[1-9][0-9]{0,11}$/.test(value))
    throw new Error("invalid_simulator_amount");
  if (BigInt(value) > 10000000000n) throw new Error("invalid_simulator_amount");
  return value;
}

function normalizeOperation(value, merchantIdentity) {
  if (
    !value ||
    typeof value !== "object" ||
    typeof value.reference !== "string" ||
    typeof value.clientReference !== "string" ||
    !["collection", "payout", "refund"].includes(value.operationType) ||
    !ALLOWED_STATUS.has(value.status) ||
    !/^(0|[1-9][0-9]{0,11})$/.test(value.feeKobo) ||
    !["pending", "available", "unknown"].includes(value.settlementStatus)
  )
    throw new Error("invalid_simulator_response");
  if (value.reference !== `sim-${value.clientReference}`) {
    const error = new Error("reference_mismatch");
    error.code = "reference_mismatch";
    throw error;
  }
  if (value.currency !== "NGN") {
    const error = new Error("currency_mismatch");
    error.code = "currency_mismatch";
    throw error;
  }
  if (
    value.operationType === "collection" &&
    (typeof value.merchantIdentity !== "string" ||
      value.merchantIdentity !== merchantIdentity)
  ) {
    const error = new Error("merchant_mismatch");
    error.code = "merchant_mismatch";
    throw error;
  }
  if (
    value.operationType === "payout" &&
    (!UUID.test(value.destinationId ?? "") ||
      !Number.isInteger(value.destinationVersion) ||
      value.destinationVersion < 1)
  ) {
    const error = new Error("destination_mismatch");
    error.code = "destination_mismatch";
    throw error;
  }
  if (
    value.operationType === "refund" &&
    !/^sim-[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(
      value.sourceReference ?? "",
    )
  ) {
    const error = new Error("source_reference_mismatch");
    error.code = "reference_mismatch";
    throw error;
  }
  try {
    safeAmount(value.amountKobo);
  } catch {
    const error = new Error("amount_mismatch");
    error.code = "amount_mismatch";
    throw error;
  }
  return {
    reference: value.reference,
    clientReference: value.clientReference,
    status: value.status,
    amountKobo: safeAmount(value.amountKobo),
    feeKobo: value.feeKobo,
    currency: value.currency,
    operationType: value.operationType,
    merchantIdentity: value.merchantIdentity ?? null,
    destinationId: value.destinationId ?? null,
    destinationVersion: value.destinationVersion ?? null,
    sourceReference: value.sourceReference ?? null,
    settlementStatus: value.settlementStatus,
  };
}

export function createLocalPaymentAdapter({
  mode,
  supabaseUrl,
  simulatorUrl,
  merchantIdentity = DEFAULT_FAKE_MERCHANT_ID,
  requestSecret,
  webhookSecret,
  fetchImpl = fetch,
}) {
  if (mode !== "local_simulator") throw new Error("unsupported payment mode");
  loopbackUrl(supabaseUrl, "local Supabase endpoint");
  const baseUrl = loopbackUrl(simulatorUrl, "loopback simulator endpoint");
  if (
    typeof requestSecret !== "string" ||
    requestSecret.length < 32 ||
    typeof webhookSecret !== "string" ||
    webhookSecret.length < 32
  )
    throw new Error("local simulator secrets are required");
  if (!/^fake_[a-z0-9_]{8,80}$/.test(merchantIdentity))
    throw new Error("local simulator merchant identity must be synthetic");

  async function request(method, path, body = "") {
    const timestamp = String(Math.floor(Date.now() / 1000));
    const digest = await hmacHex(
      requestSecret,
      `${timestamp}\n${method}\n${path}\n${body}`,
    );
    let response;
    try {
      response = await fetchImpl(new URL(path, baseUrl), {
        method,
        headers: {
          "content-type": "application/json",
          "x-simulator-timestamp": timestamp,
          "x-simulator-signature": digest,
        },
        body: method === "GET" ? undefined : body,
        signal: AbortSignal.timeout(5000),
      });
    } catch {
      const error = new Error("simulator_unavailable");
      error.code = "provider_timeout";
      throw error;
    }
    const payload = await response.json().catch(() => null);
    if (!response.ok) {
      const error = new Error(payload?.error ?? "simulator_unavailable");
      error.code =
        response.status === 409 ? "reference_mismatch" : "provider_unavailable";
      throw error;
    }
    if (payload?.found === false) return null;
    return normalizeOperation(payload, merchantIdentity);
  }

  async function create(path, input) {
    if (!input || typeof input !== "object")
      throw new Error("invalid_operation");
    safeAmount(input.amountKobo);
    if (
      input.currency !== "NGN" ||
      !UUID.test(input.idempotencyKey ?? "") ||
      !UUID.test(input.operationId ?? "")
    )
      throw new Error("invalid_operation");
    const collection = path.includes("collections");
    const refund = path.includes("refunds");
    const suppliedMerchant = input.merchantIdentity ?? merchantIdentity;
    if (collection && suppliedMerchant !== merchantIdentity) {
      const error = new Error("merchant_mismatch");
      error.code = "merchant_mismatch";
      throw error;
    }
    const body = JSON.stringify({
      operationId: input.operationId,
      clientReference: input.idempotencyKey,
      amountKobo: input.amountKobo,
      currency: input.currency,
      ...(collection ? { merchantIdentity: suppliedMerchant } : {}),
      ...(path.includes("payouts")
        ? {
            destinationId: input.destinationId,
            destinationVersion: input.destinationVersion,
          }
        : {}),
      ...(refund ? { sourceReference: input.sourceReference } : {}),
    });
    return request("POST", path, body);
  }

  async function lookupOriginalOperation(input) {
    if (!UUID.test(input?.idempotencyKey ?? ""))
      throw new Error("invalid_operation");
    return request(
      "GET",
      `/v1/operations/by-client-reference/${encodeURIComponent(input.idempotencyKey)}`,
    );
  }

  async function inspectLiquiditySnapshot() {
    const path = "/v1/liquidity";
    const timestamp = String(Math.floor(Date.now() / 1000));
    const digest = await hmacHex(requestSecret, `${timestamp}\nGET\n${path}\n`);
    let response;
    try {
      response = await fetchImpl(new URL(path, baseUrl), {
        method: "GET",
        headers: {
          "content-type": "application/json",
          "x-simulator-timestamp": timestamp,
          "x-simulator-signature": digest,
        },
        signal: AbortSignal.timeout(5000),
      });
    } catch {
      const error = new Error("simulator_unavailable");
      error.code = "provider_timeout";
      throw error;
    }
    const value = await response.json().catch(() => null);
    if (!response.ok) {
      const error = new Error("simulator_unavailable");
      error.code = "provider_unavailable";
      throw error;
    }
    const validKobo = (amount) =>
      typeof amount === "string" && /^(0|[1-9][0-9]{0,18})$/.test(amount);
    if (
      value?.currency !== "NGN" ||
      !validKobo(value.cashKobo) ||
      !validKobo(value.receivableKobo) ||
      BigInt(value.cashKobo) > 9223372036854775807n ||
      BigInt(value.receivableKobo) > 9223372036854775807n
    ) {
      const error = new Error("invalid_simulator_snapshot");
      error.code = "provider_unavailable";
      throw error;
    }
    return { cashKobo: value.cashKobo, receivableKobo: value.receivableKobo };
  }

  return Object.freeze({
    initializeCollection: (input) => create("/v1/collections", input),
    lookupOriginalOperation,
    createPayout(input) {
      if (
        !UUID.test(input.destinationId ?? "") ||
        !Number.isInteger(input.destinationVersion) ||
        input.destinationVersion < 1
      )
        throw new Error("invalid_destination");
      return create("/v1/payouts", input);
    },
    createRefund(input) {
      if (
        typeof input.sourceReference !== "string" ||
        !/^sim-[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(
          input.sourceReference,
        )
      )
        throw new Error("invalid_refund_source");
      return create("/v1/refunds", input);
    },
    lookupPayout: lookupOriginalOperation,
    lookupRefund: lookupOriginalOperation,
    inspectLiquiditySnapshot,
    verifyEvent: (rawBody, headers, now = Date.now()) =>
      verifySimulatorEvent(rawBody, headers, webhookSecret, now),
  });
}

export async function verifySimulatorEvent(
  rawBody,
  headers,
  secret,
  now = Date.now(),
) {
  const eventReference = headers.get("x-simulator-event-id") ?? "";
  const timestamp = headers.get("x-simulator-timestamp") ?? "";
  const signature = headers.get("x-simulator-signature") ?? "";
  if (
    !/^[A-Za-z0-9_-]{8,120}$/.test(eventReference) ||
    !/^\d{10}$/.test(timestamp) ||
    Math.abs(Math.floor(now / 1000) - Number(timestamp)) > 300 ||
    !/^[0-9a-f]{64}$/.test(signature)
  )
    return null;
  const expected = await hmacHex(
    secret,
    `${eventReference}.${timestamp}.${rawBody}`,
  );
  if (!crypto.subtle.timingSafeEqual) {
    let mismatch = 0;
    for (let index = 0; index < expected.length; index++)
      mismatch |= expected.charCodeAt(index) ^ signature.charCodeAt(index);
    if (mismatch !== 0) return null;
  } else if (
    !crypto.subtle.timingSafeEqual(
      encoder.encode(expected),
      encoder.encode(signature),
    )
  ) {
    return null;
  }
  let event;
  try {
    event = JSON.parse(rawBody);
  } catch {
    return null;
  }
  const allowed = [
    "eventReference",
    "clientReference",
    "operationReference",
    "status",
    "amountKobo",
    "currency",
  ];
  if (
    !event ||
    typeof event !== "object" ||
    Array.isArray(event) ||
    Object.keys(event).some((key) => !allowed.includes(key)) ||
    event.eventReference !== eventReference ||
    typeof event.clientReference !== "string" ||
    !UUID.test(event.clientReference) ||
    typeof event.operationReference !== "string" ||
    !ALLOWED_STATUS.has(event.status) ||
    !/^[0-9]{1,12}$/.test(event.amountKobo) ||
    event.currency !== "NGN"
  )
    return null;
  return event;
}
