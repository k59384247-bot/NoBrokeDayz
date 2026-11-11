import assert from "node:assert/strict";
import test from "node:test";
import { createCaseCommandHandler } from "../../../supabase/functions/_shared/case-command.mjs";
import { createCaseReadHandler } from "../../../supabase/functions/_shared/case-read.mjs";

const actorId = "11111111-1111-4111-8111-111111111111";
const caseId = "22222222-2222-4222-8222-222222222222";
const assignmentId = "33333333-3333-4333-8333-333333333333";
const jobId = "44444444-4444-4444-8444-444444444444";
const idem = "55555555-5555-4555-8555-555555555555";
const now = "2026-11-06T12:00:00.000Z";

function bearer(actor = actorId, aal = "aal1") {
  const payload = Buffer.from(JSON.stringify({ sub: actor, aal })).toString(
    "base64url",
  );
  return `header.${payload}.signature`;
}

function req(body, aal = "aal1", actor = actorId) {
  return new Request("http://local.test/cases", {
    method: "POST",
    headers: { authorization: `Bearer ${bearer(actor, aal)}` },
    body: JSON.stringify(body),
  });
}

const hold = {
  case_id: caseId,
  hold_id: caseId,
  status: "open",
  prior_assignment_state: "submitted",
  reason_code: "incomplete_work",
  narrative: "The agreed work remains unfinished.",
  desired_outcome: "Please review the remaining work.",
  follow_up: null,
  opened_at: now,
};

const participantRow = {
  case_id: caseId,
  assignment_id: assignmentId,
  status: "open",
  version: 1,
  opened_at: now,
  updated_at: now,
  timeline: [
    {
      event_type: "case_opened",
      created_at: now,
      details: {
        status: "open",
        reporter_role: "worker",
        reason_code: "incomplete_work",
        narrative: hold.narrative,
        desired_outcome: hold.desired_outcome,
        follow_up: null,
        prior_assignment_state: "submitted",
      },
    },
  ],
  timeline_truncated: false,
  participant_role: "worker",
  investigation: {
    requests: [],
    files: [],
    internal_notes: [{ note: "private staff note", created_at: now }],
  },
  traceability: {
    decision: { proposed_by: actorId },
    finalization: { finalized_by: actorId },
  },
  hold,
};

test("case participant read uses the actor from verified Auth and safe fields", async () => {
  let called;
  const handler = createCaseReadHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async (name, args) => {
      called = { name, args };
      return { ...participantRow, assigned_reviewer_id: actorId };
    },
    requestId: () => "case-request-1",
  });
  const response = await handler(
    req({ action: "participant_detail", case_id: caseId }),
  );
  const body = await response.json();
  assert.equal(response.status, 200);
  assert.equal(called.name, "server_get_assignment_case_for_actor");
  assert.equal(called.args.p_actor, actorId);
  assert.equal(body.data.case_id, caseId);
  assert.equal("assigned_reviewer_id" in body.data, false);
  assert.equal(body.data.timeline.length, 1);
  assert.equal("traceability" in body.data, false);
  assert.equal("internal_notes" in body.data.investigation, false);
});

test("closed case shares only the executed outcome and honest refund status", async () => {
  const closedAt = "2026-11-07T12:00:00.000Z";
  const outcome = {
    decision_version: 2,
    outcome: "split",
    gross_principal_kobo: "300000",
    worker_award_gross_kobo: "200000",
    poster_refund_gross_kobo: "100000",
    retained_hold_gross_kobo: "0",
    commission_kobo: "10000",
    worker_net_kobo: "190000",
    refund_status: "authorized",
  };
  const closedRow = {
    ...participantRow,
    status: "closed",
    version: 14,
    updated_at: closedAt,
    timeline: [
      ...participantRow.timeline,
      {
        event_type: "case_closed",
        created_at: closedAt,
        details: {
          status: "closed",
          update: "The case decision has been finalized.",
          ...outcome,
          execution_status: "executed",
        },
      },
    ],
    finalization: { ...outcome, status: "executed", executed_at: closedAt },
    appeal: null,
  };
  const handler = createCaseReadHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async () => closedRow,
  });
  const response = await handler(
    req({ action: "participant_detail", case_id: caseId }),
  );
  const body = await response.json();
  assert.equal(response.status, 200);
  assert.equal(body.data.status, "closed");
  assert.equal(body.data.finalization.status, "executed");
  assert.equal(body.data.finalization.refund_status, "authorized");
  assert.equal(body.data.finalization.worker_net_kobo, "190000");

  const falselySettled = createCaseReadHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async () => ({
      ...closedRow,
      finalization: { ...closedRow.finalization, refund_status: "settled" },
    }),
  });
  assert.equal(
    (
      await falselySettled(
        req({ action: "participant_detail", case_id: caseId }),
      )
    ).status,
    503,
  );
  const validSettlement = createCaseReadHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async () => ({
      ...closedRow,
      finalization: {
        ...closedRow.finalization,
        refund_status: "settled",
        refund_settled_at: closedAt,
      },
    }),
  });
  const settledResponse = await validSettlement(
    req({ action: "participant_detail", case_id: caseId }),
  );
  const settledBody = await settledResponse.json();
  assert.equal(settledResponse.status, 200);
  assert.equal(settledBody.data.finalization.refund_status, "settled");
  assert.equal(settledBody.data.finalization.refund_settled_at, closedAt);
});

