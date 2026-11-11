# Environment boundaries

Step 3 establishes local development configuration only. The local CLI is pinned as an exact npm development dependency (`supabase@2.122.0`) in `package-lock.json`; `supabase/supabase.lock` pins resolved service versions and artifact digests, and the start command uses `--frozen` to prevent silent lock updates. The tested workstation uses Node `v22.23.2`, npm `10.9.8`, and Docker Desktop/Engine `29.7.2` on Apple silicon/macOS `26.7.1`.

## Local

- Use `npm run supabase:start`, `npm run supabase:status`, and `npm run supabase:stop` from the repository root. They select Supabase's native runtime and keep its state, cache, and local database under ignored `.supabase-home/`.
- Docker was available, but its API and database listeners were bound to wildcard host addresses even after following Supabase's documented custom-network loopback configuration. Because the local-only requirement was not met on Docker Desktop `29.7.2`, this project uses the official macOS Apple-silicon native runtime instead. This runtime and the required `[experimental] stack` CLI mode are experimental; CLI flags/behavior may change. Docker stack data created during the binding test was stopped without reset and retained in Docker volumes; it is separate from the native stack.
- The native runtime's managed Functions capability timed out its HTTP readiness check. Starting the stack with `--exclude functions` succeeds; the pinned CLI's documented `supabase functions serve runtime-probe` command then serves the JWT-protected local probe successfully through the local API. Use `npm run supabase:start` in one terminal and `npm run supabase:functions` in another. This records a working local Edge Function development path while keeping the managed native Functions capability limitation explicit.
- Native service ports are assigned by the CLI and remain stable for this local stack. Get current URLs/keys from `npm run supabase:status`; do not assume ports from another machine or environment. The local stack must not be exposed to public or untrusted networks.
- `supabase/config.toml` is committed local service configuration. It is not linked to a hosted project. `supabase/.temp/` and `supabase/.branches/` are ignored by the generated `supabase/.gitignore`.
- Copy `.env.example` to `.env.local` only when application code begins consuming these variables. Replace placeholders with the local values shown by `npm run supabase:status`; do not copy secret values into documentation, commits, browser code or logs.
- `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` are the only browser-exposed Supabase values. The publishable key is intentionally public and still subject to database grants/RLS. `SUPABASE_URL` is the server-side endpoint. `SUPABASE_SECRET_KEY` is an administrative credential and server-only. `SUPABASE_DB_URL` contains database credentials and is server/tooling-only.
- Supabase local email is captured by its local mail viewer; it is not a production mail-delivery check. Local test data must be synthetic.

### Step 3 verification (29 October 2026)

- `npm run supabase:start` completed with `Stack is ready` after a normal stop/restart.
- `npm run supabase:status` reported the native runtime ready. Ten advertised service ports were checked with `lsof`; every listener used `127.0.0.1`.
- `supabase db query --local 'select 1 as local_probe'` returned `1` from the local database.
- Local Auth health, Storage status and the JWT-protected `runtime-probe` Edge Function each returned HTTP 200. The function returned `{ "ok": true }`.
- `npm run supabase:stop` stopped the local stack without resetting its data; a subsequent `npm run supabase:start` succeeded.
- The standalone Edge Runtime printed `CPU timer: not enabled (need Linux)` on macOS. The HTTP function request passed; Linux-specific CPU-time enforcement is not proven by this local runtime.
- The first native start tried the managed Functions capability and failed its readiness check. The repeatable workflow excludes that capability and serves local functions with the CLI's `functions serve` command. Supabase's native/stack mode is experimental.
- The first Docker attempt served the API but Docker Desktop's host port proxy listened on wildcard addresses, despite the documented loopback-bound network option. The Docker stack was stopped normally, not reset; its volumes were retained. No Docker containers remain running from that attempt.

## Staging

**Deferred by the user on 30 October 2026.** No staging project or Cloudflare deployment has been identified, linked, provisioned or deployed. Do not treat a project as staging based on its name. If this step is resumed, first confirm its project identity and nonproduction purpose, preserve existing data, and record safe identifiers here without credentials. Store publishable URL/key only in the appropriate deployment's public configuration, and administrative/database/provider/signing secrets only in approved server-side secret storage. Never reuse production credentials for staging. All hosted routing, cookie, asset, cache, health, permission and timing checks are pending.

## Production

No production project has been identified or linked. Production remains separate and untouched. Configure public URL/publishable key only in the browser build environment. Keep database credentials, Supabase secret/service-role keys, payment-provider credentials and signing secrets in server-side secret storage. Real-money movement and real identity-document intake remain gated by the approved launch requirements. No hosted service was provisioned or modified for Phase 1 closeout.

## Hosted project inspection

The connected Supabase project-list operation was unavailable in this session, so existing hosted projects could not be inspected. No hosted project was linked, reset, modified or treated as disposable. Before staging or production work, identify the intended project and environment through authorized access.
