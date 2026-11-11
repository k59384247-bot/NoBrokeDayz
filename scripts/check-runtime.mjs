import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { setTimeout as delay } from "node:timers/promises";

const origin = "http://127.0.0.1:8787";
const checkId = randomUUID();
const server = spawn("npm", ["run", "preview", "--", "--port", "8787"], {
  stdio: ["ignore", "pipe", "pipe"],
  env: { ...process.env, NBD_RUNTIME_PROBE: "1" },
});
let logs = "";
server.stdout.on("data", (chunk) => {
  logs += chunk.toString();
});
server.stderr.on("data", (chunk) => {
  logs += chunk.toString();
});

async function request(path, init) {
  return fetch(new URL(path, origin), { redirect: "manual", ...init });
}

try {
  let ready = false;
  for (let attempt = 0; attempt < 40; attempt += 1) {
    if (server.exitCode !== null)
      throw new Error(`Workers preview exited early.\n${logs}`);
    try {
      const response = await request("/health");
      if (response.ok) {
        ready = true;
        break;
      }
    } catch {}
    await delay(500);
  }
  assert.ok(ready, `Workers preview did not become ready.\n${logs}`);

  const health = await request("/health");
  assert.equal(health.status, 200);
  const healthBody = await health.json();
  assert.deepEqual(healthBody, { status: "ok" });
  assert.match(health.headers.get("cache-control") ?? "", /no-store/);
  assert.doesNotMatch(
    JSON.stringify(healthBody),
    /secret|version|user|email|token/i,
  );
  console.log("PASS health: safe status only");

  const page = await request("/runtime-probe");
  assert.equal(page.status, 200);
  const html = await page.text();
  assert.match(html, /server-rendered-on-worker/);
  assert.match(html, /id="rendered-at"[^>]*dateTime="\d{4}-\d\d-\d\dT/);
  assert.match(html, /src="\/runtime-probe\.svg"/);
  console.log("PASS routing + server rendering + Next Image output");

  const cookieResponse = await request("/api/probe/cookie");
  assert.equal(cookieResponse.status, 200);
  const setCookie = cookieResponse.headers.get("set-cookie") ?? "";
  assert.match(setCookie, /nbd_probe=from-worker/);
  assert.match(setCookie, /httponly/i);
  assert.match(setCookie, /secure/i);
  assert.match(setCookie, /samesite=lax/i);
  const cookie = setCookie.split(";", 1)[0];
  const personalizedPage = await request("/runtime-probe", {
    headers: { cookie },
  });
  const personalizedHtml = await personalizedPage.text();
  assert.match(
    personalizedHtml,
    /<output id="cookie-value">from-worker<\/output>/,
  );
  assert.match(
    personalizedPage.headers.get("cache-control") ?? "",
    /private|no-store/i,
  );
  console.log("PASS cookie set/read + private SSR cache headers");

  const privateResponse = await request("/api/probe/private");
  assert.equal(privateResponse.status, 200);
  assert.match(privateResponse.headers.get("cache-control") ?? "", /private/);
  assert.match(privateResponse.headers.get("cache-control") ?? "", /no-store/);
  console.log("PASS private-response cache policy");

  const image = await request("/runtime-probe.svg");
  assert.equal(image.status, 200);
  assert.match(image.headers.get("content-type") ?? "", /image\/svg\+xml/);
  assert.match(await image.text(), /<svg/);
  console.log("PASS static asset + image bytes");

  const missing = await request("/not-a-route");
  assert.equal(missing.status, 404);
  console.log("PASS unmatched route returns 404");
  console.log(`PASS Workers runtime probe (check ${checkId})`);
} catch (error) {
  console.error(
    `FAIL Workers runtime probe (check ${checkId}): ${error instanceof Error ? error.message : "unknown error"}`,
  );
  if (logs) {
    const safeLogs = logs
      .split(/\r?\n/)
      .map((line) =>
        /anon[_ -]*key|service[_ -]*role[_ -]*key|publishable[_ -]*key|secret[_ -]*key|password|jwt[_ -]*secret|postgres(?:ql)?:\/\//i.test(
          line,
        )
          ? "[redacted sensitive preview output]"
          : line.replace(
              /\beyJ[A-Za-z0-9_-]{20,}(?:\.[A-Za-z0-9_-]+){0,2}\b/g,
              "[redacted token]",
            ),
      )
      .filter(Boolean)
      .slice(-30)
      .join("\n");
    console.error(safeLogs);
  }
  process.exitCode = 1;
} finally {
  server.kill("SIGTERM");
}
