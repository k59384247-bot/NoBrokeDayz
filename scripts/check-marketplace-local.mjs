import assert from "node:assert/strict";
import {
  createHash,
  createHmac,
  randomBytes,
  randomInt,
  randomUUID,
} from "node:crypto";
import {
  chmodSync,
  closeSync,
  openSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { createServer, request as httpRequest } from "node:http";
import { resolve } from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { setTimeout as delay } from "node:timers/promises";
import { createClient } from "@supabase/supabase-js";
import WebSocket from "ws";
import { createPaymentSimulator } from "../tests/fixtures/payments/simulator.mjs";
import { createPrivateRealtimeManager } from "../lib/realtime/private-hints.mjs";
import { runNotificationEmailDelivery } from "../supabase/functions/_shared/notification-email-runner.mjs";
import { createLocalEmailCaptureAdapter } from "../supabase/functions/_shared/local-email-capture.mjs";
import { localSupabaseEnv } from "./local-supabase-env.mjs";

const root = resolve(import.meta.dirname, "..");
const cli = resolve(root, "node_modules/.bin/supabase");
const localHome = resolve(root, ".supabase-home");
const envPath = resolve(localHome, "phase3-marketplace-edge.env");
const logPath = resolve(localHome, "phase3-marketplace-edge.log");
const merchantIdentity = "fake_nbd_local_merchant_v1";
const baseEnv = localSupabaseEnv({
  ...process.env,
  NBD_PAYMENT_MODE: "local_simulator",
  NBD_SIMULATOR_MERCHANT_ID: merchantIdentity,
});
let stackStarted = false;
let edge;
let logFd;
let simulator;
let smsCapture;
let emailCapture;
let failed = false;
let status;
let retainedAuditCheckpoint;
const activeRealtimeClients = new Set();
const activeRealtimeManagers = new Set();

function trackedRealtimeManager(client) {
  activeRealtimeClients.add(client);
  const manager = createPrivateRealtimeManager(client);
  activeRealtimeManagers.add(manager);
  return manager;
}

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
    .replace(/(postgres(?:ql)?:\/\/[^:/\s]+):[^@/\s]+@/g, "$1:[redacted]@")
    .replace(/v1,whsec_[A-Za-z0-9+/=]+/g, "[redacted hook secret]");
}

function run(command, args, label, runEnv = baseEnv, silent = false) {
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
      .slice(-50)
      .join("\n");
    throw new Error(`${label} failed${output ? `:\n${output}` : ""}`);
  }
  if (!silent) {
    const output = [result.stdout, result.stderr]
      .filter(Boolean)
      .join("\n")
      .trim();
    if (output) process.stdout.write(`${redact(output)}\n`);
  }
  return result.stdout;
}

function writeEdgeEnv() {
  const values = {
    SUPABASE_URL: status.env.API_URL,
    SUPABASE_ANON_KEY: status.env.ANON_KEY,
    SUPABASE_SERVICE_ROLE_KEY: status.env.SERVICE_ROLE_KEY,
    SUPABASE_AUTH_HOOK_SEND_SMS_SECRET:
      baseEnv.SUPABASE_AUTH_HOOK_SEND_SMS_SECRET,
    NBD_PHONE_SEND_LIMIT_HMAC_KEY: baseEnv.NBD_PHONE_SEND_LIMIT_HMAC_KEY,
    NBD_LOCAL_SMS_CAPTURE_URL: smsCapture.url,
    NBD_LOCAL_SMS_CAPTURE_TOKEN: smsCapture.token,
    NBD_SCHOOL_CHALLENGE_HMAC_KEY: baseEnv.NBD_SCHOOL_CHALLENGE_HMAC_KEY,
    NBD_SCHOOL_EMAIL_ADAPTER_KEY: baseEnv.NBD_SCHOOL_EMAIL_ADAPTER_KEY,
    NBD_SCHOOL_EMAIL_ADAPTER_URL: baseEnv.NBD_SCHOOL_EMAIL_ADAPTER_URL,
    NBD_VERIFICATION_DOWNLOAD_HMAC_KEY:
      baseEnv.NBD_VERIFICATION_DOWNLOAD_HMAC_KEY,
    NBD_CASE_UPLOAD_TOKEN_KEY: baseEnv.NBD_CASE_UPLOAD_TOKEN_KEY,
    NBD_PAYMENT_MODE: baseEnv.NBD_PAYMENT_MODE,
    NBD_SIMULATOR_URL: simulator.url,
    NBD_SIMULATOR_MERCHANT_ID: merchantIdentity,
    NBD_SIMULATOR_REQUEST_SECRET: baseEnv.NBD_SIMULATOR_REQUEST_SECRET,
    NBD_SIMULATOR_WEBHOOK_SECRET: baseEnv.NBD_SIMULATOR_WEBHOOK_SECRET,
    NBD_SIMULATOR_PAYOUT_FEE_KOBO: "20000",
    NBD_PAYMENT_RUNNER_SECRET: baseEnv.NBD_PAYMENT_RUNNER_SECRET,
  };
  writeFileSync(
    envPath,
    `${Object.entries(values)
      .map(([key, value]) => `${key}=${JSON.stringify(value)}`)
      .join("\n")}\n`,
    { mode: 0o600 },
  );
  chmodSync(envPath, 0o600);
}

async function setLocalRealtimePrivateOnly(apiUrl, signedAnonKey) {
  const url = new URL("/realtime/v1/api/tenants", apiUrl);
  const response = await fetch(url, {
    method: "POST",
    headers: {
      authorization: `Bearer ${signedAnonKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      tenant: {
        name: "realtime-dev",
        external_id: "realtime-dev",
        private_only: true,
      },
    }),
  });
  if (!response.ok)
    throw new Error(
      `local Realtime private-only setup returned ${response.status}`,
    );

  const verify = await fetch(
    new URL("/realtime/v1/api/tenants/realtime-dev", apiUrl),
    { headers: { authorization: `Bearer ${signedAnonKey}` } },
  );
  if (!verify.ok)
    throw new Error("local Realtime private-only setting could not be read");
  const result = await verify.json().catch(() => null);
  if (result?.data?.private_only !== true)
    throw new Error("local Realtime did not enter private-only mode");
}

async function waitForEdge() {
  const deadline = Date.now() + 120_000;
  while (Date.now() < deadline) {
    if (edge.exitCode !== null)
      throw new Error("local Edge server exited early");
    try {
      const response = await fetch(
        `${status.env.API_URL}/functions/v1/marketplace-command`,
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
        body?.error?.code === "authentication_required"
      )
        return;
    } catch {
      // Wait for the local API gateway and Edge worker to become ready.
    }
    await delay(250);
  }
  throw new Error("marketplace-command Edge HTTP readiness timed out");
}

async function adminCreateUser(
  config,
  { email, password, phone, staffPrincipalKind },
) {
  const response = await fetch(`${config.apiUrl}/auth/v1/admin/users`, {
    method: "POST",
    headers: {
      apikey: config.serviceKey,
      authorization: `Bearer ${config.serviceKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      email,
      password,
      email_confirm: true,
      ...(phone ? { phone, phone_confirm: true } : {}),
      app_metadata: {
        local_fixture_scope: "phase3-marketplace-edge-test",
        ...(staffPrincipalKind
          ? { staff_principal_kind: staffPrincipalKind }
          : {}),
      },
      user_metadata: { account_type: "partner" },
    }),
  });
  if (!response.ok)
    throw new Error("could not create isolated local test account");
  return response.json();
}

async function signIn(config, email, password) {
  const response = await fetch(
    `${config.apiUrl}/auth/v1/token?grant_type=password`,
    {
      method: "POST",
      headers: { apikey: config.anonKey, "content-type": "application/json" },
      body: JSON.stringify({ email, password }),
    },
  );
  const result = await response.json().catch(() => null);
  if (!response.ok || typeof result?.access_token !== "string")
    throw new Error("local synthetic account sign-in failed");
  return result.access_token;
}

async function edgeCall(config, token, body) {
  const response = await fetch(
    `${config.apiUrl}/functions/v1/marketplace-command`,
    {
      method: "POST",
      headers: {
        apikey: config.anonKey,
        ...(token ? { authorization: `Bearer ${token}` } : {}),
        "content-type": "application/json",
      },
      body: JSON.stringify(body),
    },
  );
  return {
    status: response.status,
    body: await response.json().catch(() => null),
    response,
  };
}

async function profileCommandCall(config, token, body) {
  const response = await fetch(
    `${config.apiUrl}/functions/v1/profile-command`,
    {
      method: "POST",
      headers: {
        apikey: config.anonKey,
        ...(token ? { authorization: `Bearer ${token}` } : {}),
        "content-type": "application/json",
      },
      body: JSON.stringify(body),
    },
  );
  return {
    status: response.status,
    body: await response.json().catch(() => null),
  };
}

async function reviewModerationCall(config, token, body) {
  const response = await fetch(
    `${config.apiUrl}/functions/v1/review-moderation`,
    {
      method: "POST",
      headers: {
        apikey: config.anonKey,
        ...(token ? { authorization: `Bearer ${token}` } : {}),
        "content-type": "application/json",
      },
      body: JSON.stringify(body),
    },
  );
  return {
    status: response.status,
    body: await response.json().catch(() => null),
  };
}

async function postWithDroppedAcknowledgement(config, token, body) {
  const upstreamUrl = new URL(
    `${config.apiUrl}/functions/v1/marketplace-command`,
  );
  let upstreamStatus = null;
  let droppedAfterResponse = false;
  const proxy = createServer((incoming, outgoing) => {
    const upstream = httpRequest(
      upstreamUrl,
      {
        method: "POST",
        headers: {
          apikey: config.anonKey,
          authorization: `Bearer ${token}`,
          "content-type": "application/json",
        },
      },
      (response) => {
        upstreamStatus = response.statusCode;
        response.resume();
        response.once("end", () => {
          droppedAfterResponse = true;
          outgoing.destroy();
        });
      },
    );
    upstream.once("error", () => outgoing.destroy());
    incoming.pipe(upstream);
  });

  await new Promise((resolveListen, rejectListen) => {
    proxy.once("error", rejectListen);
    proxy.listen(0, "127.0.0.1", resolveListen);
  });
  const address = proxy.address();
  try {
    let clientReceivedResponse = false;
    let clientError;
    try {
      const response = await fetch(
        `http://127.0.0.1:${address.port}/functions/v1/marketplace-command`,
        {
          method: "POST",
          headers: {
            apikey: config.anonKey,
            authorization: `Bearer ${token}`,
            "content-type": "application/json",
          },
          body: JSON.stringify(body),
        },
      );
      clientReceivedResponse = true;
      await response.arrayBuffer();
    } catch (error) {
      clientError = error;
    }
    assert.equal(clientReceivedResponse, false, "proxy must drop the response");
    assert.ok(clientError, "client must observe the lost acknowledgement");
    assert.equal(droppedAfterResponse, true);
    assert.equal(upstreamStatus, 201, "the server committed before the drop");
  } finally {
    await new Promise((resolveClose) => proxy.close(resolveClose));
  }
}

async function readCall(config, token, body) {
  const response = await fetch(
    `${config.apiUrl}/functions/v1/marketplace-read`,
    {
      method: "POST",
      headers: {
        apikey: config.anonKey,
        ...(token ? { authorization: `Bearer ${token}` } : {}),
        "content-type": "application/json",
      },
      body: JSON.stringify(body),
    },
  );
  return {
    status: response.status,
    body: await response.json().catch(() => null),
    response,
  };
}

