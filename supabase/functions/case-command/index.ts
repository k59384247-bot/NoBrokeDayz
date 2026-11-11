import { createCaseCommandHandler } from "../_shared/case-command.mjs";

const supabaseUrl = Deno.env.get("SUPABASE_URL");
const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
if (!supabaseUrl || !anonKey || !serviceRoleKey)
  throw new Error("case command server configuration missing");
const baseUrl = new URL(supabaseUrl).origin;
const serverHeaders = {
  apikey: serviceRoleKey,
  authorization: `Bearer ${serviceRoleKey}`,
  "content-type": "application/json",
};
const safeDatabaseMessages = new Set([
  "case_access_denied",
  "appeal_window_closed",
  "decision_not_durably_notified",
  "appeal_window_open",
  "timely_appeal_unresolved",
  "appeal_evidence_request_open",
  "stale_decision_version",
  "case_not_found",
  "not_found",
  "idempotency_conflict",
  "stale_state",
  "case_file_limit_reached",
  "nonresponse_contact_threshold_not_met",
  "invalid_case_decision",
  "invalid_case_command",
]);

Deno.serve(
  createCaseCommandHandler({
    verifyActor: async (token: string) => {
      const response = await fetch(`${baseUrl}/auth/v1/user`, {
        headers: { apikey: anonKey, authorization: `Bearer ${token}` },
      });
      return response.ok ? response.json() : null;
    },
    rpc: async (name: string, args: Record<string, unknown>) => {
      const response = await fetch(`${baseUrl}/rest/v1/rpc/${name}`, {
        method: "POST",
        headers: serverHeaders,
        body: JSON.stringify(args),
      });
      const result = await response.json().catch(() => null);
      if (!response.ok) {
        const error = new Error("case command failed") as Error & {
          code?: string;
        };
        error.code = safeDatabaseMessages.has(result?.message)
          ? result.message
          : result?.code;
        throw error;
      }
      return result;
    },
  }),
);
