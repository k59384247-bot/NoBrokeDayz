# Foundation runbook

This runbook covers local development and security probes only. Phase 3 marketplace and money commands use private database records, authenticated Deno Edge routes and a loopback fake provider. The full synthetic path passed locally; nothing here authorizes a hosted deployment, a Bachs connection or real money movement. Phase 1 hosted Step 6 remains deferred.

## Toolchain

Use Node `22.23.2` from `.nvmrc` and npm `10.9.8` from `package.json`. `nvm use` selects Node only in the current terminal:

```sh
source ~/.nvm/nvm.sh
nvm use
npm ci
```

Check `node --version` and `npm --version` after switching; expected output is `v22.23.2` and `10.9.8`.

The formatter, type checker, linter and build run with:

```sh
npm run format
npm run format:check
npm run typecheck
npm run lint
npm run build
npm run check:runtime
npm run check:database
npm run check:identity
```

`check:runtime` builds and tests the built Workers-compatible preview on `127.0.0.1:8787`. It checks the health response, routing, server rendering, synthetic cookie handling, private cache headers, static image delivery and 404 handling. It does not deploy.

The root TypeScript check covers the app and Workers toolchain. Supabase Edge Functions use Deno's separate type environment and are excluded from this Node/Workers TypeScript project; their local runtime serve command is documented in [environments](environments.md).

`npm run typecheck:edge` runs the pinned Deno `2.1.4` CLI from the single npm lockfile against all Edge Function entrypoints. It is separate from Workers TypeScript because Supabase functions use Deno types.

`npm run check:phase2` is the pinned, sequential local closeout command. It runs formatting and linting across app, scripts, tests, libraries and Edge Function sources; Workers and Deno typechecks; identity command boundary tests; Workers runtime build/probe; local Auth, phone, school-email, private Storage, profile/staff/MFA and actual Deno Edge HTTP integrations; then a final migration reset, database permission suite and generated-type comparison. It checks Node `22.23.2` and npm `10.9.8` and redacts credential-like test output. Some component checks intentionally reset this repository's local database; read their sections below before running if local test data must be retained. It never links to or operates on hosted Supabase. The workflow in `.github/workflows/ci.yml` configures future CI, but no hosted CI run has occurred.

`npm run check:phase3` is the pinned Phase 3 local closeout runner. It first proves one controlled financial regression fails and restores the migration, then runs the Phase 1/2 suite, marketplace/payment boundary suites, and the actual local Edge journey. It ends with a clean local migration rebuild, synthetic fixture cleanup, generated-type comparison and stopped services, then writes a safe source manifest. It destroys data in this repository's local Supabase database during its checks. Do not run it when local test data must be retained. It never links to or operates on hosted Supabase.

## Local database permission check

`npm run check:database` starts the pinned native Supabase stack, resets only the local database from committed migrations and synthetic seed data, creates four synthetic Auth users through the local Auth admin API, runs four identity handler tests and pgTAP permission checks, removes and verifies cleanup of those Auth users, compares generated public types, and stops the stack. On 30 October 2026 the Phase 2 Step 2 run passed 75 pgTAP assertions (29 foundation + 46 identity) and four Auth/privileged-RPC handler tests with matching generated types. The identity tests include permitted first review transition, rejection of a second decision, and immutability of submitted content. Handler tests mock the Auth/RPC HTTP boundary to prove the actor comes from Auth `/user` and reject actor/protected fields in request JSON. The local Edge Runtime smoke check loaded the function and returned 401 for an unauthenticated request; a real access token journey remains for the Auth integration step. One fixture carries misleading user metadata to prove own-status reads protected database facts. The local service key is held only in the fixture process and is never printed or written to the repository. A missing service, failed migration, fixture lifecycle, permission test, stale type file or failed stop returns a nonzero exit code. The database check reports a random check ID and redacts credential-like CLI output on errors. On macOS, the native runtime may need user-level cache and loopback permissions; grant only the local access needed if the environment blocks those.

`npm run check:profiles` runs the non-destructive local migration/test path for Steps 2–9, using the same loopback native stack. It creates marked synthetic Auth users through the supported local Auth admin API, bootstraps only synthetic staff grants, applies pending migrations without resetting the database, runs all 319 pgTAP checks plus profile/staff boundary and local Auth/MFA tests, regenerates public client types, restores synthetic reviewer grants, removes marked baseline Auth fixtures and stops the stack. It does not launch the Deno Edge server; use `npm run check:edge-local` for that separate proof.

## Local Auth and recovery check

