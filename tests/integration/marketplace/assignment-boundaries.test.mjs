import assert from "node:assert/strict";
import test from "node:test";
import { createMarketplaceCommandHandler } from "../../../supabase/functions/_shared/marketplace-command.mjs";
import { createMarketplaceReadHandler } from "../../../supabase/functions/_shared/marketplace-read.mjs";

const actor = "a0000000-0000-4000-8000-000000000001";
const assignmentId = "b0000000-0000-4000-8000-000000000001";
const key = "c0000000-0000-4000-8000-000000000001";
const headers = {
  authorization: "Bearer valid-session",
  "content-type": "application/json",
};

function commandRequest(body) {
  return new Request("http://local/marketplace-command", {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
}

function readRequest(body) {
  return new Request("http://local/marketplace-read", {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
}

test("work stage commands derive the actor and call narrow server functions", async () => {
  const calls = [];
  const handler = createMarketplaceCommandHandler({
    verifyActor: async () => ({ id: actor }),
    rpc: async (name, args) => {
      calls.push({ name, args });
      return { assignment_id: assignmentId, assignment_state: "in_progress" };
    },
    requestId: () => "request-start",
  });
  const response = await handler(
    commandRequest({
      action: "start_assignment",
      assignment_id: assignmentId,
      idempotency_key: key,
      actor_id: "client-cannot-choose-this",
    }),
  );
  assert.equal(response.status, 400);
  assert.deepEqual(calls, []);

  const started = await handler(
    commandRequest({
      action: "start_assignment",
      assignment_id: assignmentId,
      idempotency_key: key,
    }),
  );
  assert.equal(started.status, 200);
  assert.deepEqual(calls[0], {
    name: "server_start_assignment_for_actor",
    args: {
      p_actor: actor,
      p_assignment_id: assignmentId,
      p_idempotency_key: key,
    },
  });
});

test("a participant hold report has bounded structured input", async () => {
  const calls = [];
  const handler = createMarketplaceCommandHandler({
    verifyActor: async () => ({ id: actor }),
    rpc: async (name, args) => {
      calls.push({ name, args });
      return {
        assignment: {
          assignment_id: assignmentId,
          assignment_state: "submitted",
          started_at: "2026-11-04T09:00:00Z",
          submitted_at: "2026-11-04T09:30:00Z",
          completed_at: null,
        },
        hold: { status: "open", prior_assignment_state: "submitted" },
      };
    },
    requestId: () => "request-hold",
  });
  const invalid = await handler(
    commandRequest({
      action: "open_assignment_hold",
      assignment_id: assignmentId,
      reason_code: "payment_not_released;release_now",
      narrative: "A report",
      desired_outcome: "Please review",
      idempotency_key: key,
    }),
  );
  assert.equal(invalid.status, 400);
  assert.deepEqual(calls, []);

  const oversizedFollowUp = await handler(
    commandRequest({
      action: "open_assignment_hold",
      assignment_id: assignmentId,
      reason_code: "work_not_as_described",
      narrative: "A report",
      desired_outcome: "Please review",
      follow_up: "x".repeat(501),
      idempotency_key: key,
    }),
  );
  assert.equal(oversizedFollowUp.status, 400);
  assert.deepEqual(calls, []);

  const response = await handler(
    commandRequest({
      action: "open_assignment_hold",
      assignment_id: assignmentId,
      reason_code: "work_not_as_described",
      narrative: "The delivered item did not match the agreed terms.",
      desired_outcome: "Please review the delivery.",
      follow_up: "Please check the delivery note.",
      idempotency_key: key,
    }),
  );
  assert.equal(response.status, 201);
  assert.equal(calls[0].name, "server_open_assignment_hold_for_actor");
  assert.deepEqual(calls[0].args, {
    p_actor: actor,
    p_assignment_id: assignmentId,
    p_reason_code: "work_not_as_described",
    p_narrative: "The delivered item did not match the agreed terms.",
    p_desired_outcome: "Please review the delivery.",
    p_follow_up: "Please check the delivery note.",
    p_idempotency_key: key,
  });
});

test("assignment status is participant scoped and strips private provider fields", async () => {
  const calls = [];
  const handler = createMarketplaceReadHandler({
    verifyActor: async () => ({ id: actor }),
    rpc: async (name, args) => {
      calls.push({ name, args });
      return {
        assignment: {
          assignment_id: assignmentId,
          application_id: "d0000000-0000-4000-8000-000000000001",
          thread_id: "e0000000-0000-4000-8000-000000000001",
          job_id: "f0000000-0000-4000-8000-000000000001",
          assignment_state: "submitted",
          started_at: "2026-11-04T09:00:00Z",
          submitted_at: "2026-11-04T09:30:00Z",
          completed_at: null,
          hold_status: "open",
          earnings_status: "on_hold",
          terms_version: 1,
          gross_principal_kobo: "300000",
          commission_kobo: "15000",
          worker_net_kobo: "285000",
          commission_basis_points: 500,
          worker_email: "private@example.test",
          bank_account: "never-return-this",
        },
        hold: {
          hold_id: "10000000-0000-4000-8000-000000000001",
          status: "open",
          prior_assignment_state: "submitted",
          reason_code: "work_not_as_described",
          narrative: "The item differs from the terms.",
          desired_outcome: "Please review it.",
          opened_at: "2026-11-04T10:00:00Z",
          internal_case_note: "never-return-this",
        },
      };
    },
    requestId: () => "request-assignment-status",
  });
  const response = await handler(
    readRequest({ action: "assignment_status", assignment_id: assignmentId }),
  );
  assert.equal(response.status, 200);
  assert.deepEqual(calls, [
    {
      name: "server_get_assignment_status_for_actor",
      args: { p_actor: actor, p_assignment_id: assignmentId },
    },
  ]);
  const body = await response.json();
  assert.equal(body.data.assignment.earnings_status, "on_hold");
  assert.equal(body.data.hold.reason_code, "work_not_as_described");
  assert.equal("worker_email" in body.data.assignment, false);
  assert.equal("bank_account" in body.data.assignment, false);
  assert.equal("internal_case_note" in body.data.hold, false);
});
