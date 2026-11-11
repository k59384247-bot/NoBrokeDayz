# Phase 3 local closeout

**Prepared:** 5 November 2026  
**Status:** Local synthetic backend closeout recorded. No Phase 4 work, production UI, hosted test or live money movement was started.

## Milestone summary

The local backend can track a funded demo job, keep one funded allocation per slot, accept eligible student applications, record participant work stages, calculate the worker's earnings after commission, and simulate a manually requested bank payout. A verified synthetic student and a verified synthetic partner each completed the poster journey through actual local Deno Edge HTTP. These are synthetic local behaviors, not real identity verification or banking.

The updated Phase 3 wrapper passed together on 5 November 2026, from `2026-11-05T12:25:10.220Z` to `2026-11-05T12:40:56.496Z` UTC. It used Node `v22.23.2`, npm `10.9.8`, Deno `2.1.4`, Supabase CLI `2.122.0` and PostgreSQL major 17. The clean rebuild applied 31 migrations and passed 768 pgTAP assertions in 17 files plus 4/4 identity registration checks. Marketplace handler boundaries passed 33/33; fake-payment contract tests passed 17/17. Phase 1/2 checks, app/all-Edge typechecks, lint, formatting, runtime build and local identity/storage/profile/staff checks also passed in that wrapper.

The controlled regression intentionally removed a protected-principal liquidity check on 4 November; its named pgTAP invariant failed as expected, and the migration was restored byte-for-byte. This run reused that recorded failure/restore evidence as requested and did not repeat the mutation. The wrapper rebuilt local state, removed marked synthetic fixtures and stopped local services. No hosted reset, CI run, push or deployment occurred.

The local fixtures were synthetic. At the discovery measurement point, the one available row returned in 63.4 ms through loopback Edge HTTP; the tiny-fixture query plan took 0.322 ms. These are local smoke measurements only, not Nigerian-network or production performance evidence. There was no Git HEAD. The safe source manifest is [phase-3-source-manifest.sha256](phase-3-source-manifest.sha256); its current SHA-256 is recorded in [phase-3-evidence.md](phase-3-evidence.md).

## Command-to-evidence map

**Evidence labels:** **DB** means SQL/pgTAP and database-role tests; **handler** means the shared Edge handler exercised with injected Auth/RPC dependencies; **Edge HTTP** means a real local Deno function request through the Supabase API gateway with local Auth/Postgres. The local fake provider is a separate loopback fixture. A boundary test does not imply an Edge HTTP journey.

