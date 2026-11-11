import { randomBytes } from "node:crypto";
import { resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { localSupabaseEnv } from "./local-supabase-env.mjs";

const root = resolve(import.meta.dirname, "..");
const cli = resolve(root, "node_modules/.bin/supabase");
const fixtures = [
  { email: "phase2-owner@identity.test" },
  { email: "phase2-other@identity.test" },
  { email: "phase2-trackb@identity.test", phone: "+2347000000098" },
  { email: "phase2-profileviewer@identity.test", phone: "+2347000000100" },
];
const emails = fixtures.map((fixture) => fixture.email);
const marker = "no-broke-dayz-phase2-step2-local-fixture";
const cliEnv = localSupabaseEnv();

function fail(message) {
  throw new Error(message);
}

function localAuthConfig() {
  const result = spawnSync(cli, ["status", "--output-format", "json"], {
    cwd: root,
    env: cliEnv,
    encoding: "utf8",
    maxBuffer: 2 * 1024 * 1024,
  });
  if (result.error || result.status !== 0)
    fail("could not read local Supabase status");

  let status;
  try {
    status = JSON.parse(result.stdout);
  } catch {
    fail("local Supabase status was not JSON");
  }

  const apiUrl = new URL(status.env?.API_URL);
  if (
    !["127.0.0.1", "localhost"].includes(apiUrl.hostname) ||
    !["http:", "https:"].includes(apiUrl.protocol) ||
    !status.env?.SERVICE_ROLE_KEY
  ) {
    fail("identity fixtures are restricted to a loopback Supabase project");
  }
  return { apiUrl: apiUrl.origin, serviceKey: status.env.SERVICE_ROLE_KEY };
}

async function request(config, path, options = {}) {
  const response = await fetch(`${config.apiUrl}${path}`, {
    ...options,
    headers: {
      apikey: config.serviceKey,
      Authorization: `Bearer ${config.serviceKey}`,
      "Content-Type": "application/json",
      ...options.headers,
    },
  });
  if (!response.ok)
    fail(`local Auth admin request failed (${response.status})`);
  return response.status === 204 ? null : response.json();
}

async function listFixtureUsers(config) {
  const data = await request(
    config,
    "/auth/v1/admin/users?per_page=1000&page=1",
  );
  return (data.users ?? []).filter(
    (user) =>
      emails.includes(user.email) &&
      user.app_metadata?.local_fixture_scope === marker,
  );
}

async function cleanup(config) {
  const users = await listFixtureUsers(config);
  for (const user of users) {
    await request(config, `/auth/v1/admin/users/${user.id}`, {
      method: "DELETE",
    });
  }
  if ((await listFixtureUsers(config)).length > 0) {
    fail("synthetic Auth fixture cleanup could not be verified");
  }
}

async function create(config) {
  try {
    const users = await request(
      config,
      "/auth/v1/admin/users?per_page=1000&page=1",
    );
    for (const fixture of fixtures) {
      const { email } = fixture;
      const existing = (users.users ?? []).find((user) => user.email === email);
      if (existing) {
        if (existing.app_metadata?.local_fixture_scope !== marker) {
          fail(
            "reserved synthetic fixture email is already in use; no account was changed",
          );
        }
        await request(config, `/auth/v1/admin/users/${existing.id}`, {
          method: "DELETE",
        });
      }

      await request(config, "/auth/v1/admin/users", {
        method: "POST",
        body: JSON.stringify({
          email,
          password: randomBytes(32).toString("base64url"),
          email_confirm: true,
          ...(fixture.phone
            ? { phone: fixture.phone, phone_confirm: true }
            : {}),
          app_metadata: { local_fixture_scope: marker },
          user_metadata: {
            account_type: "partner",
            verification_status: "approved",
            staff_capabilities: ["identity_suspend"],
          },
        }),
      });
    }
  } catch (error) {
    try {
      await cleanup(config);
    } catch {
      fail(
        "synthetic Auth fixture creation failed and cleanup could not be verified",
      );
    }
    throw error;
  }
}

try {
  const action = process.argv[2];
  const config = localAuthConfig();
  if (action === "create") {
    await create(config);
    console.log("PASS synthetic local Auth fixtures created");
  } else if (action === "cleanup") {
    await cleanup(config);
    console.log("PASS synthetic local Auth fixtures removed");
  } else {
    fail("expected create or cleanup action");
  }
} catch (error) {
  console.error(
    `FAIL ${error instanceof Error ? error.message : "local fixture operation failed"}`,
  );
  process.exitCode = 1;
}