test("case staff detail requires AAL2 before the RPC boundary", async () => {
  let calls = 0;
  const handler = createCaseReadHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async () => {
      calls += 1;
      return {};
    },
  });
  const response = await handler(
    req({ action: "reviewer_detail", case_id: caseId }, "aal1"),
  );
  assert.equal(response.status, 403);
  assert.equal(calls, 0);
});

test("assigned reviewer receives only validated terms and same-thread snapshot fields", async () => {
  let reviewerRow;
  const handler = createCaseReadHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async () =>
      (reviewerRow = {
        ...participantRow,
        terms_snapshot: {
          job_id: jobId,
          terms_version: 1,
          title: "Carry books",
          description: "Carry books between two campus buildings safely.",
          category_slug: "errands",
          location_type: "on_campus",
          location_detail: "Main library",
          gross_per_worker_kobo: "300000",
          slot_count: 1,
          gross_total_kobo: "300000",
          application_deadline_at: now,
          needed_by_at: "2026-11-07T12:00:00.000Z",
          start_requirements: "Meet by the entrance.",
          application_note: "Available after lectures.",
          terms_sha256: "a".repeat(64),
        },
        conversation_snapshot: [
          {
            sequence: "1",
            sender_role: "worker",
            body: "I can do this after class.",
            created_at: now,
            sender_id: actorId,
          },
        ],
        conversation_truncated: false,
        investigation: {
          triage: [],
          contact_attempts: [],
          requests: [],
          verified_facts: [],
          internal_notes: [],
          nonresponse: [],
          files: [],
          decision: {
            decision_id: jobId,
            decision_version: 1,
            worker_recipient_id: actorId,
            outcome: "split",
            reason_code: "incomplete_work",
            public_explanation:
              "Verified work supports a partial award and return of the remainder.",
            gross_principal_kobo: "300000",
            worker_award_gross_kobo: "200000",
            poster_refund_gross_kobo: "100000",
            retained_hold_gross_kobo: "0",
            commission_kobo: "10000",
            worker_net_kobo: "190000",
            terms_version: 1,
            terms_sha256: "b".repeat(64),
            evidence_item_count: 3,
            evidence_snapshot_sha256: "c".repeat(64),
            decision_sha256: "d".repeat(64),
            approval_count: 2,
            required_approvals: 2,
            nonresponse_signoff_required: false,
            nonresponse_signed_off: false,
            created_at: now,
            approved_at: now,
            status: "approved",
            internal_note: "must not be included in the response",
          },
        },
        traceability: { decision: null, finalization: null },
        reviewer_id: actorId,
        internal_note: "must stay private",
      }),
  });
  const response = await handler(
    req({ action: "reviewer_detail", case_id: caseId }, "aal2"),
  );
  const body = await response.json();
  assert.equal(response.status, 200);
  assert.equal(body.data.terms_snapshot.gross_total_kobo, "300000");
  assert.equal(
    body.data.conversation_snapshot[0].body,
    "I can do this after class.",
  );
  assert.equal("sender_id" in body.data.conversation_snapshot[0], false);
  assert.equal("reviewer_id" in body.data, false);
  assert.equal("internal_note" in body.data, false);
  assert.equal(body.data.investigation.decision.worker_net_kobo, "190000");
  assert.equal("decision_id" in body.data.investigation.decision, false);
  assert.equal(
    "worker_recipient_id" in body.data.investigation.decision,
    false,
  );
  assert.equal("internal_note" in body.data.investigation.decision, false);
  const appealRow = {
    ...reviewerRow,
    status: "appeal",
    appeal_review: {
      initial_decision_version: 1,
      initial_decision_sha256: "d".repeat(64),
      durable_notified_at: now,
      appeal_deadline_at: "2026-11-09T12:00:00.000Z",
      finalization_block_reason: "timely_appeal_unresolved",
      appeals: [],
    },
  };
  delete appealRow.traceability;
  const appealHandler = createCaseReadHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async () => appealRow,
  });
  const appealResponse = await appealHandler(
    req({ action: "appeal_reviewer_detail", case_id: caseId }, "aal2"),
  );
  const appealBody = await appealResponse.json();
  assert.equal(appealResponse.status, 200);
  assert.equal("traceability" in appealBody.data, false);
  assert.equal("internal_notes" in appealBody.data.investigation, false);
});

