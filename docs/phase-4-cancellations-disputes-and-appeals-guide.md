# No Broke Dayz — Phase 4: cancellations, refunds, disputes and appeals

Prepared: 5 November 2026. Application root: `/Users/mac/Desktop/NoBrokeDayz`.

This is a step-by-step guide for your coding agent, not application code. Give one prompt at a time and review its results. Step 1 resolves detailed contracts before dependent implementation. Complete the phase and return its evidence before requesting Phase 5.

## What you are building

The local backend that handles work or money when the ordinary job journey does not finish smoothly:

- Explicit cancellation of unused funded slots.
- Agreed pre-start cancellation and worker pre-start abandonment.
- Full dispute investigation, decisions, appeals and controlled manual finalization.
- Full/partial worker awards and poster refunds with exact accounting.
- Independent staff approvals, private case/evidence access and signed audit-checkpoint verification.

All external movements remain simulated. No Bachs connection, live funds, real evidence, hosted setup, public communication or production UI is authorized by this phase.

## Preserve what already works

Phase 3's recorded complete local wrapper passed: 31 migrations, 768 database assertions, four registration checks, 33 marketplace boundary tests, 17 simulator tests and actual local Edge journeys. Those counts describe the baseline, not a required future test quota. Preserve its behaviour and add meaningful tests for new rules.

Reuse the actual repository: `app/`, `lib/`, the existing `_shared/` handlers, server-only RPC gateways, private ledger, immutable terms, per-slot allocations, durable payment runner/callback, scoped staff MFA, identity status, notifications and financial inspection. Do not create a second ledger/provider runner or broadly expose private schemas.

Current `assignment_holds` rows are immutable, with status constrained to `open`; several commands check those rows directly. Evolve effective hold resolution deliberately through new migrations and explicit lifecycle records/projections. Simply changing one status field or dropping all immutability guards will not safely update every authorization path. Preserve original reports, work states, terms, money history and prior tests.

Phase 2's strict wrong-phone-code limit remains unresolved; real identity intake and evidence promotion are blocked by safety/privacy gates. Hosted staging/CI remain deferred/pending. Preserve those facts. Synthetic ready-evidence fixtures can test authorization and decisions, but cannot prove that actual uploaded files passed scanning.

Bachs holding and refund compatibility remain unresolved. The prior reference reports no Refund API path for NGN bank transfers and one successful refund per charge. The simulated multi-slot refund model is an application requirement test, not evidence that Bachs can fulfill it. Keep actual provider integration and live funding blocked until the route is explicitly resolved and approved.

## Step 1 — settle cancellation, case and approval contracts

**Create/update:** `docs/case-and-cancellation-contracts.md`, `docs/payments-and-recovery.md`, `docs/data-and-permissions.md`, `docs/decisions.md`, `docs/phase-4-evidence.md`.

**Prompt**

> Work in /Users/mac/Desktop/NoBrokeDayz. Implement only Phase 4 Step 1: planning contracts, no schema/commands yet. Read AGENTS.md, the approved spec, canonical cancellation/F10/F12/appeal rules, current Phase 3 contracts/evidence and actual hold/ledger/runner implementation. Map each existing command/query that assumes every historical hold remains open. Define explicit transitions, actor/capability/MFA checks, idempotency, versioned consent, decision/evidence snapshots, approvals, notification/deadline semantics, refund progress and safe participant/staff responses. Resolve the wording conflict: the approved sources describe two-person approval and a second approver different from the initiator; the later payment note says two approvals excluding the initiator. Recommend two distinct qualified approval records in total, allowing a qualified initiator to supply the first, with a different qualified second approver; present that interpretation for owner approval rather than silently imposing or removing a third-person requirement. Specify separate appeal-reviewer and senior-signoff restrictions, case-party conflicts, and who may manually finalize. Also resolve the source wording that no action creates no journal movement against the existing Phase 3 hold-liability journal reclassification: propose restoring only the internal hold classification, with no new award/refund or external payment, and obtain explicit approval of that interpretation before implementation. Propose treatment of no-action hold removal, cancellation requests racing work-start, simultaneous appeals, closure versus unsettled refund, repeat reports after no-action and suspended users' narrow case-support actions. Define bounded case fields and use the source's five dispute files/5 MB each as configurable engineering defaults, distinct from three identity files. Preserve 72 hours from durable notification to both parties, one appeal per party and server-received-before-deadline timeliness. Present a concise list of genuine owner choices before dependent implementation. Do not reopen settled commission/vendor/product rules, invent statutory retention or attribute fake refunds to Bachs. Prepare the command-by-command DB/handler/Edge acceptance map while waiting for decisions.