`npm run check:identity` uses the pinned `@supabase/supabase-js` 2.118.0 client with local Supabase Auth and Mailpit. Like `check:database`, it stops and restarts this repository's native local stack, resets the local database before and after the run, removes captured test emails, verifies that synthetic Auth users were removed, and stops the stack. It does not connect to or reset a hosted project. It intentionally clears data in this project's local database; do not run it when you need to preserve local test data. Local email confirmation is enabled; tests read confirmation and recovery links from Mailpit and follow them through Supabase Auth's `/verify` endpoint. No email leaves the local Mailpit service.

The isolated test stack uses a 60-second access-token lifetime so `auth.getUser(token)` can prove that an expired token is rejected. This is test-only local configuration, not a recommended hosted setting. Passwords and refresh sessions stay in Supabase Auth; there is no application password/session table. Supabase signout revokes the affected refresh token(s) and clears the test client's session, but an already-issued access-token JWT can remain acceptable until its expiry. Sensitive product authorization must use current protected account facts and current Auth/session state where freshness matters.

For confirmed addresses, the local Auth endpoint returns a `user_already_exists` error on duplicate signup. The application message helper maps that to the same generic message as a successful signup; callers must not display raw Auth error text. Invalid-password and unknown-account signin messages are also normalized, and recovery uses a generic response whether or not the address exists. The integration suite tests hostile redirect input against the exact loopback allow-list.

The reset command is explicitly local (`supabase db reset --local --yes`). Do not remove `--local`, link a project, or run a remote reset as a local recovery step. The script does not link or inspect hosted projects. pgTAP rows/tables are transaction-scoped and rolled back; synthetic Auth fixture users are created/deleted by supported local Auth admin requests, with cleanup checked before shutdown.

## Local phone-change check

`npm run check:phone` preserves local data. It reloads the native stack, applies pending migrations, and runs all 319 pgTAP assertions, signed-hook boundary tests and the real Auth phone-change lifecycle. Allow about five minutes plus startup: one assertion waits for Auth's actual 300-second OTP expiry. It also checks the 60-second resend boundary, wrong/reused codes, duplicate and concurrent claims, pending replacement invalidation, delivery failure, and the durable 5/hour and 10/24-hour per-phone send caps under concurrent signed hook requests. The quota table/helper are in `app_private` with no browser grants; only the narrow `public.server_reserve_phone_sms_send_for_actor` RPC has `EXECUTE` for `service_role`. The generated public type exposes its signature for typed calls but does not grant callers permission. The database reservation occurs before delivery, so a failed delivery consumes a quota slot; this is conservative and prevents free retry loops. Temporary marked fixtures and `p2step4-*@identity.test` accounts are cleaned through supported local Auth tooling; the stack stops afterward. The approved five-invalid-attempts-per-phone-change-challenge rule remains unimplemented; see the limitation below.

## Local supplementary school-email check

`npm run check:school-email` resets this repository's local native Supabase database before and after its integration suite. It first requires the pinned local native stack on loopback; it does not link, inspect or contact a hosted project. The reset removes existing data in this local database, so use it only when that local data can be discarded. It reapplies migrations and local seed data, creating the synthetic-only `school.test` allow-list entry. It creates Auth fixtures through the local Auth admin API, runs all 319 pgTAP assertions, six command/delivery boundary tests and the local end-to-end challenge suite, then resets the database to remove test users, school proofs, challenge history and audit events.

The integration test calls the shared school command handler with real local Auth tokens and Postgres RPCs. Its email adapter is a bearer-protected loopback capture at `http://127.0.0.1:54331/deliver`; generated six-digit codes remain in that test process's memory and are erased on close. HMAC and adapter secrets live in ignored, mode-0600 files under `.supabase-home/`. The suite tests exact `.test` matching, wrong-account replay, one-time confirmation, five-attempt lockout, parallel challenge consumption, parallel address ownership, current phone/age/login prerequisites, and suspension. It does not test Deno Edge Runtime serving, Zoho configuration, real mail delivery, actual UNILAG domains or current enrolment. Supabase login confirmation/recovery is a separate flow using the local Auth mail viewer.

## Local verification-file check

`npm run check:verification-files` starts this repository's native local stack and applies migrations without resetting the database. It creates and removes only marked synthetic Auth fixtures, runs all 319 pgTAP assertions (through the current identity/profile migrations), eleven file-command boundary tests and three local Auth/Storage tests, then stops the stack. It preserves unrelated local rows. The Storage tests upload a generated one-pixel PNG to quarantine, confirm anonymous/owner/unrelated reads and direct browser writes fail, and verify the application-signed proxy link expires and returns attachment plus safe headers. They also test account-token substitution and database reviewer denial.

