import assert from "node:assert/strict";
import test from "node:test";
import { createMarketplaceCommandHandler } from "../../../supabase/functions/_shared/marketplace-command.mjs";

const actor = "a0000000-0000-4000-8000-000000000001";
const jobId = "b0000000-0000-4000-8000-000000000001";
const key = "c0000000-0000-4000-8000-000000000001";
const operationId = "d0000000-0000-4000-8000-000000000001";
const jsonHeaders = {
  authorization: "Bearer valid-session",
  "content-type": "application/json",
};

function setup({ rpcResult, initialize, lookup, rpcError } = {}) {
  const calls = [];
  const handler = createMarketplaceCommandHandler({
    verifyActor: async () => ({ id: actor }),
    rpc: async (name, args) => {
      calls.push({ name, args });
      if (rpcError) throw rpcError;
      return typeof rpcResult === "function"
        ? rpcResult(name, args)
        : (rpcResult ?? { job_id: jobId, listing_state: "draft" });
    },
    paymentAdapter: {
      initializeCollection:
        initialize ??
        (async (operation) => ({
          reference: `sim-${operation.idempotencyKey}`,
          clientReference: operation.idempotencyKey,
          status: "succeeded",
        })),
      lookupOriginalOperation: lookup ?? (async () => null),
    },
    requestId: () => "request-step4",
  });
  return { handler, calls };
}

test("draft commands derive the actor from the verified session", async () => {
  const { handler, calls } = setup();
  const response = await handler(
    new Request("http://local/marketplace-command", {
      method: "POST",
      headers: jsonHeaders,
      body: JSON.stringify({
        action: "create_job_draft",
        actor_id: "ffffffff-ffff-4fff-8fff-ffffffffffff",
        idempotency_key: key,
        terms: { title: "Synthetic campus task" },
      }),
    }),
  );
  assert.equal(response.status, 400);
  assert.equal(calls.length, 0);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.equal(response.headers.get("x-request-id"), "request-step4");
});

test("draft updates bind the verified actor, expected version and replacement terms", async () => {
  const calls = [];
  const terms = {
    title: "Updated synthetic task",
    description: "A revised draft description.",
  };
  const handler = createMarketplaceCommandHandler({
    verifyActor: async () => ({ id: actor }),
    rpc: async (name, args) => {
      calls.push({ name, args });
      return {
        job_id: jobId,
        terms_version: 2,
        listing_state: "draft",
        gross_total_kobo: "900000",
      };
    },
    requestId: () => "request-update-draft",
  });
  const response = await handler(
    new Request("http://local/marketplace-command", {
      method: "POST",
      headers: jsonHeaders,
      body: JSON.stringify({
        action: "update_job_draft",
        job_id: jobId,
        expected_terms_version: 1,
        terms,
        idempotency_key: key,
      }),
    }),
  );
  const body = await response.json();
  assert.equal(response.status, 200);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].name, "server_update_job_draft_for_actor");
  assert.deepEqual(calls[0].args, {
    p_actor: actor,
    p_job_id: jobId,
    p_expected_terms_version: 1,
    p_terms: terms,
    p_idempotency_key: key,
  });
  assert.equal(body.job.terms_version, 2);
  assert.equal(body.job.gross_total_kobo, "900000");
  assert.equal(body.request_id, "request-update-draft");
});

test("draft update returns safe not-found and stale-state responses from its database boundary", async () => {
  for (const [code, status, errorCode] of [
    ["P0002", 404, "not_found"],
    ["P0001", 409, "stale_state"],
  ]) {
    const calls = [];
    const handler = createMarketplaceCommandHandler({
      verifyActor: async () => ({ id: actor }),
      rpc: async (name, args) => {
        calls.push({ name, args });
        throw Object.assign(new Error("database details are private"), {
          code,
        });
      },
      requestId: () => "request-update-draft-error",
    });
    const response = await handler(
      new Request("http://local/marketplace-command", {
        method: "POST",
        headers: jsonHeaders,
        body: JSON.stringify({
          action: "update_job_draft",
          job_id: jobId,
          expected_terms_version: 1,
          terms: { title: "Synthetic title" },
          idempotency_key: key,
        }),
      }),
    );
    assert.equal(response.status, status);
    assert.equal((await response.json()).error.code, errorCode);
    assert.equal(calls[0].name, "server_update_job_draft_for_actor");
    assert.equal(response.headers.get("cache-control"), "no-store");
  }
});

