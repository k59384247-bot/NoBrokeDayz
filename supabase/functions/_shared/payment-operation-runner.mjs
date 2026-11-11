const FINAL = new Set(["succeeded", "settled", "failed", "reversed"]);

async function resultHash(result) {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(JSON.stringify(result)),
  );
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

async function completeWithResult(complete, operation, result, status, extra) {
  return complete({
    operationId: operation.operation_id,
    operationType: operation.operation_type,
    leaseToken: operation.lease_token,
    status,
    reference: result.reference,
    feeKobo: result.feeKobo,
    amountKobo: result.amountKobo,
    currency: result.currency,
    merchantIdentity: result.merchantIdentity,
    clientReference: result.clientReference,
    destinationId: result.destinationId,
    destinationVersion: result.destinationVersion,
    sourceReference: result.sourceReference,
    settlementStatus: result.settlementStatus,
    resultSha256Hex: await resultHash(result),
    ...extra,
  });
}

export async function runPaymentOperation({ claim, complete, adapter }) {
  const operation = await claim();
  if (!operation) return { claimed: false };
  const isCollection = operation.operation_type === "collection";
  const isRefund = operation.operation_type === "refund";
  if (!isCollection && !isRefund && operation.operation_type !== "payout")
    throw new Error("unsupported_payment_operation_type");
  const lookup = isCollection
    ? adapter.lookupOriginalOperation
    : isRefund
      ? adapter.lookupRefund
      : adapter.lookupPayout;
  const create = isCollection
    ? adapter.initializeCollection
    : isRefund
      ? adapter.createRefund
      : adapter.createPayout;
  let result;
  let providerError;
  try {
    result = await lookup({
      operationId: operation.operation_id,
      idempotencyKey: operation.provider_idempotency_key,
      reference: operation.provider_operation_reference,
    });
    if (!result) {
      result = await create({
        operationId: operation.operation_id,
        idempotencyKey: operation.provider_idempotency_key,
        amountKobo: operation.amount_kobo,
        currency: operation.currency,
        merchantIdentity: isCollection
          ? operation.merchant_identity
          : undefined,
        destinationId: operation.destination_id,
        destinationVersion: operation.destination_version,
        sourceReference: operation.source_provider_reference,
      });
    }
  } catch (error) {
    providerError = error;
  }
  if (providerError) {
    if (
      [
        "amount_mismatch",
        "currency_mismatch",
        "reference_mismatch",
        "merchant_mismatch",
        "destination_mismatch",
      ].includes(providerError?.code)
    ) {
      return await complete({
        operationId: operation.operation_id,
        operationType: operation.operation_type,
        leaseToken: operation.lease_token,
        status: "exception",
        safeErrorCode: providerError.code,
      });
    }
    return await complete({
      operationId: operation.operation_id,
      operationType: operation.operation_type,
      leaseToken: operation.lease_token,
      status: "unknown",
      safeErrorCode: "provider_timeout",
      retry: true,
    });
  }
  const mismatchCode =
    !result || result.clientReference !== operation.provider_idempotency_key
      ? "reference_mismatch"
      : result.amountKobo !== operation.amount_kobo
        ? "amount_mismatch"
        : result.currency !== operation.currency
          ? "currency_mismatch"
          : isCollection &&
              result.merchantIdentity !== operation.merchant_identity
            ? "merchant_mismatch"
            : isRefund &&
                result.sourceReference !== operation.source_provider_reference
              ? "reference_mismatch"
              : !isCollection &&
                  !isRefund &&
                  (result.destinationId !== operation.destination_id ||
                    result.destinationVersion !== operation.destination_version)
                ? "destination_mismatch"
                : null;
  if (mismatchCode) {
    if (!result)
      return await complete({
        operationId: operation.operation_id,
        operationType: operation.operation_type,
        leaseToken: operation.lease_token,
        status: "exception",
        safeErrorCode: mismatchCode,
      });
    return await completeWithResult(complete, operation, result, "exception", {
      safeErrorCode: mismatchCode,
    });
  }
  if (
    isRefund &&
    result.status === "succeeded" &&
    result.settlementStatus === "available"
  ) {
    return await completeWithResult(complete, operation, result, "settled", {
      safeErrorCode: null,
      retry: false,
    });
  }
  if (isRefund && result.status === "succeeded") {
    return await completeWithResult(complete, operation, result, "processing", {
      safeErrorCode: "settlement_pending",
      retry: true,
    });
  }
  if (!FINAL.has(result.status)) {
    return await completeWithResult(
      complete,
      operation,
      result,
      result.status === "unknown" ? "unknown" : "processing",
      {
        safeErrorCode:
          result.status === "unknown" ? "unknown_result" : "settlement_pending",
        retry: true,
      },
    );
  }
  return await completeWithResult(complete, operation, result, result.status, {
    safeErrorCode: null,
    retry: false,
  });
}
