import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { test } from "node:test";
import { createPaymentCallbackHandler } from "../../../supabase/functions/_shared/payment-callback.mjs";
import { createPaymentSimulator } from "../../fixtures/payments/simulator.mjs";

const secret = randomBytes(32).toString("hex");

test("callback rejects spoofed and altered bodies without user authentication", async () => {
  const simulator = await createPaymentSimulator({
    requestSecret: randomBytes(32).toString("hex"),
    webhookSecret: secret,
  });
  try {
    let received = 0;
    const handler = createPaymentCallbackHandler({
      mode: "local_simulator",
      webhookSecret: secret,
      recordReceipt: async () => {
        received += 1;
      },
    });
    const event = simulator.makeEvent({
      eventReference: "evt-spoof-01",
      idempotencyKey: "70000000-0000-4000-8000-000000000002",
      status: "succeeded",
      amountKobo: "300000",
    });
    const spoofed = await handler(
      new Request("http://local/functions/v1/payment-simulator-callback", {
        method: "POST",
        body: event.rawBody,
        headers: { "content-type": "application/json" },
      }),
    );
    assert.equal(spoofed.status, 401);

    const altered = await handler(
      new Request("http://local/functions/v1/payment-simulator-callback", {
        method: "POST",
        body: event.rawBody.replace("300000", "300001"),
        headers: event.headers,
      }),
    );
    assert.equal(altered.status, 401);
    assert.equal(received, 0);
  } finally {
    await simulator.close();
  }
});

test("callback waits for durable receipt before acknowledgement and deduplicates replay", async () => {
  const simulator = await createPaymentSimulator({
    requestSecret: randomBytes(32).toString("hex"),
    webhookSecret: secret,
  });
  try {
    let releaseReceipt;
    const receiptGate = new Promise((resolve) => {
      releaseReceipt = resolve;
    });
    const recorded = [];
    const handler = createPaymentCallbackHandler({
      mode: "local_simulator",
      webhookSecret: secret,
      recordReceipt: async (event) => {
        await receiptGate;
        recorded.push(event);
        return { duplicate: recorded.length > 1 };
      },
      now: () => Date.now(),
    });
    const event = simulator.makeEvent({
      eventReference: "evt-replayed-01",
      idempotencyKey: "70000000-0000-4000-8000-000000000012",
      status: "succeeded",
      amountKobo: "900000",
    });
    const pendingResponse = handler(
      new Request("http://local/functions/v1/payment-simulator-callback", {
        method: "POST",
        body: event.rawBody,
        headers: event.headers,
      }),
    );
    await Promise.resolve();
    let acknowledged = false;
    pendingResponse.then(() => {
      acknowledged = true;
    });
    await new Promise((resolve) => setTimeout(resolve, 0));
    assert.equal(acknowledged, false);
    releaseReceipt();
    const response = await pendingResponse;
    assert.equal(response.status, 200);
    assert.equal(recorded.length, 1);

    const replay = await handler(
      new Request("http://local/functions/v1/payment-simulator-callback", {
        method: "POST",
        body: event.rawBody,
        headers: event.headers,
      }),
    );
    assert.equal(replay.status, 200);
    assert.equal(recorded.length, 2);
  } finally {
    await simulator.close();
  }
});

test("callbacks without local simulator mode are disabled", async () => {
  const handler = createPaymentCallbackHandler({
    mode: "disabled",
    webhookSecret: secret,
    recordReceipt: async () => assert.fail("must stay disabled"),
  });
  assert.equal(
    (
      await handler(
        new Request("http://local/functions/v1/payment-simulator-callback", {
          method: "POST",
        }),
      )
    ).status,
    404,
  );
});

test("signed duplicate and out-of-order events are accepted as receipt prompts", async () => {
  const simulator = await createPaymentSimulator({
    requestSecret: randomBytes(32).toString("hex"),
    webhookSecret: secret,
  });
  try {
    const stored = [];
    const handler = createPaymentCallbackHandler({
      mode: "local_simulator",
      webhookSecret: secret,
      recordReceipt: async (event) => {
        stored.push(event.eventReference);
        return { duplicate: false };
      },
    });
    for (const [eventReference, status] of [
      ["evt-newer-01", "succeeded"],
      ["evt-older-02", "pending"],
    ]) {
      const event = simulator.makeEvent({
        eventReference,
        idempotencyKey: "70000000-0000-4000-8000-000000000022",
        status,
        amountKobo: "900000",
      });
      assert.equal(
        (
          await handler(
            new Request(
              "http://local/functions/v1/payment-simulator-callback",
              {
                method: "POST",
                body: event.rawBody,
                headers: event.headers,
              },
            ),
          )
        ).status,
        200,
      );
    }
    assert.deepEqual(stored, ["evt-newer-01", "evt-older-02"]);
  } finally {
    await simulator.close();
  }
});
