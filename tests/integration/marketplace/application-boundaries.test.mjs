import assert from "node:assert/strict";
import test from "node:test";
import { createMarketplaceCommandHandler } from "../../../supabase/functions/_shared/marketplace-command.mjs";

const actor = "a0000000-0000-4000-8000-000000000001";
const jobId = "b0000000-0000-4000-8000-000000000001";
const key = "c0000000-0000-4000-8000-000000000001";

test("an authenticated student applies through an actor-bound command", async () => {
  const calls = [];
  const handler = createMarketplaceCommandHandler({
    verifyActor: async () => ({ id: actor }),
    rpc: async (name, args) => {
      calls.push({ name, args });
      return {
        application_id: "d0000000-0000-4000-8000-000000000001",
        thread_id: "e0000000-0000-4000-8000-000000000001",
        state: "applied",
        applied_at: "2026-11-04T10:00:00Z",
      };
    },
    requestId: () => "request-application",
  });
  const response = await handler(
    new Request("http://local/marketplace-command", {
      method: "POST",
      headers: {
        authorization: "Bearer valid-session",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        action: "apply_to_job",
        job_id: jobId,
        note: "I can do this after my lecture.",
        idempotency_key: key,
      }),
    }),
  );
  assert.equal(response.status, 201);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].name, "server_apply_to_job_for_actor");
  assert.deepEqual(calls[0].args, {
    p_actor: actor,
    p_job_id: jobId,
    p_note: "I can do this after my lecture.",
    p_idempotency_key: key,
  });
  assert.equal((await response.json()).application.state, "applied");
});

test("the owning poster accepts an application through a separate command", async () => {
  const calls = [];
  const applicationId = "d0000000-0000-4000-8000-000000000001";
  const handler = createMarketplaceCommandHandler({
    verifyActor: async () => ({ id: actor }),
    rpc: async (name, args) => {
      calls.push({ name, args });
      return {
        application_id: applicationId,
        assignment_id: "e0000000-0000-4000-8000-000000000001",
        thread_id: "f0000000-0000-4000-8000-000000000001",
        assignment_state: "assigned",
        terms_version: 1,
        gross_principal_kobo: "300000",
      };
    },
    requestId: () => "request-acceptance",
  });
  const response = await handler(
    new Request("http://local/marketplace-command", {
      method: "POST",
      headers: {
        authorization: "Bearer valid-session",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        action: "accept_application",
        application_id: applicationId,
        idempotency_key: key,
      }),
    }),
  );
  assert.equal(response.status, 200);
  assert.equal(calls[0].name, "server_accept_application_for_actor");
  assert.deepEqual(calls[0].args, {
    p_actor: actor,
    p_application_id: applicationId,
    p_idempotency_key: key,
  });
  assert.equal((await response.json()).assignment.assignment_state, "assigned");
});

test("a message uses its client ID and is acknowledged from the saved RPC result", async () => {
  const calls = [];
  const threadId = "d0000000-0000-4000-8000-000000000002";
  const clientMessageId = "e0000000-0000-4000-8000-000000000002";
  const handler = createMarketplaceCommandHandler({
    verifyActor: async () => ({ id: actor }),
    rpc: async (name, args) => {
      calls.push({ name, args });
      return {
        message_id: "f0000000-0000-4000-8000-000000000002",
        thread_id: threadId,
        client_message_id: clientMessageId,
        sequence: "9223372036854775807",
        body: "I can meet at noon.",
        replayed: false,
      };
    },
  });
  const response = await handler(
    new Request("http://local/marketplace-command", {
      method: "POST",
      headers: {
        authorization: "Bearer valid-session",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        action: "send_application_message",
        thread_id: threadId,
        client_message_id: clientMessageId,
        body: " I can meet at noon. ",
      }),
    }),
  );
  assert.equal(response.status, 201);
  assert.equal(calls[0].name, "server_send_application_message_for_actor");
  assert.deepEqual(calls[0].args, {
    p_actor: actor,
    p_thread_id: threadId,
    p_client_message_id: clientMessageId,
    p_body: "I can meet at noon.",
  });
  assert.equal((await response.json()).message.sequence, "9223372036854775807");
});

test("reject and withdraw use distinct actor-bound commands", async () => {
  const applicationId = "d0000000-0000-4000-8000-000000000003";
  const actions = [
    ["reject_application", "server_reject_application_for_actor"],
    ["withdraw_application", "server_withdraw_application_for_actor"],
  ];
  for (const [action, expectedRpc] of actions) {
    const calls = [];
    const handler = createMarketplaceCommandHandler({
      verifyActor: async () => ({ id: actor }),
      rpc: async (name, args) => {
        calls.push({ name, args });
        return { application_id: applicationId, state: action };
      },
      requestId: () => `request-${action}`,
    });
    const response = await handler(
      new Request("http://local/marketplace-command", {
        method: "POST",
        headers: {
          authorization: "Bearer valid-session",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          action,
          application_id: applicationId,
          idempotency_key: key,
        }),
      }),
    );
    assert.equal(response.status, 200);
    assert.equal(calls[0].name, expectedRpc);
    assert.deepEqual(calls[0].args, {
      p_actor: actor,
      p_application_id: applicationId,
      p_idempotency_key: key,
    });
  }
});
