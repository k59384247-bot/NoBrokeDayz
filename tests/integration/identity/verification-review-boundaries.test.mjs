import assert from "node:assert/strict";
import { test } from "node:test";
import { createVerificationReviewHandler } from "../../../supabase/functions/_shared/verification-review.mjs";

const actor = "8c5de580-8d71-4f00-a44e-859cba363e54";
const other = "0bfc5c8c-d39b-4412-a466-a1a507974b64";
const submission = "c3efefbd-8c73-47cf-98ba-307416f654a3";
function token(subject = actor, aal = "aal2") {
  const payload = Buffer.from(JSON.stringify({ sub: subject, aal })).toString(
    "base64url",
  );
  return `header.${payload}.signature`;
}
function request(body, access = token()) {
  return new Request("http://local.test/verification-review", {
    method: "POST",
    headers: {
      authorization: `Bearer ${access}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

test("review command actor is derived from Auth verified identity, not request JSON", async () => {
  const calls = [];
  const handler = createVerificationReviewHandler({
    verifyActor: async () => ({ id: actor }),
    command: async (...args) => {
      calls.push(args);
      return [{ submission_id: submission }];
    },
  });
  const response = await handler(request({ action: "queue", actor_id: other }));
  assert.equal(
    response.status,
    400,
    "unrecognized caller actor field is rejected",
  );
  assert.equal(calls.length, 0);
  const own = await handler(request({ action: "queue" }));
  assert.equal(own.status, 200);
  assert.deepEqual(calls[0], [
    "server_list_verification_queue_for_actor",
    { p_actor: actor, p_auth_aal: "aal2" },
  ]);
});

test("invalid Auth token cannot call review commands", async () => {
  let calls = 0;
  const handler = createVerificationReviewHandler({
    verifyActor: async () => null,
    command: async () => {
      calls++;
      return {};
    },
  });
  assert.equal((await handler(request({ action: "candidates" }))).status, 401);
  assert.equal(calls, 0);
});

test("review inputs use fixed commands and normalize stale-state responses", async () => {
  const calls = [];
  const handler = createVerificationReviewHandler({
    verifyActor: async () => ({ id: actor }),
    command: async (...args) => {
      calls.push(args);
      return { error: "stale_state" };
    },
  });
  const response = await handler(
    request({
      action: "review",
      submission_id: submission,
      idempotency_key: "20000000-0000-0000-0000-000000000001",
      expected_version: 1,
      expected_status: "pending",
      expected_decision_version: 0,
      decision: "needs_information",
      reason: "Please provide clearer synthetic evidence to continue review.",
    }),
  );
  assert.equal(response.status, 409);
  assert.equal(calls[0][0], "server_review_verification_for_actor");
  assert.equal(calls[0][1].p_actor, actor);
  assert.equal(calls[0][1].p_auth_aal, "aal2");
});
