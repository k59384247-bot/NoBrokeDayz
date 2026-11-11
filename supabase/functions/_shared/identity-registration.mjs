const responseHeaders = {
  "cache-control": "no-store",
  "content-type": "application/json; charset=utf-8",
};

function json(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: responseHeaders,
  });
}

function validRegistrationInput(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const allowedKeys = new Set([
    "account_type",
    "age_confirmed",
    "age_policy_version",
  ]);
  if (Object.keys(value).some((key) => !allowedKeys.has(key))) return false;
  return (
    ["student", "partner"].includes(value.account_type) &&
    value.age_confirmed === true &&
    typeof value.age_policy_version === "string" &&
    value.age_policy_version.trim().length >= 1 &&
    value.age_policy_version.length <= 40
  );
}

export function createIdentityRegistrationHandler({
  supabaseUrl,
  anonKey,
  serviceRoleKey,
  fetchImpl = fetch,
}) {
  const baseUrl = new URL(supabaseUrl).origin;
  if (!anonKey || !serviceRoleKey)
    throw new Error("identity server configuration missing");

  return async function identityRegister(request) {
    if (request.method !== "POST")
      return json(405, { error: "method_not_allowed" });

    const authorization = request.headers.get("authorization") ?? "";
    const bearer = authorization.match(/^Bearer\s+([^\s]+)$/i)?.[1];
    if (!bearer) return json(401, { error: "authentication_required" });

    let rawBody;
    try {
      rawBody = await request.text();
    } catch {
      return json(400, { error: "invalid_request" });
    }
    if (new TextEncoder().encode(rawBody).byteLength > 2048) {
      return json(413, { error: "request_too_large" });
    }

    let input;
    try {
      input = JSON.parse(rawBody);
    } catch {
      return json(400, { error: "invalid_request" });
    }
    if (!validRegistrationInput(input))
      return json(400, { error: "invalid_request" });

    let authResponse;
    let authUser;
    try {
      authResponse = await fetchImpl(`${baseUrl}/auth/v1/user`, {
        headers: { apikey: anonKey, authorization: `Bearer ${bearer}` },
      });
      if (authResponse.status === 401 || authResponse.status === 403) {
        return json(401, { error: "authentication_required" });
      }
      if (!authResponse.ok) return json(503, { error: "identity_unavailable" });
      authUser = await authResponse.json();
    } catch {
      return json(503, { error: "identity_unavailable" });
    }

    if (
      typeof authUser?.id !== "string" ||
      !/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(authUser.id)
    ) {
      return json(401, { error: "authentication_required" });
    }

    try {
      const rpcResponse = await fetchImpl(
        `${baseUrl}/rest/v1/rpc/server_register_identity_for_actor`,
        {
          method: "POST",
          headers: {
            apikey: serviceRoleKey,
            authorization: `Bearer ${serviceRoleKey}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            p_actor: authUser.id,
            p_account_type: input.account_type,
            p_age_confirmed: input.age_confirmed,
            p_age_policy_version: input.age_policy_version,
          }),
        },
      );
      const result = await rpcResponse.json().catch(() => null);
      if (!rpcResponse.ok) {
        if (result?.code === "23514")
          return json(409, { error: "account_type_immutable" });
        if (result?.code === "22023")
          return json(400, { error: "invalid_request" });
        return json(503, { error: "identity_unavailable" });
      }
      return json(200, result);
    } catch {
      return json(503, { error: "identity_unavailable" });
    }
  };
}