async function caseReadCall(config, token, body) {
  const response = await fetch(`${config.apiUrl}/functions/v1/case-read`, {
    method: "POST",
    headers: {
      apikey: config.anonKey,
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
  return {
    status: response.status,
    body: await response.json().catch(() => null),
  };
}

async function caseCommandCall(config, token, body) {
  const response = await fetch(`${config.apiUrl}/functions/v1/case-command`, {
    method: "POST",
    headers: {
      apikey: config.anonKey,
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
  return {
    status: response.status,
    body: await response.json().catch(() => null),
  };
}

async function caseEvidenceCall(config, token, body, init = {}) {
  const isBytes = body instanceof Uint8Array;
  const response = await fetch(
    `${config.apiUrl}/functions/v1/case-evidence${init.download ? "/download" : ""}`,
    {
      method: init.method ?? "POST",
      headers: {
        apikey: config.anonKey,
        ...(token ? { authorization: `Bearer ${token}` } : {}),
        ...(isBytes
          ? {
              "content-type": init.contentType ?? "application/octet-stream",
              "x-upload-intent-id": init.intentId,
              "x-upload-token": init.uploadToken,
            }
          : { "content-type": "application/json" }),
      },
      body: isBytes ? body : JSON.stringify(body),
    },
  );
  return {
    status: response.status,
    body:
      init.download && response.ok
        ? null
        : await response.json().catch(() => null),
    bytes:
      init.download && response.ok
        ? new Uint8Array(await response.arrayBuffer())
        : null,
    response,
  };
}

async function walletCall(config, token, body) {
  const response = await fetch(`${config.apiUrl}/functions/v1/wallet-command`, {
    method: "POST",
    headers: {
      apikey: config.anonKey,
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
  return {
    status: response.status,
    body: await response.json().catch(() => null),
  };
}

async function walletReadCall(config, token, body) {
  const response = await fetch(`${config.apiUrl}/functions/v1/wallet-read`, {
    method: "POST",
    headers: {
      apikey: config.anonKey,
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
  return {
    status: response.status,
    body: await response.json().catch(() => null),
  };
}

async function notificationsReadCall(config, token, body) {
  const response = await fetch(
    `${config.apiUrl}/functions/v1/notifications-read`,
    {
      method: "POST",
      headers: {
        apikey: config.anonKey,
        ...(token ? { authorization: `Bearer ${token}` } : {}),
        "content-type": "application/json",
      },
      body: JSON.stringify(body),
    },
  );
  return {
    status: response.status,
    body: await response.json().catch(() => null),
  };
}

async function notificationDeliveryOpsCall(config, token, body) {
  const response = await fetch(
    `${config.apiUrl}/functions/v1/ops-notification-delivery`,
    {
      method: "POST",
      headers: {
        apikey: config.anonKey,
        ...(token ? { authorization: `Bearer ${token}` } : {}),
        "content-type": "application/json",
      },
      body: JSON.stringify(body),
    },
  );
  return {
    status: response.status,
    body: await response.json().catch(() => null),
  };
}

async function localServiceRpc(config, name, args) {
  const response = await fetch(`${config.apiUrl}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      apikey: config.serviceKey,
      authorization: `Bearer ${config.serviceKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(args),
  });
  const result = await response.json().catch(() => null);
  if (!response.ok)
    throw new Error(`local delivery RPC failed (${response.status})`);
  return result;
}

async function realtimeTopicCall(config, token, scope, resourceId) {
  const response = await fetch(`${config.apiUrl}/functions/v1/realtime-topic`, {
    method: "POST",
    headers: {
      apikey: config.anonKey,
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      scope,
      ...(resourceId ? { resource_id: resourceId } : {}),
    }),
  });
  return {
    status: response.status,
    body: await response.json().catch(() => null),
  };
}

async function signedInRealtimeClient(config, email, password) {
  const client = createClient(config.apiUrl, config.anonKey, {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
      detectSessionInUrl: false,
    },
    realtime: { timeout: 30_000, transport: WebSocket },
  });
  const realtimeEndpoint = new URL(client.realtime.endpointURL());
  console.log(
    `Realtime WebSocket endpoint: ${realtimeEndpoint.host}${realtimeEndpoint.pathname}`,
  );
  activeRealtimeClients.add(client);
  const { data, error } = await client.auth.signInWithPassword({
    email,
    password,
  });
  assert.ifError(error);
  assert.ok(data.session?.access_token);
  return { client, session: data.session };
}

async function signedInAal2RealtimeClient(config, staff) {
  const client = createClient(config.apiUrl, config.anonKey, {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
      detectSessionInUrl: false,
    },
    realtime: { timeout: 30_000, transport: WebSocket },
  });
  activeRealtimeClients.add(client);
  const signedIn = await client.auth.signInWithPassword({
    email: staff.email,
    password: staff.password,
  });
  assert.ifError(signedIn.error);
  const verified = await client.auth.mfa.challengeAndVerify({
    factorId: staff.totpFactorId,
    code: totp(staff.totpSecret),
  });
  assert.ifError(verified.error);
  assert.ok(verified.data.access_token);
  return {
    client,
    aal1Token: signedIn.data.session.access_token,
    session: verified.data,
  };
}

async function refreshRealtimeAal2Session(client, staff) {
  const signedIn = await client.auth.signInWithPassword({
    email: staff.email,
    password: staff.password,
  });
  assert.ifError(signedIn.error);
  const verified = await client.auth.mfa.challengeAndVerify({
    factorId: staff.totpFactorId,
    code: totp(staff.totpSecret),
  });
  assert.ifError(verified.error);
  assert.ok(verified.data.access_token);
  return {
    aal1Token: signedIn.data.session.access_token,
    session: verified.data,
  };
}

async function waitForCondition(predicate, message, timeoutMs = 8_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await delay(20);
  }
  assert.ok(predicate(), message);
}

function joinRawPrivateChannel(client, topic, event, isPrivate = true) {
  activeRealtimeClients.add(client);
  let resolveReady;
  let rejectReady;
  const ready = new Promise((resolve, reject) => {
    resolveReady = resolve;
    rejectReady = reject;
  });
  ready.catch(() => {});
  const events = [];
  const channel = client.channel(topic, { config: { private: isPrivate } });
  channel.on("broadcast", { event }, (message) => events.push(message));
  channel.subscribe((status, error) => {
    if (status === "SUBSCRIBED") resolveReady();
    else if (["CHANNEL_ERROR", "TIMED_OUT", "CLOSED"].includes(status))
      rejectReady(error ?? new Error(`realtime_${status.toLowerCase()}`));
  });
  return { channel, ready, events };
}

async function opsInspectionCall(config, token, body) {
  const response = await fetch(
    `${config.apiUrl}/functions/v1/ops-financial-inspection`,
    {
      method: "POST",
      headers: {
        apikey: config.anonKey,
        ...(token ? { authorization: `Bearer ${token}` } : {}),
        "content-type": "application/json",
      },
      body: JSON.stringify(body),
    },
  );
  return {
    status: response.status,
    body: await response.json().catch(() => null),
  };
}

function base32Decode(value) {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let bits = "";
  for (const character of value.toUpperCase().replace(/=+$/, "")) {
    const digit = alphabet.indexOf(character);
    if (digit < 0) throw new Error("invalid synthetic TOTP seed");
    bits += digit.toString(2).padStart(5, "0");
  }
  const bytes = [];
  for (let offset = 0; offset + 8 <= bits.length; offset += 8)
    bytes.push(Number.parseInt(bits.slice(offset, offset + 8), 2));
  return Buffer.from(bytes);
}

function totp(secret, now = Date.now()) {
  const counter = Math.floor(now / 30_000);
  const message = Buffer.alloc(8);
  message.writeBigUInt64BE(BigInt(counter));
  const digest = createHmac("sha1", base32Decode(secret))
    .update(message)
    .digest();
  const offset = digest[digest.length - 1] & 15;
  return String(
    (digest.readUInt32BE(offset) & 0x7fffffff) % 1_000_000,
  ).padStart(6, "0");
}

async function signInAtAal2(config, email, password) {
  const client = createClient(config.apiUrl, config.anonKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const signedIn = await client.auth.signInWithPassword({ email, password });
  assert.ifError(signedIn.error);
  assert.ok(signedIn.data.session);
  const enrolled = await client.auth.mfa.enroll({
    factorType: "totp",
    friendlyName: "synthetic-phase3-financial-inspector",
  });
  assert.ifError(enrolled.error);
  assert.ok(enrolled.data.totp.secret);
  const verified = await client.auth.mfa.challengeAndVerify({
    factorId: enrolled.data.id,
    code: totp(enrolled.data.totp.secret),
  });
  assert.ifError(verified.error);
  const assurance = await client.auth.mfa.getAuthenticatorAssuranceLevel();
  assert.ifError(assurance.error);
  assert.equal(assurance.data.currentLevel, "aal2");
  return {
    aal1Token: signedIn.data.session.access_token,
    aal2Token: verified.data.access_token,
    totpFactorId: enrolled.data.id,
    totpSecret: enrolled.data.totp.secret,
  };
}

async function refreshAal2(config, staff) {
  const client = createClient(config.apiUrl, config.anonKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const signedIn = await client.auth.signInWithPassword({
    email: staff.email,
    password: staff.password,
  });
  assert.ifError(signedIn.error);
  const verified = await client.auth.mfa.challengeAndVerify({
    factorId: staff.totpFactorId,
    code: totp(staff.totpSecret),
  });
  assert.ifError(verified.error);
  return {
    ...staff,
    aal1Token: signedIn.data.session.access_token,
    aal2Token: verified.data.access_token,
  };
}

async function runPaymentRunner(config) {
  const response = await fetch(
    `${config.apiUrl}/functions/v1/payment-operation-runner`,
    {
      method: "POST",
      headers: {
        apikey: config.anonKey,
        authorization: `Bearer ${baseEnv.NBD_PAYMENT_RUNNER_SECRET}`,
      },
    },
  );
  return {
    status: response.status,
    body: await response.json().catch(() => null),
  };
}

async function sendSimulatorEvent(config, event) {
  const response = await fetch(
    `${config.apiUrl}/functions/v1/payment-simulator-callback`,
    {
      method: "POST",
      headers: { apikey: config.anonKey, ...event.headers },
      body: event.rawBody,
    },
  );
  return {
    status: response.status,
    body: await response.json().catch(() => null),
  };
}

async function provideVerifiedPartner(user, phone) {
  if (!/^[0-9a-f-]{36}$/i.test(user.id) || !/^\+234[789][0-9]{9}$/.test(phone))
    throw new Error("synthetic identity fixture values are invalid");
  const identitySql = `
    insert into app_private.identity_accounts(
      user_id,account_type,age_confirmed_at,age_policy_version,account_status,
      verification_track,verification_status
    ) values('${user.id}'::uuid,'partner',pg_catalog.now(),'marketplace-edge-test-v1',
      'active','track_b_partner','approved')
    on conflict(user_id) do update set account_type='partner',age_confirmed_at=excluded.age_confirmed_at,
      account_status='active',verification_track='track_b_partner',verification_status='approved'
  `;
  const phoneSql = `
    insert into app_private.identity_phone_bindings(user_id,phone_e164,verified_at)
    select id,'${phone}',phone_confirmed_at from auth.users where id='${user.id}'::uuid
    on conflict(user_id) do update set phone_e164=excluded.phone_e164,verified_at=excluded.verified_at
  `;
  const capabilitySql = `
    insert into app_private.identity_capabilities(user_id,capability,source)
    values('${user.id}'::uuid,'can_hire','track_b_partner')
  `;
  for (const [sql, label] of [
    [identitySql, "synthetic verified identity"],
    [phoneSql, "synthetic verified phone"],
    [capabilitySql, "synthetic hiring capability"],
  ]) {
    run(
      cli,
      ["db", "query", "--local", "--output-format", "json", sql],
      label,
      baseEnv,
      true,
    );
  }
}

async function provideVerifiedStudent(user, phone) {
  if (!/^[0-9a-f-]{36}$/i.test(user.id) || !/^\+234[789][0-9]{9}$/.test(phone))
    throw new Error("synthetic student identity fixture values are invalid");
  const identitySql = `
    insert into app_private.identity_accounts(
      user_id,account_type,age_confirmed_at,age_policy_version,account_status,
      verification_track,verification_status
    ) values('${user.id}'::uuid,'student',pg_catalog.now(),'marketplace-edge-test-v1',
      'active','track_a_manual','approved')
    on conflict(user_id) do update set account_type='student',age_confirmed_at=excluded.age_confirmed_at,
      account_status='active',verification_track='track_a_manual',verification_status='approved'
  `;
  const phoneSql = `
    insert into app_private.identity_phone_bindings(user_id,phone_e164,verified_at)
    select id,'${phone}',phone_confirmed_at from auth.users where id='${user.id}'::uuid
    on conflict(user_id) do update set phone_e164=excluded.phone_e164,verified_at=excluded.verified_at
  `;
  const capabilitySql = `
    insert into app_private.identity_capabilities(user_id,capability,source)
    values('${user.id}'::uuid,'can_work','track_a_manual'),
      ('${user.id}'::uuid,'can_hire','track_a_manual')
    on conflict(user_id,capability) do update set source=excluded.source,revoked_at=null
  `;
  for (const [sql, label] of [
    [identitySql, "synthetic verified student identity"],
    [phoneSql, "synthetic verified student phone"],
    [capabilitySql, "synthetic student work capability"],
  ]) {
    run(
      cli,
      ["db", "query", "--local", "--output-format", "json", sql],
      label,
      baseEnv,
      true,
    );
  }
}

async function createVerifiedStudent(config, label) {
  const email = `phase3-${label}-${randomUUID()}@identity.test`;
  const password = randomBytes(32).toString("base64url");
  const phone = `+2348${String(randomInt(0, 1_000_000_000)).padStart(9, "0")}`;
  const user = await adminCreateUser(config, { email, password, phone });
  await provideVerifiedStudent(user, phone);
  return {
    user,
    email,
    password,
    token: await signIn(config, email, password),
  };
}

async function createFinancialInspector(config) {
  const email = `phase3-inspector-${randomUUID()}@identity.test`;
  const password = randomBytes(32).toString("base64url");
  const user = await adminCreateUser(config, { email, password });
  for (const [sql, label] of [
    [
      `insert into app_private.identity_accounts(user_id,account_type,age_confirmed_at,age_policy_version)
       values('${user.id}'::uuid,'student',pg_catalog.now(),'phase3-local-inspection-test')`,
      "create synthetic active ops identity",
    ],
    [
      `insert into app_private.staff_grants(user_id,capability,granted_by,reason)
       values('${user.id}'::uuid,'financial_inspect','${user.id}'::uuid,
         'Synthetic local read-only finance inspection grant for Step 9 journey.')`,
      "grant synthetic read-only financial inspection",
    ],
  ]) {
    run(
      cli,
      ["db", "query", "--local", "--output-format", "json", sql],
      label,
      baseEnv,
      true,
    );
  }
  return {
    user,
    password,
    ...(await signInAtAal2(config, email, password)),
  };
}

async function createDisputeReviewer(config, label = "reviewer") {
  const email = `phase4-${label}-${randomUUID()}@identity.test`;
  const password = randomBytes(32).toString("base64url");
  const user = await adminCreateUser(config, {
    email,
    password,
    staffPrincipalKind: "human",
  });
  for (const [sql, description] of [
    [
      `insert into app_private.identity_accounts(user_id,account_type,age_confirmed_at,age_policy_version)
       values('${user.id}'::uuid,'student',pg_catalog.now(),'phase4-local-case-review-test')`,
      "create synthetic case reviewer account",
    ],
    [
      `insert into app_private.staff_grants(user_id,capability,granted_by,reason)
       values('${user.id}'::uuid,'dispute_review','${user.id}'::uuid,
         'Synthetic local case reviewer grant for Phase 4 Step 4.')`,
      "grant synthetic case review capability",
    ],
  ])
    run(
      cli,
      ["db", "query", "--local", "--output-format", "json", sql],
      description,
      baseEnv,
      true,
    );
  return {
    user,
    email,
    password,
    ...(await signInAtAal2(config, email, password)),
  };
}

async function createCaseDecisionApprover(config) {
  const email = `phase4-decision-approver-${randomUUID()}@identity.test`;
  const password = randomBytes(32).toString("base64url");
  const user = await adminCreateUser(config, {
    email,
    password,
    staffPrincipalKind: "human",
  });
  for (const [sql, description] of [
    [
      `insert into app_private.identity_accounts(user_id,account_type,age_confirmed_at,age_policy_version)
       values('${user.id}'::uuid,'student',pg_catalog.now(),'phase4-local-decision-approver')`,
      "create synthetic case decision approver account",
    ],
    [
      `insert into app_private.staff_grants(user_id,capability,granted_by,reason)
       values('${user.id}'::uuid,'financial_approve','${user.id}'::uuid,
         'Synthetic local independent case decision approval grant for Step 5.')`,
      "grant synthetic case decision approval capability",
    ],
  ])
    run(
      cli,
      ["db", "query", "--local", "--output-format", "json", sql],
      description,
      baseEnv,
      true,
    );
  return {
    user,
    email,
    password,
    ...(await signInAtAal2(config, email, password)),
  };
}

async function createCaseSeniorSigner(config) {
  const email = `phase4-case-senior-${randomUUID()}@identity.test`;
  const password = randomBytes(32).toString("base64url");
  const user = await adminCreateUser(config, {
    email,
    password,
    staffPrincipalKind: "human",
  });
  for (const [sql, description] of [
    [
      `insert into app_private.identity_accounts(user_id,account_type,age_confirmed_at,age_policy_version)
       values('${user.id}'::uuid,'student',pg_catalog.now(),'phase4-local-case-senior')`,
      "create synthetic senior signer account",
    ],
    [
      `insert into app_private.staff_grants(user_id,capability,granted_by,reason)
       values('${user.id}'::uuid,'case_senior_signoff','${user.id}'::uuid,
         'Synthetic local senior sign-off grant for Phase 4 Step 10.')`,
      "grant synthetic case senior sign-off capability",
    ],
  ])
    run(
      cli,
      ["db", "query", "--local", "--output-format", "json", sql],
      description,
      baseEnv,
      true,
    );
  return {
    user,
    email,
    password,
    ...(await signInAtAal2(config, email, password)),
  };
}

async function readCaseDecisionFinancialSnapshot(caseId) {
  const sql = `select 'NBD_CASE_DECISION_STATE:' || p.status || ':' || a.work_state || ':' ||
    (select count(*)::text from app_private.assignment_completion_authorizations ca
      where ca.allocation_id=p.allocation_id) || ':' ||
    (select count(*)::text from app_private.allocation_refund_payables rp
      where rp.allocation_id=p.allocation_id) || ':' ||
    (select count(*)::text from app_private.ledger_journal_transactions)
    from app_private.assignment_cases c
    join app_private.principal_allocations p on p.allocation_id=c.allocation_id
    join app_private.assignments a on a.assignment_id=c.assignment_id
    where c.case_id='${caseId}'::uuid`;
  const result = await runDatabaseQueryInOwnProcess(sql);
  assert.equal(result.status, 0, result.output);
  const snapshot = result.output.match(
    /NBD_CASE_DECISION_STATE:([a-z_]+:[a-z_]+:[0-9]+:[0-9]+:[0-9]+)/,
  )?.[1];
  assert.ok(
    snapshot,
    `case decision financial snapshot missing: ${result.output}`,
  );
  return snapshot;
}

async function createUngrantedAal2Inspector(config) {
  const email = `phase3-ungranted-inspector-${randomUUID()}@identity.test`;
  const password = randomBytes(32).toString("base64url");
  const user = await adminCreateUser(config, { email, password });
  run(
    cli,
    [
      "db",
      "query",
      "--local",
      "--output-format",
      "json",
      `insert into app_private.identity_accounts(user_id,account_type,age_confirmed_at,age_policy_version)
       values('${user.id}'::uuid,'student',pg_catalog.now(),'phase3-local-inspection-test')`,
    ],
    "create synthetic ungranted inspector identity",
    baseEnv,
    true,
  );
  return {
    user,
    ...(await signInAtAal2(config, email, password)),
  };
}

function runDatabaseQueryInOwnProcess(sql) {
  return new Promise((resolve) => {
    const child = spawn(
      cli,
      ["db", "query", "--local", "--output-format", "json", sql],
      { cwd: root, env: baseEnv, stdio: ["ignore", "pipe", "pipe"] },
    );
    let output = "";
    child.stdout.setEncoding("utf8").on("data", (chunk) => (output += chunk));
    child.stderr.setEncoding("utf8").on("data", (chunk) => (output += chunk));
    child.once("error", () =>
      resolve({ status: 1, output: "database query failed" }),
    );
    child.once("close", (statusCode) =>
      resolve({ status: statusCode ?? 1, output: redact(output) }),
    );
  });
}

function startDatabaseQueryInOwnProcess(sql) {
  const child = spawn(
    cli,
    ["db", "query", "--local", "--output-format", "json", sql],
    { cwd: root, env: baseEnv, stdio: ["ignore", "pipe", "pipe"] },
  );
  let output = "";
  child.stdout.setEncoding("utf8").on("data", (chunk) => (output += chunk));
  child.stderr.setEncoding("utf8").on("data", (chunk) => (output += chunk));
  const done = new Promise((resolve) => {
    child.once("error", () =>
      resolve({ status: 1, output: "database query failed" }),
    );
    child.once("close", (statusCode) =>
      resolve({ status: statusCode ?? 1, output: redact(output) }),
    );
  });
  return { child, done };
}

async function readMarketplaceStateSnapshot(jobId) {
  const sql = `select 'NBD_SNAPSHOT:' ||
    (select count(*)::text || '/' || count(*) filter(where status='unassigned')::text || '/' ||
      count(*) filter(where status='assigned')::text
     from app_private.principal_allocations where job_id='${jobId}'::uuid) || ':' ||
    (select count(*)::text from app_private.assignments where job_id='${jobId}'::uuid) || ':' ||
    (select count(*)::text from app_private.ledger_journal_transactions) || ':' ||
    (select coalesce(sum(debit_kobo),0)::text || '/' || coalesce(sum(credit_kobo),0)::text
     from app_private.ledger_account_balances)`;
  const result = await runDatabaseQueryInOwnProcess(sql);
  assert.equal(result.status, 0, result.output);
  const snapshot = result.output.match(/NBD_SNAPSHOT:([0-9/:]+)/)?.[1];
  assert.ok(snapshot, `database snapshot marker missing: ${result.output}`);
  return snapshot;
}

async function settleCollection(config, funding) {
  const providerKey = funding.provider_reference.slice("sim-".length);
  simulator.simulateSettlement(providerKey, "succeeded");
  const response = await fetch(
    `${config.apiUrl}/functions/v1/payment-operation-runner`,
    {
      method: "POST",
      headers: {
        apikey: config.anonKey,
        authorization: `Bearer ${baseEnv.NBD_PAYMENT_RUNNER_SECRET}`,
      },
    },
  );
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.result.operation_status, "succeeded");
  assert.equal(body.result.funding_status, "succeeded");
  return body;
}

async function checkNotificationDelivery(
  config,
  caseReviewer,
  outOfScopeReviewer,
  readLocalRows,
) {
  assert.ok(emailCapture, "local transactional email capture is running");
  const emailAdapter = createLocalEmailCaptureAdapter(emailCapture);
  const deliveryClaim = async () =>
    localServiceRpc(config, "server_claim_notification_email_for_runner", {
      p_worker_id: randomUUID(),
      p_lease_seconds: 1,
    });
  const deliveryComplete = async (result) =>
    localServiceRpc(config, "server_complete_notification_email_for_runner", {
      p_delivery_id: result.deliveryId,
      p_lease_token: result.leaseToken,
      p_status: result.status,
      p_safe_error_code: result.safeErrorCode,
      p_provider_capture_id: result.providerCaptureId,
    });
  const deliveryAuthorize = (job) =>
    localServiceRpc(
      config,
      "server_authorize_notification_email_dispatch_for_runner",
      {
        p_delivery_id: job.delivery_id,
        p_lease_token: job.lease_token,
      },
    );
  const resolveLocalRecipient = async (recipientId) => {
    const response = await fetch(
      `${config.apiUrl}/auth/v1/admin/users/${recipientId}`,
      {
        headers: {
          apikey: config.serviceKey,
          authorization: `Bearer ${config.serviceKey}`,
        },
      },
    );
    if (!response.ok) throw new Error("synthetic recipient lookup unavailable");
    return (await response.json()).email;
  };
  let firstClaim;
  let crashAfterCapture = true;
  const runLocalDelivery = () =>
    runNotificationEmailDelivery({
      claim: async () => {
        const job = await deliveryClaim();
        firstClaim ??= job;
        return job;
      },
      complete: async (result) => {
        if (crashAfterCapture) {
          crashAfterCapture = false;
          throw new Error("simulated_crash_after_capture");
        }
        return deliveryComplete(result);
      },
      resolveRecipient: resolveLocalRecipient,
      authorizeDispatch: deliveryAuthorize,
      adapter: emailAdapter,
    });
  await assert.rejects(runLocalDelivery(), /simulated_crash_after_capture/);
  assert.equal(emailCapture.count(firstClaim.delivery_id), 1);
  run(
    cli,
    [
      "db",
      "query",
      "--local",
      "--output-format",
      "json",
      `update app_private.notification_email_deliveries
       set available_at=pg_catalog.now()+interval '1 day'
       where delivery_id<>'${firstClaim.delivery_id}'::uuid and status in ('pending','retry_wait','unknown')`,
    ],
    "isolate local delivery recovery claim",
    baseEnv,
    true,
  );
  await delay(1250);
  const recoveredDelivery = await runLocalDelivery();
  assert.equal(recoveredDelivery.status, "provider_accepted");
  assert.equal(emailCapture.count(firstClaim.delivery_id), 1);
  const recoveredRows = readLocalRows(
    `select n.notification_id::text,n.read_at::text,d.status,d.source_kind,
       d.source_event_id::text,d.recipient_id::text,d.notification_type,
       (select count(*)::integer from app_private.notification_email_deliveries x
        where x.recipient_id=d.recipient_id and x.source_kind=d.source_kind
          and x.source_event_id=d.source_event_id and x.channel='email'
          and x.notification_type=d.notification_type) as delivery_count
     from app_private.notification_email_deliveries d
     join app_private.in_app_notifications n using(notification_id)
     where d.delivery_id='${firstClaim.delivery_id}'::uuid`,
    "verify captured email delivery state and durable notice",
  );
  assert.equal(recoveredRows.length, 1);
  assert.equal(recoveredRows[0].status, "provider_accepted");
  assert.equal(Number(recoveredRows[0].delivery_count), 1);
  const sourceKind = recoveredRows[0].source_kind;
  const sourceEventId = recoveredRows[0].source_event_id;
  const recipientId = recoveredRows[0].recipient_id;
  const notificationType = recoveredRows[0].notification_type;
  const repeatSourceNotice = `do $$ declare d record; begin
    select * into d from app_private.notification_email_deliveries where delivery_id='${firstClaim.delivery_id}'::uuid;
    if d.source_kind='marketplace' then perform app_private.add_in_app_notification(d.source_event_id,d.recipient_id,d.notification_type);
    elsif d.source_kind='financial' then perform app_private.add_financial_in_app_notification(d.source_event_id,d.recipient_id,d.notification_type);
    else perform app_private.add_identity_in_app_notification(d.source_event_id,d.recipient_id,d.notification_type); end if;
  end $$`;
  run(
    cli,
    ["db", "query", "--local", "--output-format", "json", repeatSourceNotice],
    "repeat the same notice source event",
    baseEnv,
    true,
  );
  const repeatedCounts = readLocalRows(
    `select (select count(*)::integer from app_private.in_app_notifications n
       where n.recipient_id='${recipientId}'::uuid and n.notification_type='${notificationType}'
         and ((n.event_id='${sourceEventId}'::uuid and '${sourceKind}'='marketplace')
           or (n.financial_event_id='${sourceEventId}'::uuid and '${sourceKind}'='financial')
           or (n.identity_event_id='${sourceEventId}'::uuid and '${sourceKind}'='identity'))) as notice_count,
       (select count(*)::integer from app_private.notification_email_deliveries d
        where d.recipient_id='${recipientId}'::uuid and d.source_kind='${sourceKind}'
          and d.source_event_id='${sourceEventId}'::uuid and d.channel='email'
          and d.notification_type='${notificationType}') as delivery_count`,
    "verify repeated notice source remains deduplicated",
  );
  assert.equal(Number(repeatedCounts[0].notice_count), 1);
  assert.equal(Number(repeatedCounts[0].delivery_count), 1);

  run(
    cli,
    [
      "db",
      "query",
      "--local",
      "--output-format",
      "json",
      "update app_private.notification_email_deliveries set available_at=pg_catalog.now() where status='pending'",
    ],
    "make another local delivery available for ambiguity check",
    baseEnv,
    true,
  );
  const ambiguousResult = await runNotificationEmailDelivery({
    claim: deliveryClaim,
    complete: deliveryComplete,
    resolveRecipient: resolveLocalRecipient,
    authorizeDispatch: deliveryAuthorize,
    adapter: {
      lookup: async () => ({ status: "unknown" }),
      send: async () => {
        throw new Error("ambiguous lookup must not send");
      },
    },
  });
  assert.equal(ambiguousResult.status, "unknown");
  const deliveryStaff = await refreshAal2(config, caseReviewer);
  const ungrantedDeliveryStaff = await refreshAal2(config, outOfScopeReviewer);
  const aal1DeliveryView = await notificationDeliveryOpsCall(
    config,
    deliveryStaff.aal1Token,
    { action: "list" },
  );
  assert.equal(aal1DeliveryView.status, 403);
  const ungrantedDeliveryView = await notificationDeliveryOpsCall(
    config,
    ungrantedDeliveryStaff.aal2Token,
    { action: "list" },
  );
  assert.equal(ungrantedDeliveryView.status, 403);
  run(
    cli,
    [
      "db",
      "query",
      "--local",
      "--output-format",
      "json",
      `insert into app_private.staff_grants(user_id,capability,granted_by,reason)
       values('${caseReviewer.user.id}'::uuid,'notification_delivery_review','${caseReviewer.user.id}'::uuid,
         'Synthetic local delivery review capability for Step 4.')`,
    ],
    "grant synthetic delivery status review",
    baseEnv,
    true,
  );
  const deliveryAttention = await notificationDeliveryOpsCall(
    config,
    deliveryStaff.aal2Token,
    { action: "list" },
  );
  assert.equal(deliveryAttention.status, 200);
  const unknownDelivery = deliveryAttention.body.data.items.find(
    (item) => item.status === "unknown",
  );
  assert.ok(unknownDelivery);
  assert.equal(unknownDelivery.email, undefined);
  assert.equal(
    JSON.stringify(deliveryAttention.body).includes("provider_payload"),
    false,
  );
  const stillSavedNotice = readLocalRows(
    `select count(*)::integer as count from app_private.in_app_notifications
     where notification_id='${recoveredRows[0].notification_id}'::uuid`,
    "verify an email outcome cannot remove its in-app notice",
  );
  assert.equal(stillSavedNotice[0].count, 1);
  console.log(
    "PASS Step 4 delivery: loopback capture recovered a lost post-capture acknowledgement under the same ID, duplicate source intent stayed single, ambiguous sends stayed unsent, and only the AAL2 delivery grant saw the attention queue",
  );
}

async function checkJourney() {
  const config = {
    apiUrl: new URL(status.env.API_URL).origin,
    anonKey: status.env.ANON_KEY,
    serviceKey: status.env.SERVICE_ROLE_KEY,
  };
  const email = `phase3-marketplace-${randomUUID()}@identity.test`;
  const password = randomBytes(32).toString("base64url");
  const phone = `+2347${String(randomInt(0, 1_000_000_000)).padStart(9, "0")}`;
  const poster = await adminCreateUser(config, { email, password, phone });
  await provideVerifiedPartner(poster, phone);
  let posterToken = await signIn(config, email, password);

  const unverifiedEmail = `phase3-unverified-${randomUUID()}@identity.test`;
  const unverifiedPassword = randomBytes(32).toString("base64url");
  await adminCreateUser(config, {
    email: unverifiedEmail,
    password: unverifiedPassword,
  });
  let unverifiedToken = await signIn(
    config,
    unverifiedEmail,
    unverifiedPassword,
  );

  const studentEmail = `phase3-marketplace-student-${randomUUID()}@identity.test`;
  const studentPassword = randomBytes(32).toString("base64url");
  const studentPhone = `+2348${String(randomInt(0, 1_000_000_000)).padStart(9, "0")}`;
  const student = await adminCreateUser(config, {
    email: studentEmail,
    password: studentPassword,
    phone: studentPhone,
  });
  await provideVerifiedStudent(student, studentPhone);
  let studentToken = await signIn(config, studentEmail, studentPassword);

  const invalidAuth = await edgeCall(config, null, {
    action: "funding_status",
    job_id: randomUUID(),
  });
  assert.equal(invalidAuth.status, 401);
  const unverifiedDenied = await edgeCall(config, unverifiedToken, {
    action: "create_job_draft",
    idempotency_key: randomUUID(),
    terms: { title: "Synthetic campus job" },
  });
  assert.equal(unverifiedDenied.status, 403);

  const future = (days) =>
    new Date(Date.now() + days * 86_400_000).toISOString();
  const terms = {
    title: "Synthetic campus collection task",
    description:
      "A local-only synthetic task used to verify protected funding behavior.",
    category_slug: "errands",
    location_type: "on_campus",
    location_detail: "Student Centre",
    gross_per_worker_kobo: "300000",
    slot_count: 3,
    application_deadline_at: future(2),
    needed_by_at: future(3),
    start_requirements: "Meet at the main entrance",
  };
  let step3PosterToken = posterToken;
  let step3WorkerTokens = [];
  async function createFundedStep3Job(title, slotCount = 1) {
    const deadline = future(2);
    const jobTerms = {
      ...terms,
      title,
      gross_per_worker_kobo: "120000",
      slot_count: slotCount,
      application_deadline_at: deadline,
      needed_by_at: future(3),
    };
    const draft = await edgeCall(config, step3PosterToken, {
      action: "create_job_draft",
      idempotency_key: randomUUID(),
      terms: jobTerms,
    });
    assert.equal(draft.status, 201);
    const funding = await edgeCall(config, step3PosterToken, {
      action: "fund_job",
      job_id: draft.body.job.job_id,
      expected_terms_version: 1,
      idempotency_key: randomUUID(),
    });
    assert.equal(funding.status, 202);
    await settleCollection(config, funding.body);
    return draft.body.job.job_id;
  }
  function readLocalRows(sql, label) {
    const output = run(
      cli,
      ["db", "query", "--local", "--output-format", "json", sql],
      label,
      baseEnv,
      true,
    );
    return JSON.parse(output).rows;
  }
  const createKey = randomUUID();
  const forgedActor = await edgeCall(config, posterToken, {
    action: "create_job_draft",
    actor_id: randomUUID(),
    idempotency_key: createKey,
    terms,
  });
  assert.equal(forgedActor.status, 400);
  const created = await edgeCall(config, posterToken, {
    action: "create_job_draft",
    idempotency_key: createKey,
    terms,
  });
  assert.equal(created.status, 201);
  assert.equal(created.body.job.listing_state, "draft");
  assert.equal(created.body.job.gross_total_kobo, "900000");
  assert.equal(created.response.headers.get("cache-control"), "no-store");
  assert.ok(created.body.request_id);
  assert.equal("merchant_identity" in created.body.job, false);

  const alteredCreate = await edgeCall(config, posterToken, {
    action: "create_job_draft",
    idempotency_key: createKey,
    terms: { ...terms, title: "Different job title" },
  });
  assert.equal(alteredCreate.status, 409);

  const jobId = created.body.job.job_id;
  const updatedTerms = {
    ...terms,
    description:
      "An explicitly revised synthetic task description before funding.",
  };
  const updatedDraft = await edgeCall(config, posterToken, {
    action: "update_job_draft",
    job_id: jobId,
    expected_terms_version: 1,
    terms: updatedTerms,
    idempotency_key: randomUUID(),
  });
  assert.equal(updatedDraft.status, 200);
  assert.equal(updatedDraft.body.job.job_id, jobId);
  assert.equal(updatedDraft.body.job.terms_version, 2);
  assert.equal(updatedDraft.body.job.listing_state, "draft");
  assert.equal(updatedDraft.body.job.gross_total_kobo, "900000");
  const unrelatedDraftEdit = await edgeCall(config, studentToken, {
    action: "update_job_draft",
    job_id: jobId,
    expected_terms_version: 2,
    terms: { ...updatedTerms, title: "Unrelated synthetic edit" },
    idempotency_key: randomUUID(),
  });
  assert.equal(unrelatedDraftEdit.status, 404);
  assert.equal(unrelatedDraftEdit.body.error.code, "not_found");
  run(
    cli,
    [
      "db",
      "query",
      "--local",
      "--output-format",
      "json",
      `do $draft_history$ declare v_job uuid:='${jobId}'::uuid; begin
        if (select current_terms_version from app_private.jobs where job_id=v_job)<>2
          then raise exception 'draft_current_terms_version'; end if;
        if (select count(*) from app_private.job_terms_versions where job_id=v_job)<>2
          then raise exception 'draft_terms_history_count'; end if;
        if (select description from app_private.job_terms_versions where job_id=v_job and terms_version=1)
            <>'A local-only synthetic task used to verify protected funding behavior.'
          then raise exception 'original_draft_terms_rewritten'; end if;
        if (select description from app_private.job_terms_versions where job_id=v_job and terms_version=2)
            <>'An explicitly revised synthetic task description before funding.'
          then raise exception 'updated_draft_terms_missing'; end if;
      end $draft_history$`,
    ],
    "verify draft edit appended immutable terms version 2",
    baseEnv,
    true,
  );

  const fundingKey = randomUUID();
  simulator.programNext("collection", "pending");
  const funded = await edgeCall(config, posterToken, {
    action: "fund_job",
    job_id: jobId,
    expected_terms_version: 2,
    idempotency_key: fundingKey,
  });
  assert.equal(funded.status, 202);
  assert.equal(funded.body.listing_state, "awaiting_payment");
  assert.equal(funded.body.status, "pending");
  assert.equal(funded.body.expected_gross_kobo, "900000");
  assert.match(funded.body.provider_reference, /^sim-[0-9a-f-]{36}$/i);
  assert.equal(simulator.stats().createdCollections, 1);
  const pendingDraftEdit = await edgeCall(config, posterToken, {
    action: "update_job_draft",
    job_id: jobId,
    expected_terms_version: 2,
    terms: { ...updatedTerms, gross_per_worker_kobo: "350000" },
    idempotency_key: randomUUID(),
  });
  assert.equal(pendingDraftEdit.status, 409);
  assert.equal(pendingDraftEdit.body.error.code, "stale_state");

  const duplicateFunding = await edgeCall(config, posterToken, {
    action: "fund_job",
    job_id: jobId,
    expected_terms_version: 2,
    idempotency_key: fundingKey,
  });
  assert.equal(duplicateFunding.status, 202);
  assert.equal(simulator.stats().createdCollections, 1);
  const browserReturn = await edgeCall(config, posterToken, {
    action: "payment_return",
    provider_status: "succeeded",
    provider_reference: funded.body.provider_reference,
  });
  assert.equal(browserReturn.status, 400);
  const pendingStatus = await edgeCall(config, posterToken, {
    action: "funding_status",
    job_id: jobId,
  });
  assert.equal(pendingStatus.status, 200);
  assert.equal(pendingStatus.body.funding.status, "pending");
  assert.equal(pendingStatus.body.funding.listing_state, "awaiting_payment");

  const unverifiedStatus = await edgeCall(config, unverifiedToken, {
    action: "funding_status",
    job_id: jobId,
  });
  assert.equal(unverifiedStatus.status, 404);

  const providerKey = funded.body.provider_reference.slice("sim-".length);
  const settledCollection = simulator.simulateSettlement(
    providerKey,
    "succeeded",
  );
  const storedMerchant = readLocalRows(
    `select merchant_identity from app_private.provider_operations
     where provider_idempotency_key='${providerKey}'::uuid`,
    "trace stored synthetic collection merchant",
  );
  assert.equal(storedMerchant[0].merchant_identity, merchantIdentity);
  assert.equal(
    settledCollection.merchantIdentity,
    storedMerchant[0].merchant_identity,
  );
  const runnerResponse = await fetch(
    `${config.apiUrl}/functions/v1/payment-operation-runner`,
    {
      method: "POST",
      headers: {
        apikey: config.anonKey,
        authorization: `Bearer ${baseEnv.NBD_PAYMENT_RUNNER_SECRET}`,
      },
    },
  );
  assert.equal(runnerResponse.status, 200);
  const runnerBody = await runnerResponse.json();
  const collectionOperationState = readLocalRows(
    `select operation_type,status,safe_error_code,amount_kobo::text as amount_kobo,
      currency,merchant_identity,provider_operation_reference
     from app_private.provider_operations
     where operation_id='${runnerBody.result.operation_id}'::uuid`,
    "inspect safe synthetic collection result after local runner",
  );
  assert.equal(
    runnerBody.result.operation_status,
    "succeeded",
    JSON.stringify({ runnerBody, collectionOperationState }),
  );
  assert.equal(runnerBody.result.funding_status, "succeeded");

  const finalStatus = await edgeCall(config, posterToken, {
    action: "funding_status",
    job_id: jobId,
  });
  assert.equal(finalStatus.status, 200);
  assert.equal(finalStatus.body.funding.listing_state, "open");
  assert.equal(finalStatus.body.funding.status, "succeeded");
  assert.equal(finalStatus.body.funding.expected_gross_kobo, "900000");
  assert.equal("merchant_identity" in finalStatus.body.funding, false);
  const fundedDraftEdit = await edgeCall(config, posterToken, {
    action: "update_job_draft",
    job_id: jobId,
    expected_terms_version: 2,
    terms: { ...updatedTerms, gross_per_worker_kobo: "350000" },
    idempotency_key: randomUUID(),
  });
  assert.equal(fundedDraftEdit.status, 409);
  assert.equal(fundedDraftEdit.body.error.code, "stale_state");
  run(
    cli,
    [
      "db",
      "query",
      "--local",
      "--output-format",
      "json",
      `do $draft_history$ declare v_job uuid:='${jobId}'::uuid; begin
        if (select current_terms_version from app_private.jobs where job_id=v_job)<>2
          then raise exception 'funding_changed_terms_version'; end if;
        if (select count(*) from app_private.job_terms_versions where job_id=v_job)<>2
          then raise exception 'funding_changed_terms_history'; end if;
        if exists(select 1 from app_private.job_terms_versions where job_id=v_job
          and (terms_version=1 and description<>'A local-only synthetic task used to verify protected funding behavior.'
            or terms_version=2 and gross_per_worker_kobo<>300000))
          then raise exception 'funding_reinterpreted_terms'; end if;
      end $draft_history$`,
    ],
    "verify pending and funded draft edits left both immutable terms versions intact",
    baseEnv,
    true,
  );

  const unknownTerms = {
    ...terms,
    title: "Synthetic unknown funding edit guard",
    gross_per_worker_kobo: "100000",
    slot_count: 1,
    application_deadline_at: future(2),
    needed_by_at: future(3),
  };
  const unknownDraft = await edgeCall(config, posterToken, {
    action: "create_job_draft",
    idempotency_key: randomUUID(),
    terms: unknownTerms,
  });
  assert.equal(unknownDraft.status, 201);
  const unknownJobId = unknownDraft.body.job.job_id;
  simulator.programNext("collection", "unknown");
  const unknownFunding = await edgeCall(config, posterToken, {
    action: "fund_job",
    job_id: unknownJobId,
    expected_terms_version: 1,
    idempotency_key: randomUUID(),
  });
  assert.equal(unknownFunding.status, 202);
  assert.equal(unknownFunding.body.status, "unknown");
  assert.match(unknownFunding.body.provider_reference, /^sim-[0-9a-f-]{36}$/i);
  const unknownDraftEdit = await edgeCall(config, posterToken, {
    action: "update_job_draft",
    job_id: unknownJobId,
    expected_terms_version: 1,
    terms: { ...unknownTerms, gross_per_worker_kobo: "110000" },
    idempotency_key: randomUUID(),
  });
  assert.equal(unknownDraftEdit.status, 409);
  assert.equal(unknownDraftEdit.body.error.code, "stale_state");
  const unknownProviderKey = unknownFunding.body.provider_reference.slice(
    "sim-".length,
  );
  simulator.simulateSettlement(unknownProviderKey, "failed");
  const resolvedUnknownRunner = await runPaymentRunner(config);
  assert.equal(resolvedUnknownRunner.status, 200);
  assert.equal(resolvedUnknownRunner.body.result.operation_status, "failed");
  const resolvedUnknownStatus = await edgeCall(config, posterToken, {
    action: "funding_status",
    job_id: unknownJobId,
  });
  assert.equal(resolvedUnknownStatus.status, 200);
  assert.equal(resolvedUnknownStatus.body.funding.status, null);
  assert.equal(resolvedUnknownStatus.body.funding.listing_state, "draft");
  const resolvedFailureEdit = await edgeCall(config, posterToken, {
    action: "update_job_draft",
    job_id: unknownJobId,
    expected_terms_version: 1,
    terms: {
      ...unknownTerms,
      description:
        "Updated after the original result was authoritatively failed.",
    },
    idempotency_key: randomUUID(),
  });
  assert.equal(resolvedFailureEdit.status, 200);
  assert.equal(resolvedFailureEdit.body.job.terms_version, 2);
  run(
    cli,
    [
      "db",
      "query",
      "--local",
      "--output-format",
      "json",
      `do $unknown_draft$ declare v_job uuid:='${unknownJobId}'::uuid;
        v_intent uuid:='${unknownFunding.body.funding_intent_id}'::uuid; begin
        if (select current_terms_version from app_private.jobs where job_id=v_job)<>2
          then raise exception 'resolved_unknown_draft_terms_version'; end if;
        if (select count(*) from app_private.job_terms_versions where job_id=v_job)<>2
          then raise exception 'resolved_unknown_draft_terms_history'; end if;
        if (select description from app_private.job_terms_versions where job_id=v_job and terms_version=1)
            <>'A local-only synthetic task used to verify protected funding behavior.'
          then raise exception 'resolved_unknown_rewrote_original_terms'; end if;
        if (select status from app_private.funding_intents where intent_id=v_intent)<>'failed'
          then raise exception 'unknown_lookup_did_not_resolve_funding'; end if;
        if (select count(*) from app_private.funding_attempts where funding_intent_id=v_intent and status='failed')<>1
          then raise exception 'unknown_lookup_did_not_resolve_attempt'; end if;
        if (select count(*) from app_private.provider_operations where funding_intent_id=v_intent and status='failed')<>1
          then raise exception 'unknown_lookup_did_not_resolve_provider_operation'; end if;
        if exists(select 1 from app_private.principal_allocations where job_id=v_job)
          then raise exception 'unknown_funding_created_allocation'; end if;
      end $unknown_draft$`,
    ],
    "verify resolved unknown collection did not allocate principal or reinterpret terms",
    baseEnv,
    true,
  );
  console.log(
    "PASS update_job_draft Edge HTTP: owner edit appends version 2; unrelated, pending, unknown and funded edits are denied without rewriting history",
  );

  const applicationKey = randomUUID();
  const application = await edgeCall(config, studentToken, {
    action: "apply_to_job",
    job_id: jobId,
    note: "I can help after my lecture.",
    idempotency_key: applicationKey,
  });
  assert.equal(application.status, 201);
  assert.equal(application.body.application.state, "applied");
  assert.ok(application.body.application.thread_id);
  const duplicateApplication = await edgeCall(config, studentToken, {
    action: "apply_to_job",
    job_id: jobId,
    note: "I can help after my lecture.",
    idempotency_key: applicationKey,
  });
  assert.equal(duplicateApplication.status, 201);
  assert.equal(
    duplicateApplication.body.application.application_id,
    application.body.application.application_id,
  );
  const appliedAgain = await edgeCall(config, studentToken, {
    action: "apply_to_job",
    job_id: jobId,
    idempotency_key: randomUUID(),
  });
  assert.equal(appliedAgain.status, 409);
  assert.equal(appliedAgain.body.error.code, "application_already_exists");

  const workerApplications = await readCall(config, studentToken, {
    action: "my_applications",
  });
  assert.equal(workerApplications.status, 200);
  assert.equal(workerApplications.body.data.items.length, 1);
  assert.equal(
    workerApplications.body.data.items[0].application_id,
    application.body.application.application_id,
  );
  assert.equal("worker_id" in workerApplications.body.data.items[0], false);
  const posterApplications = await readCall(config, posterToken, {
    action: "job_applications",
    job_id: jobId,
  });
  assert.equal(posterApplications.status, 200);
  assert.equal(posterApplications.body.data.items.length, 1);
  assert.equal(
    posterApplications.body.data.items[0].applicant_summary.display_name,
    null,
  );
  assert.equal("worker_id" in posterApplications.body.data.items[0], false);

  const messageId = randomUUID();
  const firstMessage = await edgeCall(config, studentToken, {
    action: "send_application_message",
    thread_id: application.body.application.thread_id,
    client_message_id: messageId,
    body: "I am available after 2 pm.",
  });
  assert.equal(firstMessage.status, 201);
  assert.equal(firstMessage.body.message.sequence, "1");
  const messageRetry = await edgeCall(config, studentToken, {
    action: "send_application_message",
    thread_id: application.body.application.thread_id,
    client_message_id: messageId,
    body: "I am available after 2 pm.",
  });
  assert.equal(messageRetry.status, 201);
  assert.equal(messageRetry.body.message.replayed, true);
  const alteredMessageRetry = await edgeCall(config, studentToken, {
    action: "send_application_message",
    thread_id: application.body.application.thread_id,
    client_message_id: messageId,
    body: "I am available after 4 pm.",
  });
  assert.equal(alteredMessageRetry.status, 409);
  assert.equal(alteredMessageRetry.body.error.code, "idempotency_conflict");
  const posterMessage = await edgeCall(config, posterToken, {
    action: "send_application_message",
    thread_id: application.body.application.thread_id,
    client_message_id: randomUUID(),
    body: "Meet at the student centre.",
  });
  assert.equal(posterMessage.status, 201);
  assert.equal(posterMessage.body.message.sequence, "2");
  const lostAckClientMessageId = randomUUID();
  await postWithDroppedAcknowledgement(config, studentToken, {
    action: "send_application_message",
    thread_id: application.body.application.thread_id,
    client_message_id: lostAckClientMessageId,
    body: "Saved before the acknowledgement was lost.",
  });
  const recoveredAck = await edgeCall(config, studentToken, {
    action: "send_application_message",
    thread_id: application.body.application.thread_id,
    client_message_id: lostAckClientMessageId,
    body: "Saved before the acknowledgement was lost.",
  });
  assert.equal(recoveredAck.status, 201);
  assert.equal(recoveredAck.body.message.sequence, "3");
  assert.equal(recoveredAck.body.message.replayed, true);
  const lostAckRows = readLocalRows(
    `select count(*)::integer as count from app_private.thread_messages
     where sender_id='${student.id}'::uuid
       and client_message_id='${lostAckClientMessageId}'::uuid`,
    "verify lost message acknowledgement retries the committed row",
  );
  assert.equal(Number(lostAckRows[0].count), 1);
  console.log(
    "PASS message retry recovered one saved row after the proxy dropped the committed HTTP acknowledgement",
  );
  for (let index = 0; index < 48; index += 1) {
    const pagedMessage = await edgeCall(config, studentToken, {
      action: "send_application_message",
      thread_id: application.body.application.thread_id,
      client_message_id: randomUUID(),
      body: `Replay boundary message ${index + 1}.`,
    });
    assert.equal(pagedMessage.status, 201);
    assert.equal(pagedMessage.body.message.sequence, String(index + 4));
  }
  const privateThread = await readCall(config, studentToken, {
    action: "application_thread",
    application_id: application.body.application.application_id,
  });
  assert.equal(privateThread.status, 200);
  assert.equal(privateThread.body.data.thread.messages.length, 50);
  assert.equal(privateThread.body.data.thread.last_sequence, "51");
  assert.equal(privateThread.body.data.thread.messages.at(-1).sequence, "50");
  assert.equal(privateThread.body.data.next_after_sequence, "50");
  assert.equal(privateThread.body.data.thread.unread_count, "1");
  assert.equal(
    "sender_id" in privateThread.body.data.thread.messages[0],
    false,
  );
  const replayPageTwo = await readCall(config, studentToken, {
    action: "application_thread",
    application_id: application.body.application.application_id,
    after_sequence: privateThread.body.data.next_after_sequence,
  });
  assert.equal(replayPageTwo.status, 200);
  assert.equal(replayPageTwo.body.data.thread.messages.length, 1);
  assert.equal(replayPageTwo.body.data.thread.messages[0].sequence, "51");
  assert.equal(replayPageTwo.body.data.next_after_sequence, null);
  const posterThread = await readCall(config, posterToken, {
    action: "application_thread",
    application_id: application.body.application.application_id,
  });
  assert.equal(posterThread.status, 200);
  assert.equal(posterThread.body.data.thread.unread_count, "50");
  const rivalThread = await readCall(config, unverifiedToken, {
    action: "application_thread",
    application_id: application.body.application.application_id,
  });
  assert.equal(rivalThread.status, 404);
  const readRace = await Promise.all([
    edgeCall(config, posterToken, {
      action: "mark_thread_read",
      thread_id: application.body.application.thread_id,
      last_read_sequence: "51",
    }),
    edgeCall(config, posterToken, {
      action: "mark_thread_read",
      thread_id: application.body.application.thread_id,
      last_read_sequence: "1",
    }),
  ]);
  assert.equal(readRace[0].status, 200);
  assert.equal(readRace[1].status, 200);
  const backwardRead = await edgeCall(config, posterToken, {
    action: "mark_thread_read",
    thread_id: application.body.application.thread_id,
    last_read_sequence: "1",
  });
  assert.equal(backwardRead.status, 200);
  assert.equal(backwardRead.body.thread_read.last_read_sequence, "51");
  const readAfterRace = await readCall(config, posterToken, {
    action: "application_thread",
    application_id: application.body.application.application_id,
  });
  assert.equal(readAfterRace.body.data.thread.read_cursor, "51");
  assert.equal(readAfterRace.body.data.thread.unread_count, "0");

  posterToken = await signIn(config, email, password);
  studentToken = await signIn(config, studentEmail, studentPassword);
  unverifiedToken = await signIn(config, unverifiedEmail, unverifiedPassword);
  const posterRealtime = await signedInRealtimeClient(config, email, password);
  const studentRealtime = await signedInRealtimeClient(
    config,
    studentEmail,
    studentPassword,
  );
  const unrelatedRealtime = await signedInRealtimeClient(
    config,
    unverifiedEmail,
    unverifiedPassword,
  );
  const realtimeTopics = {
    posterThread: await realtimeTopicCall(
      config,
      posterRealtime.session.access_token,
      "thread",
      application.body.application.application_id,
    ),
    studentThread: await realtimeTopicCall(
      config,
      studentRealtime.session.access_token,
      "thread",
      application.body.application.application_id,
    ),
    posterNotifications: await realtimeTopicCall(
      config,
      posterRealtime.session.access_token,
      "notifications",
    ),
    studentNotifications: await realtimeTopicCall(
      config,
      studentRealtime.session.access_token,
      "notifications",
    ),
  };
  for (const topic of Object.values(realtimeTopics)) {
    assert.equal(topic.status, 200, JSON.stringify(topic.body));
    assert.equal(topic.body.data.private, true);
  }
  const posterThreadTopic = realtimeTopics.posterThread.body.data;
  const studentThreadTopic = realtimeTopics.studentThread.body.data;
  const posterNotificationTopic = realtimeTopics.posterNotifications.body.data;
  const studentNotificationTopic =
    realtimeTopics.studentNotifications.body.data;

  for (const [client, topic] of [
    [posterRealtime.client, posterNotificationTopic.topic],
    [studentRealtime.client, studentNotificationTopic.topic],
  ]) {
    const { data, error } = await client.rpc("can_receive_realtime_hint", {
      p_topic: topic,
    });
    assert.ifError(error);
    assert.equal(data, true);
  }
  console.log(
    "PASS current actor JWTs authorize only their notification topics",
  );

  await posterRealtime.client.realtime.setAuth(
    posterRealtime.session.access_token,
  );
  await studentRealtime.client.realtime.setAuth(
    studentRealtime.session.access_token,
  );
  await unrelatedRealtime.client.realtime.setAuth(
    unrelatedRealtime.session.access_token,
  );

  const managers = {
    poster: trackedRealtimeManager(posterRealtime.client),
    student: trackedRealtimeManager(studentRealtime.client),
  };
  const hints = {
    posterThread: [],
    studentThread: [],
    posterNotifications: [],
    studentNotifications: [],
  };
  const posterNoticeSubscription = await managers.poster.subscribeInvalidation({
    key: "notifications",
    topic: posterNotificationTopic.topic,
    event: "notifications.changed",
    accessToken: posterRealtime.session.access_token,
    onInvalidate: (hint) => hints.posterNotifications.push(hint),
  });
  const studentNoticeSubscription =
    await managers.student.subscribeInvalidation({
      key: "notifications",
      topic: studentNotificationTopic.topic,
      event: "notifications.changed",
      accessToken: studentRealtime.session.access_token,
      onInvalidate: (hint) => hints.studentNotifications.push(hint),
    });
  await Promise.all([
    posterNoticeSubscription.ready,
    studentNoticeSubscription.ready,
  ]);
  console.log("PASS private participant notification topics joined");

  const unrelatedJoin = joinRawPrivateChannel(
    unrelatedRealtime.client,
    studentThreadTopic.topic,
    "thread.changed",
  );
  await assert.rejects(unrelatedJoin.ready);
  await unrelatedRealtime.client.removeChannel(unrelatedJoin.channel);
  const crossUserNoticeJoin = joinRawPrivateChannel(
    posterRealtime.client,
    studentNotificationTopic.topic,
    "notifications.changed",
  );
  await assert.rejects(crossUserNoticeJoin.ready);
  await posterRealtime.client.removeChannel(crossUserNoticeJoin.channel);
  const publicJoin = joinRawPrivateChannel(
    unrelatedRealtime.client,
    "nbd:public-channel-probe",
    "probe",
    false,
  );
  await assert.rejects(publicJoin.ready);
  await unrelatedRealtime.client.removeChannel(publicJoin.channel);

  let raceMessage = null;
  let replaySavedCursor = "0";
  let injectedDuringReplay = false;
  const studentThreadSubscription =
    await managers.student.subscribeApplicationThread({
      topic: studentThreadTopic.topic,
      accessToken: studentRealtime.session.access_token,
      afterSequence: "0",
      loadPage: async (afterSequence) => {
        const page = await readCall(config, studentToken, {
          action: "application_thread",
          application_id: application.body.application.application_id,
          after_sequence: afterSequence,
        });
        assert.equal(page.status, 200, JSON.stringify(page.body));
        if (!injectedDuringReplay) {
          injectedDuringReplay = true;
          raceMessage = await edgeCall(config, posterToken, {
            action: "send_application_message",
            thread_id: application.body.application.thread_id,
            client_message_id: randomUUID(),
            body: "Saved while the private replay was starting.",
          });
          assert.equal(raceMessage.status, 201);
          assert.equal(raceMessage.body.message.sequence, "52");
        }
        return page.body.data;
      },
      onSnapshot: ({ lastSavedSequence }) => {
        replaySavedCursor = lastSavedSequence;
      },
      onHint: (hint) =>
        hints.studentThread.push({ ...hint, receivedAt: Date.now() }),
    });
  await studentThreadSubscription.ready;
  console.log("PASS private applicant thread joined and replay completed");
  const posterThreadSubscription =
    await managers.poster.subscribeApplicationThread({
      topic: posterThreadTopic.topic,
      accessToken: posterRealtime.session.access_token,
      afterSequence: "51",
      loadPage: async (afterSequence) => {
        const page = await readCall(config, posterToken, {
          action: "application_thread",
          application_id: application.body.application.application_id,
          after_sequence: afterSequence,
        });
        assert.equal(page.status, 200, JSON.stringify(page.body));
        return page.body.data;
      },
      onSnapshot() {},
      onHint: (hint) =>
        hints.posterThread.push({ ...hint, receivedAt: Date.now() }),
    });
  await posterThreadSubscription.ready;
  console.log("PASS private poster thread joined and replay completed");
  await waitForCondition(
    () => hints.studentNotifications.length === 1,
    "poster message should notify only the applicant's private notice channel",
  );
  assert.equal(hints.posterNotifications.length, 0);
  assert.equal(studentThreadSubscription.cursor, "52");
  assert.equal(replaySavedCursor, "52");
  assert.equal(
    studentThreadSubscription.messages.filter((row) => row.sequence === "52")
      .length,
    1,
  );

  const writerProbe = await signedInRealtimeClient(
    config,
    studentEmail,
    studentPassword,
  );
  await writerProbe.client.realtime.setAuth(writerProbe.session.access_token);
  const writer = writerProbe.client.channel(studentThreadTopic.topic, {
    config: { private: true, broadcast: { ack: true } },
  });
  await new Promise((resolveReady, rejectReady) => {
    writer.subscribe((status, error) => {
      if (status === "SUBSCRIBED") resolveReady();
      else if (status === "CHANNEL_ERROR" || status === "TIMED_OUT")
        rejectReady(error ?? new Error("writer_channel_denied"));
    });
  });
  const forgedMessageHint = await writer.send(
    {
      type: "broadcast",
      event: "thread.changed",
      payload: { kind: "invalidate", body: "forged message" },
    },
    { timeout: 3_000 },
  );
  const forgedReadHint = await writer.send(
    {
      type: "broadcast",
      event: "thread.read_changed",
      payload: { kind: "invalidate", last_read_sequence: "999" },
    },
    { timeout: 3_000 },
  );
  assert.equal(forgedMessageHint, "error");
  assert.equal(forgedReadHint, "error");
  await writerProbe.client.removeChannel(writer);
  const unchangedAfterForgedHints = await readCall(config, studentToken, {
    action: "application_thread",
    application_id: application.body.application.application_id,
    after_sequence: "52",
  });
  assert.equal(unchangedAfterForgedHints.status, 200);
  assert.equal(unchangedAfterForgedHints.body.data.thread.read_cursor, "0");
  assert.equal(unchangedAfterForgedHints.body.data.thread.messages.length, 0);

  const latencySamples = [];
  for (let index = 0; index < 3; index += 1) {
    const priorHints = hints.studentThread.length;
    const sent = await edgeCall(config, posterToken, {
      action: "send_application_message",
      thread_id: application.body.application.thread_id,
      client_message_id: randomUUID(),
      body: `Local Realtime latency sample ${index + 1}.`,
    });
    assert.equal(sent.status, 201);
    await waitForCondition(
      () => hints.studentThread.length > priorHints,
      "saved message invalidation should reach the connected participant",
    );
    const received = hints.studentThread
      .slice(priorHints)
      .find((hint) => hint.event === "thread.changed");
    assert.ok(received);
    latencySamples.push(
      received.receivedAt - Date.parse(sent.body.message.created_at),
    );
  }
  assert.ok(
    latencySamples.every((latency) => Number.isFinite(latency) && latency >= 0),
  );

  const studentSent = await edgeCall(config, studentToken, {
    action: "send_application_message",
    thread_id: application.body.application.thread_id,
    client_message_id: randomUUID(),
    body: "The applicant reply reaches the poster through saved history.",
  });
  assert.equal(studentSent.status, 201);
  await waitForCondition(
    () => hints.posterNotifications.length === 1,
    "applicant message should notify only the poster's private notice channel",
  );
  assert.equal(hints.studentNotifications.length, 4);
  const readHintCount = hints.posterThread.filter(
    (hint) => hint.event === "thread.read_changed",
  ).length;
  const studentRead = await edgeCall(config, studentToken, {
    action: "mark_thread_read",
    thread_id: application.body.application.thread_id,
    last_read_sequence: studentSent.body.message.sequence,
  });
  assert.equal(studentRead.status, 200);
  await waitForCondition(
    () =>
      hints.posterThread.filter((hint) => hint.event === "thread.read_changed")
        .length > readHintCount,
    "read-cursor change should invalidate the other permitted participant's view",
  );
  const studentNoticeList = await notificationsReadCall(config, studentToken, {
    action: "list",
  });
  assert.equal(studentNoticeList.status, 200);
  const unreadMessageNotice = studentNoticeList.body.data.notifications.find(
    (notice) =>
      notice.notification_type === "new_message" && notice.read_at === null,
  );
  assert.ok(unreadMessageNotice);
  const studentNoticeHintCount = hints.studentNotifications.length;
  const markedStudentNotice = await notificationsReadCall(
    config,
    studentToken,
    {
      action: "mark_read",
      notification_id: unreadMessageNotice.notification_id,
    },
  );
  assert.equal(markedStudentNotice.status, 200);
  assert.ok(markedStudentNotice.body.data.read_at);
  await waitForCondition(
    () => hints.studentNotifications.length > studentNoticeHintCount,
    "first notice-read update should invalidate the recipient's private notice view",
  );
  const studentNoticeHintCountAfterRead = hints.studentNotifications.length;
  const repeatedNoticeRead = await notificationsReadCall(config, studentToken, {
    action: "mark_read",
    notification_id: unreadMessageNotice.notification_id,
  });
  assert.equal(repeatedNoticeRead.status, 200);
  await delay(200);
  assert.equal(
    hints.studentNotifications.length,
    studentNoticeHintCountAfterRead,
  );
  assert.ok(
    hints.studentThread.every(
      (hint) => JSON.stringify(hint.payload) === '{"kind":"invalidate"}',
    ),
  );
  assert.ok(
    hints.studentNotifications.every(
      (hint) => JSON.stringify(hint.payload) === '{"kind":"invalidate"}',
    ),
  );

  const posterThreadHintsAtLogout = hints.posterThread.length;
  const posterNoticeHintsAtLogout = hints.posterNotifications.length;
  const { error: posterLogoutError } =
    await posterRealtime.client.auth.signOut();
  assert.ifError(posterLogoutError);
  await waitForCondition(
    () => posterThreadSubscription.closed && posterNoticeSubscription.closed,
    "logout should remove all of the poster's Realtime channels",
  );
  const afterLogoutMessage = await edgeCall(config, studentToken, {
    action: "send_application_message",
    thread_id: application.body.application.thread_id,
    client_message_id: randomUUID(),
    body: "This saved message must wait for the poster to reconnect.",
  });
  assert.equal(afterLogoutMessage.status, 201);
  await delay(300);
  assert.equal(hints.posterThread.length, posterThreadHintsAtLogout);
  assert.equal(hints.posterNotifications.length, posterNoticeHintsAtLogout);
  console.log(
    `PASS native private Realtime sockets: replay reconciled a join race across pages; actor-scoped message/read/notice hints arrived; client writes and unrelated/cross-user/public joins were denied; saved-to-received latency ms (local warm loopback): ${latencySamples.join(", ")}`,
  );

  // Local Auth issues short-lived JWTs. Refresh the live socket's token before
  // revocation so expiry cannot be mistaken for access being revoked. Keep its
  // channel connected throughout the suspension check.
  posterToken = await signIn(config, email, password);
  studentToken = await signIn(config, studentEmail, studentPassword);
  studentRealtime.session.access_token = studentToken;
  await studentRealtime.client.realtime.setAuth(studentToken);

  run(
    cli,
    [
      "db",
      "query",
      "--local",
      "--output-format",
      "json",
      `update app_private.identity_accounts set account_status='suspended' where user_id='${student.id}'::uuid`,
    ],
    "suspend synthetic thread participant",
    baseEnv,
    true,
  );
  const studentNewMessageNoticesBeforeSuspension = Number(
    readLocalRows(
      `select count(*)::integer as count from app_private.in_app_notifications
       where recipient_id='${student.id}'::uuid and notification_type='new_message'`,
      "count applicant message notices before Realtime revocation check",
    )[0].count,
  );
  const studentThreadHintsBeforeSuspension = hints.studentThread.length;
  const studentNoticeHintsBeforeSuspension = hints.studentNotifications.length;
  const messageWhileSuspended = await edgeCall(config, posterToken, {
    action: "send_application_message",
    thread_id: application.body.application.thread_id,
    client_message_id: randomUUID(),
    body: "Saved while the applicant's account is suspended.",
  });
  assert.equal(messageWhileSuspended.status, 201);
  await delay(300);
  assert.equal(studentThreadSubscription.closed, false);
  assert.equal(hints.studentThread.length, studentThreadHintsBeforeSuspension);
  assert.equal(
    hints.studentNotifications.length,
    studentNoticeHintsBeforeSuspension,
  );
  const studentTopicWhileSuspended = await realtimeTopicCall(
    config,
    studentRealtime.session.access_token,
    "thread",
    application.body.application.application_id,
  );
  assert.equal(studentTopicWhileSuspended.status, 404);
  const suspendedProbe = await signedInRealtimeClient(
    config,
    studentEmail,
    studentPassword,
  );
  await suspendedProbe.client.realtime.setAuth(
    suspendedProbe.session.access_token,
  );
  const staleGenerationJoin = joinRawPrivateChannel(
    suspendedProbe.client,
    studentThreadTopic.topic,
    "thread.changed",
  );
  await assert.rejects(staleGenerationJoin.ready);
  await suspendedProbe.client.removeChannel(staleGenerationJoin.channel);
  assert.equal(
    Number(
      readLocalRows(
        `select count(*)::integer as count from app_private.in_app_notifications
         where recipient_id='${student.id}'::uuid and notification_type='new_message'`,
        "verify the suspended recipient's persisted notice survived the missed socket hint",
      )[0].count,
    ),
    studentNewMessageNoticesBeforeSuspension + 1,
  );
  const suspendedThreadRead = await readCall(config, studentToken, {
    action: "application_thread",
    application_id: application.body.application.application_id,
  });
  const suspendedThreadSend = await edgeCall(config, studentToken, {
    action: "send_application_message",
    thread_id: application.body.application.thread_id,
    client_message_id: randomUUID(),
    body: "A suspended participant cannot send.",
  });
  const suspendedThreadCursor = await edgeCall(config, studentToken, {
    action: "mark_thread_read",
    thread_id: application.body.application.thread_id,
    last_read_sequence: "51",
  });
  assert.equal(suspendedThreadRead.status, 403);
  assert.equal(suspendedThreadSend.status, 403);
  assert.equal(suspendedThreadCursor.status, 403);
  run(
    cli,
    [
      "db",
      "query",
      "--local",
      "--output-format",
      "json",
      `update app_private.identity_accounts set account_status='active' where user_id='${student.id}'::uuid`,
    ],
    "restore synthetic thread participant",
    baseEnv,
    true,
  );
  const studentTopicAfterRestore = await realtimeTopicCall(
    config,
    studentRealtime.session.access_token,
    "thread",
    application.body.application.application_id,
  );
  assert.equal(studentTopicAfterRestore.status, 200);
  assert.notEqual(
    studentTopicAfterRestore.body.data.topic,
    studentThreadTopic.topic,
  );
  const recoveredAfterSuspension =
    await managers.student.subscribeApplicationThread({
      topic: studentTopicAfterRestore.body.data.topic,
      accessToken: studentRealtime.session.access_token,
      afterSequence: replaySavedCursor,
      loadPage: async (afterSequence) => {
        const page = await readCall(config, studentToken, {
          action: "application_thread",
          application_id: application.body.application.application_id,
          after_sequence: afterSequence,
        });
        assert.equal(page.status, 200, JSON.stringify(page.body));
        return page.body.data;
      },
      onSnapshot: ({ lastSavedSequence }) => {
        replaySavedCursor = lastSavedSequence;
      },
      onHint: (hint) =>
        hints.studentThread.push({ ...hint, receivedAt: Date.now() }),
    });
  await recoveredAfterSuspension.ready;
  assert.equal(studentThreadSubscription.closed, true);
  assert.ok(
    recoveredAfterSuspension.messages.some(
      (message) =>
        message.sequence === messageWhileSuspended.body.message.sequence,
    ),
  );
  const studentNotificationsAfterRestore = await realtimeTopicCall(
    config,
    studentRealtime.session.access_token,
    "notifications",
  );
  assert.equal(studentNotificationsAfterRestore.status, 200);
  const restoredNoticeSubscription =
    await managers.student.subscribeInvalidation({
      key: "notifications",
      topic: studentNotificationsAfterRestore.body.data.topic,
      event: "notifications.changed",
      accessToken: studentRealtime.session.access_token,
      onInvalidate: (hint) => hints.studentNotifications.push(hint),
    });
  await restoredNoticeSubscription.ready;
  const noticeHintsAfterRestore = hints.studentNotifications.length;
  const threadHintsAfterRestore = hints.studentThread.length;
  const resumedMessage = await edgeCall(config, posterToken, {
    action: "send_application_message",
    thread_id: application.body.application.thread_id,
    client_message_id: randomUUID(),
    body: "The applicant receives hints again after authorization is restored.",
  });
  assert.equal(resumedMessage.status, 201);
  await waitForCondition(
    () => hints.studentNotifications.length > noticeHintsAfterRestore,
    "current notification topic should receive hints after permission returns",
  );
  await waitForCondition(
    () => hints.studentThread.length > threadHintsAfterRestore,
    "current thread topic should receive hints after permission returns",
  );
  await waitForCondition(
    () =>
      recoveredAfterSuspension.cursor === resumedMessage.body.message.sequence,
    "reconnected thread should replay the message saved after subscription",
  );
  assert.equal(
    recoveredAfterSuspension.cursor,
    resumedMessage.body.message.sequence,
  );
  console.log(
    "PASS already-connected revocation: the suspended socket stayed connected but got no new protected hints; stale-generation rejoin failed; durable history and notices recovered after reconnect; fresh topic resumed delivery",
  );
  const restoredThreadRead = await readCall(config, studentToken, {
    action: "application_thread",
    application_id: application.body.application.application_id,
  });
  assert.equal(restoredThreadRead.status, 200);
  assert.equal(
    restoredThreadRead.body.data.thread.last_sequence,
    resumedMessage.body.message.sequence,
  );

  const acceptanceKey = randomUUID();
  const accepted = await edgeCall(config, posterToken, {
    action: "accept_application",
    application_id: application.body.application.application_id,
    idempotency_key: acceptanceKey,
  });
  assert.equal(accepted.status, 200);
  assert.equal(accepted.body.assignment.assignment_state, "assigned");
  assert.equal(accepted.body.assignment.gross_principal_kobo, "300000");
  assert.equal(accepted.body.assignment.terms_version, 2);
  assert.equal(
    accepted.body.assignment.thread_id,
    application.body.application.thread_id,
  );
  const acceptedRetry = await edgeCall(config, posterToken, {
    action: "accept_application",
    application_id: application.body.application.application_id,
    idempotency_key: acceptanceKey,
  });
  assert.equal(acceptedRetry.status, 200);
  assert.equal(
    acceptedRetry.body.assignment.assignment_id,
    accepted.body.assignment.assignment_id,
  );
  const partnerApply = await edgeCall(config, posterToken, {
    action: "apply_to_job",
    job_id: jobId,
    idempotency_key: randomUUID(),
  });
  assert.equal(partnerApply.status, 403);
  assert.equal(partnerApply.body.error.code, "verification_required");
  const unverifiedApply = await edgeCall(config, unverifiedToken, {
    action: "apply_to_job",
    job_id: jobId,
    idempotency_key: randomUUID(),
  });
  assert.equal(unverifiedApply.status, 403);
  assert.equal(unverifiedApply.body.error.code, "verification_required");

  const discoveryStartedAt = performance.now();
  const discovery = await readCall(config, posterToken, {
    action: "discover_jobs",
    filters: {},
  });
  const discoveryMilliseconds = performance.now() - discoveryStartedAt;
  assert.equal(discovery.status, 200);
  console.log(
    `MEASURE local discovery Edge HTTP ${discoveryMilliseconds.toFixed(1)} ms; ${discovery.body.data.items.length} available row(s) returned; 20-row page; native Supabase loopback only`,
  );
  const explainOutput = run(
    cli,
    [
      "db",
      "query",
      "--local",
      "--output-format",
      "json",
      `EXPLAIN (ANALYZE,BUFFERS) SELECT j.job_id FROM app_private.jobs j JOIN app_private.job_terms_versions t ON t.job_id=j.job_id AND t.terms_version=j.current_terms_version JOIN app_private.funding_intents i ON i.intent_id=j.funded_funding_intent_id AND i.status='succeeded' JOIN public.job_categories c ON c.slug=t.category_slug AND c.enabled JOIN LATERAL (SELECT count(*)::integer allocation_count,count(*) FILTER (WHERE pa.status='unassigned')::integer slots_remaining FROM app_private.principal_allocations pa WHERE pa.job_id=j.job_id) a ON true WHERE j.campus_id='e3af45a7-0d34-4d13-9eab-c930aee55401'::uuid AND j.listing_state='open' AND j.funded_funding_intent_id IS NOT NULL AND t.application_deadline_at>pg_catalog.now() AND a.slots_remaining>0 AND a.allocation_count=i.slot_count AND t.search_document @@ pg_catalog.plainto_tsquery('pg_catalog.simple'::pg_catalog.regconfig,'campus') AND t.location_search_document @@ pg_catalog.plainto_tsquery('pg_catalog.simple'::pg_catalog.regconfig,'Student Centre') ORDER BY j.created_at DESC,j.job_id DESC LIMIT 21`,
    ],
    "explain local discovery join path",
    baseEnv,
    true,
  );
  const planScans = [
    ...new Set(
      [
        ...explainOutput.matchAll(
          /(?:Seq Scan|Index Scan|Bitmap Index Scan)(?: using ([A-Za-z0-9_]+))?/g,
        ),
      ].map((match) => match[1] ?? "sequential scan"),
    ),
  ];
  const planExecution =
    explainOutput.match(/Execution Time: ([0-9.]+) ms/)?.[1] ?? "unavailable";
  console.log(
    `PLAN local discovery join path (same eligibility joins; tiny fixture): scans=${planScans.join(", ") || "not parsed"}; execution=${planExecution} ms`,
  );
  const initialSummary = discovery.body.data.items.find(
    (item) => item.job_id === jobId,
  );
  assert.ok(initialSummary);
  assert.equal(initialSummary.gross_per_worker_kobo, "300000");
  assert.equal(initialSummary.commission_kobo, "15000");
  assert.equal(initialSummary.worker_net_kobo, "285000");
  assert.equal(initialSummary.slots_remaining, 2);
  assert.equal("poster_email" in initialSummary, false);
  assert.equal("bank_account_number" in initialSummary, false);
  assert.equal("provider_reference" in initialSummary, false);

  const detail = await readCall(config, posterToken, {
    action: "job_detail",
    job_id: jobId,
  });
  assert.equal(detail.status, 200);
  assert.equal(detail.body.data.job.terms_version, 2);
  assert.equal(detail.body.data.job.needed_by_at, terms.needed_by_at);
  assert.equal("payment_protected" in detail.body.data.job, false);

  const studentDiscovery = await readCall(config, studentToken, {
    action: "discover_jobs",
    filters: {},
  });
  assert.equal(studentDiscovery.status, 200);
  assert.ok(
    studentDiscovery.body.data.items.some((item) => item.job_id === jobId),
  );

  const unverifiedDiscovery = await readCall(config, unverifiedToken, {
    action: "discover_jobs",
    filters: {},
  });
  assert.equal(unverifiedDiscovery.status, 403);
  assert.equal(unverifiedDiscovery.body.error.code, "verification_required");

  const categories = await fetch(
    `${config.apiUrl}/rest/v1/job_categories?select=slug&limit=1`,
    { headers: { apikey: config.anonKey } },
  );
  assert.equal(categories.status, 200);
  const directJobs = await fetch(`${config.apiUrl}/rest/v1/jobs?select=*`, {
    headers: {
      apikey: config.anonKey,
      authorization: `Bearer ${posterToken}`,
    },
  });
  assert.notEqual(directJobs.status, 200);

  const directReadRpc = await fetch(
    `${config.apiUrl}/rest/v1/rpc/server_discover_jobs_for_actor`,
    {
      method: "POST",
      headers: {
        apikey: config.anonKey,
        authorization: `Bearer ${posterToken}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        p_actor: poster.id,
        p_filters: {},
        p_cursor_created_at: null,
        p_cursor_job_id: null,
        p_limit: 21,
      }),
    },
  );
  assert.ok([401, 403, 404].includes(directReadRpc.status));

  const partialFill = await readCall(config, posterToken, {
    action: "discover_jobs",
    filters: { category_slug: "errands", location: "Student Centre" },
  });
  assert.equal(partialFill.status, 200);
  assert.equal(
    partialFill.body.data.items.find((item) => item.job_id === jobId)
      .slots_remaining,
    2,
  );
  const additionalStudents = await Promise.all([
    createVerifiedStudent(config, "partial-worker"),
    createVerifiedStudent(config, "final-worker"),
  ]);
  const additionalAssignments = [];
  for (const applicant of additionalStudents) {
    const applied = await edgeCall(config, applicant.token, {
      action: "apply_to_job",
      job_id: jobId,
      idempotency_key: randomUUID(),
    });
    assert.equal(applied.status, 201);
    const unrelatedThread = await readCall(config, applicant.token, {
      action: "application_thread",
      application_id: application.body.application.application_id,
    });
    assert.equal(unrelatedThread.status, 404);
    const ownThread = await readCall(config, applicant.token, {
      action: "application_thread",
      application_id: applied.body.application.application_id,
    });
    assert.equal(ownThread.status, 200);
    const assignment = await edgeCall(config, posterToken, {
      action: "accept_application",
      application_id: applied.body.application.application_id,
      idempotency_key: randomUUID(),
    });
    assert.equal(assignment.status, 200);
    additionalAssignments.push(assignment.body.assignment.assignment_id);
  }
  assert.equal(new Set(additionalAssignments).size, 2);
  assert.equal(
    new Set([accepted.body.assignment.assignment_id, ...additionalAssignments])
      .size,
    3,
  );
  const filledDiscovery = await readCall(config, posterToken, {
    action: "discover_jobs",
    filters: {},
  });
  assert.equal(filledDiscovery.status, 200);
  assert.equal(
    filledDiscovery.body.data.items.some((item) => item.job_id === jobId),
    false,
  );
  const filledHistory = await readCall(config, posterToken, {
    action: "my_job_history",
  });
  assert.equal(filledHistory.status, 200);
  assert.equal(
    filledHistory.body.data.items.find((item) => item.job_id === jobId)
      .history_state,
    "filled",
  );
  const filledHistoricalDetail = await readCall(config, posterToken, {
    action: "my_job_detail",
    job_id: jobId,
  });
  assert.equal(filledHistoricalDetail.status, 200);
  assert.equal(filledHistoricalDetail.body.data.job.history_state, "filled");
  assert.equal(filledHistoricalDetail.body.data.job.terms_version, 2);
  run(
    cli,
    [
      "db",
      "query",
      "--local",
      "--output-format",
      "json",
      `do $step6$ declare v_job uuid:='${jobId}'::uuid; begin
        if (select count(*) from app_private.principal_allocations where job_id=v_job)<>3
          then raise exception 'three_slot_allocation_count'; end if;
        if (select count(*) from app_private.assignments where job_id=v_job)<>3
          then raise exception 'three_slot_assignment_count'; end if;
        if (select count(*) from app_private.principal_allocations p
            join app_private.assignments a on a.allocation_id=p.allocation_id
              and a.assignment_id=p.assignment_id where p.job_id=v_job and p.status='assigned')<>3
          then raise exception 'three_slot_assignment_binding'; end if;
      end $step6$`,
    ],
    "verify one allocation and assignment for each of three accepted workers",
    baseEnv,
    true,
  );

  const assignmentIds = [
    accepted.body.assignment.assignment_id,
    ...additionalAssignments,
  ];
  const mainWorkers = [
    {
      token: studentToken,
      id: student.id,
      email: studentEmail,
      password: studentPassword,
    },
    ...additionalStudents.map((applicant) => ({
      token: applicant.token,
      id: applicant.user.id,
      email: applicant.email,
      password: applicant.password,
    })),
  ];
  const prematureConfirmation = await edgeCall(config, posterToken, {
    action: "confirm_completion",
    assignment_id: assignmentIds[2],
    idempotency_key: randomUUID(),
  });
  assert.equal(prematureConfirmation.status, 409);
  assert.equal(prematureConfirmation.body.error.code, "stale_state");

  const unrelatedStart = await edgeCall(config, mainWorkers[1].token, {
    action: "start_assignment",
    assignment_id: assignmentIds[0],
    idempotency_key: randomUUID(),
  });
  assert.equal(unrelatedStart.status, 404);
  const posterStart = await edgeCall(config, posterToken, {
    action: "start_assignment",
    assignment_id: assignmentIds[0],
    idempotency_key: randomUUID(),
  });
  assert.equal(posterStart.status, 404);

  const startKey = randomUUID();
  const started = await edgeCall(config, mainWorkers[0].token, {
    action: "start_assignment",
    assignment_id: assignmentIds[0],
    idempotency_key: startKey,
  });
  assert.equal(
    started.status,
    200,
    `start_assignment ${JSON.stringify(started.body)}`,
  );
  assert.equal(started.body.assignment.assignment_state, "in_progress");
  const startRetry = await edgeCall(config, mainWorkers[0].token, {
    action: "start_assignment",
    assignment_id: assignmentIds[0],
    idempotency_key: startKey,
  });
  assert.equal(
    startRetry.status,
    200,
    `start_assignment retry ${JSON.stringify(startRetry.body)}`,
  );
  assert.equal(startRetry.body.assignment.assignment_id, assignmentIds[0]);
  const submitted = await edgeCall(config, mainWorkers[0].token, {
    action: "submit_assignment",
    assignment_id: assignmentIds[0],
    idempotency_key: randomUUID(),
  });
  assert.equal(
    submitted.status,
    200,
    `submit_assignment ${JSON.stringify(submitted.body)}`,
  );
  assert.equal(submitted.body.assignment.assignment_state, "submitted");
  const posterSubmit = await edgeCall(config, posterToken, {
    action: "submit_assignment",
    assignment_id: assignmentIds[0],
    idempotency_key: randomUUID(),
  });
  assert.equal(posterSubmit.status, 404);
  const workerConfirmer = await edgeCall(config, mainWorkers[0].token, {
    action: "confirm_completion",
    assignment_id: assignmentIds[0],
    idempotency_key: randomUUID(),
  });
  assert.equal(workerConfirmer.status, 404);
  const wrongConfirmer = await edgeCall(config, mainWorkers[1].token, {
    action: "confirm_completion",
    assignment_id: assignmentIds[0],
    idempotency_key: randomUUID(),
  });
  assert.equal(wrongConfirmer.status, 404);
  const completionKey = randomUUID();
  const completed = await edgeCall(config, posterToken, {
    action: "confirm_completion",
    assignment_id: assignmentIds[0],
    idempotency_key: completionKey,
  });
  assert.equal(
    completed.status,
    200,
    `confirm_completion ${JSON.stringify(completed.body)}`,
  );
  assert.equal(completed.body.assignment.assignment_state, "completed");
  assert.equal(completed.body.assignment.gross_principal_kobo, "300000");
  assert.equal(completed.body.assignment.commission_kobo, "15000");
  assert.equal(completed.body.assignment.worker_net_kobo, "285000");
  const completionRetry = await edgeCall(config, posterToken, {
    action: "confirm_completion",
    assignment_id: assignmentIds[0],
    idempotency_key: completionKey,
  });
  assert.equal(
    completionRetry.status,
    200,
    `confirm_completion retry ${JSON.stringify(completionRetry.body)}`,
  );
  assert.equal(completionRetry.body.assignment.assignment_state, "completed");
  const alteredCompletionRetry = await edgeCall(config, posterToken, {
    action: "confirm_completion",
    assignment_id: assignmentIds[2],
    idempotency_key: completionKey,
  });
  assert.equal(alteredCompletionRetry.status, 409);
  assert.equal(alteredCompletionRetry.body.error.code, "idempotency_conflict");

  const assignmentForReviews = assignmentIds[0];
  const reviewJournalsBefore = readLocalRows(
    "select count(*)::integer as count from app_private.ledger_journal_transactions",
    "snapshot the ledger before review operations",
  )[0].count;
  const competingReviewBodies = [
    {
      action: "submit_review",
      assignment_id: assignmentForReviews,
      rating: 5,
      review_text: "Careful and reliable work.",
      idempotency_key: randomUUID(),
    },
    {
      action: "submit_review",
      assignment_id: assignmentForReviews,
      rating: 4,
      review_text: "Good communication and delivery.",
      idempotency_key: randomUUID(),
    },
  ];
  const competingReviews = await Promise.all(
    competingReviewBodies.map((body) => edgeCall(config, posterToken, body)),
  );
  const winningIndex = competingReviews.findIndex(
    (result) => result.status === 201,
  );
  const losingIndex = competingReviews.findIndex(
    (result) => result.status === 409,
  );
  assert.notEqual(winningIndex, -1, JSON.stringify(competingReviews));
  assert.notEqual(losingIndex, -1, JSON.stringify(competingReviews));
  assert.equal(
    competingReviews[losingIndex].body.error.code,
    "review_already_submitted",
  );
  const winningReviewBody = competingReviewBodies[winningIndex];
  const winningReviewId = competingReviews[winningIndex].body.review.review_id;
  const reviewRetry = await edgeCall(config, posterToken, winningReviewBody);
  assert.equal(reviewRetry.status, 200, JSON.stringify(reviewRetry.body));
  assert.equal(reviewRetry.body.replayed, true);
  assert.equal(reviewRetry.body.review.review_id, winningReviewId);
  assert.equal(reviewRetry.body.review.target_role, "worker");

  const posterReview = await edgeCall(config, mainWorkers[0].token, {
    action: "submit_review",
    assignment_id: assignmentForReviews,
    rating: 4,
    review_text: "Clear and respectful communication.",
    idempotency_key: randomUUID(),
  });
  assert.equal(posterReview.status, 201, JSON.stringify(posterReview.body));
  assert.equal(posterReview.body.review.target_role, "poster");

  const workerProfileBeforeHide = await profileCommandCall(
    config,
    posterToken,
    { action: "view", profile_id: mainWorkers[0].id },
  );
  assert.equal(workerProfileBeforeHide.status, 200);
  assert.equal(
    workerProfileBeforeHide.body.profile.worker_rating,
    winningReviewBody.rating,
  );
  assert.equal(workerProfileBeforeHide.body.profile.worker_review_count, 1);
  assert.equal(workerProfileBeforeHide.body.profile.poster_rating, null);
  assert.equal(workerProfileBeforeHide.body.profile.completed_work_count, 1);
  const posterProfile = await profileCommandCall(config, mainWorkers[0].token, {
    action: "view",
    profile_id: poster.id,
  });
  assert.equal(posterProfile.status, 200);
  assert.equal(posterProfile.body.profile.poster_rating, 4);
  assert.equal(posterProfile.body.profile.poster_review_count, 1);
  const underlyingReviews = await profileCommandCall(config, posterToken, {
    action: "reviews",
    profile_id: mainWorkers[0].id,
  });
  assert.equal(underlyingReviews.status, 200);
  assert.equal(underlyingReviews.body.reviews.items.length, 1);
  assert.equal(
    underlyingReviews.body.reviews.items[0].review_id,
    winningReviewId,
  );
  assert.equal(underlyingReviews.body.reviews.items[0].reviewer_id, undefined);

  const report = await edgeCall(config, posterToken, {
    action: "report_review",
    review_id: winningReviewId,
  });
  assert.equal(report.status, 200, JSON.stringify(report.body));
  assert.equal(report.body.reported, true);
  const reviewModerator = await createDisputeReviewer(
    config,
    "review-moderator",
  );
  run(
    cli,
    [
      "db",
      "query",
      "--local",
      "--output-format",
      "json",
      `insert into app_private.staff_grants(user_id,capability,granted_by,reason)
       values('${reviewModerator.user.id}'::uuid,'review_moderate','${reviewModerator.user.id}'::uuid,
         'Synthetic local review moderation grant.')`,
    ],
    "grant synthetic review moderation capability",
    baseEnv,
    true,
  );
  const aal1Queue = await reviewModerationCall(
    config,
    reviewModerator.aal1Token,
    { action: "list_reported" },
  );
  assert.equal(aal1Queue.status, 403);
  const moderatorQueue = await reviewModerationCall(
    config,
    reviewModerator.aal2Token,
    { action: "list_reported" },
  );
  assert.equal(moderatorQueue.status, 200, JSON.stringify(moderatorQueue.body));
  assert.equal(moderatorQueue.body.result.items.length, 1);
  assert.equal(moderatorQueue.body.result.items[0].review_id, winningReviewId);
  assert.equal(moderatorQueue.body.result.items[0].reporter_id, undefined);
  const hideKey = randomUUID();
  const hideBody = {
    action: "hide",
    review_id: winningReviewId,
    reason: "The reported text exposes private contact details.",
    idempotency_key: hideKey,
  };
  const hiddenReview = await reviewModerationCall(
    config,
    reviewModerator.aal2Token,
    hideBody,
  );
  assert.equal(hiddenReview.status, 200, JSON.stringify(hiddenReview.body));
  assert.equal(hiddenReview.body.result.status, "hidden");
  const hiddenReviewRetry = await reviewModerationCall(
    config,
    reviewModerator.aal2Token,
    hideBody,
  );
  assert.equal(hiddenReviewRetry.status, 200);
  assert.equal(hiddenReviewRetry.body.result.replayed, true);
  const workerProfileAfterHide = await profileCommandCall(config, posterToken, {
    action: "view",
    profile_id: mainWorkers[0].id,
  });
  assert.equal(workerProfileAfterHide.body.profile.worker_rating, null);
  assert.equal(workerProfileAfterHide.body.profile.worker_review_count, 0);
  assert.equal(workerProfileAfterHide.body.profile.completed_work_count, 1);
  const visibleReviewsAfterHide = await profileCommandCall(
    config,
    posterToken,
    {
      action: "reviews",
      profile_id: mainWorkers[0].id,
    },
  );
  assert.deepEqual(visibleReviewsAfterHide.body.reviews.items, []);
  const reviewRows = readLocalRows(
    `select count(*)::integer as saved,
       count(*) filter(where exists(select 1 from app_private.assignment_review_moderation_events m
         where m.review_id=r.review_id and m.action='hidden'))::integer as hidden
     from app_private.assignment_reviews r where r.assignment_id='${assignmentForReviews}'::uuid`,
    "verify both immutable directional reviews and their hide state were persisted",
  )[0];
  assert.equal(reviewRows.saved, 2);
  assert.equal(reviewRows.hidden, 1);
  const reviewJournalsAfter = readLocalRows(
    "select count(*)::integer as count from app_private.ledger_journal_transactions",
    "verify review operations did not create a ledger effect",
  )[0].count;
  assert.equal(reviewJournalsAfter, reviewJournalsBefore);
  console.log(
    "PASS Step 6 reviews: two concurrent same-direction submissions saved one immutable review; both parties read role-specific totals; a reported review was hidden by an AAL2 moderator; retries preserved IDs; no ledger effect occurred",
  );
  if (process.env.NBD_REVIEW_ONLY === "1") return;

  for (const index of [1, 2]) {
    const worker = mainWorkers[index];
    const startedAssignment = await edgeCall(config, worker.token, {
      action: "start_assignment",
      assignment_id: assignmentIds[index],
      idempotency_key: randomUUID(),
    });
    assert.equal(
      startedAssignment.status,
      200,
      `worker ${index} start ${JSON.stringify(startedAssignment.body)}`,
    );
    const submittedAssignment = await edgeCall(config, worker.token, {
      action: "submit_assignment",
      assignment_id: assignmentIds[index],
      idempotency_key: randomUUID(),
    });
    assert.equal(
      submittedAssignment.status,
      200,
      `worker ${index} submit ${JSON.stringify(submittedAssignment.body)}`,
    );
  }
  const holdKey = randomUUID();
  const held = await edgeCall(config, mainWorkers[1].token, {
    action: "open_assignment_hold",
    assignment_id: assignmentIds[1],
    reason_code: "work_not_as_described",
    narrative: "The delivered work differs from the accepted terms.",
    desired_outcome: "Please review the agreed description and delivery.",
    idempotency_key: holdKey,
  });
  assert.equal(held.status, 201);
  assert.equal(held.body.hold.status, "open");
  assert.equal(held.body.hold.prior_assignment_state, "submitted");
  assert.equal(held.body.assignment.assignment_state, "submitted");
  assert.equal(held.body.assignment.earnings_status, "on_hold");
  const participantCase = await caseReadCall(config, mainWorkers[1].token, {
    action: "participant_detail",
    case_id: held.body.hold.hold_id,
  });
  assert.equal(
    participantCase.status,
    200,
    JSON.stringify(participantCase.body),
  );
  assert.equal(participantCase.body.data.status, "open");
  assert.ok(participantCase.body.data.timeline.length >= 1);
  const unrelatedParticipantRead = await caseReadCall(
    config,
    mainWorkers[0].token,
    { action: "participant_detail", case_id: held.body.hold.hold_id },
  );
  assert.equal(unrelatedParticipantRead.status, 404);
  const staffCaseAal1 = await caseReadCall(config, mainWorkers[1].token, {
    action: "reviewer_detail",
    case_id: held.body.hold.hold_id,
  });
  assert.equal(staffCaseAal1.status, 403);
  const reviewerAssignmentAal1 = await caseCommandCall(
    config,
    mainWorkers[1].token,
    {
      action: "assign_reviewer",
      case_id: held.body.hold.hold_id,
      reviewer_id: poster.id,
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(reviewerAssignmentAal1.status, 403);
  let caseReviewer = await createDisputeReviewer(config, "assigned-reviewer");
  let outOfScopeReviewer = await createDisputeReviewer(
    config,
    "out-of-scope-reviewer",
  );
  const queueAal1 = await caseReadCall(config, caseReviewer.aal1Token, {
    action: "review_queue",
  });
  assert.equal(queueAal1.status, 403);
  const reviewerQueue = await caseReadCall(config, caseReviewer.aal2Token, {
    action: "review_queue",
  });
  assert.equal(reviewerQueue.status, 200);
  assert.ok(
    reviewerQueue.body.data.items.some(
      (item) => item.case_id === held.body.hold.hold_id,
    ),
  );
  const assignedCase = await caseCommandCall(config, caseReviewer.aal2Token, {
    action: "assign_reviewer",
    case_id: held.body.hold.hold_id,
    reviewer_id: caseReviewer.user.id,
    idempotency_key: randomUUID(),
  });
  assert.equal(assignedCase.status, 200);
  const scopedCase = await caseReadCall(config, caseReviewer.aal2Token, {
    action: "reviewer_detail",
    case_id: held.body.hold.hold_id,
  });
  assert.equal(scopedCase.status, 200);
  assert.deepEqual(scopedCase.body.data.investigation.files, []);
  const wrongScopeCase = await caseReadCall(
    config,
    outOfScopeReviewer.aal2Token,
    { action: "reviewer_detail", case_id: held.body.hold.hold_id },
  );
  assert.equal(wrongScopeCase.status, 403);
  caseReviewer = await refreshAal2(config, caseReviewer);
  outOfScopeReviewer = await refreshAal2(config, outOfScopeReviewer);

  const reviewerRealtime = await signedInAal2RealtimeClient(
    config,
    caseReviewer,
  );
  const reviewerRealtimeClient = reviewerRealtime.client;
  caseReviewer.aal1Token = reviewerRealtime.aal1Token;
  caseReviewer.aal2Token = reviewerRealtime.session.access_token;
  const reviewerRealtimeManager = trackedRealtimeManager(
    reviewerRealtimeClient,
  );
  const assignedCaseTopic = await realtimeTopicCall(
    config,
    caseReviewer.aal2Token,
    "case",
    held.body.hold.hold_id,
  );
  assert.equal(assignedCaseTopic.status, 200);
  const outOfScopeCaseTopic = await realtimeTopicCall(
    config,
    outOfScopeReviewer.aal2Token,
    "case",
    held.body.hold.hold_id,
  );
  assert.equal(outOfScopeCaseTopic.status, 404);
  const aal1CaseTopic = await realtimeTopicCall(
    config,
    caseReviewer.aal1Token,
    "case",
    held.body.hold.hold_id,
  );
  assert.equal(aal1CaseTopic.status, 404);

  const heldApplicationId = held.body.assignment.application_id;
  const heldThreadTopic = await realtimeTopicCall(
    config,
    mainWorkers[1].token,
    "thread",
    heldApplicationId,
  );
  assert.equal(heldThreadTopic.status, 200);
  const reviewerThreadJoin = joinRawPrivateChannel(
    reviewerRealtimeClient,
    heldThreadTopic.body.data.topic,
    "thread.changed",
  );
  await assert.rejects(reviewerThreadJoin.ready);
  await reviewerRealtimeClient.removeChannel(reviewerThreadJoin.channel);

  const outOfScopeRealtimeClient = createClient(config.apiUrl, config.anonKey, {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
      detectSessionInUrl: false,
    },
    realtime: { timeout: 30_000, transport: WebSocket },
  });
  activeRealtimeClients.add(outOfScopeRealtimeClient);
  await outOfScopeRealtimeClient.realtime.setAuth(outOfScopeReviewer.aal2Token);
  const wrongReviewerJoin = joinRawPrivateChannel(
    outOfScopeRealtimeClient,
    assignedCaseTopic.body.data.topic,
    "case.changed",
  );
  await assert.rejects(wrongReviewerJoin.ready);
  await outOfScopeRealtimeClient.removeChannel(wrongReviewerJoin.channel);
  const aal1RealtimeClient = createClient(config.apiUrl, config.anonKey, {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
      detectSessionInUrl: false,
    },
    realtime: { timeout: 30_000, transport: WebSocket },
  });
  activeRealtimeClients.add(aal1RealtimeClient);
  await aal1RealtimeClient.realtime.setAuth(caseReviewer.aal1Token);
  const aal1ReviewerJoin = joinRawPrivateChannel(
    aal1RealtimeClient,
    assignedCaseTopic.body.data.topic,
    "case.changed",
  );
  await assert.rejects(aal1ReviewerJoin.ready);
  await aal1RealtimeClient.removeChannel(aal1ReviewerJoin.channel);

  const freshReviewerSession = await refreshRealtimeAal2Session(
    reviewerRealtimeClient,
    caseReviewer,
  );
  caseReviewer.aal1Token = freshReviewerSession.aal1Token;
  caseReviewer.aal2Token = freshReviewerSession.session.access_token;
  await reviewerRealtimeClient.realtime.setAuth(caseReviewer.aal2Token);
  const freshAssignedCaseTopic = await realtimeTopicCall(
    config,
    caseReviewer.aal2Token,
    "case",
    held.body.hold.hold_id,
  );
  assert.equal(freshAssignedCaseTopic.status, 200);
  assert.equal(
    freshAssignedCaseTopic.body.data.topic,
    assignedCaseTopic.body.data.topic,
  );

  const caseHints = [];
  const caseRealtimeErrors = [];
  const reviewerCaseSubscription =
    await reviewerRealtimeManager.subscribeInvalidation({
      key: "case",
      topic: assignedCaseTopic.body.data.topic,
      event: "case.changed",
      accessToken: caseReviewer.aal2Token,
      onInvalidate: (hint) => caseHints.push(hint),
      onError: (error) => caseRealtimeErrors.push(String(error)),
    });
  await reviewerCaseSubscription.ready;
  const triagedCase = await caseCommandCall(config, caseReviewer.aal2Token, {
    action: "triage_case",
    case_id: held.body.hold.hold_id,
    priority: "normal",
    rationale: "Initial review completed; continue evidence gathering.",
    idempotency_key: randomUUID(),
  });
  assert.equal(triagedCase.status, 200);
  const caseTopicAuthorizationResponse = await fetch(
    `${config.apiUrl}/rest/v1/rpc/can_receive_realtime_hint`,
    {
      method: "POST",
      headers: {
        apikey: config.anonKey,
        authorization: `Bearer ${caseReviewer.aal2Token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ p_topic: assignedCaseTopic.body.data.topic }),
    },
  );
  assert.equal(caseTopicAuthorizationResponse.status, 200);
  assert.equal(await caseTopicAuthorizationResponse.json(), true);
  const caseTopicAfterTriage = await realtimeTopicCall(
    config,
    caseReviewer.aal2Token,
    "case",
    held.body.hold.hold_id,
  );
  assert.equal(caseTopicAfterTriage.status, 200);
  assert.equal(
    caseTopicAfterTriage.body.data.topic,
    assignedCaseTopic.body.data.topic,
  );
  const triageEventRows = readLocalRows(
    `select count(*)::integer as count from app_private.assignment_case_events
     where case_id='${held.body.hold.hold_id}'::uuid and event_type='case_triaged'
       and actor_id='${caseReviewer.user.id}'::uuid`,
    "verify durable case event was saved before realtime delivery",
  );
  assert.equal(triageEventRows[0].count, 1);
  await waitForCondition(
    () => caseHints.length > 0 || caseRealtimeErrors.length > 0,
    "the assigned AAL2 reviewer should receive the private case invalidation",
  );
  assert.ok(
    caseHints.length > 0,
    `the assigned AAL2 reviewer channel closed before receiving the case invalidation: ${caseRealtimeErrors.join(" | ")}`,
  );
  assert.ok(
    caseHints.every(
      (hint) => JSON.stringify(hint.payload) === '{"kind":"invalidate"}',
    ),
  );
  console.log(
    "PASS case-scoped Realtime: assigned AAL2 reviewer joined only the case topic; AAL1, unassigned reviewer and participant-thread joins were denied",
  );
  if (process.env.NBD_REALTIME_CASE_ONLY === "1") return;
  await checkNotificationDelivery(
    config,
    caseReviewer,
    outOfScopeReviewer,
    readLocalRows,
  );
  if (process.env.NBD_NOTIFICATION_ONLY === "1") return;
  await reviewerCaseSubscription.dispose();
  await reviewerRealtimeManager.dispose();
  const evidenceRequest = await caseCommandCall(
    config,
    caseReviewer.aal2Token,
    {
      action: "request_case_information",
      case_id: held.body.hold.hold_id,
      target_party_role: "worker",
      request_kind: "evidence",
      prompt: "Please attach one image showing the completed work.",
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(evidenceRequest.status, 200);
  const requestNumber = evidenceRequest.body.result.request_number;
  const beginBody = {
    action: "begin_upload",
    case_id: held.body.hold.hold_id,
    request_number: requestNumber,
    content_type: "image/jpeg",
    size_bytes: 4,
    idempotency_key: randomUUID(),
  };
  const beginUpload = await caseEvidenceCall(
    config,
    mainWorkers[1].token,
    beginBody,
  );
  const beginUploadRetry = await caseEvidenceCall(
    config,
    mainWorkers[1].token,
    beginBody,
  );
  assert.equal(beginUpload.status, 200);
  assert.equal(beginUploadRetry.status, 200);
  assert.equal(beginUpload.body.intent_id, beginUploadRetry.body.intent_id);
  assert.equal(
    beginUpload.body.upload_token,
    beginUploadRetry.body.upload_token,
  );
  assert.equal("object_key" in beginUpload.body, false);
  const caseJpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xd9]);
  const uploadedCaseEvidence = await caseEvidenceCall(
    config,
    mainWorkers[1].token,
    caseJpeg,
    {
      method: "PUT",
      intentId: beginUpload.body.intent_id,
      uploadToken: beginUpload.body.upload_token,
      contentType: "image/jpeg",
    },
  );
  assert.equal(uploadedCaseEvidence.status, 200);
  assert.equal(uploadedCaseEvidence.body.safety_state, "quarantined");
  assert.equal(uploadedCaseEvidence.body.reviewable, false);
  const participantCaseAfterUpload = await caseReadCall(
    config,
    mainWorkers[1].token,
    { action: "participant_detail", case_id: held.body.hold.hold_id },
  );
  assert.equal(participantCaseAfterUpload.status, 200);
  assert.equal(
    participantCaseAfterUpload.body.data.investigation.files[0].safety_state,
    "quarantined",
  );
  assert.equal(
    "object_key" in participantCaseAfterUpload.body.data.investigation.files[0],
    false,
  );
  assert.equal(
    "internal_notes" in participantCaseAfterUpload.body.data.investigation,
    false,
  );
  const participantCaseForPoster = await caseReadCall(config, posterToken, {
    action: "participant_detail",
    case_id: held.body.hold.hold_id,
  });
  assert.deepEqual(participantCaseForPoster.body.data.investigation.files, []);
  const quarantinedDownload = await caseEvidenceCall(
    config,
    caseReviewer.aal2Token,
    {
      action: "download",
      case_id: held.body.hold.hold_id,
      evidence_number: uploadedCaseEvidence.body.evidence_number,
    },
    { download: true },
  );
  assert.equal(quarantinedDownload.status, 403);
  const syntheticEvidenceId = randomUUID();
  const syntheticObjectKey = `${held.body.hold.hold_id}/${mainWorkers[1].id}/${syntheticEvidenceId}/source`;
  const syntheticSha256 = createHash("sha256").update(caseJpeg).digest("hex");
  const syntheticStoragePut = await fetch(
    `${config.apiUrl}/storage/v1/object/case-evidence-quarantine/${syntheticObjectKey.split("/").map(encodeURIComponent).join("/")}`,
    {
      method: "POST",
      headers: {
        apikey: config.serviceKey,
        authorization: `Bearer ${config.serviceKey}`,
        "content-type": "image/jpeg",
        "cache-control": "0",
        "x-upsert": "false",
      },
      body: caseJpeg,
    },
  );
  assert.equal(syntheticStoragePut.status, 200);
  run(
    cli,
    [
      "db",
      "query",
      "--local",
      "--output-format",
      "json",
      `insert into app_private.case_evidence_files(
        evidence_id,evidence_number,case_id,owner_id,owner_role,request_id,storage_bucket,
        object_key,content_type,size_bytes,content_sha256,safety_state,source_kind
      ) values('${syntheticEvidenceId}'::uuid,2,'${held.body.hold.hold_id}'::uuid,
        '${mainWorkers[1].id}'::uuid,'worker',
        (select request_id from app_private.assignment_case_information_requests
          where case_id='${held.body.hold.hold_id}'::uuid and request_number=${requestNumber}),
        'case-evidence-quarantine','${syntheticObjectKey}','image/jpeg',4,
        decode('${syntheticSha256}','hex'),'ready','synthetic_test')`,
    ],
    "create isolated synthetic ready-file metadata for the authorized download control",
    baseEnv,
    true,
  );
  const syntheticDownload = await caseEvidenceCall(
    config,
    caseReviewer.aal2Token,
    {
      action: "download",
      case_id: held.body.hold.hold_id,
      evidence_number: 2,
    },
    { download: true },
  );
  assert.equal(syntheticDownload.status, 200);
  assert.deepEqual(syntheticDownload.bytes, caseJpeg);
  const outOfScopeDownload = await caseEvidenceCall(
    config,
    outOfScopeReviewer.aal2Token,
    {
      action: "download",
      case_id: held.body.hold.hold_id,
      evidence_number: uploadedCaseEvidence.body.evidence_number,
    },
    { download: true },
  );
  assert.equal(outOfScopeDownload.status, 403);
  const responseToRequest = await caseCommandCall(
    config,
    mainWorkers[1].token,
    {
      action: "respond_to_case_information",
      case_id: held.body.hold.hold_id,
      request_number: requestNumber,
      response: "I have attached a photo of the completed work.",
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(responseToRequest.status, 200);
  const caseFact = await caseCommandCall(config, caseReviewer.aal2Token, {
    action: "record_case_fact",
    case_id: held.body.hold.hold_id,
    fact_code: "work_quality",
    finding: "supported",
    staff_reasoning:
      "The reviewed submission supports a partial award under the accepted terms.",
    idempotency_key: randomUUID(),
  });
  assert.equal(caseFact.status, 200);
  const grantProposerApproval = `insert into app_private.staff_grants(user_id,capability,granted_by,reason)
    values('${caseReviewer.user.id}'::uuid,'financial_approve','${caseReviewer.user.id}'::uuid,
      'Synthetic local Step 5 proposer approval grant.')`;
  run(
    cli,
    [
      "db",
      "query",
      "--local",
      "--output-format",
      "json",
      grantProposerApproval,
    ],
    "grant synthetic proposer approval capability",
    baseEnv,
    true,
  );
  const independentApprover = await createCaseDecisionApprover(config);
  const reviewerCaseBeforeDecision = await caseReadCall(
    config,
    caseReviewer.aal2Token,
    { action: "reviewer_detail", case_id: held.body.hold.hold_id },
  );
  assert.equal(reviewerCaseBeforeDecision.status, 200);
  assert.equal(reviewerCaseBeforeDecision.body.data.status, "verifying");
  const financialStateBeforeDecision = await readCaseDecisionFinancialSnapshot(
    held.body.hold.hold_id,
  );
  const proposalBody = {
    action: "propose_case_decision",
    case_id: held.body.hold.hold_id,
    expected_case_version: reviewerCaseBeforeDecision.body.data.version,
    outcome: "split",
    award_gross_kobo: "200000",
    public_explanation:
      "Reviewed work supports a partial award and return of the remaining amount.",
    idempotency_key: randomUUID(),
  };
  const forgedProposal = await caseCommandCall(config, caseReviewer.aal2Token, {
    ...proposalBody,
    actor_id: independentApprover.user.id,
    role: "financial_approve",
    recipient_id: poster.id,
  });
  assert.equal(forgedProposal.status, 400);
  const proposedDecision = await caseCommandCall(
    config,
    caseReviewer.aal2Token,
    proposalBody,
  );
  assert.equal(proposedDecision.status, 200);
  assert.equal(proposedDecision.body.result.worker_award_gross_kobo, "200000");
  assert.equal(proposedDecision.body.result.poster_refund_gross_kobo, "100000");
  assert.equal(proposedDecision.body.result.commission_kobo, "10000");
  assert.equal(proposedDecision.body.result.worker_net_kobo, "190000");
  assert.equal(proposedDecision.body.result.approval_count, 1);
  const approvalBody = {
    action: "approve_case_decision",
    case_id: held.body.hold.hold_id,
    decision_version: proposedDecision.body.result.decision_version,
    expected_case_version: proposedDecision.body.result.case_version,
    idempotency_key: randomUUID(),
  };
  const aal1Approval = await caseCommandCall(
    config,
    independentApprover.aal1Token,
    approvalBody,
  );
  assert.equal(aal1Approval.status, 403);
  const approvedDecision = await caseCommandCall(
    config,
    independentApprover.aal2Token,
    approvalBody,
  );
  assert.equal(approvedDecision.status, 200);
  assert.equal(approvedDecision.body.result.approved, true);
  assert.equal(approvedDecision.body.result.approval_count, 2);
  const duplicateApproval = await caseCommandCall(
    config,
    independentApprover.aal2Token,
    approvalBody,
  );
  assert.equal(duplicateApproval.status, 200);
  assert.equal(duplicateApproval.body.result.decision_version, 1);
  const samePersonTwice = await caseCommandCall(
    config,
    independentApprover.aal2Token,
    { ...approvalBody, idempotency_key: randomUUID() },
  );
  assert.equal(samePersonTwice.status, 403);
  const reviewerCaseAfterDecision = await caseReadCall(
    config,
    caseReviewer.aal2Token,
    { action: "reviewer_detail", case_id: held.body.hold.hold_id },
  );
  assert.equal(reviewerCaseAfterDecision.status, 200);
  assert.equal(
    reviewerCaseAfterDecision.body.data.investigation.decision.status,
    "approved",
  );
  assert.equal(
    reviewerCaseAfterDecision.body.data.investigation.decision.approval_count,
    2,
  );
  const participantCaseAfterDecision = await caseReadCall(
    config,
    mainWorkers[1].token,
    { action: "participant_detail", case_id: held.body.hold.hold_id },
  );
  assert.equal(participantCaseAfterDecision.status, 200);
  assert.equal(participantCaseAfterDecision.body.data.status, "decision_made");
  assert.equal(
    "decision" in participantCaseAfterDecision.body.data.investigation,
    false,
  );
  const initialAppeal = participantCaseAfterDecision.body.data.appeal;
  assert.equal(initialAppeal.decision.decision_version, 1);
  assert.equal(
    Date.parse(initialAppeal.appeal_deadline_at) -
      Date.parse(initialAppeal.durable_notified_at),
    72 * 60 * 60 * 1000,
  );
  const clientClockAppeal = await caseCommandCall(config, posterToken, {
    action: "submit_case_appeal",
    case_id: held.body.hold.hold_id,
    statement:
      "I am appealing because the decision does not match the work I submitted.",
    received_at: "2026-11-05T12:00:00.000Z",
    idempotency_key: randomUUID(),
  });
  assert.equal(clientClockAppeal.status, 400);

  const lockMarker = `nbd_appeal_lock_${randomUUID().replaceAll("-", "")}`;
  const lockFunctionSetup = await runDatabaseQueryInOwnProcess(
    `create function app_private.test_hold_case_lock_for_appeal(
       p_case_id uuid,p_sleep_seconds double precision
     ) returns void language plpgsql set search_path = '' as $lock$
     begin
       perform 1 from app_private.assignment_cases where case_id=p_case_id for update;
       if not found then raise exception 'test_case_not_found'; end if;
       perform pg_catalog.pg_sleep(p_sleep_seconds);
     end;
     $lock$`,
  );
  assert.equal(lockFunctionSetup.status, 0, lockFunctionSetup.output);
  const appealLock = startDatabaseQueryInOwnProcess(
    `select app_private.test_hold_case_lock_for_appeal(
       '${held.body.hold.hold_id}'::uuid,5) /* ${lockMarker} */`,
  );
  const lockWaitStarted = Date.now();
  let appealLockAcquired = false;
  while (Date.now() - lockWaitStarted < 10_000) {
    const probe = await runDatabaseQueryInOwnProcess(
      `select 'NBD_APPEAL_LOCK:' || exists(
        select 1 from pg_stat_activity
        where query like '%${lockMarker}%' and wait_event='PgSleep')::text`,
    );
    assert.equal(probe.status, 0, probe.output);
    if (probe.output.includes("NBD_APPEAL_LOCK:true")) {
      appealLockAcquired = true;
      break;
    }
    await delay(150);
  }
  if (!appealLockAcquired) {
    const lockResult = await appealLock.done;
    await runDatabaseQueryInOwnProcess(
      "drop function app_private.test_hold_case_lock_for_appeal(uuid,double precision)",
    );
    assert.fail(
      `a separate transaction holds the case row lock: ${lockResult.output}`,
    );
  }
  let workerAppealFinished = false;
  let posterAppealFinished = false;
  const workerAppealPromise = caseCommandCall(config, mainWorkers[1].token, {
    action: "submit_case_appeal",
    case_id: held.body.hold.hold_id,
    statement:
      "I am appealing because the decision does not match the work I submitted.",
    idempotency_key: randomUUID(),
  }).then((result) => {
    workerAppealFinished = true;
    return result;
  });
  const posterAppealPromise = caseCommandCall(config, posterToken, {
    action: "submit_case_appeal",
    case_id: held.body.hold.hold_id,
    statement:
      "I am appealing as the poster because the work was not completed as agreed.",
    idempotency_key: randomUUID(),
  }).then((result) => {
    posterAppealFinished = true;
    return result;
  });
  const receiptWaitStarted = Date.now();
  let bothAppealsDurable = false;
  while (Date.now() - receiptWaitStarted < 8_000) {
    const receiptProbe = await runDatabaseQueryInOwnProcess(
      `select 'NBD_APPEAL_RECEIPTS:' || count(*)::text
       from app_private.assignment_case_appeal_receipts
       where case_id='${held.body.hold.hold_id}'::uuid`,
    );
    assert.equal(receiptProbe.status, 0, receiptProbe.output);
    if (receiptProbe.output.includes("NBD_APPEAL_RECEIPTS:2")) {
      bothAppealsDurable = true;
      break;
    }
    await delay(150);
  }
  assert.ok(
    bothAppealsDurable,
    "both server-timestamped appeal receipts commit while case processing waits",
  );
  assert.equal(workerAppealFinished, false);
  assert.equal(posterAppealFinished, false);
  const gateWhileCaseLockHeld = await runDatabaseQueryInOwnProcess(
    `select 'NBD_APPEAL_GATE:' || coalesce(
      app_private.case_appeal_finalization_block_reason(
        '${held.body.hold.hold_id}'::uuid,
        (select appeal_deadline_at from app_private.assignment_case_decision_publications
          where case_id='${held.body.hold.hold_id}'::uuid)),
      'eligible')`,
  );
  assert.equal(gateWhileCaseLockHeld.status, 0, gateWhileCaseLockHeld.output);
  assert.ok(
    gateWhileCaseLockHeld.output.includes(
      "NBD_APPEAL_GATE:timely_appeal_unresolved",
    ),
  );
  const appealLockResult = await appealLock.done;
  const lockFunctionCleanup = await runDatabaseQueryInOwnProcess(
    "drop function app_private.test_hold_case_lock_for_appeal(uuid,double precision)",
  );
  assert.equal(appealLockResult.status, 0, appealLockResult.output);
  assert.equal(lockFunctionCleanup.status, 0, lockFunctionCleanup.output);
  const [workerAppeal, posterAppeal] = await Promise.all([
    workerAppealPromise,
    posterAppealPromise,
  ]);
  assert.equal(workerAppeal.status, 200, JSON.stringify(workerAppeal.body));
  assert.equal(posterAppeal.status, 200, JSON.stringify(posterAppeal.body));
  const workerCaseWithAppeal = await caseReadCall(
    config,
    mainWorkers[1].token,
    {
      action: "participant_detail",
      case_id: held.body.hold.hold_id,
    },
  );
  const posterCaseWithAppeal = await caseReadCall(config, posterToken, {
    action: "participant_detail",
    case_id: held.body.hold.hold_id,
  });
  assert.equal(workerCaseWithAppeal.status, 200);
  assert.equal(posterCaseWithAppeal.status, 200);
  assert.equal(
    workerCaseWithAppeal.body.data.appeal.other_party_appeal_received,
    true,
  );
  assert.equal(
    posterCaseWithAppeal.body.data.appeal.other_party_appeal_received,
    true,
  );
  assert.equal(workerCaseWithAppeal.body.data.appeal.can_appeal, false);
  assert.equal(posterCaseWithAppeal.body.data.appeal.can_appeal, false);
  assert.ok(
    !JSON.stringify(workerCaseWithAppeal.body.data).includes(
      posterCaseWithAppeal.body.data.appeal.my_appeal.statement,
    ),
    "the worker projection hides the poster's private appeal statement",
  );
  assert.ok(
    !JSON.stringify(posterCaseWithAppeal.body.data).includes(
      workerCaseWithAppeal.body.data.appeal.my_appeal.statement,
    ),
    "the poster projection hides the worker's private appeal statement",
  );

  const appealReviewer = await createDisputeReviewer(config, "appeal-reviewer");
  run(
    cli,
    [
      "db",
      "query",
      "--local",
      "--output-format",
      "json",
      `insert into app_private.staff_grants(user_id,capability,granted_by,reason)
       values
         ('${appealReviewer.user.id}'::uuid,'case_appeal_review','${appealReviewer.user.id}'::uuid,
           'Synthetic local appeal-review grant for Step 6.'),
         ('${appealReviewer.user.id}'::uuid,'financial_approve','${appealReviewer.user.id}'::uuid,
           'Synthetic local financial proposal grant for appeal review.')`,
    ],
    "grant synthetic appeal reviewer capabilities",
    baseEnv,
    true,
  );
  const initialReviewerDetail = await caseReadCall(
    config,
    caseReviewer.aal2Token,
    {
      action: "appeal_reviewer_detail",
      case_id: held.body.hold.hold_id,
    },
  );
  assert.equal(initialReviewerDetail.status, 403);
  const appealAssignment = await caseCommandCall(
    config,
    caseReviewer.aal2Token,
    {
      action: "assign_appeal_reviewer",
      case_id: held.body.hold.hold_id,
      reviewer_id: appealReviewer.user.id,
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(appealAssignment.status, 200);
  const appealQueue = await caseReadCall(config, appealReviewer.aal2Token, {
    action: "appeal_review_queue",
  });
  assert.equal(appealQueue.status, 200);
  assert.equal(
    appealQueue.body.data.items.find(
      (item) => item.case_id === held.body.hold.hold_id,
    )?.pending_appeal_count,
    2,
  );
  const appealReviewerDetail = await caseReadCall(
    config,
    appealReviewer.aal2Token,
    { action: "appeal_reviewer_detail", case_id: held.body.hold.hold_id },
  );
  assert.equal(appealReviewerDetail.status, 200);
  assert.equal(appealReviewerDetail.body.data.appeal_review.appeals.length, 2);
  const workerAppealId =
    appealReviewerDetail.body.data.appeal_review.appeals.find(
      (appeal) => appeal.party_role === "worker",
    )?.appeal_id;
  const posterAppealId =
    appealReviewerDetail.body.data.appeal_review.appeals.find(
      (appeal) => appeal.party_role === "poster",
    )?.appeal_id;
  const caseSenior = await createCaseSeniorSigner(config);
  const appealQueueAal1 = await caseReadCall(config, appealReviewer.aal1Token, {
    action: "appeal_review_queue",
  });
  assert.equal(appealQueueAal1.status, 403);
  run(
    cli,
    [
      "db",
      "query",
      "--local",
      "--output-format",
      "json",
      `insert into app_private.staff_grants(user_id,capability,granted_by,reason)
       values('${appealReviewer.user.id}'::uuid,'case_senior_signoff',
         '${caseSenior.user.id}'::uuid,'Synthetic wrong-role senior grant for Step 10.')`,
    ],
    "grant appeal reviewer only for the explicit senior-separation denial case",
    baseEnv,
    true,
  );
  const posterAppealEvidenceRequest = await caseCommandCall(
    config,
    appealReviewer.aal2Token,
    {
      action: "request_case_appeal_evidence",
      case_id: held.body.hold.hold_id,
      appeal_id: posterAppealId,
      target_party_role: "poster",
      request_kind: "evidence",
      prompt:
        "Please send a response or supporting image for the appeal review.",
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(
    posterAppealEvidenceRequest.status,
    200,
    JSON.stringify(posterAppealEvidenceRequest.body),
  );
  const posterAppealRequestNumber =
    posterAppealEvidenceRequest.body.result.request_number;
  for (const [channel, note] of [
    ["phone", "No answer recorded in the local test fixture."],
    ["email", "No reply recorded in the local test fixture."],
  ]) {
    const contactAttempt = await caseCommandCall(
      config,
      appealReviewer.aal2Token,
      {
        action: "log_case_contact_attempt",
        case_id: held.body.hold.hold_id,
        target_party_role: "poster",
        channel,
        result: "no_response",
        result_note: note,
        idempotency_key: randomUUID(),
      },
    );
    assert.equal(
      contactAttempt.status,
      200,
      JSON.stringify(contactAttempt.body),
    );
    assert.equal(
      contactAttempt.body.result.attribution,
      "simulated_manual_log",
    );
  }
  const appealNonresponseAssessment = await caseCommandCall(
    config,
    appealReviewer.aal2Token,
    {
      action: "assess_case_nonresponse",
      case_id: held.body.hold.hold_id,
      target_party_role: "poster",
      substantive_reasoning:
        "Two recorded channels received no reply. This limits the poster's input but does not decide the financial result, which remains based on the accepted terms and submitted work evidence.",
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(
    appealNonresponseAssessment.status,
    200,
    JSON.stringify(appealNonresponseAssessment.body),
  );
  const [appealAssessment] = readLocalRows(
    `select assessment_id from app_private.assignment_case_nonresponse_assessments
     where case_id='${held.body.hold.hold_id}'::uuid
     order by created_at desc,assessment_id desc limit 1`,
    "read the synthetic appeal evidence non-response assessment identifier",
  );
  const selfSeniorSignoff = await caseCommandCall(
    config,
    appealReviewer.aal2Token,
    {
      action: "signoff_case_nonresponse",
      case_id: held.body.hold.hold_id,
      assessment_id: appealAssessment.assessment_id,
      substantive_reasoning:
        "A separate senior must confirm this contact snapshot. The appeal reviewer cannot sign their own assessment or decide money from silence.",
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(selfSeniorSignoff.status, 403);
  const appealSeniorSignoff = await caseCommandCall(
    config,
    caseSenior.aal2Token,
    {
      action: "signoff_case_nonresponse",
      case_id: held.body.hold.hold_id,
      assessment_id: appealAssessment.assessment_id,
      substantive_reasoning:
        "The separate senior reviewed the two-channel contact log and confirms it documents non-response only. The financial outcome still depends on work evidence and accepted terms.",
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(
    appealSeniorSignoff.status,
    200,
    JSON.stringify(appealSeniorSignoff.body),
  );
  const selfCloseAppealEvidence = await caseCommandCall(
    config,
    appealReviewer.aal2Token,
    {
      action: "close_case_appeal_evidence_nonresponse",
      case_id: held.body.hold.hold_id,
      request_number: posterAppealRequestNumber,
      substantive_reasoning:
        "This request may close only after the documented attempts and separate senior sign-off. The appeal review must continue from the submitted record.",
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(selfCloseAppealEvidence.status, 403);
  const closedAppealEvidenceRequest = await caseCommandCall(
    config,
    caseSenior.aal2Token,
    {
      action: "close_case_appeal_evidence_nonresponse",
      case_id: held.body.hold.hold_id,
      request_number: posterAppealRequestNumber,
      substantive_reasoning:
        "The request is closed after two documented contact channels and an independent senior review. The appeal reviewer can finish using the available evidence without treating silence as a financial decision.",
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(closedAppealEvidenceRequest.status, 200);
  assert.equal(closedAppealEvidenceRequest.body.result.closed, true);
  const appealEvidenceRequest = await caseCommandCall(
    config,
    appealReviewer.aal2Token,
    {
      action: "request_case_appeal_evidence",
      case_id: held.body.hold.hold_id,
      appeal_id: workerAppealId,
      target_party_role: "worker",
      request_kind: "evidence",
      prompt:
        "Please attach one image that shows the work submitted for this appeal.",
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(appealEvidenceRequest.status, 200);
  const appealRequestNumber = appealEvidenceRequest.body.result.request_number;
  const appealUploadIntent = await caseEvidenceCall(
    config,
    mainWorkers[1].token,
    {
      action: "begin_upload",
      case_id: held.body.hold.hold_id,
      request_number: appealRequestNumber,
      content_type: "image/jpeg",
      size_bytes: 4,
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(appealUploadIntent.status, 200);
  const appealUploadedFile = await caseEvidenceCall(
    config,
    mainWorkers[1].token,
    caseJpeg,
    {
      method: "PUT",
      intentId: appealUploadIntent.body.intent_id,
      uploadToken: appealUploadIntent.body.upload_token,
      contentType: "image/jpeg",
    },
  );
  assert.equal(appealUploadedFile.status, 200);
  assert.equal(appealUploadedFile.body.safety_state, "quarantined");
  assert.equal(appealUploadedFile.body.reviewable, false);
  const answerAppealRequest = await caseCommandCall(
    config,
    mainWorkers[1].token,
    {
      action: "respond_case_appeal_evidence",
      case_id: held.body.hold.hold_id,
      request_number: appealRequestNumber,
      response: "I attached the requested work photo for the appeal review.",
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(answerAppealRequest.status, 200);

  const appealReviewerCase = await caseReadCall(
    config,
    appealReviewer.aal2Token,
    { action: "appeal_reviewer_detail", case_id: held.body.hold.hold_id },
  );
  assert.equal(appealReviewerCase.status, 200);
  assert.equal(
    appealReviewerCase.body.data.investigation.files.some(
      (file) => file.safety_state === "quarantined",
    ),
    true,
  );
  const appealProposal = await caseCommandCall(
    config,
    appealReviewer.aal2Token,
    {
      action: "propose_case_decision",
      case_id: held.body.hold.hold_id,
      expected_case_version: appealReviewerCase.body.data.version,
      outcome: "full_poster_refund",
      award_gross_kobo: "0",
      public_explanation:
        "The appeal review supports returning the held amount to the poster.",
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(appealProposal.status, 200);
  const appealDecisionApproval = await caseCommandCall(
    config,
    independentApprover.aal2Token,
    {
      action: "approve_case_decision",
      case_id: held.body.hold.hold_id,
      decision_version: appealProposal.body.result.decision_version,
      expected_case_version: appealProposal.body.result.case_version,
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(appealDecisionApproval.status, 200);
  assert.equal(appealDecisionApproval.body.result.approved, true);
  const workerAppealDecision = await caseCommandCall(
    config,
    appealReviewer.aal2Token,
    {
      action: "review_case_appeal",
      case_id: held.body.hold.hold_id,
      appeal_id: workerAppealId,
      action_type: "changed",
      decision_version: appealProposal.body.result.decision_version,
      public_explanation:
        "The appeal review and approved evidence support a full return of the held amount.",
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(workerAppealDecision.status, 200);
  assert.equal(workerAppealDecision.body.result.action, "changed");
  const posterAppealDecision = await caseCommandCall(
    config,
    appealReviewer.aal2Token,
    {
      action: "review_case_appeal",
      case_id: held.body.hold.hold_id,
      appeal_id: posterAppealId,
      action_type: "upheld",
      public_explanation:
        "The appeal review confirms the approved outcome after considering the submitted record.",
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(posterAppealDecision.status, 200);
  assert.equal(posterAppealDecision.body.result.action, "upheld");
  const workerCaseAfterAppeal = await caseReadCall(
    config,
    mainWorkers[1].token,
    {
      action: "participant_detail",
      case_id: held.body.hold.hold_id,
    },
  );
  const posterCaseAfterAppeal = await caseReadCall(config, posterToken, {
    action: "participant_detail",
    case_id: held.body.hold.hold_id,
  });
  assert.equal(workerCaseAfterAppeal.status, 200);
  assert.equal(posterCaseAfterAppeal.status, 200);
  assert.equal(
    workerCaseAfterAppeal.body.data.appeal.decision.decision_version,
    2,
  );
  assert.equal(
    posterCaseAfterAppeal.body.data.appeal.decision.decision_version,
    2,
  );
  assert.equal(
    workerCaseAfterAppeal.body.data.appeal.appeal_deadline_at,
    initialAppeal.appeal_deadline_at,
  );
  run(
    cli,
    [
      "db",
      "query",
      "--local",
      "--output-format",
      "json",
      `insert into app_private.staff_grants(user_id,capability,granted_by,reason)
       values('${appealReviewer.user.id}'::uuid,'financial_initiate',
         '${appealReviewer.user.id}'::uuid,'Synthetic local early-finalization Edge check.')`,
    ],
    "grant synthetic case finalization capability",
    baseEnv,
    true,
  );
  const earlyFinalization = await caseCommandCall(
    config,
    appealReviewer.aal2Token,
    {
      action: "finalize_case",
      case_id: held.body.hold.hold_id,
      decision_version: appealProposal.body.result.decision_version,
      expected_case_version: workerCaseAfterAppeal.body.data.version,
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(
    earlyFinalization.status,
    409,
    JSON.stringify(earlyFinalization.body),
  );
  assert.equal(
    earlyFinalization.body.error.code,
    "case_finalization_not_ready",
  );
  const publicationCount = await runDatabaseQueryInOwnProcess(
    `select 'NBD_APPEAL_PUBLICATIONS:' || count(*)::text
     from app_private.assignment_case_decision_publications
     where case_id='${held.body.hold.hold_id}'::uuid`,
  );
  assert.equal(publicationCount.status, 0, publicationCount.output);
  assert.ok(publicationCount.output.includes("NBD_APPEAL_PUBLICATIONS:1"));
  assert.equal(
    await readCaseDecisionFinancialSnapshot(held.body.hold.hold_id),
    financialStateBeforeDecision,
  );
  console.log(
    "PASS Step 5–7 case Edge journey: independently approved decision, parallel timely appeals, separate appeal reviewer, quarantined appeal evidence, approved changed outcome and early-finalization denial; funds remain held",
  );

  // Step 9 traceability proof: make a separate synthetic dispute, finalize it
  // with the postgres-only historical-time helper, then settle its refund via
  // the existing local Edge runner. All reads below use the authenticated
  // case-read / financial-inspection Edge routes.
  const traceJobId = await createFundedStep3Job(
    "Synthetic case refund traceability",
    1,
  );
  const traceApplication = await edgeCall(config, mainWorkers[2].token, {
    action: "apply_to_job",
    job_id: traceJobId,
    note: "Available for the synthetic traceability task.",
    idempotency_key: randomUUID(),
  });
  assert.equal(traceApplication.status, 201);
  const traceAccepted = await edgeCall(config, posterToken, {
    action: "accept_application",
    application_id: traceApplication.body.application.application_id,
    idempotency_key: randomUUID(),
  });
  assert.equal(traceAccepted.status, 200);
  const traceStarted = await edgeCall(config, mainWorkers[2].token, {
    action: "start_assignment",
    assignment_id: traceAccepted.body.assignment.assignment_id,
    idempotency_key: randomUUID(),
  });
  assert.equal(traceStarted.status, 200);
  const traceSubmitted = await edgeCall(config, mainWorkers[2].token, {
    action: "submit_assignment",
    assignment_id: traceAccepted.body.assignment.assignment_id,
    idempotency_key: randomUUID(),
  });
  assert.equal(traceSubmitted.status, 200);
  const traceHold = await edgeCall(config, mainWorkers[2].token, {
    action: "open_assignment_hold",
    assignment_id: traceAccepted.body.assignment.assignment_id,
    reason_code: "work_not_as_described",
    narrative: "The synthetic submission does not match the accepted terms.",
    desired_outcome: "Please review the submitted work and agreed description.",
    idempotency_key: randomUUID(),
  });
  assert.equal(traceHold.status, 201);
  const traceCaseId = traceHold.body.hold.hold_id;
  const traceAssigned = await caseCommandCall(config, caseReviewer.aal2Token, {
    action: "assign_reviewer",
    case_id: traceCaseId,
    reviewer_id: caseReviewer.user.id,
    idempotency_key: randomUUID(),
  });
  assert.equal(traceAssigned.status, 200);
  const traceTriage = await caseCommandCall(config, caseReviewer.aal2Token, {
    action: "triage_case",
    case_id: traceCaseId,
    priority: "normal",
    rationale: "Review the submitted work against the accepted terms.",
    idempotency_key: randomUUID(),
  });
  assert.equal(traceTriage.status, 200);
  const tracePrivateNote = await caseCommandCall(
    config,
    caseReviewer.aal2Token,
    {
      action: "add_case_internal_note",
      case_id: traceCaseId,
      note: "Private synthetic staff note; participants must not see this.",
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(tracePrivateNote.status, 200);
  const traceFact = await caseCommandCall(config, caseReviewer.aal2Token, {
    action: "record_case_fact",
    case_id: traceCaseId,
    fact_code: "work_quality",
    finding: "supported",
    staff_reasoning:
      "The synthetic work record supports returning the held principal to the poster.",
    idempotency_key: randomUUID(),
  });
  assert.equal(traceFact.status, 200);
  const traceReviewerBeforeDecision = await caseReadCall(
    config,
    caseReviewer.aal2Token,
    { action: "reviewer_detail", case_id: traceCaseId },
  );
  assert.equal(traceReviewerBeforeDecision.status, 200);
  const traceProposal = await caseCommandCall(config, caseReviewer.aal2Token, {
    action: "propose_case_decision",
    case_id: traceCaseId,
    expected_case_version: traceReviewerBeforeDecision.body.data.version,
    outcome: "full_poster_refund",
    award_gross_kobo: "0",
    public_explanation:
      "The reviewed synthetic work record supports returning the held amount to the poster.",
    idempotency_key: randomUUID(),
  });
  assert.equal(traceProposal.status, 200);
  const traceApproval = await caseCommandCall(
    config,
    independentApprover.aal2Token,
    {
      action: "approve_case_decision",
      case_id: traceCaseId,
      decision_version: traceProposal.body.result.decision_version,
      expected_case_version: traceProposal.body.result.case_version,
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(traceApproval.status, 200);
  assert.equal(traceApproval.body.result.approved, true);
  const tracePublicationRows = readLocalRows(
    `select durable_notified_at,appeal_deadline_at from app_private.assignment_case_decision_publications
     where case_id='${traceCaseId}'::uuid`,
    "read durable synthetic case-decision notice timing",
  );
  assert.equal(tracePublicationRows.length, 1);
  assert.equal(
    Date.parse(tracePublicationRows[0].appeal_deadline_at) -
      Date.parse(tracePublicationRows[0].durable_notified_at),
    72 * 60 * 60 * 1000,
  );
  run(
    cli,
    [
      "db",
      "query",
      "--local",
      "--output-format",
      "json",
      `insert into app_private.staff_grants(user_id,capability,granted_by,reason)
       values('${caseReviewer.user.id}'::uuid,'financial_initiate',
         '${caseReviewer.user.id}'::uuid,'Synthetic local Step 9 finalization grant.')`,
    ],
    "grant synthetic finalization capability to the assigned reviewer",
    baseEnv,
    true,
  );
  run(
    cli,
    [
      "db",
      "query",
      "--local",
      "--output-format",
      "json",
      `select app_private.finalize_case_for_actor_at(
        '${caseReviewer.user.id}'::uuid,'${traceCaseId}'::uuid,
        ${traceProposal.body.result.decision_version},
        (select version from app_private.assignment_cases where case_id='${traceCaseId}'::uuid),
        'aal2','${randomUUID()}'::uuid,
        (select appeal_deadline_at+interval '1 second'
         from app_private.assignment_case_decision_publications where case_id='${traceCaseId}'::uuid)
      ) as finalization`,
    ],
    "finalize synthetic case with the postgres-only historical-time helper",
    baseEnv,
    true,
  );
  const traceParticipant = await caseReadCall(config, mainWorkers[2].token, {
    action: "participant_detail",
    case_id: traceCaseId,
  });
  const tracePoster = await caseReadCall(config, posterToken, {
    action: "participant_detail",
    case_id: traceCaseId,
  });
  for (const participant of [traceParticipant, tracePoster]) {
    assert.equal(participant.status, 200, JSON.stringify(participant.body));
    assert.equal(participant.body.data.status, "closed");
    assert.equal(
      participant.body.data.finalization.refund_status,
      "authorized",
    );
    assert.equal("traceability" in participant.body.data, false);
    assert.equal(
      "internal_notes" in participant.body.data.investigation,
      false,
    );
    assert.equal(
      JSON.stringify(participant.body.data).includes(
        "Private synthetic staff note; participants must not see this.",
      ),
      false,
    );
  }
  const participantDecision = traceParticipant.body.data.timeline.find(
    (event) => event.event_type === "decision_notified",
  );
  const posterDecision = tracePoster.body.data.timeline.find(
    (event) => event.event_type === "decision_notified",
  );
  assert.equal(
    participantDecision.details.public_explanation,
    "The reviewed synthetic work record supports returning the held amount to the poster.",
  );
  assert.deepEqual(posterDecision.details, participantDecision.details);
  async function assertTraceParticipantStatus(expectedStatus) {
    for (const token of [mainWorkers[2].token, posterToken]) {
      const response = await caseReadCall(config, token, {
        action: "participant_detail",
        case_id: traceCaseId,
      });
      assert.equal(response.status, 200, JSON.stringify(response.body));
      assert.equal(
        response.body.data.finalization.refund_status,
        expectedStatus,
      );
      assert.equal(response.body.data.status, "closed");
      assert.equal(
        response.body.data.timeline.find(
          (event) => event.event_type === "decision_notified",
        ).details.public_explanation,
        participantDecision.details.public_explanation,
      );
      assert.equal("traceability" in response.body.data, false);
      assert.equal(
        JSON.stringify(response.body.data).includes(
          "Private synthetic staff note; participants must not see this.",
        ),
        false,
      );
    }
  }
  const unrelatedCaseRead = await caseReadCall(config, studentToken, {
    action: "participant_detail",
    case_id: traceCaseId,
  });
  assert.equal(unrelatedCaseRead.status, 404);
  const unrelatedReviewerCaseRead = await caseReadCall(
    config,
    outOfScopeReviewer.aal2Token,
    { action: "reviewer_detail", case_id: traceCaseId },
  );
  assert.equal(unrelatedReviewerCaseRead.status, 403);
  const reviewerWithoutMfa = await caseReadCall(
    config,
    caseReviewer.aal1Token,
    {
      action: "reviewer_detail",
      case_id: traceCaseId,
    },
  );
  assert.equal(reviewerWithoutMfa.status, 403);

  const authorizedTraceBeforeRefund = await caseReadCall(
    config,
    caseReviewer.aal2Token,
    { action: "reviewer_detail", case_id: traceCaseId },
  );
  assert.equal(
    authorizedTraceBeforeRefund.status,
    200,
    JSON.stringify(authorizedTraceBeforeRefund.body),
  );
  assert.equal(authorizedTraceBeforeRefund.body.data.status, "closed");
  assert.equal(
    authorizedTraceBeforeRefund.body.data.traceability.decision.proposed_by,
    caseReviewer.user.id,
  );
  assert.deepEqual(
    authorizedTraceBeforeRefund.body.data.traceability.decision.approvals.map(
      (approval) => approval.actor_id,
    ),
    [caseReviewer.user.id, independentApprover.user.id],
  );
  assert.equal(
    authorizedTraceBeforeRefund.body.data.traceability.finalization
      .finalized_by,
    caseReviewer.user.id,
  );
  assert.ok(
    authorizedTraceBeforeRefund.body.data.traceability.finalization
      .finalized_at,
  );
  assert.equal(
    authorizedTraceBeforeRefund.body.data.investigation.internal_notes[0].note,
    "Private synthetic staff note; participants must not see this.",
  );

  const traceInspector = await createFinancialInspector(config);
  const financialInspectorCaseRead = await caseReadCall(
    config,
    traceInspector.aal2Token,
    { action: "reviewer_detail", case_id: traceCaseId },
  );
  assert.equal(financialInspectorCaseRead.status, 403);
  async function advanceTraceRefund(expectedStatus) {
    const deadline = Date.now() + 15_000;
    do {
      const runResult = await runPaymentRunner(config);
      assert.equal(runResult.status, 200);
      const response = await caseReadCall(config, caseReviewer.aal2Token, {
        action: "reviewer_detail",
        case_id: traceCaseId,
      });
      assert.equal(response.status, 200, JSON.stringify(response.body));
      if (
        response.body.data.traceability.finalization.refund.status ===
        expectedStatus
      )
        return response;
      await delay(250);
    } while (Date.now() < deadline);
    assert.fail(`synthetic refund did not reach ${expectedStatus}`);
  }
  const refundCountBeforeTrace = simulator.stats().createdRefunds;
  simulator.programNext("refund", "unknown");
  const firstRefundRun = await runPaymentRunner(config);
  assert.equal(firstRefundRun.status, 200);
  const refundOperation = simulator.stats().refundDetails.at(-1);
  assert.equal(simulator.stats().createdRefunds, refundCountBeforeTrace + 1);
  assert.ok(refundOperation);
  const traceDuringRefund = await caseReadCall(config, caseReviewer.aal2Token, {
    action: "reviewer_detail",
    case_id: traceCaseId,
  });
  assert.equal(traceDuringRefund.status, 200);
  const refundTrace =
    traceDuringRefund.body.data.traceability.finalization.refund;
  assert.equal(refundTrace.status, "unknown");
  await assertTraceParticipantStatus("unknown");
  assert.ok(refundTrace.operation_id);
  assert.ok(refundTrace.operation_reference);
  assert.equal(
    traceDuringRefund.body.data.investigation.decision.public_explanation,
    participantDecision.details.public_explanation,
  );
  simulator.simulateSettlement(refundOperation.clientReference, "pending");
  const processingTrace = await advanceTraceRefund("processing");
  assert.equal(
    processingTrace.body.data.traceability.finalization.refund.operation_id,
    refundTrace.operation_id,
  );
  await assertTraceParticipantStatus("processing");
  simulator.simulateSettlement(refundOperation.clientReference, "settled");
  const settledReviewerTrace = await advanceTraceRefund("settled");
  await assertTraceParticipantStatus("settled");
  assert.equal(settledReviewerTrace.status, 200);
  const settledRefundTrace =
    settledReviewerTrace.body.data.traceability.finalization.refund;
  assert.equal(settledRefundTrace.status, "settled");
  assert.equal(
    settledRefundTrace.operation_reference,
    `sim-${refundOperation.clientReference}`,
  );
  assert.equal(
    settledRefundTrace.provider_refund_reference,
    `sim-${refundOperation.clientReference}`,
  );
  const inspection = await opsInspectionCall(config, traceInspector.aal2Token, {
    action: "trace",
    reference_type: "operation",
    reference_id: settledRefundTrace.operation_id,
  });
  assert.equal(inspection.status, 200, JSON.stringify(inspection.body));
  assert.ok(
    JSON.stringify(inspection.body).includes(refundOperation.clientReference),
  );
  assert.equal(simulator.stats().createdRefunds, refundCountBeforeTrace + 1);
  run(
    cli,
    [
      "db",
      "query",
      "--local",
      "--output-format",
      "json",
      `update app_private.staff_grants set revoked_at=pg_catalog.now(),
      revoked_by='${caseReviewer.user.id}'::uuid
     where user_id='${caseReviewer.user.id}'::uuid and capability='dispute_review'`,
    ],
    "revoke synthetic assigned-reviewer read grant",
    baseEnv,
    true,
  );
  const revokedTraceRead = await caseReadCall(config, caseReviewer.aal2Token, {
    action: "reviewer_detail",
    case_id: traceCaseId,
  });
  assert.equal(revokedTraceRead.status, 403);
  console.log(
    "TRACE Step 9 synthetic example",
    JSON.stringify({
      case_id: traceCaseId,
      assignment_id: traceAccepted.body.assignment.assignment_id,
      decision_version: traceProposal.body.result.decision_version,
      finalized_at:
        settledReviewerTrace.body.data.traceability.finalization.finalized_at,
      refund_operation_id: settledRefundTrace.operation_id,
      provider_reference: settledRefundTrace.provider_refund_reference,
      amount_kobo: settledRefundTrace.amount_kobo,
    }),
  );
  console.log(
    "PASS Step 9 case/refund traceability Edge HTTP: both parties see the same written refund decision and authorized/unknown/processing/settled status; only the assigned AAL2 reviewer sees approval/finalizer actors, timestamps and provider reference; unrelated scopes and private notes remain excluded; one refund operation",
  );

  const checkpointScript = resolve(root, "scripts/check-audit-checkpoint.mjs");
  const checkpointExportOutput = run(
    process.execPath,
    [checkpointScript, "export", "--require-events"],
    "export populated local financial audit checkpoint",
    baseEnv,
    true,
  );
  const checkpointLine = checkpointExportOutput
    .split(/\r?\n/)
    .find((line) => line.startsWith("AUDIT_CHECKPOINT_RESULT:"));
  assert.ok(checkpointLine, "populated checkpoint export returns its summary");
  retainedAuditCheckpoint = JSON.parse(
    checkpointLine.slice("AUDIT_CHECKPOINT_RESULT:".length),
  );
  assert.ok(BigInt(retainedAuditCheckpoint.event_count) > 0n);
  const checkpointSelfTestOutput = run(
    process.execPath,
    [checkpointScript, "self-test"],
    "verify populated checkpoint tampering and rollback controls",
    baseEnv,
    true,
  );
  for (const expected of [
    "PASS signed checkpoint verified using a separate trusted public-key file",
    "PASS edited checkpoint and untrusted forged signature were rejected",
    "PASS recomputed chain tampering and rollback before retained checkpoint were rejected",
  ])
    assert.ok(checkpointSelfTestOutput.includes(expected), expected);
  console.log(
    `PASS populated audit checkpoint exported and independently verified before synthetic cleanup: ${retainedAuditCheckpoint.event_count} event(s), head ${retainedAuditCheckpoint.head_position}; edited data, forged signature, recomputed tampering and rollback were rejected; public trust root and checkpoint retained outside the repository at ${retainedAuditCheckpoint.directory}`,
  );

  // The local Auth configuration intentionally expires test access tokens after 60 seconds.
  posterToken = await signIn(config, email, password);
  unverifiedToken = await signIn(config, unverifiedEmail, unverifiedPassword);
  for (const worker of mainWorkers)
    worker.token = await signIn(config, worker.email, worker.password);
  studentToken = mainWorkers[0].token;
  for (const applicant of additionalStudents)
    applicant.token = mainWorkers.find(
      (worker) => worker.id === applicant.user.id,
    ).token;
  for (const staff of [
    caseReviewer,
    independentApprover,
    appealReviewer,
    outOfScopeReviewer,
    caseSenior,
  ])
    Object.assign(staff, await refreshAal2(config, staff));

  const nonresponseCaseHold = await edgeCall(config, mainWorkers[2].token, {
    action: "open_assignment_hold",
    assignment_id: assignmentIds[2],
    reason_code: "work_not_as_described",
    narrative: "The submitted work does not match the accepted job terms.",
    desired_outcome: "Review the work and the accepted terms.",
    idempotency_key: randomUUID(),
  });
  assert.equal(nonresponseCaseHold.status, 201);
  const nonresponseCaseId = nonresponseCaseHold.body.hold.hold_id;
  const nonresponseReviewer = await createDisputeReviewer(
    config,
    "nonresponse-reviewer",
  );
  run(
    cli,
    [
      "db",
      "query",
      "--local",
      "--output-format",
      "json",
      `insert into app_private.staff_grants(user_id,capability,granted_by,reason)
       values('${nonresponseReviewer.user.id}'::uuid,'financial_approve',
         '${caseSenior.user.id}'::uuid,'Synthetic local Step 10 decision proposer approval grant.')`,
    ],
    "grant synthetic approval authority to the nonresponse decision proposer",
    baseEnv,
    true,
  );
  const nonresponseQueueAal1 = await caseReadCall(
    config,
    nonresponseReviewer.aal1Token,
    { action: "review_queue" },
  );
  assert.equal(nonresponseQueueAal1.status, 403);
  const nonresponseQueue = await caseReadCall(
    config,
    nonresponseReviewer.aal2Token,
    { action: "review_queue" },
  );
  assert.equal(nonresponseQueue.status, 200);
  assert.ok(
    nonresponseQueue.body.data.items.some(
      (item) => item.case_id === nonresponseCaseId,
    ),
  );
  const nonresponseAssignment = await caseCommandCall(
    config,
    nonresponseReviewer.aal2Token,
    {
      action: "assign_reviewer",
      case_id: nonresponseCaseId,
      reviewer_id: nonresponseReviewer.user.id,
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(nonresponseAssignment.status, 200);
  const contactPayload = {
    action: "log_case_contact_attempt",
    case_id: nonresponseCaseId,
    target_party_role: "poster",
    channel: "phone",
    result: "no_response",
    result_note: "No answer in the local manual log fixture.",
    idempotency_key: randomUUID(),
  };
  assert.equal(
    (
      await caseCommandCall(
        config,
        nonresponseReviewer.aal1Token,
        contactPayload,
      )
    ).status,
    403,
  );
  const substantiveNonresponseReason =
    "Two manual contact attempts across different channels received no reply. This records the limit on party input only; the financial recommendation remains based on the accepted work terms and the submitted work evidence.";
  const earlyNonresponseAssessment = await caseCommandCall(
    config,
    nonresponseReviewer.aal2Token,
    {
      action: "assess_case_nonresponse",
      case_id: nonresponseCaseId,
      target_party_role: "poster",
      substantive_reasoning: substantiveNonresponseReason,
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(earlyNonresponseAssessment.status, 409);
  const firstNonresponseContact = await caseCommandCall(
    config,
    nonresponseReviewer.aal2Token,
    contactPayload,
  );
  assert.equal(firstNonresponseContact.status, 200);
  assert.equal(
    firstNonresponseContact.body.result.attribution,
    "simulated_manual_log",
  );
  const secondNonresponseContact = await caseCommandCall(
    config,
    nonresponseReviewer.aal2Token,
    {
      ...contactPayload,
      channel: "email",
      result_note: "No reply in the local manual log fixture.",
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(secondNonresponseContact.status, 200);
  const nonresponseAssessment = await caseCommandCall(
    config,
    nonresponseReviewer.aal2Token,
    {
      action: "assess_case_nonresponse",
      case_id: nonresponseCaseId,
      target_party_role: "poster",
      substantive_reasoning: substantiveNonresponseReason,
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(nonresponseAssessment.status, 200);
  const [nonresponseAssessmentRow] = readLocalRows(
    `select assessment_id from app_private.assignment_case_nonresponse_assessments
     where case_id='${nonresponseCaseId}'::uuid
     order by created_at desc,assessment_id desc limit 1`,
    "read the synthetic initial nonresponse assessment identifier",
  );
  const seniorAssessmentAal1 = await caseCommandCall(
    config,
    caseSenior.aal1Token,
    {
      action: "signoff_case_nonresponse",
      case_id: nonresponseCaseId,
      assessment_id: nonresponseAssessmentRow.assessment_id,
      substantive_reasoning:
        "A separate senior confirms the current contact record and its limited purpose; it is not a decision about who receives money.",
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(seniorAssessmentAal1.status, 403);
  const seniorAssessmentSignoff = await caseCommandCall(
    config,
    caseSenior.aal2Token,
    {
      action: "signoff_case_nonresponse",
      case_id: nonresponseCaseId,
      assessment_id: nonresponseAssessmentRow.assessment_id,
      substantive_reasoning:
        "A separate senior confirms two distinct recorded channels and the reviewer reasoning. This sign-off documents non-response only; it does not decide the financial result.",
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(seniorAssessmentSignoff.status, 200);
  const nonresponseReviewerDetail = await caseReadCall(
    config,
    nonresponseReviewer.aal2Token,
    { action: "reviewer_detail", case_id: nonresponseCaseId },
  );
  assert.equal(nonresponseReviewerDetail.status, 200);
  assert.equal(
    nonresponseReviewerDetail.body.data.investigation.contact_attempts.length,
    2,
  );
  assert.equal(
    nonresponseReviewerDetail.body.data.investigation.contact_attempts[0]
      .attribution,
    "simulated_manual_log",
  );
  const nonresponseProposal = await caseCommandCall(
    config,
    nonresponseReviewer.aal2Token,
    {
      action: "propose_case_decision",
      case_id: nonresponseCaseId,
      expected_case_version: nonresponseReviewerDetail.body.data.version,
      outcome: "full_poster_refund",
      award_gross_kobo: "0",
      public_explanation:
        "The accepted work terms and submitted work support returning the held principal. The unsuccessful contact attempts do not decide the financial outcome.",
      nonresponse_assessment_id: nonresponseAssessmentRow.assessment_id,
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(nonresponseProposal.status, 200);
  const decisionSignoffAal1 = await caseCommandCall(
    config,
    caseSenior.aal1Token,
    {
      action: "signoff_decision_nonresponse",
      case_id: nonresponseCaseId,
      decision_version: nonresponseProposal.body.result.decision_version,
      expected_case_version: nonresponseProposal.body.result.case_version,
      substantive_reasoning:
        "This senior sign-off is bound to the exact proposed decision and confirms its reasoning relies on work and terms evidence rather than silence.",
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(decisionSignoffAal1.status, 403);
  const decisionSignoff = await caseCommandCall(config, caseSenior.aal2Token, {
    action: "signoff_decision_nonresponse",
    case_id: nonresponseCaseId,
    decision_version: nonresponseProposal.body.result.decision_version,
    expected_case_version: nonresponseProposal.body.result.case_version,
    substantive_reasoning:
      "This senior sign-off binds to the exact decision version and confirms that the proposed refund follows the accepted work terms and evidence. Non-response is recorded only as limited party input.",
    idempotency_key: randomUUID(),
  });
  assert.equal(decisionSignoff.status, 200);
  const nonresponseDecisionApproval = await caseCommandCall(
    config,
    independentApprover.aal2Token,
    {
      action: "approve_case_decision",
      case_id: nonresponseCaseId,
      decision_version: nonresponseProposal.body.result.decision_version,
      expected_case_version: decisionSignoff.body.result.case_version,
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(nonresponseDecisionApproval.status, 200);
  assert.equal(nonresponseDecisionApproval.body.result.approved, true);
  assert.equal(nonresponseDecisionApproval.body.result.approval_count, 2);
  assert.equal(
    nonresponseDecisionApproval.body.result.poster_refund_gross_kobo,
    "300000",
  );
  console.log(
    "PASS Step 10 non-response Edge HTTP: queue AAL2 scope, simulated two-channel contact logs, early assessment denial, independent current senior sign-off, and version-bound decision sign-off plus two distinct approval records; outcome reason cites work and terms rather than silence",
  );

  const heldRetry = await edgeCall(config, mainWorkers[1].token, {
    action: "open_assignment_hold",
    assignment_id: assignmentIds[1],
    reason_code: "work_not_as_described",
    narrative: "The delivered work differs from the accepted terms.",
    desired_outcome: "Please review the agreed description and delivery.",
    idempotency_key: holdKey,
  });
  assert.equal(heldRetry.status, 201);
  assert.equal(heldRetry.body.hold.hold_id, held.body.hold.hold_id);
  const heldConfirmation = await edgeCall(config, posterToken, {
    action: "confirm_completion",
    assignment_id: assignmentIds[1],
    idempotency_key: randomUUID(),
  });
  assert.equal(heldConfirmation.status, 409);
  assert.equal(heldConfirmation.body.error.code, "assignment_on_hold");
  const heldStatus = await readCall(config, posterToken, {
    action: "assignment_status",
    assignment_id: assignmentIds[1],
  });
  assert.equal(heldStatus.status, 200);
  assert.equal(heldStatus.body.data.assignment.assignment_state, "submitted");
  assert.equal(heldStatus.body.data.hold.prior_assignment_state, "submitted");
  const unconfirmedStatus = await readCall(config, mainWorkers[2].token, {
    action: "assignment_status",
    assignment_id: assignmentIds[2],
  });
  assert.equal(unconfirmedStatus.status, 200);
  assert.equal(
    unconfirmedStatus.body.data.assignment.earnings_status,
    "on_hold",
  );
  run(
    cli,
    [
      "db",
      "query",
      "--local",
      "--output-format",
      "json",
      `do $step7$ declare v_completed uuid:='${assignmentIds[0]}'::uuid;
        v_held uuid:='${assignmentIds[1]}'::uuid; v_submitted uuid:='${assignmentIds[2]}'::uuid;
        v_worker uuid:='${student.id}'::uuid;
      begin
        if (select count(*) from app_private.assignment_completion_authorizations
            where assignment_id=v_completed)<>1 then raise exception 'completion_authorization_count'; end if;
        if (select count(*) from app_private.ledger_journal_transactions
            where effect_type='completion_released' and reference_id=(select allocation_id
              from app_private.assignments where assignment_id=v_completed))<>1
          then raise exception 'completion_journal_count'; end if;
        if (select sum(b.credit_kobo-b.debit_kobo) from app_private.ledger_account_balances b
            join app_private.ledger_accounts a using(account_id)
            where a.account_code='worker_earnings_available' and b.owner_id=v_worker
              and b.allocation_id=(select allocation_id from app_private.assignments
                where assignment_id=v_completed))<>285000 then raise exception 'worker_net_projection'; end if;
        if (select status from app_private.principal_allocations where assignment_id=v_held)<>'dispute_held'
          then raise exception 'hold_allocation_state'; end if;
        if (select count(*) from app_private.assignment_holds where assignment_id=v_held and status='open')<>1
          then raise exception 'active_hold_count'; end if;
        if (select work_state from app_private.assignments where assignment_id=v_held)<>'submitted'
          then raise exception 'held_stage_not_preserved'; end if;
        if (select count(*) from app_private.ledger_journal_transactions
            where effect_type='completion_released' and reference_id=(select allocation_id
              from app_private.assignments where assignment_id=v_held))<>0
          then raise exception 'held_completion_effect'; end if;
        if (select work_state from app_private.assignments where assignment_id=v_submitted)<>'submitted'
          or (select status from app_private.principal_allocations where assignment_id=v_submitted)<>'dispute_held'
          then raise exception 'submitted_assignment_state'; end if;
        if (select count(*) from app_private.ledger_journal_entries e
            join app_private.ledger_journal_transactions j using(journal_id)
            where j.effect_type='completion_released' and j.reference_id=(select allocation_id
              from app_private.assignments where assignment_id=v_submitted))<>0
          then raise exception 'submitted_assignment_has_earnings'; end if;
      end $step7$`,
    ],
    "verify completion, held principal, and submitted-but-unconfirmed balances",
    baseEnv,
    true,
  );
  console.log(
    "PASS Step 7 Edge HTTP: assigned worker started/submitted, poster confirmed once (NGN 2,850 net/NGN 150 commission), and a separate held assignment stayed unpaid",
  );

  const caseHeldWallet = await walletReadCall(config, mainWorkers[1].token, {
    action: "get_my_wallet",
  });
  assert.equal(caseHeldWallet.status, 200);
  assert.equal(caseHeldWallet.body.data.balances.case_held_kobo, "300000");
  const unconfirmedWallet = await walletReadCall(config, mainWorkers[2].token, {
    action: "get_my_wallet",
  });
  assert.equal(unconfirmedWallet.status, 200);
  assert.equal(unconfirmedWallet.body.data.balances.held_allocations_kobo, "0");
  assert.equal(unconfirmedWallet.body.data.balances.case_held_kobo, "300000");
  assert.equal(
    unconfirmedWallet.body.data.balances.available_earnings_kobo,
    "0",
  );
  const anonymousWallet = await walletReadCall(config, null, {
    action: "get_my_wallet",
  });
  assert.equal(anonymousWallet.status, 401);
  const unverifiedWallet = await walletReadCall(config, unverifiedToken, {
    action: "get_my_wallet",
  });
  assert.equal(unverifiedWallet.status, 403);
  const ownWallet = await walletReadCall(config, mainWorkers[0].token, {
    action: "get_my_wallet",
  });
  assert.equal(ownWallet.status, 200);
  assert.equal(ownWallet.body.data.currency, "NGN");
  assert.equal(ownWallet.body.data.balances.available_earnings_kobo, "285000");
  assert.equal(ownWallet.body.data.balances.withdrawal_reserved_kobo, "0");
  assert.equal(ownWallet.body.data.refunds_available, false);
  assert.equal(ownWallet.body.data.destination, null);
  assert.equal("provider_payload" in ownWallet.body.data, false);

  const feeReserveEffect = randomUUID();
  simulator.recordPlatformCapital("5000");
  run(
    cli,
    [
      "db",
      "query",
      "--local",
      "--output-format",
      "json",
      `select app_private.post_financial_journal('${feeReserveEffect}'::uuid,
        'platform_capital_contribution',null,null,jsonb_build_array(
          jsonb_build_object('account_code','platform_fee_reserve_cash','direction','debit','amount_kobo','5000'),
          jsonb_build_object('account_code','platform_capital_contributed','direction','credit','amount_kobo','5000')))`,
    ],
    "record explicit local platform capital for payout fee coverage",
    baseEnv,
    true,
  );

  const wrongPassword = await walletCall(config, mainWorkers[0].token, {
    action: "authorize_simulated_destination_change",
    destination_id: null,
    expected_version: 0,
    simulated_recipient_code: "fake_recipient_alpha",
    password: "wrong-local-password",
  });
  assert.equal(wrongPassword.status, 403);
  assert.equal(wrongPassword.body.error.code, "confirmation_required");
  const destinationAuthorization = await walletCall(
    config,
    mainWorkers[0].token,
    {
      action: "authorize_simulated_destination_change",
      destination_id: null,
      expected_version: 0,
      simulated_recipient_code: "fake_recipient_alpha",
      password: studentPassword,
    },
  );
  assert.equal(destinationAuthorization.status, 200);
  const destinationProof =
    destinationAuthorization.body.data.authorization_token;
  const destinationId = destinationAuthorization.body.data.destination_id;
  assert.equal(
    destinationAuthorization.body.data.destination.destination_version,
    1,
  );
  const destination = await walletCall(config, mainWorkers[0].token, {
    action: "confirm_simulated_destination_change",
    authorization_token: destinationProof,
    simulated_recipient_code: "fake_recipient_alpha",
    idempotency_key: randomUUID(),
  });
  assert.equal(destination.status, 200);
  assert.equal(destination.body.data.destination_version, 1);
  assert.equal(destination.body.data.ownership_verification, "simulator_only");
  assert.equal("account_number" in destination.body.data, false);

  const staleDestinationProof = await walletCall(config, mainWorkers[0].token, {
    action: "authorize_withdrawal",
    amount_kobo: "1",
    destination_id: destinationId,
    destination_version: 1,
    password: studentPassword,
  });
  assert.equal(staleDestinationProof.status, 200);
  const secondDestinationAuthorization = await walletCall(
    config,
    mainWorkers[0].token,
    {
      action: "authorize_simulated_destination_change",
      destination_id: destinationId,
      expected_version: 1,
      simulated_recipient_code: "fake_recipient_beta",
      password: studentPassword,
    },
  );
  assert.equal(secondDestinationAuthorization.status, 200);
  const secondDestination = await walletCall(config, mainWorkers[0].token, {
    action: "confirm_simulated_destination_change",
    authorization_token:
      secondDestinationAuthorization.body.data.authorization_token,
    simulated_recipient_code: "fake_recipient_beta",
    idempotency_key: randomUUID(),
  });
  assert.equal(secondDestination.status, 200);
  assert.equal(secondDestination.body.data.destination_version, 2);
  const stalePayout = await walletCall(config, mainWorkers[0].token, {
    action: "request_withdrawal",
    amount_kobo: "1",
    destination_id: destinationId,
    destination_version: 1,
    authorization_token: staleDestinationProof.body.data.authorization_token,
    idempotency_key: randomUUID(),
  });
  assert.equal(stalePayout.status, 404);

  const withdrawalProofs = await Promise.all([
    walletCall(config, mainWorkers[0].token, {
      action: "authorize_withdrawal",
      amount_kobo: "285000",
      destination_id: destinationId,
      destination_version: 2,
      password: studentPassword,
    }),
    walletCall(config, mainWorkers[0].token, {
      action: "authorize_withdrawal",
      amount_kobo: "285000",
      destination_id: destinationId,
      destination_version: 2,
      password: studentPassword,
    }),
  ]);
  assert.deepEqual(
    withdrawalProofs.map((result) => result.status),
    [200, 200],
  );
  const withdrawalRequests = await Promise.all(
    withdrawalProofs.map((proof) =>
      walletCall(config, mainWorkers[0].token, {
        action: "request_withdrawal",
        amount_kobo: "285000",
        destination_id: destinationId,
        destination_version: 2,
        authorization_token: proof.body.data.authorization_token,
        idempotency_key: randomUUID(),
      }),
    ),
  );
  assert.equal(
    withdrawalRequests.filter((result) => result.status === 201).length,
    1,
  );
  assert.equal(
    withdrawalRequests.filter((result) => result.status === 409).length,
    1,
  );
  const withdrawalRequest = withdrawalRequests.find(
    (result) => result.status === 201,
  );
  assert.equal(withdrawalRequest.body.data.amount_kobo, "285000");
  assert.equal(withdrawalRequest.body.data.destination.destination_version, 2);
  assert.equal(withdrawalRequest.body.data.status, "processing");
  const overpostedStatus = await walletCall(config, mainWorkers[0].token, {
    action: "request_withdrawal",
    amount_kobo: "285000",
    destination_id: destinationId,
    destination_version: 2,
    authorization_token: withdrawalProofs[0].body.data.authorization_token,
    idempotency_key: randomUUID(),
    provider_status: "paid",
  });
  assert.equal(overpostedStatus.status, 400);
  simulator.programNext("payout", "success", { feeKobo: "20000" });
  const payoutRunner = await runPaymentRunner(config);
  assert.equal(payoutRunner.status, 200);
  assert.equal(payoutRunner.body.result.operation_status, "succeeded");
  assert.equal(payoutRunner.body.result.withdrawal_status, "paid");
  const firstPayoutReference = simulator.stats().payoutClientReferences[0];
  assert.ok(firstPayoutReference);
  assert.deepEqual(simulator.stats().payoutDetails[0], {
    clientReference: firstPayoutReference,
    amountKobo: "285000",
    feeKobo: "20000",
    destinationId,
    destinationVersion: 2,
    status: "succeeded",
  });
  assert.equal(simulator.stats().createdPayouts, 1);
  const paidWallet = await walletReadCall(config, mainWorkers[0].token, {
    action: "get_my_wallet",
  });
  assert.equal(paidWallet.body.data.balances.available_earnings_kobo, "0");
  assert.equal(paidWallet.body.data.balances.withdrawal_reserved_kobo, "0");
  assert.ok(
    paidWallet.body.data.activity.some(
      (item) => item.activity_type === "withdrawal_paid",
    ),
  );

  simulator.reverseOperation(firstPayoutReference);
  const reversalEvent = simulator.makeEvent({
    eventReference: `payout-reversal-${randomUUID()}`,
    idempotencyKey: firstPayoutReference,
    status: "reversed",
    amountKobo: "285000",
  });
  const reversalReceipt = await sendSimulatorEvent(config, reversalEvent);
  assert.equal(reversalReceipt.status, 200);
  const reversalRunner = await runPaymentRunner(config);
  assert.equal(reversalRunner.status, 200);
  assert.equal(reversalRunner.body.result.operation_status, "reversed");
  assert.equal(reversalRunner.body.result.withdrawal_status, "reversed");
  const reversedWallet = await walletReadCall(config, mainWorkers[0].token, {
    action: "get_my_wallet",
  });
  assert.equal(
    reversedWallet.body.data.balances.available_earnings_kobo,
    "285000",
  );

  const reversalFeeReserveEffect = randomUUID();
  simulator.recordPlatformCapital("20000");
  run(
    cli,
    [
      "db",
      "query",
      "--local",
      "--output-format",
      "json",
      `select app_private.post_financial_journal('${reversalFeeReserveEffect}'::uuid,
        'platform_capital_contribution',null,null,jsonb_build_array(
          jsonb_build_object('account_code','platform_fee_reserve_cash','direction','debit','amount_kobo','20000'),
          jsonb_build_object('account_code','platform_capital_contributed','direction','credit','amount_kobo','20000')))`,
    ],
    "record platform capital for the unreimbursed simulated payout fee after reversal",
    baseEnv,
    true,
  );

  const failureProof = await walletCall(config, mainWorkers[0].token, {
    action: "authorize_withdrawal",
    amount_kobo: "285000",
    destination_id: destinationId,
    destination_version: 2,
    password: studentPassword,
  });
  assert.equal(failureProof.status, 200);
  const failureRequest = await walletCall(config, mainWorkers[0].token, {
    action: "request_withdrawal",
    amount_kobo: "285000",
    destination_id: destinationId,
    destination_version: 2,
    authorization_token: failureProof.body.data.authorization_token,
    idempotency_key: randomUUID(),
  });
  assert.equal(failureRequest.status, 201);
  simulator.programNext("payout", "known_failure", { feeKobo: "20000" });
  const failedRunner = await runPaymentRunner(config);
  assert.equal(failedRunner.status, 200);
  assert.equal(failedRunner.body.result.operation_status, "failed");
  assert.equal(failedRunner.body.result.withdrawal_status, "failed");
  assert.equal(simulator.stats().createdPayouts, 2);
  const failedWallet = await walletReadCall(config, mainWorkers[0].token, {
    action: "get_my_wallet",
  });
  assert.equal(
    failedWallet.body.data.balances.available_earnings_kobo,
    "285000",
  );
  assert.equal(failedWallet.body.data.balances.withdrawal_reserved_kobo, "0");

  const retryFeeReserveEffect = randomUUID();
  simulator.recordPlatformCapital("20000");
  run(
    cli,
    [
      "db",
      "query",
      "--local",
      "--output-format",
      "json",
      `select app_private.post_financial_journal('${retryFeeReserveEffect}'::uuid,
        'platform_capital_contribution',null,null,jsonb_build_array(
          jsonb_build_object('account_code','platform_fee_reserve_cash','direction','debit','amount_kobo','20000'),
          jsonb_build_object('account_code','platform_capital_contributed','direction','credit','amount_kobo','20000')))`,
    ],
    "record separately sourced local capital for the next payout fee",
    baseEnv,
    true,
  );

  const timeoutProof = await walletCall(config, mainWorkers[0].token, {
    action: "authorize_withdrawal",
    amount_kobo: "285000",
    destination_id: destinationId,
    destination_version: 2,
    password: studentPassword,
  });
  assert.equal(timeoutProof.status, 200);
  const timeoutRequest = await walletCall(config, mainWorkers[0].token, {
    action: "request_withdrawal",
    amount_kobo: "285000",
    destination_id: destinationId,
    destination_version: 2,
    authorization_token: timeoutProof.body.data.authorization_token,
    idempotency_key: randomUUID(),
  });
  assert.equal(timeoutRequest.status, 201);
  simulator.programNext("payout", "timeout_after_acceptance", {
    feeKobo: "20000",
  });
  const unknownRunner = await runPaymentRunner(config);
  assert.equal(unknownRunner.status, 200);
  assert.equal(unknownRunner.body.result.operation_status, "unknown");
  assert.equal(unknownRunner.body.result.withdrawal_status, "unknown");
  const unknownWallet = await walletReadCall(config, mainWorkers[0].token, {
    action: "get_my_wallet",
  });
  assert.equal(unknownWallet.body.data.balances.available_earnings_kobo, "0");
  assert.equal(
    unknownWallet.body.data.balances.withdrawal_unknown_kobo,
    "285000",
  );
  assert.equal(
    unknownWallet.body.data.balances.withdrawal_reserved_kobo,
    "285000",
  );
  await delay(2500);
  const recoveredRunner = await runPaymentRunner(config);
  assert.equal(recoveredRunner.status, 200);
  assert.equal(recoveredRunner.body.result.operation_status, "succeeded");
  assert.equal(recoveredRunner.body.result.withdrawal_status, "paid");
  assert.equal(simulator.stats().createdPayouts, 3);
  assert.equal(simulator.stats().payoutDetails[2].amountKobo, "285000");

  const repeatedSuccessEvent = simulator.makeEvent({
    eventReference: `payout-success-${randomUUID()}`,
    idempotencyKey: simulator.stats().payoutClientReferences[2],
    status: "succeeded",
    amountKobo: "285000",
  });
  assert.equal(
    (await sendSimulatorEvent(config, repeatedSuccessEvent)).status,
    200,
  );
  const repeatedRunner = await runPaymentRunner(config);
  assert.equal(repeatedRunner.status, 200);
  assert.equal(repeatedRunner.body.result.withdrawal_status, "paid");
  assert.equal(simulator.stats().createdPayouts, 3);
  const payoutAccounting = run(
    cli,
    [
      "db",
      "query",
      "--local",
      "--output-format",
      "json",
      `do $wallet$ declare v_job uuid:='${jobId}'::uuid;
        v_worker uuid:='${mainWorkers[0].id}'::uuid;
      begin
        if (select sum(b.balance_kobo) from app_private.ledger_account_balances b
            join app_private.ledger_accounts a using(account_id)
            where a.account_code='provider_available_cash' and b.owner_id is null
              and b.allocation_id is null)<>600000 then raise exception 'cash_must_preserve_other_slots'; end if;
        if (select sum(p.gross_principal_kobo) from app_private.principal_allocations p
            where p.job_id=v_job and p.status in ('assigned','dispute_held'))<>600000
          then raise exception 'other_worker_principal_changed'; end if;
        if (select count(*) from app_private.ledger_journal_transactions
            where effect_type='payout_settled')<>2 then raise exception 'payout_journal_count'; end if;
        if (select count(*) from app_private.ledger_journal_transactions
            where effect_type='compensating_correction')<>2 then raise exception 'failure_and_reversal_compensation_count'; end if;
        if (select sum(b.balance_kobo) from app_private.ledger_account_balances b
            join app_private.ledger_accounts a using(account_id)
            where a.account_code='provider_payout_fee_expense' and b.owner_id is null
              and b.allocation_id is null)<>60000 then raise exception 'provider_fee_expense_conservation'; end if;
        if (select sum(b.credit_kobo-b.debit_kobo) from app_private.ledger_account_balances b
            join app_private.ledger_accounts a using(account_id)
            where a.account_code='worker_withdrawal_reserved' and b.owner_id=v_worker)<>0
          then raise exception 'worker_reservation_not_cleared'; end if;
      end $wallet$`,
    ],
    "verify payout retries preserve the other slots and post each payout once",
    baseEnv,
    true,
  );
  assert.equal(payoutAccounting.trim(), "DO");
  console.log(
    "PASS Step 8 Edge HTTP: fresh-password destination versioning, 2,850-kobo-string wallet, concurrent single reservation, fee reserve, authoritative failure/reversal, lost-response lookup and duplicate success reconciliation",
  );

  const raceDeadline = new Date(Date.now() + 8_000).toISOString();
  const raceTerms = {
    ...terms,
    title: "Synthetic final-slot race",
    gross_per_worker_kobo: "120000",
    slot_count: 1,
    application_deadline_at: raceDeadline,
    needed_by_at: new Date(Date.parse(raceDeadline) + 86_400_000).toISOString(),
  };
  const raceDraft = await edgeCall(config, posterToken, {
    action: "create_job_draft",
    idempotency_key: randomUUID(),
    terms: raceTerms,
  });
  assert.equal(raceDraft.status, 201);
  const raceJobId = raceDraft.body.job.job_id;
  const raceFunding = await edgeCall(config, posterToken, {
    action: "fund_job",
    job_id: raceJobId,
    expected_terms_version: 1,
    idempotency_key: randomUUID(),
  });
  assert.equal(raceFunding.status, 202);
  await settleCollection(config, raceFunding.body);
  const competingApplicants = [studentToken, additionalStudents[0].token];
  const raceApplications = await Promise.all(
    competingApplicants.map(async (token) => {
      const result = await edgeCall(config, token, {
        action: "apply_to_job",
        job_id: raceJobId,
        idempotency_key: randomUUID(),
      });
      assert.equal(result.status, 201);
      return result.body.application;
    }),
  );
  assert.ok(raceApplications.every((row) => row.state === "applied"));
  await delay(Math.max(0, Date.parse(raceDeadline) - Date.now() + 100));
  const acceptSql = raceApplications.map(
    (row) =>
      `select public.server_accept_application_for_actor('${poster.id}'::uuid,'${row.application_id}'::uuid,'${randomUUID()}'::uuid)`,
  );
  const raceResults = await Promise.all(
    acceptSql.map((sql) => runDatabaseQueryInOwnProcess(sql)),
  );
  assert.equal(
    raceResults.filter((result) => result.status === 0).length,
    1,
    "exactly one separate database connection accepts the final slot",
  );
  const raceLoser = raceResults.find((result) => result.status !== 0);
  assert.match(raceLoser.output, /slot_unavailable/);

  const raceApplicationsAfter = await readCall(config, posterToken, {
    action: "job_applications",
    job_id: raceJobId,
  });
  assert.equal(raceApplicationsAfter.status, 200);
  const raceAcceptedRows = raceApplicationsAfter.body.data.items.filter(
    (row) => row.state === "accepted",
  );
  const racePendingRows = raceApplicationsAfter.body.data.items.filter(
    (row) => row.state === "applied",
  );
  assert.equal(raceAcceptedRows.length, 1);
  assert.equal(racePendingRows.length, 1);
  assert.ok(raceAcceptedRows[0].assignment_id);
  assert.equal(racePendingRows[0].assignment_id, null);
  const raceHistory = await readCall(config, posterToken, {
    action: "my_job_history",
  });
  assert.equal(
    raceHistory.body.data.items.find((item) => item.job_id === raceJobId)
      .history_state,
    "filled",
  );
  const raceInvariantSql = `
    do $step6$ declare v_job uuid:='${raceJobId}'::uuid;
      v_intent uuid:='${raceFunding.body.funding_intent_id}'::uuid;
    begin
      if (select count(*) from app_private.assignments where job_id=v_job)<>1
        then raise exception 'race_assignment_count'; end if;
      if (select count(*) from app_private.principal_allocations
          where job_id=v_job and status='assigned' and assignment_id is not null)<>1
        then raise exception 'race_allocation_count'; end if;
      if exists(select 1 from app_private.assignments s
          left join app_private.principal_allocations p
            on p.allocation_id=s.allocation_id and p.assignment_id=s.assignment_id
          where s.job_id=v_job and p.allocation_id is null)
        then raise exception 'race_allocation_binding'; end if;
      if (select count(*) from app_private.ledger_journal_transactions
          where reference_id=v_intent)<>1
        then raise exception 'acceptance_posted_financial_effect'; end if;
      if (select count(*) from app_private.marketplace_outbox
          where job_id=v_job and event_type='job.application_accepted')<>1
        then raise exception 'acceptance_event_count'; end if;
      if (select count(*) from app_private.in_app_notifications n
          join app_private.marketplace_outbox e using(event_id)
          where e.job_id=v_job and e.event_type='job.application_accepted'
            and n.notification_type='application_accepted')<>2
        then raise exception 'acceptance_notice_count'; end if;
      if exists(select 1 from app_private.in_app_notifications n
          join app_private.marketplace_outbox e using(event_id)
          where e.job_id=v_job and e.event_type='job.application_accepted'
          group by n.event_id,n.recipient_id,n.notification_type having count(*)>1)
        then raise exception 'duplicate_acceptance_notice'; end if;
      if (select count(*) from app_private.job_applications
          where job_id=v_job and state='applied')<>1
        then raise exception 'losing_application_not_retained'; end if;
    end $step6$;
  `;
  run(
    cli,
    ["db", "query", "--local", "--output-format", "json", raceInvariantSql],
    "verify concurrent acceptance allocation, journal and notice invariants",
    baseEnv,
    true,
  );
  console.log(
    "PASS two independent database processes raced after the application deadline; one assignment and its assigned allocation were committed",
  );

  const acceptedRaceApplication = raceApplications.find(
    (row) => row.application_id === raceAcceptedRows[0].application_id,
  );
  const acceptedRaceIndex = raceApplications.indexOf(acceptedRaceApplication);
  const raceWorker = [studentToken, additionalStudents[0].token][
    acceptedRaceIndex
  ];
  const raceAssignmentId = raceAcceptedRows[0].assignment_id;
  const raceStart = await edgeCall(config, raceWorker, {
    action: "start_assignment",
    assignment_id: raceAssignmentId,
    idempotency_key: randomUUID(),
  });
  assert.equal(raceStart.status, 200);
  const raceSubmit = await edgeCall(config, raceWorker, {
    action: "submit_assignment",
    assignment_id: raceAssignmentId,
    idempotency_key: randomUUID(),
  });
  assert.equal(raceSubmit.status, 200);
  const completionRace = await Promise.all([
    edgeCall(config, posterToken, {
      action: "confirm_completion",
      assignment_id: raceAssignmentId,
      idempotency_key: randomUUID(),
    }),
    edgeCall(config, raceWorker, {
      action: "open_assignment_hold",
      assignment_id: raceAssignmentId,
      reason_code: "incomplete_work",
      narrative: "Concurrent participant report.",
      desired_outcome: "Please review the submission.",
      idempotency_key: randomUUID(),
    }),
  ]);
  assert.equal(
    completionRace.filter((result) => result.status < 300).length,
    1,
    "exactly one concurrent Edge command wins the confirmation versus hold race",
  );
  assert.ok(
    ["assignment_on_hold", "stale_state"].includes(
      completionRace.find((result) => result.status >= 300).body?.error?.code,
    ),
    "the losing Edge command reports the committed assignment state",
  );
  const raceAssignmentStatus = await readCall(config, raceWorker, {
    action: "assignment_status",
    assignment_id: raceAssignmentId,
  });
  assert.equal(raceAssignmentStatus.status, 200);
  assert.ok(
    (raceAssignmentStatus.body.data.assignment.assignment_state ===
      "completed" &&
      raceAssignmentStatus.body.data.hold === null) ||
      (raceAssignmentStatus.body.data.assignment.assignment_state ===
        "submitted" &&
        raceAssignmentStatus.body.data.hold?.status === "open"),
  );
  console.log(
    "PASS concurrent confirm-versus-hold through actual Edge HTTP: one result committed and assignment status agrees",
  );

  const expiringTerms = {
    ...terms,
    title: "Synthetic deadline task",
    gross_per_worker_kobo: "100000",
    slot_count: 1,
    application_deadline_at: new Date(Date.now() + 3_000).toISOString(),
  };
  const expiringDraft = await edgeCall(config, posterToken, {
    action: "create_job_draft",
    idempotency_key: randomUUID(),
    terms: expiringTerms,
  });
  assert.equal(expiringDraft.status, 201);
  const expiringJobId = expiringDraft.body.job.job_id;
  const expiringFunding = await edgeCall(config, posterToken, {
    action: "fund_job",
    job_id: expiringJobId,
    expected_terms_version: 1,
    idempotency_key: randomUUID(),
  });
  assert.equal(expiringFunding.status, 202);
  await delay(3_200);
  const expiringProviderKey = expiringFunding.body.provider_reference.slice(
    "sim-".length,
  );
  simulator.simulateSettlement(expiringProviderKey, "succeeded");
  const expiryRunnerResponse = await fetch(
    `${config.apiUrl}/functions/v1/payment-operation-runner`,
    {
      method: "POST",
      headers: {
        apikey: config.anonKey,
        authorization: `Bearer ${baseEnv.NBD_PAYMENT_RUNNER_SECRET}`,
      },
    },
  );
  assert.equal(expiryRunnerResponse.status, 200);
  const expiredStatus = await edgeCall(config, posterToken, {
    action: "funding_status",
    job_id: expiringJobId,
  });
  assert.equal(
    expiredStatus.status,
    200,
    JSON.stringify({
      response: expiredStatus.body,
      seconds_until_token_expiry:
        JSON.parse(
          Buffer.from(posterToken.split(".")[1], "base64url").toString(),
        ).exp - Math.floor(Date.now() / 1000),
    }),
  );
  assert.equal(expiredStatus.body.funding.listing_state, "expired");
  const expiredDetail = await readCall(config, posterToken, {
    action: "job_detail",
    job_id: expiringJobId,
  });
  assert.equal(expiredDetail.status, 404);
  posterToken = await signIn(config, email, password);
  const afterExpiryHistory = await readCall(config, posterToken, {
    action: "my_job_history",
  });
  assert.equal(
    afterExpiryHistory.status,
    200,
    JSON.stringify(afterExpiryHistory.body),
  );
  assert.ok(
    afterExpiryHistory.body.data.items.some(
      (item) =>
        item.job_id === expiringJobId && item.history_state === "expired",
    ),
  );
  run(
    cli,
    [
      "db",
      "query",
      "--local",
      "--output-format",
      "json",
      `do $step7_expiry$ declare v_job uuid:='${expiringJobId}'::uuid;
        v_intent uuid:='${expiringFunding.body.funding_intent_id}'::uuid;
      begin
        if (select count(*) from app_private.principal_allocations
            where job_id=v_job and status='unassigned')<>1
          then raise exception 'expired_principal_not_held'; end if;
        if (select count(*) from app_private.ledger_journal_transactions
            where reference_id=v_intent and effect_type='funding_collected')<>1
          then raise exception 'expired_funding_effect_changed'; end if;
        if (select count(*) from app_private.ledger_journal_transactions
            where reference_id=v_intent and effect_type<>'funding_collected')<>0
          then raise exception 'automatic_expiry_movement'; end if;
      end $step7_expiry$`,
    ],
    "verify deadline expiry retains funded principal without a refund or release",
    baseEnv,
    true,
  );
  console.log(
    "PASS expired funded listing retained its unassigned principal; deadline caused no refund or release",
  );

  run(
    cli,
    [
      "db",
      "query",
      "--local",
      "--output-format",
      "json",
      `update app_private.identity_accounts set account_status='suspended' where user_id='${poster.id}'::uuid`,
    ],
    "suspend synthetic marketplace reader",
    baseEnv,
    true,
  );
  const suspendedDiscovery = await readCall(config, posterToken, {
    action: "discover_jobs",
    filters: {},
  });
  assert.equal(suspendedDiscovery.status, 403);
  const suspendedHistory = await readCall(config, posterToken, {
    action: "my_job_history",
  });
  assert.equal(suspendedHistory.status, 200);
  const suspendedHistoricalDetail = await readCall(config, posterToken, {
    action: "my_job_detail",
    job_id: jobId,
  });
  assert.equal(suspendedHistoricalDetail.status, 200);
  run(
    cli,
    [
      "db",
      "query",
      "--local",
      "--output-format",
      "json",
      `update app_private.identity_accounts set account_status='active' where user_id='${poster.id}'::uuid`,
    ],
    "restore synthetic marketplace reader",
    baseEnv,
    true,
  );

  const directGateway = await fetch(
    `${config.apiUrl}/rest/v1/rpc/server_start_job_funding_for_actor`,
    {
      method: "POST",
      headers: {
        apikey: config.anonKey,
        authorization: `Bearer ${posterToken}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        p_actor: poster.id,
        p_job_id: jobId,
        p_expected_terms_version: 2,
        p_idempotency_key: fundingKey,
      }),
    },
  );
  assert.ok([401, 403].includes(directGateway.status));

  const posterNotices = await notificationsReadCall(config, posterToken, {
    action: "list",
  });
  assert.equal(
    posterNotices.status,
    200,
    `poster notice list: HTTP ${posterNotices.status} (${posterNotices.body?.error?.code ?? "no_error_code"})`,
  );
  const allPosterNotices = [...posterNotices.body.data.notifications];
  let posterNoticeCursor = posterNotices.body.data.next_cursor;
  for (let page = 1; posterNoticeCursor !== null && page < 10; page++) {
    const nextPage = await notificationsReadCall(config, posterToken, {
      action: "list",
      cursor: posterNoticeCursor,
    });
    assert.equal(nextPage.status, 200, JSON.stringify(nextPage.body));
    allPosterNotices.push(...nextPage.body.data.notifications);
    posterNoticeCursor = nextPage.body.data.next_cursor;
  }
  assert.equal(
    posterNoticeCursor,
    null,
    "synthetic notice history is bounded to ten pages",
  );
  const posterNoticeTypes = allPosterNotices.map(
    (notice) => notice.notification_type,
  );
  for (const required of [
    "application_received",
    "application_accepted",
    "assignment_submitted",
    "assignment_completed",
  ])
    assert.ok(
      posterNoticeTypes.includes(required),
      `poster notice ${required}`,
    );

  const workerNotices = await notificationsReadCall(
    config,
    mainWorkers[0].token,
    { action: "list" },
  );
  assert.equal(
    workerNotices.status,
    200,
    `worker notice list: HTTP ${workerNotices.status} (${workerNotices.body?.error?.code ?? "no_error_code"})`,
  );
  const workerNoticeTypes = workerNotices.body.data.notifications.map(
    (notice) => notice.notification_type,
  );
  for (const required of [
    "application_accepted",
    "assignment_completed",
    "withdrawal_requested",
    "withdrawal_unknown",
    "withdrawal_paid",
    "withdrawal_failed",
    "withdrawal_reversed",
  ])
    assert.ok(
      workerNoticeTypes.includes(required),
      `worker notice ${required}`,
    );
  const paidNotice = workerNotices.body.data.notifications.find(
    (notice) => notice.notification_type === "withdrawal_paid",
  );
  const crossRecipientRead = await notificationsReadCall(
    config,
    mainWorkers[1].token,
    { action: "mark_read", notification_id: paidNotice.notification_id },
  );
  assert.equal(crossRecipientRead.status, 404);
  const ownRead = await notificationsReadCall(config, mainWorkers[0].token, {
    action: "mark_read",
    notification_id: paidNotice.notification_id,
  });
  assert.equal(
    ownRead.status,
    200,
    `recipient mark-read: HTTP ${ownRead.status} (${ownRead.body?.error?.code ?? "no_error_code"})`,
  );
  assert.ok(ownRead.body.data.read_at);
  const anonymousNotices = await notificationsReadCall(config, null, {
    action: "list",
  });
  assert.equal(anonymousNotices.status, 401);

  const inspector = await createFinancialInspector(config);
  const ungrantedInspector = await createUngrantedAal2Inspector(config);
  const aal1Inspection = await opsInspectionCall(config, inspector.aal1Token, {
    action: "trace",
    reference_type: "job",
    reference_id: jobId,
  });
  assert.equal(aal1Inspection.status, 403);
  const aal2WithoutGrant = await opsInspectionCall(
    config,
    ungrantedInspector.aal2Token,
    { action: "trace", reference_type: "job", reference_id: jobId },
  );
  assert.equal(aal2WithoutGrant.status, 403);
  const unauthorizedInspection = await opsInspectionCall(config, posterToken, {
    action: "trace",
    reference_type: "job",
    reference_id: jobId,
  });
  assert.equal(unauthorizedInspection.status, 403);
  const tracedJob = await opsInspectionCall(config, inspector.aal2Token, {
    action: "trace",
    reference_type: "job",
    reference_id: jobId,
  });
  if (tracedJob.status !== 200) {
    const diagnostic = await fetch(
      `${config.apiUrl}/rest/v1/rpc/server_inspect_financial_reference_for_actor`,
      {
        method: "POST",
        headers: {
          apikey: config.serviceKey,
          authorization: `Bearer ${config.serviceKey}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          p_actor: inspector.user.id,
          p_auth_aal: "aal2",
          p_reference_type: "job",
          p_reference_value: jobId,
        }),
      },
    );
    const diagnosticBody = await diagnostic.json().catch(() => null);
    throw new Error(
      `financial trace failed at HTTP ${tracedJob.status} (${tracedJob.body?.error?.code ?? "unknown"}); direct local RPC HTTP ${diagnostic.status}: ${JSON.stringify({ code: diagnosticBody?.code, message: diagnosticBody?.message, details: diagnosticBody?.details, hint: diagnosticBody?.hint })}`,
    );
  }
  assert.equal(
    tracedJob.status,
    200,
    `financial trace: HTTP ${tracedJob.status} (${tracedJob.body?.error?.code ?? "no_error_code"})`,
  );
  assert.equal(tracedJob.body.data.reference, jobId);
  assert.equal(tracedJob.body.data.jobs[0].job_id, jobId);
  assert.equal(tracedJob.body.data.allocations.length, 3);
  assert.equal(tracedJob.body.data.audit_integrity_valid, true);
  assert.equal(
    JSON.stringify(tracedJob.body).includes("account_number"),
    false,
  );
  const reconciliation = await opsInspectionCall(config, inspector.aal2Token, {
    action: "reconcile",
  });
  assert.equal(
    reconciliation.status,
    200,
    `financial reconciliation: HTTP ${reconciliation.status} (${reconciliation.body?.error?.code ?? "no_error_code"})`,
  );
  assert.equal(reconciliation.body.data.status, "balanced");
  assert.equal(reconciliation.body.data.money_movement_authorized, false);
  assert.equal(reconciliation.body.data.signed_checkpoint_proven, false);
  const tracedReconciliation = await opsInspectionCall(
    config,
    inspector.aal2Token,
    {
      action: "trace",
      reference_type: "reconciliation_run",
      reference_id: reconciliation.body.data.run_id,
    },
  );
  assert.equal(tracedReconciliation.status, 200);
  assert.equal(
    tracedReconciliation.body.data.reconciliation.status,
    "balanced",
  );
  assert.equal(tracedReconciliation.body.data.reconciliation.finding_count, 0);
  assert.ok(retainedAuditCheckpoint?.directory);
  const laterCheckpointOutput = run(
    process.execPath,
    [
      resolve(root, "scripts/check-audit-checkpoint.mjs"),
      "verify",
      retainedAuditCheckpoint.directory,
      "--require-advance",
    ],
    "verify retained checkpoint after a later financial audit event",
    baseEnv,
    true,
  );
  const laterCheckpointLine = laterCheckpointOutput
    .split(/\r?\n/)
    .find((line) => line.startsWith("AUDIT_CHECKPOINT_VERIFICATION:"));
  assert.ok(
    laterCheckpointLine,
    "later checkpoint verification returns summary",
  );
  const laterCheckpoint = JSON.parse(
    laterCheckpointLine.slice("AUDIT_CHECKPOINT_VERIFICATION:".length),
  );
  assert.equal(laterCheckpoint.later_event_verified, true);
  assert.ok(
    BigInt(laterCheckpoint.current_event_count) >
      BigInt(laterCheckpoint.retained_event_count),
  );
  console.log(
    `PASS retained populated checkpoint remains valid after reconciliation audit event(s): ${laterCheckpoint.retained_event_count} -> ${laterCheckpoint.current_event_count}`,
  );
  run(
    cli,
    [
      "db",
      "query",
      "--local",
      "--output-format",
      "json",
      `update app_private.staff_grants
       set revoked_at=pg_catalog.now(),revoked_by='${inspector.user.id}'::uuid
       where user_id='${inspector.user.id}'::uuid and capability='financial_inspect'`,
    ],
    "revoke synthetic finance inspection grant",
    baseEnv,
    true,
  );
  const revokedGrant = await opsInspectionCall(config, inspector.aal2Token, {
    action: "trace",
    reference_type: "job",
    reference_id: jobId,
  });
  assert.equal(revokedGrant.status, 403);
  console.log(
    "PASS Step 9 Edge HTTP: recipient-only notices, AAL2/current-grant read-only finance trace, simulator-to-ledger reconciliation and audit integrity",
  );

  const studentPoster = await createVerifiedStudent(config, "student-poster");
  const studentWorker = await createVerifiedStudent(
    config,
    "student-poster-worker",
  );
  const studentPosterTerms = {
    ...terms,
    title: "Synthetic student poster task",
    gross_per_worker_kobo: "300000",
    slot_count: 1,
    application_deadline_at: future(2),
    needed_by_at: future(3),
  };
  const studentDraft = await edgeCall(config, studentPoster.token, {
    action: "create_job_draft",
    idempotency_key: randomUUID(),
    terms: studentPosterTerms,
  });
  assert.equal(studentDraft.status, 201);
  assert.equal(studentDraft.body.job.gross_total_kobo, "300000");
  const studentJobId = studentDraft.body.job.job_id;
  const studentFunding = await edgeCall(config, studentPoster.token, {
    action: "fund_job",
    job_id: studentJobId,
    expected_terms_version: 1,
    idempotency_key: randomUUID(),
  });
  assert.equal(studentFunding.status, 202);
  assert.equal(studentFunding.body.expected_gross_kobo, "300000");
  await settleCollection(config, studentFunding.body);
  const studentFundingStatus = await edgeCall(config, studentPoster.token, {
    action: "funding_status",
    job_id: studentJobId,
  });
  assert.equal(studentFundingStatus.status, 200);
  assert.equal(studentFundingStatus.body.funding.listing_state, "open");

  const studentJobDiscovery = await readCall(config, studentWorker.token, {
    action: "discover_jobs",
    filters: {},
  });
  assert.equal(studentJobDiscovery.status, 200);
  assert.ok(
    studentJobDiscovery.body.data.items.some(
      (item) => item.job_id === studentJobId,
    ),
  );
  const studentApplication = await edgeCall(config, studentWorker.token, {
    action: "apply_to_job",
    job_id: studentJobId,
    idempotency_key: randomUUID(),
  });
  assert.equal(studentApplication.status, 201);
  const studentAcceptance = await edgeCall(config, studentPoster.token, {
    action: "accept_application",
    application_id: studentApplication.body.application.application_id,
    idempotency_key: randomUUID(),
  });
  assert.equal(studentAcceptance.status, 200);
  const studentAssignmentId = studentAcceptance.body.assignment.assignment_id;
  assert.equal(
    (
      await edgeCall(config, studentWorker.token, {
        action: "start_assignment",
        assignment_id: studentAssignmentId,
        idempotency_key: randomUUID(),
      })
    ).status,
    200,
  );
  assert.equal(
    (
      await edgeCall(config, studentWorker.token, {
        action: "submit_assignment",
        assignment_id: studentAssignmentId,
        idempotency_key: randomUUID(),
      })
    ).status,
    200,
  );
  const studentCompletion = await edgeCall(config, studentPoster.token, {
    action: "confirm_completion",
    assignment_id: studentAssignmentId,
    idempotency_key: randomUUID(),
  });
  assert.equal(studentCompletion.status, 200);
  assert.equal(studentCompletion.body.assignment.commission_kobo, "15000");
  assert.equal(studentCompletion.body.assignment.worker_net_kobo, "285000");
  const studentWallet = await walletReadCall(config, studentWorker.token, {
    action: "get_my_wallet",
  });
  assert.equal(studentWallet.status, 200);
  assert.equal(
    studentWallet.body.data.balances.available_earnings_kobo,
    "285000",
  );

  simulator.recordPlatformCapital("5000");
  const studentFeeReserveEffect = randomUUID();
  run(
    cli,
    [
      "db",
      "query",
      "--local",
      "--output-format",
      "json",
      `select app_private.post_financial_journal('${studentFeeReserveEffect}'::uuid,
        'platform_capital_contribution',null,null,jsonb_build_array(
          jsonb_build_object('account_code','platform_fee_reserve_cash','direction','debit','amount_kobo','5000'),
          jsonb_build_object('account_code','platform_capital_contributed','direction','credit','amount_kobo','5000')))`,
    ],
    "record separately sourced local capital for the student-poster payout fee",
    baseEnv,
    true,
  );
  const studentDestinationAuthorization = await walletCall(
    config,
    studentWorker.token,
    {
      action: "authorize_simulated_destination_change",
      destination_id: null,
      expected_version: 0,
      simulated_recipient_code: "fake_recipient_alpha",
      password: studentWorker.password,
    },
  );
  assert.equal(studentDestinationAuthorization.status, 200);
  const studentDestination = await walletCall(config, studentWorker.token, {
    action: "confirm_simulated_destination_change",
    authorization_token:
      studentDestinationAuthorization.body.data.authorization_token,
    simulated_recipient_code: "fake_recipient_alpha",
    idempotency_key: randomUUID(),
  });
  assert.equal(studentDestination.status, 200);
  assert.equal(studentDestination.body.data.destination_version, 1);
  assert.equal(
    studentDestination.body.data.ownership_verification,
    "simulator_only",
  );
  const studentWithdrawalAuthorization = await walletCall(
    config,
    studentWorker.token,
    {
      action: "authorize_withdrawal",
      amount_kobo: "285000",
      destination_id: studentDestinationAuthorization.body.data.destination_id,
      destination_version: 1,
      password: studentWorker.password,
    },
  );
  assert.equal(studentWithdrawalAuthorization.status, 200);
  const studentWithdrawal = await walletCall(config, studentWorker.token, {
    action: "request_withdrawal",
    amount_kobo: "285000",
    destination_id: studentDestinationAuthorization.body.data.destination_id,
    destination_version: 1,
    authorization_token:
      studentWithdrawalAuthorization.body.data.authorization_token,
    idempotency_key: randomUUID(),
  });
  assert.equal(studentWithdrawal.status, 201);
  assert.equal(studentWithdrawal.body.data.amount_kobo, "285000");
  assert.ok(
    ["processing", "queued_for_liquidity"].includes(
      studentWithdrawal.body.data.status,
    ),
  );
  simulator.programNext("payout", "success", { feeKobo: "20000" });
  const studentPayout = await runPaymentRunner(config);
  assert.equal(studentPayout.status, 200);
  assert.equal(studentPayout.body.result.withdrawal_status, "paid");
  const studentWalletAfterPayout = await walletReadCall(
    config,
    studentWorker.token,
    { action: "get_my_wallet" },
  );
  assert.equal(
    studentWalletAfterPayout.body.data.balances.available_earnings_kobo,
    "0",
  );
  assert.ok(
    studentWalletAfterPayout.body.data.activity.some(
      (item) => item.activity_type === "withdrawal_paid",
    ),
  );
  const studentPayoutReference = simulator
    .stats()
    .payoutClientReferences.at(-1);
  const studentPayoutDetails = simulator.stats().payoutDetails.at(-1);
  assert.ok(studentPayoutReference);
  assert.equal(studentPayoutDetails.amountKobo, "285000");
  assert.equal(
    studentPayoutDetails.destinationVersion,
    studentDestination.body.data.destination_version,
  );
  console.log(
    "PASS student poster Edge HTTP: exact funding → application/acceptance → start/submit/confirm → NGN 2,850 wallet → same-amount simulated bank payout",
  );

  const lifecycleTerms = {
    ...terms,
    title: "Synthetic application decision lifecycle",
    gross_per_worker_kobo: "100000",
    slot_count: 3,
    application_deadline_at: future(2),
    needed_by_at: future(3),
  };
  const lifecycleDraft = await edgeCall(config, studentPoster.token, {
    action: "create_job_draft",
    idempotency_key: randomUUID(),
    terms: lifecycleTerms,
  });
  assert.equal(lifecycleDraft.status, 201);
  const lifecycleJobId = lifecycleDraft.body.job.job_id;
  const lifecycleFunding = await edgeCall(config, studentPoster.token, {
    action: "fund_job",
    job_id: lifecycleJobId,
    expected_terms_version: 1,
    idempotency_key: randomUUID(),
  });
  assert.equal(lifecycleFunding.status, 202);
  assert.equal(lifecycleFunding.body.expected_gross_kobo, "300000");
  await settleCollection(config, lifecycleFunding.body);
  const lifecycleFundingStatus = await edgeCall(config, studentPoster.token, {
    action: "funding_status",
    job_id: lifecycleJobId,
  });
  assert.equal(lifecycleFundingStatus.status, 200);
  assert.equal(lifecycleFundingStatus.body.funding.listing_state, "open");

  const lifecycleTokens = await Promise.all([
    signIn(config, studentWorker.email, studentWorker.password),
    signIn(config, mainWorkers[0].email, mainWorkers[0].password),
    signIn(config, mainWorkers[1].email, mainWorkers[1].password),
  ]);
  const lifecycleApplicants = [
    {
      token: lifecycleTokens[0],
      email: studentWorker.email,
      password: studentWorker.password,
      label: "rejected applicant",
    },
    {
      token: lifecycleTokens[1],
      email: mainWorkers[0].email,
      password: mainWorkers[0].password,
      label: "withdrawing applicant",
    },
    {
      token: lifecycleTokens[2],
      email: mainWorkers[1].email,
      password: mainWorkers[1].password,
      label: "accepted applicant",
    },
  ];
  const lifecycleApplications = [];
  for (const applicant of lifecycleApplicants) {
    const applied = await edgeCall(config, applicant.token, {
      action: "apply_to_job",
      job_id: lifecycleJobId,
      note: `Synthetic ${applicant.label}.`,
      idempotency_key: randomUUID(),
    });
    assert.equal(
      applied.status,
      201,
      `${applicant.label}: ${JSON.stringify(applied.body)}`,
    );
    lifecycleApplications.push(applied.body.application);
  }

  const initialLifecycleSnapshot =
    await readMarketplaceStateSnapshot(lifecycleJobId);
  assert.match(initialLifecycleSnapshot, /^3\/3\/0:0:/);
  const rejectedApplication = lifecycleApplications[0];
  const rejectFirstMessage = await edgeCall(
    config,
    lifecycleApplicants[0].token,
    {
      action: "send_application_message",
      thread_id: rejectedApplication.thread_id,
      client_message_id: randomUUID(),
      body: "Please consider my application.",
    },
  );
  assert.equal(rejectFirstMessage.status, 201);
  const rejectReply = await edgeCall(config, studentPoster.token, {
    action: "send_application_message",
    thread_id: rejectedApplication.thread_id,
    client_message_id: randomUUID(),
    body: "Thank you for your interest.",
  });
  assert.equal(rejectReply.status, 201);
  const applicantRejectAttempt = await edgeCall(
    config,
    lifecycleApplicants[0].token,
    {
      action: "reject_application",
      application_id: rejectedApplication.application_id,
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(applicantRejectAttempt.status, 404);
  const unrelatedRejectAttempt = await edgeCall(config, mainWorkers[2].token, {
    action: "reject_application",
    application_id: rejectedApplication.application_id,
    idempotency_key: randomUUID(),
  });
  assert.equal(unrelatedRejectAttempt.status, 404);
  const rejected = await edgeCall(config, studentPoster.token, {
    action: "reject_application",
    application_id: rejectedApplication.application_id,
    idempotency_key: randomUUID(),
  });
  assert.equal(rejected.status, 200);
  assert.equal(rejected.body.application.state, "rejected");
  assert.equal(
    await readMarketplaceStateSnapshot(lifecycleJobId),
    initialLifecycleSnapshot,
    "rejection changes no assignment, allocation capacity or journal projection",
  );
  const rejectedThread = await readCall(config, lifecycleApplicants[0].token, {
    action: "application_thread",
    application_id: rejectedApplication.application_id,
  });
  assert.equal(rejectedThread.status, 200);
  assert.equal(rejectedThread.body.data.thread.thread_state, "read_only");
  assert.equal(rejectedThread.body.data.thread.messages.length, 2);
  assert.deepEqual(
    rejectedThread.body.data.thread.messages.map((message) => message.body),
    ["Please consider my application.", "Thank you for your interest."],
  );
  const rejectedLateApplicantMessage = await edgeCall(
    config,
    lifecycleApplicants[0].token,
    {
      action: "send_application_message",
      thread_id: rejectedApplication.thread_id,
      client_message_id: randomUUID(),
      body: "A message after rejection.",
    },
  );
  assert.equal(rejectedLateApplicantMessage.status, 409);
  assert.equal(rejectedLateApplicantMessage.body.error.code, "stale_state");
  const rejectedLatePosterMessage = await edgeCall(
    config,
    studentPoster.token,
    {
      action: "send_application_message",
      thread_id: rejectedApplication.thread_id,
      client_message_id: randomUUID(),
      body: "A poster message after rejection.",
    },
  );
  assert.equal(rejectedLatePosterMessage.status, 409);

  const withdrawnApplication = lifecycleApplications[1];
  const withdrawFirstMessage = await edgeCall(
    config,
    lifecycleApplicants[1].token,
    {
      action: "send_application_message",
      thread_id: withdrawnApplication.thread_id,
      client_message_id: randomUUID(),
      body: "I may need to withdraw shortly.",
    },
  );
  assert.equal(withdrawFirstMessage.status, 201);
  const withdrawReply = await edgeCall(config, studentPoster.token, {
    action: "send_application_message",
    thread_id: withdrawnApplication.thread_id,
    client_message_id: randomUUID(),
    body: "Let me know if your plans change.",
  });
  assert.equal(withdrawReply.status, 201);
  const posterWithdrawAttempt = await edgeCall(config, studentPoster.token, {
    action: "withdraw_application",
    application_id: withdrawnApplication.application_id,
    idempotency_key: randomUUID(),
  });
  assert.equal(posterWithdrawAttempt.status, 404);
  const unrelatedWithdrawAttempt = await edgeCall(
    config,
    lifecycleApplicants[0].token,
    {
      action: "withdraw_application",
      application_id: withdrawnApplication.application_id,
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(unrelatedWithdrawAttempt.status, 404);
  const withdrawn = await edgeCall(config, lifecycleApplicants[1].token, {
    action: "withdraw_application",
    application_id: withdrawnApplication.application_id,
    idempotency_key: randomUUID(),
  });
  assert.equal(withdrawn.status, 200);
  assert.equal(withdrawn.body.application.state, "withdrawn");
  assert.equal(
    await readMarketplaceStateSnapshot(lifecycleJobId),
    initialLifecycleSnapshot,
    "withdrawal changes no assignment, allocation capacity or journal projection",
  );
  const withdrawnThread = await readCall(config, lifecycleApplicants[1].token, {
    action: "application_thread",
    application_id: withdrawnApplication.application_id,
  });
  assert.equal(withdrawnThread.status, 200);
  assert.equal(withdrawnThread.body.data.thread.thread_state, "read_only");
  assert.equal(withdrawnThread.body.data.thread.messages.length, 2);
  assert.deepEqual(
    withdrawnThread.body.data.thread.messages.map((message) => message.body),
    ["I may need to withdraw shortly.", "Let me know if your plans change."],
  );
  const withdrawnLateMessage = await edgeCall(
    config,
    lifecycleApplicants[1].token,
    {
      action: "send_application_message",
      thread_id: withdrawnApplication.thread_id,
      client_message_id: randomUUID(),
      body: "A message after withdrawal.",
    },
  );
  assert.equal(withdrawnLateMessage.status, 409);
  assert.equal(withdrawnLateMessage.body.error.code, "stale_state");

  const acceptedApplication = lifecycleApplications[2];
  const lifecycleAccepted = await edgeCall(config, studentPoster.token, {
    action: "accept_application",
    application_id: acceptedApplication.application_id,
    idempotency_key: randomUUID(),
  });
  assert.equal(lifecycleAccepted.status, 200);
  assert.equal(lifecycleAccepted.body.assignment.assignment_state, "assigned");
  const acceptedLifecycleSnapshot =
    await readMarketplaceStateSnapshot(lifecycleJobId);
  assert.match(acceptedLifecycleSnapshot, /^3\/2\/1:1:/);
  const initialSnapshotParts = initialLifecycleSnapshot.split(":");
  const acceptedSnapshotParts = acceptedLifecycleSnapshot.split(":");
  assert.equal(
    BigInt(acceptedSnapshotParts[2]),
    BigInt(initialSnapshotParts[2]) + 1n,
    "acceptance appends one allocation reclassification journal",
  );
  const initialBalances = initialSnapshotParts[3].split("/").map(BigInt);
  const acceptedBalances = acceptedSnapshotParts[3].split("/").map(BigInt);
  assert.deepEqual(
    acceptedBalances,
    initialBalances.map((amount) => amount + 100000n),
    "the journal reclassifies the existing gross principal once, without new principal",
  );
  const acceptedRejectAttempt = await edgeCall(config, studentPoster.token, {
    action: "reject_application",
    application_id: acceptedApplication.application_id,
    idempotency_key: randomUUID(),
  });
  assert.equal(acceptedRejectAttempt.status, 409);
  assert.equal(acceptedRejectAttempt.body.error.code, "stale_state");
  const acceptedWithdrawAttempt = await edgeCall(
    config,
    lifecycleApplicants[2].token,
    {
      action: "withdraw_application",
      application_id: acceptedApplication.application_id,
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(acceptedWithdrawAttempt.status, 409);
  assert.equal(acceptedWithdrawAttempt.body.error.code, "stale_state");
  assert.equal(
    await readMarketplaceStateSnapshot(lifecycleJobId),
    acceptedLifecycleSnapshot,
    "terminal application commands after acceptance do not alter its assignment or funds",
  );
  run(
    cli,
    [
      "db",
      "query",
      "--local",
      "--output-format",
      "json",
      `do $application_lifecycle$ declare v_job uuid:='${lifecycleJobId}'::uuid; begin
        if (select count(*) from app_private.job_applications where job_id=v_job and state='rejected')<>1
          then raise exception 'rejected_application_state'; end if;
        if (select count(*) from app_private.job_applications where job_id=v_job and state='withdrawn')<>1
          then raise exception 'withdrawn_application_state'; end if;
        if (select count(*) from app_private.job_applications where job_id=v_job and state='accepted')<>1
          then raise exception 'accepted_application_state'; end if;
        if (select count(*) from app_private.principal_allocations where job_id=v_job)<>3
          then raise exception 'lifecycle_allocation_count'; end if;
        if (select count(*) from app_private.assignments where job_id=v_job)<>1
          then raise exception 'lifecycle_assignment_count'; end if;
        if exists(select 1 from app_private.job_applications a
          join app_private.assignments s using(application_id)
          where a.job_id=v_job and a.state in ('rejected','withdrawn'))
          then raise exception 'terminal_unselected_assignment'; end if;
        if (select count(*) from app_private.assignments s
          join app_private.job_applications a using(application_id)
          where a.job_id=v_job and a.state='accepted')<>1
          then raise exception 'accepted_assignment_binding'; end if;
        if (select count(*) from app_private.ledger_journal_transactions j
          join app_private.principal_allocations p on p.allocation_id=j.reference_id
          where p.job_id=v_job and j.effect_type='allocation_assigned')<>1
          then raise exception 'allocation_assignment_journal_count'; end if;
      end $application_lifecycle$`,
    ],
    "verify rejection and withdrawal left one accepted assignment and three separate funded slots",
    baseEnv,
    true,
  );
  console.log(
    "PASS reject_application and withdraw_application Edge HTTP: owner/applicant boundaries, accepted-state denial, retained read-only messages, unchanged rejection/withdrawal money/capacity, and one acceptance reclassification",
  );

  // The local stack intentionally issues short-lived access tokens.
  step3PosterToken = await signIn(config, email, password);
  step3WorkerTokens = await Promise.all([
    signIn(config, studentEmail, studentPassword),
    signIn(
      config,
      additionalStudents[0].user.email,
      additionalStudents[0].password,
    ),
  ]);

  const slotCancellationRaceJob = await createFundedStep3Job(
    "Synthetic cancellation and acceptance race",
  );
  step3PosterToken = await signIn(config, email, password);
  step3WorkerTokens[0] = await signIn(config, studentEmail, studentPassword);
  const slotCancellationApplication = await edgeCall(
    config,
    step3WorkerTokens[0],
    {
      action: "apply_to_job",
      job_id: slotCancellationRaceJob,
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(
    slotCancellationApplication.status,
    201,
    JSON.stringify(slotCancellationApplication.body),
  );
  const [slotCancellationAllocation] = readLocalRows(
    `select allocation_id from app_private.principal_allocations
     where job_id='${slotCancellationRaceJob}'::uuid and status='unassigned'`,
    "read synthetic allocation for the acceptance and cancellation race",
  );
  assert.ok(slotCancellationAllocation?.allocation_id);
  const [acceptanceRaceResult, cancellationRaceResult] = await Promise.all([
    edgeCall(config, step3PosterToken, {
      action: "accept_application",
      application_id:
        slotCancellationApplication.body.application.application_id,
      idempotency_key: randomUUID(),
    }),
    edgeCall(config, step3PosterToken, {
      action: "cancel_unassigned_slots",
      job_id: slotCancellationRaceJob,
      allocation_ids: [slotCancellationAllocation.allocation_id],
      reason: "The slot is no longer needed.",
      idempotency_key: randomUUID(),
    }),
  ]);
  assert.equal(cancellationRaceResult.status, 200);
  assert.ok([200, 409].includes(acceptanceRaceResult.status));
  assert.equal(cancellationRaceResult.body.results.length, 1);
  const acceptanceWon = acceptanceRaceResult.status === 200;
  assert.equal(
    cancellationRaceResult.body.results[0].result,
    acceptanceWon ? "ineligible" : "refund_payable_authorized",
  );
  const [slotCancellationRaceState] = readLocalRows(
    `select p.status,
       (select count(*) from app_private.assignments s
        where s.allocation_id=p.allocation_id) as assignment_count,
       (select count(*) from app_private.allocation_refund_payables r
        where r.allocation_id=p.allocation_id) as payable_count,
       (select count(*) from app_private.ledger_journal_transactions j
        where j.effect_type='allocation_assigned' and j.reference_id=p.allocation_id) as assigned_journals,
       (select count(*) from app_private.ledger_journal_transactions j
        join app_private.allocation_refund_payables r on r.refund_payable_id=j.reference_id
        where j.effect_type='allocation_refund_authorized' and r.allocation_id=p.allocation_id) as refund_journals
     from app_private.principal_allocations p
     where p.allocation_id='${slotCancellationAllocation.allocation_id}'::uuid`,
    "verify acceptance and unused-slot cancellation race outcome",
  );
  assert.deepEqual(
    {
      status: slotCancellationRaceState.status,
      assignment_count: Number(slotCancellationRaceState.assignment_count),
      payable_count: Number(slotCancellationRaceState.payable_count),
      assigned_journals: Number(slotCancellationRaceState.assigned_journals),
      refund_journals: Number(slotCancellationRaceState.refund_journals),
    },
    acceptanceWon
      ? {
          status: "assigned",
          assignment_count: 1,
          payable_count: 0,
          assigned_journals: 1,
          refund_journals: 0,
        }
      : {
          status: "refund_payable",
          assignment_count: 0,
          payable_count: 1,
          assigned_journals: 0,
          refund_journals: 1,
        },
  );

  step3PosterToken = await signIn(config, email, password);
  step3WorkerTokens = await Promise.all([
    signIn(config, studentEmail, studentPassword),
    signIn(
      config,
      additionalStudents[0].user.email,
      additionalStudents[0].password,
    ),
  ]);
  const startRaceJob = await createFundedStep3Job(
    "Synthetic pre-start cancellation race",
    2,
  );
  step3PosterToken = await signIn(config, email, password);
  step3WorkerTokens = await Promise.all([
    signIn(config, studentEmail, studentPassword),
    signIn(
      config,
      additionalStudents[0].user.email,
      additionalStudents[0].password,
    ),
  ]);
  const startRaceWorkers = step3WorkerTokens;
  const startRaceAssignments = [];
  for (const worker of startRaceWorkers) {
    const application = await edgeCall(config, worker, {
      action: "apply_to_job",
      job_id: startRaceJob,
      idempotency_key: randomUUID(),
    });
    assert.equal(application.status, 201, JSON.stringify(application.body));
    const assignment = await edgeCall(config, step3PosterToken, {
      action: "accept_application",
      application_id: application.body.application.application_id,
      idempotency_key: randomUUID(),
    });
    assert.equal(assignment.status, 200);
    startRaceAssignments.push(assignment.body.assignment.assignment_id);
  }

  const [abandonResult, startResult] = await Promise.all([
    edgeCall(config, startRaceWorkers[0], {
      action: "abandon_prestart_assignment",
      assignment_id: startRaceAssignments[0],
      reason: "I cannot take this work after all.",
      idempotency_key: randomUUID(),
    }),
    edgeCall(config, startRaceWorkers[0], {
      action: "start_assignment",
      assignment_id: startRaceAssignments[0],
      idempotency_key: randomUUID(),
    }),
  ]);
  assert.equal(
    [abandonResult, startResult].filter((result) => result.status === 200)
      .length,
    1,
    "start and abandonment serialize on the same allocation",
  );
  const abandonmentWon = abandonResult.status === 200;
  const [abandonmentRaceState] = readLocalRows(
    `select s.work_state,p.status,
       (select count(*) from app_private.allocation_refund_payables r
        where r.allocation_id=p.allocation_id) as payable_count,
       (select count(*) from app_private.ledger_journal_transactions j
        where j.effect_type='allocation_reopened' and j.reference_id=s.assignment_id) as reopen_journals,
       (select count(*) from app_private.allocation_assignment_bindings b
        where b.assignment_id=s.assignment_id and b.unbound_at is null) as current_bindings,
       s.terms_version
     from app_private.assignments s
     join app_private.principal_allocations p using(allocation_id)
     where s.assignment_id='${startRaceAssignments[0]}'::uuid`,
    "verify start and abandonment race outcome",
  );
  assert.deepEqual(
    {
      work_state: abandonmentRaceState.work_state,
      status: abandonmentRaceState.status,
      payable_count: Number(abandonmentRaceState.payable_count),
      reopen_journals: Number(abandonmentRaceState.reopen_journals),
      current_bindings: Number(abandonmentRaceState.current_bindings),
      terms_version: Number(abandonmentRaceState.terms_version),
    },
    abandonmentWon
      ? {
          work_state: "cancelled",
          status: "unassigned",
          payable_count: 0,
          reopen_journals: 1,
          current_bindings: 0,
          terms_version: 1,
        }
      : {
          work_state: "in_progress",
          status: "assigned",
          payable_count: 0,
          reopen_journals: 0,
          current_bindings: 1,
          terms_version: 1,
        },
  );

  step3PosterToken = await signIn(config, email, password);
  step3WorkerTokens[1] = await signIn(
    config,
    additionalStudents[0].user.email,
    additionalStudents[0].password,
  );
  const posterConsentStartRequest = await edgeCall(config, step3PosterToken, {
    action: "request_prestart_cancellation",
    assignment_id: startRaceAssignments[1],
    reason: "We agreed to stop before work begins.",
    idempotency_key: randomUUID(),
  });
  assert.equal(posterConsentStartRequest.status, 200);
  const cancellationId =
    posterConsentStartRequest.body.cancellation.cancellation_id;
  const consentKey = randomUUID();
  const [consentRaceResult, consentRaceStartResult] = await Promise.all([
    edgeCall(config, startRaceWorkers[1], {
      action: "consent_prestart_cancellation",
      cancellation_id: cancellationId,
      cancellation_version: 1,
      reason: "I agree to stop before work begins.",
      idempotency_key: consentKey,
    }),
    edgeCall(config, startRaceWorkers[1], {
      action: "start_assignment",
      assignment_id: startRaceAssignments[1],
      idempotency_key: randomUUID(),
    }),
  ]);
  assert.equal(
    [consentRaceResult, consentRaceStartResult].filter(
      (result) => result.status === 200,
    ).length,
    1,
    "final consent and work-start serialize on the same allocation",
  );
  const consentWon = consentRaceResult.status === 200;
  if (consentWon) {
    assert.equal(consentRaceResult.body.cancellation.status, "completed");
    const duplicateConsent = await edgeCall(config, startRaceWorkers[1], {
      action: "consent_prestart_cancellation",
      cancellation_id: cancellationId,
      cancellation_version: 1,
      reason: "I agree to stop before work begins.",
      idempotency_key: consentKey,
    });
    assert.equal(duplicateConsent.status, 200);
    assert.equal(duplicateConsent.body.cancellation.status, "completed");
  }
  const [consentRaceState] = readLocalRows(
    `select s.work_state,p.status,
       (select count(*) from app_private.allocation_refund_payables r
        where r.allocation_id=p.allocation_id) as payable_count,
       (select count(*) from app_private.ledger_journal_transactions j
        join app_private.allocation_refund_payables r on r.refund_payable_id=j.reference_id
        where j.effect_type='allocation_refund_authorized' and r.allocation_id=p.allocation_id) as refund_journals,
       (select count(*) from app_private.assignment_cancellation_finalizations f
        where f.assignment_id=s.assignment_id) as finalizations,
       (select count(*) from app_private.allocation_assignment_bindings b
        where b.assignment_id=s.assignment_id and b.unbound_at is null) as current_bindings
     from app_private.assignments s
     join app_private.principal_allocations p using(allocation_id)
     where s.assignment_id='${startRaceAssignments[1]}'::uuid`,
    "verify final consent and work-start race outcome",
  );
  assert.deepEqual(
    {
      work_state: consentRaceState.work_state,
      status: consentRaceState.status,
      payable_count: Number(consentRaceState.payable_count),
      refund_journals: Number(consentRaceState.refund_journals),
      finalizations: Number(consentRaceState.finalizations),
      current_bindings: Number(consentRaceState.current_bindings),
    },
    consentWon
      ? {
          work_state: "cancelled",
          status: "refund_payable",
          payable_count: 1,
          refund_journals: 1,
          finalizations: 1,
          current_bindings: 0,
        }
      : {
          work_state: "in_progress",
          status: "assigned",
          payable_count: 0,
          refund_journals: 0,
          finalizations: 0,
          current_bindings: 1,
        },
  );
  step3PosterToken = await signIn(config, email, password);
  step3WorkerTokens[0] = await signIn(
    config,
    lifecycleApplicants[0].email,
    lifecycleApplicants[0].password,
  );
  const deterministicConsentJob = await createFundedStep3Job(
    "Synthetic deterministic mutual cancellation",
  );
  const deterministicConsentApplication = await edgeCall(
    config,
    step3WorkerTokens[0],
    {
      action: "apply_to_job",
      job_id: deterministicConsentJob,
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(deterministicConsentApplication.status, 201);
  const deterministicConsentAssignment = await edgeCall(
    config,
    step3PosterToken,
    {
      action: "accept_application",
      application_id:
        deterministicConsentApplication.body.application.application_id,
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(deterministicConsentAssignment.status, 200);
  const deterministicCancellationRequest = await edgeCall(
    config,
    step3PosterToken,
    {
      action: "request_prestart_cancellation",
      assignment_id:
        deterministicConsentAssignment.body.assignment.assignment_id,
      reason: "Both participants agree to stop before work starts.",
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(deterministicCancellationRequest.status, 200);
  const deterministicConsent = await edgeCall(config, step3WorkerTokens[0], {
    action: "consent_prestart_cancellation",
    cancellation_id:
      deterministicCancellationRequest.body.cancellation.cancellation_id,
    cancellation_version: 1,
    reason: "I agree to cancel before starting this work.",
    idempotency_key: randomUUID(),
  });
  assert.equal(deterministicConsent.status, 200);
  assert.equal(deterministicConsent.body.cancellation.status, "completed");

  step3PosterToken = await signIn(config, email, password);
  step3WorkerTokens[1] = await signIn(
    config,
    lifecycleApplicants[1].email,
    lifecycleApplicants[1].password,
  );
  const deterministicAbandonJob = await createFundedStep3Job(
    "Synthetic deterministic worker abandonment",
  );
  const deterministicAbandonApplication = await edgeCall(
    config,
    step3WorkerTokens[1],
    {
      action: "apply_to_job",
      job_id: deterministicAbandonJob,
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(deterministicAbandonApplication.status, 201);
  const deterministicAbandonAssignment = await edgeCall(
    config,
    step3PosterToken,
    {
      action: "accept_application",
      application_id:
        deterministicAbandonApplication.body.application.application_id,
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(deterministicAbandonAssignment.status, 200);
  const deterministicAbandonment = await edgeCall(
    config,
    step3WorkerTokens[1],
    {
      action: "abandon_prestart_assignment",
      assignment_id:
        deterministicAbandonAssignment.body.assignment.assignment_id,
      reason: "I cannot complete the work and am releasing it before start.",
      idempotency_key: randomUUID(),
    },
  );
  assert.equal(deterministicAbandonment.status, 200);
  const [deterministicAbandonmentState] = readLocalRows(
    `select p.status,s.work_state,
       (select count(*) from app_private.allocation_refund_payables r
        where r.allocation_id=p.allocation_id) as payable_count,
       (select count(*) from app_private.allocation_assignment_bindings b
        where b.assignment_id=s.assignment_id and b.unbound_at is null) as current_bindings
     from app_private.assignments s join app_private.principal_allocations p using(allocation_id)
     where s.assignment_id='${deterministicAbandonAssignment.body.assignment.assignment_id}'::uuid`,
    "verify deterministic abandonment preserves the held principal for another worker",
  );
  assert.deepEqual(
    {
      status: deterministicAbandonmentState.status,
      work_state: deterministicAbandonmentState.work_state,
      payable_count: Number(deterministicAbandonmentState.payable_count),
      current_bindings: Number(deterministicAbandonmentState.current_bindings),
    },
    {
      status: "unassigned",
      work_state: "cancelled",
      payable_count: 0,
      current_bindings: 0,
    },
  );
  console.log(
    `PASS Step 3 Edge HTTP: unused-slot cancellation, mutual pre-start consent and worker abandonment each have deterministic success evidence; work-start races serialize to at most one financial effect; duplicate final consent replay ${consentWon ? "also passed over HTTP" : "is covered by the SQL boundary checks"}`,
  );

  assert.equal(simulator.stats().createdCollections, 11);
  assert.equal(simulator.stats().createdPayouts, 4);
  console.log(
    "PASS partner and student posters completed the local synthetic acceptance journey through actual Edge HTTP and safe client reads",
  );
}

async function stopEdge() {
  if (!edge || edge.exitCode !== null) return;
  edge.kill("SIGINT");
  await Promise.race([
    new Promise((resolveExit) => edge.once("exit", resolveExit)),
    delay(8000),
  ]);
  if (edge.exitCode === null) edge.kill("SIGTERM");
}

function redactLogFile() {
  try {
    writeFileSync(logPath, redact(readFileSync(logPath, "utf8")), {
      mode: 0o600,
    });
    chmodSync(logPath, 0o600);
  } catch {
    failed = true;
  }
}

try {
  if (process.version !== "v22.23.2")
    throw new Error("use pinned Node 22.23.2 for local Edge tests");
  run(cli, ["stop"], "stop before marketplace check", baseEnv, true);
  run(
    cli,
    [
      "start",
      "--runtime",
      "native",
      "--eager",
      "--exclude",
      "functions,analytics,studio",
      "--frozen",
    ],
    "start local stack",
    baseEnv,
    true,
  );
  stackStarted = true;
  run(
    cli,
    ["db", "reset", "--local", "--yes"],
    "reset local database",
    baseEnv,
    true,
  );
  status = JSON.parse(
    run(
      cli,
      ["status", "--output-format", "json"],
      "read local stack status",
      baseEnv,
      true,
    ),
  );
  const api = new URL(status.env?.API_URL ?? "http://invalid.test");
  if (
    status.runtime !== "native" ||
    !["127.0.0.1", "localhost"].includes(api.hostname) ||
    api.port !== "54321"
  )
    throw new Error(
      "marketplace HTTP test requires the native loopback Supabase stack",
    );

  await setLocalRealtimePrivateOnly(status.env.API_URL, status.env.ANON_KEY);

  simulator = await createPaymentSimulator({
    requestSecret: baseEnv.NBD_SIMULATOR_REQUEST_SECRET,
    webhookSecret: baseEnv.NBD_SIMULATOR_WEBHOOK_SECRET,
    merchantIdentity,
  });
  smsCapture = await (
    await import("./test-support/local-sms-capture.mjs")
  ).startLocalSmsCapture();
  emailCapture = await (
    await import("./test-support/local-notification-email-capture.mjs")
  ).startLocalNotificationEmailCapture();
  writeEdgeEnv();
  logFd = openSync(logPath, "w", 0o600);
  edge = spawn(cli, ["functions", "serve", "--env-file", envPath], {
    cwd: root,
    env: baseEnv,
    stdio: ["ignore", logFd, logFd],
  });
  await waitForEdge();
  await checkJourney();
} catch (error) {
  failed = true;
  console.error(
    `FAIL local marketplace journey: ${error instanceof Error ? error.message : "check failed"}`,
  );
  if (error instanceof Error && error.stack) console.error(error.stack);
} finally {
  await Promise.allSettled(
    [...activeRealtimeManagers].map((manager) => manager.dispose()),
  );
  for (const client of activeRealtimeClients) client.realtime.disconnect();
  activeRealtimeManagers.clear();
  activeRealtimeClients.clear();
  await stopEdge().catch(() => {
    failed = true;
  });
  if (logFd !== undefined) closeSync(logFd);
  redactLogFile();
  await simulator?.close().catch(() => {
    failed = true;
  });
  await smsCapture?.close().catch(() => {
    failed = true;
  });
  await emailCapture?.close().catch(() => {
    failed = true;
  });
  rmSync(envPath, { force: true });
  if (stackStarted) {
    try {
      run(
        cli,
        ["db", "reset", "--local", "--yes"],
        "clear local synthetic marketplace data",
        baseEnv,
        true,
      );
      run(cli, ["stop"], "stop local stack", baseEnv, true);
      console.log(
        "PASS local synthetic marketplace data cleared and Supabase stopped",
      );
    } catch {
      failed = true;
      console.error("FAIL local marketplace test cleanup");
    }
  }
}

if (failed) process.exitCode = 1;
