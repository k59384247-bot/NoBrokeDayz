import {
  confirmationTokenDigest,
  makeConfirmationToken as generateConfirmationToken,
} from "./financial-step-up.mjs";

const UUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
const KOBO = /^(0|[1-9][0-9]{0,18})$/;
const TOKEN = /^[0-9a-f]{64}$/;
const MAX_BIGINT = 9223372036854775807n;
const MAX_BODY_BYTES = 16 * 1024;
const WALLET_STATUSES = new Set([
  "queued_for_liquidity",
  "processing",
  "unknown",
  "paid",
  "failed",
  "reversed",
  "exception",
]);
const RECIPIENT_CODES = new Set([
  "fake_recipient_alpha",
  "fake_recipient_beta",
  "fake_recipient_gamma",
]);

const ERROR_MESSAGES = {
  authentication_required: "Sign in to continue.",
  confirmation_required: "Confirm your password and try again.",
  confirmation_expired: "This confirmation expired. Confirm again.",
  insufficient_available_balance: "The available balance changed.",
  verification_required: "Your account is not currently eligible for this.",
  permission_denied: "You do not have permission to do that.",
  not_found: "This item could not be found.",
  stale_state: "This item changed. Refresh and try again.",
  idempotency_conflict:
    "This request key was already used with different information.",
  invalid_request: "Check the request and try again.",
  service_unavailable:
    "This service is temporarily unavailable. Try again later.",
};

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
  return json(
    status,
    {
      error: {
        code,
        message: ERROR_MESSAGES[code] ?? ERROR_MESSAGES.service_unavailable,
      },
    },
    requestId,
  );
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function hasOnlyKeys(input, allowed) {
  return Object.keys(input).every((key) => allowed.has(key));
}

function validKobo(value, { positive = true } = {}) {
  if (
    typeof value !== "string" ||
    !KOBO.test(value) ||
    BigInt(value) > MAX_BIGINT ||
    (positive && value === "0")
  )
    return false;
  return true;
}

function validFee(value) {
  return validKobo(value, { positive: false });
}

function databaseError(error) {
  const message = error?.message ?? error?.code;
  if (message === "confirmation_expired") return [409, "confirmation_expired"];
  if (
    [
      "confirmation_required",
      "confirmation_invalid",
      "confirmation_consumed",
    ].includes(message)
  )
    return [409, "confirmation_required"];
  if (message === "insufficient_available_balance")
    return [409, "insufficient_available_balance"];
  if (message === "verification_required" || error?.code === "42501")
    return [403, "verification_required"];
  if (message === "destination_not_found" || error?.code === "P0002")
    return [404, "not_found"];
  if (message === "idempotency_conflict" || error?.code === "23505")
    return [409, "idempotency_conflict"];
  if (
    message === "stale_state" ||
    message === "destination_version_conflict" ||
    error?.code === "P0001"
  )
    return [409, "stale_state"];
  if (error?.code === "22023" || error?.code === "23514")
    return [400, "invalid_request"];
  return [503, "service_unavailable"];
}

function validDestinationChange(input) {
  return (
    hasOnlyKeys(
      input,
      new Set([
        "action",
        "destination_id",
        "expected_version",
        "simulated_recipient_code",
        "password",
      ]),
    ) &&
    (input.destination_id === null || UUID.test(input.destination_id ?? "")) &&
    Number.isInteger(input.expected_version) &&
    input.expected_version >= 0 &&
    (input.expected_version === 0
      ? input.destination_id === null
      : UUID.test(input.destination_id ?? "")) &&
    RECIPIENT_CODES.has(input.simulated_recipient_code) &&
    typeof input.password === "string" &&
    input.password.length > 0 &&
    input.password.length <= 1024
  );
}

