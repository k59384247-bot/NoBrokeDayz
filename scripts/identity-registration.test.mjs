import assert from "node:assert/strict";
import test from "node:test";
import { createIdentityRegistrationHandler } from "../supabase/functions/_shared/identity-registration.mjs";

const authSubject = "11111111-1111-4111-8111-111111111111";

test("registration derives the actor from the verified Auth user, not request JSON", async () => {
  const calls = [];
  const handler = createIdentityRegistrationHandler({
    supabaseUrl: "http://127.0.0.1:23161",
    anonKey: "local-anon",
    serviceRoleKey: "server-only-secret",
    fetchImpl: async (url, options) => {
      calls.push({ url, options });
      if (url.endsWith("/auth/v1/user")) {
        return Response.json({
          id: authSubject,
          email: "synthetic@example.test",
        });
      }
      return Response.json({
        registered: true,
        account_type: "student",
        age_confirmed: true,
        verification_status: "unverified",
      });
    },
  });

  const response = await handler(
    new Request("http://edge.local/identity-register", {
      method: "POST",
      headers: {
        authorization: "Bearer valid-user-access-token",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        account_type: "student",
        age_confirmed: true,
        age_policy_version: "age-18-v1",
      }),
    }),
  );

  assert.equal(response.status, 200);
  assert.equal(calls.length, 2);
  assert.equal(
    calls[0].options.headers.authorization,
    "Bearer valid-user-access-token",
  );
  assert.equal(
    calls[1].options.headers.authorization,
    "Bearer server-only-secret",
  );
  assert.deepEqual(JSON.parse(calls[1].options.body), {
    p_actor: authSubject,
    p_account_type: "student",
    p_age_confirmed: true,
    p_age_policy_version: "age-18-v1",
  });
  assert.equal((await response.json()).verification_status, "unverified");
});

test("request JSON cannot supply an actor or protected account fields", async () => {
  let calls = 0;
  const handler = createIdentityRegistrationHandler({
    supabaseUrl: "http://127.0.0.1:23161",
    anonKey: "local-anon",
    serviceRoleKey: "server-only-secret",
    fetchImpl: async () => {
      calls += 1;
      return Response.json({ id: authSubject });
    },
  });

  for (const body of [
    {
      account_type: "student",
      age_confirmed: true,
      age_policy_version: "age-18-v1",
      actor_id: authSubject,
    },
    {
      account_type: "student",
      age_confirmed: true,
      age_policy_version: "age-18-v1",
      is_staff: true,
    },
    {
      account_type: "student",
      age_confirmed: true,
      age_policy_version: "age-18-v1",
      verification_status: "approved",
    },
  ]) {
    const response = await handler(
      new Request("http://edge.local/identity-register", {
        method: "POST",
        headers: {
          authorization: "Bearer valid-user-access-token",
          "content-type": "application/json",
        },
        body: JSON.stringify(body),
      }),
    );
    assert.equal(response.status, 400);
  }
  assert.equal(calls, 0);
});

test("missing or invalid Auth credentials cannot reach the privileged RPC", async () => {
  let calls = 0;
  const handler = createIdentityRegistrationHandler({
    supabaseUrl: "http://127.0.0.1:23161",
    anonKey: "local-anon",
    serviceRoleKey: "server-only-secret",
    fetchImpl: async () => {
      calls += 1;
      return new Response("unauthorized", { status: 401 });
    },
  });

  const missing = await handler(
    new Request("http://edge.local/identity-register", { method: "POST" }),
  );
  assert.equal(missing.status, 401);
  const invalid = await handler(
    new Request("http://edge.local/identity-register", {
      method: "POST",
      headers: {
        authorization: "Bearer invalid-token",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        account_type: "student",
        age_confirmed: true,
        age_policy_version: "age-18-v1",
      }),
    }),
  );
  assert.equal(invalid.status, 401);
  assert.equal(calls, 1);
});

test("Auth or database outages return safe errors without exposing credentials", async () => {
  const handler = createIdentityRegistrationHandler({
    supabaseUrl: "http://127.0.0.1:23161",
    anonKey: "local-anon",
    serviceRoleKey: "server-only-secret",
    fetchImpl: async (url) => {
      if (url.endsWith("/auth/v1/user"))
        return Response.json({ id: authSubject });
      return new Response("sensitive database detail", { status: 500 });
    },
  });
  const response = await handler(
    new Request("http://edge.local/identity-register", {
      method: "POST",
      headers: {
        authorization: "Bearer valid-user-access-token",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        account_type: "student",
        age_confirmed: true,
        age_policy_version: "age-18-v1",
      }),
    }),
  );
  assert.equal(response.status, 503);
  const errorBody = await response.text();
  assert.match(errorBody, /identity_unavailable/);
  assert.doesNotMatch(
    errorBody,
    /sensitive database detail|server-only-secret/,
  );
});
