import assert from "node:assert/strict";
import test from "node:test";
import { createFreshPasswordVerifier } from "../../../supabase/functions/_shared/financial-step-up.mjs";
import { createWalletCommandHandler } from "../../../supabase/functions/_shared/wallet-command.mjs";
import { createWalletReadHandler } from "../../../supabase/functions/_shared/wallet-read.mjs";

const actorId = "a0000000-0000-4000-8000-000000000001";
const destinationId = "b0000000-0000-4000-8000-000000000001";
const key = "c0000000-0000-4000-8000-000000000001";
const token = "a".repeat(64);
const headers = {
  authorization: "Bearer session-token",
  "content-type": "application/json",
};

function commandRequest(body) {
  return new Request("http://local/wallet-command", {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
}

function readRequest(body) {
  return new Request("http://local/wallet-read", {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
}

test("fresh password check signs in the same actor and keeps its session private", async () => {
  const requests = [];
  const verify = createFreshPasswordVerifier({
    authUrl: "http://127.0.0.1:54321",
    anonKey: "local-anon-key",
    fetchImpl: async (url, options) => {
      requests.push({ url, options, body: JSON.parse(options.body) });
      return Response.json({
        access_token: "must-not-escape-this-helper",
        refresh_token: "must-not-escape-this-helper-either",
        user: { id: actorId },
      });
    },
  });
  const verified = await verify(
    { id: actorId, email: "worker@example.test" },
    "fresh-password",
  );
  assert.equal(verified, true);
  assert.equal(requests.length, 1);
  assert.match(requests[0].url, /\/auth\/v1\/token\?grant_type=password$/);
  assert.deepEqual(requests[0].body, {
    email: "worker@example.test",
    password: "fresh-password",
  });
  assert.equal(requests[0].options.headers.apikey, "local-anon-key");
});

test("fresh password check rejects a password result for a different actor", async () => {
  const verify = createFreshPasswordVerifier({
    authUrl: "http://127.0.0.1:54321",
    anonKey: "local-anon-key",
    fetchImpl: async () =>
      Response.json({ access_token: "private", user: { id: destinationId } }),
  });
  assert.equal(
    await verify({ id: actorId, phone: "+2348000000000" }, "fresh-password"),
    false,
  );
});

test("withdrawal authorization requires fresh password and returns only a bound proof", async () => {
  const calls = [];
  const handler = createWalletCommandHandler({
    verifyActor: async () => ({ id: actorId, email: "worker@example.test" }),
    verifyPassword: async (actor, password) => {
      assert.equal(actor.id, actorId);
      assert.equal(password, "fresh-password");
      return true;
    },
    makeConfirmationToken: () => token,
    hashConfirmationToken: async (value) => `digest:${value}`,
    payoutFeeKobo: "0",
    rpc: async (name, args) => {
      calls.push({ name, args });
      return {
        authorization_id: key,
        destination_id: destinationId,
        destination_version: 3,
        amount_kobo: "285000",
        expires_at: "2026-11-04T10:05:00.000Z",
        destination_summary: {
          institution_label: "Fake NBD Bank Alpha",
          recipient_label: "Synthetic Recipient Alpha",
          masked_reference: "SIM-ALPHA",
          ownership_verification: "simulator_only",
        },
      };
    },
    requestId: () => "request-authorize",
  });
  const response = await handler(
    commandRequest({
      action: "authorize_withdrawal",
      amount_kobo: "285000",
      destination_id: destinationId,
      destination_version: 3,
      password: "fresh-password",
    }),
  );
  assert.equal(response.status, 200);
  assert.deepEqual(calls, [
    {
      name: "server_authorize_withdrawal_for_actor",
      args: {
        p_actor: actorId,
        p_amount_kobo: "285000",
        p_destination_id: destinationId,
        p_destination_version: 3,
        p_proof_sha256_hex: `digest:${token}`,
      },
    },
  ]);
  const body = await response.json();
  assert.equal(body.data.authorization_token, token);
  assert.equal(body.data.amount_kobo, "285000");
  assert.equal(body.data.destination.destination_version, 3);
  assert.equal(JSON.stringify(body).includes("fresh-password"), false);
  assert.equal(JSON.stringify(body).includes("access_token"), false);
});

test("wrong password creates no authorization and client confirmation flags are rejected", async () => {
  let rpcCount = 0;
  const handler = createWalletCommandHandler({
    verifyActor: async () => ({ id: actorId, email: "worker@example.test" }),
    verifyPassword: async () => false,
    rpc: async () => {
      rpcCount++;
      return {};
    },
  });
  const badProof = await handler(
    commandRequest({
      action: "authorize_withdrawal",
      amount_kobo: "285000",
      destination_id: destinationId,
      destination_version: 3,
      password: "wrong-password",
    }),
  );
  assert.equal(badProof.status, 403);
  assert.equal((await badProof.json()).error.code, "confirmation_required");
  const fakeBoolean = await handler(
    commandRequest({
      action: "request_withdrawal",
      amount_kobo: "285000",
      destination_id: destinationId,
      destination_version: 3,
      confirmed: true,
      idempotency_key: key,
    }),
  );
  assert.equal(fakeBoolean.status, 400);
  assert.equal(rpcCount, 0);
});

test("withdrawal consumes an opaque proof and never accepts provider fields", async () => {
  const calls = [];
  const handler = createWalletCommandHandler({
    verifyActor: async () => ({ id: actorId, email: "worker@example.test" }),
    verifyPassword: async () =>
      assert.fail("request must consume an existing proof"),
    hashConfirmationToken: async (value) => `digest:${value}`,
    payoutFeeKobo: "50",
    rpc: async (name, args) => {
      calls.push({ name, args });
      return {
        withdrawal_id: key,
        status: "queued_for_liquidity",
        amount_kobo: "285000",
        destination_id: destinationId,
        destination_version: 3,
        destination_summary: {
          institution_label: "Fake NBD Bank Alpha",
          recipient_label: "Synthetic Recipient Alpha",
          masked_reference: "SIM-ALPHA",
          ownership_verification: "simulator_only",
        },
      };
    },
    requestId: () => "request-withdrawal",
  });
  const response = await handler(
    commandRequest({
      action: "request_withdrawal",
      amount_kobo: "285000",
      destination_id: destinationId,
      destination_version: 3,
      authorization_token: token,
      idempotency_key: key,
    }),
  );
  assert.equal(response.status, 201);
  assert.deepEqual(calls, [
    {
      name: "server_request_withdrawal_for_actor",
      args: {
        p_actor: actorId,
        p_amount_kobo: "285000",
        p_destination_id: destinationId,
        p_destination_version: 3,
        p_proof_sha256_hex: `digest:${token}`,
        p_expected_provider_fee_kobo: "50",
        p_idempotency_key: key,
      },
    },
  ]);
});

test("wallet reads derive actor, keep amounts as integer strings and strip bank/provider data", async () => {
  const calls = [];
  const handler = createWalletReadHandler({
    verifyActor: async () => ({ id: actorId }),
    rpc: async (name, args) => {
      calls.push({ name, args });
      return {
        currency: "NGN",
        balances: {
          available_earnings_kobo: "285000",
          held_allocations_kobo: "0",
          case_held_kobo: "0",
          withdrawal_reserved_kobo: "285000",
          withdrawal_queued_kobo: "285000",
          withdrawal_processing_kobo: "0",
          withdrawal_unknown_kobo: "0",
          poster_held_principal_kobo: "0",
          poster_refund_payable_kobo: "300000",
        },
        destination: {
          destination_id: destinationId,
          destination_version: 3,
          institution_label: "Fake NBD Bank Alpha",
          recipient_label: "Synthetic Recipient Alpha",
          masked_reference: "SIM-ALPHA",
          ownership_verification: "simulator_only",
          full_account_number: "must-not-escape",
        },
        withdrawals: [
          {
            withdrawal_id: key,
            status: "queued_for_liquidity",
            amount_kobo: "285000",
            destination_id: destinationId,
            destination_version: 3,
            institution_label: "Fake NBD Bank Alpha",
            recipient_label: "Synthetic Recipient Alpha",
            masked_reference: "SIM-ALPHA",
            ownership_verification: "simulator_only",
            commission_kobo: null,
            created_at: "2026-11-04T10:00:00.000Z",
            updated_at: "2026-11-04T10:00:00.000Z",
            provider_payload: { secret: "must-not-escape" },
          },
        ],
        refund_payables: [
          {
            refund_payable_id: key,
            allocation_id: "e0000000-0000-4000-8000-000000000001",
            amount_kobo: "300000",
            status: "authorized",
            source: "unassigned_slot",
            created_at: "2026-11-04T10:00:00.000Z",
            reason: "private reason must not escape",
          },
        ],
        activity: [],
        next_cursor: null,
      };
    },
    requestId: () => "request-wallet-read",
  });
  const response = await handler(readRequest({ action: "get_my_wallet" }));
  assert.equal(response.status, 200);
  assert.deepEqual(calls, [
    {
      name: "server_get_my_wallet_for_actor",
      args: { p_actor: actorId, p_before_created_at: null, p_before_id: null },
    },
  ]);
  const body = await response.json();
  assert.equal(body.data.balances.available_earnings_kobo, "285000");
  assert.equal(body.data.balances.poster_refund_payable_kobo, "300000");
  assert.equal(body.data.refund_payables[0].status, "authorized");
  assert.equal("reason" in body.data.refund_payables[0], false);
  assert.equal(body.data.withdrawals[0].status, "queued_for_liquidity");
  assert.equal("full_account_number" in body.data.destination, false);
  assert.equal("provider_payload" in body.data.withdrawals[0], false);
});
