import { createIdentityRegistrationHandler } from "../_shared/identity-registration.mjs";

const supabaseUrl = Deno.env.get("SUPABASE_URL");
const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

if (!supabaseUrl || !anonKey || !serviceRoleKey) {
  throw new Error("identity registration server configuration missing");
}

Deno.serve(
  createIdentityRegistrationHandler({ supabaseUrl, anonKey, serviceRoleKey }),
);
