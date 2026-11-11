# No Broke Dayz — Phase 5: communication, ratings and operations backend

Prepared: 10 November 2026. Application root: `/Users/mac/Desktop/NoBrokeDayz`.

Give your coding agent one prompt at a time. Review each result before proceeding. This guide describes the work; it contains no implementation code.

## Scope and starting point

Complete the remaining local backend work for F7 (ratings), F9 (notifications and reminders), F11 (messaging) and the operations contracts in F12. Reuse Phase 3's private application threads, saved messages, read cursors and in-app notices; reuse Phase 4's case, approval, refund and inspection APIs. Use the existing app/, lib/, Supabase migrations, shared Edge handlers and loopback gateway.

The Phase 4 baseline is the recorded passing 41-migration, 1,004-assertion run, with actual local Edge journeys and populated checkpoint verification. The earlier history-read 503 remains an intermittent observation, not a confirmed fix. No need to repeat the prior controlled mutation. Keep all real provider, identity-file, five-wrong-phone-code, production checkpoint, hosting and other launch gates open.

Stay local and synthetic. No production UI, live mail/SMS, Bachs calls or hosted provisioning. Phase 6 owns broader performance, reliability and recovery verification; Phase 7 owns production frontend integration.

## Step 1 — agree the remaining contracts and inspect existing coverage

**Files:** docs/communication-and-reputation-contracts.md, docs/data-and-permissions.md, docs/decisions.md, docs/phase-5-evidence.md.

**Prompt**

> Work in /Users/mac/Desktop/NoBrokeDayz. Complete only Phase 5 Step 1. Read AGENTS.md, spec.md, product F7/F9/F11/F12, technical sections 9–10 and Phase 4 evidence. Inventory existing message, cursor, notification, event/outbox, case access, profile counter and staff operations code. Map existing behaviour versus gaps. Propose only unresolved decisions: reminder recipients and catch-up after downtime, any rescheduling after a case closes with no action, review text and moderation rules, metric definitions/denominators, and a Realtime design that handles already-connected users whose permissions change. Include safe destination types and authorization, durable delivery/retry states and exact test boundaries. Preserve settled requirements: 24/48-hour reminders, 72-hour dispute guidance, no money movement from schedules, immutable one-review-per-direction after eligible completion, separate worker/poster averages, and private application-only chat. Present detailed choices needing owner approval before implementing the affected behaviour. Do not build code in this step.

**Expect:** a short decision list and a command-to-evidence map. No duplicate chat, notice or case system.

**Check/debug:** if the agent treats an existing handler or table as an end-to-end pass, ask for its actual evidence. If an operating value is unspecified, record a proposal instead of silently making it policy.

## Step 2 — finish message replay and read-state contracts

**Files:** existing marketplace read/command handlers under supabase/functions/, supporting migrations if needed, tests/integration/marketplace/, local Edge journey script.

**Prompt**

> Implement only Phase 5 Step 2 after approval of affected contracts. Keep one private thread per application and reuse immutable saved messages and monotonic read cursors. Add only missing bounded history/replay and unread behaviour. Replay by stable server sequence after the last durable cursor; keep sequences exact across JSON and handle page boundaries. Keep client message IDs stable across retries and reject changed payload under a reused ID. A lost acknowledgement must not create a second saved message. Confirm only after persistence; clients must distinguish pending from saved. Read updates cannot move backwards or mark inaccessible messages as read. Preserve withdrawn/rejected/closed history as read-only except the approved active-case policy. Verify current participation/qualification at every command and keep staff investigation access case-scoped. Test unrelated applicants, suspension with the same token, closed history, duplicate sends, replay gaps and read-state races. No general chat, attachments, voice notes or production screens.

**Expect:** two synthetic participants can recover messages and read state using the existing APIs, without gaps or duplicates.

**Check/debug:** test multiple replay pages and an acknowledgement lost after commit. If message IDs duplicate or unread state goes backwards, fix the persisted sequence/cursor contract before adding sockets.

## Step 3 — prove private Realtime and reconnect behaviour

**Files:** new Realtime authorization migrations as needed, a small reusable client module under lib/, local socket test runner, documentation of runtime limitations.

**Prompt**

> Implement only Phase 5 Step 3. Prove actual private Supabase Realtime Broadcast on the pinned local stack with two Auth-backed clients. Use scoped server-generated invalidation hints, not full message/notice rows or raw case, identity or money data. Prove topic membership at the Realtime boundary; topic names and client-side filtering are not access control. Do not allow clients to publish authoritative messages or read-state events directly. Test private joins, unrelated actor denial, cross-user notices, already-connected suspension/revocation and logout. Supabase documents cached channel authorization; do not assume revoking a grant immediately disconnects an existing socket. Use the approved revocation-safe dispatch/topic strategy, avoid emitting new protected hints to revoked recipients, and require current authorization on every authoritative read. Record any in-flight or runtime limitations honestly. Subscribe, recover from the last saved cursor, reconcile the subscribe/replay race, and deduplicate overlapping hints/replays. Clean up channels on logout and thread changes. Measure local saved-to-received latency with stated conditions; leave representative load/Nigerian network validation to Phase 6. If native Realtime cannot run locally, document the specific blocker and preserve working history/replay tests. Do not weaken RLS or provision hosting to get a pass.

