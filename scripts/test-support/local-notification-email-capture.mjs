import { createServer } from "node:http";
import { randomBytes, randomUUID } from "node:crypto";

const UUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
const LOOPBACK = new Set(["127.0.0.1", "::1", "::ffff:127.0.0.1"]);

export async function startLocalNotificationEmailCapture({
  token = randomBytes(32).toString("base64url"),
} = {}) {
  const messages = new Map();
  const server = createServer(async (request, response) => {
    if (
      !LOOPBACK.has(request.socket.remoteAddress) ||
      request.headers.authorization !== `Bearer ${token}`
    ) {
      response.writeHead(404).end();
      return;
    }
    const lookup = request.url?.match(/^\/deliver\/([0-9a-f-]+)$/i);
    if (request.method === "GET" && lookup && UUID.test(lookup[1])) {
      const message = messages.get(lookup[1]);
      if (!message) {
        response.writeHead(404).end();
        return;
      }
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ capture_id: message.capture_id }));
      return;
    }
    if (request.method !== "POST" || request.url !== "/deliver") {
      response.writeHead(404).end();
      return;
    }
    const chunks = [];
    let bytes = 0;
    for await (const chunk of request) {
      bytes += chunk.length;
      if (bytes > 4096) {
        response.writeHead(413).end();
        return;
      }
      chunks.push(chunk);
    }
    let message;
    try {
      message = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    } catch {
      response.writeHead(400).end();
      return;
    }
    if (
      !UUID.test(message?.deliveryId ?? "") ||
      !/^[^\s@]+@identity\.test$/i.test(message?.to ?? "") ||
      message?.template !== "transactional_notice_v1" ||
      typeof message?.subject !== "string" ||
      typeof message?.text !== "string" ||
      Object.keys(message).some(
        (key) =>
          !["deliveryId", "to", "template", "subject", "text"].includes(key),
      )
    ) {
      response.writeHead(400).end();
      return;
    }
    const normalized = JSON.stringify(message);
    const previous = messages.get(message.deliveryId);
    if (previous) {
      if (previous.normalized !== normalized) {
        response.writeHead(409).end();
        return;
      }
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ capture_id: previous.capture_id }));
      return;
    }
    const captured = { ...message, capture_id: randomUUID(), normalized };
    messages.set(message.deliveryId, captured);
    response.writeHead(202, { "content-type": "application/json" });
    response.end(JSON.stringify({ capture_id: captured.capture_id }));
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const port = server.address().port;
  return {
    url: `http://127.0.0.1:${port}`,
    token,
    count(deliveryId) {
      return messages.has(deliveryId) ? 1 : 0;
    },
    async close() {
      messages.clear();
      await new Promise((resolve, reject) =>
        server.close((error) => (error ? reject(error) : resolve())),
      );
    },
  };
}
