import assert from "node:assert/strict";
import { createHmac, randomBytes, randomInt, randomUUID } from "node:crypto";
import { after, before, test } from "node:test";
import { createClient } from "@supabase/supabase-js";
import WebSocket from "ws";
import { startLocalSmsHook } from "../../../scripts/test-support/local-sms-hook.mjs";
import { phoneSendDigest } from "../../../supabase/functions/_shared/send-sms.mjs";
import {
  confirmMyPhoneChange,
  requestMyPhoneChange,
} from "../../../lib/auth/phone-change.mjs";

const localStatus = JSON.parse(process.env.NBD_LOCAL_AUTH_STATUS_JSON ?? "{}");
const authEnv = localStatus.env ?? {};
const apiUrl = new URL(authEnv.API_URL ?? "http://127.0.0.1");
const tag = randomUUID();
const accounts = new Map();
const phoneSuffixes = new Set();
function syntheticPhone() {
  let suffix;
  do suffix = randomInt(100, 1000);
  while (phoneSuffixes.has(suffix));
  phoneSuffixes.add(suffix);
  return `+2347000000${suffix}`;
}
const phones = {
  expired: syntheticPhone(),
  owned: syntheticPhone(),
  contested: syntheticPhone(),
  deliveryFailure: syntheticPhone(),
  sendLimit: syntheticPhone(),
};
let admin;
let sms;
let ownerFirstPhoneRequestAt;

function assertLocalStatus() {
  assert.equal(localStatus.runtime, "native");
  assert.ok(["127.0.0.1", "localhost"].includes(apiUrl.hostname));
  assert.ok(authEnv.ANON_KEY);
  assert.ok(authEnv.SERVICE_ROLE_KEY);
}

function newClient(key = authEnv.ANON_KEY) {
  return createClient(apiUrl.origin, key, {
    global: {
      async fetch(input, init) {
        const response = await fetch(input, init);
        const path = new URL(
          input instanceof Request ? input.url : String(input),
        ).pathname;
        if (
          !response.ok &&
          ["/auth/v1/user", "/auth/v1/verify", "/auth/v1/token"].includes(path)
        ) {
          const body = await response
            .clone()
            .json()
            .catch(() => ({}));
          const code = /^[a-z][a-z0-9_]{0,63}$/.test(body.code ?? "")
            ? body.code
            : "unclassified";
          console.error(
            `Auth boundary: ${path} HTTP ${response.status} code=${code}`,
          );
        }
        return response;
      },
    },
    auth: {
      autoRefreshToken: false,
      detectSessionInUrl: false,
      persistSession: false,
    },
    realtime: { transport: WebSocket },
  });
}

async function sendSignedHookEvent(userId, phone, otp) {
  const secret =
    process.env.SUPABASE_AUTH_HOOK_SEND_SMS_SECRET?.match(
      /^v1,whsec_(.+)$/,
    )?.[1];
  assert.ok(secret, "local Auth Hook signing secret is available to the test");
  const eventId = randomUUID();
  const timestamp = String(Math.floor(Date.now() / 1000));
  const body = JSON.stringify({ user: { id: userId }, sms: { phone, otp } });
  const signature = createHmac("sha256", Buffer.from(secret, "base64"))
    .update(`${eventId}.${timestamp}.${body}`)
    .digest("base64");
  return fetch(process.env.NBD_LOCAL_SMS_HOOK_URL, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "webhook-id": eventId,
      "webhook-timestamp": timestamp,
      "webhook-signature": `v1,${signature}`,
    },
    body,
  });
}

async function createAccount(label) {
  const email = `p2step4-${label}-${tag}@identity.test`;
  const password = randomBytes(24).toString("base64url");
  const { data, error } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
  });
  assert.equal(error, null, "local Auth creates a synthetic email account");
  accounts.set(email, data.user.id);
  const client = newClient();
  const login = await client.auth.signInWithPassword({ email, password });
  assert.equal(
    login.error,
    null,
    "synthetic account signs in with email/password",
  );
  return { client, id: data.user.id, email };
}