function validWithdrawalAuthorization(input) {
  return (
    hasOnlyKeys(
      input,
      new Set([
        "action",
        "amount_kobo",
        "destination_id",
        "destination_version",
        "password",
      ]),
    ) &&
    validKobo(input.amount_kobo) &&
    UUID.test(input.destination_id ?? "") &&
    Number.isInteger(input.destination_version) &&
    input.destination_version > 0 &&
    typeof input.password === "string" &&
    input.password.length > 0 &&
    input.password.length <= 1024
  );
}

function validDestinationConfirmation(input) {
  return (
    hasOnlyKeys(
      input,
      new Set([
        "action",
        "authorization_token",
        "simulated_recipient_code",
        "idempotency_key",
      ]),
    ) &&
    TOKEN.test(input.authorization_token ?? "") &&
    RECIPIENT_CODES.has(input.simulated_recipient_code) &&
    UUID.test(input.idempotency_key ?? "")
  );
}

function validWithdrawalRequest(input) {
  return (
    hasOnlyKeys(
      input,
      new Set([
        "action",
        "amount_kobo",
        "destination_id",
        "destination_version",
        "authorization_token",
        "idempotency_key",
      ]),
    ) &&
    validKobo(input.amount_kobo) &&
    UUID.test(input.destination_id ?? "") &&
    Number.isInteger(input.destination_version) &&
    input.destination_version > 0 &&
    TOKEN.test(input.authorization_token ?? "") &&
    UUID.test(input.idempotency_key ?? "")
  );
}

function safeDestinationSummary(value) {
  if (
    !isObject(value) ||
    !UUID.test(value.destination_id ?? "") ||
    !Number.isInteger(value.destination_version) ||
    value.destination_version < 1 ||
    typeof value.institution_label !== "string" ||
    typeof value.recipient_label !== "string" ||
    typeof value.masked_reference !== "string" ||
    value.ownership_verification !== "simulator_only"
  )
    throw new Error("invalid_wallet_command_result");
  return {
    destination_id: value.destination_id,
    destination_version: value.destination_version,
    institution_label: value.institution_label,
    recipient_label: value.recipient_label,
    masked_reference: value.masked_reference,
    ownership_verification: "simulator_only",
  };
}

function safeAuthorization(value, token) {
  if (
    !isObject(value) ||
    !UUID.test(value.authorization_id ?? "") ||
    !UUID.test(value.destination_id ?? "") ||
    !Number.isInteger(value.destination_version) ||
    value.destination_version < 1 ||
    (value.amount_kobo !== null && !validKobo(value.amount_kobo)) ||
    typeof value.expires_at !== "string" ||
    !Number.isFinite(Date.parse(value.expires_at))
  )
    throw new Error("invalid_wallet_command_result");
  return {
    authorization_id: value.authorization_id,
    destination_id: value.destination_id,
    destination_version: value.destination_version,
    ...(value.amount_kobo === null ? {} : { amount_kobo: value.amount_kobo }),
    expires_at: new Date(value.expires_at).toISOString(),
    ...(value.destination_summary
      ? {
          destination: safeDestinationSummary({
            ...value.destination_summary,
            destination_id: value.destination_id,
            destination_version: value.destination_version,
          }),
        }
      : {}),
    authorization_token: token,
  };
}

function safeDestination(value) {
  if (
    !isObject(value) ||
    !UUID.test(value.destination_id ?? "") ||
    !Number.isInteger(value.destination_version) ||
    value.destination_version < 1 ||
    typeof value.created_at !== "string" ||
    !Number.isFinite(Date.parse(value.created_at))
  )
    throw new Error("invalid_wallet_command_result");
  return {
    destination_id: value.destination_id,
    destination_version: value.destination_version,
    institution_label: value.institution_label,
    recipient_label: value.recipient_label,
    masked_reference: value.masked_reference,
    ownership_verification: "simulator_only",
    created_at: new Date(value.created_at).toISOString(),
  };
}

