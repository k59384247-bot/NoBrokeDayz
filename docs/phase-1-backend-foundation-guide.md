# No Broke Dayz — Phase 1: backend and infrastructure foundation

Prepared: 29 October 2026. Project: `/Users/mac/Desktop/NoBrokeDayz`.

The specification is approved. This guide supplies instructions for your coding agent; it contains no application code. Run one step at a time, review the result, then give the next prompt. Stop after this phase and return with the evidence before proceeding to Phase 2.

## Goal and boundaries

Finish with a reproducible development environment, versioned database setup, access-control checks, automated repository checks and a small staging deployment proving the chosen runtime works. The backend should be ready for identity/verification implementation in Phase 2.

The designer can work in parallel. No polished screens, complete marketplace schema, verification feature, checkout, ledger, disputes or live integrations belong in this phase. A minimal deployment probe and automated test clients are infrastructure tools, not production frontend work.

The Bachs refund limitations remain tracked. They do not prevent this foundation work; they must be resolved before freezing affected payment integration contracts. Keep all fixtures synthetic, real money disabled and real identity-document collection unavailable.

## How to use the prompts

Open the actual project folder in your coding agent. Keep the three supplied PDFs accessible. The root specification is authoritative for the approved plan; the source PRD and technical document retain their product/engineering authority. The provider reference records newer evidence and explicit unresolved compatibility issues.

Ask the agent to explain any user-only account or tool setup step when it reaches it. Do not paste credentials into chat, planning records or screenshots. If a check fails, give the agent its redacted error and have it repair that step before continuing.

## Step 1 — establish repository instructions and source documents

**Files/folders to create or update**

- `README.md`: project purpose, phase status and eventual setup/check instructions.
- `AGENTS.md`: approved development rules and links to canonical documents.
- `.gitignore`: local secrets, generated build output, dependencies and local service state.
- `docs/product.md` and `docs/technical.md`: full, checked transcriptions of the supplied v2 PDFs, with source provenance.
- Existing `spec.md`, `docs/decisions.md`, `docs/launch-gates.md` and `docs/bachs-payments-reference.md`: retain and link.

**Prompt**

> Work in /Users/mac/Desktop/NoBrokeDayz. Implement only Step 1 of the Phase 1 backend foundation guide. First inspect existing files and any applicable agent instructions; preserve the approved root spec.md and planning records. Read the supplied v2 PRD and technical PDF, plus docs/bachs-payments-reference.md. Create full canonical docs/product.md and docs/technical.md from the PDFs, checking tables, acceptance bullets, formulas and state names; label these as transcriptions, not missing original Markdown files. Keep newer provider findings in the separate evidence note rather than silently rewriting the source baseline. Create concise README.md, AGENTS.md and .gitignore. AGENTS.md must require backend-first delivery, mobile-first later UI, page files at most 300 lines, narrow permissions, migrations as schema authority, integer-kobo internal money, exact poster funding, platform-funded provider costs, immutable journals, no timer-authorized money movement, independent admin approvals and tests for risky rules. Record that backend runtime/adapter versions must be verified and pinned, and that real money and identity intake remain gated. Initialize Git only if this folder is not already a repository. Do not create a remote repository, push, install dependencies or implement features in this step. Report what changed and how you verified source completeness.

**Expected result:** a documented repository with the approved rules intact. There is still no running application.

**Check:** canonical documents preserve F1–F12, per-worker pricing, role restrictions and appeal/cancellation rules. No original PDF content is confused with instructions to execute. No secrets are tracked.

**Debug:** if extraction loses tables, compare the rendered PDF pages and repair the transcription. If a repository already exists, preserve its history and unrelated changes. If agent rules disagree with the approved specification, surface the conflict and keep the user-approved requirement.

## Step 2 — select and prove the smallest compatible runtime

**Files/folders to create or update**

- `package.json`, one package-manager lockfile, TypeScript configuration and required build/lint configuration.
- Framework/runtime configuration and the appropriate Cloudflare configuration file.
- Minimal `src/app/` deployment probe and health route; minimal clients in `src/lib/` only if needed for the proof.
- `docs/runtime-compatibility.md`: exact versions, official references and observed checks.

