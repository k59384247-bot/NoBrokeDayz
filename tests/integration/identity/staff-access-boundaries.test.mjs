import assert from "node:assert/strict";
import { test } from "node:test";
import { createIdentityStaffHandler } from "../../../supabase/functions/_shared/identity-staff.mjs";

const actor = "8c5de580-8d71-4f00-a44e-859cba363e54";
const subject = "0bfc5c8c-d39b-4412-a466-a1a507974b64";
const key = "50000000-0000-0000-0000-000000000001";
function token(id = actor, aal = "aal2") {
  const payload = Buffer.from(JSON.stringify({ sub: id, aal })).toString(
    "base64url",
  );
  return `header.${payload}.signature`;
}
function request(body, access = token()) {
  return new Request("http://local.test/identity-staff", {
    method: "POST",
    headers: {
      authorization: `Bearer ${access}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

test("suspension actor and assurance come from the Auth-verified token", async () => {
  const calls = [];
  const handler = createIdentityStaffHandler({
    verifyActor: async () => ({ id: actor }),
    command: async (...args) => {
      calls.push(args);
      return { changed: true };
    },
  });
  const response = await handler(
    request({
      action: "suspend",
      subject_id: subject,
      reason: "Synthetic suspension reason for a boundary test.",
      idempotency_key: key,
      aal: "aal2",
    }),
  );
  assert.equal(response.status, 400, "client cannot supply an assurance value");
  assert.equal(calls.length, 0);
  const valid = await handler(
    request({
      action: "suspend",
      subject_id: subject,
      reason: "Synthetic suspension reason for a boundary test.",
      idempotency_key: key,
    }),
  );
  assert.equal(valid.status, 200);
  assert.deepEqual(calls[0], [
    "server_set_identity_suspension_for_actor",
    {
      p_actor: actor,
      p_subject: subject,
      p_suspended: true,
      p_reason: "Synthetic suspension reason for a boundary test.",
      p_idempotency_key: key,
      p_auth_aal: "aal2",
    },
  ]);
});

test("AAL1, invalid, or mismatched Auth sessions cannot suspend accounts", async () => {
  let calls = 0;
  const handler = createIdentityStaffHandler({
    verifyActor: async (access) =>
      access === token(actor, "aal1") ? { id: actor } : null,
    command: async () => {
      calls++;
      return {};
    },
  });
  const body = {
    action: "suspend",
    subject_id: subject,
    reason: "Synthetic suspension reason for a boundary test.",
    idempotency_key: key,
  };
  assert.equal(
    (await handler(request(body, token(actor, "aal1")))).status,
    403,
  );
  assert.equal(
    (await handler(request(body, token(subject, "aal2")))).status,
    401,
  );
  assert.equal(calls, 0);
});

test("ordinary request flags and malformed action fields are rejected", async () => {
  const handler = createIdentityStaffHandler({
    verifyActor: async () => ({ id: actor }),
    command: async () => ({ changed: true }),
  });
  for (const extra of [
    { actor_id: actor },
    { staff: true },
    { target_status: "suspended" },
  ]) {
    const response = await handler(
      request({
        action: "suspend",
        subject_id: subject,
        reason: "Synthetic suspension reason for a boundary test.",
        idempotency_key: key,
        ...extra,
      }),
    );
    assert.equal(response.status, 400);
  }
});
