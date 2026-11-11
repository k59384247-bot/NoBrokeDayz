import assert from "node:assert/strict";
import test from "node:test";
import { createNotificationReadHandler } from "../../../supabase/functions/_shared/notification-read.mjs";
import { createNotificationDeliveryOpsHandler } from "../../../supabase/functions/_shared/notification-delivery-ops.mjs";
import { createFinancialInspectionHandler } from "../../../supabase/functions/_shared/financial-inspection.mjs";

const actorId = "a0000000-0000-4000-8000-000000000001";
const noticeId = "b0000000-0000-4000-8000-000000000001";
const referenceId = "c0000000-0000-4000-8000-000000000001";
const tokenFor = (sub, aal = "aal1") =>
  `header.${Buffer.from(JSON.stringify({ sub, aal })).toString("base64url")}.sig`;

function request(path, token, body) {
  return new Request(`http://local/${path}`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

test("notice reads derive the recipient and return only safe recipient notices", async () => {
  const calls = [];
  const handler = createNotificationReadHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async (name, args) => {
      calls.push({ name, args });
      return {
        notifications: [
          {
            notification_id: noticeId,
            notification_type: "withdrawal_paid",
            created_at: "2026-11-04T10:00:00.000Z",
            read_at: null,
            provider_payload: "must-not-escape",
          },
        ],
        next_cursor: null,
      };
    },
    requestId: () => "notice-list-request",
  });
  const response = await handler(
    request("notifications-read", tokenFor(actorId), {
      action: "list",
      actor_id: "client-selected-other-user",
    }),
  );

  assert.equal(response.status, 400);
  assert.deepEqual(calls, []);
  const allowed = await handler(
    request("notifications-read", tokenFor(actorId), { action: "list" }),
  );
  assert.equal(allowed.status, 200);
  assert.deepEqual(calls[0], {
    name: "server_list_my_notifications_for_actor",
    args: {
      p_actor: actorId,
      p_before_created_at: null,
      p_before_id: null,
    },
  });
  const body = await allowed.json();
  assert.deepEqual(body.data.notifications, [
    {
      notification_id: noticeId,
      notification_type: "withdrawal_paid",
      title: "Withdrawal paid",
      created_at: "2026-11-04T10:00:00.000Z",
      read_at: null,
      destination: null,
    },
  ]);
  assert.equal(JSON.stringify(body).includes("provider_payload"), false);
});

test("a notice can only be marked read through the recipient-scoped command", async () => {
  const calls = [];
  const handler = createNotificationReadHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async (name, args) => {
      calls.push({ name, args });
      return {
        notification_id: noticeId,
        notification_type: "withdrawal_paid",
        created_at: "2026-11-04T10:00:00Z",
        read_at: "2026-11-04T10:01:00Z",
      };
    },
  });
  const response = await handler(
    request("notifications-read", tokenFor(actorId), {
      action: "mark_read",
      notification_id: noticeId,
    }),
  );

  assert.equal(response.status, 200);
  assert.deepEqual(calls, [
    {
      name: "server_mark_my_notification_read_for_actor",
      args: { p_actor: actorId, p_notification_id: noticeId },
    },
  ]);
  const denied = await handler(
    request("notifications-read", tokenFor(actorId), {
      action: "mark_read",
      notification_id: noticeId,
      recipient_id: referenceId,
    }),
  );
  assert.equal(denied.status, 400);
});

test("notice destinations are allow-listed opaque IDs", async () => {
  const handler = createNotificationReadHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async () => ({
      notifications: [
        {
          notification_id: noticeId,
          notification_type: "application_accepted",
          created_at: "2026-11-04T10:00:00.000Z",
          read_at: null,
          destination_kind: "application",
          destination_id: referenceId,
          destination_url: "https://attacker.invalid",
        },
      ],
      next_cursor: null,
    }),
  });
  const allowed = await handler(
    request("notifications-read", tokenFor(actorId), { action: "list" }),
  );
  assert.equal(allowed.status, 200);
  assert.deepEqual((await allowed.json()).data.notifications[0].destination, {
    kind: "application",
    id: referenceId,
  });

  const invalid = createNotificationReadHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async () => ({
      notifications: [
        {
          notification_id: noticeId,
          notification_type: "application_accepted",
          created_at: "2026-11-04T10:00:00.000Z",
          read_at: null,
          destination_kind: "external_url",
          destination_id: referenceId,
        },
      ],
      next_cursor: null,
    }),
  });
  const rejected = await invalid(
    request("notifications-read", tokenFor(actorId), { action: "list" }),
  );
  assert.equal(rejected.status, 503);
});

test("financial inspection requires the same Auth actor at AAL2", async () => {
  const calls = [];
  const handler = createFinancialInspectionHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async (name, args) => {
      calls.push({ name, args });
      return { reference_id: referenceId, events: [] };
    },
    inspectSimulatorLiquidity: async () => ({
      cashKobo: "0",
      receivableKobo: "0",
    }),
    requestId: () => "ops-inspection-request",
  });
  const denied = await handler(
    request("ops-financial-inspection", tokenFor(actorId, "aal1"), {
      action: "trace",
      reference_type: "operation",
      reference_id: referenceId,
    }),
  );
  assert.equal(denied.status, 403);
  assert.deepEqual(calls, []);

  const allowed = await handler(
    request("ops-financial-inspection", tokenFor(actorId, "aal2"), {
      action: "trace",
      reference_type: "operation",
      reference_id: referenceId,
    }),
  );
  assert.equal(allowed.status, 200);
  assert.deepEqual(calls[0], {
    name: "server_inspect_financial_reference_for_actor",
    args: {
      p_actor: actorId,
      p_auth_aal: "aal2",
      p_reference_type: "operation",
      p_reference_value: referenceId,
    },
  });
  const reconciliationTrace = await handler(
    request("ops-financial-inspection", tokenFor(actorId, "aal2"), {
      action: "trace",
      reference_type: "reconciliation_run",
      reference_id: referenceId,
    }),
  );
  assert.equal(reconciliationTrace.status, 200);
  assert.deepEqual(calls[1], {
    name: "server_inspect_financial_reference_for_actor",
    args: {
      p_actor: actorId,
      p_auth_aal: "aal2",
      p_reference_type: "reconciliation_run",
      p_reference_value: referenceId,
    },
  });
});