test("closed reviewer detail validates decision and refund attribution", async () => {
  const approverId = "11111111-1111-4111-8111-111111111111";
  const finalizerId = "22222222-2222-4222-8222-222222222222";
  const operationId = "33333333-3333-4333-8333-333333333333";
  const settledAt = "2026-11-08T12:00:00.000Z";
  const decisionHash = "e".repeat(64);
  const handler = createCaseReadHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async () => ({
      ...participantRow,
      status: "closed",
      finalization: {
        decision_version: 1,
        outcome: "full_poster_refund",
        gross_principal_kobo: "300000",
        worker_award_gross_kobo: "0",
        poster_refund_gross_kobo: "300000",
        retained_hold_gross_kobo: "0",
        commission_kobo: "0",
        worker_net_kobo: "0",
        refund_status: "settled",
        refund_settled_at: settledAt,
        status: "executed",
        executed_at: settledAt,
      },
      terms_snapshot: {
        job_id: jobId,
        terms_version: 1,
        title: "Carry books",
        description: "Carry books between two campus buildings safely.",
        category_slug: "errands",
        location_type: "on_campus",
        location_detail: "Main library",
        gross_per_worker_kobo: "300000",
        slot_count: 1,
        gross_total_kobo: "300000",
        application_deadline_at: now,
        needed_by_at: "2026-11-07T12:00:00.000Z",
        start_requirements: "Meet by the entrance.",
        application_note: "Available after lectures.",
        terms_sha256: "a".repeat(64),
      },
      conversation_snapshot: [],
      conversation_truncated: false,
      investigation: {
        triage: [],
        contact_attempts: [],
        requests: [],
        verified_facts: [],
        internal_notes: [{ note: "private staff note", created_at: settledAt }],
        nonresponse: [],
        files: [],
        decision: {
          decision_id: jobId,
          decision_version: 1,
          outcome: "full_poster_refund",
          reason_code: "incomplete_work",
          public_explanation:
            "The reviewed record supports returning the held amount to the poster.",
          gross_principal_kobo: "300000",
          worker_award_gross_kobo: "0",
          poster_refund_gross_kobo: "300000",
          retained_hold_gross_kobo: "0",
          commission_kobo: "0",
          worker_net_kobo: "0",
          terms_version: 1,
          terms_sha256: "b".repeat(64),
          evidence_item_count: 0,
          evidence_snapshot_sha256: "c".repeat(64),
          decision_sha256: decisionHash,
          approval_count: 2,
          required_approvals: 2,
          nonresponse_signoff_required: false,
          nonresponse_signed_off: false,
          created_at: settledAt,
          approved_at: settledAt,
          status: "approved",
        },
      },
      traceability: {
        decision: {
          decision_id: jobId,
          decision_version: 1,
          decision_sha256: decisionHash,
          proposed_by: actorId,
          proposed_at: settledAt,
          approvals: [
            { approval_number: 1, actor_id: actorId, approved_at: settledAt },
            {
              approval_number: 2,
              actor_id: approverId,
              approved_at: settledAt,
            },
          ],
          senior_signoff: null,
        },
        finalization: {
          finalization_id: "44444444-4444-4444-8444-444444444444",
          decision_version: 1,
          finalized_by: finalizerId,
          finalized_at: settledAt,
          refund: {
            status: "settled",
            amount_kobo: "300000",
            operation_id: operationId,
            operation_reference: `sim-${operationId}`,
            provider_refund_reference: `sim-${operationId}`,
            source_collection_reference: "sim-source-collection",
          },
        },
      },
    }),
  });
  const response = await handler(
    req({ action: "reviewer_detail", case_id: caseId }, "aal2"),
  );
  const body = await response.json();
  assert.equal(response.status, 200);
  assert.equal(body.data.traceability.decision.proposed_by, actorId);
  assert.equal(
    body.data.traceability.decision.approvals[1].actor_id,
    approverId,
  );
  assert.equal(body.data.traceability.finalization.finalized_by, finalizerId);
  assert.equal(
    body.data.traceability.finalization.refund.operation_reference,
    `sim-${operationId}`,
  );
  assert.equal(
    body.data.investigation.internal_notes[0].note,
    "private staff note",
  );
});

test("review queue is AAL2-only and contains triage fields without narratives", async () => {
  let called;
  const handler = createCaseReadHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async (name, args) => {
      called = { name, args };
      return {
        items: [
          {
            case_id: caseId,
            assignment_id: assignmentId,
            status: "open",
            opened_at: now,
            age_seconds: "0",
            reason_code: "incomplete_work",
            priority: "normal",
            assigned_to_me: false,
            narrative: "never expose from the queue",
          },
        ],
        truncated: false,
      };
    },
  });
  const response = await handler(req({ action: "review_queue" }, "aal2"));
  const body = await response.json();
  assert.equal(response.status, 200);
  assert.equal(called.name, "server_list_assignment_case_queue_for_actor");
  assert.equal(called.args.p_limit, 51);
  assert.equal(body.data.items.length, 1);
  assert.equal("narrative" in body.data.items[0], false);
  const aal1 = await handler(req({ action: "review_queue" }, "aal1"));
  assert.equal(aal1.status, 403);
});

test("appeal review queue is AAL2-only and validates bounded queue fields", async () => {
  const handler = createCaseReadHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async () => ({
      items: [
        {
          case_id: caseId,
          assignment_id: assignmentId,
          status: "appeal",
          opened_at: now,
          age_seconds: "2",
          appeal_deadline_at: new Date(
            Date.parse(now) + 72 * 60 * 60 * 1000,
          ).toISOString(),
          pending_appeal_count: 1,
          assigned_to_me: true,
        },
      ],
      truncated: false,
    }),
  });
  const response = await handler(
    req({ action: "appeal_review_queue" }, "aal2"),
  );
  const body = await response.json();
  assert.equal(response.status, 200);
  assert.equal(body.data.items[0].pending_appeal_count, 1);
  assert.equal(
    (await handler(req({ action: "appeal_review_queue" }, "aal1"))).status,
    403,
  );
});

