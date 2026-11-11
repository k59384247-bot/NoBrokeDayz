import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { localSupabaseEnv } from "./local-supabase-env.mjs";

const root = resolve(import.meta.dirname, "..");
const npm = resolve(dirname(process.execPath), "npm");
const deno = resolve(root, "node_modules/.bin/deno");
const supabase = resolve(root, "node_modules/.bin/supabase");
const manifestWriter = resolve(
  root,
  "scripts/write-phase4-source-manifest.mjs",
);
const matrix = resolve(root, "docs/phase-4-step-10-acceptance.md");
const packageJson = JSON.parse(
  readFileSync(resolve(root, "package.json"), "utf8"),
);
const migrationCount = readdirSync(resolve(root, "supabase/migrations")).filter(
  (name) => name.endsWith(".sql"),
).length;
const sqlTestCount = readdirSync(
  resolve(root, "supabase/tests/database"),
).filter((name) => name.endsWith(".test.sql")).length;
const startedAt = new Date().toISOString();
const baseEnv = localSupabaseEnv({ ...process.env });
const steps = [];
let failed = false;
let primaryFailure;

function redact(value) {
  return value
    .replace(
      /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g,
      "[redacted private key]",
    )
    .replace(
      /\beyJ[A-Za-z0-9_-]{20,}(?:\.[A-Za-z0-9_-]+){0,2}\b/g,
      "[redacted token]",
    )
    .replace(/sb_(?:publishable|secret)_[A-Za-z0-9_-]+/g, "[redacted key]")
    .replace(/v1,whsec_[A-Za-z0-9+/=]+/g, "[redacted hook secret]")
    .replace(/postgres(?:ql)?:\/\/[^\s]+/gi, "[redacted database URL]")
    .replace(/\b[A-Za-z0-9._%+-]+@identity\.test\b/gi, "[synthetic email]")
    .replace(/\+?234[0-9 ()-]{8,}/g, "[synthetic phone]");
}

function run(command, args, label, env = baseEnv) {
  const started = process.hrtime.bigint();
  const result = spawnSync(command, args, {
    cwd: root,
    env,
    encoding: "utf8",
    maxBuffer: 50 * 1024 * 1024,
  });
  const durationMs = Number(process.hrtime.bigint() - started) / 1e6;
  const output = redact(
    [result.stdout, result.stderr].filter(Boolean).join("\n").trim(),
  );
  const step = {
    label,
    command: [command.split("/").at(-1), ...args].join(" "),
    status: result.status === 0 && !result.error ? "passed" : "failed",
    duration_ms: Math.round(durationMs),
  };
  steps.push(step);
  if (step.status !== "passed") {
    const detail = output.split(/\r?\n/).slice(-100).join("\n");
    throw new Error(
      `${label} failed (exit ${result.status ?? "unavailable"}).${detail ? `\n${detail}` : ""}`,
    );
  }
  if (output) process.stdout.write(`${output}\n`);
  console.log(`PASS ${label} (${step.duration_ms} ms)`);
}

function npmScript(name, label, env = baseEnv) {
  console.log(`\nRUN npm run ${name} — ${label}`);
  run(npm, ["run", name], label, env);
}

function toolVersion(command, args) {
  const result = spawnSync(command, args, {
    cwd: root,
    env: baseEnv,
    encoding: "utf8",
  });
  if (result.status !== 0) return "unavailable";
  return [result.stdout, result.stderr].filter(Boolean).join(" ").trim();
}

