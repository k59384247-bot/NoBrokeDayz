export const dynamic = "force-dynamic";

export async function GET() {
  return new Response(null, {
    headers: {
      "Cache-Control": "private, no-store, max-age=0",
      "Set-Cookie":
        "nbd_probe=from-worker; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=120",
    },
  });
}
