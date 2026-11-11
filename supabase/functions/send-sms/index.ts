import { createSendSmsHandler, phoneSendDigest } from "../_shared/send-sms.mjs";

const hookSecret = Deno.env.get("SUPABASE_AUTH_HOOK_SEND_SMS_SECRET");
const captureUrl = Deno.env.get("NBD_LOCAL_SMS_CAPTURE_URL");
const captureToken = Deno.env.get("NBD_LOCAL_SMS_CAPTURE_TOKEN");
const phoneSendLimitKey = Deno.env.get("NBD_PHONE_SEND_LIMIT_HMAC_KEY");
const supabaseUrl = Deno.env.get("SUPABASE_URL");
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

if (
  !hookSecret ||
  !captureUrl ||
  !captureToken ||
  !phoneSendLimitKey ||
  !supabaseUrl ||
  !serviceRoleKey
) {
  const missing = [
    !hookSecret && "hook secret",
    !captureUrl && "capture URL",
    !captureToken && "capture token",
    !phoneSendLimitKey && "phone send limit key",
    !supabaseUrl && "Supabase URL",
    !serviceRoleKey && "server database executor",
  ].filter(Boolean);
  throw new Error(
    `local SMS hook configuration missing: ${missing.join(", ")}`,
  );
}

const target = new URL(captureUrl);
if (
  target.protocol !== "http:" ||
  !["127.0.0.1", "localhost", "::1"].includes(target.hostname)
) {
  throw new Error("SMS capture adapter must use loopback HTTP");
}

Deno.serve(
  createSendSmsHandler({
    hookSecret,
    reserveSend: async ({ userId, phone, eventId }) => {
      if (!eventId) throw new Error("Auth hook event ID missing");
      const response = await fetch(
        `${new URL(supabaseUrl).origin}/rest/v1/rpc/server_reserve_phone_sms_send_for_actor`,
        {
          method: "POST",
          headers: {
            apikey: serviceRoleKey,
            authorization: `Bearer ${serviceRoleKey}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            p_actor: userId,
            p_phone_digest: await phoneSendDigest(phone, phoneSendLimitKey),
            p_request_id: eventId,
          }),
          signal: AbortSignal.timeout(2000),
        },
      );
      if (!response.ok) throw new Error("phone send limit command unavailable");
      return (await response.json()) === true;
    },
    diagnose: async (diagnostic) => {
      await fetch(new URL("/diagnostic", target), {
        method: "POST",
        headers: {
          authorization: `Bearer ${captureToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify(diagnostic),
        signal: AbortSignal.timeout(1000),
      }).catch(() => undefined);
    },
    deliver: async ({ userId, phone, otp }) => {
      const response = await fetch(target, {
        method: "POST",
        headers: {
          authorization: `Bearer ${captureToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({ userId, phone, otp }),
        signal: AbortSignal.timeout(3000),
      });
      return response.ok;
    },
  }),
);
