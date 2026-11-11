const UUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
const SEQUENCE = /^(0|[1-9][0-9]{0,18})$/;
const MAX_SEQUENCE = 9223372036854775807n;
const MAX_BODY_BYTES = 32 * 1024;

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

const ERROR_MESSAGES = {
  authentication_required: "Sign in to continue.",
  permission_denied: "You do not have permission to do that.",
  not_found: "This item could not be found.",
  invalid_request: "Check the request and try again.",
  request_too_large: "The request is too large.",
  stale_state: "This item changed. Refresh and try again.",
  assignment_on_hold:
    "This assignment is on hold while the report is reviewed.",
  slot_unavailable: "This job no longer has an available place.",
  application_already_exists: "You have already applied to this job.",
  review_not_eligible: "This assignment is not eligible for a review yet.",
  review_already_submitted: "You have already reviewed this assignment.",
  invalid_review_text: "Review text does not meet the allowed content rules.",
  verification_required: "Your account is not currently eligible for this.",
  idempotency_conflict:
    "This request key was already used with different information.",
  service_unavailable:
    "This service is temporarily unavailable. Try again later.",
};

function fail(status, code, requestId) {
  return json(
    status,
    {
      error: {
        code,
        message: ERROR_MESSAGES[code] ?? ERROR_MESSAGES.service_unavailable,
      },
    },
    requestId,
  );
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function errorResponse(error, requestId) {
  if (error?.message === "review_not_eligible")
    return fail(409, "review_not_eligible", requestId);
  if (error?.message === "review_already_submitted")
    return fail(409, "review_already_submitted", requestId);
  if (error?.message === "invalid_review_text")
    return fail(400, "invalid_review_text", requestId);
  if (error?.message === "assignment_on_hold")
    return fail(409, "assignment_on_hold", requestId);
  if (error?.message === "slot_unavailable")
    return fail(409, "slot_unavailable", requestId);
  if (error?.message === "application_already_exists")
    return fail(409, "application_already_exists", requestId);
  if (error?.message === "verification_required")
    return fail(403, "verification_required", requestId);
  if (error?.message === "self_application_not_allowed")
    return fail(403, "permission_denied", requestId);
  if (error?.code === "42501" || error?.message === "marketplace_access_denied")
    return fail(403, "permission_denied", requestId);
  if (error?.message === "job_not_found" || error?.code === "P0002")
    return fail(404, "not_found", requestId);
  if (error?.message === "stale_state" || error?.code === "P0001")
    return fail(409, "stale_state", requestId);
  if (error?.message === "idempotency_conflict" || error?.code === "23505")
    return fail(409, "idempotency_conflict", requestId);
  if (["22023", "23514", "22P02"].includes(error?.code))
    return fail(400, "invalid_request", requestId);
  return fail(503, "service_unavailable", requestId);
}

function hasOnlyKeys(input, keys) {
  return Object.keys(input).every((key) => keys.has(key));
}

export function createMarketplaceCommandHandler({
  verifyActor,
  rpc,
  paymentAdapter,
  requestId = () => crypto.randomUUID(),
}) {
  if (typeof verifyActor !== "function" || typeof rpc !== "function")
    throw new Error("marketplace command dependencies are not configured");

  return async (request) => {
    const id = requestId();
    if (request.method !== "POST") return fail(405, "invalid_request", id);
    const token = request.headers
      .get("authorization")
      ?.replace(/^Bearer\s+/i, "");
    if (!token) return fail(401, "authentication_required", id);
    const actor = await verifyActor(token).catch(() => null);
    if (!actor || !UUID.test(actor.id ?? ""))
      return fail(401, "authentication_required", id);

    let input;
    try {
      if (
        !request.headers
          .get("content-type")
          ?.toLowerCase()
          .startsWith("application/json")
      )
        return fail(400, "invalid_request", id);
      const body = await request.text();
      if (new TextEncoder().encode(body).byteLength > MAX_BODY_BYTES)
        return fail(413, "request_too_large", id);
      input = JSON.parse(body);
    } catch {
      return fail(400, "invalid_request", id);
    }
    if (!isObject(input)) return fail(400, "invalid_request", id);

    try {
      if (
        input.action === "create_job_draft" &&
        hasOnlyKeys(input, new Set(["action", "terms", "idempotency_key"])) &&
        isObject(input.terms) &&
        UUID.test(input.idempotency_key ?? "")
      ) {
        const job = await rpc("server_create_job_draft_for_actor", {
          p_actor: actor.id,
          p_terms: input.terms,
          p_idempotency_key: input.idempotency_key,
        });
        return json(201, { job }, id);
      }

      if (
        input.action === "update_job_draft" &&
        hasOnlyKeys(
          input,
          new Set([
            "action",
            "job_id",
            "expected_terms_version",
            "terms",
            "idempotency_key",
          ]),
        ) &&
        UUID.test(input.job_id ?? "") &&
        Number.isInteger(input.expected_terms_version) &&
        input.expected_terms_version > 0 &&
        isObject(input.terms) &&
        UUID.test(input.idempotency_key ?? "")
      ) {
        const job = await rpc("server_update_job_draft_for_actor", {
          p_actor: actor.id,
          p_job_id: input.job_id,
          p_expected_terms_version: input.expected_terms_version,
          p_terms: input.terms,
          p_idempotency_key: input.idempotency_key,
        });
        return json(200, { job }, id);
      }

      if (
        input.action === "apply_to_job" &&
        hasOnlyKeys(
          input,
          new Set(["action", "job_id", "note", "idempotency_key"]),
        ) &&
        UUID.test(input.job_id ?? "") &&
        (input.note === undefined ||
          (typeof input.note === "string" && input.note.length <= 500)) &&
        UUID.test(input.idempotency_key ?? "")
      ) {
        const application = await rpc("server_apply_to_job_for_actor", {
          p_actor: actor.id,
          p_job_id: input.job_id,
          p_note: input.note?.trim() || null,
          p_idempotency_key: input.idempotency_key,
        });
        return json(201, { application }, id);
      }

      if (
        input.action === "accept_application" &&
        hasOnlyKeys(
          input,
          new Set(["action", "application_id", "idempotency_key"]),
        ) &&
        UUID.test(input.application_id ?? "") &&
        UUID.test(input.idempotency_key ?? "")
      ) {
        const assignment = await rpc("server_accept_application_for_actor", {
          p_actor: actor.id,
          p_application_id: input.application_id,
          p_idempotency_key: input.idempotency_key,
        });
        return json(200, { assignment }, id);
      }

      if (
        [
          "start_assignment",
          "submit_assignment",
          "confirm_completion",
        ].includes(input.action) &&
        hasOnlyKeys(
          input,
          new Set(["action", "assignment_id", "idempotency_key"]),
        ) &&
        UUID.test(input.assignment_id ?? "") &&
        UUID.test(input.idempotency_key ?? "")
      ) {
        const rpcName = {
          start_assignment: "server_start_assignment_for_actor",
          submit_assignment: "server_submit_assignment_for_actor",
          confirm_completion: "server_confirm_completion_for_actor",
        }[input.action];
        const assignment = await rpc(rpcName, {
          p_actor: actor.id,
          p_assignment_id: input.assignment_id,
          p_idempotency_key: input.idempotency_key,
        });
        return json(200, { assignment }, id);
      }

      if (
        input.action === "open_assignment_hold" &&
        hasOnlyKeys(
          input,
          new Set([
            "action",
            "assignment_id",
            "reason_code",
            "narrative",
            "desired_outcome",
            "follow_up",
            "idempotency_key",
          ]),
        ) &&
        UUID.test(input.assignment_id ?? "") &&
        new Set([
          "payment_not_released",
          "incomplete_work",
          "work_not_as_described",
          "unresponsive_no_show",
          "conduct_safety",
          "other",
        ]).has(input.reason_code) &&
        typeof input.narrative === "string" &&
        input.narrative.trim().length >= 1 &&
        input.narrative.length <= 2000 &&
        typeof input.desired_outcome === "string" &&
        input.desired_outcome.trim().length >= 1 &&
        input.desired_outcome.length <= 500 &&
        (input.follow_up === undefined ||
          (typeof input.follow_up === "string" &&
            input.follow_up.trim().length <= 500)) &&
        UUID.test(input.idempotency_key ?? "")
      ) {
        const result = await rpc("server_open_assignment_hold_for_actor", {
          p_actor: actor.id,
          p_assignment_id: input.assignment_id,
          p_reason_code: input.reason_code,
          p_narrative: input.narrative.trim(),
          p_desired_outcome: input.desired_outcome.trim(),
          p_follow_up: input.follow_up?.trim() || null,
          p_idempotency_key: input.idempotency_key,
        });
        return json(201, result, id);
      }

      if (
        input.action === "reject_application" &&
        hasOnlyKeys(
          input,
          new Set(["action", "application_id", "idempotency_key"]),
        ) &&
        UUID.test(input.application_id ?? "") &&
        UUID.test(input.idempotency_key ?? "")
      ) {
        const application = await rpc("server_reject_application_for_actor", {
          p_actor: actor.id,
          p_application_id: input.application_id,
          p_idempotency_key: input.idempotency_key,
        });
        return json(200, { application }, id);
      }

      if (
        input.action === "withdraw_application" &&
        hasOnlyKeys(
          input,
          new Set(["action", "application_id", "idempotency_key"]),
        ) &&
        UUID.test(input.application_id ?? "") &&
        UUID.test(input.idempotency_key ?? "")
      ) {
        const application = await rpc("server_withdraw_application_for_actor", {
          p_actor: actor.id,
          p_application_id: input.application_id,
          p_idempotency_key: input.idempotency_key,
        });
        return json(200, { application }, id);
      }

      if (
        input.action === "send_application_message" &&
        hasOnlyKeys(
          input,
          new Set(["action", "thread_id", "client_message_id", "body"]),
        ) &&
        UUID.test(input.thread_id ?? "") &&
        UUID.test(input.client_message_id ?? "") &&
        typeof input.body === "string" &&
        input.body.trim().length > 0 &&
        input.body.length <= 2000
      ) {
        const message = await rpc("server_send_application_message_for_actor", {
          p_actor: actor.id,
          p_thread_id: input.thread_id,
          p_client_message_id: input.client_message_id,
          p_body: input.body.trim(),
        });
        return json(201, { message }, id);
      }

      if (
        input.action === "mark_thread_read" &&
        hasOnlyKeys(
          input,
          new Set(["action", "thread_id", "last_read_sequence"]),
        ) &&
        UUID.test(input.thread_id ?? "") &&
        typeof input.last_read_sequence === "string" &&
        SEQUENCE.test(input.last_read_sequence) &&
        BigInt(input.last_read_sequence) <= MAX_SEQUENCE
      ) {
        const threadRead = await rpc(
          "server_mark_application_thread_read_for_actor",
          {
            p_actor: actor.id,
            p_thread_id: input.thread_id,
            p_last_read_sequence: input.last_read_sequence,
          },
        );
        return json(200, { thread_read: threadRead }, id);
      }

      if (
        input.action === "submit_review" &&
        hasOnlyKeys(
          input,
          new Set([
            "action",
            "assignment_id",
            "rating",
            "review_text",
            "idempotency_key",
          ]),
        ) &&
        UUID.test(input.assignment_id ?? "") &&
        Number.isInteger(input.rating) &&
        input.rating >= 1 &&
        input.rating <= 5 &&
        (input.review_text === undefined ||
          (typeof input.review_text === "string" &&
            Array.from(input.review_text).length <= 500)) &&
        UUID.test(input.idempotency_key ?? "")
      ) {
        const result = await rpc("server_submit_assignment_review_for_actor", {
          p_actor: actor.id,
          p_assignment_id: input.assignment_id,
          p_rating: input.rating,
          p_review_text: input.review_text?.trim() || null,
          p_idempotency_key: input.idempotency_key,
        });
        return json(result?.replayed ? 200 : 201, result, id);
      }

      if (
        input.action === "report_review" &&
        hasOnlyKeys(input, new Set(["action", "review_id"])) &&
        UUID.test(input.review_id ?? "")
      ) {
        const result = await rpc("server_report_assignment_review_for_actor", {
          p_actor: actor.id,
          p_review_id: input.review_id,
        });
        return json(200, result, id);
      }

      if (
        input.action === "fund_job" &&
        hasOnlyKeys(
          input,
          new Set([
            "action",
            "job_id",
            "expected_terms_version",
            "idempotency_key",
          ]),
        ) &&
        UUID.test(input.job_id ?? "") &&
        Number.isInteger(input.expected_terms_version) &&
        input.expected_terms_version > 0 &&
        UUID.test(input.idempotency_key ?? "")
      ) {
        if (typeof paymentAdapter?.initializeCollection !== "function")
          return fail(503, "service_unavailable", id);
        const funding = await rpc("server_start_job_funding_for_actor", {
          p_actor: actor.id,
          p_job_id: input.job_id,
          p_expected_terms_version: input.expected_terms_version,
          p_idempotency_key: input.idempotency_key,
        });
        let providerReference = funding.provider_reference ?? null;
        let status = funding.status ?? "pending";

        if (["pending", "unknown"].includes(status)) {
          try {
            let operation = await paymentAdapter.lookupOriginalOperation({
              operationId: funding.operation_id,
              idempotencyKey: funding.provider_idempotency_key,
              reference: providerReference,
            });
            if (!operation) {
              operation = await paymentAdapter.initializeCollection({
                operationId: funding.operation_id,
                idempotencyKey: funding.provider_idempotency_key,
                amountKobo: funding.amount_kobo,
                currency: funding.currency,
                merchantIdentity: funding.merchant_identity,
              });
            }
            providerReference = operation.reference;
            const saved = await rpc(
              "server_record_job_funding_initialization",
              {
                p_operation_id: funding.operation_id,
                p_provider_reference: providerReference,
              },
            );
            providerReference = saved.provider_reference ?? providerReference;
            status = saved.status ?? status;
            if (operation.status === "unknown") {
              const recovered = await rpc(
                "server_record_job_funding_unknown_for_actor",
                { p_actor: actor.id, p_operation_id: funding.operation_id },
              );
              status = recovered.status ?? "unknown";
              providerReference =
                recovered.provider_reference ?? providerReference;
            }
          } catch {
            const recovered = await rpc(
              "server_record_job_funding_unknown_for_actor",
              { p_actor: actor.id, p_operation_id: funding.operation_id },
            );
            status = recovered.status ?? "unknown";
            providerReference = recovered.provider_reference ?? null;
          }
        }

        return json(
          ["pending", "unknown"].includes(status) ? 202 : 200,
          {
            funding_intent_id: funding.funding_intent_id,
            job_id: funding.job_id,
            listing_state: funding.listing_state ?? "awaiting_payment",
            status,
            expected_gross_kobo: funding.amount_kobo,
            currency: funding.currency,
            provider_reference: providerReference,
          },
          id,
        );
      }

      if (
        input.action === "funding_status" &&
        hasOnlyKeys(input, new Set(["action", "job_id"])) &&
        UUID.test(input.job_id ?? "")
      ) {
        const status = await rpc("server_get_job_funding_status_for_actor", {
          p_actor: actor.id,
          p_job_id: input.job_id,
        });
        return json(200, { funding: status }, id);
      }

      if (
        input.action === "cancel_unassigned_slots" &&
        hasOnlyKeys(
          input,
          new Set([
            "action",
            "job_id",
            "allocation_ids",
            "reason",
            "idempotency_key",
          ]),
        ) &&
        UUID.test(input.job_id ?? "") &&
        Array.isArray(input.allocation_ids) &&
        input.allocation_ids.length >= 1 &&
        input.allocation_ids.length <= 10 &&
        input.allocation_ids.every((value) => UUID.test(value ?? "")) &&
        new Set(input.allocation_ids).size === input.allocation_ids.length &&
        typeof input.reason === "string" &&
        input.reason.trim().length >= 1 &&
        input.reason.length <= 500 &&
        UUID.test(input.idempotency_key ?? "")
      ) {
        const result = await rpc("server_cancel_unassigned_slots_for_actor", {
          p_actor: actor.id,
          p_job_id: input.job_id,
          p_allocation_ids: input.allocation_ids,
          p_reason: input.reason.trim(),
          p_idempotency_key: input.idempotency_key,
        });
        return json(200, { results: result.results ?? result }, id);
      }

      if (
        input.action === "request_prestart_cancellation" &&
        hasOnlyKeys(
          input,
          new Set(["action", "assignment_id", "reason", "idempotency_key"]),
        ) &&
        UUID.test(input.assignment_id ?? "") &&
        typeof input.reason === "string" &&
        input.reason.trim().length >= 1 &&
        input.reason.length <= 500 &&
        UUID.test(input.idempotency_key ?? "")
      ) {
        const cancellation = await rpc(
          "server_request_prestart_cancellation_for_actor",
          {
            p_actor: actor.id,
            p_assignment_id: input.assignment_id,
            p_reason: input.reason.trim(),
            p_idempotency_key: input.idempotency_key,
          },
        );
        return json(200, { cancellation }, id);
      }

      if (
        input.action === "consent_prestart_cancellation" &&
        hasOnlyKeys(
          input,
          new Set([
            "action",
            "cancellation_id",
            "cancellation_version",
            "reason",
            "idempotency_key",
          ]),
        ) &&
        UUID.test(input.cancellation_id ?? "") &&
        Number.isInteger(input.cancellation_version) &&
        input.cancellation_version > 0 &&
        typeof input.reason === "string" &&
        input.reason.trim().length >= 1 &&
        input.reason.length <= 500 &&
        UUID.test(input.idempotency_key ?? "")
      ) {
        const cancellation = await rpc(
          "server_consent_prestart_cancellation_for_actor",
          {
            p_actor: actor.id,
            p_cancellation_id: input.cancellation_id,
            p_cancellation_version: input.cancellation_version,
            p_reason: input.reason.trim(),
            p_idempotency_key: input.idempotency_key,
          },
        );
        return json(200, { cancellation }, id);
      }

      if (
        input.action === "abandon_prestart_assignment" &&
        hasOnlyKeys(
          input,
          new Set(["action", "assignment_id", "reason", "idempotency_key"]),
        ) &&
        UUID.test(input.assignment_id ?? "") &&
        typeof input.reason === "string" &&
        input.reason.trim().length >= 1 &&
        input.reason.length <= 500 &&
        UUID.test(input.idempotency_key ?? "")
      ) {
        const result = await rpc(
          "server_abandon_prestart_assignment_for_actor",
          {
            p_actor: actor.id,
            p_assignment_id: input.assignment_id,
            p_reason: input.reason.trim(),
            p_idempotency_key: input.idempotency_key,
          },
        );
        return json(200, result, id);
      }

      return fail(400, "invalid_request", id);
    } catch (error) {
      return errorResponse(error, id);
    }
  };
}