test("funding initializes only the persisted server operation and browser success stays pending", async () => {
  let initialized;
  const { handler, calls } = setup({
    rpcResult: (name) =>
      name === "server_start_job_funding_for_actor"
        ? {
            funding_intent_id: "e0000000-0000-4000-8000-000000000001",
            operation_id: operationId,
            provider_idempotency_key: "f0000000-0000-4000-8000-000000000001",
            amount_kobo: "900000",
            currency: "NGN",
            merchant_identity: "fake_nbd_local_merchant_v1",
            listing_state: "awaiting_payment",
          }
        : {
            provider_reference: `sim-${"f0000000-0000-4000-8000-000000000001"}`,
          },
    initialize: async (operation) => {
      initialized = operation;
      return {
        reference: `sim-${operation.idempotencyKey}`,
        clientReference: operation.idempotencyKey,
        amountKobo: "900000",
        currency: "NGN",
        status: "succeeded",
      };
    },
  });
  const response = await handler(
    new Request("http://local/marketplace-command", {
      method: "POST",
      headers: jsonHeaders,
      body: JSON.stringify({
        action: "fund_job",
        job_id: jobId,
        expected_terms_version: 1,
        idempotency_key: key,
      }),
    }),
  );
  const body = await response.json();
  assert.equal(response.status, 202);
  assert.deepEqual(initialized, {
    operationId,
    idempotencyKey: "f0000000-0000-4000-8000-000000000001",
    amountKobo: "900000",
    currency: "NGN",
    merchantIdentity: "fake_nbd_local_merchant_v1",
  });
  assert.equal(body.status, "pending");
  assert.equal(body.listing_state, "awaiting_payment");
  assert.equal(body.expected_gross_kobo, "900000");
  assert.equal(body.provider_reference, `sim-${initialized.idempotencyKey}`);
  assert.equal(
    calls.some(
      ({ name }) => name === "server_record_job_funding_initialization",
    ),
    true,
  );
  assert.equal(body.operation_status, undefined);
});

test("a lost initialization response remains unknown and records no success claim", async () => {
  const { handler, calls } = setup({
    rpcResult: (name) =>
      name === "server_start_job_funding_for_actor"
        ? {
            funding_intent_id: "e0000000-0000-4000-8000-000000000001",
            operation_id: operationId,
            provider_idempotency_key: "f0000000-0000-4000-8000-000000000001",
            amount_kobo: "300000",
            currency: "NGN",
            merchant_identity: "fake_nbd_local_merchant_v1",
            listing_state: "awaiting_payment",
          }
        : { status: "unknown" },
    initialize: async () => {
      throw new Error("simulator timeout after acceptance");
    },
  });
  const response = await handler(
    new Request("http://local/marketplace-command", {
      method: "POST",
      headers: jsonHeaders,
      body: JSON.stringify({
        action: "fund_job",
        job_id: jobId,
        expected_terms_version: 1,
        idempotency_key: key,
      }),
    }),
  );
  const body = await response.json();
  assert.equal(response.status, 202);
  assert.equal(body.status, "unknown");
  assert.equal(body.listing_state, "awaiting_payment");
  assert.equal(
    calls.at(-1).name,
    "server_record_job_funding_unknown_for_actor",
  );
  assert.equal(body.provider_reference, null);
});

