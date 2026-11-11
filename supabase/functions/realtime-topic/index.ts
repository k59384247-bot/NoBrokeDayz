import { createRealtimeTopicHandler } from "../_shared/realtime-topic.mjs";

const supabaseUrl = Deno.env.get("SUPABASE_URL");
const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
if (!supabaseUrl || !anonKey || !serviceRoleKey)
  throw new Error("realtime topic server configuration missing");
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
      result?.message ?? "realtime_topic_failed",
    ) as Error & {
      code?: string;
    };
    error.code = result?.code ?? result?.message;
    throw error;
  }
  return result as T;
}

Deno.serve(
  createRealtimeTopicHandler({
    verifyActor: async (token: string) => {
      const response = await fetch(`${baseUrl}/auth/v1/user`, {
        headers: { apikey: anonKey, authorization: `Bearer ${token}` },
      });
      return response.ok ? response.json() : null;
    },
    rpc,
  }),
);
