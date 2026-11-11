import { createServer } from "node:http";
import { randomBytes } from "node:crypto";

export async function startLocalSchoolEmailCapture({
  port = 54331,
  token = randomBytes(32).toString("base64url"),
} = {}) {
  const messages = [];
  const waiters = new Set();
  let closed = false;
  const server = createServer(async (request, response) => {
    if (
      request.method !== "POST" ||
      request.url !== "/deliver" ||
      request.headers.authorization !== `Bearer ${token}`
    ) {
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
    let delivery;
    try {
      delivery = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    } catch {
      response.writeHead(400).end();
      return;
    }
    const address = delivery?.to;
    const code = delivery?.variables?.code;
    if (
      delivery?.template !== "institutional-email-ownership" ||
      !/^[^@]+@school\.test$/.test(address ?? "") ||
      !/^\d{6}$/.test(code ?? "")
    ) {
      response.writeHead(400).end();
      return;
    }
    const message = {
      to: address,
      code,
      challengeId: delivery?.metadata?.challenge_id,
    };
    messages.push(message);
    for (const waiter of waiters) waiter();
    response.writeHead(204).end();
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, "127.0.0.1", resolve);
  });

  return {
    url: `http://127.0.0.1:${server.address().port}/deliver`,
    token,
    async take(address, timeoutMs = 10000) {
      const find = () => {
        const index = messages.findIndex((message) => message.to === address);
        return index < 0 ? undefined : messages.splice(index, 1)[0];
      };
      const existing = find();
      if (existing) return existing;
      return new Promise((resolve, reject) => {
        const finish = () => {
          clearTimeout(timeout);
          waiters.delete(check);
          const message = find();
          if (message) resolve(message);
          else reject(new Error("local school email capture closed"));
        };
        const check = () => {
          const message = find();
          if (message) {
            clearTimeout(timeout);
            waiters.delete(check);
            resolve(message);
          }
        };
        const timeout = setTimeout(() => {
          waiters.delete(check);
          reject(new Error("local school email capture timed out"));
        }, timeoutMs);
        waiters.add(check);
        if (closed) finish();
      });
    },
    async close() {
      closed = true;
      for (const waiter of waiters) waiter();
      messages.fill(null);
      messages.length = 0;
      await new Promise((resolve, reject) =>
        server.close((error) => (error ? reject(error) : resolve())),
      );
    },
  };
}
