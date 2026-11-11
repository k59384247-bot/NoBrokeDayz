import assert from "node:assert/strict";
import test from "node:test";
import { createMarketplaceReadHandler } from "../../../supabase/functions/_shared/marketplace-read.mjs";

const actor = "a0000000-0000-4000-8000-000000000001";
const jobId = "b0000000-0000-4000-8000-000000000001";
const headers = {
  authorization: "Bearer valid-session",
  "content-type": "application/json",
};

function request(body, authorization = headers.authorization) {
  return new Request("http://local/marketplace-read", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(authorization ? { authorization } : {}),
    },
    body: JSON.stringify(body),
  });
}

function setup({ verifyActor = async () => ({ id: actor }), rpc } = {}) {
  const calls = [];
  const handler = createMarketplaceReadHandler({
    verifyActor,
    rpc:
      rpc ??
      (async (name, args) => {
        calls.push({ name, args });
        return [];
      }),
    requestId: () => "request-step5",
  });
  return { handler, calls };
}

test("anonymous clients cannot discover jobs or invoke the read gateway", async () => {
  const { handler, calls } = setup();
  const response = await handler(
    request({ action: "discover_jobs", filters: {} }, null),
  );
  assert.equal(response.status, 401);
  assert.deepEqual(calls, []);
  assert.equal(response.headers.get("cache-control"), "no-store");
});

test("discovery derives its actor, bounds the page and strips unapproved fields", async () => {
  const rows = Array.from({ length: 21 }, (_, index) => ({
    job_id:
      index === 0
        ? jobId
        : `b0000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`,
    created_at: `2026-11-04T10:00:${String(59 - index).padStart(2, "0")}Z`,
    title: "Carry books",
    description_excerpt: "Help carry books between lecture halls.",
    category_slug: "errands",
    category_label: "Errands",
    location_type: "on_campus",
    location_detail: "Main library",
    gross_per_worker_kobo: "300000",
    commission_kobo: "15000",
    worker_net_kobo: "285000",
    slots_remaining: 3,
    terms_version: 1,
    poster_summary: {
      display_name: "Synthetic poster",
      account_type: "partner",
    },
    poster_email: "private@example.test",
    bank_account_number: "0000000000",
    provider_reference: "secret-provider-reference",
  }));
  const { handler, calls } = setup({
    rpc: async (name, args) => {
      calls.push({ name, args });
      return rows;
    },
  });
  const response = await handler(
    request({
      action: "discover_jobs",
      filters: {
        keyword: "  carry   books ",
        location: " Main   library ",
        min_gross_kobo: "100000",
        location_type: "on_campus",
      },
    }),
  );
  const body = await response.json();
  assert.equal(response.status, 200);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].name, "server_discover_jobs_for_actor");
  assert.equal(calls[0].args.p_actor, actor);
  assert.deepEqual(calls[0].args.p_filters, {
    keyword: "carry books",
    location: "Main library",
    min_gross_kobo: "100000",
    location_type: "on_campus",
  });
  assert.equal(body.data.items.length, 20);
  assert.ok(body.data.next_cursor);
  assert.equal(body.data.items[0].poster_email, undefined);
  assert.equal(body.data.items[0].bank_account_number, undefined);
  assert.equal(body.data.items[0].provider_reference, undefined);
  assert.equal(body.data.items[0].worker_net_kobo, "285000");
  assert.deepEqual(body.data.filters, calls[0].args.p_filters);
});

test("a pagination cursor cannot be reused with changed filters", async () => {
  let nextCursor;
  const rows = Array.from({ length: 21 }, (_, index) => ({
    job_id: `b0000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`,
    created_at: `2026-11-04T10:00:${String(59 - index).padStart(2, "0")}Z`,
    title: "Carry books",
    description_excerpt: "Help carry books between lecture halls.",
    category_slug: "errands",
    category_label: "Errands",
    location_type: "on_campus",
    location_detail: "Main library",
    gross_per_worker_kobo: "300000",
    commission_kobo: "15000",
    worker_net_kobo: "285000",
    slots_remaining: 1,
    terms_version: 1,
    poster_summary: {
      display_name: "Synthetic poster",
      account_type: "partner",
    },
  }));
  const { handler, calls } = setup({
    rpc: async (_name, args) => {
      calls.push(args);
      return rows;
    },
  });
  const first = await handler(
    request({ action: "discover_jobs", filters: { category_slug: "errands" } }),
  );
  nextCursor = (await first.json()).data.next_cursor;
  const second = await handler(
    request({
      action: "discover_jobs",
      filters: { category_slug: "tutoring" },
      cursor: nextCursor,
    }),
  );
  assert.equal(second.status, 400);
  assert.equal(calls.length, 1);
});

