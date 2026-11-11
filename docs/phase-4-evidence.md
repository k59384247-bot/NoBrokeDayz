# Phase 4 evidence

Application root: `/Users/mac/Desktop/NoBrokeDayz`.

## Step 1 — planning contracts and owner choices

The owner approved the three Step 1 recommendations on 5–6 November 2026:

1. Two distinct qualified approval records total; the qualified proposer may provide the first, and a different qualified person must provide the second.
2. No action restores only the internal hold classification through a balanced compensating journal; it creates no worker award, poster refund, payout or external payment.
3. Mixed batch cancellation returns one result per slot, allowing eligible slots to proceed independently.

The conflicting source wording and implementation boundaries are recorded in [case-and-cancellation-contracts.md](case-and-cancellation-contracts.md) and [decisions.md](decisions.md). The approved rule supersedes the older stricter reading in `AGENTS.md` and the payment note, which were updated. No settled commission, vendor or product rule was reopened.

## Phase 3 baseline reviewed

The reviewed Phase 3 record reports 31 migrations, 768 pgTAP assertions in 17 SQL files, 4/4 identity registration checks, 33/33 marketplace boundary tests and 17/17 simulated payment tests. It proves ordinary local journeys and the confirmation-versus-hold race. It does not prove resolution, cancellation, refunds, decisions, approvals, appeals, real provider behavior or case-file scanning. No Bachs refund route is assumed.

## Step 2 — current implementation

Migration `20261106000100_assignment_cases_and_scoped_timeline.sql` adds an active case record separately from immutable hold reports, backfills existing reports, stores accepted terms/version and the case-opening conversation sequence, and adds append-only shared timeline and access-audit records. The active case, rather than the existence of an old `status='open'` report, is the effective case predicate. The allocation and its existing journal remain the source for held amounts; wallet and reconciliation continue to use that canonical financial state.

Step 2 supports only `open → under_review`. It adds a bounded reviewer queue, explicit self-assignment/transfer, participant-safe case detail and assigned-reviewer detail. Reviewer reads require active account, current `dispute_review` grant, AAL2 and current case assignment; assignment parties are excluded. Financial inspection alone does not grant case access. Suspended parties can open/read their own eligible funded assignment case without regaining other marketplace or money actions.

Case evidence policy defaults are configurable at five files per case and 5,000,000 bytes per file, separate from the three-file identity limit. Actual case upload/download and scanning are not implemented. Step 2 adds no cancellation, decision, appeal, finalization, refund or external payment operation.

### Checks completed

- `npm run check:database` under the local Supabase stack: all migrations reset cleanly; **793 pgTAP assertions across 17 SQL files** passed, including case lifecycle, suspended-party access, scoped reviewer access, queue, terms/conversation snapshot, audit, idempotency, notification and privacy checks. The wrapper also confirmed generated public database types match `lib/database.types.ts`.
- `npm run test:cases`: **10/10** case-handler boundary tests passed.
- `npm run test:marketplace`: **33/33** marketplace boundary tests passed.
- `npm run typecheck:edge`: all Deno function entrypoints, including `case-read` and `case-command`, passed.
- `npm run typecheck` with the pinned Node `22.23.2`: passed.
- `npm run lint` and `npm run format:check`: passed.
- `npm run check:marketplace` with Node `22.23.2`: the full local Auth-backed Edge journey passed. It includes participant case-detail success and AAL1 denials for reviewer detail and assignment. Reviewer AAL2 queue, detail, assignment, scoped access and audit are proven by the database and handler tests; the local HTTP journey does not yet create an MFA reviewer and exercise those successful staff routes end to end.

All fixtures are synthetic. No live funds, Bachs endpoint, real identity files, hosted project or external notice delivery were used.

## Step 3 — voluntary cancellation and refund authorization

Migration `20261106000200_assignment_cancellations.sql` adds the four actor-scoped cancellation commands and immutable audit/idempotency records. It stores current allocation-to-assignment bindings separately from historical assignments so a pre-start abandonment can return the same held slot to discovery without rewriting the abandoned assignment, original application, thread or accepted terms. Reused slots have one current binding; prior assignments cannot start or release the allocation.

