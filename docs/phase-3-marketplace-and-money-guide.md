# No Broke Dayz — Phase 3: marketplace and money backend, locally simulated

Prepared: 3 November 2026. Application root: `/Users/mac/Desktop/NoBrokeDayz`.

This guide contains instructions and prompts, not application code. Complete one step at a time and inspect its evidence before continuing. It authorizes the local, synthetic Phase 3 journey described below. It does not authorize a hosted deployment, real payment, provider account change or production interface.

## Goal

Prove this backend journey through actual local Edge HTTP and database boundaries:

Verified synthetic poster → draft job → exact simulated funding → discoverable listing → student application → atomic acceptance → start → submission → poster confirmation → worker earnings → manual simulated bank withdrawal.

Use a clearly labelled fake payment provider. A fake success is evidence of application behaviour, not Bachs support, sandbox integration or money received in a bank account.

## Starting position and scope

- Phase 2's complete local suite passed. It remains partially verified: the five-wrong-phone-code rule is unresolved, real evidence promotion is blocked by missing scanning/sanitizing, and real domains/delivery/privacy gates remain open. Preserve these restrictions.
- Hosted staging is deferred by the user. Hosted CI has not run. Continue local-only development with the pinned Node/npm/Deno/native Supabase setup and the separate Functions server through the supported loopback gateway.
- Keep the existing `app/`, `lib/`, `supabase/functions/_shared/`, migration and test conventions. Do not create a competing `src/` tree, replace the toolchain or rename the whole architecture.
- The category table already exists as `public.job_categories`. Reuse its controlled categories. Public taxonomy does not make jobs or user data public.
- Reuse the current identity, Auth validation, staff grant and audit/event boundaries. Read current database capability/status facts on protected actions; do not invent a second verification system.
- Bachs conditional holding, fee funding and refund compatibility remain unresolved. The existing reference documents no Refund API support for NGN bank transfers and one successful refund per charge. Do not assume independent per-slot refunds against one charge will work. Any later provider implementation must recheck current official/account documentation.
- Phase 3 includes the ordinary completion/payment path, capacity safety, a minimal participant-triggered dispute hold, private application conversation persistence, essential notifications and financial inspection. Full cancellation/refund/split/appeal/approval workflows come in Phase 4; full realtime communication and ratings come later. No unsupported financial outcome may be exposed as working.

## Step 1 — write marketplace and money contracts

**Create/update:** `docs/marketplace-contracts.md`, `docs/payments-and-recovery.md`, `docs/data-and-permissions.md`, `docs/decisions.md`, `docs/phase-3-evidence.md`.

**Prompt**

> Work in /Users/mac/Desktop/NoBrokeDayz. Implement only Phase 3 Step 1: planning and test contracts. Read AGENTS.md, approved spec.md, F3–F6/F8 requirements, relevant messaging/notification/admin rules, technical states/accounting/concurrency sections, identity contracts and the latest Phase 2 evidence. Inspect actual current schema and command helpers before choosing names. Define commands and safe response shapes for draft/fund/status/discover/apply/accept/start/submit/confirm/hold/wallet/withdraw and authorized ops inspection. Preserve separate listing and assignment states, immutable funded/accepted terms, separate application deadline and needed-by time, role restrictions and per-slot principal. Specify integer-kobo JSON serialization, 500-basis-point half-up commission, journal accounts, invariants, cash/receivable availability, idempotency keys, unknown-result recovery and platform-funded fees. Define server-bound fresh confirmation for bank changes/withdrawal and exact destination version binding. Propose bounded job fields, pagination, maximum slots/amount validation and expiry rules for approval where they add product policy; keep local test limits distinct from unapproved live exposure caps or provider minimums. Map each risky rule to a failing behavioural test and the eventual actual Edge HTTP journey. Describe the fake provider's normalized contract separately from an unimplemented Bachs adapter. Keep later cancellation/appeal outcomes disabled. Present product/security choices requiring approval before dependent implementation; finish independent contracts while waiting. Do not create jobs or money tables yet.

