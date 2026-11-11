const UUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
const HEADERS = {
  "cache-control": "no-store",
  "content-type": "application/json; charset=utf-8",
};
const json = (status, body) =>
  new Response(JSON.stringify(body), { status, headers: HEADERS });

function actorClaims(token) {
  const part = token.split(".")[1];
  if (!part || !/^[A-Za-z0-9_-]+$/.test(part)) return null;
  try {
    const base64 = part.replaceAll("-", "+").replaceAll("_", "/");
    const claims = JSON.parse(
      atob(base64.padEnd(Math.ceil(base64.length / 4) * 4, "=")),
    );
    return { sub: claims.sub, aal: claims.aal };
  } catch {
    return null;
  }
}

export function createVerificationReviewHandler({ verifyActor, command }) {
  if (typeof verifyActor !== "function" || typeof command !== "function")
    throw new Error("verification review dependencies are not configured");
  return async (request) => {
    if (request.method !== "POST")
      return json(405, { error: "method_not_allowed" });
    const token = request.headers
      .get("authorization")
      ?.replace(/^Bearer\s+/i, "");
    if (!token) return json(401, { error: "authentication_required" });
    const verified = await verifyActor(token).catch(() => null);
    const claims = actorClaims(token);
    if (
      !verified ||
      !claims ||
      !UUID.test(verified.id ?? "") ||
      verified.id !== claims.sub
    )
      return json(401, { error: "authentication_required" });
    const actor = verified.id;
    const aal = claims.aal;
    let input;
    try {
      const body = await request.text();
      if (new TextEncoder().encode(body).byteLength > 4096)
        return json(413, { error: "request_too_large" });
      input = JSON.parse(body);
    } catch {
      return json(400, { error: "invalid_request" });
    }
    if (
      !input ||
      typeof input !== "object" ||
      Array.isArray(input) ||
      typeof input.action !== "string"
    )
      return json(400, { error: "invalid_request" });
    const calls = {
      candidates: [
        "server_list_verification_assignment_candidates_for_actor",
        { p_actor: actor, p_auth_aal: aal },
      ],
      queue: [
        "server_list_verification_queue_for_actor",
        { p_actor: actor, p_auth_aal: aal },
      ],
    };
    let call = calls[input.action];
    if (
      input.action === "assign" &&
      UUID.test(input.submission_id ?? "") &&
      UUID.test(input.target_reviewer_id ?? "") &&
      (input.expected_assignment_id == null ||
        UUID.test(input.expected_assignment_id)) &&
      typeof input.reason === "string"
    ) {
      call = [
        "server_assign_verification_for_actor",
        {
          p_actor: actor,
          p_target_reviewer: input.target_reviewer_id,
          p_submission_id: input.submission_id,
          p_expected_assignment_id: input.expected_assignment_id ?? null,
          p_reason: input.reason,
          p_auth_aal: aal,
        },
      ];
    }
    if (
      input.action === "review" &&
      UUID.test(input.submission_id ?? "") &&
      UUID.test(input.idempotency_key ?? "") &&
      Number.isInteger(input.expected_version) &&
      Number.isInteger(input.expected_decision_version) &&
      typeof input.expected_status === "string" &&
      typeof input.decision === "string" &&
      typeof input.reason === "string"
    ) {
      call = [
        "server_review_verification_for_actor",
        {
          p_actor: actor,
          p_submission_id: input.submission_id,
          p_expected_version: input.expected_version,
          p_expected_status: input.expected_status,
          p_expected_decision_version: input.expected_decision_version,
          p_decision: input.decision,
          p_reason: input.reason,
          p_idempotency_key: input.idempotency_key,
          p_auth_aal: aal,
        },
      ];
    }
    if (
      !call ||
      Object.keys(input).some(
        (key) =>
          !(
            input.action === "assign"
              ? [
                  "action",
                  "submission_id",
                  "target_reviewer_id",
                  "expected_assignment_id",
                  "reason",
                ]
              : input.action === "review"
                ? [
                    "action",
                    "submission_id",
                    "idempotency_key",
                    "expected_version",
                    "expected_status",
                    "expected_decision_version",
                    "decision",
                    "reason",
                  ]
                : ["action"]
          ).includes(key),
      )
    )
      return json(400, { error: "invalid_request" });
    try {
      const result = await command(call[0], call[1]);
      if (result?.error === "stale_state")
        return json(409, { error: "stale_state" });
      return json(200, { result });
    } catch (error) {
      if (
        ["reviewer_not_authorized", "invalid_submission"].includes(error?.code)
      )
        return json(403, { error: "review_access_denied" });
      if (error?.code === "evidence_not_ready")
        return json(409, { error: "evidence_not_ready" });
      return json(503, { error: "verification_unavailable" });
    }
  };
}