The application upload-access token lasts five minutes and is single-use. It is not a Supabase signed upload URL. Reviewer links use the approved ten-minute application HMAC lifetime and are bearer access during their remaining lifetime; they are not instantly revoked when a grant changes. The local test advances an injected clock to prove expiry without waiting ten minutes. All service uploads stay quarantined because local malware scanning, PDF sanitization and image decoding/re-encoding are unavailable. No production evidence is reviewable yet. See [verification-files.md](verification-files.md) for exact checks and limits.

## Local staff and suspension check

`npm run bootstrap:local-staff` provisions only fixed synthetic `@identity.test` accounts through local Supabase Auth, registers them through their own identity commands, and uses the local database CLI to add audited reviewer/suspension grants. It refuses a non-native or non-loopback project. It does not modify hosted Auth or grant a real person. Passwords and captured TOTP seeds remain in ignored `.supabase-home/step8-staff.json` with mode `0600`.

`npm run check:staff-access` stops and restarts the native local stack to reload TOTP settings, applies migrations without resetting local data, runs all 319 pgTAP tests and the real local Auth TOTP/AAL2 integration, removes only marked baseline fixtures, and stops the stack. Synthetic Step 8 Auth accounts and their MFA factors persist for repeat checks. It checks AAL1 denial, wrong and revoked grants, reviewer assignment scope, direct profile API denial after suspension with the same access token, the surviving own-help route, unsuspension and actual local access-token expiry. This command exercises the shared handler against Auth and PostgREST; actual Deno HTTP is separately tested by `check:edge-local`. See [staff-access.md](staff-access.md).

An existing reviewer download URL remains a bearer credential until its 10-minute expiry. Suspending its owner, revoking a staff grant or signing out does not shorten that already-issued URL lifetime. This is separate from the immediate current-state checks on database and Data API commands.

`npm run cleanup:verification-orphans` requires the local native stack on loopback. It deletes only quarantine objects older than 24 hours that have no evidence row and no active/finalized upload intent. It does not remove metadata or finalized review history; the 24-hour cutoff is for operational orphan cleanup, not legal retention.

The `check:phone` process serves a signed local HTTP Send SMS Hook at `http://127.0.0.1:54330/send-sms`. Supabase generates and validates the OTP; the handler verifies Supabase's hook signature, normalizes the destination and reserves the durable send quota through a narrow server-only database command before delivering to a synthetic-number capture adapter. Challenge codes stay in test-process memory. There is no HTTP endpoint for reading or verifying them. The `check:phone` run proves native Auth-to-loopback-hook delivery. Separately, `check:edge-local` sends Auth-signed synthetic hook events through the actual local Deno `send-sms` route and proves the same database quota denies the sixth concurrent send. This does not claim the hosted Auth hook is configured, real SMS is delivered, or Nigerian carrier/DND delivery works. No SMS provider or Africa's Talking account is connected.

## Local case investigation and evidence

Phase 4 Step 4 uses `case-command` for assigned-reviewer triage/contact/request/fact actions and participant replies, `case-read` for bounded participant or reviewer overview responses, and `case-evidence` for requested uploads and scoped byte downloads. Run `npm run check:marketplace` to apply migrations, exercise the local API gateway and Deno Edge routes, upload synthetic JPEG bytes through the private Storage path, and verify reviewer scope and quarantine denial. This check resets and clears only this repository's local database and stops the stack; it does not contact a hosted project.

Staff contact rows always carry `simulated_manual_log`; they do not prove a real call, email or visit. Two attempts across two channels plus substantive reasoning are required before a non-response assessment; a separate current senior grant and AAL2 are required to sign its exact contact snapshot. No timer, silence or category creates a money outcome.

Case file policy defaults to five files and 5,000,000 bytes each. Type/signature checks do not scan for malware or make files safe. Keep every actual case upload in the private quarantine bucket until a real scanning and safety-review process is implemented. There is no safe-mark command. For a local download-positive check, use only `source_kind='synthetic_test'` metadata and a separate generated synthetic object; this fixture does not show that scanning works. Metadata and byte download are separately scoped and audited, and neither returns a public URL. Do not infer an external refund, provider settlement or legal retention period from a case record.

