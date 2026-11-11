import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";
import { after, before, test } from "node:test";
import { createClient } from "@supabase/supabase-js";
import WebSocket from "ws";
import {
  safeRecoveryMessage,
  safeSignInMessage,
  safeSignupMessage,
} from "../../../lib/auth/safe-messages.mjs";

const confirmRedirect = "http://127.0.0.1:3000/auth/confirm";
const recoveryRedirect = "http://127.0.0.1:3000/auth/recovery";
const allowedRedirects = new Set([
  "http://127.0.0.1:3000",
  confirmRedirect,
  recoveryRedirect,
]);
const hostileRedirect = "https://attacker.example/steal";
const policyVersion = "18-plus-v1";
const localStatus = JSON.parse(process.env.NBD_LOCAL_AUTH_STATUS_JSON ?? "{}");
const authEnv = localStatus.env ?? {};
const apiUrl = new URL(authEnv.API_URL ?? "http://127.0.0.1");
const mailpitUrl = new URL(authEnv.MAILPIT_URL ?? "http://127.0.0.1");
const emailTag = randomUUID();
const studentEmail = `p2step3-student-${emailTag}@identity.test`;
const partnerEmail = `p2step3-partner-${emailTag}@identity.test`;
const missingEmail = `p2step3-missing-${emailTag}@identity.test`;
const testEmails = new Set([studentEmail, partnerEmail, missingEmail]);
let admin;

function assertLocalStatus() {
  assert.ok(["127.0.0.1", "localhost"].includes(apiUrl.hostname));
  assert.ok(["127.0.0.1", "localhost"].includes(mailpitUrl.hostname));
  assert.ok(authEnv.ANON_KEY);
  assert.ok(authEnv.SERVICE_ROLE_KEY);
}

function newClient(key = authEnv.ANON_KEY) {
  return createClient(apiUrl.origin, key, {
    auth: {
      autoRefreshToken: false,
      detectSessionInUrl: false,
      persistSession: false,
    },
    realtime: { transport: WebSocket },
  });
}

