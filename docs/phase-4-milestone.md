# Phase 4 local milestone

**Prepared:** 10 November 2026  
**Status:** Phase 4's synthetic local command and evidence suite passed on 9 November. This closes the tested local backend scope only. It does not establish a staffed service, production UI, real provider route, independent production audit witness or readiness for live funds.

## What works locally

The `marketplace-command` surface supports per-slot cancellation, mutual pre-start cancellation and worker abandonment. `case-command` supports triage, simulated contact logs, information/evidence requests, participant responses, fact records, private notes, two-person decision approvals, senior signoff, appeal receipt/review and explicit finalization. `case-read` serves participant/reviewer queues and scoped details; `case-evidence` controls uploads and downloads. The existing payment runner, simulator callback and reconciliation process refund payables without creating a second runner or ledger; `ops-financial-inspection` remains read-only. The local checkpoint script exports and verifies a signed audit-chain checkpoint. The exact action-by-action DB, handler and local Edge HTTP map is in [phase-4-step-10-acceptance.md](phase-4-step-10-acceptance.md).

The local simulator exercised authorization, liquidity queuing, pending/unknown outcomes, reconciliation to processing and settled, known failure, reversal, duplicate/out-of-order events, and separate allocation results. In the traceability scenario one saved simulated refund progressed through `unknown` → `processing` → `settled`; parties saw only the permitted case/payment status and written reason, while the assigned AAL2 reviewer could trace the saved decision and refund reference. This is fake-provider behavior and does not show that a bank received money.

## Evidence from the complete recorded run

The sequential `npm run check:phase4` run passed on 9 November 2026 from **19:33:13.370Z to 19:47:17.425Z** (14m 4s), with Node `22.23.2`, npm `10.9.8`, Deno `2.1.4`, Supabase CLI `2.122.0` and PostgreSQL major 17. The wrapper rebuilt **41 migrations**, ran **17 SQL test files / 1,004 pgTAP assertions**, and matched generated public database types to `lib/database.types.ts`.

- SQL/permission layer: all 17 database test files passed, including the case, appeal, cancellation, refund, approval, privacy and journal invariants.
- Shared handler/boundary layer: case handlers **31/31**, checkpoint unit tests **6/6**, marketplace boundaries **35/35**, payment tests **20/20**; Phase 1/2 regression, lint, format, application and Deno checks passed.
- Actual Edge layer: the local Deno functions ran behind the local Supabase API gateway with separate Auth-issued synthetic party and staff accounts and AAL1/AAL2 sessions. The journey passed the command matrix's success, denial, privacy, concurrency and simulator scenarios. It included two simultaneous party appeals, the cancellation/start races, denial for unrelated or wrongly scoped identities, and read-grant revocation.
- Checkpoint: before cleanup, the populated case/refund journey exported and verified a signed checkpoint with **34 events at head 34**. Edited content, a forged signature, changed/recomputed chain tampering and a rollback snapshot below the retained head failed. The rollback proof used the prior chain head as a modeled restored snapshot; the test did not destructively roll back the database. Later legitimate events advanced the chain to **94 events**, and the earlier checkpoint still verified.
- Cleanup: the runner cleared its marked synthetic records, stopped the local Supabase stack and restored the pre-run local Supabase home backup. No hosted project or real payment was used.

The wrapper recorded 337 ms for case handlers, 277 ms for checkpoint tests, 679,176 ms for Phase 1/2 checks, 372 ms for marketplace boundaries, 480 ms for payment tests, 114,299 ms for the local Edge journey, 47,662 ms for the terminal database/type/cleanup check and 109 ms for manifest writing. These are one local run's timings, not production performance measurements.

The wrapper reused the earlier recorded Phase 3 controlled failure/restore evidence rather than changing a migration during the final run. The complete final run did not repeat that intentional mutation.

There was no committed Git `HEAD`. The exact safe manifest recorded for the passing suite has **211 files** and digest `4ae3d732895e1e2a6bac0aaa1962815cd29c7e70a5d705b394f1b3bb0478e2cf` in [phase-4-source-manifest.sha256](phase-4-source-manifest.sha256). The documentation-only closeout edits are being made after that recorded test; they do not change the implementation that was exercised. The full per-command results, including a one-off earlier `my_job_history` 503 that did not reproduce in the focused or final run, are recorded in [phase-4-evidence.md](phase-4-evidence.md).

