const UUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
const PROFILE_FIELDS = new Set([
  "display_name",
  "photo_key",
  "faculty_label",
  "campus_id",
  "bio",
  "skills",
  "availability",
  "business_name",
  "business_location",
  "organisation_label",
]);
function validTimestamp(value) {
  return (
    typeof value === "string" &&
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(
      value,
    ) &&
    Number.isFinite(Date.parse(value)) &&
    value.length <= 40
  );
}

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

export function createProfileCommandHandler({
  verifyActor,
  command,
  requestId = () => crypto.randomUUID(),
}) {
  if (typeof verifyActor !== "function" || typeof command !== "function")
    throw new Error("profile command dependencies are not configured");

  return async (request) => {
    const id = requestId();
    if (request.method !== "POST")
      return json(405, { error: "method_not_allowed" }, id);
    const token = request.headers
      .get("authorization")
      ?.replace(/^Bearer\s+/i, "");
    if (!token) return json(401, { error: "authentication_required" }, id);
    const actor = await verifyActor(token).catch(() => null);
    if (!actor || !UUID.test(actor.id ?? ""))
      return json(401, { error: "authentication_required" }, id);

    let input;
    try {
      if (
        !request.headers
          .get("content-type")
          ?.toLowerCase()
          .startsWith("application/json")
      )
        return json(400, { error: "invalid_request" }, id);
      const body = await request.text();
      if (new TextEncoder().encode(body).byteLength > 8192)
        return json(413, { error: "request_too_large" }, id);
      input = JSON.parse(body);
    } catch {
      return json(400, { error: "invalid_request" }, id);
    }
    if (!input || typeof input !== "object" || Array.isArray(input))
      return json(400, { error: "invalid_request" }, id);

    let name;
    let args;
    let responseField = "profile";
    if (
      input.action === "update" &&
      Object.keys(input).every((key) => ["action", "profile"].includes(key)) &&
      input.profile &&
      typeof input.profile === "object" &&
      !Array.isArray(input.profile) &&
      Object.keys(input.profile).length > 0 &&
      Object.keys(input.profile).every((key) => PROFILE_FIELDS.has(key))
    ) {
      name = "server_update_profile_for_actor";
      args = { p_actor: actor.id, p_profile: input.profile };
    } else if (
      input.action === "view" &&
      Object.keys(input).every((key) =>
        ["action", "profile_id"].includes(key),
      ) &&
      UUID.test(input.profile_id ?? "")
    ) {
      name = "server_get_safe_profile_for_viewer";
      args = { p_viewer: actor.id, p_subject: input.profile_id };
    } else if (
      input.action === "reviews" &&
      Object.keys(input).every((key) =>
        [
          "action",
          "profile_id",
          "before_created_at",
          "before_review_id",
        ].includes(key),
      ) &&
      UUID.test(input.profile_id ?? "") &&
      ((input.before_created_at === undefined &&
        input.before_review_id === undefined) ||
        (validTimestamp(input.before_created_at) &&
          UUID.test(input.before_review_id ?? "")))
    ) {
      name = "server_list_profile_reviews_for_viewer";
      args = {
        p_viewer: actor.id,
        p_subject: input.profile_id,
        p_before_created_at: input.before_created_at ?? null,
        p_before_review_id: input.before_review_id ?? null,
      };
      responseField = "reviews";
    } else {
      return json(
        400,
        {
          error:
            input.action === "update" ? "invalid_profile" : "invalid_request",
        },
        id,
      );
    }

    try {
      const result = await command(name, args);
      if (
        result?.error === "profile_unavailable" ||
        result?.error === "profile_not_found"
      )
        return json(404, { error: "profile_not_found" }, id);
      return json(200, { [responseField]: result }, id);
    } catch (error) {
      if (error?.code === "42501")
        return json(403, { error: "profile_access_denied" }, id);
      if (["22023", "22P02", "23514"].includes(error?.code))
        return json(400, { error: "invalid_profile" }, id);
      if (
        error?.code === "P0002" ||
        error?.code === "profile_not_found" ||
        error?.code === "profile_unavailable"
      )
        return json(404, { error: "profile_not_found" }, id);
      return json(503, { error: "profile_service_unavailable" }, id);
    }
  };
}