**Expect:** a reviewable set of decisions with safe defaults, not new policy hidden in code. The owner can approve the detailed recommendations together or revise them by number.

**Check:** distinguish voluntary authorized cancellation from an admin money decision. A normal poster confirmation or permitted cancellation does not require a fictitious dispute. Silence/contact failure never decides a case. Full award, full refund, split and no action each have a defined result.

**Debug:** pause only the implementation that depends on an unanswered choice. If approval wording conflicts, record source precedence and the owner's decision. Continue to Step 2 once required choices are approved.

## Step 2 — evolve holds into versioned cases and scoped timelines

**Create/update:** new `supabase/migrations/`, case database tests, case handlers under `supabase/functions/` and `_shared/`, case data/permission documentation.

**Prompt**

> Implement only Phase 4 Step 2, beginning with failing authorization/lifecycle tests. Extend existing hold/report records into one coherent case model. Preserve immutable report history and add controlled lifecycle/resolution records so a resolved historical hold does not block every future valid action. Update all current hold checks consistently: confirmation, submission/start, status, discovery where affected, reconciliation and wallet projections. Preserve one active case per affected allocation, prior work state and exact accepted terms. Cases are available only for funded assignments from assigned through submitted; unfunded listings and settled ordinary completion cannot silently become new escrow cases. Capture reason/narrative/desired outcome/follow-up and attach relevant terms and authorized conversation history. Provide participant-visible timeline separately from internal notes, third-party identity material and reviewer access metadata. Both parties receive the same shared case status; rival applications/threads remain private. Add explicit reviewer assignment, active account/current scoped grant and MFA checks. Financial inspection alone grants no case investigation or decision authority. Audit submission, assignment and access changes; events/notices commit with state. Use migrations and generated safe types without rewriting the Phase 3 history.

**Expect:** existing synthetic holds remain inspectable, newly opened cases atomically freeze only their allocation, and participants can read a safe shared timeline.

**Check:** opening a case versus ordinary confirmation still has one valid winner. A hold must cover every unresolved portion, including a potential poster refund. Unrelated earnings and assignments remain usable.

**Debug:** search every old `status='open'` or historical-row existence check before declaring migration complete. Preserve the original report and ledger immutability while evolving controlled current state.

## Step 3 — cancel unused slots and handle pre-start assignment changes

**Create/update:** cancellation/consent/abandonment commands, allocation lifecycle/history records, refunded-slot status support and concurrency tests.

**Prompt**

> Implement only Phase 4 Step 3. An owning eligible poster can explicitly cancel an unassigned funded slot and authorize its refund payable; a batch cancellation examines each slot and must never refund principal bound to another active assignment. State whether a mixed batch is atomic or returns per-slot results according to the approved Step 1 contract. For an accepted assignment before start, require both participants' explicit consent bound to the same immutable assignment/terms/cancellation version; one request alone cannot move money. Work-start versus consent completion must serialize on current state. After work starts, unilateral financial cancellation is denied and the participant uses the case route. Worker pre-start abandonment cancels that assignment and returns its still-held principal to an unassigned slot without refund or second poster charge; re-opening discovery remains subject to the original deadline. Preserve historical assignment/allocation links and original application/thread; reuse capacity safely without weakening one application per worker/job or permitting two active bindings. Close affected conversations according to policy and preserve read-only history. Add idempotent user authorizations, reason/consent audit, events/notices and balanced reclassification where needed. No background timer can trigger cancellation/refund. Implement refund authorization/payable state here; external simulated settlement comes later.