async function identityStatus(client) {
  const { data, error } = await client.rpc("get_my_identity_status");
  assert.equal(error, null, "own identity status query succeeds");
  return data;
}

before(async () => {
  assertLocalStatus();
  admin = newClient(authEnv.SERVICE_ROLE_KEY);
  sms = await startLocalSmsHook({
    url: process.env.NBD_LOCAL_SMS_HOOK_URL,
    hookSecret: process.env.SUPABASE_AUTH_HOOK_SEND_SMS_SECRET,
    reserveSend: async ({ userId, phone, eventId }) => {
      const digest = await phoneSendDigest(
        phone,
        process.env.NBD_PHONE_SEND_LIMIT_HMAC_KEY,
      );
      const { data, error } = await admin.rpc(
        "server_reserve_phone_sms_send_for_actor",
        {
          p_actor: userId,
          p_phone_digest: digest,
          p_request_id: eventId,
        },
      );
      assert.ifError(error);
      return data === true;
    },
    failurePhones: [phones.deliveryFailure],
  });
});

after(async () => {
  try {
    if (admin) {
      for (const userId of accounts.values()) {
        const { error } = await admin.auth.admin.deleteUser(userId);
        assert.equal(
          error,
          null,
          "temporary synthetic Auth account is removed",
        );
      }
    }
  } finally {
    await sms?.close();
  }
});