**Expect:** private message/read/notice hints reach permitted test clients, and reconnect fetches durable state even when a hint was lost.

**Check/debug:** test revocation without a cooperative unsubscribe. A denied new join alone doesn't prove safety for an already-connected user. Inspect the actual gateway/socket and permissions before changing policies.

## Step 4 — complete notices and simulated transactional email

**Files:** existing notices and event/outbox migrations, shared delivery handlers, a local capture adapter/test fixture, delivery tests and runbook.

**Prompt**

> Implement only Phase 5 Step 4. Inventory and reuse existing identity, marketplace, case and financial events/notices. Fill missing application, acceptance, submission, release, withdrawal, verification and case/appeal outcome notices and transactional email requests; do not send an email for every chat message. Persist intent atomically with its source transition, deduplicate by recipient/event/channel/type, and make in-app read state independent of email outcomes. Return allow-listed destination kinds/IDs for the later frontend; opening a destination must still enforce its own authorization. Use a loopback-only email capture adapter with safe synthetic data, not live Zoho. Keep operational delivery credentials out of shared responses/logs and avoid private evidence, bank data or OTPs in ordinary templates. Add leased delivery claims, bounded retry/backoff, reclaim, permanent failure and exhausted/unknown visibility. Reconcile ambiguity rather than blindly resending; don't promise exactly-once external delivery. Keep the notice consumer separate from authority to post money or finalize a case. Preserve immediate Auth OTP dispatch and existing phone gates; no new SMS reminder channel.

**Expect:** the same event produces one notice and one intended delivery per approved channel; delivery failure leaves the in-app notice intact.

**Check/debug:** force a crash after capture and a repeated event. Compare delivery identity and persisted outcome before any retry. A capture result is local evidence, not proof of delivery to a real mailbox.

## Step 5 — add reminders that cannot move money

**Files:** scheduled reminder jobs/commands, local runner hooks, reminder timing and race tests, runbook.

**Prompt**

> Implement only Phase 5 Step 5. Schedule notices from committed submission: reminders at 24 and 48 hours and guidance toward the dispute route at 72 hours, using approved recipients and downtime behaviour. Use a server clock, a stable per-assignment/version/stage key and durable due records. Recheck eligible submitted state at dispatch; suppress on confirmation, cancellation or dispute, including races with an already-claimed reminder. Define the dispatch boundary honestly: a delivery already sent cannot be recalled. A reminder job may create only its allowed notices/delivery intents; its credentials and commands must not authorize earnings release, refunds, payouts, case opening or finalization. Test due/not-due, duplicate claims, retries, restart/catch-up and suppression with isolated time fixtures. No client time, live timer waits, public backdating route or real SMS/email.

**Expect:** a qualifying synthetic submission receives only the expected messages, and there is no ledger or hold change caused by the schedule.

**Check/debug:** compare journal, allocation and case state before and after the reminder test. If a stale reminder fires after a committed state change, fix the eligibility/claim boundary; don't hide it only in a later UI.

## Step 6 — add two-sided ratings and rebuildable counters

**Files:** private review/report/moderation migrations, profile-safe read and review command handlers, DB and Edge tests, contract notes.

**Prompt**

> Implement only Phase 5 Step 6. Permit one immutable 1–5 review with optional bounded text in each direction per eligible completed assignment. Derive reviewer, target and role from the assignment; require finalized completion and no open dispute/appeal. Test ordinary completion, eligible final worker award, and denial on cancellation/refund-only/no-action cases that are not otherwise completed. No early review, self-review, unrelated review, duplicate race or editing a submitted rating. Implement authorized reporting and scoped, audited moderation per approved rules; preserve original records and define how hidden reviews affect public totals. Expose safe underlying reviews and separate worker/poster averages/counts; show unrated when no qualifying reviews. Completed-work counts follow qualifying finalized assignments once, not applications or bank-withdrawal count. Maintain projections transactionally or through deduplicated events and provide a repeatable rebuild from authoritative records. Generic profile writes cannot set ratings/counts. No ranking, quality labels or automated moderation judgments.

**Expect:** each party can submit one eligible review, and the safe profile reflects the correct role totals after retries and rebuild.

**Check/debug:** test two simultaneous reviews in the same direction and compare projections before/after rebuilding. If a split outcome is unresolved, use the approved finalization/closure rules rather than assuming any wallet credit unlocks reviews.

