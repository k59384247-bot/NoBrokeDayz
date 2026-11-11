import {
  DEFAULT_FAKE_MERCHANT_ID,
  createLocalPaymentAdapter,
} from "../_shared/payment-adapter.mjs";
import { createFreshPasswordVerifier } from "../_shared/financial-step-up.mjs";
import { createWalletCommandHandler } from "../_shared/wallet-command.mjs";

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const mode = Deno.env.get("NBD_PAYMENT_MODE") ?? "disabled";
if (!supabaseUrl || !anonKey || !serviceRoleKey || mode !== "local_simulator")
  throw new Error("local wallet command configuration missing");

const payoutFeeKobo = Deno.env.get("NBD_SIMULATOR_PAYOUT_FEE_KOBO") ?? "0";
if (
  !/^(0|[1-9][0-9]{0,9})$/.test(payoutFeeKobo) ||
  BigInt(payoutFeeKobo) > 1000000000n
)
  throw new Error("local simulator payout fee is invalid");

createLocalPaymentAdapter({
  mode,
  supabaseUrl,
  simulatorUrl: Deno.env.get("NBD_SIMULATOR_URL"),
  merchantIdentity:
    Deno.env.get("NBD_SIMULATOR_MERCHANT_ID") ?? DEFAULT_FAKE_MERCHANT_ID,
  requestSecret: Deno.env.get("NBD_SIMULATOR_REQUEST_SECRET"),
  webhookSecret: Deno.env.get("NBD_SIMULATOR_WEBHOOK_SECRET"),
});

const baseUrl = new URL(supabaseUrl).origin;
const serviceHeaders = {
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
    headers: serviceHeaders,
    body: JSON.stringify(values),
  });
  const result = await response.json().catch(() => null);
  if (!response.ok) {
    const error = new Error(
      result?.message ?? "wallet_command_failed",
    ) as Error & {
      code?: string;
    };
    error.code = result?.code ?? result?.message;
    throw error;
  }
  return result as T;
}

Deno.serve(
  createWalletCommandHandler({
    verifyActor: async (token: string) => {
      const response = await fetch(`${baseUrl}/auth/v1/user`, {
        headers: { apikey: anonKey, authorization: `Bearer ${token}` },
      });
      return response.ok ? response.json() : null;
    },
    verifyPassword: createFreshPasswordVerifier({ authUrl: baseUrl, anonKey }),
    rpc,
    payoutFeeKobo,
  }),
);