test(
  "Supabase phone-change OTP verifies the same account and protects the pending binding",
  { timeout: 390_000 },
  async (t) => {
    const expired = await createAccount("expired");
    const owner = await createAccount("owner");
    const contenderA = await createAccount("contender-a");
    const contenderB = await createAccount("contender-b");
    const deliveryFailure = await createAccount("delivery-failure");
    const expiryChallenge = await requestMyPhoneChange(
      expired.client.auth,
      phones.expired,
    );
    assert.equal(
      expiryChallenge.error,
      null,
      "Auth accepts the synthetic expiry challenge",
    );
    const expiredDelivery = await sms.take(phones.expired, expired.id);
    const challengeExpiresAt = Date.now() + 300_100;

    await t.test(
      "durable send quota is atomic across simultaneous signed Auth hook events",
      async () => {
        const responses = await Promise.all(
          Array.from({ length: 6 }, (_, index) =>
            sendSignedHookEvent(
              expired.id,
              phones.sendLimit,
              String(100001 + index),
            ),
          ),
        );
        assert.equal(
          responses.filter((response) => response.status === 200).length,
          5,
          "exactly five concurrent phone sends are reserved",
        );
        assert.equal(
          responses.filter((response) => response.status === 429).length,
          1,
          "the sixth concurrent send is refused by the database quota",
        );
        for (let index = 0; index < 5; index++)
          await sms.take(phones.sendLimit, expired.id);
      },
    );

    await t.test(
      "wrong OTP fails; Auth confirmation binds the existing user once",
      async () => {
        const before = await identityStatus(owner.client);
        assert.equal(before.phone_verified, false);
        const sent = await requestMyPhoneChange(
          owner.client.auth,
          phones.owned,
        );
        assert.equal(
          sent.error,
          null,
          "Auth accepts the signed-in phone change",
        );
        ownerFirstPhoneRequestAt = Date.now();
        const delivery = await sms.take(phones.owned, owner.id);
        const resent = await requestMyPhoneChange(
          owner.client.auth,
          phones.owned,
        );
        assert.equal(
          resent.error?.code,
          "rate_limited",
          "Auth enforces the resend wait before delivery",
        );
        const wrongCode = delivery.otp === "000000" ? "000001" : "000000";
        assert.ok(
          (
            await confirmMyPhoneChange(
              owner.client.auth,
              phones.owned,
              wrongCode,
            )
          ).error,
          "Auth rejects a wrong phone-change code",
        );
        assert.equal(
          (await identityStatus(owner.client)).phone_verified,
          false,
        );

        const confirmed = await confirmMyPhoneChange(
          owner.client.auth,
          phones.owned,
          delivery.otp,
        );
        assert.equal(
          confirmed.error,
          null,
          "Supabase Auth verifies its own OTP",
        );
        assert.equal(
          confirmed.data.userId,
          owner.id,
          "phone change keeps the original Auth user ID",
        );
        assert.equal(confirmed.data.phone, phones.owned);
        assert.equal((await identityStatus(owner.client)).phone_verified, true);

        assert.ok(
          (
            await confirmMyPhoneChange(
              owner.client.auth,
              phones.owned,
              delivery.otp,
            )
          ).error,
          "Auth rejects a reused code",
        );
        assert.equal((await identityStatus(owner.client)).phone_verified, true);
      },
    );

    await t.test(
      "duplicate verified ownership and concurrent pending claims are denied",
      async () => {
        assert.ok(
          (await requestMyPhoneChange(contenderA.client.auth, phones.owned))
            .error,
          "another account cannot claim an already verified number",
        );
        assert.equal(
          (await identityStatus(contenderA.client)).phone_verified,
          false,
        );

        const attempts = await Promise.all([
          requestMyPhoneChange(contenderA.client.auth, phones.contested),
          requestMyPhoneChange(contenderB.client.auth, phones.contested),
        ]);
        assert.equal(
          attempts.filter((result) => !result.error).length,
          1,
          "only one concurrent account can reserve a phone change",
        );
        const winner = attempts[0].error ? contenderB : contenderA;
        const loser = attempts[0].error ? contenderA : contenderB;
        assert.ok(winner && loser);
        const confirmed = await confirmMyPhoneChange(
          winner.client.auth,
          phones.contested,
          (await sms.take(phones.contested, winner.id)).otp,
        );
        assert.equal(confirmed.error, null);
        assert.equal(confirmed.data.userId, winner.id);
        assert.equal(
          (await identityStatus(winner.client)).phone_verified,
          true,
        );
        assert.equal(
          (await identityStatus(loser.client)).phone_verified,
          false,
        );
      },
    );

    await t.test(
      "new phone request immediately invalidates the old protected binding",
      async () => {
        await new Promise((resolve) =>
          setTimeout(
            resolve,
            Math.max(0, ownerFirstPhoneRequestAt + 60_100 - Date.now()),
          ),
        );
        const replacement = "+2347000000005";
        const pending = await requestMyPhoneChange(
          owner.client.auth,
          replacement,
        );
        assert.equal(
          pending.error,
          null,
          "new number enters Auth's phone-change flow",
        );
        assert.equal(
          (await identityStatus(owner.client)).phone_verified,
          false,
          "hook delivery alone and the previous number do not satisfy phone ownership",
        );
      },
    );

    await t.test(
      "failed SMS delivery cannot establish verified ownership",
      async () => {
        const failed = await requestMyPhoneChange(
          deliveryFailure.client.auth,
          phones.deliveryFailure,
        );
        assert.ok(failed.error);
        assert.equal(
          (await identityStatus(deliveryFailure.client)).phone_verified,
          false,
        );
      },
    );

    await t.test(
      "Auth-generated phone-change OTP expires and cannot bind the phone",
      async () => {
        await new Promise((resolve) =>
          setTimeout(
            resolve,
            Math.max(0, challengeExpiresAt - Date.now() + 250),
          ),
        );
        const stale = await confirmMyPhoneChange(
          expired.client.auth,
          phones.expired,
          expiredDelivery.otp,
        );
        assert.ok(
          stale.error,
          "Supabase Auth rejects its delivered code after the configured challenge lifetime",
        );
        assert.equal(
          (await identityStatus(expired.client)).phone_verified,
          false,
        );
      },
    );
  },
);