Do not reintroduce fixed `auth.sms.test_otp` values for the expiry assertion: CLI 2.122.0 ignores the local `test_otp_valid_until` field, leaving Auth's fixture shortcut active indefinitely. Read-only runtime inspection confirmed native Auth receives `GOTRUE_SMS_OTP_EXP=300` and `GOTRUE_SMS_MAX_FREQUENCY=60s`. The durable app send cap is 5 per normalized phone per rolling hour and 10 per rolling 24 hours; it stores a server-keyed HMAC digest, not the phone number, and Auth hook request IDs prevent replay. Supabase's `/auth/v1/verify` throttle is IP-scoped, not the approved five-wrong-attempts-per-challenge rule. Its MFA Verification Hook accepts MFA factor checks, not the `phone_change` OTP verify request, so that rule remains a blocker. The local `token_verifications = 5` is an IP-level five-minute throttle with token-bucket burst behavior. Proposed choices are (a) wait for a Supabase phone-change-specific attempt control, or (b) design an Auth gateway that counts failed `phone_change` verification responses while forwarding OTP generation/validation to Supabase Auth and blocks direct bypass of the upstream endpoint. Option (b) adds substantial deployment and proof requirements and is not implemented. See Supabase's [rate-limit endpoint table](https://supabase.com/docs/guides/auth/rate-limits), [MFA Verification Hook payload](https://supabase.com/docs/guides/auth/auth-hooks/mfa-verification-hook), and [phone-change flow](https://supabase.com/docs/guides/auth/phone-login#updating-a-phone-number). Never assign a confirmed timestamp manually to make a test pass.

## Local case and refund traceability

Use the existing `case-read` Edge route for case status. A participant posts `{"action":"participant_detail","case_id":"<case-uuid>"}`. Both parties receive the published written decision and the current refund status (`authorized`, `queued_for_liquidity`, `processing`, `unknown`, `failed`, `exception`, `settled` or `reversed`) from saved case/refund records. They do not receive reviewer identities, refund operation references or private staff notes.

An assigned reviewer must use an AAL2 session with the current `dispute_review` grant and posts `{"action":"reviewer_detail","case_id":"<case-uuid>"}`. This response remains available to that reviewer after case closure. `traceability.decision` shows the proposer and each approval actor with timestamps. `traceability.finalization` shows who executed the outcome and when. For a refund, `traceability.finalization.refund.operation_reference` is the stable simulated provider reference once the existing runner creates the refund operation; `provider_refund_reference` is populated only after simulated settlement. Before an operation exists, these references are null while the payable remains authorized or queued. Provider settlement is not confirmation that a bank credited the poster.

`financial_inspect` remains a separate read-only grant. It cannot read a case through `case-read`, and it cannot propose, approve, finalize or release a case hold. To independently trace an operation, use `/functions/v1/ops-financial-inspection` with an AAL2 financial inspector and `{"action":"trace","reference_type":"operation","reference_id":"<operation-uuid>"}`. The reviewer view and finance inspection refer to the same saved operation and audit records.

For Phase 5 Step 4 email exceptions, an active AAL2 staff account with the separate `notification_delivery_review` grant may call `/functions/v1/ops-notification-delivery` with `{"action":"list"}` and continue with the returned cursor. It shows only delivery ID, recipient ID, notice type, status, attempt count and safe error code for unknown, exhausted and permanent-failure rows. It does not show email addresses or message content and does not resend messages. No grant is provisioned by migration and no production screen exists yet. The local loopback capture is not proof of real mailbox delivery.

Phase 5 Step 5 uses `assignment-reminder-runner` for due reminder work. A committed submission creates private due records for 24 and 48 hours (poster) and 72 hours (worker). The runner creates only an in-app notice and its transactional-email intent. It does not send SMS or email, create a case, or call a financial command. Its mode defaults to `disabled`; when enabled it requires a separate server-only bearer secret and accepts only an empty POST. Invoke it on a short internal schedule; the local implementation does not install a hosted cron job. After downtime, it dispatches only the latest due stage once. The database uses server time and has no public timestamp override.

Phase 5 Step 6 reviews are available only after ordinary completion or a finalized positive worker award, with all cases and appeals closed. Each party may save one immutable 1–5 review; optional text is limited to 500 characters, whitespace is normalized, and URLs are rejected. Reviews publish on submission. A user who can view a review may report it through `marketplace-command` (`report_review`). A separate `review-moderation` route lists reported reviews or hides one; the database requires an active human account, a current `review_moderate` grant and AAL2 for every command. Reports do not hide automatically. Hiding appends an audited record and removes that review from public text, average and count while leaving the original and its one-review slot intact. No real moderator grant or admin screen is provisioned. If a projection needs a repair, run `select app_private.rebuild_profile_reputation_projections();` through the local database-owner CLI after reviewing the mismatch; the function rebuilds from finalized assignment and immutable review records. Profile commands cannot set the projections directly.

The reminder worker rechecks assignment state at its database dispatch boundary. Confirmation, cancellation or dispute suppresses pending stages. A no-action case restarts the sequence only when finalization restores the submitted state. The email consumer checks eligibility again immediately before its send call. A committed in-app notice or an email request already in flight cannot be recalled. No live email or SMS was used for this step.

