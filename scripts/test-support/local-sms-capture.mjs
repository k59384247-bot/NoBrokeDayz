import { createServer } from "node:http";
import { randomBytes, timingSafeEqual } from "node:crypto";

const syntheticPhones = new Set([
  "+2347000000001",
  "+2347000000002",
  "+2347000000003",
  "+2347000000004",
  "+2347000000005",
  "+2347000000006",
]);

export async function startLocalSmsCapture({ failurePhones = [] } = {}) {
  const token = randomBytes(32).toString("base64url");
  const deliveries = [];
  const diagnosticEvents = [];
  const forcedFailures = new Set(failurePhones);
  const server = createServer((request, response) => {
    const providedToken = Buffer.from(
      request.headers.authorization?.replace(/^Bearer /, "") ?? "",
    );
    const expectedToken = Buffer.from(token);
    if (
      request.method !== "POST" ||
      !["/capture", "/diagnostic"].includes(request.url) ||
      providedToken.length !== expectedToken.length ||
      !timingSafeEqual(providedToken, expectedToken)
    ) {
      response.writeHead(404).end();
      return;
    }

    let body = "";
    request.setEncoding("utf8");
    request.on("data", (chunk) => {
      body += chunk;
      if (body.length > 2048) request.destroy();
    });
    request.on("end", () => {
      try {
        const delivery = JSON.parse(body);
        if (request.url === "/diagnostic") {
          if (
            ![
              "signature_invalid",
              "invalid_json",
              "invalid_payload",
              "invalid_phone",
              "delivery_failed",
              "send_limit_unavailable",
              "send_limit_reached",
            ].includes(delivery.reason)
          ) {
            response.writeHead(400).end();
            return;
          }
          diagnosticEvents.push(delivery);
          response.writeHead(204).end();
          return;
        }
        if (
          (!syntheticPhones.has(delivery.phone) &&
            !/^\+2347000000[0-9]{3}$/.test(delivery.phone)) ||
          !/^[0-9a-f-]{36}$/i.test(delivery.userId) ||
          !/^\d{6}$/.test(delivery.otp)
        ) {
          response.writeHead(400).end();
          return;
        }
        if (forcedFailures.has(delivery.phone)) {
          response.writeHead(503).end();
          return;
        }
        deliveries.push(delivery);
        response.writeHead(204).end();
      } catch {
        response.writeHead(400).end();
      }
    });
  });

  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  if (!address || typeof address === "string") {
    server.close();
    throw new Error("local SMS capture did not bind to loopback");
  }

  return {
    url: `http://127.0.0.1:${address.port}/capture`,
    token,
    take(phone, timeoutMs = 15000, userId) {
      const deadline = Date.now() + timeoutMs;
      return new Promise((resolve, reject) => {
        const poll = () => {
          const index = deliveries.findIndex(
            (item) =>
              item.phone === phone && (!userId || item.userId === userId),
          );
          if (index >= 0) {
            resolve(deliveries.splice(index, 1)[0]);
          } else if (Date.now() >= deadline) {
            reject(new Error("local synthetic SMS was not captured"));
          } else {
            setTimeout(poll, 25);
          }
        };
        poll();
      });
    },
    diagnostics() {
      return diagnosticEvents.slice();
    },
    close() {
      for (const delivery of deliveries) delivery.otp = "000000";
      deliveries.length = 0;
      return new Promise((resolve, reject) =>
        server.close((error) => (error ? reject(error) : resolve())),
      );
    },
  };
}