An owning active poster with `can_hire` can cancel selected unassigned funded slots. Mixed batches return a result for each slot. Each eligible slot creates one exact-gross `authorized` refund payable and one balanced journal entry. A pre-start assignment cancellation requires the requester's consent and a second explicit consent bound to the same assignment, accepted terms hash/version and cancellation version. The second consent creates one payable. Worker abandonment returns held principal to the unassigned slot with a balanced internal reclassification and no refund. None of these actions create a case. The poster wallet exposes the authorized payable separately from held funds; the payment runner still has no refund operation, so this step does not claim settlement.

### Step 3 checks

- `npm run check:database` under local Supabase: migrations reset cleanly; **833 pgTAP assertions across 17 SQL files passed**. The wrapper also verified the generated public database types match `lib/database.types.ts` and removed its synthetic Auth fixtures.
- `npm run test:marketplace`: **35/35** handler/read boundary tests passed, including actor derivation and strict cancellation request validation.
- `npm run check:marketplace` with Node `22.23.2`: the full local Auth-backed Edge journey passed. The new HTTP checks raced acceptance against unused-slot cancellation, work-start against worker abandonment, and work-start against final mutual consent; each saved exactly one valid outcome. The database suite deterministically replayed completed consent and verified no second payable, journal or finalization; the HTTP journey repeats that replay when final consent wins its race. The journey also verified mixed per-slot results and authoritative allocation, assignment-binding and payable state.
- `npm run typecheck` with Node `22.23.2`, `npm run typecheck:edge`, `npm run lint` and `npm run format:check`: passed.

All added payment scenarios use synthetic local collection settlement. They do not contact Bachs, request a refund, simulate a refund settlement or assert funds reached a poster's bank. The Edge check cleared its synthetic database and stopped local Supabase after completion.

## Step 4 — scoped case investigation and evidence intake

Migration `20261106000300_case_investigation_and_evidence.sql` adds case triage, reviewer assignment checks, simulated/manual contact logs, targeted information and evidence requests, participant responses, private fact findings and reviewer notes, plus non-response assessments. Non-response requires two recorded no-response attempts through two different channels, substantive reasoning and a current, separate senior signoff. Contact records are explicitly labeled as local/manual logs; they do not claim a real call, email or visit happened. Conduct/safety cases get urgent review priority without the reason category choosing a money outcome.

The `case-read`, `case-command` and `case-evidence` Edge routes return the complete authorized overview and accept scoped investigation actions. Participants see only their own requests, replies and file metadata; staff notes and contact history stay private. Staff access requires AAL2, an active `dispute_review` grant and current case assignment. Metadata reads and byte downloads are separately authorized and audited. Participants with suspended accounts retain only their narrow case-support access.

Dispute files use separate configurable limits from identity files: defaults are five files per case and 5,000,000 bytes per file; the engineering ceiling is 25 files and 100,000,000 bytes per file. Browser access to the private quarantine bucket is denied. Actual uploaded files remain quarantined and cannot be downloaded or promoted because a real safety scanner is not available. The successful download check uses an isolated `synthetic_test` ready-file fixture only; it does not represent a scan or user upload.

### Step 4 checks

- `npm run check:database` with local Supabase: **862 pgTAP assertions across 17 files passed**; migrations reset cleanly and generated public database types match `lib/database.types.ts`.
- `npm run test:cases`: **15/15** handler and evidence boundary tests passed. `npm run test:marketplace`: **35/35** marketplace boundary tests passed.
- `npm run check:marketplace` with Node `22.23.2`: the Auth-backed local Edge journey passed the assigned-reviewer investigation flow, out-of-scope denial, safe participant overview, idempotent evidence upload, actual-upload quarantine, quarantine download denial, synthetic-ready scoped download and AAL1 participant response. The broader marketplace, payment-simulator and cancellation regression journey also passed and cleaned up its local fixtures.
- `npm run typecheck`, `npm run typecheck:edge`, `npm run lint` and `npm run format:check`: passed with Node `22.23.2`.

Step 4 adds no case decision, appeal, refund authorization/settlement, real contact delivery, safety-scan bypass or retention period. The local contact records are simulations, external notifications are not claimed as delivered and no Bachs route is involved.

## Step 5 — case decision proposals and approvals

Migration `20261106000400_case_decisions_and_approvals.sql` adds immutable case decision versions, two-record independent financial approvals and a separate non-response senior-signoff record. The assigned proposer must have active `dispute_review` and `financial_approve`, AAL2, active account status and a trusted human principal, and cannot be a case party. The proposal creates approval record one. A different currently qualified human supplies record two. Multiple grants held by one identity do not satisfy the distinct-person check; service and unknown principals are rejected. `financial_inspect` remains read-only.

