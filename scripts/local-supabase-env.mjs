import { chmodSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { randomBytes } from "node:crypto";

const root = resolve(import.meta.dirname, "..");
const localHome = resolve(root, ".supabase-home");
const secretPath = resolve(localHome, "send-sms-hook-secret");
const schoolHmacPath = resolve(localHome, "school-email-challenge-key");
const schoolAdapterPath = resolve(localHome, "school-email-adapter-key");
const verificationDownloadPath = resolve(
  localHome,
  "verification-download-hmac-key",
);
const caseUploadPath = resolve(localHome, "case-upload-token-key");
const phoneSendLimitPath = resolve(localHome, "phone-send-limit-hmac-key");
const paymentSimulatorRequestPath = resolve(
  localHome,
  "payment-simulator-request-key",
);
const paymentSimulatorWebhookPath = resolve(
  localHome,
  "payment-simulator-webhook-key",
);
const paymentRunnerPath = resolve(localHome, "payment-runner-key");
const assignmentReminderRunnerPath = resolve(
  localHome,
  "assignment-reminder-runner-key",
);

function localSecret(path) {
  try {
    const value = readFileSync(path, "utf8").trim();
    if (!/^[A-Za-z0-9_-]{43}$/.test(value)) throw new Error("invalid secret");
    chmodSync(path, 0o600);
    return value;
  } catch (error) {
    if (error?.code !== "ENOENT")
      throw new Error("local identity secret is invalid");
    const value = randomBytes(32).toString("base64url");
    writeFileSync(path, value, { mode: 0o600, flag: "wx" });
    return value;
  }
}

export function localSupabaseEnv(base = process.env) {
  mkdirSync(localHome, { recursive: true, mode: 0o700 });
  let secret;
  try {
    secret = readFileSync(secretPath, "utf8").trim();
  } catch {
    secret = randomBytes(32).toString("base64");
    writeFileSync(secretPath, secret, { mode: 0o600, flag: "wx" });
  }
  if (!/^[A-Za-z0-9+/]{43}=$/.test(secret)) {
    throw new Error("local Auth hook secret is invalid");
  }
  const schoolHmacKey = localSecret(schoolHmacPath);
  const schoolAdapterKey = localSecret(schoolAdapterPath);
  const verificationDownloadKey = localSecret(verificationDownloadPath);
  const caseUploadKey = localSecret(caseUploadPath);
  const phoneSendLimitKey = localSecret(phoneSendLimitPath);
  const paymentSimulatorRequestKey = localSecret(paymentSimulatorRequestPath);
  const paymentSimulatorWebhookKey = localSecret(paymentSimulatorWebhookPath);
  const paymentRunnerKey = localSecret(paymentRunnerPath);
  const assignmentReminderRunnerKey = localSecret(assignmentReminderRunnerPath);
  const schoolAdapterUrl = new URL(
    base.NBD_SCHOOL_EMAIL_ADAPTER_URL ?? "http://127.0.0.1:54331/deliver",
  );
  if (
    schoolAdapterUrl.protocol !== "http:" ||
    !["127.0.0.1", "localhost"].includes(schoolAdapterUrl.hostname) ||
    schoolAdapterUrl.pathname !== "/deliver" ||
    !schoolAdapterUrl.port ||
    Number(schoolAdapterUrl.port) < 1024 ||
    schoolAdapterUrl.username ||
    schoolAdapterUrl.password ||
    schoolAdapterUrl.search ||
    schoolAdapterUrl.hash
  ) {
    throw new Error(
      "local school email adapter must use a loopback test listener",
    );
  }
  chmodSync(secretPath, 0o600);
  const hookUrl = new URL(
    base.NBD_LOCAL_SMS_HOOK_URL ?? "http://127.0.0.1:54330/send-sms",
  );
  if (
    hookUrl.protocol !== "http:" ||
    !["127.0.0.1", "localhost"].includes(hookUrl.hostname) ||
    hookUrl.pathname !== "/send-sms" ||
    !hookUrl.port ||
    Number(hookUrl.port) < 1024 ||
    hookUrl.username ||
    hookUrl.password ||
    hookUrl.search ||
    hookUrl.hash
  ) {
    throw new Error("local SMS hook must use a loopback test listener");
  }
  return {
    ...base,
    SUPABASE_EXPERIMENTAL_STACK: "1",
    SUPABASE_HOME: localHome,
    SUPABASE_TELEMETRY_DISABLED: "1",
    SUPABASE_AUTH_HOOK_SEND_SMS_SECRET: `v1,whsec_${secret}`,
    NBD_LOCAL_SMS_HOOK_URL: hookUrl.href,
    NBD_SCHOOL_CHALLENGE_HMAC_KEY: schoolHmacKey,
    NBD_SCHOOL_EMAIL_ADAPTER_KEY: schoolAdapterKey,
    NBD_SCHOOL_EMAIL_ADAPTER_URL: schoolAdapterUrl.href,
    NBD_VERIFICATION_DOWNLOAD_HMAC_KEY: verificationDownloadKey,
    NBD_CASE_UPLOAD_TOKEN_KEY: caseUploadKey,
    NBD_PHONE_SEND_LIMIT_HMAC_KEY: phoneSendLimitKey,
    NBD_PAYMENT_MODE: base.NBD_PAYMENT_MODE ?? "disabled",
    NBD_SIMULATOR_URL: base.NBD_SIMULATOR_URL ?? "http://127.0.0.1:54329",
    NBD_SIMULATOR_MERCHANT_ID:
      base.NBD_SIMULATOR_MERCHANT_ID ?? "fake_nbd_local_merchant_v1",
    NBD_SIMULATOR_REQUEST_SECRET:
      base.NBD_SIMULATOR_REQUEST_SECRET ?? paymentSimulatorRequestKey,
    NBD_SIMULATOR_WEBHOOK_SECRET:
      base.NBD_SIMULATOR_WEBHOOK_SECRET ?? paymentSimulatorWebhookKey,
    NBD_PAYMENT_RUNNER_SECRET:
      base.NBD_PAYMENT_RUNNER_SECRET ?? paymentRunnerKey,
    NBD_ASSIGNMENT_REMINDER_MODE:
      base.NBD_ASSIGNMENT_REMINDER_MODE ?? "disabled",
    NBD_ASSIGNMENT_REMINDER_RUNNER_SECRET:
      base.NBD_ASSIGNMENT_REMINDER_RUNNER_SECRET ?? assignmentReminderRunnerKey,
  };
}
