import assert from "node:assert/strict";
import test from "node:test";
import { createRealtimeTopicHandler } from "../../../supabase/functions/_shared/realtime-topic.mjs";

const actor = "10000000-0000-4000-8000-000000000001";
const token = (claims = { sub: actor, aal: "aal2" }) =>
  `header.${Buffer.from(JSON.stringify(claims)).toString("base64url")}.sig`;

function request(body, accessToken = token()) {
  return new Request("http://local/functions/v1/realtime-topic", {
    method: "POST",
    headers: { authorization: `Bearer ${accessToken}` },
    body: JSON.stringify(body),
  });
}

test("topic lookup derives the actor and AAL from the verified Auth token", async () => {
  let received;
  const handler = createRealtimeTopicHandler({
    verifyActor: async () => ({ id: actor }),
    rpc: async (_name, args) => {
      received = args;
      return {
        topic:
          "nbd:case:20000000-0000-4000-8000-000000000001:actor:10000000-0000-4000-8000-000000000001:g:4",
        event: "case.changed",
        private: true,
      };
    },
    requestId: () => "request-id",
  });

  const response = await handler(
    request({
      scope: "case",
      resource_id: "20000000-0000-4000-8000-000000000001",
    }),
  );
  assert.equal(response.status, 200);
  assert.deepEqual(received, {
    p_actor: actor,
    p_scope: "case",
    p_resource: "20000000-0000-4000-8000-000000000001",
    p_auth_aal: "aal2",
  });
  assert.equal((await response.json()).data.private, true);
});

test("topic lookup rejects client supplied actors and mismatched Auth subjects", async () => {
  let calls = 0;
  const handler = createRealtimeTopicHandler({
    verifyActor: async () => ({ id: actor }),
    rpc: async () => {
      calls += 1;
      throw new Error("must not call RPC");
    },
  });

  const extraActor = await handler(
    request({ scope: "notifications", actor_id: actor }),
  );
  assert.equal(extraActor.status, 400);
  const mismatch = await handler(
    request({ scope: "notifications" }, token({ sub: "other", aal: "aal1" })),
  );
  assert.equal(mismatch.status, 401);
  assert.equal(calls, 0);
});