test("every staff case command rejects malformed payloads before its RPC", async () => {
  const invalidPayloads = [
    { action: "triage_case", priority: "critical", rationale: "Review now." },
    {
      action: "log_case_contact_attempt",
      target_party_role: "poster",
      channel: "sms",
      result: "no_response",
    },
    {
      action: "request_case_information",
      target_party_role: "worker",
      request_kind: "information",
      prompt: " ",
    },
    {
      action: "respond_to_case_information",
      request_number: 0,
      response: "Reply.",
    },
    {
      action: "record_case_fact",
      fact_code: "work_delivery",
      finding: "maybe",
      staff_reasoning:
        "The submitted record was reviewed against the accepted terms.",
    },
    { action: "add_case_internal_note", note: " " },
    {
      action: "assess_case_nonresponse",
      target_party_role: "poster",
      substantive_reasoning: "Too short.",
    },
    {
      action: "signoff_case_nonresponse",
      assessment_id: "bad",
      substantive_reasoning:
        "This signed reasoning is long enough to pass the basic text limit.",
    },
    {
      action: "propose_case_decision",
      expected_case_version: 3,
      outcome: "split",
      award_gross_kobo: "03",
      public_explanation:
        "A clear public explanation tied to the evidence and terms.",
    },
    {
      action: "approve_case_decision",
      decision_version: 0,
      expected_case_version: 3,
    },
    {
      action: "signoff_decision_nonresponse",
      decision_version: 1,
      expected_case_version: 3,
      substantive_reasoning: "Too short.",
    },
    { action: "finalize_case", decision_version: 1, expected_case_version: 0 },
    {
      action: "request_case_appeal_evidence",
      appeal_id: "bad",
      target_party_role: "poster",
      request_kind: "evidence",
      prompt: "Attach the requested evidence.",
    },
    {
      action: "respond_case_appeal_evidence",
      request_number: 0,
      response: "Reply.",
    },
    {
      action: "close_case_appeal_evidence_nonresponse",
      request_number: 1,
      substantive_reasoning: "Too short.",
    },
    {
      action: "review_case_appeal",
      appeal_id: caseId,
      action_type: "silence_decides_money",
      public_explanation:
        "This explanation is long enough for the public text limit.",
    },
  ];
  let rpcCalls = 0;
  const handler = createCaseCommandHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async () => {
      rpcCalls += 1;
      return {};
    },
  });
  for (const payload of invalidPayloads) {
    const response = await handler(
      req({ ...payload, case_id: caseId, idempotency_key: idem }, "aal2"),
    );
    assert.equal(response.status, 400, payload.action);
    assert.equal((await response.json()).error.code, "invalid_request");
  }
  assert.equal(rpcCalls, 0);
});

test("nonresponse and appeal-evidence commands validate staff payloads and MFA", async () => {
  const calls = [];
  const assessmentId = "66666666-6666-4666-8666-666666666666";
  const handler = createCaseCommandHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async (name, args) => {
      calls.push({ name, args });
      if (args.p_action === "close_case_appeal_evidence_nonresponse")
        return {
          case_id: caseId,
          status: "verifying",
          version: 5,
          request_number: 2,
          closed: true,
        };
      return {
        case_id: caseId,
        status:
          args.p_action === "log_case_contact_attempt"
            ? "contacting_other_party"
            : "verifying",
        version: calls.length + 1,
        recorded: true,
      };
    },
  });
  const send = (body, aal = "aal2") => handler(req(body, aal));
  const base = {
    action: "log_case_contact_attempt",
    case_id: caseId,
    idempotency_key: idem,
  };
  assert.equal(
    (
      await send({
        ...base,
        target_party_role: "poster",
        channel: "sms",
        result: "no_response",
      })
    ).status,
    400,
  );
  assert.equal(calls.length, 0);
  assert.equal(
    (
      await send(
        {
          ...base,
          target_party_role: "poster",
          channel: "phone",
          result: "no_response",
        },
        "aal1",
      )
    ).status,
    403,
  );
  assert.equal(
    (
      await send({
        ...base,
        target_party_role: "poster",
        channel: "phone",
        result: "no_response",
      })
    ).status,
    200,
  );
  const assess = {
    action: "assess_case_nonresponse",
    case_id: caseId,
    idempotency_key: idem,
    target_party_role: "poster",
    substantive_reasoning:
      "Two recorded attempts across phone and email received no reply. This is a contact record only; the case outcome must still follow the submitted evidence and accepted terms.",
  };
  assert.equal(
    (await send({ ...assess, substantive_reasoning: "Too short." })).status,
    400,
  );
  assert.equal((await send(assess, "aal1")).status, 403);
  assert.equal((await send(assess)).status, 200);
  const signoff = {
    action: "signoff_case_nonresponse",
    case_id: caseId,
    idempotency_key: idem,
    assessment_id: assessmentId,
    substantive_reasoning:
      "The separate senior reviewed the current contact attempts and confirms the assessment is limited to documenting non-response. It does not determine the financial outcome.",
  };
  assert.equal((await send({ ...signoff, assessment_id: "bad" })).status, 400);
  assert.equal((await send(signoff)).status, 200);
  const close = {
    action: "close_case_appeal_evidence_nonresponse",
    case_id: caseId,
    idempotency_key: idem,
    request_number: 2,
    substantive_reasoning:
      "The current two-channel contact record and separate senior sign-off support closing this unanswered evidence request. The appeal reviewer can now finish the appeal using the available submitted evidence.",
  };
  assert.equal((await send(close, "aal1")).status, 403);
  assert.equal((await send(close)).status, 200);
  assert.equal(calls.length, 4);
  assert.deepEqual(
    calls.map(({ args }) => args.p_action),
    [
      "log_case_contact_attempt",
      "assess_case_nonresponse",
      "signoff_case_nonresponse",
      "close_case_appeal_evidence_nonresponse",
    ],
  );
  assert.equal(calls[0].args.p_payload.channel, "phone");
  assert.equal(calls[1].args.p_payload.target_party_role, "poster");
  assert.equal(calls[2].args.p_payload.assessment_id, assessmentId);
  assert.equal(calls[3].args.p_payload.request_number, 2);
});

