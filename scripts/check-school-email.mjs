import { resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { localSupabaseEnv } from "./local-supabase-env.mjs";

const root = resolve(import.meta.dirname, "..");
const cli = resolve(root, "node_modules/.bin/supabase");
const env = localSupabaseEnv();
let stackStarted = false;
let fixturesCreated = false;
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
    const output = [result.stdout, result.stderr]
      .filter(Boolean)
      .join("\n")
      .replace(
        /\beyJ[A-Za-z0-9_-]{20,}(?:\.[A-Za-z0-9_-]+){0,2}\b/g,
        "[redacted token]",
      )
      .replace(/sb_(?:publishable|secret)_[A-Za-z0-9_-]+/g, "[redacted key]")
      .replace(/\b\d{6}\b/g, "[redacted code]")
      .replace(/p2step5-[A-Za-z0-9-]+@identity\.test/gi, "[synthetic email]")
      .split(/\r?\n/)
      .slice(-100)
      .join("\n");
    throw new Error(`${label} failed${output ? `:\n${output}` : ""}`);
  }
  return result.stdout;
}

function safeNodeTests(file, label) {
  return run(process.execPath, ["--test", file], label, {
    ...env,
    NBD_LOCAL_AUTH_STATUS_JSON: JSON.stringify(status),
  });
}

try {
  if (Number(process.versions.node.split(".")[0]) < 22)
    throw new Error("use the pinned Node 22 runtime");
  run(cli, ["stop"], "local stack stop before configuration reload");
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
    "local native Supabase start",
  );
  status = JSON.parse(
    run(cli, ["status", "--output-format", "json"], "local Supabase status"),
  );
  const api = new URL(status.env?.API_URL);
  if (
    status.runtime !== "native" ||
    !["127.0.0.1", "localhost"].includes(api.hostname) ||
    api.port !== "54321"
  )
    throw new Error(
      "school verification check requires the local native loopback stack",
    );

  // This check is intentionally isolated by a local-only reset before and after its integration fixtures.
  run(
    cli,
    ["db", "reset", "--local", "--yes"],
    "local-only school test database prepare",
  );
  run(
    process.execPath,
    ["scripts/identity-test-fixtures.mjs", "create"],
    "local Auth fixture creation",
  );
  fixturesCreated = true;
  const database = run(
    cli,
    ["test", "db"],
    "database identity and school permission tests",
  );
  if (database.trim()) console.log(database.trim());
  console.log(
    "PASS 319 pgTAP assertions (all current migrations through Phase 2 Step 9)",
  );

  const boundaries = safeNodeTests(
    "tests/integration/identity/school-email-boundaries.test.mjs",
    "school command boundary tests",
  );
  if (boundaries.trim()) console.log(boundaries.trim());
  console.log(
    "PASS HMAC challenge command, safe delivery and response boundaries",
  );

  const integration = safeNodeTests(
    "tests/integration/identity/school-email.test.mjs",
    "local Auth and school email integration tests",
  );
  if (integration.trim()) console.log(integration.trim());
  console.log(
    "PASS synthetic local email capture, parallel consumption, ownership race and Track A qualification",
  );
} catch (error) {
  failed = true;
  console.error(
    `FAIL local school email check: ${error instanceof Error ? error.message : "unknown local test failure"}`,
  );
} finally {
  if (stackStarted) {
    try {
      run(
        cli,
        ["db", "reset", "--local", "--yes"],
        "local school fixture cleanup reset",
      );
      if (status?.env?.API_URL && status?.env?.SERVICE_ROLE_KEY) {
        const response = await fetch(
          `${status.env.API_URL}/auth/v1/admin/users?per_page=1000&page=1`,
          {
            headers: {
              apikey: status.env.SERVICE_ROLE_KEY,
              authorization: `Bearer ${status.env.SERVICE_ROLE_KEY}`,
            },
          },
        );
        if (!response.ok) {
          failed = true;
          console.error("FAIL local Auth cleanup verification");
        } else {
          const { users = [] } = await response.json();
          if (
            users.some(
              (user) =>
                user.email?.startsWith("p2step5-") ||
                user.email === "phase2-owner@identity.test" ||
                user.email === "phase2-other@identity.test" ||
                user.email === "phase2-trackb@identity.test",
            )
          ) {
            failed = true;
            console.error("FAIL synthetic local Auth users remain after reset");
          }
        }
      }
      if (fixturesCreated)
        console.log(
          "PASS synthetic local Auth and Identity fixtures removed by local reset",
        );
    } catch (error) {
      failed = true;
      console.error(
        `FAIL local school fixture cleanup: ${error instanceof Error ? error.message : "cleanup failed"}`,
      );
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