Decision versions bind the reason, exact gross split and derived recipients, accepted terms, decision evidence snapshot, snapshot hash and decision hash. All four outcomes—full worker award, full poster refund, split and no action—conserve the exact allocation gross. Commission is rounded half-up at 5% of gross awarded to the worker only. Editing the recipient, outcome, amounts, reason or evidence basis creates a new immutable version and cannot carry approvals forward. A non-response decision also requires a separate current AAL2 human with `case_senior_signoff`, distinct from the parties, assigned reviewer and proposer; the sign-off binds to the exact decision version and current non-response assessment.

Step 5 stops before publication or movement. The second approval changes the staff case to `decision_made`, while the participant-safe projection remains at its pre-decision stage until Step 6 durably notifies both parties. No decision notice, 72-hour clock, appeal, journal entry, hold release, award release, refund payable, provider operation or external payment is created here. The approved no-action internal classification journal remains for later manual finalization.

### Step 5 checks

- `npm run check:database`: local migrations reset cleanly; **902 pgTAP assertions across 17 SQL files passed**, and generated public types matched `lib/database.types.ts`. Database coverage includes the four outcomes, exact split/commission, AAL2, active grants, case-party denial, service principal denial, revoked grants, duplicate/same-person approval denial, stale versions and keys, separate senior sign-off, participant decision hiding and unchanged journal/payable/held state.
- `npm run test:cases`: **20/20** handler and response-boundary tests passed, including spoofed actor/role/recipient/private-note rejection and decision response allow-list/conservation checks.
- `npm run typecheck:edge`, `npm run lint` and Prettier checks passed. The Auth-backed local `npm run check:marketplace` journey exercised a split proposal, AAL2 distinct-person approval, duplicate/forged request denial and the same held financial state before and after approval; the broader marketplace and cancellation regression journey cleaned up its synthetic data and stopped local Supabase.

Synthetic human-principal markers establish only local command authorization. No staffed live operations, external notice delivery, appeal workflow, manual finalization, refund progress/settlement, Bachs behavior or real-money movement is claimed.

## Step 6 — durable decision notices and appeals

Migration `20261106000500_case_decision_notifications_and_appeals.sql` publishes only an approved decision. In the same database transaction, it creates one shared decision event, durable in-app notices for both parties, and an immutable publication record containing the decision version/hash, shared notification time and a deadline exactly 72 hours later. The initial clock is not reset by email, opening a notice, later evidence or a changed appeal outcome. Email remains supplementary and is not represented as sent.

Appeal receipt is a separate server-timestamped command that commits before case-lock processing. The server accepts a party's single appeal only when receipt time is strictly before the stored deadline; clients cannot provide or backdate the time. Processing then locks and updates the case. This preserves simultaneous appeals and prevents a timely receipt from losing while its state update waits. Participant responses expose only that party's own statement plus whether the other party appealed. Timely appeals and outstanding appeal evidence requests block later finalization; the held allocation and all financial state remain unchanged in this step.

An active, human appeal reviewer must have current `case_appeal_review`, `dispute_review` and `financial_approve` grants, AAL2 and the current appeal assignment. The reviewer cannot be a case party or the initial reviewer. Appeal evidence requests and responses are versioned and keep their own evidence snapshot; actual uploads remain quarantined. An appeal may uphold the effective decision or select a later independently approved decision version. A changed outcome uses the same two-person approvals and any required version-bound non-response senior sign-off; it does not restart the initial appeal clock. Both parties receive the same allowed appeal-result notice. No appeal command releases funds, creates a refund payable or closes the case.

The private finalization gate reports whether the initial window is open, a timely appeal is unresolved, an appeal evidence request remains open, or the case is eligible for later review. It is not exposed as a client clock override or money command. Ordinary poster completion remains independent of the 72-hour appeal period.

### Step 6 checks