**Expect:** unused-slot cancellation creates an identifiable refund obligation. Pre-start mutual cancellation and worker abandonment have different money outcomes. Expired discovery does not automatically return money.

**Check:** race acceptance against unused-slot cancellation, abandonment against start, and duplicate consent against final cancellation. Verify capacity, terms history and one financial effect. No old assignment can later release a reused allocation.

**Debug:** if re-opening requires rewriting immutable historical records, introduce an explicit current binding/history boundary. Do not erase the cancelled assignment or repurpose its completion authorization.

## Step 4 — add investigation, private evidence and contact attempts

**Create/update:** restricted investigation/contact/evidence commands, case-specific private buckets/metadata, scoped thread reads, evidence/timeline tests and runbook.

**Prompt**

> Implement only Phase 4 Step 4. Build scoped local case investigation commands: triage/acknowledgement, reviewer assignment, contacting the other party, information/evidence requests and verifying facts. Prioritize conduct/safety without letting a category decide money. Record contact channel, staff, time, result and attribution. Unresponsive classification requires at least two attempts across two channels; final non-response decisions also need recorded current senior sign-off and substantive reasoning, never silence alone. Local contact entries are clearly simulated/manual log fixtures, not evidence a real phone call/email/visit occurred. Preserve user-added evidence before the initial decision and during an authorized appeal evidence request; decision versions keep their original evidence snapshot. Implement dispute-file limits and private owner/participant/reviewer access separately from identity files. Reuse safe intake/quarantine controls but not identity reviewer grants. No public URLs, unrelated messages, raw IDs, private notes or unsafe files in shared case responses. Actual uploads stay quarantined while safety inspection is unavailable. Use isolated synthetic ready-file metadata only for tests that need reviewed evidence; do not add a browser/staff mark-safe bypass or pretend those fixtures prove scanning. Expose a local complete case overview response for later screens, not an export-only replacement for the workflow.

**Expect:** a reviewer can inspect the authorized terms, conversation, submissions and contact history; participants see only allowed shared information and next steps.

**Check:** case access ends or narrows as the approved assignment/grant policy requires. An MFA user with the wrong grant or case scope cannot fetch evidence. Metadata/timeline access and byte downloads each need their own tests.

**Debug:** if case completion requires unsafe evidence promotion, retain the live gate and use clearly isolated synthetic facts for the local workflow. Missing scanning is not permission to make raw uploads reviewable.

## Step 5 — record immutable decisions and independent approvals

**Create/update:** decision/version/approval/senior-signoff records and commands; local staff fixtures; actual MFA/permission/independence tests.

**Prompt**

> Implement only Phase 4 Step 5 using the owner's approved approval model. A scoped authorized reviewer may propose full worker award, full poster refund, split or no action against the exact held allocation. Record reason code, written explanation, evidence/terms versions, award/refund kobo and immutable decision hash/version. Validate gross allocation conservation and compute 5% commission only on gross awarded to the worker, half-up in integer kobo. Proposing/approving a decision must not release earnings or dispatch a refund. Require the approved independent human approval records for every beta admin money amount, with current grants and AAL2; enforce separation by actor identity even if one person holds multiple role grants. Synthetic staff fixture identities prove local authorization only, not staffed live operations. Case parties cannot approve their own outcome. Editing amounts, recipient, reason or evidential decision basis creates a new version and invalidates approval applicability. Bind senior sign-off for non-response decisions to the same version. Reject service accounts as independent human approvers. financial_inspect remains read-only. Test caller actor/role spoofing, stale approvals, double approval, revoked grants, reused decision keys and competing decision versions. Preserve ordinary user confirmation/cancellation authorizations as separate paths.

