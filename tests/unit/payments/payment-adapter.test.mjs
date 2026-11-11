import assert from "node:assert/strict";
import { createHmac, randomBytes } from "node:crypto";
import { afterEach, test } from "node:test";
import { createLocalPaymentAdapter } from "../../../supabase/functions/_shared/payment-adapter.mjs";
import { createPaymentSimulator } from "../../fixtures/payments/simulator.mjs";
import { runPaymentOperation } from "../../../supabase/functions/_shared/payment-operation-runner.mjs";

const requestSecret = randomBytes(32).toString("hex");
const webhookSecret = randomBytes(32).toString("hex");
const supabaseUrl = "http://127.0.0.1:54321";
const active = new Set();

async function setup() {
  const simulator = await createPaymentSimulator({
    requestSecret,
    webhookSecret,
  });
  active.add(simulator);
  const adapter = createLocalPaymentAdapter({
    mode: "local_simulator",
    supabaseUrl,
    simulatorUrl: simulator.url,
    requestSecret,
    webhookSecret,
  });
  return { simulator, adapter };
}

afterEach(async () => {
  await Promise.all([...active].map((simulator) => simulator.close()));
  active.clear();
});

test("simulator mode requires local application and provider endpoints", () => {
  assert.throws(
    () =>
      createLocalPaymentAdapter({
        mode: "local_simulator",
        supabaseUrl: "https://project.supabase.co",
        simulatorUrl: "http://127.0.0.1:9000",
        requestSecret,
        webhookSecret,
      }),
    /local Supabase endpoint/,
  );
  assert.throws(
    () =>
      createLocalPaymentAdapter({
        mode: "local_simulator",
        supabaseUrl,
        simulatorUrl: "https://payments.example.com",
        requestSecret,
        webhookSecret,
      }),
    /loopback simulator endpoint/,
  );
  assert.throws(
    () => createLocalPaymentAdapter({ mode: "bachs", supabaseUrl }),
    /unsupported payment mode/,
  );
});

test("simulator validates integer-kobo strings within its separate local test guard", async () => {
  const { adapter } = await setup();
  await assert.rejects(
    adapter.initializeCollection({
      operationId: "60000000-0000-4000-8000-000000000051",
      idempotencyKey: "60000000-0000-4000-8000-000000000052",
      amountKobo: "1.5",
      currency: "NGN",
    }),
    /invalid_simulator_amount/,
  );
  const atLocalGuard = await adapter.initializeCollection({
    operationId: "60000000-0000-4000-8000-000000000053",
    idempotencyKey: "60000000-0000-4000-8000-000000000054",
    amountKobo: "10000000000",
    currency: "NGN",
  });
  assert.equal(atLocalGuard.amountKobo, "10000000000");
  await assert.rejects(
    adapter.initializeCollection({
      operationId: "60000000-0000-4000-8000-000000000055",
      idempotencyKey: "60000000-0000-4000-8000-000000000056",
      amountKobo: "10000000001",
      currency: "NGN",
    }),
    /invalid_simulator_amount/,
  );
});

test("adapter rejects a response that changes the stable provider reference", async () => {
  const idempotencyKey = "60000000-0000-4000-8000-000000000055";
  const adapter = createLocalPaymentAdapter({
    mode: "local_simulator",
    supabaseUrl,
    simulatorUrl: "http://127.0.0.1:54329",
    requestSecret,
    webhookSecret,
    fetchImpl: async () =>
      new Response(
        JSON.stringify({
          reference: "sim-altered",
          clientReference: idempotencyKey,
          status: "succeeded",
          amountKobo: "100",
          feeKobo: "0",
          currency: "NGN",
          operationType: "collection",
          settlementStatus: "pending",
        }),
        { status: 200, headers: { "content-type": "application/json" } },
      ),
  });
  await assert.rejects(
    adapter.lookupOriginalOperation({ idempotencyKey }),
    (error) => error.code === "reference_mismatch",
  );
});