**Expect:** one agreed model showing who can do what, when money is allocated and how retries behave. The fake provider's capabilities are never attributed to Bachs.

**Check:** no automatic release/refund after a deadline; no extra poster fee; no partner work capability; no fundable edit of accepted terms. A single job with three workers must have three allocations and assignments, not one shared worker status.

**Debug:** if draft price, collected gross, provider net cash and worker net are conflated, resolve the accounting model first. If a proposal changes the product promise or claims a provider capability, record it for explicit resolution. Continue dependent work after required contract decisions are accepted.

## Step 2 — add the ledger and transactional financial foundation

**Create/update:** new timestamped `supabase/migrations/`; financial tests under `supabase/tests/database/`; exact-money helpers where needed under `_shared/` or `lib/`; generated client-safe types.

**Records:** funding intents/attempts, one principal allocation per funded slot, private ledger accounts/journals/entries, transactional rebuildable wallet projections, durable authorizations/provider operations, webhook receipts, command idempotency and financial exceptions. Add only records needed by this phase; reuse existing event/audit/outbox records where appropriate.

**Prompt**

> Implement only Phase 3 Step 2, test-first for financial rules. Add private financial records and narrow transactional functions using migrations after the existing history. Store bigint integer kobo and validate range/overflow; serialize safely without JavaScript number precision loss. Snapshot 500 basis points per allocation and round commission half-up exactly on awarded gross. Enforce balanced journals at commit or an equally tested controlled-function boundary; ordinary clients and generic service paths cannot insert/update/delete journal rows or set balances. Corrections append compensating journals. Update wallet projections, allocations, unique business-effect IDs, authorization, audit and domain-event/outbox records in the same transaction as their business result. Prove allocation conservation and distinguish held principal, worker liability, revenue, provider cash/receivable and platform expenses. A worker reservation/bank settlement is not another allocation of the original gross. Expose no private tables directly; reuse the approved server-only RPC gateway pattern only with narrowly granted operations and actor validation. Preserve existing identity helpers and grants. Test duplicate effect IDs, fractional-naira rounding, oversized/invalid amounts, unbalanced journals, immutable entries and projection rebuild comparison. No provider network call occurs inside a DB transaction.

**Expect:** controlled financial transactions conserve amounts and journals balance. There is still no payment integration or user-spendable seeded money.

**Check:** NGN 3,000 gross yields NGN 150 commission and NGN 2,850 net. Test kobo edge cases as well as round naira. Platform capital/fee reserve uses its own documented source, not fabricated earnings or another job's reserved principal.

**Debug:** if totals differ, inspect rounding basis and double-counted reservation/settlement. Fix with migration/function changes and rebuild local test data; do not edit posted financial rows to hide an invariant failure.

## Step 3 — build a local fake provider and durable operation runner

**Create/update:** a payment adapter contract and fake implementation under `supabase/functions/_shared/`; isolated simulator/test support under `tests/fixtures/payments/` or `scripts/`; payment boundary tests; local-only configuration/runbook.

**Prompt**

> Implement only Phase 3 Step 3. Build a deterministic local payment simulator behind a small normalized adapter contract: initialize collection, look up original operation, simulate settlement, verify simulator events and create/look up simulated payout. Include programmable pending/success/known failure/reversal/unknown outcomes, duplicate/out-of-order events and timeout after provider acceptance. Persist the application operation identity before the external boundary. The operation runner claims durable jobs with leases and bounded retries, and reuses original references; job retry cannot invent release authorization. A simulated timeout must remain unknown until authoritative simulator lookup resolves it. Bind mode and allowed simulator endpoint to explicit local/test configuration, reject accidental nonlocal targets, and provide no production-capable debug funding or callback injection route. A browser must not select its provider, override amount/status or obtain simulator signing secrets. Authenticate local callbacks separately from users; if using a fake raw-body signature, document it as a simulator protocol, not proof of Bachs webhook verification. Test spoofed/altered/replayed events and durable receipt-before-ack processing. Keep Bachs network calls, keys, SDK integration and refunds unimplemented. Synthetic balances/destinations must be unmistakably fake.

