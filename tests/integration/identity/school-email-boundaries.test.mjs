import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { test } from "node:test";
import { createSchoolEmailHandler } from "../../../supabase/functions/_shared/school-email.mjs";

const actor = "8c5de580-8d71-4f00-a44e-859cba363e54";
const accessToken = "synthetic-access-token";
const requestKey = "8756a9d2-6467-489f-8d9f-672ae9f983b7";
const key = Buffer.alloc(32, 19).toString("base64url");
const digest = (code) =>
  createHmac("sha256", Buffer.from(key, "base64url"))
    .update(code)
    .digest("hex");

function request(body, token = accessToken) {
  return new Request("http://local.test/school-email", {
    method: "POST",
    headers: token ? { authorization: `Bearer ${token}` } : {},
    body: JSON.stringify(body),
  });
}

function makeHandler(overrides = {}) {
  const calls = [];
  const handler = createSchoolEmailHandler({
    hmacKey: key,
    verifyActor: async (token) => {
      calls.push(["verify", token]);
      return actor;
    },
    command: async (name, input) => {
      calls.push(["command", name, input]);
      if (name === "server_begin_school_challenge_for_actor")
        return {
          challenge_id: "c3efefbd-8c73-47cf-98ba-307416f654a3",
          issued: true,
        };
      if (name === "server_confirm_school_challenge_for_actor")
        return {
          confirmed: true,
          qualified: false,
          next_steps: ["verify_phone"],
        };
      return { invalidated: true };
    },
    deliver: async (email, code) => calls.push(["deliver", email, code]),
    randomCode: () => "042871",
    ...overrides,
  });
  return { handler, calls };
}

test("school challenge issuance binds the verified actor and keeps code out of the response", async () => {
  const { handler, calls } = makeHandler();
  const response = await handler(
    request({
      action: "begin",
      email: "Student@school.test",
      idempotency_key: requestKey,
    }),
  );
  const text = await response.text();
  assert.equal(response.status, 200);
  assert.equal(text.includes("042871"), false);
  assert.deepEqual(await JSON.parse(text), {
    challenge_id: "c3efefbd-8c73-47cf-98ba-307416f654a3",
    state: "pending",
  });
  assert.deepEqual(calls[0], ["verify", accessToken]);
  const rpc = calls.find((call) => call[0] === "command");
  assert.equal(rpc[1], "server_begin_school_challenge_for_actor");
  assert.equal(rpc[2].p_actor, actor);
  assert.equal(rpc[2].p_email, "student@school.test");
  assert.equal(rpc[2].p_request_key, requestKey);
  assert.equal(rpc[2].p_code_digest, digest("042871"));
  assert.equal(JSON.stringify(rpc).includes("042871"), false);
  assert.equal(calls.at(-1)[0], "deliver");
  assert.equal(calls.at(-1)[1], "student@school.test");
  assert.ok(
    /^\d{6}$/.test(calls.at(-1)[2]),
    "delivery receives a six-digit synthetic code",
  );
});

test("school confirmation is bound to authenticated actor and keyed digest", async () => {
  const { handler, calls } = makeHandler();
  const response = await handler(
    request({
      action: "confirm",
      challenge_id: "c3efefbd-8c73-47cf-98ba-307416f654a3",
      code: "042871",
    }),
  );
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    confirmed: true,
    qualified: false,
    next_steps: ["verify_phone"],
  });
  const rpc = calls.find((call) => call[0] === "command");
  assert.equal(rpc[1], "server_confirm_school_challenge_for_actor");
  assert.equal(rpc[2].p_actor, actor);
  assert.equal(rpc[2].p_code_digest, digest("042871"));
  assert.equal(JSON.stringify(rpc).includes("042871"), false);
});

test("school challenge rejects caller actor, unknown input and unauthenticated requests", async () => {
  let verified = 0;
  const { handler } = makeHandler({
    verifyActor: async () => {
      verified++;
      return actor;
    },
  });
  for (const input of [
    {
      action: "begin",
      email: "x@school.test",
      idempotency_key: requestKey,
      actor_id: actor,
    },
    {
      action: "begin",
      email: "x@school.test",
      idempotency_key: requestKey,
      privileged: true,
    },
  ])
    assert.equal((await handler(request(input))).status, 400);
  assert.equal(
    (
      await handler(
        request(
          {
            action: "begin",
            email: "x@school.test",
            idempotency_key: requestKey,
          },
          "",
        ),
      )
    ).status,
    401,
  );
  assert.equal(verified, 0);
});

test("failed local delivery invalidates the issued challenge and exposes no code", async () => {
  const { handler, calls } = makeHandler({
    deliver: async () => {
      throw new Error("private adapter detail");
    },
  });
  const response = await handler(
    request({
      action: "begin",
      email: "Student@school.test",
      idempotency_key: requestKey,
    }),
  );
  const text = await response.text();
  assert.equal(response.status, 503);
  assert.equal(text.includes("042871"), false);
  assert.equal(text.includes("private adapter detail"), false);
  assert.ok(
    calls.some((call) => call[1] === "server_fail_school_challenge_for_actor"),
  );
});

test("server-enforced resend limits map to a safe throttled response", async () => {
  const { handler, calls } = makeHandler({
    command: async () => {
      throw Object.assign(new Error("private database detail"), {
        code: "rate_limited",
      });
    },
  });
  const response = await handler(
    request({
      action: "begin",
      email: "student@school.test",
      idempotency_key: requestKey,
    }),
  );
  const text = await response.text();
  assert.equal(response.status, 429);
  assert.deepEqual(await JSON.parse(text), { error: "rate_limited" });
  assert.equal(text.includes("private database detail"), false);
  assert.equal(
    calls.some((call) => call[0] === "deliver"),
    false,
  );
});

test("retrying the same idempotency key returns the existing challenge without a second delivery", async () => {
  const { handler, calls } = makeHandler({
    command: async () => ({
      issued: false,
      state: "pending",
      challenge_id: "c3efefbd-8c73-47cf-98ba-307416f654a3",
    }),
  });
  const response = await handler(
    request({
      action: "begin",
      email: "student@school.test",
      idempotency_key: requestKey,
    }),
  );
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    challenge_id: "c3efefbd-8c73-47cf-98ba-307416f654a3",
    state: "pending",
  });
  assert.equal(
    calls.some((call) => call[0] === "deliver"),
    false,
  );
});
