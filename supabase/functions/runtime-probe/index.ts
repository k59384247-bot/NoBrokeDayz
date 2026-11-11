// Step 3 infrastructure probe: confirms the local Edge Runtime can serve a function.
Deno.serve(
  () =>
    new Response(JSON.stringify({ ok: true }), {
      headers: {
        "cache-control": "no-store",
        "content-type": "application/json; charset=utf-8",
      },
    }),
);