The synthetic refund trace recorded in the evidence was case `6bab2a9d-e829-4ca0-b136-8251a2251ab6`, decision version 1, refund operation `b71aaf85-ecaa-4aa2-b5d3-49e1c49afa0f`, amount 120,000 kobo. Cleanup removed the fixture; these values are evidence references, not queryable live records.

## Coverage limits and live gates

No Phase 4 command row in the current acceptance matrix is marked as missing a local Edge journey. That coverage means a local synthetic request reached the handler and database under the stated test identities. The checkpoint is not an Edge endpoint: local script code exported and verified a signature over audit events created by the Edge journey, with database-chain checks and six unit tests. The rollback case compared against a modeled prior chain head; it did not destructively restore or roll back PostgreSQL. Neither result proves external delivery, real staffing, account-owner resistance or production permissions. The following limits remain:

- Two independent approval records, separation of parties, version binding and stale/revoked-authority denials passed with synthetic local staff. No appointed or trained live reviewers, senior approver, appeal reviewer or operations rota exists.
- In-app decision notices were durably exercised. Email/SMS delivery and response times were not tested; delivery failures must not be presented as real-world contact.
- Actual dispute uploads remain quarantined because scanning and sanitization are unavailable. A separately isolated synthetic-ready file supports the allowed download test only. This is not file-safety evidence. Identity-file safety has the same live blocker.
- The signed checkpoint test uses a same-workstation test signer plus public key/checkpoint files in OS temporary storage. No independently controlled production storage, key custody, retention/rotation or operational verification exists.
- Bachs NGN bank-transfer refund compatibility remains unresolved for partial/repeated multi-slot refunds. The local simulator does not prove a Bachs route, external settlement or bank receipt.
- Approved privacy, retention, terms and operational incident policies remain outstanding. No statutory retention period is inferred here.
- Approved cash reserves, provider-fee capacity, per-job/slot exposure and pilot caps remain unresolved. Local fixtures and synthetic amounts are not live limits.
- Phase 2's five failed phone-code attempts per challenge remains unenforced; Auth's tested throttles are not equivalent.
- Hosting, hosted CI, deployment, Nigerian network/capacity checks, real SMS/email delivery and real identity intake remain unverified or blocked.
- No production UI or public content was produced. The full product is not ready for live money.

See [launch-gates.md](launch-gates.md) for the maintained gate register and [runbook.md](runbook.md) for local replay, case/refund tracing and checkpoint verification steps.

## Internal weekly update packet — draft only

**Review status:** prepared for internal Community and Growth review only; not sent, shared externally or published. No user research or feedback session is claimed.

**Completed:** recorded the successful local synthetic command suite and updated the reproduction/trace instructions.  
**In progress:** no further implementation; documentation changes follow the recorded test and did not alter the exercised implementation.  
**Next:** wait for owner direction. Phase 5 has not started.  
**Blockers:** provider/refund compatibility, phone-attempt limit, file safety, privacy/retention, staffed operations, reserve/exposure limits, independent checkpoint custody, hosting and real delivery remain open.  
**Lesson:** an uncertain simulator response must be reconciled against its original saved operation; it cannot be treated as a bank receipt.

**Safe local summary:**

```text
local simulation — no real money or real case
Phase 4 complete recorded local suite: PASS (2026-11-09)
41 migrations; 1,004 database assertions / 17 SQL files
Case handlers 31/31; checkpoint unit 6/6; marketplace 35/35; payments 20/20
Actual local Auth-backed Edge case, appeal and simulated refund journey: PASS
Audit checkpoint: 34 events verified before cleanup; later 34 → 94 still verified
Bachs, real staff/delivery, file scanning, independent production checkpoint and live funds: NOT TESTED
```

**Plain-language note:** The local backend can record a dispute, let each side appeal within the stated window, require two different staff accounts to approve a money decision, and demonstrate a refund with a fake payment service. That does not mean a real support team is available or that anyone has received a bank payment.

**Content opportunities for internal review:**

1. Explain why an unanswered message or a timer cannot decide who gets the money.
2. Explain why a demo refund can remain “unknown” while the system checks its original saved request.

No screenshot or recording exists. Use only the redacted summary above. Do not show credentials, OTPs, staff identities, internal notes, raw evidence, bank details, live security limits or fake receipts.

**Feedback question for a future session:** What would help each person understand a case update, appeal deadline and refund status? This question has not been asked; no response or product decision is claimed.

## Handoff

Phase 4 local synthetic verification is recorded. Review the evidence and remaining gates before proposing another phase. Do not infer Phase 5 authorization, production UI approval or permission to move real money from this closeout.
