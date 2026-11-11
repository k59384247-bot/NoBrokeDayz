const headers = {
  "cache-control": "no-store",
  "content-type": "application/json; charset=utf-8",
};

function json(status, body) {
  return new Response(JSON.stringify(body), { status, headers });
}

function sameSecret(left, right) {
  if (
    typeof left !== "string" ||
    typeof right !== "string" ||
    left.length !== right.length
  )
    return false;
  let mismatch = 0;
  for (let index = 0; index < left.length; index++)
    mismatch |= left.charCodeAt(index) ^ right.charCodeAt(index);
  return mismatch === 0;
}

export function createAssignmentReminderRunnerHandler({
  mode,
  runnerSecret,
  runBatch,
}) {
  if (typeof runBatch !== "function")
    throw new Error("assignment reminder runner is not configured");
  if (
    mode === "enabled" &&
    (typeof runnerSecret !== "string" || runnerSecret.length < 32)
  )
    throw new Error("assignment reminder runner secret is not configured");
  return async (request) => {
    if (mode !== "enabled") return json(404, { error: "not_found" });
    if (request.method !== "POST")
      return json(405, { error: "method_not_allowed" });
    const token =
      request.headers
        .get("authorization")
        ?.match(/^Bearer\s+([^\s]+)$/i)?.[1] ?? "";
    if (!sameSecret(token, runnerSecret))
      return json(401, { error: "runner_authentication_required" });
    if ((await request.text().catch(() => "invalid")) !== "")
      return json(400, { error: "invalid_request" });
    try {
      return json(200, { result: await runBatch() });
    } catch {
      return json(503, { error: "assignment_reminder_runner_unavailable" });
    }
  };
}