**Expect:** tests can reproduce success and uncertainty reliably, without contacting any provider or creating real money. Restart/retry preserves identities and one financial effect.

**Check:** simulate provider acceptance followed by a lost response, restart the consumer and look up the original operation. No second payout/collection should be created merely because the first response disappeared.

**Debug:** if the fake provider always returns success, add the required failure scenarios before relying on it. If a test can bypass authorization by directly marking an operation paid, remove that application-facing shortcut; privileged fixture controls belong only in isolated local test tooling.

## Step 4 — implement job drafting and exact-total simulated funding

**Create/update:** jobs/immutable terms migrations; cohesive marketplace/payment Edge handlers and `_shared/` modules; job/funding database and actual HTTP tests; data/permission documentation.

**Prompt**

> Implement only Phase 3 Step 4. A current verified student or partner can create their own draft using title, description, controlled category, location, positive gross per worker, slots, application deadline, needed-by and agreed start requirements. Recheck protected capability/suspension at every command. Compute total server-side as gross per worker × slots. Snapshot immutable terms when initiating funding and bind the funding intent to that exact version/amount/currency/merchant identity. Price/slot edits during pending funding must not reinterpret a later callback; use explicit versioning/replacement contracts and safe stale-state responses. Initialize simulated checkout with a stable reference and mark awaiting payment. Browser return remains pending and cannot fund a listing. Only a validated simulator result/lookup for exact expected NGN principal may atomically journal funding once, create one held allocation per slot and publish the job. Wrong currency/amount/account/reference, duplicate excess collections and unknown results go to ops exceptions without corrupting funds or silently disappearing from reconciliation. Record processing costs separately and account for provider net receipt without shrinking funded principal. Prevent material in-place edits after funding. Expiry removes discoverability but never refunds. Do not implement a real Bachs endpoint or bypass funding via user-editable fields.

**Expect:** three NGN 3,000 slots require exactly NGN 9,000. Pending/failed/unknown collections do not publish a job; repeated success events create one funding journal and three allocations.

**Check:** an unverified/suspended/unrelated actor cannot fund or edit the poster's job. Same idempotency key with altered input fails. An old collection success cannot fund newly changed terms.

**Debug:** if simulated browser navigation publishes a job, move success authority to the server/event verification path. If fees reduce the slot allocation, correct accounting and platform fee coverage before proceeding.

## Step 5 — implement verified-only discovery and job detail reads

**Status:** Implemented locally in migration `20261104000300_marketplace_discovery.sql` and the `marketplace-read` Edge route. See [Phase 3 evidence](phase-3-evidence.md) for the measured local HTTP journey and scope limits.

**Create/update:** narrow job queries/projections, measured indexes/search vector migrations, discovery API tests and a small test-client interface contract.

**Prompt**

> Implement only Phase 3 Step 5. Expose discoverable job summaries/details only to currently qualified active students/partners. Deny anonymous and unverified direct API queries; public category reads are not job access. A listing must be funded, open, UNILAG-only, before its application deadline and have available slots. Return 20 initial rows with stable created_at/id cursor pagination, keyword/category/gross-pay/location/needed-by filters and safe poster summary in one bounded query. Use PostgreSQL full-text search and evidence-based indexes rather than another search service. Preserve deterministic filter/cursor state for the later frontend. Detail includes gross per worker, slots remaining, exact net after commission and the immutable terms version. No private identity/contact/bank columns or unapproved protection claims. Funded owner/participant history uses separate authorized queries so filled/expired jobs remain inspectable without appearing available. Test partial fill, final fill, expiry, unpublished/cancelled states, stale cursor results and same-token suspension. Record query measurements with dataset/conditions; do not call a tiny local fixture a Nigerian-network performance pass.

**Expect:** qualified test clients see only available funded listings; the poster can still inspect their own historical record through its allowed path.

**Check:** a filled job is absent from discovery, not erased from assignment/history. Filtering cannot broaden row permissions.