**Expect:** case outcomes can be proposed and approved, but money remains held until the appeal and manual-finalization rules pass.

**Check:** a second click by the same staff account cannot satisfy independence. A version change cannot retain old approvals by copying them. A user-facing reason is mandatory and excludes private internal notes.

**Debug:** if changing a recipient only updates an unrelated table while an old approved hash still applies, include the effective immutable destination/outcome in the authorized version and finalization checks. Do not trust the UI to keep decision fields unchanged.

## Step 6 — notify both parties and implement appeals

**Create/update:** decision notification/deadline and appeal commands/records; deduplicated in-app notices/outbox; precise timing and race tests.

**Prompt**

> Implement only Phase 4 Step 6. Notify both parties durably in-app of the same initial decision/version and store the 72-hour appeal deadline from authoritative durable notification to both. Persist the relevant notices and timing consistently; email is supplementary and its failure cannot erase or reset durable notice. Each party may appeal once within the initial decision's allowed window; a revised decision must not silently create unlimited new appeal rights. Preserve both parties' eligibility and unresolved appeal requests, not only the first appellant. Appeals use a reviewer different from the initial reviewer; current grants/MFA and case scope apply. Keep the full allocation and any unfinalized refund portion held during the window and timely appeals. Use one authoritative server-time model: timely means received before the stored deadline, never a client-supplied timestamp. Define durable appeal receipt/ordering so a timely server-received appeal cannot be overtaken by finalization because a later lock wait crosses the deadline. Test before, exact and after deadline, parallel appeals and appeal-versus-finalization with real separate transactions. No user-visible clock override/backdate endpoint. Use isolated local fixtures/test clock support for historical deadlines, while proving a normal initial decision actually creates 72 hours. Appeal decisions and evidence requests are immutable/versioned. Any changed financial outcome requires approvals for the changed version. A timer may surface an eligible case to staff but cannot release/refund it; ordinary poster completion has no blanket 72-hour delay.

**Expect:** one timely appeal prevents execution, a different reviewer can handle it, and both parties see consistent allowed status. Late appeals fail safely with a support route.

**Check:** neither delayed email nor opening the notification changes the deadline. Exact-deadline behaviour matches the documented strict-before rule. One party's appeal does not erase the other's remaining eligibility.

**Debug:** if tests sleep for 72 real hours or edit immutable production decisions, replace them with isolated valid historical fixtures. If a lock wait causes a timely received appeal to lose, fix receipt/finalization ordering rather than extending deadlines silently.

## Step 7 — manually finalize eligible cases with exact accounting

**Create/update:** finalization command/authorization records, ledger transitions and status projections, full/split/no-action tests.

**Prompt**

> Implement only Phase 4 Step 7. An explicitly authenticated authorized admin with current MFA/grants must initiate finalization. In one locked transaction recheck funded principal, active case/allocation/decision version, senior sign-off where required, current independent approvals, appeal-window eligibility and absence of unresolved timely appeals. Prevent duplicate execution and conflicting outcomes. Full/partial worker awards allocate exact net/commission, complete the assignment and create only the required durable provider authorization; poster refund portions become refund payable, not a spendable poster top-up. A full refund cancels the assignment. No action resolves the case hold and restores the prior valid work state without releasing/refunding money; implement the approved internal hold-liability reclassification without mislabelling it as an external payment or new award. Preserve hold/report/history and allow future valid commands to see the resolved state. Failed finalization leaves all financial state unchanged. Test NGN 3,000 allocation / NGN 2,000 gross worker award → NGN 1,900 worker net + NGN 100 commission + NGN 1,000 poster refund payable. Commission never applies to refunded gross. Finalized decision, execution, refund settlement and case-closure states remain distinguishable under the approved contract. Job completion requires at least one paid completed assignment and all funded slots resolved; pending refunds cannot be hidden as settled. Worker bank withdrawal remains separate and user-requested.

