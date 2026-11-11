# No Broke Dayz — development log

## 29 October 2026 — planning milestone

Completed: reviewed the three supplied source documents; drafted the whole-product specification and Phase 0 guide; confirmed login, separate job timing fields and backend-first delivery; placed draft planning records in the user-provided project folder.

In progress: specification review and remaining product decisions. No application code, provider integration, deployment or performance benchmark exists yet.

Next: obtain explicit specification/test-boundary approval; then provide Phase 1 instructions when the user asks to proceed.

Evidence: root spec.md; docs/phase-0-planning-guide.md; docs/decisions.md; docs/launch-gates.md. These are internal planning documents, not approved public content.

Lesson: separate a funded job's per-worker assignments and payment authorizations from bank settlement. Source rules, proposed choices and actual integration evidence need distinct status.

Potential weekly content opportunities for Community and Growth review:

1. Explain planned per-worker pay, total poster funding and worker take-home using synthetic examples, clearly marked as planned behaviour.
2. Ask students which details they need before applying for a campus job.

Safe capture: no feature screenshot or recording is available because no app has been built. Do not share internal specifications without appropriate approval.

Review status: prepared internally; not sent, approved for publication or published.

## 4 November 2026 — Phase 3 local closeout (F3–F6/F8)

Completed: the full updated `npm run check:phase3` suite passed together with 31 migrations, 768 pgTAP assertions, 4/4 identity registration checks, 31/31 marketplace boundary tests and 17/17 fake-payment tests. Student and partner poster journeys, allocation and assignment separation, work confirmation, safe wallet reads, manual simulated withdrawal, and separate-connection races ran through the local Deno Edge/API path. The controlled liquidity regression failed its target invariant, the migration was restored byte-for-byte, and the complete suite passed on restored source. Fixtures were removed and local services stopped.

Limitation: three implemented command boundaries remain partially verified at the Edge HTTP layer: draft update, application rejection and application withdrawal. The tests cover them at the database/shared-handler boundaries as recorded in docs/phase-3-milestone.md. The local provider is a fake; no Bachs sandbox/live behavior or real payment was exercised.

Lesson: a lost payment response must be resolved by looking up the original saved operation. A retry must not invent a new payment identity or authorize another money movement.

Evidence: docs/phase-3-evidence.md, docs/phase-3-milestone.md, docs/phase-3-source-manifest.sha256. No Git HEAD was present; the safe source manifest is used instead. No hosted CI, deployment, message, publication, or real-money movement is claimed.

Draft weekly packet and content opportunities are prepared in docs/phase-3-milestone.md. Status: internal review only; not sent or published. Phase 4 and production UI remain unstarted.

## Weekly update template

Week/date:
Completed:
In progress:
Next:
Evidence/build/test reference:
Blockers:
Lesson:
One or two content opportunities:
Feedback question:
Safe screenshots/recordings, when available:
Review/approval status:

Prepare one brief update and one or two content opportunities each week. Add milestone evidence when meaningful progress occurs; do not invent progress to fill a content quota.

## 29 October 2026 — recommendation approval

The user approved all section 13 recommendations. Updated root spec.md, the decision log and Phase 0 guide. Detailed evidence/policy/design gates remain tracked. Overall specification and testing-boundary approval is still pending; no application code was created. This is internal planning progress, not a completed feature or provider integration.

## 29 October 2026 — specification approved and provider reference review

The user approved the complete specification and testing approach. Read the Bachs Introduction page open in Safari, then consulted linked official public documentation. Found a refund capability gap affecting NGN bank transfers and repeated multi-slot refunds; recorded as a contract/live-use blocker without changing product entitlements. Reference research is not a working integration, measured benchmark or provider approval. No application code or external communication was created.

## 29 October 2026 — Phase 1 guide supplied

The user asked for the next step. Prepared docs/phase-1-backend-foundation-guide.md with seven sequential steps, coding-agent prompts, file targets, expected results, debugging, evidence requirements and milestone/weekly documentation. The guide covers foundation only; application implementation has not started. Provider refund constraints remain gated. Await actual Phase 1 build/check results before Phase 2.

## 30 October 2026 — Phase 1 local foundation closeout

Reviewed Steps 1–7 against repository artifacts and recorded command results in docs/phase-1-evidence.md. Formatting, Cloudflare type generation/TypeScript, lint, build and the Workers-compatible local preview passed. The local Supabase check started the native stack, reset only the local database from committed migration/seed files, passed all 29 pgTAP assertions, matched generated public types, and stopped the stack. The existing controlled negative policy check demonstrated expected client-role denial failures before the policy was restored. The milestone and weekly update packet is in docs/phase-1-milestone.md; it was not sent or published.

