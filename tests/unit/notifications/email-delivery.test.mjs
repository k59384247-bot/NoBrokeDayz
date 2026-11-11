import assert from "node:assert/strict";
import test from "node:test";
import { createLocalEmailCaptureAdapter } from "../../../supabase/functions/_shared/local-email-capture.mjs";
import { runNotificationEmailDelivery } from "../../../supabase/functions/_shared/notification-email-runner.mjs";
import { startLocalNotificationEmailCapture } from "../../../scripts/test-support/local-notification-email-capture.mjs";

const deliveryId = "a0000000-0000-4000-8000-000000000001";
const recipientId = "b0000000-0000-4000-8000-000000000001";
const lease = (digit) => `c0000000-0000-4000-8000-00000000000${digit}`;

test("capture retries reconcile a stable delivery ID after a lost completion", async () => {
  const capture = await startLocalNotificationEmailCapture();
  try {
    const adapter = createLocalEmailCaptureAdapter(capture);
    let claimCount = 0;
    let completionCount = 0;
    let sends = 0;
    const completed = [];
    const dependencies = {
      claim: async () => ({
        delivery_id: deliveryId,
        lease_token: lease(++claimCount),
        recipient_id: recipientId,
        notification_type: "application_accepted",
        previous_status: claimCount === 1 ? "pending" : "unknown",
      }),
      complete: async (result) => {
        completionCount++;
        if (completionCount === 1)
          throw new Error("simulated worker crash after capture");
        completed.push(result);
      },
      resolveRecipient: async () => "synthetic@identity.test",
      authorizeDispatch: async () => true,
      adapter: {
        ...adapter,
        send: async (message) => {
          sends++;
          return adapter.send(message);
        },
      },
    };

    await assert.rejects(
      runNotificationEmailDelivery(dependencies),
      /simulated worker crash/,
    );
    assert.equal(capture.count(deliveryId), 1);
    await runNotificationEmailDelivery(dependencies);
    assert.equal(sends, 1);
    assert.equal(capture.count(deliveryId), 1);
    assert.equal(completed[0].deliveryId, deliveryId);
    assert.equal(completed[0].status, "provider_accepted");
  } finally {
    await capture.close();
  }
});

test("ambiguous lookup is visible and never causes a blind second send", async () => {
  const completed = [];
  let sends = 0;
  await runNotificationEmailDelivery({
    claim: async () => ({
      delivery_id: deliveryId,
      lease_token: lease(1),
      recipient_id: recipientId,
      notification_type: "verification_approved",
    }),
    complete: async (result) => completed.push(result),
    resolveRecipient: async () => "synthetic@identity.test",
    authorizeDispatch: async () => true,
    adapter: {
      lookup: async () => ({ status: "unknown" }),
      send: async () => {
        sends++;
        return { status: "accepted", captureId: lease(2) };
      },
    },
  });
  assert.equal(sends, 0);
  assert.equal(completed[0].status, "unknown");
  assert.equal(completed[0].safeErrorCode, "ambiguous_result");
});

test("a local capture refuses real addresses and changed payloads under one ID", async () => {
  const capture = await startLocalNotificationEmailCapture();
  try {
    assert.throws(
      () =>
        createLocalEmailCaptureAdapter({
          url: "https://mail.example.com",
          token: capture.token,
        }),
      /loopback/,
    );
    const adapter = createLocalEmailCaptureAdapter(capture);
    const original = {
      deliveryId,
      to: "synthetic@identity.test",
      template: "transactional_notice_v1",
      subject: "Application accepted",
      text: "Sign in to review the details.",
    };
    assert.equal((await adapter.send(original)).status, "accepted");
    assert.equal(
      (await adapter.send({ ...original, subject: "Changed" })).status,
      "permanent_failure",
    );
    assert.equal(capture.count(deliveryId), 1);
  } finally {
    await capture.close();
  }
});

test("recipient lookup failure retries safely and rejects non-synthetic addresses", async () => {
  const outcomes = [];
  const base = {
    claim: async () => ({
      delivery_id: deliveryId,
      lease_token: lease(1),
      recipient_id: recipientId,
      notification_type: "withdrawal_paid",
    }),
    complete: async (result) => outcomes.push(result),
    authorizeDispatch: async () => true,
    adapter: {
      lookup: async () => ({ status: "absent" }),
      send: async () => ({ status: "accepted", captureId: lease(2) }),
    },
  };
  await runNotificationEmailDelivery({
    ...base,
    resolveRecipient: async () => {
      throw new Error("Auth unavailable");
    },
  });
  await runNotificationEmailDelivery({
    ...base,
    resolveRecipient: async () => "real@example.com",
  });
  assert.deepEqual(
    outcomes.map((item) => item.status),
    ["retry_wait", "permanent_failure"],
  );
  assert.equal(outcomes[1].safeErrorCode, "capture_rejected");
});

test("a reminder that is no longer eligible is suppressed before capture", async () => {
  let sends = 0;
  let completions = 0;
  const result = await runNotificationEmailDelivery({
    claim: async () => ({
      delivery_id: deliveryId,
      lease_token: lease(1),
      recipient_id: recipientId,
      notification_type: "assignment_reminder_24h",
    }),
    complete: async () => {
      completions++;
    },
    resolveRecipient: async () => "synthetic@identity.test",
    authorizeDispatch: async () => false,
    adapter: {
      lookup: async () => ({ status: "absent" }),
      send: async () => {
        sends++;
        return { status: "accepted", captureId: lease(2) };
      },
    },
  });
  assert.deepEqual(result, { claimed: true, status: "suppressed" });
  assert.equal(sends, 0);
  assert.equal(completions, 0);
});