**Expect:** the outcome is executed once only after all required controls pass. All journals balance and allocation conservation holds; another assignment's money does not move.

**Check:** manual finalization without approvals, with an open appeal, before eligibility, on the wrong version or under revoked authority fails at the backend. No-action produces no award/refund and restores exactly the retained stage.

**Debug:** if a scheduler can invoke finalization as an implicit admin, remove that path. It can process an already-recorded final authorization afterward; it cannot create the human authorization.

## Step 8 — extend the simulator for controlled refund settlement

**Create/update:** normalized fake refund adapter/fixture, existing durable runner/callback extensions, refund/status RPCs, reconciliation and unknown-result tests.

**Prompt**

> Implement only Phase 4 Step 8. Extend the existing local fake provider and durable operation runner for refunds authorized by eligible explicit cancellations or finalized cases. Do not create a second runner/ledger. Persist refund operation/source-collection/allocation mapping, exact principal, fee treatment, effect identity and original provider reference before a simulated external call. Serialize cumulative authorized/reserved/successful refunds against collected principal across worker slots, including pending/unknown attempts; two requests cannot over-refund one charge or reuse an allocation. Model independent per-slot and repeated partial outcomes as simulator features only, preserving the unresolved Bachs compatibility gate. Reconciliation and callbacks update observed status for existing authorizations; they never invent one. Unknown stays under reconciliation with payable/reserves intact; known failure leaves the user's refund entitlement visible and prevents duplicate restoration or retry payment. Success clears the payable once; any verified reversal uses a separate compensating incident workflow, never silent journal edits or unrelated wallet debits. Provider fees are platform expenses; poster receives the authorized refund principal. Test insufficient cleared refund cash, platform fee shortages, pending, timeout after acceptance, duplicate/out-of-order events, retry/lease reclaim, failure/reversal and independent slot outcomes. Refund progress must not claim bank receipt from mere provider acceptance. No real bank details, provider call, changed payment rail or disguised payout-as-refund workaround.

**Expect:** simulated authorized refunds progress from payable to processing/unknown/settled truthfully. An unknown refund cannot be sent again under a fresh identity. A fee does not reduce the promised refund.

**Check:** race two slot refunds against one job collection and verify cumulative limits, one effect each and exact per-allocation outcomes. Unresolved/held portions remain protected even when another slot settles.

**Debug:** if partial successes close the entire job or consume another allocation's funds, separate parent summary from allocation/operation state. If real Bachs support is assumed from fake tests, correct the claim and preserve the launch blocker.

## Step 9 — complete ops/case responses, notifications and local audit checkpoints

**Create/update:** case queue/detail/participant history APIs, extended financial inspection/reconciliation, checkpoint exporter/verifier, `docs/case-runbook.md`, `docs/audit-checkpoints.md`.

**Prompt**

> Implement only Phase 4 Step 9. Provide actual backend workflow responses for reviewer queues, investigation/contact logs, decisions/approvals, appeal assignment, manual finalization and refund exceptions. This prepares later admin screens; an export alone is not a substitute. Staff read/write permissions remain distinct and scoped, with AAL2/current grant/assignment checks; financial_inspect cannot decide, approve, finalize or remove a hold. Participants see their own safe case/payment status and written reason; private internal/third-party material stays excluded. Deduplicate relevant in-app notices and local email-delivery requests, preserving events with state. Record first response, initial decision and final financial settlement separately; a 72-hour initial-decision target is not proof the appeal/refund is finished. Extend current audit hash chains with deterministic sequence and checkpoint export/signature verification using a separate local signer/test key outside the database/browser/repository. Test event edit/delete/reorder, forged checkpoint and rollback to a prior database state against a retained trusted checkpoint. Protect sensitive payloads and record the verification trust root. A same-workstation test signer demonstrates the mechanism, not independent production custody or database-owner resistance. Actual separately controlled checkpoint storage, key custody, retention/rotation and operational verification remain explicit live gates. Do not buy hosting or claim independent production witnessing.

