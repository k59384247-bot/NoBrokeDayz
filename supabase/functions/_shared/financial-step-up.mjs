const UUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;

export function createFreshPasswordVerifier({
  authUrl,
  anonKey,
  fetchImpl = fetch,
}) {
  if (typeof authUrl !== "string" || typeof anonKey !== "string")
    throw new Error("fresh password verifier is not configured");

  return async (actor, password) => {
    if (
      !actor ||
      !UUID.test(actor.id ?? "") ||
      typeof password !== "string" ||
      password.length < 1 ||
      password.length > 1024
    )
      return false;

    const identifier =
      typeof actor.email === "string" && actor.email.length > 0
        ? { email: actor.email }
        : typeof actor.phone === "string" && actor.phone.length > 0
          ? { phone: actor.phone }
          : null;
    if (!identifier) return false;

    try {
      const response = await fetchImpl(
        `${new URL(authUrl).origin}/auth/v1/token?grant_type=password`,
        {
          method: "POST",
          headers: {
            apikey: anonKey,
            "content-type": "application/json",
          },
          body: JSON.stringify({ ...identifier, password }),
          signal: AbortSignal.timeout(5000),
        },
      );
      if (!response.ok) return false;
      const result = await response.json().catch(() => null);
      return result?.user?.id === actor.id;
    } catch {
      return false;
    }
  };
}

export async function confirmationTokenDigest(token) {
  if (typeof token !== "string" || !/^[0-9a-f]{64}$/.test(token))
    throw new Error("invalid_confirmation_token");
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(token),
  );
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

export function makeConfirmationToken() {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