test("an explicit unknown simulator result is persisted and returned as unknown", async () => {
  const { handler, calls } = setup({
    rpcResult: (name) => {
      if (name === "server_start_job_funding_for_actor")
        return {
          funding_intent_id: "e0000000-0000-4000-8000-000000000001",
          operation_id: operationId,
          provider_idempotency_key: "f0000000-0000-4000-8000-000000000001",
          amount_kobo: "900000",
          currency: "NGN",
          merchant_identity: "fake_nbd_local_merchant_v1",
          listing_state: "awaiting_payment",
        };
      if (name === "server_record_job_funding_unknown_for_actor")
        return {
          status: "unknown",
          provider_reference: `sim-${"f0000000-0000-4000-8000-000000000001"}`,
        };
      return {
        status: "pending",
        provider_reference: `sim-${"f0000000-0000-4000-8000-000000000001"}`,
      };
    },
    initialize: async (operation) => ({
      reference: `sim-${operation.idempotencyKey}`,
      clientReference: operation.idempotencyKey,
      status: "unknown",
    }),
  });
  const response = await handler(
    new Request("http://local/marketplace-command", {
      method: "POST",
      headers: jsonHeaders,
      body: JSON.stringify({
        action: "fund_job",
        job_id: jobId,
        expected_terms_version: 1,
        idempotency_key: key,
      }),
    }),
  );
  const body = await response.json();
  assert.equal(response.status, 202);
  assert.equal(body.status, "unknown");
  assert.equal(body.listing_state, "awaiting_payment");
  assert.ok(
    calls.some(
      ({ name }) => name === "server_record_job_funding_unknown_for_actor",
    ),
  );
});

test("idempotency conflicts are safe HTTP conflicts without database details", async () => {
  const { handler } = setup({
    rpcError: Object.assign(new Error("idempotency_conflict"), {
      code: "23505",
    }),
  });
  const response = await handler(
    new Request("http://local/marketplace-command", {
      method: "POST",
      headers: jsonHeaders,
      body: JSON.stringify({
        action: "create_job_draft",
        idempotency_key: key,
        terms: {},
      }),
    }),
  );
  assert.equal(response.status, 409);
  assert.deepEqual(await response.json(), {
    error: {
      code: "idempotency_conflict",
      message: "This request key was already used with different information.",
    },
    request_id: "request-step4",
  });
});

test("funding does not persist an intent when the local simulator is disabled", async () => {
  const calls = [];
  const handler = createMarketplaceCommandHandler({
    verifyActor: async () => ({ id: actor }),
    rpc: async (name) => {
      calls.push(name);
      return { operation_id: operationId };
    },
  });
  const response = await handler(
    new Request("http://local/marketplace-command", {
      method: "POST",
      headers: jsonHeaders,
      body: JSON.stringify({
        action: "fund_job",
        job_id: jobId,
        expected_terms_version: 1,
        idempotency_key: key,
      }),
    }),
  );
  assert.equal(response.status, 503);
  assert.deepEqual(calls, []);
  assert.equal((await response.json()).error.code, "service_unavailable");
});