function safeWithdrawal(value) {
  if (
    !isObject(value) ||
    !UUID.test(value.withdrawal_id ?? "") ||
    !WALLET_STATUSES.has(value.status) ||
    !validKobo(value.amount_kobo) ||
    !UUID.test(value.destination_id ?? "") ||
    !Number.isInteger(value.destination_version) ||
    value.destination_version < 1
  )
    throw new Error("invalid_wallet_command_result");
  return {
    withdrawal_id: value.withdrawal_id,
    status: value.status,
    amount_kobo: value.amount_kobo,
    currency: "NGN",
    destination_id: value.destination_id,
    destination_version: value.destination_version,
    ...(value.destination_summary
      ? {
          destination: safeDestinationSummary({
            ...value.destination_summary,
            destination_id: value.destination_id,
            destination_version: value.destination_version,
          }),
        }
      : {}),
  };
}

export function createWalletCommandHandler({
  verifyActor,
  verifyPassword,
  rpc,
  payoutFeeKobo = "0",
  makeConfirmationToken = generateConfirmationToken,
  hashConfirmationToken = confirmationTokenDigest,
  requestId = () => crypto.randomUUID(),
}) {
  if (
    typeof verifyActor !== "function" ||
    typeof verifyPassword !== "function" ||
    typeof rpc !== "function" ||
    !validFee(payoutFeeKobo)
  )
    throw new Error("wallet command dependencies are not configured");

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
    if (!isObject(input)) return fail(400, "invalid_request", id);

    try {
      if (
        input.action === "authorize_simulated_destination_change" &&
        validDestinationChange(input)
      ) {
        if (!(await verifyPassword(actor, input.password)))
          return fail(403, "confirmation_required", id);
        const token = makeConfirmationToken();
        const proofSha256Hex = await hashConfirmationToken(token);
        const authorization = await rpc(
          "server_authorize_simulated_destination_change_for_actor",
          {
            p_actor: actor.id,
            p_destination_id: input.destination_id,
            p_expected_version: input.expected_version,
            p_simulated_recipient_code: input.simulated_recipient_code,
            p_proof_sha256_hex: proofSha256Hex,
          },
        );
        return json(200, { data: safeAuthorization(authorization, token) }, id);
      }

      if (
        input.action === "confirm_simulated_destination_change" &&
        validDestinationConfirmation(input)
      ) {
        const destination = await rpc(
          "server_confirm_simulated_destination_change_for_actor",
          {
            p_actor: actor.id,
            p_proof_sha256_hex: await hashConfirmationToken(
              input.authorization_token,
            ),
            p_simulated_recipient_code: input.simulated_recipient_code,
            p_idempotency_key: input.idempotency_key,
          },
        );
        return json(200, { data: safeDestination(destination) }, id);
      }

      if (
        input.action === "authorize_withdrawal" &&
        validWithdrawalAuthorization(input)
      ) {
        if (!(await verifyPassword(actor, input.password)))
          return fail(403, "confirmation_required", id);
        const token = makeConfirmationToken();
        const authorization = await rpc(
          "server_authorize_withdrawal_for_actor",
          {
            p_actor: actor.id,
            p_amount_kobo: input.amount_kobo,
            p_destination_id: input.destination_id,
            p_destination_version: input.destination_version,
            p_proof_sha256_hex: await hashConfirmationToken(token),
          },
        );
        return json(200, { data: safeAuthorization(authorization, token) }, id);
      }

      if (
        input.action === "request_withdrawal" &&
        validWithdrawalRequest(input)
      ) {
        const withdrawal = await rpc("server_request_withdrawal_for_actor", {
          p_actor: actor.id,
          p_amount_kobo: input.amount_kobo,
          p_destination_id: input.destination_id,
          p_destination_version: input.destination_version,
          p_proof_sha256_hex: await hashConfirmationToken(
            input.authorization_token,
          ),
          p_expected_provider_fee_kobo: payoutFeeKobo,
          p_idempotency_key: input.idempotency_key,
        });
        return json(201, { data: safeWithdrawal(withdrawal) }, id);
      }

      return fail(400, "invalid_request", id);
    } catch (error) {
      const [status, code] = databaseError(error);
      return fail(status, code, id);
    }
  };
}