**Debug:** inspect query plans and missing join/index paths before adding caching. Test current identity helper calls and RLS/response shape together when direct API access exposes too much or hides allowed rows.

## Step 6 — add applications, atomic acceptance and private thread persistence

**Status:** implemented locally with private application/assignment/thread migrations, authenticated Edge commands and participant-scoped reads. Assignment start/submit/confirm and participant holds are implemented in Step 7. See `docs/phase-3-evidence.md` for current test results.

**Create/update:** application/assignment/terms-binding/thread/message migrations, marketplace/messaging commands, concurrency and participant-access tests.

**Prompt**

> Implement only Phase 3 Step 6. Current verified students may apply once to another person's available job with an optional bounded note; partners and self-applicants fail at the command/database boundary. Applying creates one private application thread but reserves no slot. The owning qualified poster accepts an eligible application transactionally: lock job/available allocation, verify worker's current eligibility, bind one assignment and immutable terms snapshot, and update capacity without double-reserving principal. Two simultaneous final-slot accepts must not both succeed. A partially filled job stays discoverable. Reuse one thread through acceptance. Add minimal text persistence/read APIs with participant authorization, client message IDs, stable sequence and read-only retention on rejected/withdrawn/closed applications according to approved transitions; no reapplication. Messages must be saved before acknowledging sent. No general direct messaging, attachments, voice notes, realtime/presence feature or unrelated staff access. Acceptance/application events and essential in-app notices persist transactionally. Test rival-thread denial, retries, duplicates, eligibility changes between apply/accept and stale listings. Keep accepted and unselected applicants' identities private to permitted viewers.

**Expect:** one application gives one private thread; one accepted application gives one funded assignment. Applying neither authorizes work nor claims a slot.

**Check:** race two acceptance calls against a one-slot job using separate connections. Verify capacity, allocation bindings, journal effects and notification uniqueness afterward.

**Debug:** if browser-style sequential tests pass but concurrency oversubscribes, fix locking/unique constraints. If retry creates another thread, enforce the unique application/thread relationship instead of client-side suppression.

## Step 7 — implement assignment progress, a safety hold and ordinary release

**Status:** implemented locally with private assignment progress/hold records, authenticated Edge commands and participant-scoped status reads. The local HTTP journey verifies the exact completion split, an isolated held allocation, expiry without refund/release, and a concurrent confirm-versus-hold race. See `docs/phase-3-evidence.md` for test results and live-service blockers.

**Create/update:** assignment start/submit/confirm commands; minimal participant problem-report/hold record; financial/state-race tests; safe status/history projections.

**Prompt**

> Implement only Phase 3 Step 7. The assigned eligible worker explicitly starts and later submits their own assignment. Applying/acceptance does not start work; submission does not release money. The owning eligible poster may confirm only submitted, funded, nonterminal assignments without a hold. In one transaction lock the allocation, record authorization, allocate exact worker net/commission, update the wallet projection, mark completed once and append audit/events/notices. Worker earnings release is internal accounting, separate from provider settlement and bank payout. Implement the minimal legitimate participant report/open-hold command now, retaining prior assignment stage and reason/narrative/desired outcome; this protects the ordinary release path before the full Phase 4 case workflow. Only assigned-through-submitted funded participants can open it, and one active case/hold per allocation is enforced. Race confirmation against hold creation: one eligible result wins and no contradictory movement commits. Do not use a client-editable dispute flag or a test-only production hold setter. Full investigation, split/refund/appeal/finalization controls remain unavailable until Phase 4; an unresolved held allocation stays held, with honest supported-status responses. No timer, reminder, silence, cron or generic admin can release it. Completion is idempotent; count completed work once when eligible and keep later rating eligibility compatible with closed disputes/appeals.

**Expect:** one confirmed NGN 3,000 assignment credits NGN 2,850 available earnings and NGN 150 commission once. Another worker's held assignment stays separate. A submitted-but-unconfirmed worker has no spendable earnings from that assignment.

**Check:** try worker-as-poster confirmation, confirmation before submission, replayed confirmation and confirm-versus-hold races. Test that other assignments and unrelated available earnings remain usable.