test("simulator exposes no authenticated outcome or callback injection route", async () => {
  const { simulator } = await setup();
  const path = "/v1/test/settle";
  const body = JSON.stringify({ status: "succeeded", amountKobo: "1" });
  const timestamp = String(Math.floor(Date.now() / 1000));
  const signature = createHmac("sha256", requestSecret)
    .update(`${timestamp}\nPOST\n${path}\n${body}`)
    .digest("hex");
  const response = await fetch(`${simulator.url}${path}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-simulator-timestamp": timestamp,
      "x-simulator-signature": signature,
    },
    body,
  });
  assert.equal(response.status, 404);
});

test("normalized simulator liquidity reports only integer-kobo cash and receivable", async () => {
  const { simulator, adapter } = await setup();
  simulator.recordPlatformCapital("5000");
  simulator.programNext("collection", "success", { feeKobo: "50" });
  const collection = await adapter.initializeCollection({
    operationId: "60000000-0000-4000-8000-000000000061",
    idempotencyKey: "60000000-0000-4000-8000-000000000062",
    amountKobo: "300000",
    currency: "NGN",
  });
  assert.deepEqual(await adapter.inspectLiquiditySnapshot(), {
    cashKobo: "5000",
    receivableKobo: "299950",
  });
  simulator.simulateSettlement(collection.clientReference, "succeeded");
  assert.deepEqual(await adapter.inspectLiquiditySnapshot(), {
    cashKobo: "304950",
    receivableKobo: "0",
  });
});

test("fake collection and payout preserve operation identity and support lookup", async () => {
  const { simulator, adapter } = await setup();
  simulator.programNext("collection", "pending");
  simulator.programNext("payout", "success", { feeKobo: "50" });
  const collection = {
    operationId: "60000000-0000-4000-8000-000000000001",
    idempotencyKey: "60000000-0000-4000-8000-000000000002",
    amountKobo: "300000",
    currency: "NGN",
  };
  const created = await adapter.initializeCollection(collection);
  assert.equal(created.status, "pending");
  assert.equal(
    (await adapter.lookupOriginalOperation(collection)).reference,
    created.reference,
  );
  assert.equal(
    (await adapter.initializeCollection(collection)).reference,
    created.reference,
  );
  assert.equal(simulator.stats().createdCollections, 1);

  const payout = await adapter.createPayout({
    operationId: "60000000-0000-4000-8000-000000000003",
    idempotencyKey: "60000000-0000-4000-8000-000000000004",
    amountKobo: "285000",
    currency: "NGN",
    destinationId: "60000000-0000-4000-8000-000000000005",
    destinationVersion: 1,
  });
  assert.equal(payout.status, "succeeded");
  assert.equal(payout.destinationId, "60000000-0000-4000-8000-000000000005");
  assert.equal(payout.destinationVersion, 1);
  assert.equal(payout.feeKobo, "50");
  assert.equal(
    (
      await adapter.lookupPayout({
        idempotencyKey: "60000000-0000-4000-8000-000000000004",
      })
    ).reference,
    payout.reference,
  );
  assert.equal(simulator.stats().createdPayouts, 1);
});

test("programmed outcomes include known failure, unknown, pending, success and reversal", async () => {
  const { simulator, adapter } = await setup();
  for (const [index, outcome] of [
    "known_failure",
    "unknown",
    "pending",
    "success",
    "reversal",
  ].entries()) {
    simulator.programNext("collection", outcome);
    const idempotencyKey = `60000000-0000-4000-8000-00000000001${index}`;
    const response = await adapter.initializeCollection({
      operationId: idempotencyKey,
      idempotencyKey,
      amountKobo: "1",
      currency: "NGN",
    });
    assert.equal(
      response.status,
      {
        known_failure: "failed",
        unknown: "unknown",
        pending: "pending",
        success: "succeeded",
        reversal: "succeeded",
      }[outcome],
    );
    if (outcome === "reversal")
      assert.equal(
        (await adapter.lookupOriginalOperation({ idempotencyKey })).status,
        "reversed",
      );
  }
});

test("accepted collection with a lost response stays unknown until lookup; retry creates once", async () => {
  const { simulator, adapter } = await setup();
  simulator.programNext("collection", "timeout_after_acceptance");
  const operation = {
    operation_id: "60000000-0000-4000-8000-000000000021",
    provider_idempotency_key: "60000000-0000-4000-8000-000000000022",
    amount_kobo: "900000",
    currency: "NGN",
    operation_type: "collection",
    merchant_identity: "fake_nbd_local_merchant_v1",
    lease_token: "lease-a",
  };
  const calls = [];
  const runner = {
    claim: async () => ({ ...operation }),
    complete: async (result) => calls.push(result),
  };
  await runPaymentOperation({ ...runner, adapter });
  assert.equal(calls[0].status, "unknown");
  assert.equal(simulator.stats().createdCollections, 1);

  const settled = await adapter.lookupOriginalOperation({
    idempotencyKey: operation.provider_idempotency_key,
  });
  assert.equal(settled.status, "succeeded");
  const retryCalls = [];
  await runPaymentOperation({
    claim: async () => ({ ...operation, lease_token: "lease-b" }),
    complete: async (result) => retryCalls.push(result),
    adapter,
  });
  assert.equal(retryCalls[0].status, "succeeded");
  assert.equal(retryCalls[0].reference, settled.reference);
  assert.equal(simulator.stats().createdCollections, 1);
});

test("collection runner rejects a missing or different claimed merchant identity", async () => {
  const { simulator, adapter } = await setup();
  const collection = await adapter.initializeCollection({
    operationId: "60000000-0000-4000-8000-000000000031",
    idempotencyKey: "60000000-0000-4000-8000-000000000032",
    amountKobo: "900000",
    currency: "NGN",
  });
  simulator.simulateSettlement(collection.clientReference, "succeeded");
  for (const merchantIdentity of [undefined, "fake_wrong_merchant_v1"]) {
    let completion;
    await runPaymentOperation({
      claim: async () => ({
        operation_id: "60000000-0000-4000-8000-000000000031",
        provider_idempotency_key: collection.clientReference,
        amount_kobo: "900000",
        currency: "NGN",
        operation_type: "collection",
        merchant_identity: merchantIdentity,
        lease_token: "synthetic-lease",
      }),
      complete: async (result) => {
        completion = result;
      },
      adapter,
    });
    assert.equal(completion.status, "exception");
    assert.equal(completion.safeErrorCode, "merchant_mismatch");
    assert.equal(completion.merchantIdentity, "fake_nbd_local_merchant_v1");
  }
  assert.equal(simulator.stats().createdCollections, 1);
});

test("refund retries reuse the source charge and do not settle on provider acceptance", async () => {
  const { simulator, adapter } = await setup();
  const collection = await adapter.initializeCollection({
    operationId: "60000000-0000-4000-8000-000000000091",
    idempotencyKey: "60000000-0000-4000-8000-000000000092",
    amountKobo: "300000",
    currency: "NGN",
  });
  const refund = {
    operation_id: "60000000-0000-4000-8000-000000000093",
    provider_idempotency_key: "60000000-0000-4000-8000-000000000094",
    operation_type: "refund",
    amount_kobo: "300000",
    currency: "NGN",
    source_provider_reference: collection.reference,
    expected_provider_fee_kobo: "25",
    lease_token: "refund-lease-1",
  };
  await assert.rejects(
    adapter.createRefund({
      operationId: refund.operation_id,
      idempotencyKey: refund.provider_idempotency_key,
      amountKobo: refund.amount_kobo,
      currency: refund.currency,
      sourceReference: collection.reference,
    }),
    /invalid_refund_source/,
  );
  simulator.simulateSettlement(collection.clientReference, "succeeded");
  const results = [];
  const runner = {
    claim: async () => ({ ...refund }),
    complete: async (result) => results.push(result),
  };

  simulator.programNext("refund", "timeout_after_acceptance", {
    feeKobo: "25",
  });
  await runPaymentOperation({ ...runner, adapter });
  assert.equal(results.at(-1).status, "unknown");

  refund.lease_token = "refund-lease-2";
  await runPaymentOperation({ ...runner, adapter });
  assert.equal(results.at(-1).status, "processing");
  assert.equal(results.at(-1).retry, true);
  assert.equal(results.at(-1).amountKobo, "300000");
  assert.equal(results.at(-1).sourceReference, collection.reference);
  assert.equal(simulator.stats().createdRefunds, 1);

  simulator.simulateSettlement(refund.provider_idempotency_key, "settled");
  refund.lease_token = "refund-lease-3";
  await runPaymentOperation({ ...runner, adapter });
  assert.equal(results.at(-1).status, "settled");
  assert.equal(results.at(-1).retry, false);
  assert.equal(results.at(-1).settlementStatus, "available");
  assert.equal(simulator.stats().createdRefunds, 1);
  assert.equal(simulator.stats().createdPayouts, 0);
});

test("simulator permits independent partial slot refunds but caps them to the source charge", async () => {
  const { simulator, adapter } = await setup();
  const collection = await adapter.initializeCollection({
    operationId: "60000000-0000-4000-8000-000000000095",
    idempotencyKey: "60000000-0000-4000-8000-000000000096",
    amountKobo: "600000",
    currency: "NGN",
  });
  simulator.simulateSettlement(collection.clientReference, "succeeded");
  simulator.programNext("refund", "pending");
  simulator.programNext("refund", "known_failure");
  const first = await adapter.createRefund({
    operationId: "60000000-0000-4000-8000-000000000097",
    idempotencyKey: "60000000-0000-4000-8000-000000000098",
    amountKobo: "300000",
    currency: "NGN",
    sourceReference: collection.reference,
  });
  const second = await adapter.createRefund({
    operationId: "60000000-0000-4000-8000-000000000099",
    idempotencyKey: "60000000-0000-4000-8000-000000000100",
    amountKobo: "300000",
    currency: "NGN",
    sourceReference: collection.reference,
  });
  assert.equal(first.status, "pending");
  assert.equal(second.status, "failed");
  assert.deepEqual(
    simulator.stats().refundDetails.map(({ amountKobo, status }) => ({
      amountKobo,
      status,
    })),
    [
      { amountKobo: "300000", status: "pending" },
      { amountKobo: "300000", status: "failed" },
    ],
  );
  await assert.rejects(
    adapter.createRefund({
      operationId: "60000000-0000-4000-8000-000000000101",
      idempotencyKey: "60000000-0000-4000-8000-000000000102",
      amountKobo: "1",
      currency: "NGN",
      sourceReference: collection.reference,
    }),
    /refund_limit_exceeded/,
  );
});

test("altered operation terms are rejected by the simulator's idempotency key", async () => {
  const { adapter } = await setup();
  const original = {
    operationId: "60000000-0000-4000-8000-000000000031",
    idempotencyKey: "60000000-0000-4000-8000-000000000032",
    amountKobo: "300000",
    currency: "NGN",
  };
  await adapter.initializeCollection({
    ...original,
    operationId: "60000000-0000-4000-8000-000000000031",
  });
  await assert.rejects(
    adapter.initializeCollection({
      ...original,
      operationId: "60000000-0000-4000-8000-000000000031",
      amountKobo: "300001",
    }),
    /idempotency_conflict/,
  );
  const payout = {
    operationId: "60000000-0000-4000-8000-000000000033",
    idempotencyKey: "60000000-0000-4000-8000-000000000034",
    amountKobo: "285000",
    currency: "NGN",
    destinationId: "60000000-0000-4000-8000-000000000035",
    destinationVersion: 1,
  };
  await adapter.createPayout(payout);
  await assert.rejects(
    adapter.createPayout({
      ...payout,
      destinationId: "60000000-0000-4000-8000-000000000036",
      destinationVersion: 2,
    }),
    /idempotency_conflict/,
  );
});

test("settlement is a local fixture control and lookup is authoritative", async () => {
  const { simulator, adapter } = await setup();
  const operation = {
    operationId: "60000000-0000-4000-8000-000000000041",
    idempotencyKey: "60000000-0000-4000-8000-000000000042",
    amountKobo: "900000",
    currency: "NGN",
  };
  simulator.programNext("collection", "pending");
  assert.equal(
    (await adapter.initializeCollection(operation)).status,
    "pending",
  );
  simulator.simulateSettlement(operation.idempotencyKey, "succeeded");
  assert.equal(
    (await adapter.lookupOriginalOperation(operation)).status,
    "succeeded",
  );
});

test("runner parks a provider amount mismatch as an exception without retrying", async () => {
  const operation = {
    operation_id: "60000000-0000-4000-8000-000000000061",
    provider_idempotency_key: "60000000-0000-4000-8000-000000000062",
    amount_kobo: "300000",
    currency: "NGN",
    operation_type: "collection",
    lease_token: "lease-mismatch",
  };
  const results = [];
  await runPaymentOperation({
    claim: async () => operation,
    complete: async (result) => results.push(result),
    adapter: {
      lookupOriginalOperation: async () => null,
      initializeCollection: async () => ({
        clientReference: operation.provider_idempotency_key,
        amountKobo: "300001",
        currency: "NGN",
        status: "succeeded",
      }),
    },
  });
  assert.equal(results[0].status, "exception");
  assert.equal(results[0].safeErrorCode, "amount_mismatch");
  assert.equal(results[0].retry, undefined);
});