test("case assignment requires AAL2 and rejects client-supplied actor identity", async () => {
  let called;
  const handler = createCaseCommandHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async (name, args) => {
      called = { name, args };
      return {
        case_id: caseId,
        status: "under_review",
        version: 2,
        assigned: true,
      };
    },
  });
  const denied = await handler(
    req({
      action: "assign_reviewer",
      case_id: caseId,
      reviewer_id: actorId,
      idempotency_key: idem,
    }),
  );
  assert.equal(denied.status, 403);
  assert.equal(called, undefined);
  const malformed = await handler(
    req(
      {
        action: "assign_reviewer",
        case_id: caseId,
        reviewer_id: actorId,
        idempotency_key: idem,
        actor_id: actorId,
      },
      "aal2",
    ),
  );
  assert.equal(malformed.status, 400);
  assert.equal(called, undefined);
});

test("case assignment forwards verified actor and idempotent command fields", async () => {
  let called;
  const handler = createCaseCommandHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async (name, args) => {
      called = { name, args };
      return {
        case_id: caseId,
        status: "under_review",
        version: 2,
        assigned: true,
      };
    },
    requestId: () => "case-request-2",
  });
  const response = await handler(
    req(
      {
        action: "assign_reviewer",
        case_id: caseId,
        reviewer_id: actorId,
        idempotency_key: idem,
      },
      "aal2",
    ),
  );
  const body = await response.json();
  assert.equal(response.status, 200);
  assert.equal(called.name, "server_assign_case_reviewer_for_actor");
  assert.deepEqual(called.args, {
    p_actor: actorId,
    p_case_id: caseId,
    p_reviewer_id: actorId,
    p_auth_aal: "aal2",
    p_idempotency_key: idem,
  });
  assert.equal(body.result.version, 2);
});

test("staff investigation command forwards only approved payload fields", async () => {
  let called;
  const handler = createCaseCommandHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async (name, args) => {
      called = { name, args };
      return {
        case_id: caseId,
        status: "under_review",
        version: 3,
        priority: "urgent",
        acknowledged: true,
      };
    },
  });
  const response = await handler(
    req(
      {
        action: "triage_case",
        case_id: caseId,
        idempotency_key: idem,
        priority: "normal",
        rationale: "Safety concern needs prompt review.",
      },
      "aal2",
    ),
  );
  assert.equal(response.status, 200);
  assert.equal(called.name, "server_case_investigation_command_for_actor");
  assert.deepEqual(called.args.p_payload, {
    priority: "normal",
    rationale: "Safety concern needs prompt review.",
  });
  assert.equal(called.args.p_actor, actorId);
  assert.equal(called.args.p_auth_aal, "aal2");
});

test("decision proposal derives the actor and sends only the immutable proposal fields", async () => {
  let called;
  const handler = createCaseCommandHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async (name, args) => {
      called = { name, args };
      return {
        case_id: caseId,
        status: "verifying",
        case_version: 8,
        decision_version: 1,
        outcome: "split",
        gross_principal_kobo: "300000",
        worker_award_gross_kobo: "200000",
        poster_refund_gross_kobo: "100000",
        retained_hold_gross_kobo: "0",
        commission_kobo: "10000",
        worker_net_kobo: "190000",
        decision_sha256: "a".repeat(64),
        approval_count: 1,
        required_approvals: 2,
        approved: false,
        proposed: true,
      };
    },
  });
  const response = await handler(
    req(
      {
        action: "propose_case_decision",
        case_id: caseId,
        idempotency_key: idem,
        expected_case_version: 7,
        outcome: "split",
        award_gross_kobo: "200000",
        public_explanation:
          "The verified work supports a partial award and return of the remaining amount.",
      },
      "aal2",
    ),
  );
  const body = await response.json();
  assert.equal(response.status, 200);
  assert.equal(called.name, "server_propose_case_decision_for_actor");
  assert.equal(called.args.p_actor, actorId);
  assert.equal(called.args.p_expected_case_version, 7);
  assert.deepEqual(called.args.p_payload, {
    outcome: "split",
    award_gross_kobo: "200000",
    public_explanation:
      "The verified work supports a partial award and return of the remaining amount.",
  });
  assert.equal(body.result.worker_net_kobo, "190000");
  assert.equal("actor_id" in body.result, false);
});

