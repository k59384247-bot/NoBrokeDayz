import { verifySimulatorEvent } from "./payment-adapter.mjs";

const headers = {
  "cache-control": "no-store",
  "content-type": "application/json; charset=utf-8",
};

function json(status, body) {
  return new Response(JSON.stringify(body), { status, headers });
}

export function createPaymentCallbackHandler({
  mode,
  webhookSecret,
  recordReceipt,
  now = () => Date.now(),
}) {
  if (typeof recordReceipt !== "function")
    throw new Error("payment callback receipt store is not configured");
  return async (request) => {
    if (mode !== "local_simulator") return json(404, { error: "not_found" });
    if (request.method !== "POST")
      return json(405, { error: "method_not_allowed" });
    let rawBody;
    try {
      rawBody = await request.text();
    } catch {
      return json(400, { error: "invalid_event" });
    }
    if (new TextEncoder().encode(rawBody).byteLength > 8192)
      return json(413, { error: "event_too_large" });
    const event = await verifySimulatorEvent(
      rawBody,
      request.headers,
      webhookSecret,
      now(),
    );
    if (!event) return json(401, { error: "invalid_simulator_signature" });
    const payloadSha256 = [
      ...new Uint8Array(
        await crypto.subtle.digest(
          "SHA-256",
          new TextEncoder().encode(rawBody),
        ),
      ),
    ]
      .map((byte) => byte.toString(16).padStart(2, "0"))
      .join("");
    try {
      const receipt = await recordReceipt({ ...event, payloadSha256 });
      return json(200, {
        accepted: true,
        duplicate: receipt?.duplicate === true,
      });
    } catch {
      return json(503, { error: "receipt_store_unavailable" });
    }
  };
}
