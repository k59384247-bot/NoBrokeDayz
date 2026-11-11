import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { localSupabaseEnv } from "./local-supabase-env.mjs";

const root = resolve(import.meta.dirname, "..");
const npm = resolve(dirname(process.execPath), "npm");
const deno = resolve(root, "node_modules/.bin/deno");
const supabase = resolve(root, "node_modules/.bin/supabase");
const manifestWriter = resolve(
  root,
  "scripts/write-phase3-source-manifest.mjs",
);
const packageJson = JSON.parse(
  readFileSync(resolve(root, "package.json"), "utf8"),
);
const requiredScripts = [
  "check:phase2",
  "test:marketplace",
  "test:payments",
  "check:marketplace",
  "check:database",
];
const regressionScript = resolve(root, "scripts/check-phase3-regression.mjs");
const skipControlledRegression =
  process.env.NBD_SKIP_PHASE3_CONTROLLED_REGRESSION === "1";
const migrationCount = readdirSync(resolve(root, "supabase/migrations")).filter(
  (name) => name.endsWith(".sql"),
).length;
const startedAt = new Date().toISOString();
const baseEnv = localSupabaseEnv({ ...process.env });
const npmVersion = spawnSync(npm, ["--version"], {
  cwd: root,
  encoding: "utf8",
});
const denoVersion = spawnSync(deno, ["--version"], {
  cwd: root,
  env: baseEnv,
  encoding: "utf8",
});
const supabaseVersion = spawnSync(supabase, ["--version"], {
  cwd: root,
  env: baseEnv,
  encoding: "utf8",
});
let failed = false;
let primaryFailure;

function redact(value) {
  return value
    .replace(
      /\beyJ[A-Za-z0-9_-]{20,}(?:\.[A-Za-z0-9_-]+){0,2}\b/g,
      "[redacted token]",
    )
    .replace(/sb_(?:publishable|secret)_[A-Za-z0-9_-]+/g, "[redacted key]")
    .replace(/v1,whsec_[A-Za-z0-9+/=]+/g, "[redacted hook secret]")
    .replace(/postgres(?:ql)?:\/\/[^\s]+/gi, "[redacted database URL]");
}

function run(command, args, label, env = baseEnv) {
  const result = spawnSync(command, args, {
    cwd: root,
    env,
    encoding: "utf8",
    maxBuffer: 40 * 1024 * 1024,
  });
  const output = redact(
    [result.stdout, result.stderr].filter(Boolean).join("\n").trim(),
  );
  if (result.error || result.status !== 0) {
    throw new Error(
      `${label} failed (exit ${result.status ?? "unavailable"}).${output ? `\n${output.split(/\r?\n/).slice(-100).join("\n")}` : ""}`,
    );
  }
  if (output) process.stdout.write(`${output}\n`);
}

function validateToolchain() {
  assert.equal(process.version, "v22.23.2", "Node must match .nvmrc");
  assert.equal(npmVersion.status, 0);
  assert.equal(npmVersion.stdout.trim(), "10.9.8");
  assert.equal(denoVersion.status, 0);
  assert.match(denoVersion.stdout, /deno 2\.1\.4 \(stable,/);
  assert.equal(supabaseVersion.status, 0);
  assert.match(supabaseVersion.stdout, /2\.122\.0/);
  assert.ok(migrationCount > 0, "migration directory must not be empty");
  for (const path of [regressionScript, manifestWriter]) {
    if (!existsSync(path))
      throw new Error(`required phase runner file is missing: ${path}`);
  }
  for (const name of requiredScripts) {
    if (!packageJson.scripts?.[name])
      throw new Error(`required npm script is missing: ${name}`);
  }
}

function runNpmScript(name, label, { phase2Wrapper = false } = {}) {
  const env = phase2Wrapper ? { ...baseEnv, NBD_PHASE3_WRAPPER: "1" } : baseEnv;
  console.log(`\nRUN npm run ${name} — ${label}`);
  run(npm, ["run", name], label, env);
  console.log(`PASS npm run ${name}`);
}

console.log(`Phase 3 Step 10 local acceptance started: ${startedAt}`);
console.log(
  `Toolchain: Node ${process.version}; npm ${npmVersion.stdout?.trim() ?? "unavailable"}; ${denoVersion.stdout?.split(/\r?\n/)[0] ?? "Deno unavailable"}; Supabase CLI ${supabaseVersion.stdout?.trim() ?? "unavailable"}; PostgreSQL major ${readFileSync(resolve(root, "supabase/config.toml"), "utf8").match(/major_version = (\d+)/)?.[1] ?? "unknown"}`,
);
console.log(`Migration count: ${migrationCount}`);
console.log("Runtime boundary: native local Supabase and loopback HTTP only");

try {
  validateToolchain();
  if (skipControlledRegression) {
    console.log(
      "\nSKIP controlled financial mutation — reusing the recorded 4 November 2026 failure/restore evidence as requested; this run changes no production financial rule",
    );
  } else {
    console.log(
      "\nRUN controlled financial regression — temporarily ignore protected job principal; require the invariant test to fail, restore the migration, then rebuild local state",
    );
    run(
      process.execPath,
      [regressionScript],
      "controlled financial regression",
    );
    console.log(
      "PASS controlled financial regression and byte-for-byte restore",
    );
  }
  runNpmScript(
    "check:phase2",
    "original Phase 1/2 acceptance and regression checks",
    { phase2Wrapper: true },
  );
  runNpmScript(
    "test:marketplace",
    "marketplace handler boundaries and client-safe response regressions",
  );
  runNpmScript(
    "test:payments",
    "normalized local simulator adapter and retry regressions",
  );
  runNpmScript(
    "check:marketplace",
    "actual local Deno Edge HTTP acceptance, partner/student posters, and separate-connection races",
  );
} catch (error) {
  failed = true;
  primaryFailure = error;
  console.error(
    `\nFAIL Phase 3 Step 10: ${error instanceof Error ? error.message : "required check failed"}`,
  );
} finally {
  try {
    runNpmScript(
      "check:database",
      "terminal local migration rebuild, database regressions, fixture cleanup, formatted type comparison and stopped services",
    );
  } catch (error) {
    failed = true;
    console.error(
      `\nFAIL terminal local rebuild/cleanup: ${error instanceof Error ? error.message : "database check failed"}`,
    );
    if (!primaryFailure) primaryFailure = error;
  }
  try {
    run(process.execPath, [manifestWriter], "write safe source manifest");
  } catch (error) {
    failed = true;
    console.error(
      `\nFAIL source manifest: ${error instanceof Error ? error.message : "manifest generation failed"}`,
    );
    if (!primaryFailure) primaryFailure = error;
  }
}

const finishedAt = new Date().toISOString();
console.log(`Phase 3 Step 10 local acceptance finished: ${finishedAt}`);
if (failed) {
  console.error("FAIL Phase 3 Step 10 required checks did not all pass");
  process.exitCode = 1;
} else {
  console.log(
    "PASS Phase 3 Step 10 complete local acceptance, Phase 1/2 regression, and final clean rebuild",
  );
}