test("decision commands reject actor, role, recipient and private-note spoofing", async () => {
  let calls = 0;
  const handler = createCaseCommandHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async () => {
      calls += 1;
      return {};
    },
  });
  const response = await handler(
    req(
      {
        action: "propose_case_decision",
        case_id: caseId,
        idempotency_key: idem,
        expected_case_version: 7,
        outcome: "full_poster_refund",
        award_gross_kobo: "0",
        public_explanation:
          "The evidence supports returning the held amount to the poster.",
        actor_id: actorId,
        role: "financial_approve",
        recipient_id: actorId,
        internal_note: "private staff note",
      },
      "aal2",
    ),
  );
  assert.equal(response.status, 400);
  assert.equal(calls, 0);
});

test("decision proposal is AAL2-only and rejects links, identifiers and invalid amounts", async () => {
  let calls = 0;
  const handler = createCaseCommandHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async () => {
      calls += 1;
      return {};
    },
  });
  const payload = {
    action: "propose_case_decision",
    case_id: caseId,
    idempotency_key: idem,
    expected_case_version: 7,
    outcome: "full_worker_award",
    award_gross_kobo: "300000",
    public_explanation:
      "The verified evidence supports completion and release. See https://example.test",
  };
  assert.equal((await handler(req(payload, "aal2"))).status, 400);
  assert.equal(
    (await handler(req({ ...payload, award_gross_kobo: "3.2" }, "aal2")))
      .status,
    400,
  );
  assert.equal(
    (
      await handler(
        req(
          { ...payload, public_explanation: "Decision based on " + jobId },
          "aal2",
        ),
      )
    ).status,
    400,
  );
  const validPayload = {
    ...payload,
    public_explanation: "The evidence supports the selected full worker award.",
  };
  assert.equal((await handler(req(validPayload, "aal1"))).status, 403);
  assert.equal(calls, 0);
});

test("second human approval forwards only version-bound identifiers and validates conservation", async () => {
  let called;
  const handler = createCaseCommandHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async (name, args) => {
      called = { name, args };
      return {
        case_id: caseId,
        status: "decision_made",
        case_version: 9,
        decision_version: 1,
        outcome: "split",
        gross_principal_kobo: "300000",
        worker_award_gross_kobo: "200000",
        poster_refund_gross_kobo: "100000",
        retained_hold_gross_kobo: "0",
        commission_kobo: "10000",
        worker_net_kobo: "190000",
        decision_sha256: "b".repeat(64),
        approval_count: 2,
        required_approvals: 2,
        approved: true,
        proposed: false,
      };
    },
  });
  const response = await handler(
    req(
      {
        action: "approve_case_decision",
        case_id: caseId,
        idempotency_key: idem,
        decision_version: 1,
        expected_case_version: 8,
      },
      "aal2",
    ),
  );
  assert.equal(response.status, 200);
  assert.equal(called.name, "server_approve_case_decision_for_actor");
  assert.deepEqual(called.args, {
    p_actor: actorId,
    p_case_id: caseId,
    p_decision_version: 1,
    p_expected_case_version: 8,
    p_auth_aal: "aal2",
    p_idempotency_key: idem,
  });
  assert.equal((await response.json()).result.approved, true);
  const malformed = createCaseCommandHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async () => ({
      case_id: caseId,
      status: "decision_made",
      case_version: 9,
      decision_version: 1,
      outcome: "split",
      gross_principal_kobo: "300000",
      worker_award_gross_kobo: "200000",
      poster_refund_gross_kobo: "99999",
      retained_hold_gross_kobo: "0",
      commission_kobo: "10000",
      worker_net_kobo: "190000",
      decision_sha256: "b".repeat(64),
      approval_count: 2,
      required_approvals: 2,
      approved: true,
      proposed: false,
    }),
  });
  assert.equal(
    (
      await malformed(
        req(
          {
            action: "approve_case_decision",
            case_id: caseId,
            idempotency_key: idem,
            decision_version: 1,
            expected_case_version: 8,
          },
          "aal2",
        ),
      )
    ).status,
    503,
  );
});

test("non-response senior signoff binds its explanation to the same decision version", async () => {
  let called;
  const handler = createCaseCommandHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async (name, args) => {
      called = { name, args };
      return {
        case_id: caseId,
        status: "verifying",
        case_version: 8,
        decision_version: 3,
        decision_sha256: "e".repeat(64),
        signed_off: true,
      };
    },
  });
  const response = await handler(
    req(
      {
        action: "signoff_decision_nonresponse",
        case_id: caseId,
        idempotency_key: idem,
        decision_version: 3,
        expected_case_version: 8,
        substantive_reasoning:
          "The senior review confirms the current contact attempts and selected non-response assessment for this exact decision version.",
      },
      "aal2",
    ),
  );
  assert.equal(response.status, 200);
  assert.equal(
    called.name,
    "server_signoff_case_decision_nonresponse_for_actor",
  );
  assert.equal(called.args.p_actor, actorId);
  assert.equal(called.args.p_decision_version, 3);
  assert.equal(called.args.p_expected_case_version, 8);
  assert.equal(called.args.p_auth_aal, "aal2");
  assert.equal(called.args.p_substantive_reasoning.length > 100, true);
});

