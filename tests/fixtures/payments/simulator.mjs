import { createHmac, timingSafeEqual } from "node:crypto";
import { createServer } from "node:http";

const OUTCOMES = new Set([
  "pending",
  "success",
  "known_failure",
  "unknown",
  "reversal",
  "timeout_after_acceptance",
]);
const UUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
const DEFAULT_MERCHANT = "fake_nbd_local_merchant_v1";

function sign(secret, value) {
  return createHmac("sha256", secret).update(value).digest("hex");
}

function sameHex(left, right) {
  if (!/^[0-9a-f]{64}$/.test(right)) return false;
  const a = Buffer.from(left, "hex");
  const b = Buffer.from(right, "hex");
  return a.length === b.length && timingSafeEqual(a, b);
}

export async function createPaymentSimulator({
  requestSecret,
  webhookSecret,
  merchantIdentity = DEFAULT_MERCHANT,
}) {
  if (requestSecret?.length < 32 || webhookSecret?.length < 32)
    throw new Error("simulator secrets must be at least 32 characters");
  if (!/^fake_[a-z0-9_]{8,80}$/.test(merchantIdentity))
    throw new Error("simulator merchant identity must be synthetic");
  const operations = new Map();
  const byClientReference = new Map();
  const outcomes = { collection: [], payout: [], refund: [] };
  let createdCollections = 0;
  let createdPayouts = 0;
  let createdRefunds = 0;
  let platformCapitalKobo = 0n;

  function liquiditySnapshot() {
    let cash = platformCapitalKobo;
    let receivable = 0n;
    for (const operation of operations.values()) {
      const amount = BigInt(operation.amountKobo);
      const fee = BigInt(operation.feeKobo);
      if (operation.type === "collection" && operation.status === "succeeded") {
        const net = amount - fee;
        if (operation.settlementStatus === "available") cash += net;
        else receivable += net;
      } else if (operation.type === "payout") {
        if (operation.status === "succeeded") cash -= amount + fee;
        if (operation.status === "failed" || operation.status === "reversed")
          cash -= fee;
      } else if (operation.type === "refund") {
        if (operation.status === "settled") cash -= amount + fee;
        if (operation.status === "failed") cash -= fee;
        if (operation.status === "reversed" && operation.wasSettled)
          cash += amount;
      }
    }
    return {
      currency: "NGN",
      cashKobo: cash.toString(),
      receivableKobo: receivable.toString(),
    };
  }

  function programNext(type, outcome, options = {}) {
    if (!outcomes[type] || !OUTCOMES.has(outcome))
      throw new Error("invalid_simulator_scenario");
    if (
      Object.keys(options).some((key) => key !== "feeKobo") ||
      (options.feeKobo !== undefined &&
        !/^(0|[1-9][0-9]{0,11})$/.test(options.feeKobo))
    )
      throw new Error("invalid_simulator_scenario");
    outcomes[type].push({ outcome, feeKobo: options.feeKobo ?? "0" });
  }

  function publicOperation(operation) {
    return {
      reference: operation.reference,
      clientReference: operation.clientReference,
      status: operation.status,
      amountKobo: operation.amountKobo,
      feeKobo: operation.feeKobo,
      currency: operation.currency,
      operationType: operation.type,
      merchantIdentity: operation.merchantIdentity,
      ...(operation.type === "payout"
        ? {
            destinationId: operation.destinationId,
            destinationVersion: operation.destinationVersion,
          }
        : {}),
      settlementStatus: operation.settlementStatus,
      ...(operation.type === "refund"
        ? { sourceReference: operation.sourceReference }
        : {}),
    };
  }

  function createOperation(type, body, response) {
    const existing = byClientReference.get(body.clientReference);
    const shape = {
      type,
      operationId: body.operationId,
      clientReference: body.clientReference,
      amountKobo: body.amountKobo,
      currency: body.currency,
      merchantIdentity: body.merchantIdentity ?? null,
      destinationId: body.destinationId ?? null,
      destinationVersion: body.destinationVersion ?? null,
      sourceReference: body.sourceReference ?? null,
    };
    if (existing) {
      const existingShape = {
        type: existing.type,
        operationId: existing.operationId,
        clientReference: existing.clientReference,
        amountKobo: existing.amountKobo,
        currency: existing.currency,
        merchantIdentity: existing.merchantIdentity,
        destinationId: existing.destinationId,
        destinationVersion: existing.destinationVersion,
        sourceReference: existing.sourceReference,
      };
      if (JSON.stringify(shape) !== JSON.stringify(existingShape)) {
        response.writeHead(409, { "content-type": "application/json" });
        response.end(JSON.stringify({ error: "idempotency_conflict" }));
        return;
      }
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify(publicOperation(existing)));
      return;
    }
    const source =
      type === "refund"
        ? byClientReference.get(body.sourceReference?.replace(/^sim-/, ""))
        : null;
    if (
      type === "refund" &&
      (!source ||
        source.type !== "collection" ||
        source.status !== "succeeded" ||
        source.settlementStatus !== "available")
    ) {
      response.writeHead(409, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: "invalid_refund_source" }));
      return;
    }
    if (type === "refund") {
      const reserved = [...byClientReference.values()]
        .filter(
          (operation) =>
            operation.type === "refund" &&
            operation.sourceReference === body.sourceReference,
        )
        .reduce((total, operation) => total + BigInt(operation.amountKobo), 0n);
      if (reserved + BigInt(body.amountKobo) > BigInt(source.amountKobo)) {
        response.writeHead(409, { "content-type": "application/json" });
        response.end(JSON.stringify({ error: "refund_limit_exceeded" }));
        return;
      }
    }
    const scenario = outcomes[type].shift() ?? {
      outcome: "pending",
      feeKobo: "0",
    };
    const outcome = scenario.outcome;
    const operation = {
      ...shape,
      reference: `sim-${body.clientReference}`,
      status:
        outcome === "known_failure"
          ? "failed"
          : outcome === "unknown"
            ? "unknown"
            : "succeeded",
      feeKobo: scenario.feeKobo,
      settlementStatus: "pending",
      merchantIdentity: type === "collection" ? body.merchantIdentity : null,
      reverseOnLookup: outcome === "reversal",
      sourceReference: type === "refund" ? body.sourceReference : null,
      wasSettled: false,
    };
    operations.set(operation.reference, operation);
    byClientReference.set(operation.clientReference, operation);
    if (type === "collection") createdCollections++;
    else if (type === "payout") createdPayouts++;
    else createdRefunds++;

    if (outcome === "pending") operation.status = "pending";
    if (outcome === "timeout_after_acceptance") {
      operation.status = "succeeded";
      response.destroy();
      return;
    }
    response.writeHead(201, { "content-type": "application/json" });
    response.end(JSON.stringify(publicOperation(operation)));
  }

  const server = createServer(async (request, response) => {
    if (
      request.socket.remoteAddress &&
      !["127.0.0.1", "::1", "::ffff:127.0.0.1"].includes(
        request.socket.remoteAddress,
      )
    ) {
      response.writeHead(403).end();
      return;
    }
    const chunks = [];
    let size = 0;
    for await (const chunk of request) {
      size += chunk.length;
      if (size > 16384) {
        response.writeHead(413).end();
        return;
      }
      chunks.push(chunk);
    }
    const rawBody = Buffer.concat(chunks).toString("utf8");
    const timestamp = request.headers["x-simulator-timestamp"] ?? "";
    const supplied = request.headers["x-simulator-signature"] ?? "";
    const path = new URL(request.url, "http://127.0.0.1").pathname;
    const expected = sign(
      requestSecret,
      `${timestamp}\n${request.method}\n${request.url}\n${rawBody}`,
    );
    if (
      !/^\d{10}$/.test(timestamp) ||
      Math.abs(Date.now() / 1000 - Number(timestamp)) > 60 ||
      !sameHex(expected, supplied)
    ) {
      response.writeHead(401, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: "invalid_request_signature" }));
      return;
    }

    if (
      request.method === "POST" &&
      ["/v1/collections", "/v1/payouts", "/v1/refunds"].includes(path)
    ) {
      let body;
      try {
        body = JSON.parse(rawBody);
      } catch {
        response.writeHead(400).end();
        return;
      }
      if (
        !UUID.test(body.operationId ?? "") ||
        !UUID.test(body.clientReference ?? "") ||
        typeof body.amountKobo !== "string" ||
        !/^[1-9][0-9]{0,11}$/.test(body.amountKobo) ||
        BigInt(body.amountKobo) > 10000000000n ||
        body.currency !== "NGN" ||
        (path.endsWith("/collections") &&
          body.merchantIdentity !== merchantIdentity) ||
        (path.endsWith("/payouts") &&
          (typeof body.destinationId !== "string" ||
            !Number.isInteger(body.destinationVersion))) ||
        (path.endsWith("/refunds") &&
          (typeof body.sourceReference !== "string" ||
            !/^sim-[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(
              body.sourceReference,
            )))
      ) {
        response.writeHead(400, { "content-type": "application/json" });
        response.end(JSON.stringify({ error: "invalid_operation" }));
        return;
      }
      createOperation(
        path.endsWith("/collections")
          ? "collection"
          : path.endsWith("/payouts")
            ? "payout"
            : "refund",
        body,
        response,
      );
      return;
    }
    if (request.method === "GET" && path === "/v1/liquidity") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify(liquiditySnapshot()));
      return;
    }
    const match = path.match(
      /^\/v1\/operations\/by-client-reference\/([A-Za-z0-9-]+)$/,
    );
    if (request.method === "GET" && match) {
      const operation = byClientReference.get(decodeURIComponent(match[1]));
      if (operation?.reverseOnLookup) {
        operation.reverseOnLookup = false;
        operation.status = "reversed";
      }
      response.writeHead(200, { "content-type": "application/json" });
      response.end(
        JSON.stringify(
          operation ? publicOperation(operation) : { found: false },
        ),
      );
      return;
    }
    response.writeHead(404, { "content-type": "application/json" });
    response.end(JSON.stringify({ error: "not_found" }));
  });

  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  return {
    url: `http://127.0.0.1:${address.port}`,
    programNext,
    recordPlatformCapital(amountKobo) {
      if (
        typeof amountKobo !== "string" ||
        !/^[1-9][0-9]{0,18}$/.test(amountKobo)
      )
        throw new Error("invalid_test_capital");
      platformCapitalKobo += BigInt(amountKobo);
    },
    liquiditySnapshot,
    stats: () => ({
      createdCollections,
      createdPayouts,
      createdRefunds,
      operationCount: operations.size,
      payoutClientReferences: [...byClientReference.values()]
        .filter((operation) => operation.type === "payout")
        .map((operation) => operation.clientReference),
      payoutDetails: [...byClientReference.values()]
        .filter((operation) => operation.type === "payout")
        .map((operation) => ({
          clientReference: operation.clientReference,
          amountKobo: operation.amountKobo,
          feeKobo: operation.feeKobo,
          destinationId: operation.destinationId,
          destinationVersion: operation.destinationVersion,
          status: operation.status,
        })),
      refundDetails: [...byClientReference.values()]
        .filter((operation) => operation.type === "refund")
        .map((operation) => ({
          clientReference: operation.clientReference,
          sourceReference: operation.sourceReference,
          amountKobo: operation.amountKobo,
          feeKobo: operation.feeKobo,
          status: operation.status,
          settlementStatus: operation.settlementStatus,
        })),
    }),
    simulateSettlement(clientReference, status = "succeeded") {
      if (
        !new Set(["pending", "succeeded", "settled", "failed", "reversed"]).has(
          status,
        )
      )
        throw new Error("invalid_settlement_status");
      const operation = byClientReference.get(clientReference);
      if (!operation) throw new Error("simulated_operation_not_found");
      operation.status = status;
      operation.reverseOnLookup = false;
      if (
        operation.type === "collection" &&
        (status === "succeeded" || status === "settled")
      )
        operation.settlementStatus = "available";
      if (operation.type === "refund" && status === "settled") {
        operation.wasSettled = true;
        operation.settlementStatus = "available";
      }
      return publicOperation(operation);
    },
    reverseOperation(clientReference) {
      const operation = byClientReference.get(clientReference);
      if (!operation) throw new Error("simulated_operation_not_found");
      if (operation.type === "refund" && operation.status === "settled")
        operation.wasSettled = true;
      operation.status = "reversed";
      operation.reverseOnLookup = false;
      return publicOperation(operation);
    },
    makeEvent({
      eventReference,
      idempotencyKey,
      status,
      amountKobo = "1",
      currency = "NGN",
    }) {
      const operation = byClientReference.get(idempotencyKey);
      const body = {
        eventReference,
        clientReference: idempotencyKey,
        operationReference: operation?.reference ?? `sim-${idempotencyKey}`,
        status,
        amountKobo,
        currency,
      };
      const rawBody = JSON.stringify(body);
      const timestamp = String(Math.floor(Date.now() / 1000));
      const signature = sign(
        webhookSecret,
        `${eventReference}.${timestamp}.${rawBody}`,
      );
      return {
        rawBody,
        headers: {
          "content-type": "application/json",
          "x-simulator-event-id": eventReference,
          "x-simulator-timestamp": timestamp,
          "x-simulator-signature": signature,
        },
      };
    },
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}