**Debug:** if a hold freezes an entire job/wallet, scope it to the affected allocation. If a timer releases funds, remove that authority and retain reminders as notifications only. Never resolve a held test case by editing its financial rows.

## Step 8 — implement wallet reads and manual simulated bank withdrawal

**Status:** implemented locally with private wallet/destination/withdrawal records, fresh-password proof, authenticated wallet Edge routes and exact payout accounting through the local fake provider. The actual local Edge journey covers wallet privacy, bound destination versions, concurrent reservations, platform-funded provider cost, reversal and timeout/recovery. See `docs/phase-3-evidence.md`. No real bank details or Bachs capability were implemented.

**Create/update:** wallet/withdrawal/destination records and handlers, operation-bound fresh-confirmation support, local fake destination fixtures and withdrawal integration tests.

**Prompt**

> Implement only Phase 3 Step 8. Provide own-wallet balances/history that distinguish available earnings, held allocations, case-held amounts, withdrawal reserved/processing amounts and poster-held principal; do not report future refund capabilities as complete. Add versioned synthetic bank/recipient destinations whose ownership/verification is explicitly a simulator fact, not Bachs KYC. Prove supported fresh authentication or operation-bound step-up before sensitive destination changes and withdrawals. A single-use confirmation binds verified actor, command, exact amount, destination version and expiry; consume it atomically with reservation. Replayed or altered proof fails; no client-confirmed boolean. No arbitrary platform withdrawal fee/minimum, no general deposits/transfers or automatic payout. The request atomically reserves available earnings and creates a durable operation before invoking the simulator outside the transaction. Concurrent requests cannot overspend. Provider cash/settlement availability and platform fee reserves must cover the intended operation without using principal owed to other jobs. Simulated bank receipt equals requested net; record provider costs separately, including any recipient fee-funding allocation without misclassifying it as worker income. Pending stays processing, timeout stays unknown, and authoritative failure/reversal compensates only once under the documented observed-result rule. Check original operation identity before retry. A callback cannot change destination/amount or pay another actor.

**Expect:** a worker with NGN 2,850 available can request that exact simulated bank amount. The reservation prevents a second spend; “paid” appears only after authoritative simulator completion.

**Check:** race two requests against the same balance. Simulate accepted payout with lost response, changed destination after confirmation, duplicate success, known failure, reversal and missing callback. Verify conservation, one compensation and original-reference reconciliation.

**Debug:** if unknown payouts restore available balance, fix state handling before retry. If fees make the fake recipient short of funds, show the platform funding entry and reserve—not a worker deduction or invented provider capability.

## Step 9 — complete essential events, inspection and reconciliation

**Status:** Implemented locally. Recipient-only notice reads, AAL2/current-`financial_inspect` read-only tracing, simulator-to-ledger reconciliation, audit integrity checks and local reference/pause instructions are in place. No independent signed audit checkpoint, email/SMS sender, live provider, refund, case outcome or hosted configuration is implemented. See [phase-3-evidence.md](phase-3-evidence.md).

**Create/update:** authorized staff financial inspection/exception APIs, any additional operational wallet/history projections, leased job consumer, local reconciliation check and `docs/payments-and-recovery.md`/`docs/runbook.md`.

**Prompt**

> Implement only Phase 3 Step 9. Complete essential in-app notices for application/acceptance/submission/release/withdrawal outcome, using existing immutable events and durable outbox records committed with business state. Deduplicate per user/event/type and enforce recipient-only reads. Local delivery failure never rolls back money or invents successful email; real Zoho/SMS and full reminder scheduling remain later work. Jobs can execute only persisted authorized operations, with leases, reclaim and bounded retry/exception visibility. Add narrow MFA-and-current-capability staff queries for funding, allocations, journal entries, provider references, outbox/unknown/mismatch exceptions and safe audit tracing. Inspection is not permission to edit journals or release cases. Reconciliation compares journal-derived balances, projections, simulator cash/receivables, unresolved operations and held liabilities; detects mismatches without creating new authorization. Record financial authorization/access/provider outcomes with attributable append-only audit and integrity checks; independent signed audit checkpoints remain explicitly unproved until their later workflow exists. Prove interrupted-consumer recovery and missing callback lookup. Document how to trace a reference and suspend affected simulated commands. Do not resolve exceptions by issuing a new payment identity, resetting journals or debiting unrelated earnings.