**Expect:** local staff can follow a case and payment reference through authorized actions; participants see consistent outcomes; tampering is detectable against retained local test checkpoints within the documented trust boundary.

**Check:** a database hash-chain recomputed after tampering must fail against the trusted signed checkpoint. A signer controlled by the same database credential is not an independent trust boundary. All checkpoint claims identify which part is actually proven.

**Debug:** if a checkpoint verifier simply trusts a new public key supplied with each export, bind the approved trust key separately. If cases close before refund outcome is known, fix settlement/status reporting according to the approved Step 1 contract.

## Step 10 — verify every exposed command through actual local Edge HTTP

**Create/update:** database tests; `tests/integration/cases/` and simulator tests; local Edge journey scripts; `scripts/check-phase4.mjs`; generated types; future CI/local check configuration; `docs/phase-4-evidence.md`.

**Prompt**

> Implement only Phase 4 Step 10. Build a command-to-evidence matrix before calling the phase verified. Every newly exposed case/cancellation/refund command/read must have relevant database/permission tests, handler validation tests and actual local Deno Edge HTTP success/denial evidence; do not leave three actions untested at HTTP and label the phase complete. Cover the scenarios below, original Phase 1–3 regressions and the complete updated toolchain/type/lint/format checks. Use actual Auth-issued AAL1/AAL2 sessions and separate synthetic staff/party identities. Concurrency tests use separate DB connections or simultaneous Edge requests and inspect committed ledger/allocation state. Deadline fixtures remain isolated and cannot create a production time/approval bypass. Confirm the existing 31 migrations rebuild with new migrations, generated types compare consistently and existing behaviours still pass. The phase wrapper runs required checks sequentially, fails honestly, redacts credentials, cleans marked fixtures and stops services. Include one meaningful new failing-then-fixed approval/appeal/accounting regression if not already evidenced; preserve and reuse valid failure/restore evidence rather than mutating migrations on every run. After necessary fixes run the complete updated suite together once. Record test/migration counts, safe revision/source manifest, timings, synthetic dataset and every deferred boundary. No hosted/real-provider execution.

### Acceptance matrix

| Scenario | Required observable result |
| --- | --- |
| Unused slot cancellation | Explicit owner action; eligible allocation only; one refund authorization/payable; acceptance race safe. |
| Mutual pre-start cancellation | Matching versioned consent from both participants; start/cancel race produces one valid state. |
| Worker abandonment | Pre-start only; assignment cancelled, same principal returned to capacity, no refund/second charge, historical terms retained. |
| Started work | Unilateral financial cancellation denied; valid dispute path remains. |
| Case opening | Funded participant only, one active hold, no cross-allocation freeze; confirmation race still safe. |
| Evidence/timeline privacy | Relevant chat/terms only; assigned reviewer scope; private notes/third-party identity/unsafe uploads excluded. |
| Non-response | Two attempts/two channels plus senior sign-off and reason required; silence alone never settles. |
| Approvals | Approved count of distinct qualified identities; initiator cannot second-approve; service/party/wrong grant denied. |
| Version changes | Old approval/senior sign-off cannot authorize changed decision, recipient, amount or reason. |
| Appeal clock | 72 hours from durable notices to both; server strict-before deadline; email failure/client clock irrelevant. |
| Appeals | One per party, different reviewer, concurrent requests accounted for; hold persists and changed award needs current approvals. |
| Boundary race | Timely appeal versus manual finalization cannot lose its hold due to stale reads/lock timing. |
| Final outcomes | Full award/completed, full refund/cancelled, split/exact commission, no action/prior work restored. |
| Timers | Case eligibility/reminders alone never credit earnings, authorize refunds or dispatch new money decisions. |
| Refunds | Stable original references, cumulative cap including pending/unknown, separate slot outcomes, fees platform-funded. |
| Unknown/failure/reversal | No fresh replacement while unresolved; once-only accounting; entitlement/status remains truthful. |
| Parent summary | At least one paid completion plus every funded slot resolved; no false completion from pending refunds. |
| Audit | Append-only actions and signature/checkpoint tamper tests pass within stated local trust boundary. |
| HTTP completeness | Every new action has real local gateway success/denial coverage; permission helpers alone are insufficient. |
| Regression/safety | Existing identity/marketplace checks pass; fake mode local-only; real identity/payment/hosting gates unchanged. |