- `npm run check:database`: migrations reset cleanly; **917 pgTAP assertions across 17 SQL files passed**, including durable notice pairing, exact 72-hour storage, before/exact/after deadline behavior, strict server receipt, two-party and duplicate appeal behavior, held-money invariants and receipt processing idempotency. Generated public types matched `lib/database.types.ts`.
- `npm run test:cases`: **24/24** case handler/read tests passed, including receipt-before-processing order, timestamp spoof rejection, late appeal support response and participant projection privacy.
- `npm run check:marketplace` with Node `22.23.2`: the full Auth-backed local Edge journey passed, including parallel receipt-versus-case-lock processing, simultaneous worker/poster appeals, private statements, separate appeal reviewer, quarantined appeal evidence, participant response and changed outcome with fresh approvals. The broader marketplace/payment regression journey also passed and cleared its synthetic data.
- `npm run typecheck`, `npm run typecheck:edge`, `npm run lint` and `npm run format:check`: passed after regenerating `lib/database.types.ts`.

All staff and evidence scenarios are synthetic local fixtures. This step adds no real email delivery, safety-scan bypass, refund processing, Bachs route, automatic timer action, manual finalizer, journal movement or external payment.

## Step 7 — manual case finalization

Migration `20261106000600_case_finalization.sql` adds one explicit finalizer behind `case-command`. It requires the current assigned human reviewer, AAL2, active `dispute_review` and `financial_initiate` grants, plus the version's two current independent human approvals and any required separate senior sign-off. In one locked transaction it rechecks the published decision version, case/allocation binding, held principal, appeal deadline, every timely appeal and open appeal evidence request. A server timer or runner cannot call this command or create its authorization.

Execution, case closure and refund settlement remain distinct. Full and split awards credit only the approved worker net and 5% commission on awarded gross, and store a durable case-award authorization. A refund portion becomes an `authorized` poster refund payable; no refund provider operation, poster wallet top-up or worker bank payout is created. Full refund cancels the assignment. No action leaves the assignment at its exact prior work stage and posts the approved balanced internal reclassification from dispute-held to assigned principal; it creates no award or refund. Immutable report, hold, decision, approval, appeal and assignment history remain available through the safe case view.

The local case response reports `finalization_status=executed` separately from `status=closed`, and reports a refund only as `authorized` until a later settlement step confirms it. An idempotent replay returns the same saved execution; another key cannot execute a conflicting outcome. Failed gates roll back journals and state changes together. Job history reports completion only after at least one completed earnings allocation and every funded allocation has reached the completed earnings state; an authorized refund is not treated as settled.

### Step 7 DB / handler / Edge acceptance evidence

| Boundary         | Implementation                                                                                                                                                                                                      | Acceptance evidence                                                                                                                                                                                                                                                                                                                                                                    |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Database command | `finalize_case_for_actor_at` is private and its test-only historical-time argument is granted only to `postgres`; `server_finalize_case_for_actor` has no timestamp override and is granted only to `service_role`. | Tests deny missing/revoked finalizer grants, unresolved appeals, early execution and stale versions; only one case finalization is stored. A local split fixture verifies NGN 3,000 principal = NGN 2,000 worker gross + NGN 1,000 refund; worker net is NGN 1,900 and commission NGN 100. No-action verifies one balanced internal classification journal and normal work can resume. |
| Edge handler     | `case-command` accepts only `decision_version` and `expected_case_version`, derives the actor from Auth, requires AAL2 and returns an allow-listed result without journal IDs or private notes.                     | Unit tests verify the RPC mapping, exact split arithmetic and AAL1 denial. The Auth-backed local Edge journey confirms an assigned appeal reviewer is denied while the real 72-hour window remains open and held funds stay unchanged.                                                                                                                                                 |
| Participant read | `case-read` adds the immutable finalization summary to the existing case projection.                                                                                                                                | Unit and database checks ensure participants see `authorized`, never `settled`, and no staff or journal identifiers.                                                                                                                                                                                                                                                                   |
| Appeal ordering  | The durable receipt RPC and finalizer serialize on a per-case database lock; the finalizer takes it after the case row, and receipt time is assigned only after the receipt command gets the lock.                  | The database acceptance suite covers the persisted receipt gate, strict deadline rules and unresolved-appeal denial; receipt processing stays a separate action.                                                                                                                                                                                                                       |

### Step 7 checks

