const UUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
const RFC3339 =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$/i;
const AMOUNT = /^(0|[1-9][0-9]{0,17})$/;
const SEQUENCE = /^(0|[1-9][0-9]{0,18})$/;
const MAX_SEQUENCE = 9223372036854775807n;
const PAGE_SIZE = 20;
const MESSAGE_PAGE_SIZE = 50;
const MAX_BODY_BYTES = 32 * 1024;
const ASSIGNMENT_STATES = new Set([
  "assigned",
  "in_progress",
  "submitted",
  "completed",
  "cancelled",
]);
const HOLD_REASONS = new Set([
  "payment_not_released",
  "incomplete_work",
  "work_not_as_described",
  "unresponsive_no_show",
  "conduct_safety",
  "other",
]);
const FILTER_KEYS = new Set([
  "keyword",
  "location",
  "category_slug",
  "min_gross_kobo",
  "max_gross_kobo",
  "location_type",
  "needed_by_from",
  "needed_by_to",
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

const MESSAGES = {
  authentication_required: "Sign in to continue.",
  verification_required: "Your account is not currently eligible for this.",
  permission_denied: "You do not have permission to view this item.",
  not_found: "This item could not be found.",
  invalid_request: "Check the request and try again.",
  request_too_large: "The request is too large.",
  service_unavailable:
    "This service is temporarily unavailable. Try again later.",
};

function fail(status, code, requestId) {
  return json(
    status,
    {
      error: { code, message: MESSAGES[code] ?? MESSAGES.service_unavailable },
    },
    requestId,
  );
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function onlyKeys(value, allowed) {
  return Object.keys(value).every((key) => allowed.has(key));
}

function stableJson(value) {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(",")}]`;
  if (isObject(value))
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${stableJson(value[key])}`)
      .join(",")}}`;
  return JSON.stringify(value);
}

function isTimestamp(value) {
  return (
    typeof value === "string" &&
    RFC3339.test(value) &&
    Number.isFinite(Date.parse(value))
  );
}

function normalizeFilters(input) {
  if (!isObject(input) || !onlyKeys(input, FILTER_KEYS)) return null;
  const filters = {};
  if (Object.hasOwn(input, "keyword")) {
    if (typeof input.keyword !== "string") return null;
    const keyword = input.keyword.trim().replace(/\s+/g, " ");
    if (keyword.length > 100) return null;
    if (keyword) filters.keyword = keyword;
  }
  if (Object.hasOwn(input, "location")) {
    if (typeof input.location !== "string") return null;
    const location = input.location.trim().replace(/\s+/g, " ");
    if (location.length > 100) return null;
    if (location) filters.location = location;
  }
  if (Object.hasOwn(input, "category_slug")) {
    if (
      typeof input.category_slug !== "string" ||
      !/^[a-z0-9]+(?:-[a-z0-9]+){0,7}$/.test(input.category_slug)
    )
      return null;
    filters.category_slug = input.category_slug;
  }
  for (const key of ["min_gross_kobo", "max_gross_kobo"]) {
    if (Object.hasOwn(input, key)) {
      if (
        typeof input[key] !== "string" ||
        !AMOUNT.test(input[key]) ||
        BigInt(input[key]) > 100_000_000n
      )
        return null;
      filters[key] = input[key];
    }
  }
  if (
    filters.min_gross_kobo !== undefined &&
    filters.max_gross_kobo !== undefined &&
    BigInt(filters.min_gross_kobo) > BigInt(filters.max_gross_kobo)
  )
    return null;
  if (Object.hasOwn(input, "location_type")) {
    if (!new Set(["on_campus", "remote", "hybrid"]).has(input.location_type))
      return null;
    filters.location_type = input.location_type;
  }
  for (const key of ["needed_by_from", "needed_by_to"]) {
    if (Object.hasOwn(input, key)) {
      if (!isTimestamp(input[key])) return null;
      filters[key] = new Date(input[key]).toISOString();
    }
  }
  if (
    filters.needed_by_from &&
    filters.needed_by_to &&
    Date.parse(filters.needed_by_from) > Date.parse(filters.needed_by_to)
  )
    return null;
  return filters;
}

function encodeCursor(value) {
  const bytes = new TextEncoder().encode(JSON.stringify(value));
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function decodeCursor(
  cursor,
  kind,
  filters,
  { timeField = "created_at", idField = "job_id" } = {},
) {
  if (
    typeof cursor !== "string" ||
    cursor.length > 2048 ||
    !/^[A-Za-z0-9_-]+$/.test(cursor)
  )
    return null;
  try {
    const binary = atob(cursor.replace(/-/g, "+").replace(/_/g, "/"));
    const bytes = Uint8Array.from(binary, (character) =>
      character.charCodeAt(0),
    );
    const value = JSON.parse(new TextDecoder().decode(bytes));
    if (
      !isObject(value) ||
      !onlyKeys(value, new Set(["v", "kind", "filters", timeField, idField])) ||
      value.v !== 1 ||
      value.kind !== kind ||
      !isObject(value.filters) ||
      stableJson(value.filters) !== stableJson(filters) ||
      !isTimestamp(value[timeField]) ||
      !UUID.test(value[idField] ?? "")
    )
      return null;
    return {
      [timeField]: new Date(value[timeField]).toISOString(),
      [idField]: value[idField],
    };
  } catch {
    return null;
  }
}

function safePoster(value) {
  if (!isObject(value)) return null;
  return {
    display_name:
      typeof value.display_name === "string"
        ? value.display_name.slice(0, 60)
        : null,
    account_type: ["student", "partner"].includes(value.account_type)
      ? value.account_type
      : null,
  };
}

function amount(value) {
  if (typeof value !== "string" || !AMOUNT.test(value))
    throw new Error("invalid_marketplace_read_projection");
  return value;
}

function safeSummary(row, { history = false } = {}) {
  if (
    !isObject(row) ||
    !UUID.test(row.job_id ?? "") ||
    !isTimestamp(row.created_at) ||
    !Number.isInteger(row.slots_remaining) ||
    row.slots_remaining < 0 ||
    row.slots_remaining > 10 ||
    !Number.isInteger(row.terms_version) ||
    row.terms_version < 1
  )
    throw new Error("invalid_marketplace_read_projection");
  const result = {
    job_id: row.job_id,
    created_at: new Date(row.created_at).toISOString(),
    title: typeof row.title === "string" ? row.title : "",
    description_excerpt:
      typeof row.description_excerpt === "string"
        ? row.description_excerpt
        : "",
    category_slug:
      typeof row.category_slug === "string" ? row.category_slug : "",
    category_label:
      typeof row.category_label === "string" ? row.category_label : "",
    location_type: row.location_type,
    location_detail:
      typeof row.location_detail === "string" ? row.location_detail : null,
    gross_per_worker_kobo: amount(row.gross_per_worker_kobo),
    commission_kobo: amount(row.commission_kobo),
    worker_net_kobo: amount(row.worker_net_kobo),
    slots_remaining: row.slots_remaining,
    terms_version: row.terms_version,
    poster_summary: safePoster(row.poster_summary),
  };
  if (history) {
    if (!new Set(["open", "expired", "filled"]).has(row.history_state))
      throw new Error("invalid_marketplace_read_projection");
    result.history_state = row.history_state;
  }
  return result;
}

function safeDetail(row, { history = false } = {}) {
  const summary = safeSummary(row, { history });
  return {
    ...summary,
    description: typeof row.description === "string" ? row.description : "",
    application_deadline_at: isTimestamp(row.application_deadline_at)
      ? new Date(row.application_deadline_at).toISOString()
      : null,
    needed_by_at: isTimestamp(row.needed_by_at)
      ? new Date(row.needed_by_at).toISOString()
      : null,
    start_requirements:
      typeof row.start_requirements === "string" ? row.start_requirements : "",
    application_note:
      typeof row.application_note === "string" ? row.application_note : "",
  };
}

const APPLICATION_STATES = new Set([
  "applied",
  "accepted",
  "rejected",
  "withdrawn",
  "closed",
]);

function sequence(value) {
  if (
    typeof value !== "string" ||
    !SEQUENCE.test(value) ||
    BigInt(value) > MAX_SEQUENCE
  )
    throw new Error("invalid_marketplace_read_projection");
  return value;
}

function safeApplication(row, { owner }) {
  if (
    !isObject(row) ||
    !UUID.test(row.application_id ?? "") ||
    !UUID.test(row.thread_id ?? "") ||
    !UUID.test(row.job_id ?? "") ||
    !APPLICATION_STATES.has(row.state) ||
    !Number.isInteger(row.terms_version) ||
    row.terms_version < 1 ||
    !isTimestamp(row.applied_at) ||
    (row.note !== null &&
      (typeof row.note !== "string" || row.note.length > 500))
  )
    throw new Error("invalid_marketplace_read_projection");
  const result = {
    application_id: row.application_id,
    thread_id: row.thread_id,
    job_id: row.job_id,
    state: row.state,
    note: row.note,
    terms_version: row.terms_version,
    applied_at: new Date(row.applied_at).toISOString(),
    assignment_id: UUID.test(row.assignment_id ?? "")
      ? row.assignment_id
      : null,
  };
  if (owner) {
    result.applicant_summary = safePoster(row.applicant_summary);
  } else {
    result.job_title = typeof row.job_title === "string" ? row.job_title : "";
    result.gross_per_worker_kobo = amount(row.gross_per_worker_kobo);
    result.poster_summary = safePoster(row.poster_summary);
  }
  return result;
}

function safeApplicationThread(row) {
  if (
    !isObject(row) ||
    !UUID.test(row.application_id ?? "") ||
    !UUID.test(row.thread_id ?? "") ||
    !UUID.test(row.job_id ?? "") ||
    !APPLICATION_STATES.has(row.application_state) ||
    !new Set(["open", "read_only"]).has(row.thread_state) ||
    !Number.isInteger(row.terms_version) ||
    row.terms_version < 1 ||
    !isTimestamp(row.applied_at) ||
    !Array.isArray(row.messages) ||
    row.messages.length > MESSAGE_PAGE_SIZE + 1 ||
    (row.note !== null &&
      (typeof row.note !== "string" || row.note.length > 500))
  )
    throw new Error("invalid_marketplace_read_projection");

  const lastSequence = sequence(row.last_sequence);
  const readCursor = sequence(row.read_cursor);
  const unreadCount = sequence(row.unread_count);
  let previous = 0n;
  const messages = row.messages.map((message) => {
    if (
      !isObject(message) ||
      !UUID.test(message.message_id ?? "") ||
      !UUID.test(message.client_message_id ?? "") ||
      typeof message.sender_is_me !== "boolean" ||
      typeof message.body !== "string" ||
      message.body.length < 1 ||
      message.body.length > 2000 ||
      !isTimestamp(message.created_at)
    )
      throw new Error("invalid_marketplace_read_projection");
    const messageSequence = sequence(message.sequence);
    const numericSequence = BigInt(messageSequence);
    if (numericSequence <= previous || numericSequence > BigInt(lastSequence))
      throw new Error("invalid_marketplace_read_projection");
    previous = numericSequence;
    return {
      message_id: message.message_id,
      client_message_id: message.client_message_id,
      sequence: messageSequence,
      sender_is_me: message.sender_is_me,
      body: message.body,
      created_at: new Date(message.created_at).toISOString(),
    };
  });
  const visibleMessages = messages.slice(0, MESSAGE_PAGE_SIZE);
  return {
    thread: {
      application_id: row.application_id,
      thread_id: row.thread_id,
      job_id: row.job_id,
      job_title: typeof row.job_title === "string" ? row.job_title : "",
      application_state: row.application_state,
      thread_state: row.thread_state,
      terms_version: row.terms_version,
      note: row.note,
      applied_at: new Date(row.applied_at).toISOString(),
      assignment_id: UUID.test(row.assignment_id ?? "")
        ? row.assignment_id
        : null,
      assignment_state: row.assignment_state ?? null,
      gross_per_worker_kobo: amount(row.gross_per_worker_kobo),
      other_party: safePoster(row.other_party),
      last_sequence: lastSequence,
      read_cursor: readCursor,
      unread_count: unreadCount,
      messages: visibleMessages,
    },
    next_after_sequence:
      messages.length > MESSAGE_PAGE_SIZE
        ? (visibleMessages.at(-1)?.sequence ?? null)
        : null,
  };
}

function safeAssignmentStatus(row) {
  if (!isObject(row) || !isObject(row.assignment))
    throw new Error("invalid_assignment_status_projection");
  const assignment = row.assignment;
  if (
    !UUID.test(assignment.assignment_id ?? "") ||
    !UUID.test(assignment.application_id ?? "") ||
    !UUID.test(assignment.thread_id ?? "") ||
    !UUID.test(assignment.job_id ?? "") ||
    !ASSIGNMENT_STATES.has(assignment.assignment_state) ||
    !Number.isInteger(assignment.terms_version) ||
    assignment.terms_version < 1 ||
    assignment.commission_basis_points !== 500 ||
    !["open", null].includes(assignment.hold_status) ||
    !["not_released", "on_hold", "available"].includes(
      assignment.earnings_status,
    )
  )
    throw new Error("invalid_assignment_status_projection");
  const gross = amount(assignment.gross_principal_kobo);
  const commission = amount(assignment.commission_kobo);
  const workerNet = amount(assignment.worker_net_kobo);
  if (BigInt(gross) !== BigInt(commission) + BigInt(workerNet))
    throw new Error("invalid_assignment_status_projection");
  const startedAt = assignment.started_at;
  const submittedAt = assignment.submitted_at;
  const completedAt = assignment.completed_at;
  const validProgressTimestamps =
    (assignment.assignment_state === "assigned" &&
      startedAt === null &&
      submittedAt === null &&
      completedAt === null) ||
    (assignment.assignment_state === "in_progress" &&
      isTimestamp(startedAt) &&
      submittedAt === null &&
      completedAt === null) ||
    (assignment.assignment_state === "submitted" &&
      isTimestamp(startedAt) &&
      isTimestamp(submittedAt) &&
      completedAt === null) ||
    (assignment.assignment_state === "completed" &&
      isTimestamp(startedAt) &&
      isTimestamp(submittedAt) &&
      isTimestamp(completedAt)) ||
    assignment.assignment_state === "cancelled";
  if (!validProgressTimestamps)
    throw new Error("invalid_assignment_status_projection");
  let hold = null;
  if (row.hold !== null) {
    const value = row.hold;
    if (
      !isObject(value) ||
      !UUID.test(value.hold_id ?? "") ||
      (value.case_id !== undefined && value.case_id !== value.hold_id) ||
      value.status !== "open" ||
      !ASSIGNMENT_STATES.has(value.prior_assignment_state) ||
      !HOLD_REASONS.has(value.reason_code) ||
      typeof value.narrative !== "string" ||
      value.narrative.length < 1 ||
      value.narrative.length > 2000 ||
      typeof value.desired_outcome !== "string" ||
      value.desired_outcome.length < 1 ||
      value.desired_outcome.length > 500 ||
      (value.follow_up !== undefined &&
        value.follow_up !== null &&
        (typeof value.follow_up !== "string" ||
          value.follow_up.length > 500)) ||
      !isTimestamp(value.opened_at)
    )
      throw new Error("invalid_assignment_status_projection");
    hold = {
      case_id: value.case_id ?? value.hold_id,
      hold_id: value.hold_id,
      status: value.status,
      prior_assignment_state: value.prior_assignment_state,
      reason_code: value.reason_code,
      narrative: value.narrative,
      desired_outcome: value.desired_outcome,
      follow_up: value.follow_up ?? null,
      opened_at: new Date(value.opened_at).toISOString(),
    };
  }
  if ((hold === null) !== (assignment.hold_status === null))
    throw new Error("invalid_assignment_status_projection");
  return {
    assignment: {
      assignment_id: assignment.assignment_id,
      application_id: assignment.application_id,
      thread_id: assignment.thread_id,
      job_id: assignment.job_id,
      assignment_state: assignment.assignment_state,
      started_at: isTimestamp(startedAt)
        ? new Date(startedAt).toISOString()
        : null,
      submitted_at: isTimestamp(submittedAt)
        ? new Date(submittedAt).toISOString()
        : null,
      completed_at: isTimestamp(completedAt)
        ? new Date(completedAt).toISOString()
        : null,
      hold_status: assignment.hold_status,
      earnings_status: assignment.earnings_status,
      terms_version: assignment.terms_version,
      gross_principal_kobo: gross,
      commission_kobo: commission,
      worker_net_kobo: workerNet,
      commission_basis_points: 500,
    },
    hold,
  };
}

function mapError(error, requestId) {
  if (error?.code === "42501" || error?.message === "marketplace_access_denied")
    return fail(403, "verification_required", requestId);
  if (error?.code === "P0002" || error?.message === "job_not_found")
    return fail(404, "not_found", requestId);
  if (error?.code === "P0001" || error?.message === "stale_state")
    return fail(409, "stale_state", requestId);
  if (["22023", "22P02"].includes(error?.code))
    return fail(400, "invalid_request", requestId);
  return fail(503, "service_unavailable", requestId);
}

export function createMarketplaceReadHandler({
  verifyActor,
  rpc,
  requestId = () => crypto.randomUUID(),
}) {
  if (typeof verifyActor !== "function" || typeof rpc !== "function")
    throw new Error("marketplace read dependencies are not configured");

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
        input.action === "discover_jobs" &&
        onlyKeys(input, new Set(["action", "filters", "cursor"]))
      ) {
        const filters = normalizeFilters(input.filters ?? {});
        if (filters === null) return fail(400, "invalid_request", id);
        const cursor =
          input.cursor === undefined
            ? null
            : decodeCursor(input.cursor, "discover", filters);
        if (input.cursor !== undefined && !cursor)
          return fail(400, "invalid_request", id);
        const rows = await rpc("server_discover_jobs_for_actor", {
          p_actor: actor.id,
          p_filters: filters,
          p_cursor_created_at: cursor?.created_at ?? null,
          p_cursor_job_id: cursor?.job_id ?? null,
          p_limit: PAGE_SIZE + 1,
        });
        if (!Array.isArray(rows) || rows.length > PAGE_SIZE + 1)
          throw new Error("invalid_marketplace_read_projection");
        const hasMore = rows.length > PAGE_SIZE;
        const visible = rows.slice(0, PAGE_SIZE).map((row) => safeSummary(row));
        const last = visible.at(-1);
        return json(
          200,
          {
            data: {
              items: visible,
              filters,
              next_cursor:
                hasMore && last
                  ? encodeCursor({
                      v: 1,
                      kind: "discover",
                      filters,
                      created_at: last.created_at,
                      job_id: last.job_id,
                    })
                  : null,
            },
          },
          id,
        );
      }

      if (
        input.action === "job_detail" &&
        onlyKeys(input, new Set(["action", "job_id"])) &&
        UUID.test(input.job_id ?? "")
      ) {
        const row = await rpc("server_get_discoverable_job_detail_for_actor", {
          p_actor: actor.id,
          p_job_id: input.job_id,
        });
        if (!isObject(row)) return fail(404, "not_found", id);
        return json(200, { data: { job: safeDetail(row) } }, id);
      }

      if (
        input.action === "my_job_detail" &&
        onlyKeys(input, new Set(["action", "job_id"])) &&
        UUID.test(input.job_id ?? "")
      ) {
        const row = await rpc("server_get_my_funded_job_detail_for_actor", {
          p_actor: actor.id,
          p_job_id: input.job_id,
        });
        if (!isObject(row)) return fail(404, "not_found", id);
        return json(
          200,
          { data: { job: safeDetail(row, { history: true }) } },
          id,
        );
      }

      if (
        input.action === "my_job_history" &&
        onlyKeys(input, new Set(["action", "cursor"]))
      ) {
        const cursor =
          input.cursor === undefined
            ? null
            : decodeCursor(input.cursor, "history", {});
        if (input.cursor !== undefined && !cursor)
          return fail(400, "invalid_request", id);
        const rows = await rpc("server_get_my_funded_job_history", {
          p_actor: actor.id,
          p_cursor_created_at: cursor?.created_at ?? null,
          p_cursor_job_id: cursor?.job_id ?? null,
          p_limit: PAGE_SIZE + 1,
        });
        if (!Array.isArray(rows) || rows.length > PAGE_SIZE + 1)
          throw new Error("invalid_marketplace_read_projection");
        const hasMore = rows.length > PAGE_SIZE;
        const visible = rows
          .slice(0, PAGE_SIZE)
          .map((row) => safeSummary(row, { history: true }));
        const last = visible.at(-1);
        return json(
          200,
          {
            data: {
              items: visible,
              next_cursor:
                hasMore && last
                  ? encodeCursor({
                      v: 1,
                      kind: "history",
                      filters: {},
                      created_at: last.created_at,
                      job_id: last.job_id,
                    })
                  : null,
            },
          },
          id,
        );
      }

      if (
        input.action === "job_applications" &&
        onlyKeys(input, new Set(["action", "job_id", "cursor"])) &&
        UUID.test(input.job_id ?? "")
      ) {
        const filters = { job_id: input.job_id };
        const cursor =
          input.cursor === undefined
            ? null
            : decodeCursor(input.cursor, "job_applications", filters, {
                timeField: "applied_at",
                idField: "application_id",
              });
        if (input.cursor !== undefined && !cursor)
          return fail(400, "invalid_request", id);
        const rows = await rpc("server_get_job_applications_for_actor", {
          p_actor: actor.id,
          p_job_id: input.job_id,
          p_cursor_applied_at: cursor?.applied_at ?? null,
          p_cursor_application_id: cursor?.application_id ?? null,
          p_limit: PAGE_SIZE + 1,
        });
        if (!Array.isArray(rows) || rows.length > PAGE_SIZE + 1)
          throw new Error("invalid_marketplace_read_projection");
        const hasMore = rows.length > PAGE_SIZE;
        const visible = rows
          .slice(0, PAGE_SIZE)
          .map((row) => safeApplication(row, { owner: true }));
        const last = visible.at(-1);
        return json(
          200,
          {
            data: {
              items: visible,
              next_cursor:
                hasMore && last
                  ? encodeCursor({
                      v: 1,
                      kind: "job_applications",
                      filters,
                      applied_at: last.applied_at,
                      application_id: last.application_id,
                    })
                  : null,
            },
          },
          id,
        );
      }

      if (
        input.action === "my_applications" &&
        onlyKeys(input, new Set(["action", "cursor"]))
      ) {
        const cursor =
          input.cursor === undefined
            ? null
            : decodeCursor(
                input.cursor,
                "my_applications",
                {},
                {
                  timeField: "applied_at",
                  idField: "application_id",
                },
              );
        if (input.cursor !== undefined && !cursor)
          return fail(400, "invalid_request", id);
        const rows = await rpc("server_get_my_applications_for_actor", {
          p_actor: actor.id,
          p_cursor_applied_at: cursor?.applied_at ?? null,
          p_cursor_application_id: cursor?.application_id ?? null,
          p_limit: PAGE_SIZE + 1,
        });
        if (!Array.isArray(rows) || rows.length > PAGE_SIZE + 1)
          throw new Error("invalid_marketplace_read_projection");
        const hasMore = rows.length > PAGE_SIZE;
        const visible = rows
          .slice(0, PAGE_SIZE)
          .map((row) => safeApplication(row, { owner: false }));
        const last = visible.at(-1);
        return json(
          200,
          {
            data: {
              items: visible,
              next_cursor:
                hasMore && last
                  ? encodeCursor({
                      v: 1,
                      kind: "my_applications",
                      filters: {},
                      applied_at: last.applied_at,
                      application_id: last.application_id,
                    })
                  : null,
            },
          },
          id,
        );
      }

      if (
        input.action === "application_thread" &&
        onlyKeys(
          input,
          new Set(["action", "application_id", "after_sequence"]),
        ) &&
        UUID.test(input.application_id ?? "") &&
        (input.after_sequence === undefined ||
          (typeof input.after_sequence === "string" &&
            SEQUENCE.test(input.after_sequence) &&
            BigInt(input.after_sequence) <= MAX_SEQUENCE))
      ) {
        const row = await rpc("server_get_application_thread_for_actor", {
          p_actor: actor.id,
          p_application_id: input.application_id,
          p_after_sequence: input.after_sequence ?? "0",
          p_limit: MESSAGE_PAGE_SIZE + 1,
        });
        if (!isObject(row)) return fail(404, "not_found", id);
        return json(200, { data: safeApplicationThread(row) }, id);
      }

      if (
        input.action === "assignment_status" &&
        onlyKeys(input, new Set(["action", "assignment_id"])) &&
        UUID.test(input.assignment_id ?? "")
      ) {
        const row = await rpc("server_get_assignment_status_for_actor", {
          p_actor: actor.id,
          p_assignment_id: input.assignment_id,
        });
        return json(200, { data: safeAssignmentStatus(row) }, id);
      }

      return fail(400, "invalid_request", id);
    } catch (error) {
      return mapError(error, id);
    }
  };
}