**Expect:** the full synthetic cancellation→refund and case→decision→appeal→manual-finalization→settlement journeys pass, alongside previously working ordinary confirmations and withdrawals.

**Debug:** a passing assertion count is insufficient if the matrix has missing routes. If a new timer-based shortcut makes a test convenient, remove the shortcut and construct a valid isolated test state. No need to rerun the entire long suite after documentation-only wording changes; run the relevant formatting check and retain the tested source identity.

## Step 11 — document the milestone and hand back results

**Create/update:** `docs/phase-4-evidence.md`, `docs/phase-4-milestone.md`, runbooks, data/permission/decision/launch records, `docs/development-log.md` and `docs/community-feedback.md`.

**Prompt**

> Close Phase 4 locally only. Summarize the implemented commands, exact DB/handler/actual Edge evidence, simulator behaviours, complete suite result, cleanup and source identity. State any partial route/evidence/approval/checkpoint coverage honestly. Update the case/refund/audit runbook so a new developer can reproduce local staff/party scenarios, inspect an appeal deadline/decision hash/authorization, trace an unknown refund and verify a retained checkpoint without secrets. Keep all Bachs, strict phone-attempt, file-safety, privacy, real staff, reserve/exposure, independent production checkpoint, hosting and real-delivery gates explicit. Update the milestone/weekly documentation below. Do not send or publish it, add production UI, start Phase 5 or mark the entire product ready for live money.

### Milestone and weekly documentation

After cancellation/refund, independent approval and appeal/finalization milestones, append a brief note: what works, requirement IDs, passing evidence, what remains simulated and a real implementation lesson.

At phase close prepare:

1. **Safe capture:** a redacted test summary or synthetic API walkthrough of a held allocation remaining held during appeal, then an explicitly approved simulated outcome. Label clearly: **local simulation — no real money or real case**. Do not create a plausible fake bank receipt or show a real person's dispute.
2. **Plain-language note:** explain that the backend now supports reasoned dispute handling and controlled demo refunds, with a second-person check and appeal opportunity. Do not claim a staffed live service, guaranteed recovery, licensed escrow or finished admin interface.
3. **Brief weekly update:** completed, in progress, next, blocker and one genuine lesson. Prepare one or two content opportunities per week, such as why a deadline cannot automatically award money, or why a proposed decision stays held during appeal.
4. **Feedback:** if useful, ask what an appeal/status explanation should tell each party so they understand what happens next. Record actual observations and accepted/deferred product decisions, not invented sessions.
5. **Review gate:** internal material for Community and Growth review only. Exclude credentials, OTPs, bank data, private notes, staff identities, internal security limits and raw evidence. Nothing is sent or published by the coding agent.

## Completion and next phase

The phase is locally verified when the approved contracts, all implemented actions, independence/appeal/race/refund/accounting controls and checkpoint mechanism pass their appropriate tests together, with explicit boundaries for quarantined files and local checkpoint independence. If any required core path remains unproved, report it as partial and name the missing evidence.

Real provider refund capability and production approvals remain separate blockers even after perfect simulator tests. Full production UI and operational readiness are not established by this backend phase.

Return the agent summary, `docs/phase-4-evidence.md` and `docs/phase-4-milestone.md` here. We review them before Phase 5, which completes communication, reminders, ratings and remaining marketplace/ops backend features.