test("funded owner history uses a separate actor-bound detail query", async () => {
  const row = {
    job_id: jobId,
    created_at: "2026-11-04T10:00:00Z",
    title: "Carry books",
    description_excerpt: "Help carry books between lecture halls.",
    category_slug: "errands",
    category_label: "Errands",
    location_type: "on_campus",
    location_detail: "Main library",
    gross_per_worker_kobo: "300000",
    commission_kobo: "15000",
    worker_net_kobo: "285000",
    slots_remaining: 0,
    terms_version: 1,
    history_state: "filled",
    poster_summary: {
      display_name: "Synthetic poster",
      account_type: "partner",
    },
    description:
      "Carry books safely between the campus library and lecture halls.",
    application_deadline_at: "2026-11-06T10:00:00Z",
    needed_by_at: "2026-11-07T10:00:00Z",
    start_requirements: "Meet at the library entrance",
    application_note: "Bring a student card",
    poster_private_notes: "must not leak",
  };
  const { handler, calls } = setup({
    rpc: async (name, args) => {
      calls.push({ name, args });
      return row;
    },
  });
  const response = await handler(
    request({ action: "my_job_detail", job_id: jobId }),
  );
  const body = await response.json();
  assert.equal(response.status, 200, JSON.stringify(body));
  assert.equal(calls[0].name, "server_get_my_funded_job_detail_for_actor");
  assert.equal(calls[0].args.p_actor, actor);
  assert.equal(body.data.job.history_state, "filled");
  assert.equal(body.data.job.description, row.description);
  assert.equal(body.data.job.poster_private_notes, undefined);
});

test("an application thread is participant-scoped and preserves 64-bit sequences", async () => {
  const applicationId = "c0000000-0000-4000-8000-000000000002";
  const threadId = "d0000000-0000-4000-8000-000000000002";
  const row = {
    application_id: applicationId,
    thread_id: threadId,
    job_id: jobId,
    job_title: "Carry books",
    application_state: "applied",
    thread_state: "open",
    terms_version: 1,
    note: "I am available after class.",
    applied_at: "2026-11-04T10:00:00Z",
    assignment_id: null,
    assignment_state: null,
    gross_per_worker_kobo: "300000",
    other_party: { display_name: "Synthetic poster", account_type: "partner" },
    last_sequence: "9223372036854775807",
    read_cursor: "9223372036854775806",
    unread_count: "1",
    messages: [
      {
        message_id: "e0000000-0000-4000-8000-000000000002",
        client_message_id: "f0000000-0000-4000-8000-000000000002",
        sequence: "9223372036854775807",
        sender_is_me: false,
        body: "Meet at noon.",
        created_at: "2026-11-04T10:01:00Z",
        sender_id: "private-user-id",
        provider_reference: "must-not-leak",
      },
    ],
    applicant_email: "private@example.test",
  };
  const { handler, calls } = setup({
    rpc: async (name, args) => {
      calls.push({ name, args });
      return row;
    },
  });
  const response = await handler(
    request({
      action: "application_thread",
      application_id: applicationId,
      after_sequence: "9223372036854775806",
    }),
  );
  const body = await response.json();
  assert.equal(response.status, 200, JSON.stringify(body));
  assert.equal(calls[0].name, "server_get_application_thread_for_actor");
  assert.deepEqual(calls[0].args, {
    p_actor: actor,
    p_application_id: applicationId,
    p_after_sequence: "9223372036854775806",
    p_limit: 51,
  });
  assert.equal(body.data.thread.last_sequence, "9223372036854775807");
  assert.equal(body.data.thread.unread_count, "1");
  assert.equal(body.data.thread.messages[0].sequence, "9223372036854775807");
  assert.equal(body.data.thread.messages[0].sender_id, undefined);
  assert.equal(body.data.thread.messages[0].provider_reference, undefined);
  assert.equal(body.data.thread.applicant_email, undefined);
});