- `npm run check:database`: all migrations reset cleanly; **964 pgTAP assertions across 17 SQL files passed**, including the NGN 3,000 / NGN 2,000 split, full-refund assignment cancellation, independent senior sign-off, both appeal outcomes, duplicate execution, pending refund state, and no-action restoration. Generated public types match `lib/database.types.ts`.
- `npm run test:cases`: **27/27** case handler/read tests passed.
- `npm run test:identity-registration`: **4/4** Auth boundary checks passed as part of the database check.
- `npm run check:marketplace` with Node `22.23.2`: Auth-backed local Edge journey passed, including the early finalization denial; the wider marketplace, payout simulator and cancellation regressions also passed.

The successful historical finalization is exercised in the local SQL suite through the `postgres`-only helper. The public Edge command is tested against the actual stored deadline while the appeal window remains open and denies execution before eligibility; no production clock override or 72-hour wait is used.

Only synthetic local staff and payment facts are used. No provider refund settlement, Bachs integration, worker withdrawal, real staff operation or timer-authorized case execution is claimed.

## Step 8 — simulated refund settlement

Migration `20261106000700_refund_settlement_runner.sql` extends the existing durable payment operation queue and fake provider. It creates no second runner or ledger. An authorized cancellation or finalized-case payable is the only source for an operation. Before the external simulator call, an immutable mapping saves its payable, allocation, funding intent/attempt, source collection operation and original provider reference, exact principal, expected fee, effect identities and request hash. A per-source lock reserves all authorized and already-mapped amounts against that charge; the cumulative amount cannot exceed collected gross, and each allocation gets at most one operation.

The existing runner starts an operation only when its source collection is confirmed successful and available, secured principal is present, and platform fee cash can cover expected provider costs. Platform reserves can cover fee gaps, never uncleared or otherwise protected principal. The fake provider independently requires an available source collection and caps all accepted slot refunds against its collected amount. Multiple partial outcomes are simulator features only.

The runner looks up the same client reference before creating or retrying. Provider acceptance remains `processing`; a timeout or unresolved lookup remains `unknown`; a confirmed failure leaves the poster's payable visible. Neither state creates a fresh refund identity. Only a validated `settled` result with available settlement posts the exact payable reduction and a separate platform refund-fee expense. That journal clears the payable once. A verified reversal creates an immutable open incident for read-only reconciliation; it does not edit earlier journals or debit an unrelated wallet. Durable in-app progress and the case view distinguish authorized, queued, processing, unknown, failed, settled and reversal review. Provider settlement is not described as proof of bank receipt.

### Step 8 DB / runner / simulator acceptance map

| Boundary                               | Implementation                                                                                                                                                                                                                                                | Acceptance evidence                                                                                                                                                                                               |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Database authorization and reservation | `prepare_local_refund_operations`, `try_start_queued_refunds_for_liquidity`, and `server_claim_payment_operation_for_runner` materialize only existing payables, lock per funding intent, preserve the source charge reference, and share the existing queue. | Tests prove an uncleared source cannot dispatch, each slot has its own exact mapping, total authorized/reserved principal stays within the collection, and a platform fee shortfall leaves payables queued.       |
| Database result application            | `server_complete_refund_operation_for_runner` checks lease, saved operation, client key, source reference, amount, currency, expected fee, settlement and result hash before changing progress or posting the balanced settlement journal.                    | Tests cover settled, failed, unknown, retry with the same operation, duplicate callback, expired lease rejection/reclaim, independent slot statuses, fee expense, and reversal incident without journal mutation. |
| Edge runner                            | `payment-operation-runner` explicitly routes `refund` to the refund result RPC; the shared runner calls `lookupRefund` first and only calls `createRefund` for that saved identity.                                                                           | Payment handler/unit checks verify exact source reference, stable key reuse, timeout-after-acceptance lookup and acceptance does not settle.                                                                      |
| Local provider                         | `createRefund` / `lookupRefund` use the existing loopback simulator at `/v1/refunds`; fixture outcomes can vary by slot.                                                                                                                                      | The fake refuses unsettled sources and rejects cumulative refunds above collected gross. It is synthetic evidence only.                                                                                           |
| Callback and participant reads         | Simulator receipt stores a digest and queues a lookup for a matching existing operation. Wallet/case projections read persisted refund progress.                                                                                                              | Repeated receipts create no operation; failure and unknown remain visible; settled is reported only after the controlled database result.                                                                         |

### Step 8 checks