| Implemented command or read                                                                                 | Database evidence                                                                                                                                     | Shared-handler evidence                                                                                                                                                                                 | Actual local Edge HTTP evidence                                                                                                                                                   | Closeout status                                                        |
| ----------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| `create_job_draft`, `update_job_draft`                                                                      | `012_marketplace_drafts_funding.test.sql` proves appended immutable terms, unrelated-actor denial and stale funding-state responses                   | `command-boundaries.test.mjs` checks the actor-bound RPC arguments and safe not-found/stale responses                                                                                                   | `check-marketplace-local.mjs` verifies owner edit appends version 2; unrelated user, pending, unknown and funded edits are denied; prior terms stay unchanged                     | Pass for the tested local command paths                                |
| `fund_job`, `funding_status`                                                                                | `011_local_payment_simulator.test.sql`, `012_marketplace_drafts_funding.test.sql`                                                                     | `command-boundaries.test.mjs` covers saved-operation initialization, browser return pending, unknown response, idempotency conflict and disabled mode                                                   | `check-marketplace-local.mjs` funds both posters' jobs and checks status through `marketplace-command`                                                                            | Pass for local simulation                                              |
| `discover_jobs`, `job_detail`, `my_job_detail`, `my_job_history`                                            | `013_marketplace_discovery.test.sql`                                                                                                                  | `read-boundaries.test.mjs` covers actor-derived discovery, bounded/filter-stable cursors, safe fields and owner history                                                                                 | `check-marketplace-local.mjs` exercises discovery, details, owner history and expiry visibility                                                                                   | Pass for tested synthetic actors/data                                  |
| `apply_to_job`, `accept_application`                                                                        | `014_marketplace_applications.test.sql`                                                                                                               | `application-boundaries.test.mjs` checks student actor and owning-poster acceptance                                                                                                                     | `check-marketplace-local.mjs` exercises application and acceptance; two independent database processes race the final-slot command after applications are created                 | Pass; race is DB-command concurrency, not simultaneous Edge HTTP calls |
| `reject_application`, `withdraw_application`                                                                | `014_marketplace_applications.test.sql` proves pending transitions, immutable capacity, read-only threads and no assignment for unselected applicants | `application-boundaries.test.mjs` checks distinct actor-bound commands                                                                                                                                  | `check-marketplace-local.mjs` verifies poster/applicant permissions, denials after acceptance, retained read-only messages, and unchanged rejection/withdrawal money and capacity | Pass for the tested local command paths                                |
| `job_applications`, `my_applications`, `application_thread`, `send_application_message`, `mark_thread_read` | `013_marketplace_discovery.test.sql`, `014_marketplace_applications.test.sql`                                                                         | `read-boundaries.test.mjs`, `application-boundaries.test.mjs` check participant scope, sequence and saved-message acknowledgement                                                                       | `check-marketplace-local.mjs` reads applicant/thread data, sends/replays messages and updates the read cursor through Edge HTTP                                                   | Pass for tested participant journey                                    |
| `start_assignment`, `submit_assignment`, `confirm_completion`, `open_assignment_hold`, `assignment_status`  | `014_marketplace_applications.test.sql`                                                                                                               | `assignment-boundaries.test.mjs` checks actor/state and scoped hold/status shapes                                                                                                                       | `check-marketplace-local.mjs` exercises worker start/submit, owner confirmation, hold/status and a concurrent confirm-versus-hold Edge HTTP race                                  | Pass; each allocation remains independent                              |
| `get_my_wallet`, destination proof/change, `authorize_withdrawal`, `request_withdrawal`                     | `010_financial_foundation.test.sql`, `015_wallet_withdrawals.test.sql`                                                                                | `wallet-boundaries.test.mjs` covers fresh authentication, actor/proof binding, altered fields and safe projections                                                                                      | `check-marketplace-local.mjs` reads wallet, creates immutable synthetic destination versions, races reservations and exercises success/failure/reversal/unknown payout recovery   | Pass for the local simulator only                                      |
| Notification `list`, `mark_read`                                                                            | `016_notices_inspection_reconciliation.test.sql`                                                                                                      | `operations-boundaries.test.mjs` checks recipient-only safe reads and mark-read scope                                                                                                                   | `check-marketplace-local.mjs` reads poster/worker notices, denies cross-recipient reads and marks the worker's own notice read                                                    | Pass for in-app persistence; no email/SMS delivery claim               |
| Financial inspection `trace`, `reconcile`                                                                   | `016_notices_inspection_reconciliation.test.sql`                                                                                                      | `operations-boundaries.test.mjs` checks AAL2, server-sourced simulator values and no journal/hold mutation command                                                                                      | `check-marketplace-local.mjs` traces a job, reconciles simulator/ledger totals, reads the saved run and checks audit integrity through local Edge HTTP                            | Pass as read-only local/test inspection                                |
| Provider callback, operation runner and original-operation lookup                                           | `011_local_payment_simulator.test.sql`; money effects also covered by `012` and `015`                                                                 | `payment-adapter.test.mjs`, `payment-callback.test.mjs`, `payment-operation-runner-http.test.mjs` cover simulator outcomes, spoof/replay protection, receipt-before-ack and persisted-job authorization | `check-marketplace-local.mjs` reaches local callback/runner paths and proves lost-response lookup uses the original operation identity                                            | Pass for the local fake contract; no Bachs evidence                    |

### Focused verification and failure record

All three previously partial actions now have direct local Edge HTTP coverage, and `update_job_draft` also has dedicated shared-handler coverage. The final wrapper passed with the expanded journey. No core assertion failed in that wrapper. Earlier focused runs exposed incorrect expectations in the test harness (privacy-safe `404` for an unrelated actor and the existing one-journal allocation reclassification); those expectations were corrected before the final run. The separate controlled liquidity mutation failure/restore remains the previously recorded 4 November evidence and was not repeated.

Database evidence uses `anon`/`authenticated` permission assertions and controlled SQL transactions; handler-boundary evidence invokes the shared handler without serving Deno; actual Edge HTTP evidence is limited to the requests described above. No privileged-owner-only assertion is used as proof of browser permission behavior.

## Fake provider and Bachs boundary

