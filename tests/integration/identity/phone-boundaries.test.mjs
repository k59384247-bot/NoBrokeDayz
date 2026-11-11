import assert from "node:assert/strict";
import { createHmac, randomUUID } from "node:crypto";
import { test } from "node:test";
import { normalizeNigerianPhone } from "../../../lib/auth/phone-number.mjs";
import {
  confirmMyPhoneChange,
  requestMyPhoneChange,
} from "../../../lib/auth/phone-change.mjs";
import { createSendSmsHandler } from "../../../supabase/functions/_shared/send-sms.mjs";
import { startLocalSmsCapture } from "../../../scripts/test-support/local-sms-capture.mjs";

const secret = `v1,whsec_${Buffer.alloc(32, 7).toString("base64")}`;

function signedRequest(body, timestamp = Math.floor(Date.now() / 1000)) {
  const id = randomUUID();
  const signature = createHmac("sha256", Buffer.alloc(32, 7))
    .update(`${id}.${timestamp}.${body}`)
    .digest("base64");
  return new Request("http://local.test/send-sms", {
    method: "POST",
    body,
    headers: {
      "webhook-id": id,
      "webhook-timestamp": String(timestamp),
      "webhook-signature": `v1,${signature}`,
    },
  });
}

test("phone numbers normalize Nigerian local, country-code, and E.164 forms", () => {
  assert.equal(normalizeNigerianPhone("0803 123 4567"), "+2348031234567");
  assert.equal(normalizeNigerianPhone("234-803-123-4567"), "+2348031234567");
  assert.equal(normalizeNigerianPhone("+234 (803) 123-4567"), "+2348031234567");
});

test("phone normalization rejects malformed and non-Nigerian numbers", () => {
  for (const input of [
    "",
    "0803 123",
    "+1 415 555 0100",
    "0203 123 4567",
    "+23480312345678",
  ]) {
    assert.throws(() => normalizeNigerianPhone(input), /invalid phone number/);
  }
});

test("signed Supabase SMS hook sends the Auth-generated code only to the local adapter", async (t) => {
  const capture = await startLocalSmsCapture();
  t.after(() => capture.close());
  const handler = createSendSmsHandler({
    hookSecret: secret,
    reserveSend: async () => true,
    deliver: async (delivery) => {
      const response = await fetch(capture.url, {
        method: "POST",
        headers: {
          authorization: `Bearer ${capture.token}`,
          "content-type": "application/json",
        },
        body: JSON.stringify(delivery),
      });
      return response.status === 204;
    },
  });
  const body = JSON.stringify({
    user: {
      id: "8c5de580-8d71-4f00-a44e-859cba363e54",
      phone: "0700 000 0001",
    },
    sms: { otp: "038194" },
  });
  const response = await handler(signedRequest(body));
  const responseText = await response.text();

  assert.equal(response.status, 200);
  assert.deepEqual(await JSON.parse(responseText), {});
  assert.equal(responseText.includes("038194"), false);
  assert.deepEqual(await capture.take("+2347000000001"), {
    userId: "8c5de580-8d71-4f00-a44e-859cba363e54",
    phone: "+2347000000001",
    otp: "038194",
  });
});

test("invalid and expired hook signatures never reach the delivery adapter", async () => {
  let deliveryCount = 0;
  const handler = createSendSmsHandler({
    hookSecret: secret,
    reserveSend: async () => true,
    deliver: async () => deliveryCount++,
  });
  const body = JSON.stringify({
    user: {
      id: "8c5de580-8d71-4f00-a44e-859cba363e54",
      phone: "2348031234567",
    },
    sms: { otp: "038194" },
  });
  const invalid = signedRequest(body);
  invalid.headers.set("webhook-signature", "v1,AAAA");
  const expired = signedRequest(body, Math.floor(Date.now() / 1000) - 301);

  for (const request of [invalid, expired]) {
    const response = await handler(request);
    const responseText = await response.text();
    assert.equal(response.status, 401);
    assert.equal(responseText.includes("038194"), false);
  }
  assert.equal(deliveryCount, 0);
});

