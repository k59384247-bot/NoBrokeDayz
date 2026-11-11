import { createReviewModerationHandler } from "../_shared/review-moderation.mjs";

const supabaseUrl = Deno.env.get("SUPABASE_URL");
const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
if (!supabaseUrl || !anonKey || !serviceRoleKey)
  throw new Error("review moderation server configuration missing");
const baseUrl = new URL(supabaseUrl).origin;
const serverHeaders = {
  apikey: serviceRoleKey,
  authorization: `Bearer ${serviceRoleKey}`,
  "content-type": "application/json",
};

Deno.serve(
  createReviewModerationHandler({
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
        const error = new Error(
          typeof result?.message === "string"
            ? result.message
            : "review_moderation_failed",
        ) as Error & { code?: string };
        error.code = result?.code;
        throw error;
      }
      return result;
    },
  }),
);
