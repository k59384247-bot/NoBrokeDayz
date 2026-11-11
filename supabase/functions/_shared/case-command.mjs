const UUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
const MAX_BODY_BYTES = 4096;
const STAFF_ACTIONS = {
  triage_case: ["priority", "rationale"],
  log_case_contact_attempt: [
    "target_party_role",
    "channel",
    "result",
    "result_note",
  ],
  request_case_information: ["target_party_role", "request_kind", "prompt"],
  respond_to_case_information: ["request_number", "response"],
  record_case_fact: ["fact_code", "finding", "staff_reasoning"],
  add_case_internal_note: ["note"],
  assess_case_nonresponse: ["target_party_role", "substantive_reasoning"],
  signoff_case_nonresponse: ["assessment_id", "substantive_reasoning"],
  propose_case_decision: [
    "expected_case_version",
    "outcome",
    "award_gross_kobo",
    "public_explanation",
    "nonresponse_assessment_id",
  ],
  approve_case_decision: ["decision_version", "expected_case_version"],
  signoff_decision_nonresponse: [
    "decision_version",
    "expected_case_version",
    "substantive_reasoning",
  ],
  finalize_case: ["decision_version", "expected_case_version"],
  request_case_appeal_evidence: [
    "appeal_id",
    "target_party_role",
    "request_kind",
    "prompt",
  ],
  respond_case_appeal_evidence: ["request_number", "response"],
  close_case_appeal_evidence_nonresponse: [
    "request_number",
    "substantive_reasoning",
  ],
  review_case_appeal: [
    "appeal_id",
    "action_type",
    "public_explanation",
    "decision_version",
  ],
};
const DECISION_OUTCOMES = new Set([
  "full_worker_award",
  "full_poster_refund",
  "split",
  "no_action",
]);
const ROLES = new Set(["worker", "poster"]);
const CHANNELS = new Set(["in_app", "phone", "email", "in_person", "other"]);
const CONTACT_RESULTS = new Set([
  "no_response",
  "reached",
  "declined",
  "delivery_failed",
  "contact_unavailable",
  "other",
]);
const FINDINGS = new Set([
  "supported",
  "not_supported",
  "inconclusive",
  "needs_more_information",
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

function mapError(error, requestId) {
  if (error?.code === "42501" || error?.code === "case_access_denied")
    return fail(403, "case_access_denied", requestId);
  if (error?.code === "appeal_window_closed")
    return json(
      409,
      {
        error: { code: "appeal_window_closed" },
        next_step: "Contact case support for help.",
      },
      requestId,
    );
  if (
    [
      "decision_not_durably_notified",
      "appeal_window_open",
      "timely_appeal_unresolved",
      "appeal_evidence_request_open",
    ].includes(error?.code)
  )
    return json(
      409,
      {
        error: { code: "case_finalization_not_ready" },
        next_step: "Wait for the appeal period or required review to finish.",
      },
      requestId,
    );
  if (
    error?.code === "P0002" ||
    error?.code === "case_not_found" ||
    error?.code === "not_found"
  )
    return fail(404, "not_found", requestId);
  if (
    error?.code === "23505" ||
    error?.code === "idempotency_conflict" ||
    error?.code === "P0001" ||
    error?.code === "stale_state"
  )
    return fail(409, "stale_state", requestId);
  if (error?.code === "case_file_limit_reached")
    return fail(409, "case_file_limit_reached", requestId);
  if (error?.code === "nonresponse_contact_threshold_not_met")
    return fail(409, "contact_threshold_not_met", requestId);
  if (
    error?.code === "22023" ||
    error?.code === "invalid_case_decision" ||
    error?.code === "invalid_case_command"
  )
    return fail(400, "invalid_request", requestId);
  return fail(503, "case_command_unavailable", requestId);
}

function safeDecisionCommandResult(result, action, caseId) {
  if (!result || result.case_id !== caseId) return null;
  const amount = (value) =>
    typeof value === "string" && /^(0|[1-9][0-9]{0,8})$/.test(value);
  if (action === "signoff_decision_nonresponse") {
    return result.status === "verifying" &&
      Number.isInteger(result.case_version) &&
      result.case_version > 0 &&
      Number.isInteger(result.decision_version) &&
      result.decision_version > 0 &&
      /^[0-9a-f]{64}$/i.test(result.decision_sha256 ?? "") &&
      result.signed_off === true
      ? {
          case_id: result.case_id,
          status: result.status,
          case_version: result.case_version,
          decision_version: result.decision_version,
          decision_sha256: result.decision_sha256,
          signed_off: true,
        }
      : null;
  }
  if (
    !["verifying", "decision_made"].includes(result.status) ||
    !Number.isInteger(result.case_version) ||
    result.case_version < 1 ||
    !Number.isInteger(result.decision_version) ||
    result.decision_version < 1 ||
    !DECISION_OUTCOMES.has(result.outcome) ||
    !amount(result.gross_principal_kobo) ||
    !amount(result.worker_award_gross_kobo) ||
    !amount(result.poster_refund_gross_kobo) ||
    !amount(result.retained_hold_gross_kobo) ||
    !amount(result.commission_kobo) ||
    !amount(result.worker_net_kobo) ||
    !/^[0-9a-f]{64}$/i.test(result.decision_sha256 ?? "") ||
    ![1, 2].includes(result.approval_count) ||
    result.required_approvals !== 2 ||
    typeof result.approved !== "boolean" ||
    typeof result.proposed !== "boolean"
  )
    return null;
  if (
    BigInt(result.gross_principal_kobo) !==
    BigInt(result.worker_award_gross_kobo) +
      BigInt(result.poster_refund_gross_kobo) +
      BigInt(result.retained_hold_gross_kobo)
  )
    return null;
  return {
    case_id: result.case_id,
    status: result.status,
    case_version: result.case_version,
    decision_version: result.decision_version,
    outcome: result.outcome,
    gross_principal_kobo: result.gross_principal_kobo,
    worker_award_gross_kobo: result.worker_award_gross_kobo,
    poster_refund_gross_kobo: result.poster_refund_gross_kobo,
    retained_hold_gross_kobo: result.retained_hold_gross_kobo,
    commission_kobo: result.commission_kobo,
    worker_net_kobo: result.worker_net_kobo,
    decision_sha256: result.decision_sha256,
    approval_count: result.approval_count,
    required_approvals: 2,
    approved: result.approved,
    proposed: result.proposed,
  };
}

function safeFinalizationCommandResult(result, caseId) {
  const amount = (value) =>
    typeof value === "string" && /^(0|[1-9][0-9]{0,8})$/.test(value);
  if (
    !result ||
    result.case_id !== caseId ||
    result.status !== "closed" ||
    result.finalization_status !== "executed" ||
    !Number.isInteger(result.version) ||
    result.version < 1 ||
    !Number.isInteger(result.decision_version) ||
    result.decision_version < 1 ||
    !DECISION_OUTCOMES.has(result.outcome) ||
    !["authorized", "not_applicable"].includes(result.refund_status) ||
    !amount(result.gross_principal_kobo) ||
    !amount(result.worker_award_gross_kobo) ||
    !amount(result.poster_refund_gross_kobo) ||
    !amount(result.retained_hold_gross_kobo) ||
    !amount(result.commission_kobo) ||
    !amount(result.worker_net_kobo)
  )
    return null;
  const gross = BigInt(result.gross_principal_kobo);
  const award = BigInt(result.worker_award_gross_kobo);
  const refund = BigInt(result.poster_refund_gross_kobo);
  const retained = BigInt(result.retained_hold_gross_kobo);
  const commission = BigInt(result.commission_kobo);
  if (
    gross !== award + refund + retained ||
    commission !== (award === 0n ? 0n : (award * 500n + 5000n) / 10000n) ||
    BigInt(result.worker_net_kobo) !== award - commission ||
    refund > 0n !== (result.refund_status === "authorized") ||
    (result.outcome === "full_worker_award" &&
      (award !== gross || refund !== 0n || retained !== 0n)) ||
    (result.outcome === "full_poster_refund" &&
      (refund !== gross || award !== 0n || retained !== 0n)) ||
    (result.outcome === "split" &&
      (award === 0n || refund === 0n || retained !== 0n)) ||
    (result.outcome === "no_action" &&
      (award !== 0n || refund !== 0n || retained !== gross))
  )
    return null;
  return {
    case_id: caseId,
    status: "closed",
    version: result.version,
    finalization_status: "executed",
    decision_version: result.decision_version,
    outcome: result.outcome,
    gross_principal_kobo: result.gross_principal_kobo,
    worker_award_gross_kobo: result.worker_award_gross_kobo,
    poster_refund_gross_kobo: result.poster_refund_gross_kobo,
    retained_hold_gross_kobo: result.retained_hold_gross_kobo,
    commission_kobo: result.commission_kobo,
    worker_net_kobo: result.worker_net_kobo,
    refund_status: result.refund_status,
  };
}

function safeAppealCommandResult(result, action, caseId) {
  if (
    !result ||
    result.case_id !== caseId ||
    !["appeal", "verifying", "decision_made", "closed"].includes(
      result.status,
    ) ||
    !Number.isInteger(result.version) ||
    result.version < 1
  )
    return null;
  if (action === "submit_case_appeal") {
    return result.received === true
      ? {
          case_id: result.case_id,
          status: result.status,
          version: result.version,
          received: true,
        }
      : null;
  }
  if (action === "assign_appeal_reviewer") {
    return result.assigned === true
      ? {
          case_id: result.case_id,
          status: result.status,
          version: result.version,
          assigned: true,
        }
      : null;
  }
  if (action === "request_case_appeal_evidence") {
    return result.requested === true &&
      Number.isInteger(result.request_number) &&
      result.request_number >= 1 &&
      result.request_number <= 100
      ? {
          case_id: result.case_id,
          status: result.status,
          version: result.version,
          request_number: result.request_number,
          requested: true,
        }
      : null;
  }
  if (
    action === "respond_case_appeal_evidence" ||
    action === "close_case_appeal_evidence_nonresponse"
  ) {
    const field =
      action === "respond_case_appeal_evidence" ? "received" : "closed";
    return result[field] === true &&
      Number.isInteger(result.request_number) &&
      result.request_number >= 1
      ? {
          case_id: result.case_id,
          status: result.status,
          version: result.version,
          request_number: result.request_number,
          [field]: true,
        }
      : null;
  }
  if (action === "review_case_appeal") {
    return result.appeal_decided === true &&
      ["upheld", "changed"].includes(result.action) &&
      Number.isInteger(result.decision_version) &&
      result.decision_version > 0
      ? {
          case_id: result.case_id,
          status: result.status,
          version: result.version,
          appeal_decided: true,
          action: result.action,
          decision_version: result.decision_version,
        }
      : null;
  }
  return null;
}

function validActionPayload(action, value) {
  if (action === "assign_reviewer") return false;
  const fields = STAFF_ACTIONS[action];
  if (!fields || Object.keys(value).some((key) => !fields.includes(key)))
    return false;
  const text = (key, min, max) =>
    typeof value[key] === "string" &&
    value[key].trim().length >= min &&
    value[key].length <= max;
  switch (action) {
    case "triage_case":
      return (
        ["normal", "urgent"].includes(value.priority) &&
        text("rationale", 1, 500)
      );
    case "log_case_contact_attempt":
      return (
        ROLES.has(value.target_party_role) &&
        CHANNELS.has(value.channel) &&
        CONTACT_RESULTS.has(value.result) &&
        (value.result_note === undefined ||
          value.result_note === null ||
          text("result_note", 1, 500))
      );
    case "request_case_information":
      return (
        ROLES.has(value.target_party_role) &&
        ["information", "evidence"].includes(value.request_kind) &&
        text("prompt", 1, 500)
      );
    case "respond_to_case_information":
      return (
        Number.isInteger(value.request_number) &&
        value.request_number >= 1 &&
        value.request_number <= 100 &&
        text("response", 1, 2000)
      );
    case "record_case_fact":
      return (
        typeof value.fact_code === "string" &&
        /^[a-z][a-z0-9_]{1,49}$/.test(value.fact_code) &&
        FINDINGS.has(value.finding) &&
        text("staff_reasoning", 20, 2000)
      );
    case "add_case_internal_note":
      return text("note", 1, 2000);
    case "assess_case_nonresponse":
      return (
        ROLES.has(value.target_party_role) &&
        text("substantive_reasoning", 100, 2000)
      );
    case "signoff_case_nonresponse":
      return (
        UUID.test(value.assessment_id ?? "") &&
        text("substantive_reasoning", 100, 2000)
      );
    case "propose_case_decision":
      return (
        Number.isInteger(value.expected_case_version) &&
        value.expected_case_version > 0 &&
        DECISION_OUTCOMES.has(value.outcome) &&
        typeof value.award_gross_kobo === "string" &&
        /^(0|[1-9][0-9]{0,8})$/.test(value.award_gross_kobo) &&
        text("public_explanation", 20, 2000) &&
        !/(https?:\/\/|www\.|\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b)/i.test(
          value.public_explanation,
        ) &&
        (value.nonresponse_assessment_id === undefined ||
          value.nonresponse_assessment_id === null ||
          UUID.test(value.nonresponse_assessment_id))
      );
    case "approve_case_decision":
      return (
        Number.isInteger(value.decision_version) &&
        value.decision_version > 0 &&
        Number.isInteger(value.expected_case_version) &&
        value.expected_case_version > 0
      );
    case "signoff_decision_nonresponse":
      return (
        Number.isInteger(value.decision_version) &&
        value.decision_version > 0 &&
        Number.isInteger(value.expected_case_version) &&
        value.expected_case_version > 0 &&
        text("substantive_reasoning", 100, 2000)
      );
    case "finalize_case":
      return (
        Number.isInteger(value.decision_version) &&
        value.decision_version > 0 &&
        Number.isInteger(value.expected_case_version) &&
        value.expected_case_version > 0
      );
    case "request_case_appeal_evidence":
      return (
        UUID.test(value.appeal_id ?? "") &&
        ROLES.has(value.target_party_role) &&
        ["information", "evidence"].includes(value.request_kind) &&
        text("prompt", 1, 500) &&
        !/(https?:\/\/|www\.|\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b)/i.test(
          value.prompt,
        )
      );
    case "respond_case_appeal_evidence":
      return (
        Number.isInteger(value.request_number) &&
        value.request_number >= 1 &&
        value.request_number <= 100 &&
        text("response", 1, 2000)
      );
    case "close_case_appeal_evidence_nonresponse":
      return (
        Number.isInteger(value.request_number) &&
        value.request_number >= 1 &&
        value.request_number <= 100 &&
        text("substantive_reasoning", 100, 2000)
      );
    case "review_case_appeal":
      return (
        UUID.test(value.appeal_id ?? "") &&
        ["upheld", "changed"].includes(value.action_type) &&
        text("public_explanation", 20, 2000) &&
        !/(https?:\/\/|www\.|\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b)/i.test(
          value.public_explanation,
        ) &&
        (value.action_type === "upheld"
          ? value.decision_version === undefined
          : Number.isInteger(value.decision_version) &&
            value.decision_version > 1)
      );
    default:
      return false;
  }
}

export function createCaseCommandHandler({
  verifyActor,
  rpc,
  requestId = () => crypto.randomUUID(),
}) {
  if (typeof verifyActor !== "function" || typeof rpc !== "function")
    throw new Error("case command dependencies are not configured");
  return async (request) => {
    const id = requestId();
    if (request.method !== "POST") return fail(405, "method_not_allowed", id);
    const token = request.headers
      .get("authorization")
      ?.replace(/^Bearer\s+/i, "");
    if (!token) return fail(401, "authentication_required", id);
    const actor = await verifyActor(token).catch(() => null);
    const claims = claimsFrom(token);
    if (
      !actor ||
      !UUID.test(actor.id ?? "") ||
      claims?.sub !== actor.id ||
      !["aal1", "aal2"].includes(claims.aal)
    )
      return fail(401, "authentication_required", id);
    let input;
    try {
      const body = await request.text();
      if (new TextEncoder().encode(body).byteLength > MAX_BODY_BYTES)
        return fail(413, "request_too_large", id);
      input = JSON.parse(body);
    } catch {
      return fail(400, "invalid_request", id);
    }
    if (!input || typeof input !== "object" || Array.isArray(input))
      return fail(400, "invalid_request", id);
    try {
      if (
        input.action === "submit_case_appeal" &&
        Object.keys(input).every((key) =>
          ["action", "case_id", "statement", "idempotency_key"].includes(key),
        ) &&
        UUID.test(input.case_id ?? "") &&
        UUID.test(input.idempotency_key ?? "") &&
        typeof input.statement === "string" &&
        input.statement.trim().length >= 20 &&
        input.statement.length <= 2000 &&
        !/(https?:\/\/|www\.|\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b)/i.test(
          input.statement,
        )
      ) {
        const receipt = await rpc(
          "server_record_case_appeal_receipt_for_actor",
          {
            p_actor: actor.id,
            p_case_id: input.case_id,
            p_statement: input.statement.trim(),
            p_auth_aal: claims.aal,
            p_idempotency_key: input.idempotency_key,
          },
        );
        if (!UUID.test(receipt?.appeal_id ?? "") || receipt.received !== true)
          throw new Error("invalid_case_appeal_receipt");
        const result = await rpc(
          "server_process_case_appeal_receipt_for_actor",
          {
            p_actor: actor.id,
            p_appeal_id: receipt.appeal_id,
            p_auth_aal: claims.aal,
          },
        );
        const safeResult = safeAppealCommandResult(
          result,
          input.action,
          input.case_id,
        );
        if (!safeResult) throw new Error("invalid_case_appeal_projection");
        return json(200, { result: safeResult }, id);
      }
      if (
        input.action === "assign_appeal_reviewer" &&
        claims.aal === "aal2" &&
        Object.keys(input).every((key) =>
          ["action", "case_id", "reviewer_id", "idempotency_key"].includes(key),
        ) &&
        UUID.test(input.case_id ?? "") &&
        UUID.test(input.reviewer_id ?? "") &&
        UUID.test(input.idempotency_key ?? "")
      ) {
        const result = await rpc(
          "server_assign_case_appeal_reviewer_for_actor",
          {
            p_actor: actor.id,
            p_case_id: input.case_id,
            p_reviewer_id: input.reviewer_id,
            p_auth_aal: claims.aal,
            p_idempotency_key: input.idempotency_key,
          },
        );
        const safeResult = safeAppealCommandResult(
          result,
          input.action,
          input.case_id,
        );
        if (!safeResult) throw new Error("invalid_case_appeal_projection");
        return json(200, { result: safeResult }, id);
      }
      if (input.action === "assign_reviewer" && claims.aal !== "aal2")
        return fail(403, "case_access_denied", id);
      if (
        input.action === "assign_reviewer" &&
        claims.aal === "aal2" &&
        Object.keys(input).every((key) =>
          ["action", "case_id", "reviewer_id", "idempotency_key"].includes(key),
        ) &&
        UUID.test(input.case_id ?? "") &&
        UUID.test(input.reviewer_id ?? "") &&
        UUID.test(input.idempotency_key ?? "")
      ) {
        const result = await rpc("server_assign_case_reviewer_for_actor", {
          p_actor: actor.id,
          p_case_id: input.case_id,
          p_reviewer_id: input.reviewer_id,
          p_auth_aal: claims.aal,
          p_idempotency_key: input.idempotency_key,
        });
        if (
          !result ||
          result.case_id !== input.case_id ||
          result.status !== "under_review" ||
          !Number.isInteger(result.version) ||
          result.version < 1 ||
          result.assigned !== true
        )
          throw new Error("invalid_case_command_projection");
        return json(200, { result }, id);
      }
      const fields = STAFF_ACTIONS[input.action];
      if (
        !fields ||
        !UUID.test(input.case_id ?? "") ||
        !UUID.test(input.idempotency_key ?? "") ||
        Object.keys(input).some(
          (key) =>
            !["action", "case_id", "idempotency_key", ...fields].includes(key),
        ) ||
        !validActionPayload(
          input.action,
          Object.fromEntries(
            Object.entries(input).filter(([key]) => fields.includes(key)),
          ),
        )
      )
        return fail(400, "invalid_request", id);
      if (
        input.action !== "respond_to_case_information" &&
        input.action !== "respond_case_appeal_evidence" &&
        claims.aal !== "aal2"
      )
        return fail(403, "case_access_denied", id);
      const payload = Object.fromEntries(
        Object.entries(input).filter(([key]) => fields.includes(key)),
      );
      if (
        [
          "request_case_appeal_evidence",
          "respond_case_appeal_evidence",
          "close_case_appeal_evidence_nonresponse",
          "review_case_appeal",
        ].includes(input.action)
      ) {
        const appealPayload =
          input.action === "review_case_appeal"
            ? {
                appeal_id: payload.appeal_id,
                action: payload.action_type,
                public_explanation: payload.public_explanation.trim(),
                ...(payload.decision_version !== undefined
                  ? { decision_version: payload.decision_version }
                  : {}),
              }
            : payload;
        const result = await rpc("server_case_appeal_command_for_actor", {
          p_actor: actor.id,
          p_case_id: input.case_id,
          p_action: input.action,
          p_payload: appealPayload,
          p_auth_aal: claims.aal,
          p_idempotency_key: input.idempotency_key,
        });
        const safeResult = safeAppealCommandResult(
          result,
          input.action,
          input.case_id,
        );
        if (!safeResult) throw new Error("invalid_case_appeal_projection");
        return json(200, { result: safeResult }, id);
      }
      if (
        [
          "propose_case_decision",
          "approve_case_decision",
          "signoff_decision_nonresponse",
          "finalize_case",
        ].includes(input.action)
      ) {
        if (claims.aal !== "aal2") return fail(403, "case_access_denied", id);
        let result;
        if (input.action === "finalize_case") {
          result = await rpc("server_finalize_case_for_actor", {
            p_actor: actor.id,
            p_case_id: input.case_id,
            p_decision_version: payload.decision_version,
            p_expected_case_version: payload.expected_case_version,
            p_auth_aal: claims.aal,
            p_idempotency_key: input.idempotency_key,
          });
          const safeResult = safeFinalizationCommandResult(
            result,
            input.case_id,
          );
          if (!safeResult)
            throw new Error("invalid_case_finalization_projection");
          return json(200, { result: safeResult }, id);
        } else if (input.action === "propose_case_decision") {
          result = await rpc("server_propose_case_decision_for_actor", {
            p_actor: actor.id,
            p_case_id: input.case_id,
            p_expected_case_version: payload.expected_case_version,
            p_payload: {
              outcome: payload.outcome,
              award_gross_kobo: payload.award_gross_kobo,
              public_explanation: payload.public_explanation.trim(),
              ...(payload.nonresponse_assessment_id !== undefined
                ? {
                    nonresponse_assessment_id:
                      payload.nonresponse_assessment_id,
                  }
                : {}),
            },
            p_auth_aal: claims.aal,
            p_idempotency_key: input.idempotency_key,
          });
        } else if (input.action === "approve_case_decision") {
          result = await rpc("server_approve_case_decision_for_actor", {
            p_actor: actor.id,
            p_case_id: input.case_id,
            p_decision_version: payload.decision_version,
            p_expected_case_version: payload.expected_case_version,
            p_auth_aal: claims.aal,
            p_idempotency_key: input.idempotency_key,
          });
        } else {
          result = await rpc(
            "server_signoff_case_decision_nonresponse_for_actor",
            {
              p_actor: actor.id,
              p_case_id: input.case_id,
              p_decision_version: payload.decision_version,
              p_expected_case_version: payload.expected_case_version,
              p_substantive_reasoning: payload.substantive_reasoning.trim(),
              p_auth_aal: claims.aal,
              p_idempotency_key: input.idempotency_key,
            },
          );
        }
        const safeResult = safeDecisionCommandResult(
          result,
          input.action,
          input.case_id,
        );
        if (!safeResult) throw new Error("invalid_case_decision_projection");
        return json(200, { result: safeResult }, id);
      }
      const result = await rpc("server_case_investigation_command_for_actor", {
        p_actor: actor.id,
        p_case_id: input.case_id,
        p_action: input.action,
        p_payload: payload,
        p_auth_aal: claims.aal,
        p_idempotency_key: input.idempotency_key,
      });
      if (
        !result ||
        result.case_id !== input.case_id ||
        !["under_review", "contacting_other_party", "verifying"].includes(
          result.status,
        ) ||
        !Number.isInteger(result.version) ||
        result.version < 1
      )
        throw new Error("invalid_case_command_projection");
      return json(200, { result }, id);
    } catch (error) {
      console.error(
        "case_command_rejected",
        error?.code ?? "internal_case_command_failure",
      );
      return mapError(error, id);
    }
  };
}
