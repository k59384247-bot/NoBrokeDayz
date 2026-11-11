import { createAssignmentReminderRunnerHandler } from "../_shared/assignment-reminder-runner-http.mjs";

const mode = Deno.env.get("NBD_ASSIGNMENT_REMINDER_MODE") ?? "disabled";
if (!new Set(["disabled", "enabled"]).has(mode))
  throw new Error("unsupported assignment reminder mode");
const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const runnerSecret =
  Deno.env.get("NBD_ASSIGNMENT_REMINDER_RUNNER_SECRET") ?? "";
if (mode === "enabled" && (!supabaseUrl || !serviceRoleKey))
  throw new Error("assignment reminder runner server configuration missing");

const baseUrl = supabaseUrl ? new URL(supabaseUrl).origin : "";
const serverHeaders = {
  apikey: serviceRoleKey,
  authorization: `Bearer ${serviceRoleKey}`,
  "content-type": "application/json",
};

async function rpc<T>(
  name: string,
  values: Record<string, unknown>,
): Promise<T> {
  const response = await fetch(`${baseUrl}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: serverHeaders,
    body: JSON.stringify(values),
  });
  const result = await response.json().catch(() => null);
  if (!response.ok)
    throw new Error(result?.message ?? "assignment_reminder_command_failed");
  return result as T;
}

async function runBatch() {
  let claimed = 0;
  let dispatched = 0;
  let suppressed = 0;
  let retried = 0;
  for (let index = 0; index < 25; index++) {
    const job = await rpc<Record<string, unknown> | null>(
      "server_claim_assignment_reminder_for_runner",
      { p_worker_id: crypto.randomUUID(), p_lease_seconds: 60 },
    );
    if (!job) break;
    claimed++;
    try {
      const result = await rpc<{ status: string }>(
        "server_dispatch_assignment_reminder_for_runner",
        {
          p_reminder_id: job.reminder_id,
          p_lease_token: job.lease_token,
        },
      );
      if (result.status === "dispatched") dispatched++;
      else if (result.status === "suppressed") suppressed++;
    } catch {
      await rpc("server_fail_assignment_reminder_for_runner", {
        p_reminder_id: job.reminder_id,
        p_lease_token: job.lease_token,
        p_safe_error_code: "runner_failure",
      }).catch(() => null);
      retried++;
    }
  }
  return { claimed, dispatched, suppressed, retried };
}

Deno.serve(
  createAssignmentReminderRunnerHandler({ mode, runnerSecret, runBatch }),
);
