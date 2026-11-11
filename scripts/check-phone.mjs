import { resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { localSupabaseEnv } from "./local-supabase-env.mjs";

const root = resolve(import.meta.dirname, "..");
const cli = resolve(root, "node_modules/.bin/supabase");
const env = localSupabaseEnv();
let stackStarted = false;
let identityFixturesCreated = false;
let failed = false;
let status;

function run(command, args, label, runEnv = env) {
  const result = spawnSync(command, args, {
    cwd: root,
    env: runEnv,
    encoding: "utf8",
    maxBuffer: 8 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) {
    const safeLines = [result.stdout, result.stderr]
      .filter(Boolean)
      .join("\n")
      .replace(
        /\beyJ[A-Za-z0-9_-]{20,}(?:\.[A-Za-z0-9_-]+){0,2}\b/g,
        "[redacted token]",
      )
      .replace(/sb_(?:publishable|secret)_[A-Za-z0-9_-]+/g, "[redacted key]")
      .replace(/\bv1,whsec_[A-Za-z0-9+/=]+/g, "[redacted hook secret]")
      .replace(/\b\d{6}\b/g, "[redacted code]")
      .replace(/\+?234[0-9 ()-]{8,}/g, "[synthetic phone]")
      .replace(/p2step4-[A-Za-z0-9-]+@identity\.test/gi, "[synthetic email]")
      .split(/\r?\n/);
    const diagnostics = safeLines
      .filter((line) => line.includes("Auth boundary:"))
      .slice(0, 20);
    const safeOutput = [...diagnostics, ...safeLines.slice(-80)].join("\n");
    throw new Error(`${label} failed${safeOutput ? `:\n${safeOutput}` : ""}`);
  }
  return result.stdout;
}

async function cleanupAuthFixtures() {
  if (!status?.env?.API_URL || !status.env.SERVICE_ROLE_KEY) return;
  const baseUrl = status.env.API_URL;
  const serviceKey = status.env.SERVICE_ROLE_KEY;
  const headers = { apikey: serviceKey, authorization: `Bearer ${serviceKey}` };
  const listUsers = async () => {
    const response = await fetch(
      `${baseUrl}/auth/v1/admin/users?per_page=1000&page=1`,
      { headers },
    );
    if (!response.ok)
      throw new Error("local Auth fixture cleanup could not list users");
    return (await response.json()).users ?? [];
  };

  for (const user of await listUsers()) {
    if (
      !user.email?.startsWith("p2step4-") ||
      !user.email.endsWith("@identity.test")
    )
      continue;
    const deleted = await fetch(`${baseUrl}/auth/v1/admin/users/${user.id}`, {
      method: "DELETE",
      headers,
    });
    if (!deleted.ok)
      throw new Error("local synthetic Auth account cleanup failed");
  }
  if (
    (await listUsers()).some(
      (user) =>
        user.email?.startsWith("p2step4-") &&
        user.email.endsWith("@identity.test"),
    )
  ) {
    throw new Error(
      "local synthetic Auth account cleanup could not be verified",
    );
  }
  console.log(
    "PASS synthetic Auth fixtures cleaned without resetting local data",
  );
}

try {
  run(cli, ["stop"], "local stack stop before Auth configuration reload");
  stackStarted = true;
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
    "local Supabase start",
  );
  run(
    cli,
    ["migration", "up", "--local"],
    "non-destructive local migration apply",
  );
  status = JSON.parse(
    run(cli, ["status", "--output-format", "json"], "local Supabase status"),
  );
  const apiUrl = new URL(status.env?.API_URL);
  if (
    status.runtime !== "native" ||
    !["127.0.0.1", "localhost"].includes(apiUrl.hostname) ||
    apiUrl.port !== "54321" ||
    !status.env?.ANON_KEY ||
    !status.env?.SERVICE_ROLE_KEY
  ) {
    throw new Error(
      "phone integration requires the configured local native stack on loopback",
    );
  }

  run(
    process.execPath,
    ["scripts/identity-test-fixtures.mjs", "create"],
    "local database permission fixture creation",
  );
  identityFixturesCreated = true;
  run("npm", ["run", "supabase:test"], "database permission regression suite");
  run(
    process.execPath,
    ["scripts/identity-test-fixtures.mjs", "cleanup"],
    "local database permission fixture cleanup",
  );
  identityFixturesCreated = false;
  console.log("PASS foundation and identity database permission regressions");

  const adapterOutput = run(
    process.execPath,
    ["--test", "tests/integration/identity/phone-boundaries.test.mjs"],
    "simulated signed SMS hook tests",
  );
  if (adapterOutput.trim()) console.log(adapterOutput.trim());
  console.log(
    "PASS simulated Auth-signed webhook and local fake delivery adapter",
  );

  const testEnv = {
    ...env,
    NBD_LOCAL_AUTH_STATUS_JSON: JSON.stringify(status),
  };
  console.log(
    "RUN real Auth phone-change checks; the expiry assertion waits at least five minutes",
  );
  const authOutput = run(
    process.execPath,
    ["--test", "tests/integration/identity/phone.test.mjs"],
    "local Auth phone-change integration tests",
    testEnv,
  );
  const authReport = authOutput
    .split(/\r?\n/)
    .filter((line) => !line.includes("Auth boundary:"))
    .join("\n");
  if (authReport.trim()) console.log(authReport.trim());
  console.log(
    "PASS real Auth phone_change API with Auth-signed local SMS Hook and synthetic capture",
  );
} catch (error) {
  failed = true;
  console.error(
    `FAIL local phone integration: ${error instanceof Error ? error.message : "unknown local test failure"}`,
  );
} finally {
  if (identityFixturesCreated) {
    try {
      run(
        process.execPath,
        ["scripts/identity-test-fixtures.mjs", "cleanup"],
        "local database permission fixture cleanup",
      );
    } catch {
      failed = true;
      console.error("FAIL local database permission fixture cleanup");
    }
  }
  try {
    await cleanupAuthFixtures();
  } catch (error) {
    failed = true;
    console.error(
      `FAIL local phone fixture cleanup: ${error instanceof Error ? error.message : "unknown cleanup failure"}`,
    );
  }
  if (stackStarted) {
    try {
      run(cli, ["stop"], "local Supabase stop");
      console.log("PASS local Supabase stopped without resetting local data");
    } catch {
      failed = true;
      console.error("FAIL local Supabase stop");
    }
  }
}

if (failed) process.exitCode = 1;
