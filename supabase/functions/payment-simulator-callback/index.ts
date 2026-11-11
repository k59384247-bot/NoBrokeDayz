import { createLocalPaymentAdapter } from "../_shared/payment-adapter.mjs";
import { createPaymentCallbackHandler } from "../_shared/payment-callback.mjs";

const mode = Deno.env.get("NBD_PAYMENT_MODE") ?? "disabled";
if (!new Set(["disabled", "local_simulator"]).has(mode))
  throw new Error("unsupported payment mode");
const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const webhookSecret = Deno.env.get("NBD_SIMULATOR_WEBHOOK_SECRET") ?? "";
if (mode === "local_simulator") {
  createLocalPaymentAdapter({
    mode,
    supabaseUrl,
    simulatorUrl: Deno.env.get("NBD_SIMULATOR_URL"),
    requestSecret: Deno.env.get("NBD_SIMULATOR_REQUEST_SECRET"),
    webhookSecret,
  });
  if (!serviceRoleKey)
    throw new Error("local payment callback server configuration missing");
}

const baseUrl = supabaseUrl ? new URL(supabaseUrl).origin : "";
const serverHeaders = {
  apikey: serviceRoleKey,
  authorization: `Bearer ${serviceRoleKey}`,
  "content-type": "application/json",
};

Deno.serve(
  createPaymentCallbackHandler({
    mode,
    webhookSecret,
    recordReceipt: async (event: Record<string, string>) => {
      const response = await fetch(
        `${baseUrl}/rest/v1/rpc/server_record_payment_simulator_receipt`,
        {
          method: "POST",
          headers: serverHeaders,
          body: JSON.stringify({
            p_event_reference: event.eventReference,
            p_client_reference: event.clientReference,
            p_provider_reference: event.operationReference,
            p_payload_sha256_hex: event.payloadSha256,
          }),
        },
      );
      const result = await response.json().catch(() => null);
      if (!response.ok)
        throw new Error(result?.message ?? "receipt_store_unavailable");
      return result;
    },
  }),
);
