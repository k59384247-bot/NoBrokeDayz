# Runtime compatibility — Phase 1 Step 2

Checked: 29 October 2026. Scope: a local deployment probe only; this is not an application feature or a hosted deployment.

## Decision

Use vinext with React/TypeScript and the Cloudflare Vite plugin on Workers. Cloudflare's current Next.js guide recommends vinext for new Workers applications. The guide labels vinext beta; its feature table lists App Router, route handlers and server rendering as supported, while image optimization is partial. Cloudflare's OpenNext guide says to keep OpenNext for existing apps and use vinext for new apps when compatibility allows. The required small probe passed with vinext, so there is no observed compatibility gap that warrants OpenNext at this stage.

The probe covers one App Router page, a server-rendered cookie read, route handlers, a safe health response, a private response policy and a static image. It does not establish compatibility for every Next.js API or future product feature. Recheck vinext compatibility against each later feature before relying on it.

Official references, checked 29 October 2026:

- [Cloudflare Next.js / vinext guide](https://developers.cloudflare.com/workers/framework-guides/web-apps/nextjs/)
- [Cloudflare OpenNext adapter guide](https://developers.cloudflare.com/workers/framework-guides/web-apps/opennext/)
- [Cloudflare Vite plugin](https://developers.cloudflare.com/workers/vite-plugin/) — documents `vite preview` running the build in the local Workers runtime (`workerd`).
- [Cloudflare local development](https://developers.cloudflare.com/workers/local-development/)

## Pinned toolchain

`package-lock.json` is the npm lockfile. Direct dependencies use exact versions; no second package manager or lockfile is present.

| Tool/package | Pinned version | Notes |
| --- | --- | --- |
| Node.js | 22.23.2 | `.nvmrc`; current Node 20 default is below the `cf` CLI requirement. |
| npm | 10.9.8 | Recorded by `packageManager` in `package.json`. |
| `vinext` | 1.4.0 | Next.js API compatibility layer on Vite. |
| `@vinext/cloudflare` | 1.3.0 | Cloudflare image optimizer adapter. |
| `react`, `react-dom`, `react-server-dom-webpack` | 19.3.1 | Matched versions. |
| `vite` | 8.3.5 | Build and preview. |
| `@vitejs/plugin-react` | 6.1.2 | React integration. |
| `@vitejs/plugin-rsc` | 0.5.38 | React Server Components integration. |
| `@cloudflare/vite-plugin` | 2.0.0-beta.v.7 | Beta release selected by Cloudflare's current vinext scaffolder. |
| `cf` | 1.0.0-beta.25 | Cloudflare configuration/type-generation CLI. |
| `typescript` | 7.0.2 | Type check. |
| `oxlint` | 1.90.0 | Lint. |

Cloudflare C3 `create-cloudflare@2.74.4` generated the initial official vinext/Workers template, which was reduced to this probe. Its delegated `create-vinext-app` version was 1.1.0. C3 is not a project dependency. The C3 setup flow itself requires Node 22; Node 22.23.2 was already installed, so no runtime was installed globally.

The lockfile pins `fflate` to patched version 0.7.5 through a narrow npm override because the initially resolved 0.7.3 was reported by npm as vulnerable to malformed ZIP64 input. `npm audit` after the override reported 0 vulnerabilities.

## Commands

From the project root, switch to the pinned Node version, install the locked dependency graph, and use these commands:

```sh
source ~/.nvm/nvm.sh
nvm use
npm ci
npm run dev
npm run typecheck
npm run lint
npm run build
npm run preview
npm run check:runtime
```

`typecheck` generates `.cloudflare/types/index.d.ts` using `cf workers types`, then runs `tsc --noEmit`. `check:runtime` builds and starts `vite preview` on `127.0.0.1:8787`, then runs the built-in Node HTTP assertions in `scripts/check-runtime.mjs`. The Cloudflare Vite plugin runs that preview in local `workerd`; it is not only the framework dev server. No remote binding, account, secret, or deploy command is used.

## Observed checks

| Check | Result |
| --- | --- |
| Clean install from npm lockfile | Pass: `npm ci --cache /private/tmp/nbd-npm-cache --no-audit --no-fund`. |
| Local development start | Pass: `npm run dev -- --port 8788`; `/health` and `/runtime-probe` responded on loopback. |
| Type generation and TypeScript | Pass: `.cloudflare/types/index.d.ts` generated and `tsc --noEmit` exited 0. |
| Lint | Pass: `npm run lint`. |
| Production build | Pass: `vite build` completed and emitted the routes. |
| Workers-compatible runtime preview | Pass: `npm run check:runtime` built the project and all six HTTP assertions passed. |
| Dependency audit | Pass: `npm audit --json --cache /private/tmp/nbd-npm-cache` reported zero vulnerabilities after the `fflate` override. |

The runtime assertions verify:

- `/health` returns only `{ "status": "ok" }` with `Cache-Control: no-store`.
- `/runtime-probe` routes successfully and returns server-rendered marker/time HTML.
- A synthetic `HttpOnly; Secure; SameSite=Lax` cookie is set by a route handler and read by a later server-rendered request.
- The cookie-dependent SSR response carries a private/no-store cache policy; a separate private route also returns `private, no-store`.
- `next/image` emits the expected static asset URL and the SVG is served by the Worker with an image content type.
- An unmatched path returns 404.

## Limits and remaining checks

- The probe uses `next/image` with `unoptimized`. Static image delivery is proven; Cloudflare image transformations, responsive optimization and binding/account behavior are not. Keep this supported static strategy until the image optimization path is separately validated and any account/billing requirement is approved. This matches Cloudflare's documented partial vinext image support.
- The vinext build emits a static-analysis warning that it cannot classify dynamic API use such as `cookies()` and `headers()` automatically. This page declares `dynamic = "force-dynamic"`; the Worker test confirmed cookie-specific output and private cache headers. Keep explicit route behavior and recheck cache headers when adding personalized pages.
- Vite dev emitted React's development-only diagnostic that `eval()` is unavailable in this runtime. The dev health and server-rendered routes worked; stack reconstruction that relies on `eval()` is not available in dev. The built Workers preview has no such runtime failure.
- The build also reports sourcemap warnings from the React Server Components/vinext transform and ineffective dynamic imports in vinext internals. The build and probe pass; source-map fidelity and chunking were not acceptance criteria for this foundation probe.
- Cloudflare's local `workerd` preview proves local runtime behavior, not a hosted `workers.dev` deployment, domain routing, production bindings or account-specific image optimization. Hosted checks remain for the later staging step.
- The active shell default was Node 20.20.2, which is too old for this pinned `cf` CLI. Node 22.23.2 is installed and selected by `.nvmrc`; use `nvm use` before project commands.
- Real payments, identity-document intake, Supabase configuration and all marketplace features remain out of scope and gated by the approved plan.
