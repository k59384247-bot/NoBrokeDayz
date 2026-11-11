import { resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { localSupabaseEnv } from "./local-supabase-env.mjs";

const root = resolve(import.meta.dirname, "..");
const cli = resolve(root, "node_modules/.bin/supabase");
const cliEnv = localSupabaseEnv({
  ...process.env,
});
let started = false;
let failed = false;
let status;

function run(command, args, label, env = cliEnv) {
  const result = spawnSync(command, args, {
    cwd: root,
    env,
    encoding: "utf8",
    maxBuffer: 8 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) {
    const detail = [result.stdout, result.stderr]
      .filter(Boolean)
      .join("\n")
      .split(/\r?\n/)
      .map((line) =>
        /anon[_ -]*key|service[_ -]*role[_ -]*key|publishable[_ -]*key|secret[_ -]*key|jwt[_ -]*secret|postgres(?:ql)?:\/\//i.test(
          line,
        )
          ? "[redacted sensitive output]"
          : line.replace(
              /\beyJ[A-Za-z0-9_-]{20,}(?:\.[A-Za-z0-9_-]+){0,2}\b/g,
              "[redacted token]",
            ),
      )
      .filter(Boolean)
      .slice(-200)
      .join("\n");
    throw new Error(
      `${label} failed.\n${detail || "No safe diagnostic output."}`,
    );
  }
  return result.stdout;
}

try {
  run(cli, ["stop"], "local stack stop before Auth config reload");
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
    "local Supabase start",
  );
  run(
    cli,
    ["db", "reset", "--local", "--yes"],
    "local identity database prepare",
  );

  const statusText = run(
    cli,
    ["status", "--output-format", "json"],
    "local Supabase status",
  );
  status = JSON.parse(statusText);
  const restAddress = status.endpoints?.["rest.http"]?.address;
  const authAddress = status.endpoints?.["auth.http"]?.address;
  if (
    status.runtime !== "native" ||
    !["127.0.0.1", "localhost"].includes(restAddress) ||
    !["127.0.0.1", "localhost"].includes(authAddress) ||
    !status.env?.ANON_KEY ||
    !status.env?.SERVICE_ROLE_KEY ||
    !status.env?.MAILPIT_URL
  ) {
    throw new Error(
      "identity integration is restricted to this local native stack and Mailpit",
    );
  }

  const testEnv = {
    ...process.env,
    NBD_LOCAL_AUTH_STATUS_JSON: JSON.stringify(status),
  };
  const testOutput = run(
    process.execPath,
    ["--test", "tests/integration/identity/auth.test.mjs"],
    "local Auth integration tests",
    testEnv,
  );
  if (testOutput.trim()) console.log(testOutput.trim());
  console.log(
    "PASS local Auth integration (synthetic accounts and local Mailpit only)",
  );
} catch (error) {
  failed = true;
  console.error(
    `FAIL local Auth integration: ${error instanceof Error ? error.message : "unknown error"}`,
  );
} finally {
  if (started) {
    try {
      if (status?.env?.MAILPIT_URL) {
        const response = await fetch(
          new URL("/api/v1/messages", status.env.MAILPIT_URL),
          {
            method: "DELETE",
            headers: { "Content-Type": "application/json" },
            body: "{}",
          },
        );
        if (!response.ok) {
          failed = true;
          console.error("FAIL local Mailpit cleanup");
        }
      }
      run(
        cli,
        ["db", "reset", "--local", "--yes"],
        "local Auth fixture cleanup",
      );
      const cleanedStatus = JSON.parse(
        run(cli, ["status", "--output-format", "json"], "local cleanup status"),
      );
      const adminResponse = await fetch(
        `${cleanedStatus.env.API_URL}/auth/v1/admin/users?per_page=1000&page=1`,
        {
          headers: {
            apikey: cleanedStatus.env.SERVICE_ROLE_KEY,
            Authorization: `Bearer ${cleanedStatus.env.SERVICE_ROLE_KEY}`,
          },
        },
      );
      if (!adminResponse.ok) {
        failed = true;
        console.error("FAIL local Auth cleanup verification");
      } else {
        const adminPage = await adminResponse.json();
        if (
          (adminPage.users ?? []).some(
            (user) =>
              user.email?.startsWith("p2step3-") &&
              user.email?.endsWith("@identity.test"),
          )
        ) {
          failed = true;
          console.error("FAIL synthetic Auth account cleanup verification");
        } else {
          console.log(
            "PASS local Auth users, database records, and Mailpit messages cleaned",
          );
        }
      }
    } catch (error) {
      failed = true;
      console.error(
        `FAIL local Auth fixture cleanup: ${error instanceof Error ? error.message : "unknown error"}`,
      );
    }
    try {
      run(cli, ["stop"], "local Supabase stop");
      console.log("PASS local Supabase stopped");
    } catch (error) {
      failed = true;
      console.error(
        `FAIL local Supabase stop: ${error instanceof Error ? error.message : "unknown error"}`,
      );
    }
  }
}

if (failed) process.exitCode = 1;
