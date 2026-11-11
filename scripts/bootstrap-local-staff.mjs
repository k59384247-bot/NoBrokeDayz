import { randomBytes } from "node:crypto";
import { chmodSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { createClient } from "@supabase/supabase-js";
import { localSupabaseEnv } from "./local-supabase-env.mjs";

const root = resolve(import.meta.dirname, "..");
const cli = resolve(root, "node_modules/.bin/supabase");
const home = resolve(root, ".supabase-home");
const credentialsPath = resolve(home, "step8-staff.json");
const fixtureMarker = "no-broke-dayz-phase2-step8-local-fixture";
const fixtureEmails = {
  operator: "phase2-bootstrap-operator@identity.test",
  reviewer: "phase2-staff-reviewer-final@identity.test",
  applicant: "phase2-staff-applicant@identity.test",
  unrelated: "phase2-staff-unrelated-final@identity.test",
};
const env = localSupabaseEnv();

function fail(message) {
  throw new Error(message);
}

function run(command, args, label) {
  const result = spawnSync(command, args, {
    cwd: root,
    env,
    encoding: "utf8",
    maxBuffer: 2 * 1024 * 1024,
  });
  if (result.error || result.status !== 0)
    fail(
      `${label} failed${[result.stderr, result.stdout].filter(Boolean).length ? `: ${[result.stderr, result.stdout].filter(Boolean).join("\n").slice(-1000)}` : ""}`,
    );
  return result.stdout;
}

function status() {
  let value;
  try {
    value = JSON.parse(
      run(cli, ["status", "--output-format", "json"], "local status"),
    );
  } catch {
    fail("staff bootstrap requires a running local native Supabase stack");
  }
  const api = new URL(value.env?.API_URL ?? "http://invalid.test");
  if (
    value.runtime !== "native" ||
    !["127.0.0.1", "localhost"].includes(api.hostname) ||
    api.port !== "54321" ||
    !value.env?.ANON_KEY ||
    !value.env?.SERVICE_ROLE_KEY
  )
    fail("staff bootstrap is restricted to the native local loopback project");
  return value;
}

function readCredentials() {
  try {
    return JSON.parse(readFileSync(credentialsPath, "utf8"));
  } catch (error) {
    if (error?.code !== "ENOENT")
      fail("local staff credentials file is invalid");
    return { fixture_scope: fixtureMarker, users: {} };
  }
}

function saveCredentials(credentials) {
  mkdirSync(home, { recursive: true, mode: 0o700 });
  writeFileSync(credentialsPath, `${JSON.stringify(credentials, null, 2)}\n`, {
    mode: 0o600,
  });
  chmodSync(credentialsPath, 0o600);
}

async function adminRequest(config, path, options = {}) {
  const response = await fetch(`${config.apiUrl}/auth/v1/admin${path}`, {
    ...options,
    headers: {
      apikey: config.serviceKey,
      authorization: `Bearer ${config.serviceKey}`,
      "content-type": "application/json",
      ...options.headers,
    },
  });
  const body = await response.json().catch(() => null);
  if (!response.ok) fail("local Auth admin operation failed");
  return body;
}

async function provisionAuthUsers(config, credentials) {
  const listing = await adminRequest(config, "/users?per_page=1000&page=1");
  for (const [role, email] of Object.entries(fixtureEmails)) {
    let user = (listing.users ?? []).find(
      (candidate) => candidate.email === email,
    );
    let password = credentials.users?.[role]?.password;
    if (user && user.app_metadata?.local_fixture_scope !== fixtureMarker)
      fail(
        "reserved synthetic staff email is already in use; no account was changed",
      );
    if (!password) password = randomBytes(32).toString("base64url");
    if (!user) {
      user = await adminRequest(config, "/users", {
        method: "POST",
        body: JSON.stringify({
          email,
          password,
          email_confirm: true,
          app_metadata: { local_fixture_scope: fixtureMarker },
          user_metadata: {
            account_type: "partner",
            verification_status: "approved",
            staff: true,
            staff_capabilities: ["verification_review", "identity_suspend"],
          },
        }),
      });
    } else {
      user = await adminRequest(config, `/users/${user.id}`, {
        method: "PUT",
        body: JSON.stringify({
          password,
          email_confirm: true,
          app_metadata: {
            ...user.app_metadata,
            local_fixture_scope: fixtureMarker,
          },
        }),
      });
    }
    credentials.users ??= {};
    credentials.users[role] = {
      ...credentials.users[role],
      id: user.id,
      email,
      password,
    };
  }
  saveCredentials(credentials);
}

async function registerIdentity(config, credentials, role) {
  const user = credentials.users[role];
  const client = createClient(config.apiUrl, config.anonKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data, error } = await client.auth.signInWithPassword({
    email: user.email,
    password: user.password,
  });
  if (error || !data.session) fail("synthetic local account sign-in failed");
  const response = await fetch(
    `${config.apiUrl}/rest/v1/rpc/register_my_identity`,
    {
      method: "POST",
      headers: {
        apikey: config.anonKey,
        authorization: `Bearer ${data.session.access_token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        p_account_type: "student",
        p_age_confirmed: true,
        p_age_policy_version: "age-18-v1",
      }),
    },
  );
  if (!response.ok) {
    const body = await response.json().catch(() => null);
    if (body?.message !== "identity_already_registered")
      fail("synthetic account identity provisioning failed");
  }
  return user.id;
}

function grantCapabilities(ids) {
  const valid = Object.values(ids).every((id) => /^[0-9a-f-]{36}$/i.test(id));
  if (!valid) fail("local fixture identity was invalid");
  const sql = `
    with requested(user_id,capability,granted_by,reason) as (values
      ('${ids.reviewer}'::uuid,'verification_review','${ids.operator}'::uuid,'Synthetic local reviewer access bootstrapped by the guarded local CLI.'),
      ('${ids.reviewer}'::uuid,'identity_suspend','${ids.operator}'::uuid,'Synthetic local suspension access bootstrapped by the guarded local CLI.'),
      ('${ids.reviewer}'::uuid,'identity_unsuspend','${ids.operator}'::uuid,'Synthetic local unsuspension access bootstrapped by the guarded local CLI.')
    )
    insert into app_private.staff_grants(user_id,capability,granted_by,reason)
    select r.user_id,r.capability,r.granted_by,r.reason
    from requested r
    where not exists(
      select 1 from app_private.staff_grants g
      where g.user_id=r.user_id and g.capability=r.capability and g.revoked_at is null
    )
  `;
  run(
    cli,
    ["db", "query", "--local", "--output-format", "json", sql],
    "local staff grant bootstrap",
  );
}

async function main() {
  const local = status();
  const credentials = readCredentials();
  if (credentials.fixture_scope !== fixtureMarker)
    fail("local staff credentials file has the wrong fixture scope");
  const config = {
    apiUrl: new URL(local.env.API_URL).origin,
    anonKey: local.env.ANON_KEY,
    serviceKey: local.env.SERVICE_ROLE_KEY,
  };
  await provisionAuthUsers(config, credentials);
  const ids = {};
  for (const role of Object.keys(fixtureEmails))
    ids[role] = await registerIdentity(config, credentials, role);
  grantCapabilities(ids);
  saveCredentials(credentials);
  console.log(
    "PASS synthetic local staff and identity fixtures provisioned; credentials remain in ignored .supabase-home/step8-staff.json",
  );
}

main().catch((error) => {
  console.error(
    `FAIL local staff bootstrap: ${error instanceof Error ? error.message : "operation failed"}`,
  );
  process.exitCode = 1;
});