test("delivery attention is restricted to the current AAL2 ops command", async () => {
  const calls = [];
  const handler = createNotificationDeliveryOpsHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async (name, args) => {
      calls.push({ name, args });
      return {
        items: [
          {
            delivery_id: noticeId,
            recipient_id: referenceId,
            notification_type: "verification_approved",
            status: "unknown",
            attempt_count: 2,
            safe_error_code: "ambiguous_result",
            created_at: "2026-11-04T10:00:00.000Z",
            updated_at: "2026-11-04T10:01:00.000Z",
            email: "private@example.test",
            provider_payload: "must-not-escape",
          },
        ],
      };
    },
  });
  const denied = await handler(
    request("ops-notification-delivery", tokenFor(actorId, "aal1"), {
      action: "list",
    }),
  );
  assert.equal(denied.status, 403);
  assert.deepEqual(calls, []);

  const allowed = await handler(
    request("ops-notification-delivery", tokenFor(actorId, "aal2"), {
      action: "list",
    }),
  );
  assert.equal(allowed.status, 200);
  assert.deepEqual(calls, [
    {
      name: "server_list_notification_delivery_attention_for_actor",
      args: {
        p_actor: actorId,
        p_auth_aal: "aal2",
        p_before_updated_at: null,
        p_before_delivery_id: null,
      },
    },
  ]);
  const body = await allowed.json();
  assert.equal(body.data.items[0].email, undefined);
  assert.equal(JSON.stringify(body).includes("provider_payload"), false);

  const noGrant = createNotificationDeliveryOpsHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async () => {
      const error = new Error("denied");
      error.code = "staff_access_denied";
      throw error;
    },
  });
  const deniedByCurrentGrant = await noGrant(
    request("ops-notification-delivery", tokenFor(actorId, "aal2"), {
      action: "list",
    }),
  );
  assert.equal(deniedByCurrentGrant.status, 403);
});

test("delivery attention pages use a validated stable cursor", async () => {
  const calls = [];
  const handler = createNotificationDeliveryOpsHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async (name, args) => {
      calls.push({ name, args });
      return calls.length === 1
        ? {
            items: [],
            next_cursor: {
              updated_at: "2026-11-04T10:00:00.000Z",
              id: noticeId,
            },
          }
        : { items: [], next_cursor: null };
    },
  });
  const first = await handler(
    request("ops-notification-delivery", tokenFor(actorId, "aal2"), {
      action: "list",
    }),
  );
  const firstBody = await first.json();
  assert.equal(first.status, 200);
  assert.equal(typeof firstBody.data.next_cursor, "string");
  const second = await handler(
    request("ops-notification-delivery", tokenFor(actorId, "aal2"), {
      action: "list",
      cursor: firstBody.data.next_cursor,
    }),
  );
  assert.equal(second.status, 200);
  assert.deepEqual(calls[1].args, {
    p_actor: actorId,
    p_auth_aal: "aal2",
    p_before_updated_at: "2026-11-04T10:00:00.000Z",
    p_before_delivery_id: noticeId,
  });
  const invalid = await handler(
    request("ops-notification-delivery", tokenFor(actorId, "aal2"), {
      action: "list",
      cursor: "untrusted",
    }),
  );
  assert.equal(invalid.status, 400);
});

test("reconciliation takes its simulator figures from the server adapter", async () => {
  const calls = [];
  const handler = createFinancialInspectionHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async (name, args) => {
      calls.push({ name, args });
      return { run_id: referenceId, findings: [] };
    },
    inspectSimulatorLiquidity: async () => ({
      cashKobo: "12345",
      receivableKobo: "678",
    }),
  });
  const response = await handler(
    request("ops-financial-inspection", tokenFor(actorId, "aal2"), {
      action: "reconcile",
      cash_kobo: "999999",
      receivable_kobo: "999999",
    }),
  );

  assert.equal(response.status, 400);
  assert.deepEqual(calls, []);
  const allowed = await handler(
    request("ops-financial-inspection", tokenFor(actorId, "aal2"), {
      action: "reconcile",
    }),
  );
  assert.equal(allowed.status, 200);
  assert.deepEqual(calls[0], {
    name: "server_reconcile_financial_state_for_actor",
    args: {
      p_actor: actorId,
      p_auth_aal: "aal2",
      p_simulator_cash_kobo: "12345",
      p_simulator_receivable_kobo: "678",
    },
  });
});

test("financial inspection exposes no command for journal or held-case changes", async () => {
  let calls = 0;
  const handler = createFinancialInspectionHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async () => {
      calls++;
      return {};
    },
    inspectSimulatorLiquidity: async () => ({
      cashKobo: "0",
      receivableKobo: "0",
    }),
  });
  const response = await handler(
    request("ops-financial-inspection", tokenFor(actorId, "aal2"), {
      action: "release_held_funds",
      assignment_id: referenceId,
    }),
  );
  assert.equal(response.status, 400);
  assert.equal(calls, 0);
});
