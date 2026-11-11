import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { localSupabaseEnv } from "./local-supabase-env.mjs";

const root = resolve(import.meta.dirname, "..");
const migrationPath = resolve(
  root,
  "supabase/migrations/20261104000700_wallet_and_manual_withdrawals.sql",
);
const cli = resolve(root, "node_modules/.bin/supabase");
const npm = resolve(dirname(process.execPath), "npm");
const fixtureScript = resolve(root, "scripts/identity-test-fixtures.mjs");
const testPath = "supabase/tests/database/015_wallet_withdrawals.test.sql";
const testSourcePath = resolve(root, testPath);
const temporaryTestPath = resolve(
  root,
  ".supabase-home/step10-controlled-regression.test.sql",
);
const invariantName =
  "payment runner cannot claim or dispatch the queued payout without sufficient liquidity";
const original = readFileSync(migrationPath);
const source = original.toString("utf8");
const protectedCashRule = "v_available:=v_cash-v_other_protected;";
const mutation = "v_available:=v_cash;";
const matches = source.split(protectedCashRule).length - 1;
const baseEnv = localSupabaseEnv({
  ...process.env,
  NBD_PAYMENT_MODE: "disabled",
});
let stackStartAttempted = false;
let stackStarted = false;
let fixturesCreated = false;
let temporaryTestWritten = false;
let passed = false;
let cleanupError;

function redact(value) {
  return value
    .replace(
      /\beyJ[A-Za-z0-9_-]{20,}(?:\.[A-Za-z0-9_-]+){0,2}\b/g,
      "[redacted token]",
    )
    .replace(
      /("[A-Z0-9_]*(?:KEY|SECRET|TOKEN|PASSWORD)[A-Z0-9_]*"\s*:\s*")[^"]*(")/gi,
      "$1[redacted local secret]$2",
    )
    .replace(/sb_(?:publishable|secret)_[A-Za-z0-9_-]+/g, "[redacted key]")
    .replace(/postgres(?:ql)?:\/\/[^\s]+/gi, "[redacted database URL]");
}

function run(command, args, label, env = baseEnv, silent = false) {
  const result = spawnSync(command, args, {
    cwd: root,
    env,
    encoding: "utf8",
    maxBuffer: 20 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) {
    const output = redact(
      [result.stdout, result.stderr].filter(Boolean).join("\n").trim(),
    );
    throw new Error(
      `${label} failed${output ? `:\n${output.slice(-6000)}` : ""}`,
    );
  }
  const output = [result.stdout, result.stderr]
    .filter(Boolean)
    .join("\n")
    .trim();
  if (!silent && output) process.stdout.write(`${redact(output)}\n`);
  return result.stdout;
}

try {
  assert.equal(matches, 1, "controlled regression anchor must match once");
  writeFileSync(migrationPath, source.replace(protectedCashRule, mutation));

  stackStartAttempted = true;
  run(cli, ["stop"], "stop any prior local stack");
  run(
    npm,
    ["run", "supabase:start"],
    "start native local Supabase",
    baseEnv,
    true,
  );
  stackStarted = true;
  run(
    npm,
    ["run", "supabase:reset:local"],
    "apply the controlled mutation to a clean local database",
  );
  const status = JSON.parse(
    run(
      cli,
      ["status", "--output-format", "json"],
      "read local status",
      baseEnv,
      true,
    ),
  );
  const api = new URL(status.env?.API_URL ?? "http://invalid.test");
  assert.equal(status.runtime, "native");
  assert.ok(["127.0.0.1", "localhost"].includes(api.hostname));
  assert.equal(api.port, "54321");

  run(
    process.execPath,
    [fixtureScript, "create"],
    "create local Auth fixtures",
  );
  fixturesCreated = true;

  const testSource = readFileSync(testSourcePath, "utf8");
  const assertionMarker = `'${invariantName}');`;
  const assertionMarkerIndex = testSource.indexOf(assertionMarker);
  assert.notEqual(
    assertionMarkerIndex,
    -1,
    "wallet invariant assertion must exist",
  );
  assert.equal(
    testSource.indexOf(assertionMarker, assertionMarkerIndex + 1),
    -1,
    "wallet invariant assertion must be unique",
  );
  const assertionEnd = testSource.indexOf(");", assertionMarkerIndex);
  assert.notEqual(
    assertionEnd,
    -1,
    "wallet invariant assertion must be complete",
  );
  writeFileSync(
    temporaryTestPath,
    `${testSource.slice(0, assertionEnd + 2)}\nselect * from finish();\nrollback;\n`,
    { flag: "wx", mode: 0o600 },
  );
  temporaryTestWritten = true;

  const result = spawnSync(cli, ["test", "db", "--local", temporaryTestPath], {
    cwd: root,
    env: baseEnv,
    encoding: "utf8",
    maxBuffer: 20 * 1024 * 1024,
  });
  const output = redact(
    [result.stdout, result.stderr].filter(Boolean).join("\n"),
  );
  const detectedInvariantFailure =
    output.includes(invariantName) && /Failed test|not ok/.test(output);
  if (result.error || result.status === 0 || !detectedInvariantFailure) {
    throw new Error(
      `controlled mutation did not produce the expected failing assertion (exit ${result.status ?? "unavailable"}).\n${output.split(/\r?\n/).slice(-50).join("\n")}`,
    );
  }

  console.log(
    `PASS controlled regression: the deliberate protected-principal availability defect failed the expected pgTAP assertion: "${invariantName}"`,
  );
  passed = true;
} finally {
  writeFileSync(migrationPath, original);
  assert.deepEqual(readFileSync(migrationPath), original);
  console.log("PASS controlled migration source restored byte-for-byte");

  if (temporaryTestWritten) {
    try {
      unlinkSync(temporaryTestPath);
    } catch (error) {
      cleanupError ??= error;
    }
  }
  if (fixturesCreated) {
    try {
      run(
        process.execPath,
        [fixtureScript, "cleanup"],
        "remove local Auth fixtures",
      );
    } catch (error) {
      cleanupError = error;
    }
  }
  if (stackStartAttempted) {
    if (stackStarted) {
      try {
        run(
          npm,
          ["run", "supabase:reset:local"],
          "rebuild local database from restored migrations",
        );
      } catch (error) {
        cleanupError ??= error;
      }
    }
    try {
      run(npm, ["run", "supabase:stop"], "stop local Supabase");
      console.log(
        "PASS controlled regression cleanup: restored local database rebuilt and services stopped",
      );
    } catch (error) {
      cleanupError ??= error;
    }
  }
}

if (cleanupError) throw cleanupError;
if (!passed) process.exitCode = 1;