Run `npm run check:marketplace` under Node 22.23.2 for the synthetic journey. **It resets and clears this repository's local Supabase database.** Use it only when that local data is disposable. The Step 9 scenario creates a separate synthetic dispute, confirms the stored 72-hour notice interval, uses only the postgres-only historical-time helper to pass the appeal window without waiting three real days, and performs participant/reviewer/finance reads through local Edge HTTP. Both parties are checked at authorized, unknown, processing and settled refund stages; one saved operation/reference is retained throughout. The reviewer is also checked at AAL1, outside the case assignment and after revoking the current read grant. Private staff notes must never appear in participant responses.

The script prints `TRACE Step 9 synthetic example` with the case ID, assignment ID, decision version, execution time, refund operation ID and simulated provider reference. Those are synthetic identifiers, not credentials. The automatic checks use them in the requests above before cleanup. Each run creates new IDs; after cleanup they are retained evidence only and cannot be queried against the cleared database. For manual inspection in the local debugger, pause after the successful settled reviewer/finance reads and before the `revoke synthetic assigned-reviewer read grant` call. The case and refund IDs are in `traceCaseId` and `settledRefundTrace.operation_id`; use the authenticated requests above while the fixture exists. The test then revokes its reviewer's grant and verifies denial before printing the trace line and cleaning up. Keep that denial in place.

The [Phase 4 Step 10 command-to-evidence matrix](phase-4-step-10-acceptance.md) maps each exposed case, cancellation, refund and inspection command to its SQL, handler and local Edge HTTP evidence, including the success and denial paths.

### Secret-free local replay and inspection

From the repository root, use Node `22.23.2` and run `npm run check:marketplace` for the focused synthetic case/refund journey, or `npm run check:phase4` for the full sequential suite. Both use only the native loopback Supabase project and the fake provider. They reset local data and clean marked fixtures; `check:marketplace` also stops its local stack. Run them only when that local database can be cleared. No API token, password, OTP, provider key or bank detail needs to be copied into this runbook or a command line.

The focused journey creates separate Auth-issued worker, poster, assigned reviewer, independent approver, appeal reviewer and finance-inspector identities. It sends actual requests through local Deno Edge HTTP. The assertions check both parties' case status and written decision; the stored 72-hour deadline; the reviewer-only decision hash, approval actors and finalizer; the unknown-to-processing-to-settled refund trace; and denial for unrelated parties/reviewers, AAL1, wrong scope and a revoked grant. The participant response excludes private staff notes and reviewer trace fields. The test uses the server-created deadline; its isolated postgres-only historical-time fixture exists only to cross the wait in test code and is not exposed as an Edge command.

To inspect a live synthetic row instead of only reading the assertions, run `node --inspect-brk scripts/check-marketplace-local.mjs` from the repository root and attach the IDE's Node debugger. Set breakpoints at `const initialAppeal = participantCaseAfterDecision.body.data.appeal;`, `const refundTrace = traceDuringRefund.body.data.traceability.finalization.refund;`, and the later checkpoint verification after `const laterCheckpoint = JSON.parse(...)` in `scripts/check-marketplace-local.mjs`. At the appeal breakpoint, `initialAppeal.durable_notified_at` and `initialAppeal.appeal_deadline_at` are the party-visible timestamps. At the refund breakpoint, `refundTrace.status` is `unknown`; its `operation_id` and `operation_reference` identify the already-saved refund operation. The shared `case-read` action `reviewer_detail` returns `traceability.decision.decision_sha256`, approval actors/times and finalization actor/time. The two parties use `participant_detail` and never receive that trace or private notes. Keep tokens in debugger memory; do not print them or paste them into shell history.

While stopped at a breakpoint, a local read-only SQL query can show the immutable execution authorization row behind the safe response. Replace `CASE_UUID` with the synthetic case ID printed by the script before cleanup:

```sh
node scripts/supabase-local.mjs db query --local --output-format json \
  "select p.case_id, p.durable_notified_at, p.appeal_deadline_at,
          d.decision_version, encode(d.decision_sha256, 'hex') as decision_sha256,
          f.finalization_id, f.outcome, f.finalized_by, f.executed_at,
          f.approval_one_id, f.approval_two_id,
          aa.authorization_id as worker_award_authorization_id,
          f.refund_payable_id as refund_authorization_id,
          payable.authorized_by as refund_authorized_by,
          payable.status as payable_status,
          payable.amount_kobo as refund_authorized_kobo,
          progress.status as refund_status, progress.operation_id,
          operation.status as provider_operation_status,
          operation.provider_operation_reference
     from app_private.assignment_case_decision_publications p
     join app_private.assignment_case_decision_versions d
       on d.decision_id = p.decision_id and d.decision_version = p.decision_version
     left join app_private.assignment_case_finalizations f on f.case_id = p.case_id
     left join app_private.assignment_case_award_authorizations aa
       on aa.finalization_id = f.finalization_id
     left join app_private.allocation_refund_payables payable
       on payable.refund_payable_id = f.refund_payable_id
     left join app_private.allocation_refund_progress progress
       on progress.refund_payable_id = payable.refund_payable_id
     left join app_private.provider_operations operation
       on operation.operation_id = progress.operation_id
    where p.case_id = 'CASE_UUID'::uuid;"
```

