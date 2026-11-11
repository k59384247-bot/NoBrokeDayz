import { spawn, spawnSync } from "node:child_process";
import { createHmac, randomInt, randomUUID } from "node:crypto";
import {
  chmodSync,
  closeSync,
  openSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { localSupabaseEnv } from "./local-supabase-env.mjs";

const root = resolve(import.meta.dirname, "..");
const cli = resolve(root, "node_modules/.bin/supabase");
const localHome = resolve(root, ".supabase-home");
const edgeEnvPath = resolve(localHome, "phase2-edge-functions.env");
const edgeLogPath = resolve(localHome, "phase2-edge-functions.log");
const env = localSupabaseEnv();
let stackMayBeRunning = false;
let fixturesReady = false;
let edgeServer;
let logFd;
let failed = false;
let capture;
let status;

function redact(value) {
  return value
    .replace(
      /\beyJ[A-Za-z0-9_-]{20,}(?:\.[A-Za-z0-9_-]+){0,2}\b/g,
      "[redacted JWT]",
    )
    .replace(
      /sb_(?:publishable|secret)_[A-Za-z0-9_-]+/g,
      "[redacted Supabase key]",
    )
    .replace(/v1,whsec_[A-Za-z0-9+/=]+/g, "[redacted hook secret]")
    .replace(/\b\d{6}\b/g, "[redacted OTP]")
    .replace(/\+?234[0-9 ()-]{8,}/g, "[synthetic phone]")
    .replace(/phase2-[\w-]+@identity\.test/gi, "[synthetic email]");
}

function run(command, args, label, runEnv = env) {
  const result = spawnSync(command, args, {
    cwd: root,
    env: runEnv,
    encoding: "utf8",
    maxBuffer: 8 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) {
    const output = redact(
      [result.stderr, result.stdout].filter(Boolean).join("\n"),
    )
      .split(/\r?\n/)
      .slice(-70)
      .join("\n");
    throw new Error(`${label} failed${output ? `:\n${output}` : ""}`);
  }
  return result.stdout;
}

function writeEdgeEnv() {
  const values = {
    SUPABASE_URL: status.env.API_URL,
    SUPABASE_ANON_KEY: status.env.ANON_KEY,
    SUPABASE_SERVICE_ROLE_KEY: status.env.SERVICE_ROLE_KEY,
    SUPABASE_AUTH_HOOK_SEND_SMS_SECRET: env.SUPABASE_AUTH_HOOK_SEND_SMS_SECRET,
    NBD_PHONE_SEND_LIMIT_HMAC_KEY: env.NBD_PHONE_SEND_LIMIT_HMAC_KEY,
    NBD_LOCAL_SMS_CAPTURE_URL: capture.url,
    NBD_LOCAL_SMS_CAPTURE_TOKEN: capture.token,
    NBD_SCHOOL_CHALLENGE_HMAC_KEY: env.NBD_SCHOOL_CHALLENGE_HMAC_KEY,
    NBD_SCHOOL_EMAIL_ADAPTER_KEY: env.NBD_SCHOOL_EMAIL_ADAPTER_KEY,
    NBD_SCHOOL_EMAIL_ADAPTER_URL: env.NBD_SCHOOL_EMAIL_ADAPTER_URL,
    NBD_VERIFICATION_DOWNLOAD_HMAC_KEY: env.NBD_VERIFICATION_DOWNLOAD_HMAC_KEY,
    NBD_PAYMENT_MODE: env.NBD_PAYMENT_MODE,
    NBD_SIMULATOR_URL: env.NBD_SIMULATOR_URL,
    NBD_SIMULATOR_MERCHANT_ID: env.NBD_SIMULATOR_MERCHANT_ID,
    NBD_SIMULATOR_REQUEST_SECRET: env.NBD_SIMULATOR_REQUEST_SECRET,
    NBD_SIMULATOR_WEBHOOK_SECRET: env.NBD_SIMULATOR_WEBHOOK_SECRET,
    NBD_PAYMENT_RUNNER_SECRET: env.NBD_PAYMENT_RUNNER_SECRET,
  };
  const contents = Object.entries(values)
    .map(([key, value]) => `${key}=${JSON.stringify(value)}`)
    .join("\n");
  writeFileSync(edgeEnvPath, `${contents}\n`, { mode: 0o600 });
  chmodSync(edgeEnvPath, 0o600);
}

async function waitForEdge() {
  const deadline = Date.now() + 45_000;
  while (Date.now() < deadline) {
    if (edgeServer.exitCode !== null)
      throw new Error("local Edge server exited before accepting requests");
    try {
      const response = await fetch(
        `${status.env.API_URL}/functions/v1/identity-staff`,
        {
          method: "POST",
          headers: {
            apikey: status.env.ANON_KEY,
            "content-type": "application/json",
          },
          body: "{}",
          signal: AbortSignal.timeout(2000),
        },
      );
      const body = await response.json().catch(() => null);
      if (
        response.status === 401 &&
        body?.error === "authentication_required"
      ) {
        console.log(
          "PASS Deno Edge handler is reachable through local API HTTP",
        );
        return;
      }
    } catch {
      // Wait for local API gateway and the Edge worker to become ready.
    }
    await delay(250);
  }
  throw new Error("local Deno Edge HTTP readiness check timed out");
}

async function verifyEdgeSmsQuota() {
  const credentials = JSON.parse(
    readFileSync(resolve(localHome, "step8-staff.json"), "utf8"),
  );
  const actorId = credentials.users.applicant?.id;
  if (!/^[0-9a-f-]{36}$/i.test(actorId ?? ""))
    throw new Error("local synthetic SMS actor is unavailable");
  const signingSecret =
    env.SUPABASE_AUTH_HOOK_SEND_SMS_SECRET.match(/^v1,whsec_(.+)$/)?.[1];
  if (!signingSecret) throw new Error("local Auth Hook signing key is invalid");
  const phone = `+2347000000${randomInt(100, 1000)}`;
  const pendingCodes = [];
  const requests = Array.from({ length: 6 }, () => {
    const eventId = randomUUID();
    const timestamp = String(Math.floor(Date.now() / 1000));
    const otp = String(randomInt(100000, 1000000));
    pendingCodes.push(otp);
    const body = JSON.stringify({
      user: { id: actorId },
      sms: { phone, otp },
    });
    const signature = createHmac("sha256", Buffer.from(signingSecret, "base64"))
      .update(`${eventId}.${timestamp}.${body}`)
      .digest("base64");
    return fetch(`${status.env.API_URL}/functions/v1/send-sms`, {
      method: "POST",
      headers: {
        apikey: status.env.ANON_KEY,
        "content-type": "application/json",
        "webhook-id": eventId,
        "webhook-timestamp": timestamp,
        "webhook-signature": `v1,${signature}`,
      },
      body,
    });
  });
  const responses = await Promise.all(requests);
  const responseBodies = await Promise.all(
    responses.map((response) => response.text()),
  );
  if (
    responses.filter((response) => response.status === 200).length !== 5 ||
    responses.filter((response) => response.status === 429).length !== 1 ||
    pendingCodes.some((code) =>
      responseBodies.some((body) => body.includes(code)),
    )
  ) {
    throw new Error(
      "Deno Edge SMS hook did not enforce its durable phone quota",
    );
  }
  for (let index = 0; index < 5; index++) {
    const delivery = await capture.take(phone, 5000, actorId);
    delivery.otp = "000000";
  }
  console.log(
    "PASS local Deno Send SMS Edge HTTP path reserves five sends and refuses the sixth",
  );
}

async function stopEdge() {
  if (!edgeServer || edgeServer.exitCode !== null) return;
  edgeServer.kill("SIGINT");
  await Promise.race([
    new Promise((resolve) => edgeServer.once("exit", resolve)),
    delay(8000),
  ]);
  if (edgeServer.exitCode === null) edgeServer.kill("SIGTERM");
}

function redactLogFile() {
  try {
    const contents = readFileSync(edgeLogPath, "utf8");
    writeFileSync(edgeLogPath, redact(contents), { mode: 0o600 });
    chmodSync(edgeLogPath, 0o600);
  } catch {
    failed = true;
  }
}

try {
  if (process.version !== "v22.23.2")
    throw new Error("use pinned Node 22.23.2 for local Edge tests");

  run(cli, ["stop"], "local Supabase stop before the Edge check");
  stackMayBeRunning = true;
  run(
    cli,
    [
      "start",
      "--runtime",
      "native",
      "--eager",
      "--exclude",
      "functions",
      "--frozen",
    ],
    "native loopback Supabase start",
  );
  run(cli, ["migration", "up", "--local"], "non-destructive local migrations");
  status = JSON.parse(
    run(cli, ["status", "--output-format", "json"], "local Supabase status"),
  );
  const api = new URL(status.env?.API_URL ?? "http://invalid.test");
  if (
    status.runtime !== "native" ||
    !["127.0.0.1", "localhost"].includes(api.hostname) ||
    api.port !== "54321" ||
    !status.env?.ANON_KEY ||
    !status.env?.SERVICE_ROLE_KEY
  ) {
    throw new Error(
      "Edge check requires the native local loopback Supabase stack",
    );
  }

  run(
    process.execPath,
    ["scripts/bootstrap-local-staff.mjs"],
    "synthetic local staff and AAL2 fixture setup",
  );
  fixturesReady = true;
  capture = await (
    await import("./test-support/local-sms-capture.mjs")
  ).startLocalSmsCapture();
  writeEdgeEnv();
  logFd = openSync(edgeLogPath, "w", 0o600);
  edgeServer = spawn(cli, ["functions", "serve", "--env-file", edgeEnvPath], {
    cwd: root,
    env,
    stdio: ["ignore", logFd, logFd],
  });
  await waitForEdge();
  await verifyEdgeSmsQuota();

  const output = run(
    process.execPath,
    ["--test", "tests/integration/identity/edge-runtime.test.mjs"],
    "actual local Edge HTTP and queue-visibility integration",
    { ...env, NBD_LOCAL_AUTH_STATUS_JSON: JSON.stringify(status) },
  );
  const safeOutput = redact(output.trim());
  if (safeOutput) console.log(safeOutput);
  console.log("PASS real local Auth session and Edge HTTP authorization cases");
} catch (error) {
  failed = true;
  console.error(
    `FAIL local Edge check: ${error instanceof Error ? error.message : "local check failed"}`,
  );
} finally {
  try {
    await stopEdge();
  } catch {
    failed = true;
    console.error("FAIL local Deno Edge server shutdown");
  }
  redactLogFile();
  if (logFd !== undefined) closeSync(logFd);
  await capture?.close().catch(() => {
    failed = true;
    console.error("FAIL local SMS capture shutdown");
  });
  try {
    rmSync(edgeEnvPath, { force: true });
    if (fixturesReady)
      run(
        process.execPath,
        ["scripts/bootstrap-local-staff.mjs"],
        "synthetic local staff grant restoration",
      );
    if (stackMayBeRunning)
      run(cli, ["stop"], "local Supabase stop after Edge tests");
    console.log("PASS local synthetic grants restored and Supabase stopped");
  } catch {
    failed = true;
    console.error("FAIL local Edge fixture or stack cleanup");
  }
}

if (failed) process.exitCode = 1;