test("case finalization derives the staff actor and validates the executed amounts", async () => {
  let called;
  const handler = createCaseCommandHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async (name, args) => {
      called = { name, args };
      return {
        case_id: caseId,
        status: "closed",
        version: 14,
        finalization_status: "executed",
        decision_version: 5,
        outcome: "split",
        gross_principal_kobo: "300000",
        worker_award_gross_kobo: "200000",
        poster_refund_gross_kobo: "100000",
        retained_hold_gross_kobo: "0",
        commission_kobo: "10000",
        worker_net_kobo: "190000",
        refund_status: "authorized",
        journal_id: jobId,
        internal_note: "private",
      };
    },
  });
  const response = await handler(
    req(
      {
        action: "finalize_case",
        case_id: caseId,
        idempotency_key: idem,
        decision_version: 5,
        expected_case_version: 13,
      },
      "aal2",
    ),
  );
  const body = await response.json();
  assert.equal(response.status, 200);
  assert.equal(called.name, "server_finalize_case_for_actor");
  assert.deepEqual(called.args, {
    p_actor: actorId,
    p_case_id: caseId,
    p_decision_version: 5,
    p_expected_case_version: 13,
    p_auth_aal: "aal2",
    p_idempotency_key: idem,
  });
  assert.equal(body.result.finalization_status, "executed");
  assert.equal(body.result.worker_net_kobo, "190000");
  assert.equal(body.result.refund_status, "authorized");
  assert.equal("journal_id" in body.result, false);
  assert.equal("internal_note" in body.result, false);

  let calledAtAal1 = false;
  const aal1Handler = createCaseCommandHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async () => {
      calledAtAal1 = true;
      return {};
    },
  });
  const denied = await aal1Handler(
    req(
      {
        action: "finalize_case",
        case_id: caseId,
        idempotency_key: idem,
        decision_version: 5,
        expected_case_version: 13,
      },
      "aal1",
    ),
  );
  assert.equal(denied.status, 403);
  assert.equal(calledAtAal1, false);
});

test("an ineligible case finalization returns a safe retry response", async () => {
  const handler = createCaseCommandHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async () => {
      throw Object.assign(new Error("not ready"), {
        code: "appeal_window_open",
      });
    },
  });
  const response = await handler(
    req(
      {
        action: "finalize_case",
        case_id: caseId,
        idempotency_key: idem,
        decision_version: 5,
        expected_case_version: 13,
      },
      "aal2",
    ),
  );
  const body = await response.json();
  assert.equal(response.status, 409);
  assert.equal(body.error.code, "case_finalization_not_ready");
  assert.equal(
    body.next_step,
    "Wait for the appeal period or required review to finish.",
  );
});

test("participants can only answer an open case request at AAL1", async () => {
  let called;
  const handler = createCaseCommandHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async (name, args) => {
      called = { name, args };
      return {
        case_id: caseId,
        status: "under_review",
        version: 3,
        request_number: 1,
        received: true,
      };
    },
  });
  const response = await handler(
    req(
      {
        action: "respond_to_case_information",
        case_id: caseId,
        idempotency_key: idem,
        request_number: 1,
        response: "I have attached the requested details.",
      },
      "aal1",
    ),
  );
  assert.equal(response.status, 200);
  assert.equal(called.args.p_auth_aal, "aal1");
  assert.deepEqual(called.args.p_payload, {
    request_number: 1,
    response: "I have attached the requested details.",
  });
  const staffAction = await handler(
    req(
      {
        action: "triage_case",
        case_id: caseId,
        idempotency_key: idem,
        priority: "normal",
        rationale: "Review this case.",
      },
      "aal1",
    ),
  );
  assert.equal(staffAction.status, 403);
});

test("invalid private reviewer details fail closed without leaking raw response", async () => {
  const handler = createCaseReadHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async () => ({
      ...participantRow,
      secret_note: "not for participants",
    }),
  });
  const response = await handler(
    req({ action: "participant_detail", case_id: caseId }),
  );
  const body = await response.json();
  assert.equal(response.status, 200);
  assert.equal("secret_note" in body.data, false);
  assert.equal("assigned_reviewer_id" in body.data, false);
  assert.ok(!JSON.stringify(body).includes("not for participants"));
});

test("participant projections with report IDs inconsistent with case IDs fail closed", async () => {
  const handler = createCaseReadHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async () => ({ ...participantRow, hold: { ...hold, hold_id: jobId } }),
  });
  const response = await handler(
    req({ action: "participant_detail", case_id: caseId }),
  );
  assert.equal(response.status, 503);
  const body = await response.json();
  assert.deepEqual(body.error, { code: "case_read_unavailable" });
});

