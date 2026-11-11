const UUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
const MAX_BODY_BYTES = 4096;
const CASE_STATES = new Set([
  "open",
  "under_review",
  "contacting_other_party",
  "verifying",
  "decision_made",
  "appeal",
  "refund_pending",
  "closed",
]);
const WORK_STATES = new Set(["assigned", "in_progress", "submitted"]);
const FINDINGS = new Set([
  "supported",
  "not_supported",
  "inconclusive",
  "needs_more_information",
]);
const REASONS = new Set([
  "payment_not_released",
  "incomplete_work",
  "work_not_as_described",
  "unresponsive_no_show",
  "conduct_safety",
  "other",
]);
const REFUND_PROGRESS = new Set([
  "authorized",
  "queued_for_liquidity",
  "processing",
  "unknown",
  "failed",
  "exception",
  "settled",
  "reversed",
]);

function json(status, body, requestId) {
  return new Response(JSON.stringify({ ...body, request_id: requestId }), {
    status,
    headers: {
      "cache-control": "no-store",
      "content-type": "application/json; charset=utf-8",
      "x-request-id": requestId,
    },
  });
}

function fail(status, code, requestId) {
  return json(status, { error: { code } }, requestId);
}

function claimsFrom(token) {
  const part = token?.split(".")[1];
  if (!part || !/^[A-Za-z0-9_-]+$/.test(part)) return null;
  try {
    const normalized = part.replaceAll("-", "+").replaceAll("_", "/");
    return JSON.parse(
      atob(normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=")),
    );
  } catch {
    return null;
  }
}

function timestamp(value) {
  return (
    typeof value === "string" &&
    Number.isFinite(Date.parse(value)) &&
    new Date(value).toISOString()
  );
}

function safeHold(value) {
  if (
    !value ||
    !UUID.test(value.hold_id ?? "") ||
    (value.case_id !== undefined && value.case_id !== value.hold_id) ||
    value.status !== "open" ||
    !WORK_STATES.has(value.prior_assignment_state) ||
    !REASONS.has(value.reason_code) ||
    typeof value.narrative !== "string" ||
    value.narrative.length < 1 ||
    value.narrative.length > 2000 ||
    typeof value.desired_outcome !== "string" ||
    value.desired_outcome.length < 1 ||
    value.desired_outcome.length > 500 ||
    (value.follow_up !== null &&
      (typeof value.follow_up !== "string" || value.follow_up.length > 500)) ||
    !timestamp(value.opened_at)
  )
    throw new Error("invalid_case_projection");
  return {
    case_id: value.case_id ?? value.hold_id,
    hold_id: value.hold_id,
    status: "open",
    prior_assignment_state: value.prior_assignment_state,
    reason_code: value.reason_code,
    narrative: value.narrative,
    desired_outcome: value.desired_outcome,
    follow_up: value.follow_up,
    opened_at: timestamp(value.opened_at),
  };
}

function safeTimelineEvent(value) {
  const createdAt = timestamp(value?.created_at);
  if (!createdAt) throw new Error("invalid_case_projection");
  let details;
  if (value.event_type === "case_opened") {
    const source = value.details;
    if (
      !source ||
      source.status !== "open" ||
      !["worker", "poster"].includes(source.reporter_role) ||
      !REASONS.has(source.reason_code) ||
      typeof source.narrative !== "string" ||
      source.narrative.length < 1 ||
      source.narrative.length > 2000 ||
      typeof source.desired_outcome !== "string" ||
      source.desired_outcome.length < 1 ||
      source.desired_outcome.length > 500 ||
      (source.follow_up !== null &&
        (typeof source.follow_up !== "string" ||
          source.follow_up.length > 500)) ||
      !WORK_STATES.has(source.prior_assignment_state)
    )
      throw new Error("invalid_case_projection");
    details = {
      status: "open",
      reporter_role: source.reporter_role,
      reason_code: source.reason_code,
      narrative: source.narrative,
      desired_outcome: source.desired_outcome,
      follow_up: source.follow_up,
      prior_assignment_state: source.prior_assignment_state,
    };
  } else if (
    ["reviewer_assigned", "reviewer_reassigned", "status_changed"].includes(
      value.event_type,
    )
  ) {
    if (
      value.details?.status !== "under_review" ||
      value.details?.update !== "A reviewer is looking into the case."
    )
      throw new Error("invalid_case_projection");
    details = {
      status: "under_review",
      update: "A reviewer is looking into the case.",
    };
  } else if (value.event_type === "case_triaged") {
    if (
      value.details?.status !== "under_review" ||
      value.details?.update !== "A reviewer is looking into the case."
    )
      throw new Error("invalid_case_projection");
    details = {
      status: "under_review",
      update: "A reviewer is looking into the case.",
    };
  } else if (value.event_type === "information_requested") {
    const source = value.details;
    if (
      !source ||
      !Number.isInteger(source.request_number) ||
      source.request_number < 1 ||
      source.request_number > 100 ||
      !["information", "evidence"].includes(source.request_kind) ||
      source.status !== "open" ||
      typeof source.prompt !== "string" ||
      source.prompt.trim().length < 1 ||
      source.prompt.length > 500 ||
      /https?:\/\/|\bwww\.|[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}/i.test(
        source.prompt,
      )
    )
      throw new Error("invalid_case_projection");
    details = {
      request_number: source.request_number,
      request_kind: source.request_kind,
      prompt: source.prompt,
      status: "open",
    };
  } else if (
    ["participant_response", "evidence_added"].includes(value.event_type)
  ) {
    const source = value.details;
    const expected =
      value.event_type === "participant_response"
        ? ["Your response was received.", "Your appeal response was received."]
        : "The uploaded file is awaiting safety inspection.";
    if (
      !source ||
      !(Array.isArray(expected)
        ? expected.includes(source.update)
        : source.update === expected)
    )
      throw new Error("invalid_case_projection");
    details = { update: source.update };
  } else if (
    ["appeal_opened", "appeal_reviewer_assigned"].includes(value.event_type)
  ) {
    const expected =
      value.event_type === "appeal_opened"
        ? "An appeal was received and is being reviewed."
        : "A separate reviewer is reviewing the appeal.";
    if (value.details?.update !== expected)
      throw new Error("invalid_case_projection");
    details = { update: expected };
  } else if (value.event_type === "decision_notified") {
    const source = value.details;
    const decision = safePublicDecision(source);
    const notifiedAt = timestamp(source?.notified_at);
    const deadlineAt = timestamp(source?.appeal_deadline_at);
    if (
      !notifiedAt ||
      !deadlineAt ||
      Date.parse(deadlineAt) - Date.parse(notifiedAt) !== 72 * 60 * 60 * 1000
    )
      throw new Error("invalid_case_projection");
    details = {
      ...decision,
      notified_at: notifiedAt,
      appeal_deadline_at: deadlineAt,
    };
  } else if (value.event_type === "appeal_decision_recorded") {
    const source = value.details;
    if (source?.update !== "The appeal review is complete.")
      throw new Error("invalid_case_projection");
    details = {
      update: source.update,
      ...safePublicDecision(source),
    };
  } else if (value.event_type === "case_closed") {
    const source = value.details;
    const finalization = safeFinalizationAmounts(source);
    if (
      source?.status !== "closed" ||
      source?.update !== "The case decision has been finalized." ||
      source?.execution_status !== "executed"
    )
      throw new Error("invalid_case_projection");
    details = {
      status: "closed",
      update: source.update,
      ...finalization,
      execution_status: "executed",
    };
  } else {
    throw new Error("invalid_case_projection");
  }
  return { event_type: value.event_type, created_at: createdAt, details };
}

function safeParticipantCase(value, includeParticipantDetails = false) {
  const hold = safeHold(value?.hold);
  const finalization =
    value?.finalization == null
      ? null
      : safeFinalizationSummary(value.finalization);
  if (
    !value ||
    !UUID.test(value.case_id ?? "") ||
    !UUID.test(value.assignment_id ?? "") ||
    !CASE_STATES.has(value.status) ||
    !Number.isInteger(value.version) ||
    value.version < 1 ||
    !timestamp(value.opened_at) ||
    !timestamp(value.updated_at) ||
    !Array.isArray(value.timeline) ||
    value.timeline.length > 100 ||
    typeof value.timeline_truncated !== "boolean"
  )
    throw new Error("invalid_case_projection");
  if (hold.case_id !== value.case_id)
    throw new Error("invalid_case_projection");
  if ((value.status === "closed") !== (finalization !== null))
    throw new Error("invalid_case_projection");
  const result = {
    case_id: value.case_id,
    assignment_id: value.assignment_id,
    status: value.status,
    version: value.version,
    opened_at: timestamp(value.opened_at),
    updated_at: timestamp(value.updated_at),
    hold,
    finalization,
    timeline: value.timeline.map(safeTimelineEvent),
    timeline_truncated: value.timeline_truncated,
  };
  if (includeParticipantDetails) {
    if (!["worker", "poster"].includes(value.participant_role))
      throw new Error("invalid_case_projection");
    result.participant_role = value.participant_role;
    result.investigation = safeParticipantInvestigation(value.investigation);
    result.appeal = safeParticipantAppeal(value.appeal);
  }
  return result;
}

function safeFinalizationAmounts(value) {
  const amount = (item) =>
    typeof item === "string" && /^(0|[1-9][0-9]{0,8})$/.test(item);
  const refundSettledAt = value?.refund_settled_at
    ? timestamp(value.refund_settled_at)
    : null;
  if (
    !value ||
    !Number.isInteger(value.decision_version) ||
    value.decision_version < 1 ||
    !["full_worker_award", "full_poster_refund", "split", "no_action"].includes(
      value.outcome,
    ) ||
    (!REFUND_PROGRESS.has(value.refund_status) &&
      value.refund_status !== "not_applicable") ||
    !amount(value.gross_principal_kobo) ||
    !amount(value.worker_award_gross_kobo) ||
    !amount(value.poster_refund_gross_kobo) ||
    !amount(value.retained_hold_gross_kobo) ||
    !amount(value.commission_kobo) ||
    !amount(value.worker_net_kobo)
  )
    throw new Error("invalid_case_projection");
  const gross = BigInt(value.gross_principal_kobo);
  const award = BigInt(value.worker_award_gross_kobo);
  const refund = BigInt(value.poster_refund_gross_kobo);
  const retained = BigInt(value.retained_hold_gross_kobo);
  const commission = BigInt(value.commission_kobo);
  if (
    gross !== award + refund + retained ||
    commission !== (award === 0n ? 0n : (award * 500n + 5000n) / 10000n) ||
    BigInt(value.worker_net_kobo) !== award - commission ||
    (refund === 0n) !== (value.refund_status === "not_applicable") ||
    ["settled", "reversed"].includes(value.refund_status) !==
      Boolean(refundSettledAt) ||
    (value.outcome === "full_worker_award" &&
      (award !== gross || refund !== 0n || retained !== 0n)) ||
    (value.outcome === "full_poster_refund" &&
      (refund !== gross || award !== 0n || retained !== 0n)) ||
    (value.outcome === "split" &&
      (award === 0n || refund === 0n || retained !== 0n)) ||
    (value.outcome === "no_action" &&
      (award !== 0n || refund !== 0n || retained !== gross))
  )
    throw new Error("invalid_case_projection");
  return {
    decision_version: value.decision_version,
    outcome: value.outcome,
    gross_principal_kobo: value.gross_principal_kobo,
    worker_award_gross_kobo: value.worker_award_gross_kobo,
    poster_refund_gross_kobo: value.poster_refund_gross_kobo,
    retained_hold_gross_kobo: value.retained_hold_gross_kobo,
    commission_kobo: value.commission_kobo,
    worker_net_kobo: value.worker_net_kobo,
    refund_status: value.refund_status,
    refund_settled_at: refundSettledAt,
  };
}

function safeFinalizationSummary(value) {
  const executedAt = timestamp(value?.executed_at);
  if (value?.status !== "executed" || !executedAt)
    throw new Error("invalid_case_projection");
  return {
    ...safeFinalizationAmounts(value),
    status: "executed",
    executed_at: executedAt,
  };
}

function safeCaseFile(file) {
  const createdAt = timestamp(file?.created_at);
  if (
    !file ||
    !Number.isInteger(file.evidence_number) ||
    file.evidence_number < 1 ||
    file.evidence_number > 25 ||
    (file.request_number !== null &&
      (!Number.isInteger(file.request_number) ||
        file.request_number < 1 ||
        file.request_number > 100)) ||
    !["image/jpeg", "image/png", "application/pdf"].includes(
      file.content_type,
    ) ||
    !Number.isInteger(file.size_bytes) ||
    file.size_bytes < 1 ||
    file.size_bytes > 100_000_000 ||
    !["quarantined", "ready", "rejected"].includes(file.safety_state) ||
    !createdAt
  )
    throw new Error("invalid_case_projection");
  return {
    evidence_number: file.evidence_number,
    request_number: file.request_number,
    content_type: file.content_type,
    size_bytes: file.size_bytes,
    safety_state: file.safety_state,
    created_at: createdAt,
  };
}

function safeParticipantInvestigation(value) {
  if (!value || !Array.isArray(value.requests) || !Array.isArray(value.files))
    throw new Error("invalid_case_projection");
  const requests = value.requests.map((request) => {
    const createdAt = timestamp(request?.created_at);
    const respondedAt = request?.responded_at
      ? timestamp(request.responded_at)
      : null;
    if (
      !request ||
      !Number.isInteger(request.request_number) ||
      request.request_number < 1 ||
      request.request_number > 100 ||
      !["information", "evidence"].includes(request.request_kind) ||
      typeof request.prompt !== "string" ||
      request.prompt.trim().length < 1 ||
      request.prompt.length > 500 ||
      /https?:\/\/|\bwww\.|[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}/i.test(
        request.prompt,
      ) ||
      !["open", "responded", "closed"].includes(request.status) ||
      !createdAt ||
      (request.response !== null &&
        (typeof request.response !== "string" ||
          request.response.length < 1 ||
          request.response.length > 2000)) ||
      (request.responded_at !== null && !respondedAt)
    )
      throw new Error("invalid_case_projection");
    return {
      request_number: request.request_number,
      request_kind: request.request_kind,
      prompt: request.prompt,
      status: request.status,
      created_at: createdAt,
      response: request.response,
      responded_at: respondedAt,
    };
  });
  if (requests.length > 100 || value.files.length > 5)
    throw new Error("invalid_case_projection");
  return { requests, files: value.files.map(safeCaseFile) };
}

function safePublicDecision(value) {
  const amount = (item) =>
    typeof item === "string" && /^(0|[1-9][0-9]{0,8})$/.test(item);
  if (
    !value ||
    !Number.isInteger(value.decision_version) ||
    value.decision_version < 1 ||
    !["full_worker_award", "full_poster_refund", "split", "no_action"].includes(
      value.outcome,
    ) ||
    !REASONS.has(value.reason_code) ||
    typeof value.public_explanation !== "string" ||
    value.public_explanation.length < 20 ||
    value.public_explanation.length > 2000 ||
    /https?:\/\/|\bwww\.|\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b/i.test(
      value.public_explanation,
    ) ||
    !amount(value.gross_principal_kobo) ||
    !amount(value.worker_award_gross_kobo) ||
    !amount(value.poster_refund_gross_kobo) ||
    !amount(value.retained_hold_gross_kobo) ||
    !amount(value.commission_kobo) ||
    !amount(value.worker_net_kobo)
  )
    throw new Error("invalid_case_projection");
  const gross = BigInt(value.gross_principal_kobo);
  const award = BigInt(value.worker_award_gross_kobo);
  const refund = BigInt(value.poster_refund_gross_kobo);
  const retained = BigInt(value.retained_hold_gross_kobo);
  const commission = BigInt(value.commission_kobo);
  if (
    gross !== award + refund + retained ||
    commission !== (award === 0n ? 0n : (award * 500n + 5000n) / 10000n) ||
    BigInt(value.worker_net_kobo) !== award - commission
  )
    throw new Error("invalid_case_projection");
  return {
    decision_version: value.decision_version,
    outcome: value.outcome,
    reason_code: value.reason_code,
    public_explanation: value.public_explanation,
    gross_principal_kobo: value.gross_principal_kobo,
    worker_award_gross_kobo: value.worker_award_gross_kobo,
    poster_refund_gross_kobo: value.poster_refund_gross_kobo,
    retained_hold_gross_kobo: value.retained_hold_gross_kobo,
    commission_kobo: value.commission_kobo,
    worker_net_kobo: value.worker_net_kobo,
  };
}

function safeAppealRequests(value) {
  if (!Array.isArray(value) || value.length > 100)
    throw new Error("invalid_case_projection");
  return value.map((request) => {
    const createdAt = timestamp(request?.created_at);
    const respondedAt = request?.responded_at
      ? timestamp(request.responded_at)
      : null;
    if (
      !request ||
      !Number.isInteger(request.request_number) ||
      request.request_number < 1 ||
      request.request_number > 100 ||
      !["information", "evidence"].includes(request.request_kind) ||
      typeof request.prompt !== "string" ||
      request.prompt.length < 1 ||
      request.prompt.length > 500 ||
      /https?:\/\/|\bwww\.|\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b/i.test(
        request.prompt,
      ) ||
      !["open", "responded", "closed"].includes(request.status) ||
      !createdAt ||
      (request.response !== null &&
        (typeof request.response !== "string" ||
          request.response.length < 1 ||
          request.response.length > 2000)) ||
      (request.responded_at !== null && !respondedAt)
    )
      throw new Error("invalid_case_projection");
    const result = {
      request_number: request.request_number,
      request_kind: request.request_kind,
      prompt: request.prompt,
      status: request.status,
      created_at: createdAt,
      response: request.response,
      responded_at: respondedAt,
    };
    if (request.target_party_role !== undefined) {
      if (!["worker", "poster"].includes(request.target_party_role))
        throw new Error("invalid_case_projection");
      result.target_party_role = request.target_party_role;
    }
    return result;
  });
}

function safeParticipantAppeal(value) {
  if (value === null || value === undefined) return null;
  const notifiedAt = timestamp(value.durable_notified_at);
  const deadlineAt = timestamp(value.appeal_deadline_at);
  const appealStatuses = new Set([
    "under_review",
    "window_open",
    "window_closed",
  ]);
  if (
    !notifiedAt ||
    !deadlineAt ||
    Date.parse(deadlineAt) - Date.parse(notifiedAt) !== 72 * 60 * 60 * 1000 ||
    typeof value.can_appeal !== "boolean" ||
    typeof value.other_party_appeal_received !== "boolean" ||
    !appealStatuses.has(value.status)
  )
    throw new Error("invalid_case_projection");
  let myAppeal = null;
  if (value.my_appeal !== null) {
    const receivedAt = timestamp(value.my_appeal?.received_at);
    if (
      !receivedAt ||
      typeof value.my_appeal.statement !== "string" ||
      value.my_appeal.statement.length < 20 ||
      value.my_appeal.statement.length > 2000 ||
      /https?:\/\/|\bwww\.|\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b/i.test(
        value.my_appeal.statement,
      ) ||
      !["under_review", "request_evidence", "upheld", "changed"].includes(
        value.my_appeal.status,
      )
    )
      throw new Error("invalid_case_projection");
    myAppeal = {
      statement: value.my_appeal.statement,
      received_at: receivedAt,
      status: value.my_appeal.status,
    };
  }
  const requests = safeAppealRequests(value.requests);
  return {
    decision: safePublicDecision(value.decision),
    durable_notified_at: notifiedAt,
    appeal_deadline_at: deadlineAt,
    can_appeal: value.can_appeal,
    my_appeal: myAppeal,
    other_party_appeal_received: value.other_party_appeal_received,
    status: value.status,
    requests,
  };
}

function safeStaffInvestigation(value) {
  if (
    !value ||
    !Array.isArray(value.triage) ||
    !Array.isArray(value.contact_attempts) ||
    !Array.isArray(value.requests) ||
    !Array.isArray(value.verified_facts) ||
    !Array.isArray(value.internal_notes) ||
    !Array.isArray(value.nonresponse) ||
    !Array.isArray(value.files) ||
    value.triage.length > 100 ||
    value.contact_attempts.length > 200 ||
    value.requests.length > 100 ||
    value.verified_facts.length > 200 ||
    value.internal_notes.length > 200 ||
    value.nonresponse.length > 100 ||
    value.files.length > 5
  )
    throw new Error("invalid_case_projection");
  const checkList = (rows, validator) => rows.map(validator);
  const result = {
    triage: checkList(value.triage, (row) => {
      const acknowledgedAt = timestamp(row?.acknowledged_at);
      if (
        !["normal", "urgent"].includes(row?.priority) ||
        typeof row?.rationale !== "string" ||
        row.rationale.length < 1 ||
        row.rationale.length > 500 ||
        !acknowledgedAt
      )
        throw new Error("invalid_case_projection");
      return {
        priority: row.priority,
        rationale: row.rationale,
        acknowledged_at: acknowledgedAt,
      };
    }),
    contact_attempts: checkList(value.contact_attempts, (row) => {
      const recordedAt = timestamp(row?.recorded_at);
      if (
        !["worker", "poster"].includes(row?.target_party_role) ||
        !["in_app", "phone", "email", "in_person", "other"].includes(
          row?.channel,
        ) ||
        ![
          "no_response",
          "reached",
          "declined",
          "delivery_failed",
          "contact_unavailable",
          "other",
        ].includes(row?.result) ||
        row?.attribution !== "simulated_manual_log" ||
        (row.result_note !== null &&
          (typeof row.result_note !== "string" ||
            row.result_note.length > 500)) ||
        !recordedAt
      )
        throw new Error("invalid_case_projection");
      return {
        target_party_role: row.target_party_role,
        channel: row.channel,
        result: row.result,
        result_note: row.result_note,
        attribution: row.attribution,
        recorded_at: recordedAt,
      };
    }),
    requests: value.requests.map((row) => {
      const request = safeParticipantInvestigation({
        requests: [{ ...row, target_party_role: undefined }],
        files: [],
      }).requests[0];
      if (!["worker", "poster"].includes(row.target_party_role))
        throw new Error("invalid_case_projection");
      return { ...request, target_party_role: row.target_party_role };
    }),
    verified_facts: checkList(value.verified_facts, (row) => {
      const recordedAt = timestamp(row?.recorded_at);
      if (
        !/^[a-z][a-z0-9_]{1,49}$/.test(row?.fact_code ?? "") ||
        ![...FINDINGS].includes(row?.finding) ||
        typeof row?.staff_reasoning !== "string" ||
        row.staff_reasoning.length < 20 ||
        row.staff_reasoning.length > 2000 ||
        !recordedAt
      )
        throw new Error("invalid_case_projection");
      return {
        fact_code: row.fact_code,
        finding: row.finding,
        staff_reasoning: row.staff_reasoning,
        recorded_at: recordedAt,
      };
    }),
    internal_notes: checkList(value.internal_notes, (row) => {
      const createdAt = timestamp(row?.created_at);
      if (
        typeof row?.note !== "string" ||
        row.note.length < 1 ||
        row.note.length > 2000 ||
        !createdAt
      )
        throw new Error("invalid_case_projection");
      return { note: row.note, created_at: createdAt };
    }),
    nonresponse: checkList(value.nonresponse, (row) => {
      const assessedAt = timestamp(row?.assessed_at);
      const signedOffAt = row?.signed_off_at
        ? timestamp(row.signed_off_at)
        : null;
      if (
        !["worker", "poster"].includes(row?.target_party_role) ||
        !Number.isInteger(row?.contact_attempt_count) ||
        row.contact_attempt_count < 2 ||
        !Number.isInteger(row?.distinct_channel_count) ||
        row.distinct_channel_count < 2 ||
        typeof row?.substantive_reasoning !== "string" ||
        row.substantive_reasoning.length < 100 ||
        row.substantive_reasoning.length > 2000 ||
        typeof row?.senior_signed_off !== "boolean" ||
        (row.senior_signoff_reasoning !== null &&
          (typeof row.senior_signoff_reasoning !== "string" ||
            row.senior_signoff_reasoning.length > 2000)) ||
        !assessedAt ||
        (row.signed_off_at !== null && !signedOffAt)
      )
        throw new Error("invalid_case_projection");
      return {
        target_party_role: row.target_party_role,
        contact_attempt_count: row.contact_attempt_count,
        distinct_channel_count: row.distinct_channel_count,
        substantive_reasoning: row.substantive_reasoning,
        assessed_at: assessedAt,
        senior_signed_off: row.senior_signed_off,
        senior_signoff_reasoning: row.senior_signoff_reasoning,
        signed_off_at: signedOffAt,
      };
    }),
    files: value.files.map(safeCaseFile),
  };
  if ("decision" in value) result.decision = safeStaffDecision(value.decision);
  return result;
}

function safeStaffDecision(value) {
  if (value === null) return null;
  const amount = (item) =>
    typeof item === "string" && /^(0|[1-9][0-9]{0,8})$/.test(item);
  if (
    !value ||
    !Number.isInteger(value.decision_version) ||
    value.decision_version < 1 ||
    !["full_worker_award", "full_poster_refund", "split", "no_action"].includes(
      value.outcome,
    ) ||
    !REASONS.has(value.reason_code) ||
    typeof value.public_explanation !== "string" ||
    value.public_explanation.length < 20 ||
    value.public_explanation.length > 2000 ||
    /https?:\/\/|\bwww\.|\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b/i.test(
      value.public_explanation,
    ) ||
    !amount(value.gross_principal_kobo) ||
    !amount(value.worker_award_gross_kobo) ||
    !amount(value.poster_refund_gross_kobo) ||
    !amount(value.retained_hold_gross_kobo) ||
    !amount(value.commission_kobo) ||
    !amount(value.worker_net_kobo) ||
    !Number.isInteger(value.terms_version) ||
    value.terms_version < 1 ||
    !/^[0-9a-f]{64}$/i.test(value.terms_sha256 ?? "") ||
    !Number.isInteger(value.evidence_item_count) ||
    value.evidence_item_count < 0 ||
    value.evidence_item_count > 1000 ||
    !/^[0-9a-f]{64}$/i.test(value.evidence_snapshot_sha256 ?? "") ||
    !/^[0-9a-f]{64}$/i.test(value.decision_sha256 ?? "") ||
    !Number.isInteger(value.approval_count) ||
    value.approval_count < 0 ||
    value.approval_count > 2 ||
    value.required_approvals !== 2 ||
    typeof value.nonresponse_signoff_required !== "boolean" ||
    typeof value.nonresponse_signed_off !== "boolean" ||
    ![
      "awaiting_second_approval",
      "awaiting_nonresponse_signoff",
      "approved",
    ].includes(value.status) ||
    !timestamp(value.created_at) ||
    (value.approved_at !== null && !timestamp(value.approved_at))
  )
    throw new Error("invalid_case_projection");
  const gross = BigInt(value.gross_principal_kobo);
  const award = BigInt(value.worker_award_gross_kobo);
  const refund = BigInt(value.poster_refund_gross_kobo);
  const retained = BigInt(value.retained_hold_gross_kobo);
  const commission = BigInt(value.commission_kobo);
  const workerNet = BigInt(value.worker_net_kobo);
  const expectedCommission =
    award === 0n ? 0n : (award * 500n + 5000n) / 10000n;
  if (
    gross !== award + refund + retained ||
    commission !== expectedCommission ||
    workerNet !== award - commission ||
    (value.status === "approved" &&
      (value.approved_at === null || value.approval_count !== 2)) ||
    (value.status === "awaiting_nonresponse_signoff" &&
      (!value.nonresponse_signoff_required || value.nonresponse_signed_off))
  )
    throw new Error("invalid_case_projection");
  return {
    decision_version: value.decision_version,
    outcome: value.outcome,
    reason_code: value.reason_code,
    public_explanation: value.public_explanation,
    gross_principal_kobo: value.gross_principal_kobo,
    worker_award_gross_kobo: value.worker_award_gross_kobo,
    poster_refund_gross_kobo: value.poster_refund_gross_kobo,
    retained_hold_gross_kobo: value.retained_hold_gross_kobo,
    commission_kobo: value.commission_kobo,
    worker_net_kobo: value.worker_net_kobo,
    terms_version: value.terms_version,
    terms_sha256: value.terms_sha256,
    evidence_item_count: value.evidence_item_count,
    evidence_snapshot_sha256: value.evidence_snapshot_sha256,
    decision_sha256: value.decision_sha256,
    approval_count: value.approval_count,
    required_approvals: 2,
    nonresponse_signoff_required: value.nonresponse_signoff_required,
    nonresponse_signed_off: value.nonresponse_signed_off,
    created_at: timestamp(value.created_at),
    approved_at: value.approved_at ? timestamp(value.approved_at) : null,
    status: value.status,
  };
}

function safeStaffTrace(value) {
  if (!value || !("decision" in value) || !("finalization" in value))
    throw new Error("invalid_case_projection");
  let decision = null;
  if (value.decision !== null) {
    const source = value.decision;
    if (
      !UUID.test(source?.decision_id ?? "") ||
      !Number.isInteger(source?.decision_version) ||
      source.decision_version < 1 ||
      !/^[0-9a-f]{64}$/i.test(source?.decision_sha256 ?? "") ||
      !UUID.test(source?.proposed_by ?? "") ||
      !timestamp(source?.proposed_at) ||
      !Array.isArray(source?.approvals) ||
      source.approvals.length > 2
    )
      throw new Error("invalid_case_projection");
    const approvalNumbers = new Set();
    const approvals = source.approvals.map((approval) => {
      if (
        ![1, 2].includes(approval?.approval_number) ||
        approvalNumbers.has(approval.approval_number) ||
        !UUID.test(approval?.actor_id ?? "") ||
        !timestamp(approval?.approved_at)
      )
        throw new Error("invalid_case_projection");
      approvalNumbers.add(approval.approval_number);
      return {
        approval_number: approval.approval_number,
        actor_id: approval.actor_id,
        approved_at: timestamp(approval.approved_at),
      };
    });
    let seniorSignoff = null;
    if (source.senior_signoff !== null) {
      if (
        !UUID.test(source.senior_signoff?.actor_id ?? "") ||
        !timestamp(source.senior_signoff?.signed_at)
      )
        throw new Error("invalid_case_projection");
      seniorSignoff = {
        actor_id: source.senior_signoff.actor_id,
        signed_at: timestamp(source.senior_signoff.signed_at),
      };
    }
    decision = {
      decision_id: source.decision_id,
      decision_version: source.decision_version,
      decision_sha256: source.decision_sha256,
      proposed_by: source.proposed_by,
      proposed_at: timestamp(source.proposed_at),
      approvals,
      senior_signoff: seniorSignoff,
    };
  }
  let finalization = null;
  if (value.finalization !== null) {
    const source = value.finalization;
    if (
      !UUID.test(source?.finalization_id ?? "") ||
      !Number.isInteger(source?.decision_version) ||
      source.decision_version < 1 ||
      !UUID.test(source?.finalized_by ?? "") ||
      !timestamp(source?.finalized_at)
    )
      throw new Error("invalid_case_projection");
    let refund = null;
    if (source.refund !== null) {
      const row = source.refund;
      const optionalReference = (item) =>
        item === null ||
        (typeof item === "string" && item.length > 0 && item.length <= 180);
      if (
        !REFUND_PROGRESS.has(row?.status) ||
        !/^(0|[1-9][0-9]{0,8})$/.test(row?.amount_kobo ?? "") ||
        !(row?.operation_id === null || UUID.test(row?.operation_id ?? "")) ||
        !optionalReference(row?.operation_reference) ||
        !optionalReference(row?.provider_refund_reference) ||
        !optionalReference(row?.source_collection_reference) ||
        (["settled", "reversed"].includes(row.status) &&
          (!row.provider_refund_reference ||
            !row.operation_reference ||
            !row.source_collection_reference))
      )
        throw new Error("invalid_case_projection");
      refund = {
        status: row.status,
        amount_kobo: row.amount_kobo,
        operation_id: row.operation_id,
        operation_reference: row.operation_reference,
        provider_refund_reference: row.provider_refund_reference,
        source_collection_reference: row.source_collection_reference,
      };
    }
    finalization = {
      finalization_id: source.finalization_id,
      decision_version: source.decision_version,
      finalized_by: source.finalized_by,
      finalized_at: timestamp(source.finalized_at),
      refund,
    };
  }
  return { decision, finalization };
}

function safeStaffCase(value) {
  const result = safeParticipantCase({
    ...value,
    timeline: [],
    timeline_truncated: false,
    hold: value?.hold,
  });
  const terms = value.terms_snapshot;
  const messages = value.conversation_snapshot;
  const applicationDeadline = timestamp(terms?.application_deadline_at);
  const neededBy = timestamp(terms?.needed_by_at);
  if (
    !terms ||
    !UUID.test(terms.job_id ?? "") ||
    !Number.isInteger(terms.terms_version) ||
    terms.terms_version < 1 ||
    typeof terms.title !== "string" ||
    terms.title.length < 3 ||
    terms.title.length > 100 ||
    typeof terms.description !== "string" ||
    terms.description.length < 20 ||
    terms.description.length > 5000 ||
    !/^[a-z0-9-]{1,50}$/.test(terms.category_slug ?? "") ||
    !["on_campus", "remote", "hybrid"].includes(terms.location_type) ||
    (terms.location_detail !== null &&
      (typeof terms.location_detail !== "string" ||
        terms.location_detail.length < 2 ||
        terms.location_detail.length > 160)) ||
    !/^[1-9][0-9]*$/.test(terms.gross_per_worker_kobo ?? "") ||
    !Number.isInteger(terms.slot_count) ||
    terms.slot_count < 1 ||
    terms.slot_count > 10 ||
    !/^[1-9][0-9]*$/.test(terms.gross_total_kobo ?? "") ||
    BigInt(terms.gross_per_worker_kobo) * BigInt(terms.slot_count) !==
      BigInt(terms.gross_total_kobo) ||
    !applicationDeadline ||
    !neededBy ||
    Date.parse(applicationDeadline) > Date.parse(neededBy) ||
    typeof terms.start_requirements !== "string" ||
    terms.start_requirements.length > 1000 ||
    typeof terms.application_note !== "string" ||
    terms.application_note.length > 500 ||
    !/^[0-9a-f]{64}$/i.test(terms.terms_sha256 ?? "") ||
    !Array.isArray(messages) ||
    messages.length > 100 ||
    typeof value.conversation_truncated !== "boolean"
  )
    throw new Error("invalid_case_projection");
  const safeMessages = messages.map((message) => {
    if (
      !message ||
      !/^[1-9][0-9]*$/.test(message.sequence ?? "") ||
      !["worker", "poster"].includes(message.sender_role) ||
      typeof message.body !== "string" ||
      message.body.length < 1 ||
      message.body.length > 2000 ||
      !timestamp(message.created_at)
    )
      throw new Error("invalid_case_projection");
    return {
      sequence: message.sequence,
      sender_role: message.sender_role,
      body: message.body,
      created_at: timestamp(message.created_at),
    };
  });
  if (!value.investigation) throw new Error("invalid_case_projection");
  return {
    ...result,
    terms_snapshot: {
      job_id: terms.job_id,
      terms_version: terms.terms_version,
      title: terms.title,
      description: terms.description,
      category_slug: terms.category_slug,
      location_type: terms.location_type,
      location_detail: terms.location_detail,
      gross_per_worker_kobo: terms.gross_per_worker_kobo,
      slot_count: terms.slot_count,
      gross_total_kobo: terms.gross_total_kobo,
      application_deadline_at: applicationDeadline,
      needed_by_at: neededBy,
      start_requirements: terms.start_requirements,
      application_note: terms.application_note,
      terms_sha256: terms.terms_sha256,
    },
    conversation_snapshot: safeMessages,
    conversation_truncated: value.conversation_truncated,
    investigation: safeStaffInvestigation(value.investigation),
  };
}

function safeReviewQueue(value) {
  if (!value || !Array.isArray(value.items))
    throw new Error("invalid_case_queue_items");
  if (value.items.length > 50) throw new Error("invalid_case_queue_page_size");
  if (typeof value.truncated !== "boolean")
    throw new Error("invalid_case_queue_truncation_flag");
  const items = value.items.map((item) => {
    const openedAt = timestamp(item?.opened_at);
    if (
      !item ||
      !UUID.test(item.case_id ?? "") ||
      !UUID.test(item.assignment_id ?? "")
    )
      throw new Error("invalid_case_queue_identity");
    if (
      !["open", "under_review", "contacting_other_party", "verifying"].includes(
        item.status,
      )
    )
      throw new Error("invalid_case_queue_status");
    if (!openedAt) throw new Error("invalid_case_queue_opened_at");
    if (!/^(0|[1-9][0-9]*)$/.test(item.age_seconds ?? ""))
      throw new Error("invalid_case_queue_age");
    if (!REASONS.has(item.reason_code))
      throw new Error("invalid_case_queue_reason");
    if (!["normal", "urgent"].includes(item.priority))
      throw new Error("invalid_case_queue_priority");
    if (typeof item.assigned_to_me !== "boolean")
      throw new Error("invalid_case_queue_assignment");
    return {
      case_id: item.case_id,
      assignment_id: item.assignment_id,
      status: item.status,
      opened_at: openedAt,
      age_seconds: item.age_seconds,
      reason_code: item.reason_code,
      priority: item.priority,
      assigned_to_me: item.assigned_to_me,
    };
  });
  return { items, truncated: value.truncated };
}

function safeAppealQueue(value) {
  if (
    !value ||
    !Array.isArray(value.items) ||
    value.items.length > 50 ||
    typeof value.truncated !== "boolean"
  )
    throw new Error("invalid_case_queue_projection");
  return {
    items: value.items.map((item) => {
      const openedAt = timestamp(item?.opened_at);
      const deadlineAt = timestamp(item?.appeal_deadline_at);
      if (
        !item ||
        !UUID.test(item.case_id ?? "") ||
        !UUID.test(item.assignment_id ?? "") ||
        !["appeal", "verifying", "decision_made"].includes(item.status) ||
        !openedAt ||
        !deadlineAt ||
        !/^(0|[1-9][0-9]*)$/.test(item.age_seconds ?? "") ||
        !Number.isInteger(item.pending_appeal_count) ||
        item.pending_appeal_count < 1 ||
        item.pending_appeal_count > 2 ||
        typeof item.assigned_to_me !== "boolean"
      )
        throw new Error("invalid_case_queue_projection");
      return {
        case_id: item.case_id,
        assignment_id: item.assignment_id,
        status: item.status,
        opened_at: openedAt,
        age_seconds: item.age_seconds,
        appeal_deadline_at: deadlineAt,
        pending_appeal_count: item.pending_appeal_count,
        assigned_to_me: item.assigned_to_me,
      };
    }),
    truncated: value.truncated,
  };
}

function safeAppealStaffCase(value) {
  if (!value?.appeal_review) throw new Error("invalid_case_projection");
  const result = safeStaffCase(value);
  delete result.investigation.internal_notes;
  const review = value.appeal_review;
  const deadlineAt = timestamp(review.appeal_deadline_at);
  const notifiedAt = timestamp(review.durable_notified_at);
  if (
    !Number.isInteger(review.initial_decision_version) ||
    review.initial_decision_version < 1 ||
    !/^[0-9a-f]{64}$/i.test(review.initial_decision_sha256 ?? "") ||
    !deadlineAt ||
    !notifiedAt ||
    Date.parse(deadlineAt) - Date.parse(notifiedAt) !== 72 * 60 * 60 * 1000 ||
    !Array.isArray(review.appeals) ||
    review.appeals.length > 2 ||
    ![
      null,
      "decision_not_durably_notified",
      "appeal_window_open",
      "timely_appeal_unresolved",
      "appeal_evidence_request_open",
    ].includes(review.finalization_block_reason)
  )
    throw new Error("invalid_case_projection");
  result.appeal_review = {
    initial_decision_version: review.initial_decision_version,
    initial_decision_sha256: review.initial_decision_sha256,
    appeal_deadline_at: deadlineAt,
    durable_notified_at: notifiedAt,
    finalization_block_reason: review.finalization_block_reason,
    appeals: review.appeals.map((appeal) => {
      const receivedAt = timestamp(appeal?.received_at);
      if (
        !appeal ||
        !UUID.test(appeal.appeal_id ?? "") ||
        !["worker", "poster"].includes(appeal.party_role) ||
        typeof appeal.statement !== "string" ||
        appeal.statement.length < 20 ||
        appeal.statement.length > 2000 ||
        /https?:\/\/|\bwww\.|\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b/i.test(
          appeal.statement,
        ) ||
        !receivedAt ||
        !["under_review", "request_evidence", "upheld", "changed"].includes(
          appeal.status,
        ) ||
        !Array.isArray(appeal.review_versions) ||
        appeal.review_versions.length > 100 ||
        !Array.isArray(appeal.requests) ||
        appeal.requests.length > 100
      )
        throw new Error("invalid_case_projection");
      const requests = safeAppealRequests(appeal.requests);
      return {
        appeal_id: appeal.appeal_id,
        party_role: appeal.party_role,
        statement: appeal.statement,
        received_at: receivedAt,
        status: appeal.status,
        review_versions: appeal.review_versions.map((version) => {
          const createdAt = timestamp(version?.created_at);
          if (
            !version ||
            !Number.isInteger(version.review_version) ||
            version.review_version < 1 ||
            !["request_evidence", "upheld", "changed"].includes(
              version.action,
            ) ||
            !Number.isInteger(version.applied_decision_version) ||
            version.applied_decision_version < 1 ||
            !/^[0-9a-f]{64}$/i.test(version.evidence_snapshot_sha256 ?? "") ||
            (version.public_explanation !== null &&
              (typeof version.public_explanation !== "string" ||
                version.public_explanation.length < 20 ||
                version.public_explanation.length > 2000)) ||
            (version.request_number !== null &&
              (!Number.isInteger(version.request_number) ||
                version.request_number < 1 ||
                version.request_number > 100)) ||
            !createdAt
          )
            throw new Error("invalid_case_projection");
          return {
            review_version: version.review_version,
            action: version.action,
            applied_decision_version: version.applied_decision_version,
            public_explanation: version.public_explanation,
            evidence_snapshot_sha256: version.evidence_snapshot_sha256,
            created_at: createdAt,
            request_number: version.request_number,
          };
        }),
        requests,
      };
    }),
  };
  return result;
}

async function authenticate(request, verifyActor) {
  const token = request.headers
    .get("authorization")
    ?.replace(/^Bearer\s+/i, "");
  if (!token) return null;
  const actor = await verifyActor(token).catch(() => null);
  const claims = claimsFrom(token);
  if (!actor || !UUID.test(actor.id ?? "") || claims?.sub !== actor.id)
    return null;
  return { actor, aal: claims.aal };
}

async function readBody(request) {
  const body = await request.text();
  if (new TextEncoder().encode(body).byteLength > MAX_BODY_BYTES)
    return { tooLarge: true };
  try {
    return { value: JSON.parse(body) };
  } catch {
    return { invalid: true };
  }
}

function mapError(error, requestId) {
  const code = error?.appCode ?? error?.code;
  if (code === "42501" || code === "case_access_denied")
    return fail(403, "case_access_denied", requestId);
  if (code === "P0002" || code === "case_not_found")
    return fail(404, "not_found", requestId);
  if (
    code === "23505" ||
    code === "idempotency_conflict" ||
    code === "P0001" ||
    code === "stale_state"
  )
    return fail(409, "stale_state", requestId);
  return fail(503, "case_read_unavailable", requestId);
}

export function createCaseReadHandler({
  verifyActor,
  rpc,
  requestId = () => crypto.randomUUID(),
}) {
  if (typeof verifyActor !== "function" || typeof rpc !== "function")
    throw new Error("case read dependencies are not configured");
  return async (request) => {
    const id = requestId();
    if (request.method !== "POST") return fail(405, "method_not_allowed", id);
    const auth = await authenticate(request, verifyActor);
    if (!auth) return fail(401, "authentication_required", id);
    const body = await readBody(request).catch(() => ({ invalid: true }));
    if (body.tooLarge) return fail(413, "request_too_large", id);
    const input = body.value;
    if (!input || typeof input !== "object" || Array.isArray(input))
      return fail(400, "invalid_request", id);
    try {
      if (
        input.action === "participant_detail" &&
        Object.keys(input).every((key) =>
          ["action", "case_id"].includes(key),
        ) &&
        UUID.test(input.case_id ?? "")
      ) {
        const row = await rpc("server_get_assignment_case_for_actor", {
          p_actor: auth.actor.id,
          p_case_id: input.case_id,
        });
        return json(200, { data: safeParticipantCase(row, true) }, id);
      }
      if (
        input.action === "review_queue" &&
        Object.keys(input).every((key) => key === "action")
      ) {
        if (auth.aal !== "aal2") return fail(403, "case_access_denied", id);
        const row = await rpc("server_list_assignment_case_queue_for_actor", {
          p_actor: auth.actor.id,
          p_auth_aal: auth.aal,
          p_limit: 51,
        });
        return json(200, { data: safeReviewQueue(row) }, id);
      }
      if (
        input.action === "appeal_review_queue" &&
        Object.keys(input).every((key) => key === "action")
      ) {
        if (auth.aal !== "aal2") return fail(403, "case_access_denied", id);
        const row = await rpc(
          "server_list_assignment_case_appeal_queue_for_actor",
          {
            p_actor: auth.actor.id,
            p_auth_aal: auth.aal,
            p_limit: 51,
          },
        );
        return json(200, { data: safeAppealQueue(row) }, id);
      }
      if (
        input.action === "appeal_reviewer_detail" &&
        Object.keys(input).every((key) =>
          ["action", "case_id"].includes(key),
        ) &&
        UUID.test(input.case_id ?? "")
      ) {
        if (auth.aal !== "aal2") return fail(403, "case_access_denied", id);
        const row = await rpc(
          "server_get_assignment_case_appeal_for_reviewer",
          {
            p_actor: auth.actor.id,
            p_case_id: input.case_id,
            p_auth_aal: auth.aal,
          },
        );
        return json(200, { data: safeAppealStaffCase(row) }, id);
      }
      if (
        input.action === "reviewer_detail" &&
        Object.keys(input).every((key) =>
          ["action", "case_id"].includes(key),
        ) &&
        UUID.test(input.case_id ?? "")
      ) {
        if (auth.aal !== "aal2") return fail(403, "case_access_denied", id);
        const row = await rpc("server_get_assignment_case_for_reviewer", {
          p_actor: auth.actor.id,
          p_case_id: input.case_id,
          p_auth_aal: auth.aal,
        });
        const data = safeStaffCase(row);
        const traceability = safeStaffTrace(row.traceability);
        if ((data.status === "closed") !== (traceability.finalization !== null))
          throw new Error("invalid_case_projection");
        return json(200, { data: { ...data, traceability } }, id);
      }
      return fail(400, "invalid_request", id);
    } catch (error) {
      const code =
        typeof error?.code === "string" && /^[A-Z0-9_]{1,32}$/.test(error.code)
          ? error.code
          : "unclassified";
      const category =
        typeof error?.safeCategory === "string" &&
        /^[a-z][a-z0-9_]{0,63}$/.test(error.safeCategory)
          ? error.safeCategory
          : typeof error?.message === "string" &&
              /^[a-z][a-z0-9_]{0,63}$/.test(error.message)
            ? error.message
            : "case_read_failure";
      const response = mapError(error, id);
      if (response.status === 503)
        console.error(
          JSON.stringify({
            event: "case_read_failure",
            request_id: id,
            code,
            category,
          }),
        );
      return response;
    }
  };
}