## Step 7 — finish operations metrics and actionable exceptions

**Files:** existing ops handlers and narrow read RPCs, metrics definitions, exception/replay tests, docs/runbook.md and permission map.

**Prompt**

> Implement only Phase 5 Step 7. Reuse current case queues, identity reviews and financial inspection; fill remaining backend contract gaps for later admin screens. Add bounded, scoped, MFA-and-current-grant metric reads. Define time window, poster type, attribution and denominators explicitly. Keep funded jobs distinct from assignments; compute GMV from verified collections without double-counting allocations; reconcile commission, provider/refund/delivery costs and contribution margin against authoritative records. Distinguish first response, initial decision and final settlement, and use the approved completed-job and repeat-participation definitions. Mark synthetic outputs. Report unknown/failed/exhausted movements and delivery jobs with safe IDs and actionable next steps. If exposing manual replay, restrict and audit it and reuse the original operation identity after appropriate reconciliation. Read-only financial inspection cannot replay or approve movement; replay cannot create a new authorization, alter a ledger or bypass the existing two-person/appeal rules. Prove permissions, correct totals on hand-calculated fixtures, and no duplicate effect after retry. Do not build admin screens or add another reporting store unless necessary.

**Expect:** a granted synthetic reviewer can read correctly scoped operational information; unrelated actors and insufficient MFA/grants are denied.

**Check/debug:** reconcile a fixture with multiple workers, a split refund and simulated fees. If a report totals both job funding and per-slot principal as GMV, correct the aggregation. If a replay would start a replacement payment, stop and preserve the exception for reconciliation.

## Step 8 — full local acceptance and documented closeout

**Files:** scripts/check-phase5.mjs (or equivalent existing-wrapper extension), relevant test scripts, docs/phase-5-evidence.md, docs/phase-5-milestone.md, development log, feedback notes and launch gates.

**Prompt**

> Complete only Phase 5 Step 8. Map F7/F9/F11 and remaining F12 contracts to actual database, handler, local Edge HTTP and socket evidence as applicable. Run the focused checks, then the complete updated local phase suite once with Phase 1–4 regression coverage and pinned tools. Verify actual saved-message/reconnect, private joins and live revocation; notice deduplication and failure; 24/48/72-hour timing and terminal-state suppression with no financial writes; eligible/ineligible reviews, projection rebuild and moderation scope; metric correctness and authorized original-identity replay. Demonstrate one meaningful new negative test where needed, without repeating old controlled mutations. Record timings/conditions, versions, migration/test counts, revision or safe manifest, fixture cleanup and stopped services. Name any untested HTTP/socket path and keep that scope partial. If the prior history-read 503 recurs, capture safe diagnostics and investigate; do not claim a fix merely because it doesn't recur. Update the runbook and prepare the internal milestone packet. Do not start Phase 6, deploy, use a real provider or build production UI.

### What counts as done

| Area | Required local evidence |
| --- | --- |
| Messaging | Durable acknowledgement, ordered replay, read-state and closed-thread rules through actual APIs. |
| Realtime | Actual permitted socket delivery and denied joins, existing-connection revocation protection, reconnect without lost or duplicate saved messages. |
| Delivery | Durable intent, independent in-app state, deduplication, recoverable/exhausted jobs; local email capture clearly labelled. |
| Reminders | Correct due times, restart/retry, suppression, and no new financial authorization or movement. |
| Ratings | Both directions, eligibility, immutability, reporting/moderation and repeatable counter rebuild. |
| Ops | Safe metrics by poster type, actionable exceptions and scoped/audited original-identity replay where exposed. |
| Regression | Full suite passes together; clean migrations/types, local fixture cleanup and stopped services. |

### Milestone and weekly documentation

After major messaging, reminder and ratings milestones, record the actual evidence, one limitation and one lesson. At closeout prepare a brief weekly update and one or two content ideas, such as how chat catches up after a connection drop or why reviews unlock only after a completed job. A safe demo can use two synthetic test clients; label it local and avoid showing tokens, private conversations, case records, staff identities or internal thresholds. If useful, ask students what reminder or review information would help them; record only feedback actually received. Prepare the packet for Community and Growth review. Nothing is sent or published.

Bring back the agent summary and Phase 5 evidence/milestone before asking to continue. Phase 6 covers broader backend verification, measured optimization and recovery. Frontend implementation follows in Phase 7.

## Reference for Step 3

[Supabase Realtime authorization](https://supabase.com/docs/guides/realtime/authorization#updating-rls-policies) documents cached channel policies. [Database Broadcast guidance](https://supabase.com/docs/guides/realtime/subscribing-to-database-changes#using-broadcast) describes private subscriptions. Use restrictive project-specific policies and prove behaviour on the pinned runtime; do not copy a permissive sample policy into this application.
