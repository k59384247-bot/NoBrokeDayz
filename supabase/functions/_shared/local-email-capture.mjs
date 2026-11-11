const UUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;

export function createLocalEmailCaptureAdapter({ url, token }) {
  const endpoint = new URL(url);
  if (
    endpoint.protocol !== "http:" ||
    endpoint.hostname !== "127.0.0.1" ||
    endpoint.username ||
    endpoint.password ||
    typeof token !== "string" ||
    token.length < 32
  )
    throw new Error("local email capture must use authenticated loopback HTTP");
  return {
    async lookup(deliveryId) {
      if (!UUID.test(deliveryId ?? "")) throw new Error("invalid_delivery_id");
      const response = await fetch(
        new URL(`/deliver/${deliveryId}`, endpoint),
        { headers: { authorization: `Bearer ${token}` } },
      );
      if (response.status === 404) return { status: "absent" };
      if (!response.ok) return { status: "unknown" };
      const result = await response.json().catch(() => null);
      if (!UUID.test(result?.capture_id ?? "")) return { status: "unknown" };
      return { status: "found", captureId: result.capture_id };
    },
    async send(message) {
      const response = await fetch(new URL("/deliver", endpoint), {
        method: "POST",
        headers: {
          authorization: `Bearer ${token}`,
          "content-type": "application/json",
        },
        body: JSON.stringify(message),
      });
      if (response.ok) {
        const result = await response.json().catch(() => null);
        return UUID.test(result?.capture_id ?? "")
          ? { status: "accepted", captureId: result.capture_id }
          : { status: "unknown" };
      }
      return response.status === 400 || response.status === 409
        ? { status: "permanent_failure" }
        : { status: "unknown" };
    },
  };
}