test("the command response is limited to a current under-review assignment", async () => {
  const handler = createCaseCommandHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async () => ({
      case_id: caseId,
      status: "closed",
      version: 9,
      assigned: true,
    }),
  });
  const response = await handler(
    req(
      {
        action: "assign_reviewer",
        case_id: caseId,
        reviewer_id: actorId,
        idempotency_key: idem,
      },
      "aal2",
    ),
  );
  assert.equal(response.status, 503);
  assert.equal((await response.json()).error.code, "case_command_unavailable");
});

test("case read requires authenticated POST with a bounded body", async () => {
  const handler = createCaseReadHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async () => participantRow,
  });
  const get = await handler(
    new Request("http://local.test/cases", { method: "GET" }),
  );
  assert.equal(get.status, 405);
  const large = await handler(
    new Request("http://local.test/cases", {
      method: "POST",
      headers: { authorization: `Bearer ${bearer()}` },
      body: `{"action":"participant_detail","case_id":"${caseId}","padding":"${"x".repeat(5000)}"}`,
    }),
  );
  assert.equal(large.status, 413);
});

test("appeal receipt commits before the case-lock processing command", async () => {
  const appealId = "66666666-6666-4666-8666-666666666666";
  const calls = [];
  const handler = createCaseCommandHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async (name, args) => {
      calls.push({ name, args });
      return name === "server_record_case_appeal_receipt_for_actor"
        ? {
            appeal_id: appealId,
            received: true,
            received_at: now,
            replayed: false,
          }
        : {
            case_id: caseId,
            status: "appeal",
            version: 2,
            received: true,
            applied: true,
          };
    },
  });
  const response = await handler(
    req(
      {
        action: "submit_case_appeal",
        case_id: caseId,
        statement:
          "I am appealing because the decision does not match the work I submitted.",
        idempotency_key: idem,
      },
      "aal1",
    ),
  );
  const body = await response.json();
  assert.equal(response.status, 200);
  assert.deepEqual(
    calls.map(({ name }) => name),
    [
      "server_record_case_appeal_receipt_for_actor",
      "server_process_case_appeal_receipt_for_actor",
    ],
  );
  assert.equal(calls[0].args.p_actor, actorId);
  assert.equal(calls[0].args.p_auth_aal, "aal1");
  assert.equal("p_received_at" in calls[0].args, false);
  assert.equal(calls[1].args.p_appeal_id, appealId);
  assert.deepEqual(body.result, {
    case_id: caseId,
    status: "appeal",
    version: 2,
    received: true,
  });
});

test("participants cannot provide an appeal timestamp or another actor", async () => {
  let calls = 0;
  const handler = createCaseCommandHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async () => {
      calls += 1;
      return {};
    },
  });
  const response = await handler(
    req(
      {
        action: "submit_case_appeal",
        case_id: caseId,
        statement:
          "I am appealing because the decision does not match the work I submitted.",
        idempotency_key: idem,
        received_at: "2026-11-05T12:00:00.000Z",
      },
      "aal1",
    ),
  );
  assert.equal(response.status, 400);
  assert.equal(calls, 0);
});

test("late appeal returns a safe support route without pretending it was filed", async () => {
  let calls = 0;
  const handler = createCaseCommandHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async () => {
      calls += 1;
      throw { code: "appeal_window_closed" };
    },
  });
  const response = await handler(
    req(
      {
        action: "submit_case_appeal",
        case_id: caseId,
        statement:
          "I am appealing because the decision does not match the work I submitted.",
        idempotency_key: idem,
      },
      "aal1",
    ),
  );
  const body = await response.json();
  assert.equal(response.status, 409);
  assert.equal(calls, 1);
  assert.deepEqual(body.error, { code: "appeal_window_closed" });
  assert.equal(body.next_step, "Contact case support for help.");
});

test("participant appeal projection includes only their statement and deadline", async () => {
  const handler = createCaseReadHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async () => ({
      ...participantRow,
      appeal: {
        decision: {
          decision_version: 1,
          outcome: "split",
          reason_code: "incomplete_work",
          public_explanation:
            "The reviewed work supports a partial award under the agreed terms.",
          gross_principal_kobo: "300000",
          worker_award_gross_kobo: "200000",
          poster_refund_gross_kobo: "100000",
          retained_hold_gross_kobo: "0",
          commission_kobo: "10000",
          worker_net_kobo: "190000",
        },
        durable_notified_at: now,
        appeal_deadline_at: "2026-11-09T12:00:00.000Z",
        can_appeal: true,
        my_appeal: {
          statement:
            "I am appealing because the decision does not match the work I submitted.",
          received_at: now,
          status: "under_review",
        },
        other_party_appeal_received: true,
        status: "under_review",
        requests: [],
      },
    }),
  });
  const response = await handler(
    req({ action: "participant_detail", case_id: caseId }),
  );
  const body = await response.json();
  assert.equal(response.status, 200);
  assert.equal(body.data.appeal.decision.decision_version, 1);
  assert.equal(body.data.appeal.can_appeal, true);
  assert.equal(body.data.appeal.other_party_appeal_received, true);
  assert.equal(
    body.data.appeal.my_appeal.statement,
    "I am appealing because the decision does not match the work I submitted.",
  );
  assert.equal("appeal_id" in body.data.appeal.my_appeal, false);
});