async function mailpit(path, init) {
  const response = await fetch(new URL(`/api/v1/${path}`, mailpitUrl), init);
  assert.ok(response.ok, "local Mailpit request must succeed");
  if (response.status === 204) return null;
  const text = await response.text();
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

function recipientsContain(message, email) {
  return JSON.stringify(message).toLowerCase().includes(email.toLowerCase());
}

async function findMessage(email, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const page = await mailpit("messages?start=0&limit=100");
    const messages = page.messages ?? page.Messages ?? [];
    const summary = messages.find((item) => recipientsContain(item, email));
    if (summary) {
      const id = summary.ID ?? summary.Id ?? summary.id;
      assert.ok(id, "Mailpit returned a message ID");
      const message = await mailpit(`message/${encodeURIComponent(id)}`);
      return { id, message };
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  assert.fail(
    "expected synthetic Auth email was not captured by local Mailpit",
  );
}

function messageLink(message, expectedType) {
  const body = [message.Text, message.HTML, message.Message, message.Snippet]
    .filter((value) => typeof value === "string")
    .join("\n")
    .replaceAll("&amp;", "&")
    .replaceAll("&#x3D;", "=");
  const candidates = body.match(/https?:\/\/[^\s"'<>]+/g) ?? [];
  const link = candidates
    .map((value) => {
      try {
        return new URL(value.replace(/[),.;]+$/, ""));
      } catch {
        return null;
      }
    })
    .find((url) => url?.searchParams.get("type") === expectedType);
  assert.ok(link, `Mailpit message contains a ${expectedType} link`);
  return link;
}

async function verifyMailLink(client, email, url, expectedType) {
  assert.ok(
    url.searchParams.has("token") || url.searchParams.has("token_hash"),
    "Auth email contains a verification token",
  );
  const response = await fetch(url, { redirect: "manual" });
  assert.ok([301, 302, 303, 307, 308].includes(response.status));
  const location = response.headers.get("location");
  assert.ok(
    location,
    "Auth verification redirects to the exact local callback",
  );
  const callback = new URL(location);
  assert.ok(
    allowedRedirects.has(callback.origin + callback.pathname),
    "Auth callback stays on the local allow-list",
  );

  const fragment = new URLSearchParams(callback.hash.slice(1));
  const accessToken = fragment.get("access_token");
  const refreshToken = fragment.get("refresh_token");
  if (accessToken && refreshToken) {
    const session = await client.auth.setSession({
      access_token: accessToken,
      refresh_token: refreshToken,
    });
    assert.ok(
      !session.error,
      `Auth did not accept the verified ${expectedType} session (${session.error?.code ?? "unknown"})`,
    );
    return session.data.session;
  }

  const code = callback.searchParams.get("code");
  assert.ok(code, "Auth callback contains an implicit session or PKCE code");
  const exchanged = await client.auth.exchangeCodeForSession(code);
  assert.ok(
    !exchanged.error,
    `Auth did not exchange the verified ${expectedType} code (${exchanged.error?.code ?? "unknown"})`,
  );
  return exchanged.data.session;
}

async function identityStatus(client) {
  const { data, error } = await client.rpc("get_my_identity_status");
  assert.equal(error, null, "own identity status command succeeds");
  return data;
}

async function provision(client, accountType, ageConfirmed = true) {
  return client.rpc("register_my_identity", {
    p_account_type: accountType,
    p_age_confirmed: ageConfirmed,
    p_age_policy_version: policyVersion,
  });
}

before(() => {
  assertLocalStatus();
  admin = newClient(authEnv.SERVICE_ROLE_KEY);
});

after(async () => {
  if (!admin) return;
  const page = await mailpit("messages?start=0&limit=200");
  const messages = page.messages ?? page.Messages ?? [];
  const ids = messages
    .filter((item) =>
      [...testEmails].some((email) => recipientsContain(item, email)),
    )
    .map((item) => item.ID ?? item.Id ?? item.id)
    .filter(Boolean);
  if (ids.length) {
    await mailpit("messages", {
      method: "DELETE",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ IDs: ids }),
    });
  }
});

test(
  "local email/password lifecycle confirms login ownership without product approval",
  { timeout: 180000 },
  async (t) => {
    let studentClient;
    let studentPassword = randomBytes(24).toString("base64url");
    let studentId;
    let partnerId;

    await t.test(
      "signup and login-email confirmation use local Mailpit",
      async () => {
        studentClient = newClient();
        const signup = await studentClient.auth.signUp({
          email: studentEmail,
          password: studentPassword,
          options: { emailRedirectTo: confirmRedirect },
        });
        assert.equal(signup.error, null, "synthetic signup succeeds");
        assert.ok(signup.data.user?.id, "Auth creates a synthetic user");
        studentId = signup.data.user.id;
        assert.equal(
          signup.data.session,
          null,
          "unconfirmed signup has no session",
        );
        assert.equal(Boolean(signup.data.user.email_confirmed_at), false);

        const confirmation = await findMessage(studentEmail);
        const link = messageLink(confirmation.message, "signup");
        assert.equal(
          link.searchParams.get("redirect_to"),
          confirmRedirect,
          "confirmation email uses the exact local allow-listed redirect",
        );
        const session = await verifyMailLink(
          studentClient,
          studentEmail,
          link,
          "signup",
        );
        assert.ok(session.access_token);

        const { data: confirmed, error } =
          await admin.auth.admin.getUserById(studentId);
        assert.equal(error, null);
        assert.ok(
          confirmed.user.email_confirmed_at,
          "Auth records login-email confirmation",
        );
        const verified = await studentClient.auth.getUser(session.access_token);
        assert.equal(
          verified.error,
          null,
          "Auth server validates the issued access token",
        );
        assert.equal(verified.data.user.id, studentId);
        console.log(
          "PASS signup, local confirmation email, and Auth token verification",
        );
      },
    );

    await t.test(
      "duplicate signup and bad signin do not reveal account existence",
      async () => {
        await new Promise((resolve) => setTimeout(resolve, 1100));
        const duplicate = await newClient().auth.signUp({
          email: studentEmail,
          password: studentPassword,
        });
        assert.equal(
          safeSignupMessage(duplicate.error),
          safeSignupMessage(null),
          "duplicate signup gets the same safe user-facing response",
        );
        assert.equal(
          duplicate.data.session,
          null,
          "duplicate signup grants no session",
        );

        const known = await newClient().auth.signInWithPassword({
          email: studentEmail,
          password: "wrong-password-for-test",
        });
        const unknown = await newClient().auth.signInWithPassword({
          email: missingEmail,
          password: "wrong-password-for-test",
        });
        assert.ok(known.error && unknown.error);
        assert.equal(
          safeSignInMessage(known.error),
          safeSignInMessage(unknown.error),
          "signin messages do not expose account existence",
        );
        console.log("PASS duplicate signup and generic signin errors");
      },
    );

    await t.test(
      "onboarding provisions once and ignores later metadata claims",
      async () => {
        const invalid = await provision(studentClient, "student", false);
        assert.ok(
          invalid.error,
          "failed age affirmation does not provision identity",
        );
        assert.deepEqual(await identityStatus(studentClient), {
          registered: false,
          phone_verified: false,
          login_email_confirmed: true,
          verified: false,
          can_post: false,
          can_work: false,
        });

        const first = await provision(studentClient, "student");
        assert.equal(
          first.error,
          null,
          "valid onboarding provisions the student identity",
        );
        const retry = await provision(studentClient, "student");
        assert.equal(retry.error, null, "same-type retry is idempotent");
        assert.equal(retry.data.account_type, "student");

        const switched = await provision(studentClient, "partner");
        assert.ok(switched.error, "onboarding cannot change account type");
        const metadata = await studentClient.auth.updateUser({
          data: {
            account_type: "partner",
            verification_status: "approved",
            is_staff: true,
            staff_capabilities: ["identity_suspend"],
            age_confirmed: false,
          },
        });
        assert.equal(
          metadata.error,
          null,
          "Auth metadata can be edited as untrusted profile data",
        );

        const status = await identityStatus(studentClient);
        assert.equal(status.account_type, "student");
        assert.equal(status.age_confirmed, true);
        assert.equal(status.verification_status, "unverified");
        assert.equal(status.institutional_email_verified, false);
        assert.deepEqual(status.capabilities, []);
        assert.equal("staff_capabilities" in status, false);
        console.log(
          "PASS onboarding retry/type lock and metadata escalation denial",
        );
      },
    );

    await t.test(
      "recovery is non-enumerating and cannot approve the account",
      async () => {
        const known = await studentClient.auth.resetPasswordForEmail(
          studentEmail,
          {
            redirectTo: recoveryRedirect,
          },
        );
        const unknown = await newClient().auth.resetPasswordForEmail(
          missingEmail,
          {
            redirectTo: recoveryRedirect,
          },
        );
        assert.equal(known.error, null);
        assert.equal(
          unknown.error,
          null,
          "unknown recovery address receives the same result",
        );
        assert.equal(
          safeRecoveryMessage(known.error),
          safeRecoveryMessage(unknown.error),
          "recovery message does not expose account existence",
        );

        const recoveryMessage = await findMessage(studentEmail);
        const recoveryLink = messageLink(recoveryMessage.message, "recovery");
        assert.equal(
          recoveryLink.searchParams.get("redirect_to"),
          recoveryRedirect,
        );
        const recovery = await verifyMailLink(
          studentClient,
          studentEmail,
          recoveryLink,
          "recovery",
        );
        assert.ok(recovery.access_token);

        const newPassword = randomBytes(24).toString("base64url");
        const update = await studentClient.auth.updateUser({
          password: newPassword,
        });
        assert.equal(
          update.error,
          null,
          "recovery session can set a new Auth password",
        );
        studentPassword = newPassword;
        const status = await identityStatus(studentClient);
        assert.equal(status.account_type, "student");
        assert.equal(status.verification_status, "unverified");
        assert.equal(status.institutional_email_verified, false);
        console.log(
          "PASS recovery changes Auth password only; identity remains unverified",
        );
      },
    );

    await t.test(
      "hostile redirect falls back to the local allow-list",
      async () => {
        await new Promise((resolve) => setTimeout(resolve, 1100));
        const requested = await studentClient.auth.resetPasswordForEmail(
          studentEmail,
          {
            redirectTo: hostileRedirect,
          },
        );
        assert.equal(
          requested.error,
          null,
          "Auth recovery request stays generic",
        );
        const message = await findMessage(studentEmail);
        const link = messageLink(message.message, "recovery");
        const redirect = link.searchParams.get("redirect_to");
        assert.ok(redirect);
        assert.equal(
          allowedRedirects.has(redirect),
          true,
          "Auth rejects hostile redirect targets",
        );
        assert.notEqual(redirect, hostileRedirect);
        console.log("PASS hostile recovery redirect is not used");
      },
    );

    await t.test(
      "partner remains restricted after confirmation and provisioning",
      async () => {
        const partnerClient = newClient();
        const password = randomBytes(24).toString("base64url");
        const signup = await partnerClient.auth.signUp({
          email: partnerEmail,
          password,
          options: { emailRedirectTo: confirmRedirect },
        });
        assert.equal(signup.error, null);
        partnerId = signup.data.user?.id;
        assert.ok(partnerId);
        const message = await findMessage(partnerEmail);
        const link = messageLink(message.message, "signup");
        const session = await verifyMailLink(
          partnerClient,
          partnerEmail,
          link,
          "signup",
        );
        const validToken = await partnerClient.auth.getUser(
          session.access_token,
        );
        assert.equal(
          validToken.error,
          null,
          "Auth validates the confirmed partner token",
        );

        const provisioned = await provision(partnerClient, "partner");
        assert.equal(provisioned.error, null);
        const changed = await provision(partnerClient, "student");
        assert.ok(changed.error, "partner cannot switch account type");
        const status = await identityStatus(partnerClient);
        assert.equal(status.account_type, "partner");
        assert.equal(status.verification_status, "unverified");
        assert.deepEqual(status.capabilities, []);
        assert.equal(status.can_post, false);
        assert.equal(status.can_work, false);
        console.log("PASS partner signup and restricted unverified status");
      },
    );

    await t.test(
      "password sign-in, refresh, signout, and token expiry",
      async () => {
        const loginClient = newClient();
        const login = await loginClient.auth.signInWithPassword({
          email: studentEmail,
          password: studentPassword,
        });
        assert.equal(
          login.error,
          null,
          "confirmed user can sign in with password",
        );
        assert.ok(login.data.session);
        const refreshed = await loginClient.auth.refreshSession({
          refresh_token: login.data.session.refresh_token,
        });
        assert.equal(refreshed.error, null, "Auth refreshes the session");
        assert.ok(refreshed.data.session.refresh_token);
        const authenticated = await loginClient.auth.getUser(
          refreshed.data.session.access_token,
        );
        assert.equal(
          authenticated.error,
          null,
          "Auth validates the refreshed access token",
        );

        const accessToken = refreshed.data.session.access_token;
        const refreshToken = refreshed.data.session.refresh_token;
        const signout = await loginClient.auth.signOut({ scope: "local" });
        assert.equal(signout.error, null, "local signout succeeds");
        const localSession = await loginClient.auth.getSession();
        assert.equal(
          localSession.data.session,
          null,
          "client clears its stored session",
        );

        const refreshAgain = await newClient().auth.refreshSession({
          refresh_token: refreshToken,
        });
        assert.ok(
          refreshAgain.error,
          "signed-out refresh token cannot create a new session",
        );

        const invalid = await newClient().auth.getUser("not.a.valid.token");
        assert.ok(invalid.error, "malformed access token is rejected by Auth");

        const expiresAt = refreshed.data.session.expires_at * 1000;
        const waitMs = Math.max(0, expiresAt - Date.now() + 1500);
        assert.ok(
          waitMs <= 62000,
          "local test session has the configured short test expiry",
        );
        await new Promise((resolve) => setTimeout(resolve, waitMs));
        const expired = await newClient().auth.getUser(accessToken);
        assert.ok(expired.error, "expired access token is rejected by Auth");
        console.log(
          "PASS signin, refresh, local signout, and server-verified token expiry",
        );
      },
    );
  },
);