**Expect:** a granted local ops test user can trace why a balance changed and inspect unresolved operations; an ordinary user sees only their own allowed history/notices.

**Check:** financial movement, event and projection update cannot partially commit. Two consumers cannot claim/execute a business effect twice. A fake queue retry does not create authorization for held funds.

**Debug:** if an email failure removes a notice, separate durable in-app state from transport delivery. For mismatches, preserve evidence and mark an exception; investigate rather than forcing a balance to the expected number.

## Step 10 — prove the complete local journey and failure suite

**Status:** Passed locally with `npm run check:phase3` on 4 November 2026. The complete run record, local-only limits and source manifest are in [phase-3-evidence.md](phase-3-evidence.md).

**Create/update:** local marketplace/payment test runners and `tests/integration/payments/`; `scripts/check-phase3.mjs`; relevant `package.json`/future CI checks; `docs/phase-3-evidence.md`.

**Prompt**

> Implement only Phase 3 Step 10: full acceptance and regression. Use current approved synthetic identity fixtures through supported local flows; never introduce a deployable verification/funding bypass. Fixture-only ready evidence metadata must remain isolated from real file promotion. Run the job→funding→application→acceptance→start→submit→confirmation→wallet→manual simulated bank withdrawal journey through actual Deno Edge HTTP and client-safe reads, including student and partner posters. Use separate connections for races. Include all acceptance cases below, original Phase 1/2 regressions and current type/lint/format checks, including all Edge entries and generated types. Ensure scripts compare/write types with consistent formatting. Add a single sequential phase wrapper that fails on missing/failed required checks and ends with local-only rebuild/fixture cleanup and stopped services. Database assertion totals grow naturally; preserving 319 existing assertions is a regression baseline, not an arbitrary target. No hosted reset, CI claim, push or deployment. Record exact toolchain, migration count, test results, timestamps, build/revision or a safe source manifest if no Git HEAD exists, and synthetic dataset/network conditions. Run one controlled financial/permission regression showing an invariant test fails, restore the source and rerun the complete suite together. Do not rerun a long suite repeatedly without a change/failure reason. Report simulated-provider evidence honestly and keep unresolved launch contracts visible.

### Required acceptance cases

| Boundary            | Required result                                                                                                                           |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| Current identity    | Anonymous/unverified/suspended reads/commands denied; partner cannot work; same-token suspension enforced.                                |
| Exact collection    | 3 × NGN 3,000 means NGN 9,000 principal; no surcharge; provider fees do not reduce allocations.                                           |
| Funding authority   | Redirect/client status cannot fund; wrong amount/currency/account/reference quarantined; duplicate receipt/business effect once.          |
| Immutable agreement | Old funding/acceptance version cannot mutate to new terms; no funded price/slot edit in place.                                            |
| Availability        | Draft/unfunded/expired/filled unavailable; partial fill visible; owner/participant history still authorized.                              |
| Applications        | One per worker/job; no self/partner apply; thread private; no capacity reservation until acceptance.                                      |
| Capacity race       | Final-slot competing acceptance gives one assignment/allocation binding, with correct remaining capacity.                                 |
| Progress/release    | Assigned worker only; submission earns nothing yet; owning poster confirmation allocates net/commission once.                             |
| Hold race           | Confirmation versus participant hold cannot both win; no unrelated assignment/earnings frozen.                                            |
| Accounting          | Half-up kobo rounding, overflow handling, balanced journals, allocation conservation, immutable entries and projection rebuild agreement. |
| Withdrawal          | Fresh bound proof, verified synthetic destination, atomic reservation, no overspend or fee deduction from requested net.                  |
| Unknown outcomes    | Timeout after acceptance creates one operation; original lookup/retry and callback order reconcile without duplicate payment.             |
| Failure/reversal    | Proven result compensates once; late/duplicate events do not blindly regress state or create extra earnings.                              |
| Privacy/ops         | No cross-user wallet/thread/notice/ledger leak; staff requires current grant/MFA and cannot mutate journals or finalize held cases.       |
| Durable work        | Events/outbox commit atomically; consumer crash/reclaim and receipt-before-ack preserve one effect.                                       |
| Safety boundary     | Nonlocal fake configuration and ordinary-user simulator controls denied; no real provider reached; earlier phone/file gates intact.       |