**Prompt**

> Implement only Phase 1 Step 2. Inspect installed tooling before asking me to install anything. Keep the approved Next.js-compatible React/TypeScript and Cloudflare Workers architecture. Check current official Cloudflare documentation: assess the recommended vinext path first and use the documented OpenNext compatibility path only if the required compatibility proof warrants it. Record why, pin the tested versions and use one package manager/lockfile consistently. Create the smallest deployment probe needed to test routing, server rendering, cookie handling, static assets, image handling and private-response caching in the Workers-compatible runtime. Treat this as test infrastructure, not product UI. Keep the health response free of secrets, detailed internal versions and user data. Establish repeatable local start, type-check, lint, build and runtime-preview commands. Test the actual Workers-compatible preview, not only the framework dev server. Record unsupported behaviour and repair or resolve it before calling the runtime proven. Do not add marketplace features, backend financial routes, speculative dependencies or a design system. Report exact commands, results and remaining hosted checks.

**Expected result:** local build and Workers-compatible preview run; a simple probe responds. There is no dashboard, marketplace or product feature to evaluate yet.

**Check:** versions and compatibility results are recorded. Cookie/private-response checks prove intended behaviour without a real user session or financial action. The image check is a compatibility result, not a reason to purchase an image service automatically.

**Debug:** if ordinary local development succeeds but the Workers preview fails, inspect runtime compatibility and unsupported Node dependencies. Use current official adapter guidance rather than adding another application server. If an image feature requires an unavailable binding or paid service, record the restriction and use an approved supported strategy before claiming compatibility.

## Step 3 — start local Supabase and separate configuration

**Files/folders to create or update**

- `supabase/config.toml` and appropriate ignored local service state.
- `.env.example`: variable names and safe placeholders only.
- Ignored local configuration for development; hosted secrets configured separately later.
- `docs/environments.md`: local/staging/production map and safe ownership references.
- `README.md`: exact prerequisites and repeatable setup commands.

**Prompt**

> Implement only Phase 1 Step 3. Inspect whether a supported container runtime, Supabase CLI and required language runtime are already installed. Use the official local Supabase workflow with pinned/reproducible tooling. If a user-only prerequisite is missing, give me the precise installation/start step and continue independent documentation work; do not replace Supabase with another backend. Initialize and start the local stack, bind development services to the local machine appropriately and verify database/auth/storage/Edge Function development access needed by the plan. Define separate local, staging and production configuration. Public browser configuration must contain only intended publishable values; database credentials, administrative keys, provider secrets and signing secrets remain server-only. Create .env.example with placeholders and document each variable's purpose/location without exposing values. Inspect whether hosted projects already exist only through authorized access; do not assume a Supabase project I created is disposable or automatically production/staging. Do not link, reset or modify a hosted database in this step. Demonstrate local startup and safe shutdown/restart, and report missing prerequisites honestly.

**Expected result:** a local Supabase development stack runs independently of any hosted database. Local fixtures can be disposable without risking a remote project.

**Check:** identify the exact local host/project before running any reset. Staging and production keys are absent from the browser bundle and local example file. Local signup/email testing does not imply Zoho or Africa's Talking delivery works.

**Debug:** for connection errors, check whether the container runtime is running and the configured ports conflict with another project. For environment errors, report the missing variable name rather than printing secrets. Do not disable permissions or borrow production credentials to make a local check pass.

## Step 4 — establish migrations, permissions and database checks

**Files/folders to create or update**

- `supabase/migrations/`: timestamped foundational schema/grant changes.
- `supabase/seed.sql`: minimal synthetic reference data only, where the foundation needs it.
- `supabase/tests/`: foundation grant/RLS and migration checks.
- `src/lib/database.types.ts` or one documented equivalent generated-type location.
- `docs/data-and-permissions.md`: schema boundaries and planned role/command matrix.

**Prompt**