test("application thread replay pages are bounded, ordered and gap-free", async () => {
  const applicationId = "c0000000-0000-4000-8000-000000000003";
  const threadId = "d0000000-0000-4000-8000-000000000003";
  const base = 9007199254741000n;
  const messages = Array.from({ length: 51 }, (_, index) => ({
    message_id: `e0000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`,
    client_message_id: `f0000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`,
    sequence: (base + BigInt(index + 1)).toString(),
    sender_is_me: index % 2 === 0,
    body: `Message ${index + 1}`,
    created_at: "2026-11-04T10:01:00Z",
  }));
  const row = {
    application_id: applicationId,
    thread_id: threadId,
    job_id: jobId,
    job_title: "Carry books",
    application_state: "applied",
    thread_state: "open",
    terms_version: 1,
    note: null,
    applied_at: "2026-11-04T10:00:00Z",
    assignment_id: null,
    assignment_state: null,
    gross_per_worker_kobo: "300000",
    other_party: null,
    last_sequence: messages.at(-1).sequence,
    read_cursor: base.toString(),
    unread_count: "26",
    messages,
  };
  const { handler, calls } = setup({
    rpc: async (name, args) => {
      calls.push({ name, args });
      return {
        ...row,
        messages: messages.filter(
          (message) => BigInt(message.sequence) > BigInt(args.p_after_sequence),
        ),
      };
    },
  });
  const first = await handler(
    request({
      action: "application_thread",
      application_id: applicationId,
      after_sequence: base.toString(),
    }),
  );
  const firstBody = await first.json();
  assert.equal(first.status, 200);
  assert.equal(firstBody.data.thread.messages.length, 50);
  assert.equal(
    firstBody.data.thread.messages[0].sequence,
    (base + 1n).toString(),
  );
  assert.equal(
    firstBody.data.thread.messages.at(-1).sequence,
    (base + 50n).toString(),
  );
  assert.equal(firstBody.data.next_after_sequence, (base + 50n).toString());
  assert.equal(firstBody.data.thread.unread_count, "26");

  const second = await handler(
    request({
      action: "application_thread",
      application_id: applicationId,
      after_sequence: firstBody.data.next_after_sequence,
    }),
  );
  const secondBody = await second.json();
  assert.equal(second.status, 200);
  assert.equal(secondBody.data.thread.messages.length, 1);
  assert.equal(
    secondBody.data.thread.messages[0].sequence,
    (base + 51n).toString(),
  );
  assert.equal(secondBody.data.next_after_sequence, null);
  assert.deepEqual(
    calls.map((call) => call.args.p_after_sequence),
    [base.toString(), (base + 50n).toString()],
  );
});

test("poster applicant reads are job-scoped, paged and remove private identity fields", async () => {
  const rows = Array.from({ length: 21 }, (_, index) => ({
    application_id: `c0000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`,
    thread_id: `d0000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`,
    job_id: jobId,
    state: "applied",
    note: null,
    terms_version: 1,
    applied_at: `2026-11-04T10:00:${String(59 - index).padStart(2, "0")}Z`,
    assignment_id: null,
    applicant_summary: {
      display_name: "Synthetic applicant",
      account_type: "student",
    },
    worker_id: "private-user-id",
    applicant_email: "private@example.test",
  }));
  const { handler, calls } = setup({
    rpc: async (name, args) => {
      calls.push({ name, args });
      return rows;
    },
  });
  const response = await handler(
    request({ action: "job_applications", job_id: jobId }),
  );
  const body = await response.json();
  assert.equal(response.status, 200);
  assert.equal(calls[0].name, "server_get_job_applications_for_actor");
  assert.equal(calls[0].args.p_actor, actor);
  assert.equal(calls[0].args.p_job_id, jobId);
  assert.equal(calls[0].args.p_limit, 21);
  assert.equal(body.data.items.length, 20);
  assert.ok(body.data.next_cursor);
  assert.equal(body.data.items[0].applicant_summary.account_type, "student");
  assert.equal(body.data.items[0].worker_id, undefined);
  assert.equal(body.data.items[0].applicant_email, undefined);
});

test("student application history uses its own private query and serializes gross as an integer string", async () => {
  const row = {
    application_id: "c0000000-0000-4000-8000-000000000004",
    thread_id: "d0000000-0000-4000-8000-000000000004",
    job_id: jobId,
    state: "accepted",
    note: null,
    terms_version: 1,
    applied_at: "2026-11-04T10:00:00Z",
    assignment_id: "e0000000-0000-4000-8000-000000000004",
    job_title: "Carry books",
    gross_per_worker_kobo: "300000",
    poster_summary: {
      display_name: "Synthetic poster",
      account_type: "partner",
    },
    poster_email: "private@example.test",
  };
  const { handler, calls } = setup({
    rpc: async (name, args) => {
      calls.push({ name, args });
      return [row];
    },
  });
  const response = await handler(request({ action: "my_applications" }));
  const body = await response.json();
  assert.equal(response.status, 200);
  assert.equal(calls[0].name, "server_get_my_applications_for_actor");
  assert.equal(calls[0].args.p_actor, actor);
  assert.equal(calls[0].args.p_limit, 21);
  assert.equal(body.data.items[0].gross_per_worker_kobo, "300000");
  assert.equal(body.data.items[0].poster_email, undefined);
});