**Expected overall example:** poster simulator debit NGN 9,000; three allocations of NGN 3,000. One completed worker earns NGN 2,850 with NGN 150 commission. Other allocations stay held until their own valid outcomes. A manual simulated withdrawal pays NGN 2,850, with platform-funded expenses separately accounted. With unresolved slots, the parent job must not be counted as fully completed.

**Debug:** passing helper tests alone do not prove the Edge/RPC/state transition path. Inspect actual transaction results and operation identities after every race/timeout. Stop at any accounting discrepancy rather than continuing to a cosmetic demo.

## Step 11 — document the milestone and stop before Phase 4

**Status:** Local closeout packet prepared on 4 November 2026. See [phase-3-milestone.md](phase-3-milestone.md) and [phase-3-evidence.md](phase-3-evidence.md). Phase 4 and production UI remain unstarted.

**Create/update:** `docs/phase-3-evidence.md`, `docs/phase-3-milestone.md`, `docs/development-log.md`, `docs/community-feedback.md`, `docs/launch-gates.md`, README/runbook and decision records.

**Prompt**

> Close Phase 3 locally. Map each implemented command to its actual tests, distinguish database/shared-handler tests from real local Edge requests and distinguish fake-provider scenarios from any unperformed Bachs sandbox/live work. Mark core failures as partial verification, not passed. Record whether the full updated suite passed together, cleanup completed and services stopped. Update the runbook so another developer can trace a simulated reference, investigate unknown state and reproduce the tests. Preserve the approved product and identity/provider/file/hosting gates. Explicitly list unimplemented Phase 4 cancellations, refunds/splits, appeal windows and independent money-decision workflows; no hold may be financially resolved through an unfinished shortcut. Prepare the milestone/weekly packet below, without sending or publishing anything. Do not start Phase 4 or create production UI.

### What to document and prepare for Community and Growth

After funding, acceptance/release and withdrawal milestones, append a short factual development note with requirement IDs, actual passing evidence, one limitation and one genuine challenge/lesson.

At phase close:

1. Capture a redacted local test result and optionally a short synthetic API/test-client walkthrough of one job journey. Label it **local simulation—no real money moved**. No fake banking receipt that could be mistaken for a real transaction.
2. Explain casually what works: the backend can track a funded demo job, safely assign workers and calculate earnings. Clarify that the interface and real payments remain unbuilt/unapproved.
3. Prepare one brief weekly update and one or two content opportunities based on actual work. Suggested topics: why applying does not reserve a slot; why available earnings and a completed bank payout are different.
4. If useful, ask what information students need before accepting a job, or how they expect pending versus available earnings to be explained. Record real feedback and owner decisions; do not claim a user-research result without a session.
5. Keep secrets, synthetic passwords/codes, full private requests, bank fields, staff identities, security thresholds and internal documents out of shareable captures. Prepare material for review only; no sending/publication by the agent.

## Completion and handoff

Phase 3's local core is verified only when the whole ordinary journey and failure/concurrency/permission/accounting checks pass together through the appropriate boundaries. Mocked Bachs behaviour cannot establish provider compatibility. Full F3–F12 acceptance, audited human case decisions, refund routes, realtime polish, real delivery, hosted recovery/performance and live launch remain later gated work.

Return the agent summary, `docs/phase-3-evidence.md` and `docs/phase-3-milestone.md` here. Include any blocker and exact redacted failure. We review those results before proceeding to Phase 4.
