import { createSchoolEmailHandler } from "../_shared/school-email.mjs";

const supabaseUrl = Deno.env.get("SUPABASE_URL");
const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const hmacKey = Deno.env.get("NBD_SCHOOL_CHALLENGE_HMAC_KEY");
const adapterUrl = Deno.env.get("NBD_SCHOOL_EMAIL_ADAPTER_URL");
const adapterKey = Deno.env.get("NBD_SCHOOL_EMAIL_ADAPTER_KEY");

if (
  !supabaseUrl ||
  !anonKey ||
  !serviceRoleKey ||
  !hmacKey ||
  !adapterUrl ||
  !adapterKey
) {
  throw new Error("school email server configuration missing");
}

const baseUrl = new URL(supabaseUrl).origin;
const baseHeaders = {
  apikey: serviceRoleKey,
  authorization: `Bearer ${serviceRoleKey}`,
  "content-type": "application/json",
};

Deno.serve(
  createSchoolEmailHandler({
    hmacKey,
    verifyActor: async (token: string) => {
      const response = await fetch(`${baseUrl}/auth/v1/user`, {
        headers: { apikey: anonKey, authorization: `Bearer ${token}` },
      });
      if (!response.ok) return null;
      return (await response.json()).id;
    },
    command: async (name: string, args: Record<string, unknown>) => {
      const response = await fetch(`${baseUrl}/rest/v1/rpc/${name}`, {
        method: "POST",
        headers: baseHeaders,
        body: JSON.stringify(args),
      });
      const result = await response.json().catch(() => null);
      if (!response.ok) {
        const error = new Error("identity command failed") as Error & {
          code?: string;
        };
        error.code = result?.message;
        throw error;
      }
      return result;
    },
    deliver: async (
      to: string,
      code: string,
      context: { challengeId: string; actorId: string },
    ) => {
      const response = await fetch(adapterUrl, {
        method: "POST",
        headers: {
          authorization: `Bearer ${adapterKey}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          to,
          template: "institutional-email-ownership",
          variables: { code, expires_minutes: 10 },
          metadata: {
            challenge_id: context.challengeId,
            actor_id: context.actorId,
          },
        }),
      });
      if (!response.ok) throw new Error("school email delivery failed");
    },
  }),
);
