import {
  DEFAULT_FAKE_MERCHANT_ID,
  createLocalPaymentAdapter,
} from "../_shared/payment-adapter.mjs";
import { createFinancialInspectionHandler } from "../_shared/financial-inspection.mjs";

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const mode = Deno.env.get("NBD_PAYMENT_MODE") ?? "disabled";
if (!supabaseUrl || !anonKey || !serviceRoleKey || mode !== "local_simulator")
  throw new Error("local financial inspection configuration missing");

const simulator = createLocalPaymentAdapter({
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

async function rpc<T>(name: string, args: Record<string, unknown>): Promise<T> {
  const response = await fetch(`${baseUrl}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: serviceHeaders,
    body: JSON.stringify(args),
  });
  const result = await response.json().catch(() => null);
  if (!response.ok) {
    const error = new Error(
      result?.message ?? "financial_inspection_failed",
    ) as Error & { code?: string };
    error.code = result?.code ?? result?.message;
    throw error;
  }
  return result as T;
}

Deno.serve(
  createFinancialInspectionHandler({
    verifyActor: async (token: string) => {
      const response = await fetch(`${baseUrl}/auth/v1/user`, {
        headers: { apikey: anonKey, authorization: `Bearer ${token}` },
      });
      return response.ok ? response.json() : null;
    },
    rpc,
    inspectSimulatorLiquidity: () => simulator.inspectLiquiditySnapshot(),
  }),
);