This privileged local database query is for tracing saved synthetic rows; it is not permission evidence. The Edge requests and denial assertions are the permission evidence. A poster refund has an immutable `refund_payable_id` before an operation exists; at `unknown`, the same payable maps to the same saved operation/reference. Unknown means the simulator result is unresolved, not that the poster received money. The run must not issue a second refund identity.

At the later checkpoint breakpoint, inspect `retainedAuditCheckpoint.directory` in the debugger, then, from a second terminal while the local process remains paused and the local stack is still running, verify the retained public checkpoint against the advanced chain:

```sh
node scripts/check-audit-checkpoint.mjs verify "/temporary/directory/printed/by/the/test" --require-advance
```

The verifier reads the trusted public key and signed checkpoint from that directory; it needs no secret or signing key. It confirms the original signed head remains valid after later events. Resume the debugger to let the harness reset its marked synthetic data and stop Supabase. If the harness has already finished, its retained artifacts still support evidence review, but this `verify` command needs the local chain running; it cannot prove a live-chain comparison after cleanup. The same-workstation test is not independent production storage or key custody.

For a collection `merchant_mismatch`, compare the stored `provider_operations.merchant_identity`, `server_claim_payment_operation_for_runner`'s `merchant_identity`, and the simulator result's `merchantIdentity`. In the reproduced regression the collection and simulator both held `fake_nbd_local_merchant_v1`, but the Step 8 claim projection omitted the expected field. Corrective migration `20261109000200_restore_collection_merchant_claim.sql` restores that field. Keep the runner's equality check: a missing or different expected identity must still be rejected. The migration does not release parked exceptions or manufacture a new provider operation. No hosted endpoint, real provider call or bank receipt is involved. The final local Edge journey passed, including these case/refund checks and cleanup. See [Phase 4 evidence](phase-4-evidence.md) for the recorded synthetic references, actual results and remaining Step 9 scope.

## Local signed audit checkpoint

For the populated case/refund proof, run `npm run check:marketplace` (or the full `npm run check:phase4`) under Node 22.23.2. **This resets and clears this repository's local Supabase database.** After the synthetic case/refund journey has committed its audit events, the script exports and verifies the signed checkpoint before cleanup. It then commits later legitimate reconciliation events and verifies the earlier retained checkpoint again. The success lines record the saved event count/head, rejection checks and later event count. The stack must be the native loopback project; no hosted database is accepted.

The checkpoint reuses `app_private.financial_audit_integrity` and `financial_audit_integrity_valid()`. A canonical Ed25519 checkpoint is signed in process memory outside PostgreSQL. Its separately trusted `trust/trusted-public.pem` and `retained/retained-checkpoint.json` are stored under the OS temporary path printed by the run, outside the repository and database. The verifier loads the trusted key from that separate file, never from the checkpoint. The private key is not written or printed.

The check accepts the original signature, then rejects edited checkpoint content, a signature from an untrusted key, a changed recomputed chain head, and a database snapshot rolled back before the retained head. For a populated run, rollback uses the real prior audit-chain head as the modeled restored snapshot; the database itself is not destructively edited. After a later real simulator reconciliation event advances the chain, the retained checkpoint must still verify. The printed event count is the chain count at export, before cleanup.

