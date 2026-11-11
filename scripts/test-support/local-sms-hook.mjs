import { createServer } from "node:http";
import { createSendSmsHandler } from "../../supabase/functions/_shared/send-sms.mjs";
import { startLocalSmsCapture } from "./local-sms-capture.mjs";

// This signed delivery listener exists only inside the local test process; it cannot verify OTPs.
export async function startLocalSmsHook({
  url,
  hookSecret,
  reserveSend,
  failurePhones = [],
}) {
  const target = new URL(url);
  if (
    target.protocol !== "http:" ||
    !["127.0.0.1", "localhost"].includes(target.hostname) ||
    target.pathname !== "/send-sms"
  ) {
    throw new Error("local SMS hook must use the loopback test listener");
  }
  const handler = createSendSmsHandler({
    hookSecret,
    reserveSend,
    deliver: async (delivery) => {
      const response = await fetch(capture.url, {
        method: "POST",
        headers: {
          authorization: `Bearer ${capture.token}`,
          "content-type": "application/json",
        },
        body: JSON.stringify(delivery),
      });
      return response.ok;
    },
  });
  const capture = await startLocalSmsCapture({ failurePhones });
  const server = createServer(async (request, response) => {
    if (request.method !== "POST" || request.url !== target.pathname) {
      response.writeHead(404).end();
      return;
    }
    try {
      const chunks = [];
      let length = 0;
      for await (const chunk of request) {
        length += chunk.length;
        if (length > 16_384) {
          response.writeHead(413).end();
          return;
        }
        chunks.push(chunk);
      }
      const headers = new Headers();
      for (const [name, value] of Object.entries(request.headers)) {
        if (value !== undefined)
          headers.set(name, Array.isArray(value) ? value.join(" ") : value);
      }
      const result = await handler(
        new Request(target, {
          method: "POST",
          headers,
          body: Buffer.concat(chunks),
        }),
      );
      response.writeHead(result.status, Object.fromEntries(result.headers));
      response.end(await result.text());
    } catch {
      response.writeHead(503).end();
    }
  });
  try {
    await new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(Number(target.port), target.hostname, resolve);
    });
  } catch (error) {
    await capture.close();
    throw error;
  }
  return {
    take: (phone, userId) => capture.take(phone, 15_000, userId),
    async close() {
      await new Promise((resolve, reject) =>
        server.close((error) => (error ? reject(error) : resolve())),
      );
      await capture.close();
    },
  };
}
