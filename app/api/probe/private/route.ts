export const dynamic = "force-dynamic";

export async function GET() {
  return Response.json(
    { private: true },
    { headers: { "Cache-Control": "private, no-store, max-age=0" } },
  );
}