test("phone-change hook delivers to sms.phone rather than the user's previous phone", async () => {
  let target;
  const handler = createSendSmsHandler({
    hookSecret: secret,
    reserveSend: async () => true,
    deliver: async (delivery) => {
      target = delivery.phone;
      return true;
    },
  });
  const body = JSON.stringify({
    user: {
      id: "8c5de580-8d71-4f00-a44e-859cba363e54",
      phone: "2347000000002",
    },
    sms: { phone: "2347000000005", otp: "038194" },
  });
  assert.equal((await handler(signedRequest(body))).status, 200);
  assert.equal(target, "+2347000000005");
});

test("signed SMS delivery reserves the durable phone quota before sending", async () => {
  let reservation;
  let deliveries = 0;
  const userId = "8c5de580-8d71-4f00-a44e-859cba363e54";
  const handler = createSendSmsHandler({
    hookSecret: secret,
    reserveSend: async (request) => {
      reservation = request;
      return false;
    },
    deliver: async () => {
      deliveries++;
      return true;
    },
  });
  const body = JSON.stringify({
    user: { id: userId, phone: "2347000000001" },
    sms: { otp: "038194" },
  });
  const request = signedRequest(body);
  const response = await handler(request);
  const responseText = await response.text();

  assert.equal(response.status, 429);
  assert.deepEqual(reservation, {
    userId,
    phone: "+2347000000001",
    eventId: request.headers.get("webhook-id"),
  });
  assert.equal(deliveries, 0);
  assert.equal(responseText.includes("038194"), false);
});

test("delivery failure returns no OTP and does not claim successful delivery", async () => {
  const capture = await startLocalSmsCapture({
    failurePhones: ["+2347000000001"],
  });
  try {
    const handler = createSendSmsHandler({
      hookSecret: secret,
      reserveSend: async () => true,
      deliver: async (delivery) => {
        const response = await fetch(capture.url, {
          method: "POST",
          headers: {
            authorization: `Bearer ${capture.token}`,
            "content-type": "application/json",
          },
          body: JSON.stringify(delivery),
        });
        return response.status === 204;
      },
    });
    const body = JSON.stringify({
      user: {
        id: "8c5de580-8d71-4f00-a44e-859cba363e54",
        phone: "+2347000000001",
      },
      sms: { otp: "038194" },
    });
    const response = await handler(signedRequest(body));
    const responseText = await response.text();

    assert.equal(response.status, 503);
    assert.equal(responseText.includes("038194"), false);
  } finally {
    await capture.close();
  }
});

test("phone change uses the signed-in confirmed email account and phone_change OTP type", async () => {
  const calls = [];
  const auth = {
    async getUser() {
      return {
        data: {
          user: { email: "synthetic@identity.test", email_confirmed_at: "now" },
        },
        error: null,
      };
    },
    async updateUser(value) {
      calls.push(["update", value]);
      return { data: {}, error: null };
    },
    async verifyOtp(value) {
      calls.push(["verify", value]);
      return {
        data: {
          user: {
            id: "8c5de580-8d71-4f00-a44e-859cba363e54",
            phone: "2348031234567",
            phone_confirmed_at: "now",
          },
        },
        error: null,
      };
    },
  };

  assert.equal((await requestMyPhoneChange(auth, "0803 123 4567")).error, null);
  const confirmed = await confirmMyPhoneChange(auth, "2348031234567", "038194");
  assert.equal(confirmed.error, null);
  assert.equal(
    confirmed.data.phone,
    "+2348031234567",
    "Auth digits are projected as canonical application E.164",
  );
  assert.deepEqual(calls, [
    ["update", { phone: "+2348031234567" }],
    [
      "verify",
      { phone: "+2348031234567", token: "038194", type: "phone_change" },
    ],
  ]);
});

test("unconfirmed accounts and malformed OTPs cannot enter phone-change verification", async () => {
  let authCalls = 0;
  const auth = {
    async getUser() {
      return {
        data: { user: { email: "pending@identity.test" } },
        error: null,
      };
    },
    async updateUser() {
      authCalls++;
      return { data: {}, error: null };
    },
    async verifyOtp() {
      authCalls++;
      return { data: {}, error: null };
    },
  };
  assert.ok((await requestMyPhoneChange(auth, "+2348031234567")).error);
  assert.ok((await confirmMyPhoneChange(auth, "+2348031234567", "bad")).error);
  assert.equal(authCalls, 0);
});
