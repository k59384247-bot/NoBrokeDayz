const UUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
const TEMPLATES = Object.freeze({
  application_received: [
    "New application",
    "There is an application update. Sign in to review it.",
  ],
  application_accepted: [
    "Application accepted",
    "Your application was accepted. Sign in to view the details.",
  ],
  application_rejected: [
    "Application update",
    "There is an application update. Sign in to review it.",
  ],
  application_withdrawn: [
    "Application withdrawn",
    "An application was withdrawn. Sign in to review the update.",
  ],
  application_closed: [
    "Application closed",
    "An application was closed. Sign in to review the update.",
  ],
  assignment_started: [
    "Work started",
    "Work has started on an assignment. Sign in to view the details.",
  ],
  assignment_submitted: [
    "Work submitted",
    "Work was submitted for review. Sign in to view the details.",
  ],
  assignment_completed: [
    "Work confirmed",
    "An assignment was confirmed complete. Sign in to view the details.",
  ],
  assignment_hold_opened: [
    "Review requested",
    "An assignment needs review. Sign in to view the details.",
  ],
  assignment_case_decision: [
    "Case decision available",
    "A case decision is available. Sign in to review it.",
  ],
  assignment_case_finalized: [
    "Case outcome finalized",
    "A case outcome was finalized. Sign in to review it.",
  ],
  assignment_reminder_24h: [
    "Confirmation reminder",
    "Submitted work is waiting for your confirmation. Sign in to review it.",
  ],
  assignment_reminder_48h: [
    "Confirmation reminder",
    "Submitted work is still waiting for your confirmation. Sign in to review it.",
  ],
  assignment_dispute_guidance_72h: [
    "Dispute route available",
    "Your submitted work is still waiting for confirmation. Sign in to view the dispute route.",
  ],
  slot_refund_authorized: [
    "Refund update",
    "There is a refund update. Sign in to review it.",
  ],
  assignment_cancellation_requested: [
    "Cancellation requested",
    "An assignment cancellation was requested. Sign in to review it.",
  ],
  assignment_cancellation_completed: [
    "Cancellation completed",
    "An assignment cancellation was completed. Sign in to review it.",
  ],
  assignment_abandoned: [
    "Assignment ended",
    "An assignment ended early. Sign in to review the update.",
  ],
  withdrawal_requested: [
    "Withdrawal requested",
    "A withdrawal request was recorded. Sign in to review its status.",
  ],
  withdrawal_processing: [
    "Withdrawal processing",
    "A withdrawal is being processed. Sign in to review its status.",
  ],
  withdrawal_unknown: [
    "Withdrawal status update",
    "A withdrawal status is being reconciled. Sign in to review it.",
  ],
  withdrawal_paid: [
    "Withdrawal paid",
    "A withdrawal was marked paid. Sign in to review its status.",
  ],
  withdrawal_failed: [
    "Withdrawal update",
    "A withdrawal needs follow up. Sign in to review its status.",
  ],
  withdrawal_reversed: [
    "Withdrawal update",
    "A withdrawal was reversed. Sign in to review its status.",
  ],
  withdrawal_exception: [
    "Withdrawal needs review",
    "A withdrawal needs review. Sign in to view its status.",
  ],
  refund_processing: [
    "Refund processing",
    "A refund is being processed. Sign in to review its status.",
  ],
  refund_unknown: [
    "Refund status update",
    "A refund status is being reconciled. Sign in to review it.",
  ],
  refund_settled: [
    "Refund update",
    "A refund settlement was confirmed. Sign in to review its status.",
  ],
  refund_failed: [
    "Refund update",
    "A refund needs follow up. Sign in to review its status.",
  ],
  refund_exception: [
    "Refund needs review",
    "A refund needs review. Sign in to view its status.",
  ],
  refund_reversal_review: [
    "Refund needs review",
    "A refund reversal needs review. Sign in to view its status.",
  ],
  verification_submitted: [
    "Verification received",
    "Your verification submission was received. Sign in to review its status.",
  ],
  verification_approved: [
    "Verification approved",
    "Your verification was approved. Sign in to review your account.",
  ],
  verification_not_approved: [
    "Verification update",
    "There is a verification update. Sign in to review your account.",
  ],
  verification_revoked: [
    "Verification update",
    "There is a verification update. Sign in to review your account.",
  ],
});

async function finish(
  complete,
  job,
  status,
  safeErrorCode = null,
  captureId = null,
) {
  return complete({
    deliveryId: job.delivery_id,
    leaseToken: job.lease_token,
    status,
    safeErrorCode,
    providerCaptureId: captureId,
  });
}

export async function runNotificationEmailDelivery({
  claim,
  complete,
  resolveRecipient,
  authorizeDispatch,
  adapter,
}) {
  if (
    [claim, complete, resolveRecipient, authorizeDispatch].some(
      (fn) => typeof fn !== "function",
    ) ||
    typeof adapter?.lookup !== "function" ||
    typeof adapter?.send !== "function"
  )
    throw new Error(
      "notification email runner dependencies are not configured",
    );
  const job = await claim();
  if (!job) return { claimed: false };
  if (
    !UUID.test(job.delivery_id ?? "") ||
    !UUID.test(job.lease_token ?? "") ||
    !UUID.test(job.recipient_id ?? "")
  )
    throw new Error("invalid_notification_delivery_claim");
  const template = TEMPLATES[job.notification_type];
  if (!template)
    return finish(complete, job, "permanent_failure", "capture_rejected");

  let existing;
  try {
    existing = await adapter.lookup(job.delivery_id);
  } catch {
    return finish(complete, job, "unknown", "ambiguous_result");
  }
  if (existing?.status === "found")
    return finish(complete, job, "provider_accepted", null, existing.captureId);
  if (existing?.status !== "absent")
    return finish(complete, job, "unknown", "ambiguous_result");

  let email;
  try {
    email = await resolveRecipient(job.recipient_id);
  } catch {
    return finish(complete, job, "retry_wait", "recipient_unavailable");
  }
  if (typeof email !== "string" || !/^[^\s@]+@identity\.test$/i.test(email))
    return finish(complete, job, "permanent_failure", "capture_rejected");

  let allowed;
  try {
    allowed = await authorizeDispatch(job);
  } catch {
    return finish(complete, job, "retry_wait", "eligibility_check_unavailable");
  }
  if (allowed !== true) return { claimed: true, status: "suppressed" };

  let result;
  try {
    result = await adapter.send({
      deliveryId: job.delivery_id,
      to: email,
      template: "transactional_notice_v1",
      subject: template[0],
      text: template[1],
    });
  } catch {
    return finish(complete, job, "unknown", "ambiguous_result");
  }
  if (result?.status === "accepted")
    return finish(complete, job, "provider_accepted", null, result.captureId);
  if (result?.status === "permanent_failure")
    return finish(complete, job, "permanent_failure", "capture_rejected");
  return finish(complete, job, "unknown", "ambiguous_result");
}