function validateSetup() {
  assert.equal(process.version, "v22.23.2", "use the pinned Node runtime");
  assert.equal(toolVersion(npm, ["--version"]), "10.9.8");
  assert.match(toolVersion(deno, ["--version"]), /deno 2\.1\.4 \(stable,/);
  assert.match(toolVersion(supabase, ["--version"]), /2\.122\.0/);
  assert.equal(migrationCount, 41, "all 41 current migrations are expected");
  assert.equal(sqlTestCount, 17, "all 17 SQL test files are expected");
  for (const name of [
    "check:phase2",
    "test:marketplace",
    "test:payments",
    "test:cases",
    "test:audit-checkpoint",
    "check:marketplace",
    "check:database",
  ])
    assert.ok(packageJson.scripts?.[name], `missing required script ${name}`);
  assert.ok(existsSync(manifestWriter));
  assert.ok(existsSync(matrix));
}

console.log(`Phase 4 Step 10 local acceptance started: ${startedAt}`);
console.log(
  `Toolchain: Node ${process.version}; npm ${toolVersion(npm, ["--version"])}; ${toolVersion(deno, ["--version"]).split(/\r?\n/)[0]}; Supabase CLI ${toolVersion(supabase, ["--version"])}; PostgreSQL major ${readFileSync(resolve(root, "supabase/config.toml"), "utf8").match(/major_version = (\d+)/)?.[1] ?? "unknown"}`,
);
console.log(`Migration count: ${migrationCount}`);
console.log(`SQL database test files: ${sqlTestCount}`);
console.log(
  "Runtime boundary: native local Supabase and loopback Deno Edge HTTP only",
);

try {
  validateSetup();
  console.log(
    "Reusing the recorded Phase 3 controlled failure/restore evidence; no migration is mutated for this run.",
  );
  npmScript(
    "test:cases",
    "case command/read handler validation and safe projections",
  );
  npmScript("test:audit-checkpoint", "signed audit checkpoint unit tests");
  npmScript(
    "check:phase2",
    "Phase 1/2 regression, format, lint, Deno/app types and local runtime checks",
    { ...baseEnv, NBD_PHASE3_WRAPPER: "1" },
  );
  npmScript(
    "test:marketplace",
    "marketplace database/handler boundary integration tests",
  );
  npmScript(
    "test:payments",
    "payment runner, simulator, callback and retry integration tests",
  );
  npmScript(
    "check:marketplace",
    "local Auth AAL1/AAL2 and actual Deno Edge HTTP marketplace, case, cancellation and refund journey",
  );
} catch (error) {
  failed = true;
  primaryFailure = error;
  console.error(
    `\nFAIL Phase 4 Step 10 required checks: ${error instanceof Error ? error.message : "local check failed"}`,
  );
} finally {
  try {
    npmScript(
      "check:database",
      "terminal rebuild of all migrations, SQL permission tests, marked fixture cleanup, generated type comparison and local shutdown",
    );
  } catch (error) {
    failed = true;
    if (!primaryFailure) primaryFailure = error;
    console.error(
      `\nFAIL terminal local rebuild/cleanup: ${error instanceof Error ? error.message : "database check failed"}`,
    );
  }
  try {
    run(
      process.execPath,
      [manifestWriter],
      "write safe Phase 4 source manifest",
    );
  } catch (error) {
    failed = true;
    if (!primaryFailure) primaryFailure = error;
    console.error(
      `\nFAIL safe source manifest: ${error instanceof Error ? error.message : "manifest generation failed"}`,
    );
  }
}

const finishedAt = new Date().toISOString();
console.log(`Phase 4 Step 10 local acceptance finished: ${finishedAt}`);
for (const step of steps)
  console.log(
    `STEP ${step.status.toUpperCase()} ${step.label}: ${step.duration_ms} ms`,
  );
const gitRevision = spawnSync("git", ["rev-parse", "HEAD"], {
  cwd: root,
  encoding: "utf8",
});
console.log(
  gitRevision.status === 0
    ? `Git revision: ${gitRevision.stdout.trim()}`
    : "Git revision: unavailable (no committed HEAD in this workspace)",
);
if (failed) {
  console.error(
    `FAIL Phase 4 Step 10: ${primaryFailure instanceof Error ? primaryFailure.message : "required local evidence is incomplete"}`,
  );
  process.exitCode = 1;
} else {
  console.log(
    "PASS Phase 4 Step 10 local acceptance; production provider, hosted services and independent production checkpoint custody remain outside this local proof.",
  );
}