The tested provider is `tests/fixtures/payments/simulator.mjs`, a deterministic loopback fake used by `supabase/functions/_shared/payment-adapter.mjs`. Tests program pending, success, known failure, reversal, unknown and timeout-after-acceptance outcomes; duplicate/out-of-order events; lost responses; lookup of the original collection/payout identity; and separately accounted synthetic provider fees. Synthetic bank destinations are labelled `simulator_only`. No real funds, bank account or provider call exists in this evidence.

No Bachs sandbox or live request, SDK, credential, webhook verification, fee, settlement, payout, holding or refund behavior was tested. The fake's HMAC is only a simulator protocol and says nothing about Bachs webhook signatures. The documented NGN bank-transfer refund limitation and one-refund-per-payment constraint remain unresolved against the product's promised refund/split handling; see [bachs-payments-reference.md](bachs-payments-reference.md).

## Product and launch boundaries preserved

- No automatic release/refund after application deadline, needed-by time, silence, reminder or cron.
- No additional poster fee. Provider costs use separately recorded platform capital/reserve; local amounts and fake-provider limits are not live caps or provider minimums.
- Partners can hire but cannot apply, start or submit work. A job with three slots has three allocations and, after three acceptances, three separate assignments.
- Funded and accepted terms remain immutable. Listing state, assignment work state and hold status remain separate.
- A held allocation stays held. There is no Phase 4 cancellation, refund/split, appeal window, case investigation/finalization, independent human money-decision approval, or admin financial outcome. Timers and generic staff inspection cannot resolve a hold.
- Phase 2's five-invalid-phone-code limit and scanner/sanitizer-based identity-file promotion are still blockers. Real UNILAG domains, real email/SMS, privacy/retention approval, staffing and real identity intake remain gated.
- No hosted service, hosted CI, production deployment, production UI, real payment, or Nigerian-network performance claim was created.

## Internal weekly update packet — draft only

**Status:** Prepared for Community and Growth review. Not sent or published.

**Redacted local test capture:**

```text
local simulation — no real money moved
Phase 3 wrapper: PASS (2026-11-05 12:25:10–12:40:56 UTC)
Database: 31 migrations; 768 pgTAP assertions / 17 files; identity registration 4/4
Marketplace boundaries: 33/33; fake payment contract: 17/17
update_job_draft, reject_application, withdraw_application Edge HTTP: PASS
Student and partner poster Edge HTTP journeys: PASS
Final local rebuild, synthetic fixture cleanup, services stopped: PASS
Controlled mutation: prior 4 November failure/restore evidence reused; not repeated
Bachs sandbox/live, hosted CI, deployment and real money: NOT TESTED
```

This is a redacted summary of the recorded wrapper result, not a raw CLI transcript. It contains no synthetic credentials, private request, banking receipt or provider secret.

> **Completed:** The local backend can track a funded demo job, assign separate workers to funded slots, record submitted work, calculate worker earnings, and show a manual simulated payout. Student and partner poster journeys passed the local synthetic test suite. **No real money moved.**  
> **Limitation:** Payments use a local fake provider; production screens, Bachs integration and case/refund outcomes are not ready. No local test moved real money.  
> **Lesson:** When a payment response is lost, the safe retry looks up the original saved operation; creating a new payment could duplicate the charge.  
> **Next:** Preserve the identity, provider, privacy, operational and hosting gates before any later live work.

### Content opportunities for review

1. Explain that applying does not reserve a slot; the poster's acceptance assigns one funded slot to one worker.
2. Explain the difference between available earnings and a completed simulated payout. Label every example **local simulation — no real money moved**.

No screenshot or recording was produced. A redacted runner summary may be prepared for review; omit tokens, local keys, synthetic passwords/codes, private requests, bank fields, staff identities and detailed security thresholds. Do not use a fake bank receipt or present the simulator as Bachs.

### Feedback question to ask only in a future session

What would help students understand the difference between a job's gross pay, their after-commission earnings, and a pending versus completed payout?

No feedback session has occurred and no answer or product decision is claimed.

## Handoff

Phase 3 is closed for local synthetic implementation evidence, including the three previously partial command journeys. Do not start Phase 4, build production UI, contact providers, publish this packet or treat this record as launch approval. Review the gates in [launch-gates.md](launch-gates.md) and the trace/recovery instructions in [runbook.md](runbook.md) before planning later work.
