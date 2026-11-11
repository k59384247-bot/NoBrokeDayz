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
      .replace(
        /p2step[0-9]+-[A-Za-z0-9-]+@identity\.test/gi,
        "[synthetic email]",
      )
      .split(/\r?\n/)
      .slice(-80)
      .join("\n");
    throw new Error(`${label} failed${output ? `:\n${output}` : ""}`);
  }
  return result.stdout;
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
    api.port !== "54321"
  )
    throw new Error(
      "verification file checks require the local native loopback stack",
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
    "database identity, Storage and file permission tests",
  );
  if (database.trim()) console.log(database.trim());
  console.log(
    "PASS 319 pgTAP assertions (all current migrations through Phase 2 Step 9)",
  );

  const testEnv = {
    ...env,
    NBD_LOCAL_AUTH_STATUS_JSON: JSON.stringify(status),
  };
  const boundary = run(
    process.execPath,
    [
      "--test",
      "tests/integration/identity/verification-files-boundaries.test.mjs",
    ],
    "verification evidence command boundary tests",
  );
  if (boundary.trim()) console.log(boundary.trim());
  console.log(
    "PASS eleven upload, validation, quarantine and reviewer authorization boundary tests",
  );

  const reviewBoundary = run(
    process.execPath,
    [
      "--test",
      "tests/integration/identity/verification-review-boundaries.test.mjs",
    ],
    "verification review command boundary tests",
  );
  if (reviewBoundary.trim()) console.log(reviewBoundary.trim());
  console.log("PASS three verification review command boundary tests");

  const storage = run(
    process.execPath,
    ["--test", "tests/integration/identity/verification-storage.test.mjs"],
    "local Auth and Storage integration tests",
    testEnv,
  );
  if (storage.trim()) console.log(storage.trim());
  console.log(
    "PASS local Auth ownership, private Storage access and application download proxy expiry tests",
  );
} catch (error) {
  failed = true;
  console.error(
    `FAIL local verification evidence check: ${error instanceof Error ? error.message : "unknown local test failure"}`,
  );
} finally {
  if (stackStarted) {
    if (fixturesCreated) {
      try {
        run(
          process.execPath,
          ["scripts/identity-test-fixtures.mjs", "cleanup"],
          "local Auth fixture cleanup",
        );
        console.log("PASS synthetic local Auth fixtures removed");
      } catch (error) {
        failed = true;
        console.error(
          `FAIL local Auth fixture cleanup: ${error instanceof Error ? error.message : "cleanup failed"}`,
        );
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
