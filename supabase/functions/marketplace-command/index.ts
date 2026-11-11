import {
  DEFAULT_FAKE_MERCHANT_ID,
  createLocalPaymentAdapter,
} from "../_shared/payment-adapter.mjs";
import { createMarketplaceCommandHandler } from "../_shared/marketplace-command.mjs";

const supabaseUrl = Deno.env.get("SUPABASE_URL");
const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
if (!supabaseUrl || !anonKey || !serviceRoleKey)
  throw new Error("marketplace command server configuration missing");
const baseUrl = new URL(supabaseUrl).origin;
const serverHeaders = {
  apikey: serviceRoleKey,
  authorization: `Bearer ${serviceRoleKey}`,
  "content-type": "application/json",
};
const mode = Deno.env.get("NBD_PAYMENT_MODE") ?? "disabled";
if (!new Set(["disabled", "local_simulator"]).has(mode))
  throw new Error("unsupported payment mode");
const paymentAdapter =
  mode === "local_simulator"
    ? createLocalPaymentAdapter({
        mode,
        supabaseUrl,
        simulatorUrl: Deno.env.get("NBD_SIMULATOR_URL"),
        merchantIdentity:
          Deno.env.get("NBD_SIMULATOR_MERCHANT_ID") ?? DEFAULT_FAKE_MERCHANT_ID,
        requestSecret: Deno.env.get("NBD_SIMULATOR_REQUEST_SECRET"),
        webhookSecret: Deno.env.get("NBD_SIMULATOR_WEBHOOK_SECRET"),
      })
    : undefined;

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
  if (!response.ok) {
    const error = new Error(
      result?.message ?? "marketplace_command_failed",
    ) as Error & {
      code?: string;
    };
    error.code = result?.code ?? result?.message;
    throw error;
  }
  return result as T;
}

Deno.serve(
  createMarketplaceCommandHandler({
    verifyActor: async (token: string) => {
      const response = await fetch(`${baseUrl}/auth/v1/user`, {
        headers: { apikey: anonKey, authorization: `Bearer ${token}` },
      });
      return response.ok ? response.json() : null;
    },
    rpc,
    paymentAdapter,
  }),
);
