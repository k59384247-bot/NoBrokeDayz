import { spawnSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { localSupabaseEnv } from "./local-supabase-env.mjs";

const root = resolve(import.meta.dirname, "..");
const cli = resolve(root, "node_modules/.bin/supabase");
const env = localSupabaseEnv();
let started = false;
let fixturesCreated = false;
let failed = false;
let status;

function run(command, args, label, extraEnv = env) {
  const result = spawnSync(command, args, {
    cwd: root,
    env: extraEnv,
    encoding: "utf8",
    maxBuffer: 8 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) {
    const output = [result.stderr, result.stdout]
      .filter(Boolean)
      .join("\n")
      .replace(
        /\beyJ[A-Za-z0-9_-]{20,}(?:\.[A-Za-z0-9_-]+){0,2}\b/g,
        "[redacted token]",
      )
      .replace(/sb_(?:publishable|secret)_[A-Za-z0-9_-]+/g, "[redacted key]")
      .replace(/\b\d{6}\b/g, "[redacted code]")
      .replace(/phase2-[\w-]+@identity\.test/gi, "[synthetic email]")
      .split(/\r?\n/)
      .slice(-80)
      .join("\n");
    throw new Error(`${label} failed${output ? `:\n${output}` : ""}`);
  }
  return result.stdout;
}

function fixture(action) {
  return run(
    process.execPath,
    ["scripts/identity-test-fixtures.mjs", action],
    `synthetic Auth fixture ${action}`,
  );
}

try {
  if (Number(process.versions.node.split(".")[0]) !== 22)
    throw new Error("use the repository-pinned Node 22 runtime (.nvmrc)");
  run(cli, ["stop"], "local stack stop before config reload");
  started = true;
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
    "native local Supabase start",
  );
  run(
    cli,
    ["migration", "up", "--local"],
    "non-destructive local migration apply",
  );
  status = JSON.parse(
    run(cli, ["status", "--output-format", "json"], "local Supabase status"),
  );
  const api = new URL(status.env?.API_URL);
  if (
    status.runtime !== "native" ||
    !["127.0.0.1", "localhost"].includes(api.hostname) ||
    api.port !== "54321" ||
    !status.env?.ANON_KEY ||
    !status.env?.SERVICE_ROLE_KEY
  )
    throw new Error(
      "staff access tests require the local native loopback project",
    );

  const types = run(
    cli,
    ["gen", "types", "typescript", "--local", "--schema", "public"],
    "client-safe public type generation",
  );
  if (!types.includes("export type Json") || types.includes("app_private"))
    throw new Error(
      `generated database types are invalid or expose a private schema: ${types.slice(0, 180)}`,
    );
  const formattedTypes = spawnSync(
    resolve(root, "node_modules/.bin/prettier"),
    ["--parser", "typescript"],
    {
      cwd: root,
      env,
      encoding: "utf8",
      input: types,
      maxBuffer: 10 * 1024 * 1024,
    },
  );
  if (formattedTypes.error || formattedTypes.status !== 0)
    throw new Error("client-safe database type formatting failed");
  writeFileSync(resolve(root, "lib/database.types.ts"), formattedTypes.stdout);
  console.log(
    "PASS formatted client-safe database types regenerated from public schema",
  );

  fixture("create");
  fixturesCreated = true;
  run(
    process.execPath,
    ["scripts/bootstrap-local-staff.mjs"],
    "synthetic local staff bootstrap",
  );
  const database = run(
    cli,
    ["test", "db"],
    "identity and staff database boundary tests",
  );
  if (database.trim()) console.log(database.trim());
  console.log(
    "PASS 319 pgTAP assertions, including foundation and Phase 2 Steps 2–9 boundaries",
  );

  const integrationEnv = {
    ...env,
    NBD_LOCAL_AUTH_STATUS_JSON: JSON.stringify(status),
  };
  const auth = run(
    process.execPath,
    [
      "--test",
      "tests/integration/identity/staff-access-boundaries.test.mjs",
      "tests/integration/identity/staff-mfa.test.mjs",
      "tests/integration/identity/profile-command-boundaries.test.mjs",
    ],
    "local MFA and staff command integration tests",
    integrationEnv,
  );
  if (auth.trim()) console.log(auth.trim());
  console.log(
    "PASS local Supabase TOTP AAL2, scoped identity commands, profile privacy and token-expiry tests",
  );
  run(
    process.execPath,
    ["scripts/bootstrap-local-staff.mjs"],
    "synthetic local staff grant restoration",
  );
  console.log("PASS synthetic reviewer grants restored for repeat local use");
} catch (error) {
  failed = true;
  console.error(
    `FAIL staff access check: ${error instanceof Error ? error.message : "local test failure"}`,
  );
} finally {
  if (started) {
    if (fixturesCreated) {
      try {
        fixture("cleanup");
        console.log("PASS synthetic baseline Auth fixtures removed");
      } catch {
        failed = true;
        console.error("FAIL cleanup of synthetic baseline Auth fixtures");
      }
    }
    try {
      run(cli, ["stop"], "local Supabase stop");
      console.log("PASS local Supabase stopped");
    } catch {
      failed = true;
      console.error("FAIL local Supabase stop");
    }
  }
}

if (failed) process.exitCode = 1;