> Implement only Phase 1 Step 4. Establish SQL migrations as the schema source of truth and a minimal backend security foundation for the approved product. Define private/unexposed schema boundaries and explicit least-privilege grants for application-owned objects. For exposed application tables, enable RLS explicitly in migrations, even if the hosted automatic-RLS setting is enabled. A dashboard checkbox is not a substitute for reproducible policies/grants. Leave newly created tables unexposed until their specific client access is intentionally granted; do not disable the whole Data API because the approved architecture uses it. Limit this phase to necessary foundation/reference objects, not the complete marketplace, identity feature or money schema. Do not modify Supabase-managed Auth/Storage internals to apply blanket policies. Document planned anonymous/unverified/student/partner/suspended/unrelated/staff access, separating current tested foundation rules from future rules. Add meaningful allow/deny tests for objects actually created, using client roles rather than a privileged owner that bypasses RLS. Prove local clean rebuild and repeatability with synthetic seed data, then generate database types. Test-only fixtures must remain isolated. Report what is enforced now and what is deferred to Phase 2.

**Expected result:** the same local database can be rebuilt from committed migrations. Unauthorized access to the foundation objects is denied; types reflect the actual schema.

**Check:** test output demonstrates denial, not merely successful privileged access. Permission checks match grants as well as RLS. Nothing grants a student status or creates spendable balances prematurely.

**Debug:** if a table has permission errors, inspect its intended grants and policies rather than disabling RLS. If reads return no rows, test the intended role and ownership/verification conditions. If a reset targets a hosted database, stop and confirm the environment before proceeding. Capture schema drift before modifying remote history.

## Step 5 — automate repository checks and failure reporting

**Files/folders to create or update**

- `.github/workflows/ci.yml` and necessary project check scripts/configuration.
- `tests/integration/`: small runtime/environment checks with observable value.
- `docs/runbook.md`: startup, common foundation failures and health-check interpretation.
- `docs/phase-1-evidence.md`: actual check results, versions and unresolved issues.

**Prompt**

> Implement only Phase 1 Step 5. Make the local foundation checks reproducible and encode them in CI: lockfile install, formatting/type/lint, build, relevant runtime checks and local database migration/permission tests. Required checks must fail when their test fails and must not silently pass by skipping unavailable database services. Keep ordinary pull-request validation free of production secrets. Configure safe error reporting and correlation IDs where the foundation actually needs them; do not install a large observability platform speculatively. Health output must not expose credentials, connection strings or private records. Keep tests focused on observable runtime/security behaviour rather than implementation details or arbitrary coverage percentages. Verify checks locally and include one controlled negative check showing an intended failure is detected. Record that a workflow file/local run is not evidence of a hosted CI run; if no remote exists, mark hosted CI execution pending rather than creating/pushing a remote without my instruction.

**Expected result:** repeatable checks catch foundation failures and provide readable diagnostics. Hosted CI status is reported accurately.

**Check:** no required check is an empty placeholder; dependencies are pinned; a broken permission/build cannot be presented as green. Redact diagnostic secrets.

**Debug:** fix the actual failing check rather than suppressing it. If local and CI differ, compare runtime/CLI versions, service readiness and environment-variable names. Avoid retries that hide deterministic failures.

## Step 6 — verify isolated staging and record a baseline

**Files/folders to create or update**

- Environment-specific deployment configuration and documented scripts.
- `docs/environments.md`, `docs/runtime-compatibility.md` and `docs/phase-1-evidence.md`.
- `docs/runbook.md`: staging deploy/rollback and diagnostic steps.

**Prompt**

> Implement only Phase 1 Step 6. Use an explicitly identified nonproduction Cloudflare deployment and isolated Supabase staging project. Confirm actual project IDs/purpose before linking or deploying; preserve any existing data. If accounts, access, a remote repository or budget authorization are missing, complete local work and document the exact hosted step still blocked. Do not create paid subscriptions or use a production project as staging. Deploy only the minimal runtime/health probe; apply reviewed foundation migrations to the approved staging target through the documented workflow. Keep staging secrets server-side, previews on staging and production untouched. Verify hosted routing, cookie behaviour, assets, safe cache headers, health and intended permission denial. Record request timings and failures with timestamp, build, client location/network conditions and environment. Label these as foundation baselines, not feed/chat/mobile performance acceptance. List later Nigerian region-comparison/load work. Document rollback for the probe and the separate migration recovery procedure. Do not implement payments or claim the Bachs refund gap is resolved.