- `npm run check:database`: fresh local migrations and **997 pgTAP assertions across 17 SQL files passed**. This includes three independent slot refunds against one collected charge, liquidity and fee-reserve gates, settlement/failure/unknown progress, same-operation retry and lease reclamation, duplicate receipt, reversal reconciliation, and a stale settlement after reversal.
- `npm run test:payments`: **19/19** local payment tests passed, including simulator source-settlement enforcement, independent partial outcomes, source-charge caps, timeout-after-acceptance and stable refund lookup.
- `npm run supabase:types`: regenerated `lib/database.types.ts` from the local public schema for the new server-only result RPC.

No actual Bachs request, Bachs refund capability, bank details, live funds or poster bank receipt is tested. Bachs compatibility remains a launch blocker; this simulator does not resolve the documented NGN transfer/refund limitation.

## Step 9 — case and refund traceability

The existing participant case response already carried the published written decision in the shared `decision_notified` event and the current refund progress from `allocation_refund_progress`. Its allow-list excluded private staff notes. The existing reviewer detail required AAL2, a current `dispute_review` grant and the current case assignment; financial inspection remained a separate read-only permission. The gap was after closure: reviewer detail denied the assigned reviewer, and no case response connected the decision proposer and approvers, finalizer and refund operation reference.

Migration `20261109000100_case_refund_traceability.sql` extends only the existing assigned-reviewer read path. A currently assigned reviewer with AAL2 and the current grant can read a closed case and see the decision proposer, both approval actors and times, version/hash, finalizer and execution time, and the saved refund operation/provider reference. The projection reads the immutable decision, approval and finalization records plus existing refund progress/mapping/settlement records; it creates no second audit ledger or refund record. Participants receive no traceability object, staff actor IDs, operation references, internal notes or third-party material. An unrelated participant receives not-found; an unassigned reviewer is denied. `financial_inspect` alone still does not grant case access or money commands.

The focused journey in `scripts/check-marketplace-local.mjs` creates one synthetic job, assignment and dispute through local commands, adds a private staff note, proposes a full refund and records the independent second approval. It verifies that the durable decision notice creates exactly 72 hours, then uses the existing postgres-only historical-time helper to pass the appeal window without adding a user clock override. It finalizes the existing case and processes the already-authorized payable through the existing local refund runner. Participant and reviewer reads, unrelated-access denial and the separate read-only financial operation trace are sent through local Edge HTTP. The same refund operation is observed as unknown, then processing/pending, then settled. Both participants are read at every stage. The simulator settles the refund; this does not prove bank receipt.

### Merchant mismatch investigation and correction — 9 November 2026

The failure was reproduced through local Edge HTTP before changing the claim function. The synthetic collection stored `fake_nbd_local_merchant_v1`; the simulator returned that same identity. Temporary runner diagnostics showed `expected: null` (the claimed field was absent) and `received: fake_nbd_local_merchant_v1`. The runner correctly recorded `merchant_mismatch`, left funding pending and created no funded allocation.

The source was `20261106000700_refund_settlement_runner.sql`: its replacement of `claim_payment_operation_job` added refund fields but omitted the `merchant_identity` returned by the earlier collection implementation. Adapter configuration and the stored collection identity agreed. The mismatch was introduced at the database-to-runner claim boundary. The old unit fixture supplied the missing field itself, and the old SQL funding test supplied the expected merchant directly when completing funding, so neither covered that boundary.

Corrective migration `20261109000200_restore_collection_merchant_claim.sql` restores the persisted merchant identity to the existing claim response. It leaves merchant validation, operation identities, leases, source-refund mappings and financial authorization unchanged. A new SQL assertion reads the actual claimed field: it failed with `have: NULL / want: fake_nbd_local_merchant_v1` before migration and the full focused file passed **75/75** afterward. A runner test independently proves that a missing or different claimed identity still becomes a `merchant_mismatch` exception; no duplicate collection is created.

Verification also exposed a Step 9 response regression: the shared staff-response validator required traceability on the separate appeal-review response, whose existing scoped RPC does not supply it. A focused handler test failed with 503 before correction. Trace validation now applies at the `reviewer_detail` route that owns the new projection; the appeal response continues to exclude initial private notes and trace fields. That test now passes. No appeal permission or financial rule was changed.

### Step 9 checks