The user postponed hosted Step 6. No hosted service was provisioned, linked, deployed to or modified. No Git remote is configured, so hosted CI has not run. Phase 1 remains incomplete until its hosted checks are resumed and evidenced. Bachs holding/refund, real-money, identity/privacy, operations, recovery and performance gates remain open. Do not start Phase 2 automatically.

## 30 October 2026 — Phase 2 guide supplied

The user requested Phase 2 after the local Phase 1 evidence review. Prepared docs/phase-2-identity-and-verification-guide.md using the actual app/, lib/, native local Supabase and existing check layout. The guide contains ten sequential steps, contract/detail approval, coding-agent prompts, acceptance evidence, troubleshooting and milestone/weekly documentation. Hosted staging and CI remain deferred/pending. No identity implementation, deployment, paid setup, real document collection or provider delivery was performed by this guide-authoring task.

## 3 November 2026 — Phase 3 guide supplied

The user requested Phase 3 after the complete updated local Phase 2 suite passed. Prepared docs/phase-3-marketplace-and-money-guide.md with eleven sequential instruction steps for marketplace commands, ledger, locally simulated funding/payout, allocation safety, essential messaging/notices, actual Edge tests and documentation. Phase 2 remains partially verified; the per-challenge phone-attempt and evidence-safety gates persist. Bachs holding/refund integration, hosted services and real money remain blocked/deferred. This task authored a guide only; no marketplace or payment implementation was performed.

## 5 November 2026 — Phase 4 guide supplied

The user requested Phase 4 after Phase 3 local verification gaps were closed and its complete suite passed. Prepared docs/phase-4-cancellations-disputes-and-appeals-guide.md: cancellation/consent/abandonment, per-slot simulated refunds, scoped cases/evidence, independent approvals, appeals, manual finalization, audit checkpoints and complete local command evidence. Step 1 requires owner resolution of approval-count wording and hold/no-action accounting semantics plus other detailed contracts before dependent implementation. This task authored instructions only; no Phase 4 application implementation, provider call, hosting or real-money action was performed. Existing launch gates remain.

## 10 November 2026 — Phase 4 local closeout

Completed: recorded the full local Phase 4 result from 9 November and updated the case/refund/audit runbook for reproducing the synthetic party/reviewer journey, inspecting the appeal deadline and decision hash, tracing an unknown refund, and verifying the retained checkpoint while the local chain is still running. The sequential `npm run check:phase4` result passed: 41 migrations, 1,004 pgTAP assertions across 17 files, case handlers 31/31, checkpoint tests 6/6, marketplace boundaries 35/35, payment tests 20/20, and the Auth-backed local Deno Edge journey. The populated checkpoint verified at 34 events before cleanup and remained valid after later events advanced the chain to 94. The marked fixtures were removed, local services stopped and original local Supabase home restored.

In progress/blockers: all live gates remain. Bachs refund compatibility; five failed phone-code attempts per challenge; file scanning/sanitization; privacy and retention approval; appointed real staff; funded reserve/exposure caps; independent production checkpoint key custody/storage; hosting/CI and capacity; real email/SMS delivery; real identity intake and any real bank settlement are not established. The synthetic staff and same-workstation checkpoint prove only local mechanisms. No Phase 5 or live-money readiness is implied.

Evidence: [Phase 4 milestone](phase-4-milestone.md), [Phase 4 evidence](phase-4-evidence.md), [command-to-evidence matrix](phase-4-step-10-acceptance.md), [runbook](runbook.md), [safe source manifest](phase-4-source-manifest.sha256). No committed Git `HEAD` was present. The recorded test source manifest has 211 files and SHA-256 `4ae3d732895e1e2a6bac0aaa1962815cd29c7e70a5d705b394f1b3bb0478e2cf`. The current closeout edits are documentation-only and were made after that recorded run; the Phase 4 implementation tested by the run was not changed.

Lesson: a passing fake-provider journey proves that the application can preserve one authorization through an uncertain response; it cannot prove the provider or bank completed it.

Weekly packet: redacted summary and two possible content topics are prepared in [phase-4-milestone.md](phase-4-milestone.md). The question about explaining case updates, appeal deadlines and refund status is proposed for a future session only; no feedback was collected. Status: internal review only, not sent or published. No screenshot or recording was created.

## 10 November 2026 — Phase 5 guide supplied

Prepared the local backend guide for private Realtime/replay, notices and simulated email, reminders, ratings, operations metrics and verification. This is a planning deliverable; no application code, live integrations or hosted settings changed.
