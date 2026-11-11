import { createCaseReadHandler } from "../_shared/case-read.mjs";

const supabaseUrl = Deno.env.get("SUPABASE_URL");
const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
if (!supabaseUrl || !anonKey || !serviceRoleKey)
  throw new Error("case read server configuration missing");
const baseUrl = new URL(supabaseUrl).origin;
const serverHeaders = {
  apikey: serviceRoleKey,
  authorization: `Bearer ${serviceRoleKey}`,
  "content-type": "application/json",
};

Deno.serve(
  createCaseReadHandler({
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
        const error = new Error("case read request failed") as Error & {
          code?: string;
          appCode?: string;
          safeCategory?: string;
        };
        error.code = result?.code;
        const message =
          typeof result?.message === "string" ? result.message : "";
        error.appCode = /^[a-z][a-z0-9_]{0,63}$/.test(message)
          ? message
          : undefined;
        error.safeCategory = /^[a-z][a-z0-9_]{0,63}$/.test(message)
          ? message
          : /function .*schema cache/i.test(message)
            ? "rpc_schema_cache_miss"
            : /permission denied/i.test(message)
              ? "rpc_permission_denied"
              : /does not exist/i.test(message)
                ? "database_object_missing"
                : "database_request_failed";
        throw error;
      }
      return result;
    },
  }),
);