- `npm run test:cases`: **28/28** passed, including participant privacy, closed-case trace validation and the existing appeal response without trace fields.
- `npm run test:payments`: **20/20** passed, including missing/different claimed merchant rejection.
- Focused database file `012_marketplace_drafts_funding.test.sql`: **75/75** passed after the corrective migration, including wrong-merchant exception/no-allocation assertions.
- `npm run typecheck:edge` and `npm run lint`: passed. The full TypeScript check previously passed under Node 22.23.2; this correction changes no application TypeScript.
- Local Edge HTTP reached and passed the Step 9 scenario: both parties saw the written decision and authorized/unknown/processing/settled refund status; the assigned AAL2 reviewer traced both approvals, finalizer/time and the same refund reference; unrelated participant/reviewer, AAL1 reviewer and `financial_inspect`-only reads were denied. The assigned AAL2 reviewer was also denied after revoking the current `dispute_review` grant. Private staff notes were excluded from every participant read, and one refund operation was created.
- `npm run check:marketplace`: **passed with exit 0**, including the case/refund scenario, remaining marketplace/finance checks and final reset/shutdown. Two test-harness assumptions surfaced after the new scenario: the original 60-second participant logins expired (HTTP 401), and the first 20-notice page no longer contained an older completion notice. The harness now signs the same synthetic participants in again at the phase boundary and follows the existing notification cursor. Auth expiry and notice page size were not changed.
- Native startup required local runtime filesystem/socket access. Optional analytics/studio/realtime services were excluded after analytics DNS and dependent readiness failures. The Edge readiness wait is bounded at 120 seconds because the 45-second attempt stopped before the local runtime became ready. Required Auth, REST, Storage, database and Edge HTTP remain exercised.
- This verifies the requested case/refund slice and the local signed-checkpoint mechanism described below. Production signer custody, independent checkpoint storage and other unimplemented Step 9 requirements remain incomplete. No hosted services, real provider call or bank receipt was tested. The original local Supabase state was backed up before resets and restored after the final check; the stack was stopped after checkpoint verification.

### Recorded synthetic example

These references came from the final passing Edge HTTP run. The fixture was cleared during cleanup, so they describe that run rather than a live case. A rerun prints new references under `TRACE Step 9 synthetic example`.

| Saved reference       | Observed value                             |
| --------------------- | ------------------------------------------ |
| `case_id`             | `6bab2a9d-e829-4ca0-b136-8251a2251ab6`     |
| `assignment_id`       | `88f3e5cd-3baf-4e68-948f-d1bd55c9205c`     |
| `decision_version`    | `1`                                        |
| `finalized_at`        | `2026-11-09T19:45:20.571Z`                 |
| `refund_operation_id` | `b71aaf85-ecaa-4aa2-b5d3-49e1c49afa0f`     |
| `provider_reference`  | `sim-b6651251-2737-446c-ab2f-c7811a4b7539` |
| `amount_kobo`         | `120000`                                   |

The refund is the full 120,000-kobo principal (NGN 1,200), with zero worker award and zero commission. The same written explanation was visible to both participants: “The reviewed synthetic work record supports returning the held amount to the poster.” The existing runner retained one refund identity through unknown, processing and simulated settlement. The reviewer response and separate finance trace resolved that same saved operation. This establishes local traceability and access control for synthetic records, not real Bachs refund compatibility or bank receipt.

### Standalone empty-chain checkpoint check — 9 November 2026

This earlier standalone check observed an empty local audit chain. It is retained as historical evidence for the standalone checker; the populated Step 10 checkpoint proof below supersedes it for the synthetic case/refund journey.

The checkpoint checker reuses `app_private.financial_audit_integrity` and its existing `financial_audit_integrity_valid()` function. No table, audit ledger, public endpoint or migration was added. It exports only the chain's validity, count and ordered head position/event/hash, canonicalizes the checkpoint JSON, and signs it with Ed25519 outside PostgreSQL. The verifier loads the public key from a separate trusted-key file; it does not accept a key embedded in the checkpoint. The test private key exists only in process memory.

`npm run check:audit-checkpoint` ran against the native loopback database without reset or database writes. The existing chain validator returned valid with **0 events** and head position **0**. The signed empty-chain checkpoint passed verification. Edited checkpoint content, a signature from a second untrusted key, a changed self-consistent chain head and an older signed checkpoint below its retained anchor were rejected. Since this database had no real chain events, the tamper and rollback cases used synthetic in-memory chain states; no real event row was edited, deleted, reordered, or rolled back.

