import assert from "node:assert/strict";
import test from "node:test";
import { createMarketplaceCommandHandler } from "../../../supabase/functions/_shared/marketplace-command.mjs";
import { createProfileCommandHandler } from "../../../supabase/functions/_shared/profile-command.mjs";
import { createReviewModerationHandler } from "../../../supabase/functions/_shared/review-moderation.mjs";

const actor = "a0000000-0000-4000-8000-000000000001";
const assignment = "b0000000-0000-4000-8000-000000000001";
const reviewId = "c0000000-0000-4000-8000-000000000001";
const key = "d0000000-0000-4000-8000-000000000001";
const profileId = "e0000000-0000-4000-8000-000000000001";

function jwt(aal = "aal2") {
  const payload = Buffer.from(JSON.stringify({ aal })).toString("base64url");
  return `header.${payload}.signature`;
}

function request(url, body, token = "valid-session") {
  return new Request(`http://local/${url}`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

test("review submission derives the actor, bounds text and distinguishes a saved retry", async () => {
  const calls = [];
  let replayed = false;
  const handler = createMarketplaceCommandHandler({
    verifyActor: async () => ({ id: actor }),
    rpc: async (name, args) => {
      calls.push({ name, args });
      return { replayed, review: { review_id: reviewId } };
    },
  });
  const input = {
    action: "submit_review",
    assignment_id: assignment,
    rating: 5,
    review_text: "  Reliable   and careful.  ",
    idempotency_key: key,
  };
  const saved = await handler(request("marketplace-command", input));
  assert.equal(saved.status, 201);
  assert.deepEqual(calls[0], {
    name: "server_submit_assignment_review_for_actor",
    args: {
      p_actor: actor,
      p_assignment_id: assignment,
      p_rating: 5,
      p_review_text: "Reliable   and careful.",
      p_idempotency_key: key,
    },
  });
  replayed = true;
  const retry = await handler(request("marketplace-command", input));
  assert.equal(retry.status, 200);
  assert.equal((await retry.json()).replayed, true);
  const injectedActor = await handler(
    request("marketplace-command", { ...input, actor_id: profileId }),
  );
  assert.equal(injectedActor.status, 400);
  assert.equal(calls.length, 2);
});

test("review input is bounded and database conflicts stay safe", async () => {
  const calls = [];
  const handler = createMarketplaceCommandHandler({
    verifyActor: async () => ({ id: actor }),
    rpc: async (name, args) => {
      calls.push({ name, args });
      throw Object.assign(new Error("review_already_submitted"), {
        code: "23505",
      });
    },
  });
  for (const body of [
    {
      action: "submit_review",
      assignment_id: assignment,
      rating: 0,
      idempotency_key: key,
    },
    {
      action: "submit_review",
      assignment_id: assignment,
      rating: 5,
      review_text: "x".repeat(501),
      idempotency_key: key,
    },
  ]) {
    const response = await handler(request("marketplace-command", body));
    assert.equal(response.status, 400);
  }
  const conflict = await handler(
    request("marketplace-command", {
      action: "submit_review",
      assignment_id: assignment,
      rating: 5,
      idempotency_key: key,
    }),
  );
  assert.equal(conflict.status, 409);
  assert.equal((await conflict.json()).error.code, "review_already_submitted");
  assert.equal(calls.length, 1);
});

test("profile review pages derive the viewer and preserve exact cursor timestamps", async () => {
  const calls = [];
  const handler = createProfileCommandHandler({
    verifyActor: async () => ({ id: actor }),
    command: async (name, args) => {
      calls.push({ name, args });
      return {
        items: [{ review_id: reviewId, target_role: "worker", rating: 5 }],
      };
    },
  });
  const before = "2026-11-11T08:15:23.123456+00:00";
  const response = await handler(
    request("profile-command", {
      action: "reviews",
      profile_id: profileId,
      before_created_at: before,
      before_review_id: reviewId,
    }),
  );
  assert.equal(response.status, 200);
  assert.deepEqual(calls[0], {
    name: "server_list_profile_reviews_for_viewer",
    args: {
      p_viewer: actor,
      p_subject: profileId,
      p_before_created_at: before,
      p_before_review_id: reviewId,
    },
  });
  assert.deepEqual((await response.json()).reviews.items, [
    { review_id: reviewId, target_role: "worker", rating: 5 },
  ]);
  const invalidCursor = await handler(
    request("profile-command", {
      action: "reviews",
      profile_id: profileId,
      before_created_at: before,
    }),
  );
  assert.equal(invalidCursor.status, 400);
  assert.equal(calls.length, 1);
});

test("moderation requires AAL2, derives the actor and passes only bounded commands", async () => {
  const calls = [];
  const handler = createReviewModerationHandler({
    verifyActor: async () => ({ id: actor }),
    rpc: async (name, args) => {
      calls.push({ name, args });
      return { items: [], next_cursor: null };
    },
  });
  const denied = await handler(
    request("review-moderation", { action: "list_reported" }, jwt("aal1")),
  );
  assert.equal(denied.status, 403);
  assert.equal(calls.length, 0);

  const listed = await handler(
    request("review-moderation", { action: "list_reported" }, jwt()),
  );
  assert.equal(listed.status, 200);
  assert.deepEqual(calls[0], {
    name: "server_list_review_moderation_queue_for_actor",
    args: {
      p_actor: actor,
      p_auth_aal: "aal2",
      p_before_reported_at: null,
      p_before_review_id: null,
      p_limit: 21,
    },
  });

  const hidden = await handler(
    request(
      "review-moderation",
      {
        action: "hide",
        review_id: reviewId,
        reason: "This synthetic text contains private contact details.",
        idempotency_key: key,
      },
      jwt(),
    ),
  );
  assert.equal(hidden.status, 200);
  assert.equal(calls[1].name, "server_hide_assignment_review_for_actor");
  assert.equal(calls[1].args.p_actor, actor);
  assert.equal(calls[1].args.p_auth_aal, "aal2");
  assert.equal(calls[1].args.p_review_id, reviewId);
  assert.equal("reporter_id" in calls[1].args, false);
});

test("AAL2 alone cannot bypass the database moderator grant", async () => {
  const handler = createReviewModerationHandler({
    verifyActor: async () => ({ id: actor }),
    rpc: async () => {
      throw Object.assign(new Error("review_moderation_denied"), {
        code: "42501",
      });
    },
  });
  const response = await handler(
    request("review-moderation", { action: "list_reported" }, jwt()),
  );
  assert.equal(response.status, 403);
  assert.equal((await response.json()).error.code, "review_moderation_denied");
});
