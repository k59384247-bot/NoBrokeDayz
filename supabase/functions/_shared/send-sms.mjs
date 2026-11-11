import { normalizeNigerianPhone } from "../../../lib/auth/phone-number.mjs";

/** @typedef {{ userId: string, phone: string, otp: string }} SmsDelivery */
/** @typedef {{ userId: string, phone: string, eventId: string }} SmsSendRequest */
/** @typedef {{ reason: string, hasUserId?: boolean, hasPhone?: boolean, hasOtp?: boolean, otpLength?: number }} SmsDiagnostic */

const responseHeaders = {
  "cache-control": "no-store",
  "content-type": "application/json; charset=utf-8",
};

function json(status, body = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: responseHeaders,
  });
}

function decodeBase64(value) {
  const binary = atob(value);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function decodeHookSecret(value) {
  const encoded = value?.match(/^v1,whsec_([A-Za-z0-9+/]+={0,2})$/)?.[1];
  if (!encoded) throw new Error("send SMS hook secret is invalid");
  const key = decodeBase64(encoded);
  if (key.byteLength < 32) throw new Error("send SMS hook secret is invalid");
  return key;
}

/** @param {string} phone @param {string} secret */
export async function phoneSendDigest(phone, secret) {
  if (!/^[A-Za-z0-9_-]{43}$/.test(secret))
    throw new Error("phone send limit key is invalid");
  const base64 = secret.replaceAll("-", "+").replaceAll("_", "/");
  const keyBytes = Uint8Array.from(
    atob(base64.padEnd(Math.ceil(base64.length / 4) * 4, "=")),
    (character) => character.charCodeAt(0),
  );
  const key = await crypto.subtle.importKey(
    "raw",
    keyBytes,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(phone)),
  );
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join(
    "",
  );
}

async function signedByAuth(request, rawBody, keyBytes, now) {
  const id = request.headers.get("webhook-id");
  const timestamp = request.headers.get("webhook-timestamp");
  const signatures = request.headers.get("webhook-signature") ?? "";
  if (!id || !timestamp || !/^\d{1,12}$/.test(timestamp)) return false;
  const timestampSeconds = Number(timestamp);
  if (Math.abs(Math.floor(now() / 1000) - timestampSeconds) > 300) return false;

  const key = await crypto.subtle.importKey(
    "raw",
    keyBytes,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"],
  );
  const signedPayload = new TextEncoder().encode(
    `${id}.${timestamp}.${rawBody}`,
  );
  for (const signature of signatures.split(/\s+/)) {
    const encoded = signature.match(/^v1,([A-Za-z0-9+/]+={0,2})$/)?.[1];
    if (!encoded) continue;
    try {
      if (
        await crypto.subtle.verify(
          "HMAC",
          key,
          decodeBase64(encoded),
          signedPayload,
        )
      ) {
        return true;
      }
    } catch {
      // Ignore malformed signature encodings.
    }
  }
  return false;
}

/**
 * @param {{ hookSecret: string, reserveSend: (request: SmsSendRequest) => Promise<boolean>, deliver: (delivery: SmsDelivery) => Promise<boolean>, diagnose?: (diagnostic: SmsDiagnostic) => Promise<void>, now?: () => number }} dependencies
 */
export function createSendSmsHandler({
  hookSecret,
  reserveSend,
  deliver,
  diagnose = async () => {},
  now = Date.now,
}) {
  const keyBytes = decodeHookSecret(hookSecret);
  if (typeof reserveSend !== "function")
    throw new Error("durable SMS send limit is not configured");
  if (typeof deliver !== "function")
    throw new Error("SMS delivery adapter missing");

  return async function sendSms(request) {
    if (request.method !== "POST") return json(405);
    const rawBody = await request.text().catch(() => "");
    if (new TextEncoder().encode(rawBody).byteLength > 16_384) {
      return json(413);
    }

    if (!(await signedByAuth(request, rawBody, keyBytes, now))) {
      await diagnose({ reason: "signature_invalid" });
      return json(401);
    }

    let event;
    try {
      event = JSON.parse(rawBody);
    } catch {
      await diagnose({ reason: "invalid_json" });
      return json(400);
    }
    const userId = event?.user?.id;
    const phone = event?.sms?.phone ?? event?.user?.phone;
    const otp = event?.sms?.otp;
    if (
      typeof userId !== "string" ||
      !/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(userId) ||
      typeof otp !== "string" ||
      !/^\d{6}$/.test(otp)
    ) {
      await diagnose({
        reason: "invalid_payload",
        hasUserId: typeof userId === "string",
        hasPhone: typeof phone === "string" && phone.length > 0,
        hasOtp: typeof otp === "string",
        otpLength: typeof otp === "string" ? otp.length : 0,
      });
      return json(400);
    }

    let normalizedPhone;
    try {
      normalizedPhone = normalizeNigerianPhone(phone);
    } catch {
      await diagnose({ reason: "invalid_phone" });
      return json(400);
    }

    let reserved;
    try {
      reserved = await reserveSend({
        userId,
        phone: normalizedPhone,
        eventId: request.headers.get("webhook-id"),
      });
    } catch {
      await diagnose({ reason: "send_limit_unavailable" });
      return json(503);
    }
    if (reserved !== true) {
      await diagnose({ reason: "send_limit_reached" });
      return json(429);
    }

    try {
      if (!(await deliver({ userId, phone: normalizedPhone, otp }))) {
        await diagnose({ reason: "delivery_failed" });
        return json(503);
      }
    } catch {
      await diagnose({ reason: "delivery_failed" });
      return json(503);
    }
    return json(200);
  };
}