The run passed `npm run test:audit-checkpoint` (**6/6**) and `npm run lint`. The retained test public key and signed checkpoint were written as separate files under the OS temporary directory, outside the repository and database. The signing key was not written or logged. Recorded public-key fingerprint prefix: `5becb20f96a57a9a`; signed checkpoint digest prefix: `1c89e196b4955b06`.

This proves the local signature and retained-anchor checks for a same-workstation test key. It does not prove independent production custody, protection from a workstation/database owner controlling both the signer and storage, or any external witnessing. Production key custody, independent checkpoint retention, retention/rotation policy and a scheduled operational verification remain launch requirements. See the [audit checkpoint runbook](runbook.md#local-signed-audit-checkpoint).

### Phase 4 Step 10 acceptance — 9 November 2026

The complete sequential local acceptance passed with the pinned Node `22.23.2`, npm `10.9.8`, Deno `2.1.4`, Supabase CLI `2.122.0` and PostgreSQL major `17`. The wrapper start/end times were **19:33:13.370Z–19:47:17.425Z** (14 minutes 4 seconds). It applied all **41 migrations**, ran **17 SQL test files / 1,004 pgTAP assertions**, and confirmed generated public database types matched `lib/database.types.ts`.

All stages passed: case handler/read validation (**31/31**), signed checkpoint unit tests (**6/6**), Phase 1/2 regressions and format/lint/Deno/app type checks, marketplace handler boundaries (**35/35**), payment tests (**20/20**), the actual local Auth-backed Deno Edge HTTP journey and terminal migration/type/cleanup pass. The wrapper's recorded durations were 337 ms for case handlers, 277 ms for checkpoint unit tests, 679,176 ms for Phase 1/2, 372 ms for marketplace boundaries, 480 ms for payment tests, 114,299 ms for the local Edge journey, 47,662 ms for the terminal migration/database/type check and 109 ms for the manifest. The wrapper reused the previously recorded Phase 3 controlled failure/restore evidence; it did not mutate a migration to manufacture a failure in this run.

During earlier preflight reruns, the expired-listing `my_job_history` read returned a 503 once; the local Edge log categorized it as an invalid projection. It passed in the later focused journey and the final combined run. The specific field did not reproduce under diagnostics, which were removed afterward, so no application fix is claimed for that intermittent observation.

The local Edge run used separate synthetic party, reviewer, approver, appeal-reviewer, senior and finance-inspector identities with Auth-issued AAL1/AAL2 sessions. It passed case decision/appeal/refund traceability, scoped denials, non-response review, cancellation/start races, refund runner/reconciliation and the broader Phase 1–3 marketplace regressions. It cleared marked synthetic data and stopped the local stack. No hosted services, Bachs endpoint, real provider, real bank details or bank receipt were involved.

For the populated refund case above, the checker exported and verified a checkpoint from the existing audit hash chain **before cleanup**, with **34 events** at head position 34. Edited data, a forged signature, recomputed chain tampering and a rollback below the retained checkpoint were rejected. A later legitimate reconciliation event advanced the live chain from **34 to 94 events**; the earlier trusted checkpoint still verified. The test key remained in memory, while the trusted public key and retained checkpoint were outside the repository/database under the OS temporary directory. This proves the local verification mechanism for this synthetic run only.

The recorded safe source manifest contains **211 files** and has SHA-256 `4ae3d732895e1e2a6bac0aaa1962815cd29c7e70a5d705b394f1b3bb0478e2cf`; see [phase-4-source-manifest.sha256](phase-4-source-manifest.sha256). There was no committed Git `HEAD` in the workspace, so the manifest digest is the reproducible source identifier for this run. Its output excludes credentials and local Supabase state.

The required failing-then-fixed appeal regression was reused from Step 9: the focused `case-handlers` test caught a 503 when the shared staff validator incorrectly required reviewer traceability on the separate appeal-review response. Validation was narrowed to the `reviewer_detail` response that owns the trace fields; the appeal response remains scoped and private-note-free. That regression and its passing correction are recorded above; this acceptance did not alter the approved financial rules.

Local Step 10 acceptance is verified. Remaining live gates include Bachs refund compatibility, production provider and bank-receipt evidence, real evidence scanning, independently controlled audit-checkpoint storage and signing-key custody, retention/rotation policy, and operational checkpoint verification. The same-workstation test does not prove resistance to an owner who controls the database, signer and temporary storage.