**Expected result:** a minimal nonproduction deployment works and its environment boundaries are proven. If external setup is unavailable, the phase is locally verified with explicit hosted checks pending; it is not fully complete.

**Check:** evidence records exact staging identifiers without credentials, observed results and pending tests. Health latency alone does not establish the product's feed, chat or mobile-page targets. No test performed against production counts as staging evidence.

**Debug:** if a deployment succeeds but requests fail, check build/runtime logs, bindings and configuration. If hosted DB access differs from local, compare migrations, grants, policies and environment selection. Preserve stable history; never use a remote reset as a routine fix.

## Step 7 — document the milestone and finish the phase

**Files/folders to update**

- `docs/phase-1-evidence.md` and `README.md`.
- `docs/development-log.md`, `docs/community-feedback.md`, `docs/decisions.md` and `docs/launch-gates.md` as needed.

**What to document for the role brief**

1. Capture a safe screenshot of completed checks and, when available, the synthetic staging health/probe result. Show no environment files, secrets, private dashboard data or account identifiers.
2. Write a plain-language note: the development foundation now has repeatable setup and automated checks; users cannot yet post jobs or receive payment.
3. Record one actual obstacle, its cause and how it was resolved. Reference check evidence privately.
4. Prepare one brief weekly update and one or two genuine content opportunities for Community and Growth review. Possible themes: why permission tests matter; why payment success and bank payout are separate. Label unbuilt product behaviour as planned.
5. Ask a useful feedback question only if needed, such as what students expect a verification-status explanation to tell them. Record real feedback when received; do not fabricate answers.

**Prompt**

> Close Phase 1 only. Review every step against its actual evidence and update docs/phase-1-evidence.md with pass/fail/blocked status, exact checks, runtime versions, safe environment references and remaining work. Update setup/runbook documentation so another developer can reproduce local startup and checks. Prepare the milestone note and brief weekly update with one or two content opportunities, clearly separating working infrastructure from planned product features. Include safe capture instructions; do not send or publish the packet. Keep Bachs refund/holding and other live gates visible. Report what works, how it was tested and what remains blocked. Do not begin identity features or advance to Phase 2 automatically.

## What “done” looks like

- Canonical product/technical sources and approved spec remain consistent, with newer provider constraints preserved separately.
- Repository setup is repeatable; secrets and local service state are ignored.
- A pinned Next.js-compatible/Workers runtime passes local and hosted compatibility checks.
- Local Supabase starts, rebuilds from migrations and generates matching types.
- Grants/RLS checks prove the actual foundation's access boundaries.
- Local checks pass; hosted CI passes once a remote is authorized and available.
- An isolated staging probe works; production is untouched.
- Evidence, runbooks and the milestone/weekly packet are complete.
- No production UI, real ID collection or payment integration is claimed complete.

If hosted CI or staging remains blocked, report Phase 1 as partially complete, list the missing access/action and retain passing local evidence. Do not invent a successful deployment or move on silently.

## What to send back here

Send the Phase 1 agent summary and `docs/phase-1-evidence.md`, including failed or blocked checks. A short message can say: “Phase 1 is complete; here are the results,” or “Phase 1 is blocked at Step __; here is the redacted error.” Ask to proceed to Phase 2 only once the phase evidence is ready for review.

## Official setup references

Checked 29 October 2026; recheck when selecting/pinning actual tooling:

- [Cloudflare Next.js guidance](https://developers.cloudflare.com/workers/framework-guides/web-apps/nextjs/) recommends vinext for new Next.js-compatible Workers applications. [OpenNext guidance](https://developers.cloudflare.com/workers/framework-guides/web-apps/opennext/) documents the alternative and its compatibility limits. Selection remains subject to the phase's actual compatibility proof.
- [Supabase local development](https://supabase.com/docs/guides/local-development) describes CLI and local runtime prerequisites. [Local workflow](https://supabase.com/docs/guides/local-development/cli-workflows) distinguishes local and hosted operations. [Migrations](https://supabase.com/docs/guides/local-development/database-migrations) explains reproducible schema changes.