`npm run check:audit-checkpoint` alone verifies the chain present at that moment and does not create the populated dispute/refund example. Each export makes a new temporary key and trust directory. Keep the printed checkpoint directory if you need to inspect that run after cleanup; the cleared local database cannot be reconstructed from the saved checkpoint alone. This same-workstation test proves the local signature and anchor mechanism only. It does not prove protection from an owner controlling the database, signer and temp directory. Production key custody, independently controlled checkpoint storage, retention/rotation and operational verification remain launch requirements. See [checkpoint evidence](phase-4-evidence.md#phase-4-step-10-acceptance).

## Phase 4 Step 10 combined local acceptance

Run `npm run check:phase4` after selecting the pinned Node version from `.nvmrc` (22.23.2) and npm version from `package.json` (10.9.8). The wrapper runs case handlers, checkpoint unit checks, Phase 1/2 regressions and toolchain checks, marketplace boundary tests, payment tests, the full local Deno Edge journey, then the terminal migration rebuild, database suite, generated-type comparison and cleanup. It prints each check's duration and writes `docs/phase-4-source-manifest.sha256`, a safe SHA-256 inventory of source files. It reports the committed Git revision when one exists; for an uncommitted workspace, the manifest digest is the reproducible source identifier.

This command resets the repository's local Supabase database and removes only marked synthetic fixtures. Use it only when that local data is disposable. Its synthetic journey uses separate Auth-issued party and staff identities, local TOTP/AAL2, loopback Edge HTTP and the fake payment simulator. It does not contact hosted services or a real provider. The populated audit checkpoint is exported and verified after the dispute/refund audit events and before cleanup. See the [recorded Step 10 run](phase-4-evidence.md#phase-4-step-10-acceptance) for actual counts, timing, source manifest, event count and remaining launch gates.

## Local Deno Edge HTTP check

`npm run check:edge-local` starts the native local stack without its bundled Functions service, launches `supabase functions serve` as a separate pinned local Deno process, and sends requests through the local API gateway at `http://127.0.0.1:54321/functions/v1/`. This is the tested route: direct host requests to the worker's advertised port `8081` were refused, while gateway requests reached the handler. The test proves invalid-token 401; AAL1, unrelated-user and revoked-current-grant 403; an authorized real TOTP/AAL2 reviewer queue response; and actual SMS Edge path five accepted/one rate-limited synthetic hook event. The full-suite run measured commit-to-candidate queue visibility and commit-to-assigned-queue visibility at 74 ms and 150 ms. Both were below 60 seconds in this one local run; this is not a production load guarantee or realtime UI claim. The runner redacts its ignored log and stops the local services. It preserves database history and leaves a synthetic review request closed as `needs_information`.

## Local payment simulator boundary

`npm run test:payments` starts an ephemeral fake provider on `127.0.0.1` and tests the normalized adapter, operation retry, internal runner route and separately signed callback handler. It generates all signing secrets in memory and makes no outbound provider request. The provider fixture has no route for choosing outcomes or injecting callbacks; tests control it through an imported fixture object. `NBD_PAYMENT_MODE` defaults to `disabled`. Local Edge configuration accepts only `local_simulator` with loopback Supabase and simulator URLs plus server-only request, webhook and runner secrets. Never use `NBD_SIMULATOR_*` secrets in browser code or `NEXT_PUBLIC_*` variables.

The simulator protocol signs `timestamp + method + request path + raw request body` for internal adapter calls. Its callback protocol signs `event ID + timestamp + raw body`. That signature is only a fake-provider test rule. It does not verify Bachs signatures. A callback acknowledges only after its digest receipt is committed; the runner then looks up the saved provider operation. The combined Phase 3 journey exercises local simulated funding and withdrawal; it creates no real payment or bank receipt.

## Phase 3 local acceptance and recovery

Run `npm run check:phase3` with Node `v22.23.2`, npm `10.9.8`, Deno `2.1.4`, Supabase CLI `2.122.0` and PostgreSQL `17.11.0.006`. It is destructive to this repository's **local** Supabase data: it resets the local database, creates only synthetic Auth fixtures, exercises local routes and removes fixtures before shutdown. It does not contact hosted services. The latest all-together run passed on 4 November 2026; exact results and source manifest are in [phase-3-evidence.md](phase-3-evidence.md). The command-level verification map, including partial Edge coverage, is in [phase-3-milestone.md](phase-3-milestone.md).

To investigate an unknown simulated operation, use the owner-scoped `funding_status` request for a collection or `get_my_wallet` for a withdrawal. Preserve its operation/provider reference. With an active local/test account holding the current `financial_inspect` grant and an AAL2 session, use `ops-financial-inspection` to trace that saved reference, then run reconciliation and retain its `run_id` and findings. An unknown withdrawal remains reserved; an unknown collection remains unpublished. Let the authorized local runner look up the original saved operation identity when it is available. Never make a new payment identity, edit provider status/journals, or manually clear a reservation. If the authorized local runner is unavailable, leave the operation in unknown state and retain the exception for investigation.

To pause local simulated money operations, stop the runner consumer first. If it cannot be stopped separately, stop the local Supabase stack with `npm run supabase:stop`; this stops the HTTP routes and preserves the local database. Do not restart a consumer to create new authorization. When the issue is resolved, resume only through the existing saved operation and original provider reference. No deadline, timer, reminder, silence or cron may release held money.

## Financial reference tracing and local pause

Use `/functions/v1/ops-financial-inspection` only with an active local/test staff account that has the current `financial_inspect` grant and an AAL2 session. The route is read-only. Trace a saved local record with a POST JSON body such as:

```json
{ "action": "trace", "reference_type": "job", "reference_id": "<job-uuid>" }
```

Supported reference types are `operation`, `provider_reference` (`sim-...` only), `funding_intent`, `withdrawal`, `journal`, `job`, and `reconciliation_run`. For a provider reference, send `{"action":"trace","reference_type":"provider_reference","reference":"sim-<uuid>"}`. The response includes bounded related state, safe errors, exceptions, durable outbox state and attributable audit fields; it excludes full bank data, identity evidence, secrets, lease values and raw provider payloads. For a reconciliation, POST `{"action":"reconcile"}`. Save its `run_id`; trace that ID as `reconciliation_run` to retrieve the immutable summary/findings later. A `mismatch` or `unknown` result is preserved for investigation. Do not edit journal rows, reset the database, create a replacement payment ID or debit unrelated earnings to force a match.

To pause local simulated money work while preserving its records, stop the operation-runner consumer first, then block the local `marketplace-command`, `wallet-command` and `payment-operation-runner` routes at the local gateway. Keep the `ops-financial-inspection` route available only if read-only tracing is still needed; its local-simulator call is a signed liquidity read. If route-level blocking is unavailable, run `npm run supabase:stop` to stop the local stack; this preserves the local database. In an interactive local function server, `NBD_PAYMENT_MODE=disabled` prevents a payment adapter from starting, but the wallet and ops-inspection functions also require `local_simulator` configuration and will be unavailable in that mode. Restart routes only after the issue is understood. Unknown and queued operations remain saved and do not gain new authorization when a consumer restarts.

`npm run check:marketplace` resets the native local Supabase database before and after testing. It creates only synthetic Auth actors, starts the local Deno Edge route and loopback simulator, then exercises funding, discovery, application/thread, acceptance, start/submit/confirm/hold, wallet, simulated withdrawal, notices and ops inspection through the local API gateway. It includes both student and partner posters, separate-connection final-slot acceptance, and an Edge HTTP confirmation-versus-hold race. It removes test data and stops Supabase. It will erase pre-existing data in this repository's local database; use it only when that local data can be discarded. It never targets a hosted project or calls a payment provider.

For interactive local work, use `npm run supabase:start`, `npm run supabase:status`, and `npm run supabase:stop`. These use `.supabase-home/` and the native runtime as documented in [environments](environments.md). Do not paste local keys or database URLs into logs or issue reports.

To serve a local Edge Function, keep the stack running in one terminal and run `npm run supabase:functions` in a second for the runtime probe, `npm run supabase:functions:identity` for the JWT-verified registration handler, or `node scripts/supabase-local.mjs functions serve identity-school-email` for the JWT-verified school challenge handler. `check:phone` owns and closes its signed SMS test listener; the `send-sms` Edge Function is not separately served by that command. Use `npm run supabase:stop` for safe shutdown; it preserves local data. Use `npm run check:database` when you intend a clean, local-only rebuild. It does not target a hosted project.

## Failure handling

- If the Workers preview fails, inspect the first failed assertion and the build output. Health must remain `{ "status": "ok" }` with `Cache-Control: no-store`; it must not include credentials, versions, or user data.
- If database start fails, the check fails. It does not skip tests when a service is unavailable. Use the printed check ID to correlate the sanitized report with the CI run.
- If an authorization assertion fails, inspect grants and policies in the migration. Do not disable RLS or grant broad access to make the test pass.
- If a phone command fails, retain the test's safe Auth HTTP status/error code and inspect the matching local Auth/database error. The corrected boundary expects Auth country-code digits without `+` and treats both empty string and NULL as no pending challenge; the protected application mirror adds `+`. Keep raw request bodies, OTPs, contacts and credentials out of diagnostic output.
- If generated types differ, run `npm run supabase:types` against the local stack and review the schema change before updating the generated file.
- If local staff access fails, check that the token completed a TOTP challenge and actually reports AAL2, then check the current grant in the private database. Do not change `user_metadata` or widen browser grants to repair staff access.
- Preserve local service data unless a local reset is intended. Never use hosted reset commands for troubleshooting.

## Reporting boundary

The project has no hosted application error-reporting service. The local marketplace and finance handlers return request IDs and safe error envelopes; local check harnesses redact credential-like diagnostics. Use those request IDs with local sanitized logs only. Do not put full requests, identity evidence, bank data, auth tokens, provider secrets or provider payloads in reports.

Real payment movement and real identity-document intake remain gated. This runbook does not authorize hosted deployment, hosted database changes or production secrets in pull-request CI. Hosted Phase 1 staging checks, hosted CI, timing/region measurements and staging permission checks remain pending. See [phase-1-evidence](phase-1-evidence.md) and [launch-gates](launch-gates.md).
