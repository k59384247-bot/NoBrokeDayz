import { createLocalPaymentAdapter } from "../_shared/payment-adapter.mjs";
import { createPaymentOperationRunnerHandler } from "../_shared/payment-operation-runner-http.mjs";
import { runPaymentOperation } from "../_shared/payment-operation-runner.mjs";

const mode = Deno.env.get("NBD_PAYMENT_MODE") ?? "disabled";
if (!new Set(["disabled", "local_simulator"]).has(mode))
  throw new Error("unsupported payment mode");
const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const runnerSecret = Deno.env.get("NBD_PAYMENT_RUNNER_SECRET") ?? "";
let adapter: ReturnType<typeof createLocalPaymentAdapter> | undefined;
if (mode === "local_simulator") {
  adapter = createLocalPaymentAdapter({
    mode,
    supabaseUrl,
    simulatorUrl: Deno.env.get("NBD_SIMULATOR_URL"),
    merchantIdentity: Deno.env.get("NBD_SIMULATOR_MERCHANT_ID"),
    requestSecret: Deno.env.get("NBD_SIMULATOR_REQUEST_SECRET"),
    webhookSecret: Deno.env.get("NBD_SIMULATOR_WEBHOOK_SECRET"),
  });
  if (!serviceRoleKey || runnerSecret.length < 32)
    throw new Error("local payment runner server configuration missing");
}

const baseUrl = supabaseUrl ? new URL(supabaseUrl).origin : "";
const serverHeaders = {
  apikey: serviceRoleKey,
  authorization: `Bearer ${serviceRoleKey}`,
  "content-type": "application/json",
};

async function rpc<T>(
  name: string,
  values: Record<string, unknown>,
): Promise<T> {
  const response = await fetch(`${baseUrl}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: serverHeaders,
    body: JSON.stringify(values),
  });
  const result = await response.json().catch(() => null);
  if (!response.ok)
    throw new Error(result?.message ?? "payment_runner_command_failed");
  return result as T;
}

Deno.serve(
  createPaymentOperationRunnerHandler({
    mode,
    runnerSecret,
    runOnce: () =>
      runPaymentOperation({
        adapter: adapter!,
        claim: () =>
          rpc<Record<string, unknown> | null>(
            "server_claim_payment_operation_for_runner",
            {
              p_worker_id: crypto.randomUUID(),
              p_lease_seconds: 30,
            },
          ),
        complete: (result: Record<string, unknown>) =>
          result.operationType === "refund"
            ? rpc<Record<string, unknown>>(
                "server_complete_refund_operation_for_runner",
                {
                  p_operation_id: result.operationId,
                  p_lease_token: result.leaseToken,
                  p_status: result.status,
                  p_provider_reference: result.reference ?? null,
                  p_amount_kobo: result.amountKobo ?? null,
                  p_currency: result.currency ?? null,
                  p_client_reference: result.clientReference ?? null,
                  p_source_provider_reference: result.sourceReference ?? null,
                  p_fee_kobo: result.feeKobo ?? null,
                  p_settlement_status: result.settlementStatus ?? null,
                  p_safe_error_code: result.safeErrorCode ?? null,
                  p_retry: result.retry ?? false,
                  p_result_sha256_hex: result.resultSha256Hex ?? null,
                },
              )
            : result.operationType === "collection"
              ? rpc<Record<string, unknown>>(
                  "server_complete_job_funding_with_settlement_for_runner",
                  {
                    p_operation_id: result.operationId,
                    p_lease_token: result.leaseToken,
                    p_status: result.status,
                    p_provider_reference: result.reference ?? null,
                    p_amount_kobo: result.amountKobo ?? null,
                    p_currency: result.currency ?? null,
                    p_merchant_identity: result.merchantIdentity ?? null,
                    p_client_reference: result.clientReference ?? null,
                    p_fee_kobo: result.feeKobo ?? "0",
                    p_safe_error_code: result.safeErrorCode ?? null,
                    p_retry: result.retry ?? false,
                    p_result_sha256_hex: result.resultSha256Hex ?? null,
                    p_settlement_status: result.settlementStatus ?? "pending",
                  },
                )
              : rpc<Record<string, unknown>>(
                  "server_complete_worker_payout_for_runner",
                  {
                    p_operation_id: result.operationId,
                    p_lease_token: result.leaseToken,
                    p_status: result.status,
                    p_provider_reference: result.reference ?? null,
                    p_amount_kobo: result.amountKobo ?? null,
                    p_currency: result.currency ?? null,
                    p_client_reference: result.clientReference ?? null,
                    p_destination_id: result.destinationId ?? null,
                    p_destination_version: result.destinationVersion ?? null,
                    p_fee_kobo: result.feeKobo ?? "0",
                    p_safe_error_code: result.safeErrorCode ?? null,
                    p_retry: result.retry ?? false,
                    p_result_sha256_hex: result.resultSha256Hex ?? null,
                  },
                ),
      }),
  }),
);
