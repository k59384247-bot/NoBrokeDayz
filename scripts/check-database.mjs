import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { localSupabaseEnv } from "./local-supabase-env.mjs";

const root = resolve(import.meta.dirname, "..");
const checkId = randomUUID();
const cli = resolve(root, "node_modules/.bin/supabase");
const cliEnv = localSupabaseEnv({
  ...process.env,
});
let startAttempted = false;
let failed = false;

function run(command, args, phase, env = process.env) {
  const result = spawnSync(command, args, {
    cwd: root,
    env,
    encoding: "utf8",
    maxBuffer: 10 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) {
    const detail = [result.stdout, result.stderr]
      .filter(Boolean)
      .join("\n")
      .split(/\r?\n/)
      .map((line) =>
        /anon[_ -]*key|service[_ -]*role[_ -]*key|publishable[_ -]*key|secret[_ -]*key|password|jwt[_ -]*secret|postgres(?:ql)?:\/\//i.test(
          line,
        )
          ? "[redacted sensitive CLI output]"
          : line.replace(
              /\beyJ[A-Za-z0-9_-]{20,}(?:\.[A-Za-z0-9_-]+){0,2}\b/g,
              "[redacted token]",
            ),
      )
      .filter(Boolean)
      .slice(-30)
      .join("\n");
    throw new Error(
      `${phase} failed (check ${checkId}, exit ${result.status ?? "unavailable"}).\n${detail || "No safe diagnostic output was available."}`,
    );
  }
  if (phase !== "start") {
    const output = [result.stdout, result.stderr]
      .filter(Boolean)
      .join("\n")
      .trim();
    if (output) process.stdout.write(`${output}\n`);
  }
}

try {
  startAttempted = true;
  run("npm", ["run", "supabase:start"], "start");
  console.log(`PASS local Supabase started (check ${checkId})`);
  run("npm", ["run", "supabase:reset:local"], "local migration reset");
  run(
    "node",
    ["scripts/identity-test-fixtures.mjs", "create"],
    "synthetic Auth fixture creation",
    cliEnv,
  );
  try {
    run(
      "npm",
      ["run", "test:identity-registration"],
      "identity registration boundary tests",
    );
    run("npm", ["run", "supabase:test"], "database permission tests");
  } finally {
    run(
      "node",
      ["scripts/identity-test-fixtures.mjs", "cleanup"],
      "synthetic Auth fixture cleanup",
      cliEnv,
    );
  }

  const generated = spawnSync(
    cli,
    ["gen", "types", "typescript", "--local", "--schema", "public"],
    { cwd: root, env: cliEnv, encoding: "utf8", maxBuffer: 10 * 1024 * 1024 },
  );
  if (generated.error || generated.status !== 0) {
    throw new Error(
      `type generation failed (check ${checkId}, exit ${generated.status ?? "unavailable"}).`,
    );
  }
  const formattedTypes = spawnSync(
    resolve(root, "node_modules/.bin/prettier"),
    ["--parser", "typescript", "--stdin-filepath", "lib/database.types.ts"],
    {
      cwd: root,
      env: cliEnv,
      encoding: "utf8",
      input: generated.stdout,
      maxBuffer: 10 * 1024 * 1024,
    },
  );
  if (formattedTypes.error || formattedTypes.status !== 0) {
    throw new Error(
      `generated database type formatting failed (check ${checkId}).`,
    );
  }
  const checkedInTypes = readFileSync(
    resolve(root, "lib/database.types.ts"),
    "utf8",
  ).trimEnd();
  if (formattedTypes.stdout.trimEnd() !== checkedInTypes) {
    throw new Error(
      `generated database types are stale (check ${checkId}); run npm run supabase:types.`,
    );
  }
  console.log(
    `PASS formatted generated public database types match (check ${checkId})`,
  );
} catch (error) {
  failed = true;
  console.error(
    `FAIL ${error instanceof Error ? error.message : `unknown failure (check ${checkId})`}`,
  );
} finally {
  if (startAttempted) {
    try {
      run("npm", ["run", "supabase:stop"], "stop");
      console.log(`PASS local Supabase stopped (check ${checkId})`);
    } catch (error) {
      failed = true;
      console.error(
        `FAIL ${error instanceof Error ? error.message : `local Supabase stop failed (check ${checkId})`}`,
      );
    }
  }
}

if (failed) process.exitCode = 1;
