import assert from "node:assert/strict";
import { test } from "node:test";
import { createProfileCommandHandler } from "../../../supabase/functions/_shared/profile-command.mjs";

const actor = "8c5de580-8d71-4f00-a44e-859cba363e54";
const subject = "0bfc5c8c-d39b-4412-a466-a1a507974b64";
const makeRequest = (body, token = "verified-token") =>
  new Request("http://local.test/profile-command", {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });

test("profile edits derive the actor and reject mass-assignment keys", async () => {
  const calls = [];
  const handler = createProfileCommandHandler({
    verifyActor: async () => ({ id: actor }),
    command: async (...args) => {
      calls.push(args);
      return { display_name: "Synthetic Name" };
    },
    requestId: () => "profile-test-request-1",
  });
  const valid = await handler(
    makeRequest({
      action: "update",
      profile: {
        display_name: "Synthetic Name",
        skills: ["Research"],
        campus_id: "00000000-0000-0000-0000-000000000001",
      },
    }),
  );
  assert.equal(valid.status, 200);
  assert.equal(valid.headers.get("x-request-id"), "profile-test-request-1");
  assert.deepEqual(calls[0], [
    "server_update_profile_for_actor",
    {
      p_actor: actor,
      p_profile: {
        display_name: "Synthetic Name",
        skills: ["Research"],
        campus_id: "00000000-0000-0000-0000-000000000001",
      },
    },
  ]);
  for (const protectedKey of [
    "actor_id",
    "user_type",
    "account_type",
    "verified_badge",
    "capabilities",
    "staff_capabilities",
    "completed_work_count",
    "worker_review_count",
    "poster_rating",
    "phone",
    "legal_name",
  ]) {
    const response = await handler(
      makeRequest({
        action: "update",
        profile: { display_name: "Synthetic Name", [protectedKey]: true },
      }),
    );
    assert.equal(
      response.status,
      400,
      `${protectedKey} cannot be mass-assigned`,
    );
    assert.equal((await response.json()).error, "invalid_profile");
  }
  assert.equal(
    calls.length,
    1,
    "invalid writes never reach the database command",
  );
  assert.equal(
    (
      await handler(
        makeRequest({ action: "update", profile: { campus_label: "Made up" } }),
      )
    ).status,
    400,
    "clients select only configured campus IDs, never supply display labels",
  );
});

test("profile lookup derives its viewer and accepts only one target identifier", async () => {
  const calls = [];
  const handler = createProfileCommandHandler({
    verifyActor: async () => ({ id: actor }),
    command: async (...args) => {
      calls.push(args);
      return { verified_badge: true };
    },
    requestId: () => "profile-test-request-2",
  });
  const response = await handler(
    makeRequest({ action: "view", profile_id: subject }),
  );
  assert.equal(response.status, 200);
  assert.deepEqual(calls[0], [
    "server_get_safe_profile_for_viewer",
    {
      p_viewer: actor,
      p_subject: subject,
    },
  ]);
  for (const body of [
    { action: "view", profile_id: subject, viewer_id: subject },
    { action: "view", profile_id: "not-a-uuid" },
    { action: "view", profile_id: subject, include_private: true },
  ]) {
    assert.equal((await handler(makeRequest(body))).status, 400);
  }
  assert.equal(calls.length, 1);
});

test("profile command errors use safe stable categories and request IDs", async () => {
  const handler = createProfileCommandHandler({
    verifyActor: async () => ({ id: actor }),
    command: async (name) => {
      const error = new Error("private postgres detail must not escape");
      error.code =
        name === "server_update_profile_for_actor" ? "22023" : "P0002";
      throw error;
    },
    requestId: () => "profile-test-request-3",
  });
  const invalid = await handler(
    makeRequest({ action: "update", profile: { bio: "x" } }),
  );
  assert.equal(invalid.status, 400);
  assert.deepEqual(await invalid.json(), {
    error: "invalid_profile",
    request_id: "profile-test-request-3",
  });
  const unavailable = await handler(
    makeRequest({ action: "view", profile_id: subject }),
  );
  assert.equal(unavailable.status, 404);
  const body = await unavailable.json();
  assert.equal(body.error, "profile_not_found");
  assert.equal(body.request_id, "profile-test-request-3");
  assert.equal(JSON.stringify(body).includes("postgres"), false);
});

test("invalid Auth sessions are rejected before profile commands", async () => {
  let commands = 0;
  const handler = createProfileCommandHandler({
    verifyActor: async (token) => (token === "good" ? { id: actor } : null),
    command: async () => {
      commands += 1;
      return {};
    },
  });
  const response = await handler(
    makeRequest({ action: "view", profile_id: subject }, "expired"),
  );
  assert.equal(response.status, 401);
  assert.equal((await response.json()).error, "authentication_required");
  assert.equal(commands, 0);
});
