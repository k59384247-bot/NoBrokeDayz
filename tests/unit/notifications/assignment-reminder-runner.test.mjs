import assert from "node:assert/strict";
import test from "node:test";
import { createAssignmentReminderRunnerHandler } from "../../../supabase/functions/_shared/assignment-reminder-runner-http.mjs";

const secret = "local-synthetic-reminder-runner-secret-0001";

test("reminder runner requires its own bearer secret and accepts no body", async () => {
  let batches = 0;
  const handler = createAssignmentReminderRunnerHandler({
    mode: "enabled",
    runnerSecret: secret,
    runBatch: async () => {
      batches++;
      return { claimed: 1, dispatched: 1, suppressed: 0, retried: 0 };
    },
  });
  assert.equal(
    (await handler(new Request("http://local", { method: "GET" }))).status,
    405,
  );
  assert.equal(
    (await handler(new Request("http://local", { method: "POST" }))).status,
    401,
  );
  assert.equal(
    (
      await handler(
        new Request("http://local", {
          method: "POST",
          headers: { authorization: `Bearer ${secret}` },
          body: "{}",
        }),
      )
    ).status,
    400,
  );
  const response = await handler(
    new Request("http://local", {
      method: "POST",
      headers: { authorization: `Bearer ${secret}` },
    }),
  );
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    result: { claimed: 1, dispatched: 1, suppressed: 0, retried: 0 },
  });
  assert.equal(batches, 1);
});

test("disabled reminder runner is not an operations route", async () => {
  const handler = createAssignmentReminderRunnerHandler({
    mode: "disabled",
    runnerSecret: "",
    runBatch: async () => assert.fail("disabled runner must not run"),
  });
  assert.equal(
    (await handler(new Request("http://local", { method: "POST" }))).status,
    404,
  );
});
