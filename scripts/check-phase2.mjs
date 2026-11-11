import { spawnSync } from "node:child_process";
import { dirname, resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const npm = resolve(dirname(process.execPath), "npm");
const checks = [
  ["format:check", "Prettier coverage for app, lib, tests and Edge Functions"],
  ["lint", "Oxlint coverage for app, scripts, lib, tests and Edge Functions"],
  [
    "typecheck:edge",
    "pinned Deno typecheck for every Edge Function entrypoint",
  ],
  ["typecheck", "Workers and application TypeScript"],
  ["test:identity-boundaries", "isolated identity command boundary tests"],
  ["check:runtime", "built local Workers-compatible runtime probe"],
  [
    "check:identity",
    "local Auth signup, confirmation, signin, recovery and cleanup",
  ],
  ["check:phone", "local Auth phone-change and signed SMS Hook integration"],
  [
    "check:school-email",
    "local school challenge and Track A qualification integration",
  ],
  [
    "check:verification-files",
    "local private Storage and evidence integration",
  ],
  [
    "check:profiles",
    "local staff AAL2, profile and identity database integration",
  ],
  [
    "check:edge-local",
    "actual local Deno HTTP authorization and reviewer queue visibility timing",
  ],
  ...(process.env.NBD_PHASE3_WRAPPER === "1"
    ? []
    : [
        [
          "check:database",
          "final migration rebuild, permission suite, type comparison and cleanup",
        ],
      ]),
];

function redact(value) {
  return value
    .replace(
      /\beyJ[A-Za-z0-9_-]{20,}(?:\.[A-Za-z0-9_-]+){0,2}\b/g,
      "[redacted JWT]",
    )
    .replace(
      /sb_(?:publishable|secret)_[A-Za-z0-9_-]+/g,
      "[redacted Supabase key]",
    )
    .replace(/v1,whsec_[A-Za-z0-9+/=]+/g, "[redacted hook secret]")
    .replace(/postgres(?:ql)?:\/\/[^\s]+/gi, "[redacted database URL]")
    .replace(/\b\d{6}\b/g, "[redacted OTP]")
    .replace(/\+?234[0-9 ()-]{8,}/g, "[synthetic phone]")
    .replace(/p2step[0-9]+-[A-Za-z0-9-]+@identity\.test/gi, "[synthetic email]")
    .replace(/phase2-[\w-]+@identity\.test/gi, "[synthetic email]");
}

function run(command, args, label) {
  const result = spawnSync(command, args, {
    cwd: root,
    env: process.env,
    encoding: "utf8",
    maxBuffer: 40 * 1024 * 1024,
  });
  const output = redact(
    [result.stdout, result.stderr].filter(Boolean).join("\n").trim(),
  );
  if (result.error || result.status !== 0) {
    const lines = output.split(/\r?\n/).slice(-100).join("\n");
    throw new Error(
      `${label} failed (exit ${result.status ?? "unavailable"}).${lines ? `\n${lines}` : ""}`,
    );
  }
  if (output) process.stdout.write(`${output}\n`);
}

const npmVersion = spawnSync(npm, ["--version"], {
  cwd: root,
  encoding: "utf8",
});
if (
  process.version !== "v22.23.2" ||
  npmVersion.status !== 0 ||
  npmVersion.stdout.trim() !== "10.9.8"
) {
  console.error(
    "FAIL check:phase2 requires Node 22.23.2 and npm 10.9.8 (.nvmrc/packageManager)",
  );
  process.exit(1);
}

console.log(
  `Toolchain: Node ${process.version}, npm ${npmVersion.stdout.trim()}`,
);
try {
  for (const [script, label] of checks) {
    console.log(`\nRUN npm run ${script} — ${label}`);
    run(npm, ["run", script], label);
    console.log(`PASS npm run ${script}`);
  }
  console.log(
    process.env.NBD_PHASE3_WRAPPER === "1"
      ? "\nPASS Phase 1/2 local acceptance checks; final rebuild is owned by Phase 3 wrapper"
      : "\nPASS Phase 2 local acceptance checks and final local fixture cleanup",
  );
} catch (error) {
  console.error(
    `\nFAIL check:phase2: ${error instanceof Error ? error.message : "local check failed"}`,
  );
  process.exitCode = 1;
}
