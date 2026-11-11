import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { test } from "node:test";
import { createPaymentOperationRunnerHandler } from "../../../supabase/functions/_shared/payment-operation-runner-http.mjs";

const secret = randomBytes(32).toString("hex");
const url = "http://127.0.0.1/functions/v1/payment-operation-runner";

test("runner route rejects user calls, browser controls and disabled mode", async () => {
  let runs = 0;
  const handler = createPaymentOperationRunnerHandler({
    mode: "local_simulator",
    runnerSecret: secret,
    runOnce: async () => {
      runs++;
      return { claimed: false };
    },
  });
  assert.equal(
    (await handler(new Request(url, { method: "POST" }))).status,
    401,
  );
  assert.equal(
    (
      await handler(
        new Request(url, {
          method: "POST",
          headers: {
            authorization: `Bearer ${secret}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            amount: "1",
            provider: "bachs",
            status: "succeeded",
          }),
        }),
      )
    ).status,
    400,
  );
  assert.equal(runs, 0);
  assert.equal(
    (
      await createPaymentOperationRunnerHandler({
        mode: "disabled",
        runOnce: async () => assert.fail("disabled runner must not execute"),
      })(new Request(url, { method: "POST" }))
    ).status,
    404,
  );
});

test("runner invokes one persisted job only after internal authentication", async () => {
  let runs = 0;
  const handler = createPaymentOperationRunnerHandler({
    mode: "local_simulator",
    runnerSecret: secret,
    runOnce: async () => {
      runs++;
      return { claimed: true, status: "unknown" };
    },
  });
  const response = await handler(
    new Request(url, {
      method: "POST",
      headers: { authorization: `Bearer ${secret}` },
    }),
  );
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    result: { claimed: true, status: "unknown" },
  });
  assert.equal(runs, 1);
});