test("Step 3 cancellation commands derive the actor and call only their scoped database command", async () => {
  const assignmentId = "10000000-0000-4000-8000-000000000001";
  const allocationId = "20000000-0000-4000-8000-000000000001";
  const cancellationId = "30000000-0000-4000-8000-000000000001";
  const actions = [
    {
      body: {
        action: "cancel_unassigned_slots",
        job_id: jobId,
        allocation_ids: [allocationId],
        reason: "This slot is no longer needed.",
        idempotency_key: key,
      },
      rpc: "server_cancel_unassigned_slots_for_actor",
      args: {
        p_actor: actor,
        p_job_id: jobId,
        p_allocation_ids: [allocationId],
        p_reason: "This slot is no longer needed.",
        p_idempotency_key: key,
      },
    },
    {
      body: {
        action: "request_prestart_cancellation",
        assignment_id: assignmentId,
        reason: "The parties agreed to stop before work starts.",
        idempotency_key: key,
      },
      rpc: "server_request_prestart_cancellation_for_actor",
      args: {
        p_actor: actor,
        p_assignment_id: assignmentId,
        p_reason: "The parties agreed to stop before work starts.",
        p_idempotency_key: key,
      },
    },
    {
      body: {
        action: "consent_prestart_cancellation",
        cancellation_id: cancellationId,
        cancellation_version: 1,
        reason: "I agree to cancel before work starts.",
        idempotency_key: key,
      },
      rpc: "server_consent_prestart_cancellation_for_actor",
      args: {
        p_actor: actor,
        p_cancellation_id: cancellationId,
        p_cancellation_version: 1,
        p_reason: "I agree to cancel before work starts.",
        p_idempotency_key: key,
      },
    },
    {
      body: {
        action: "abandon_prestart_assignment",
        assignment_id: assignmentId,
        reason: "I can no longer do this work.",
        idempotency_key: key,
      },
      rpc: "server_abandon_prestart_assignment_for_actor",
      args: {
        p_actor: actor,
        p_assignment_id: assignmentId,
        p_reason: "I can no longer do this work.",
        p_idempotency_key: key,
      },
    },
  ];

  for (const entry of actions) {
    const calls = [];
    const handler = createMarketplaceCommandHandler({
      verifyActor: async () => ({ id: actor }),
      rpc: async (name, args) => {
        calls.push({ name, args });
        return { accepted: true };
      },
      requestId: () => "request-step3-cancellation",
    });
    const response = await handler(
      new Request("http://local/marketplace-command", {
        method: "POST",
        headers: jsonHeaders,
        body: JSON.stringify(entry.body),
      }),
    );
    assert.equal(response.status, 200, entry.body.action);
    assert.deepEqual(calls, [{ name: entry.rpc, args: entry.args }]);
  }
});

test("Step 3 cancellation rejects duplicate slots, client actor identity and invalid versions before RPC", async () => {
  const calls = [];
  const handler = createMarketplaceCommandHandler({
    verifyActor: async () => ({ id: actor }),
    rpc: async (...args) => calls.push(args),
    requestId: () => "request-step3-invalid",
  });
  const allocationId = "20000000-0000-4000-8000-000000000001";
  const invalidInputs = [
    {
      action: "cancel_unassigned_slots",
      job_id: jobId,
      allocation_ids: [allocationId, allocationId],
      reason: "Cancel these slots.",
      idempotency_key: key,
    },
    {
      action: "cancel_unassigned_slots",
      actor_id: actor,
      job_id: jobId,
      allocation_ids: [allocationId],
      reason: "Cancel this slot.",
      idempotency_key: key,
    },
    {
      action: "consent_prestart_cancellation",
      cancellation_id: "30000000-0000-4000-8000-000000000001",
      cancellation_version: 0,
      reason: "I agree.",
      idempotency_key: key,
    },
    {
      action: "request_prestart_cancellation",
      assignment_id: "not-an-assignment-id",
      reason: "The parties agree to stop before work starts.",
      idempotency_key: key,
    },
    {
      action: "consent_prestart_cancellation",
      cancellation_id: "30000000-0000-4000-8000-000000000001",
      cancellation_version: 1,
      reason: " ",
      idempotency_key: key,
    },
    {
      action: "abandon_prestart_assignment",
      assignment_id: "10000000-0000-4000-8000-000000000001",
      reason: " ",
      idempotency_key: key,
    },
  ];
  for (const input of invalidInputs) {
    const response = await handler(
      new Request("http://local/marketplace-command", {
        method: "POST",
        headers: jsonHeaders,
        body: JSON.stringify(input),
      }),
    );
    assert.equal(response.status, 400);
    assert.equal((await response.json()).error.code, "invalid_request");
  }
  assert.deepEqual(calls, []);
});
