# No Broke Dayz — Phase 0: agree the plan before building

Status: Phase 0 specification approval received on 29 October 2026. This guide records the planning process. Wait for the user to request Phase 1 before supplying the next detailed guide; no application code is being created in this provider-review task.

Update, 29 October 2026: project folder confirmed as `/Users/mac/Desktop/NoBrokeDayz`. The draft root specification and planning records have been created. Start with Step 2; Step 1 is complete. Specification approval was received on 29 October 2026. A newly researched Bachs refund limitation remains a gated payment-integration issue; see root spec.md section 13.

This is the only detailed phase guide supplied now. Subsequent phases will be provided after you complete the current phase and ask to continue. The short dependency map in the draft specification is orientation, not an instruction to build everything at once.

## What this phase achieves

You finish with an approved `spec.md` in the actual project root, clearly recorded decisions, and a list of external launch requirements. You know what the first coding phase will build and what remains blocked. There is no working website expected at this stage.

You have confirmed that you are starting without provider accounts, design assets, original Markdown documents or an existing application folder. Synthetic data can be used while provider and launch requirements are tracked separately.

## Step 1 — create the project folder and identify it

Create a folder named `no-broke-dayz` in your chosen location, or choose another name. Send its full location to this chat. Keep the current review documents outside the future app until that location is confirmed.

Files to place there during planning:

- `spec.md` — the review copy supplied with this guide, then revised and explicitly approved.
- `docs/decisions.md` — accepted decisions and outstanding choices.
- `docs/launch-gates.md` — provider, policy, staff, recovery and real-money prerequisites with owners/evidence/status.
- `docs/development-log.md` — weekly updates, milestone notes and links to safe captures.
- `docs/community-feedback.md` — observations, questions and resulting product decisions.

The `docs/` folder and records above are planning artifacts. Defer application source, dependency setup and AGENTS.md until the approved foundation phase. The technical baseline specifically places AGENTS.md in the real application repository when it is initialized.

**Prompt for the agent, after you supply the actual folder:**

> Work only on planning documents in the project folder I have identified. Read the supplied draft specification and all three source PDFs. Copy the draft to root spec.md, retaining DRAFT status and its source provenance. Create docs/decisions.md, docs/launch-gates.md, docs/development-log.md and docs/community-feedback.md as concise planning records. Record that no application, design handoff, provider accounts or original Markdown sources exist yet. Preserve the prescribed stack and all financial rules. Do not install dependencies, scaffold code, configure live services, publish content or mark the specification ready. Report the exact planning files created and decisions still requiring my approval.

**Expected result:** the project contains planning records and no implementation. All blockers have an owner or an explicit “owner not yet assigned” entry. No credentials appear in documents.

**Check:** open root `spec.md`; confirm its draft status, correct folder and the approved v2 source dates. Confirm the copied review document is not being mistaken for an original source file.

**If something goes wrong:** if the agent starts installing packages or creates a web app, stop implementation and retain the planning files. If it rewrites financial rules or chooses a different provider, restore the documented baseline and record the issue for discussion. If it cannot read a PDF, provide the file access/path; do not accept an invented summary.

## Step 2 — review the proposed decisions

Read sections 1, 8, 11 and 13 of `spec.md` first. Then check the feature/acceptance table and test boundaries.

Decisions confirmed on 29 October 2026:

1. **Login:** email/password, with school-email verification and phone verification handled separately.
2. **Application timing:** separate application deadline and work needed-by time. The user has also approved a future application deadline no later than needed-by.
3. **Delivery order:** the whole product remains in scope. Build and verify backend/infrastructure first while the designer prepares designs. Use automated command/API tests and synthetic test clients during backend phases. Implement the production frontend against verified backend contracts when designs are ready; finish browser/mobile/accessibility acceptance after integration. Visual design is no longer a prerequisite to backend work.

All section 13 recommendations were accepted on 29 October 2026. Record them as decisions; obtain any detailed values, provider evidence or additional approvals explicitly required by those recommendations at the relevant contract gate, with explicit owners and blockers. Provider minimums must be confirmed before enabling real affected money actions; retention policies before real identity intake.

**Prompt for the agent:**

> Review spec.md against the PRD v2 and technical v2 sources. For each proposed decision, distinguish a source requirement, a derived implementation proposal and an unanswered owner/provider question. Preserve exact poster total, 500-basis-point worker commission with half-up kobo rounding, platform-paid provider fees, manual bank withdrawals, per-slot allocations, no timer-based release/refund, all-amount two-human admin money approvals and a different appeal reviewer. Check that application deadline and needed-by are modeled explicitly rather than silently conflated. Update the decision register only from my answers. Ask concise questions for remaining implementation blockers; leave evidence-dependent launch values open. Keep spec.md in DRAFT status until I explicitly approve it.

**Expected result:** no ambiguous requirement is silently converted into a settled decision. Every proposal has accepted/pending/rejected status and a reason where needed.

**Check:** the spec still excludes AI/native apps/multi-campus from the MVP. There are no invented school domains, provider endpoints, fee assumptions, legal retention periods, release dates or staff appointments.

**Debug:** if the agent says “the documents require email/password,” correct it: that is a proposal, while Supabase Auth is settled. If it merges application cutoff and work timing without a decision, return that item to pending. If it adds 72 hours to every ordinary payout, restore the rule: the appeal hold applies to case decisions, not ordinary poster confirmation.

## Step 3 — track external dependencies now

You do not need to solve every live-launch dependency to begin an approved synthetic/sandbox build. You do need to know exactly which real capabilities remain blocked.

Track these in `docs/launch-gates.md`:

| Dependency | What you need to obtain | What remains blocked until verified |
| --- | --- | --- |
| Bachs account and sandbox | Account access and current official/account integration documentation, followed by supported sandbox credentials stored privately. | Claiming a real Bachs integration; an adapter with invented endpoints cannot count. |
| Bachs live acceptance | Written holding/ownership/duration, KYC, payout/refund/split/freeze/chargeback support, fee funding and safe reference lookup/idempotency. | Live money and payment-protection marketing claims. |
| Africa's Talking | Account, transactional sender approval and delivery evidence across the specified Nigerian networks including DND. | Production OTP delivery; provider acceptance alone is insufficient. |
| Zoho CPaaS/domain | Sending account, domain authentication and successful real school-mailbox delivery. | Production email verification and account delivery. |
| School-email allow-list | Confirmed actual institutional domains and owner-approved verification rules. | Granting student status from a guessed domain. |
| Staff and escalation | Named authorized reviewers, separate financial approval and appeal review coverage, senior ops and support route. | Live human-reviewed workflows without adequate separation. |
| Policies | Owner-approved retention/deletion, terms, privacy/data processing, permitted work, age and incident procedures. | Real identity intake and the affected live operations. |
| Recovery and exposure | Tested offsite DB/file recovery, reconciliation, pilot limits and fee cash reserve. | Real-money pilot. |
| Design | Designer prepares approved mobile flows and their non-happy-path states in parallel with backend development. | Production frontend implementation without an approved design handoff; backend work may proceed. |

**Prompt for the agent:**

> Prepare a launch-dependency register from spec.md and the source documents. Include dependency, owner, current status, evidence required, affected capability, next action and verification date. Separate account creation, sandbox access and live approval. Since no accounts exist, label them unavailable rather than integrated. Verify changing vendor capabilities, APIs, runtime compatibility, prices and quotas against current official sources when working on that dependency, and record source/date. Keep secrets out of the register. Prepare any questions/materials for me to use with providers; do not contact anyone, create paid subscriptions or publish claims on my behalf.

**Expected result:** missing accounts do not force invention of integrations. A fake-provider demonstration can support local testing but is explicitly labeled and never counted as sandbox/provider evidence.

**Check:** every live blocker lists a concrete artifact that will close it, such as written provider acceptance or a measured restore result. “We use Supabase” is not evidence of a backup strategy.

**Debug:** replace vague “done” statuses with specific evidence. If a vendor cannot support a required flow, escalate to the owner before implementation depends on it; preserve the rule rather than quietly swapping vendors or auto-releasing funds.

## Step 4 — approve the testing boundaries and finish the specification

Approve tests at the authorized backend command/database boundary for financial and permission rules, supported by provider contract tests and a small set of full browser journeys. This verifies actual behaviour without testing every component's internal details.

**Prompt for the agent:**

> Complete a specification consistency review without writing application code. Map every F1–F12 feature to its acceptance evidence and build phase. Verify database command tests cover authorization, allocation conservation, balanced journals, integer rounding, idempotency, concurrent acceptance/withdrawal, confirmation-versus-dispute and appeal-versus-finalization. Include browser journeys for students, posters, partners and staff, plus private-file/realtime permissions and recovery/provider failure checks. Preserve the distinction between synthetic, sandbox and live evidence. List unresolved implementation blockers, deferred launch gates and the user's proposed test-boundary decision. Leave status DRAFT and present the exact specification version for my approval.

**Expected result:** the plan covers successful journeys, denial paths, uncertain provider results, races and recovery. It follows the dependency map rather than building all screens first.

**Check:** ask whether this plan would catch a double withdrawal after a timeout, a partner directly applying through the API, the last slot being accepted twice, and an appeal racing finalization. Each needs explicit planned evidence.

**Debug:** if tests focus only on a commission helper or whether buttons render, add observable command-boundary tests and full journey evidence. If the plan needs all live policies solved before any local fixture can run, separate synthetic development approval from the real launch gate.

## Step 5 — document this milestone and prepare the weekly handoff

This section fulfills the supplied role brief as a workflow. Prepare the material for review; you are not required to publish internal specifications or turn every milestone into a public post.

**Files to update:** `docs/development-log.md` and `docs/community-feedback.md`. Store approved-to-capture demo media in a dedicated local content folder outside public source when it could contain internal information; add only genuinely safe approved assets to version control.

**Capture now:** an accurate planning summary. No app exists yet, so there is no feature demo to record. Do not share the PRD/spec themselves without the appropriate approval. Later phases will name specific synthetic screens and short recordings to capture.

**Weekly note fields:** week/date; completed work; in-progress work; planned next work; evidence; blocker; one lesson; feedback needed; one or two potential content opportunities; review status. A week with no completed feature still gets a truthful progress note.

**Suggested opportunities for this planning milestone:**

- Explain in simple terms why pay per worker, total poster cost and worker take-home are shown separately. Mark this as planned product behaviour until built.
- Ask students what they need to know about a campus job before deciding to apply. Do not promise an approved release date.

**Feedback log fields:** date; question; participant/context using minimal personal data; observation; related requirement; proposed response; accepted/deferred/rejected decision and reason.

**Prompt for the agent:**

> Prepare a short Phase 0 milestone note and weekly development-update draft based only on completed planning work. State clearly that no application or provider integration has been built. Explain why the planned verification, clear prices and human dispute process matter to students. Suggest one or two content opportunities grounded in this week's progress and one genuine user-research question. Add a feedback-log entry template. Exclude secrets, private documents, unapproved capability claims and release promises. Mark the packet ready for Community and Growth review, not published or approved. Do not send it to anyone.

**Expected result:** a short factual packet that the Community and Growth team can review and adapt. Their review and appropriate approval precede external sharing, especially sensitive material. Keep this work lightweight enough to protect build quality and delivery.

**Check:** every claim is labeled completed, in development or planned. A synthetic preview is labeled synthetic; sandbox money is labeled sandbox. There is no suggestion that selecting a vendor means an approved live payment arrangement exists.

**Debug:** if the draft says “students can now get paid,” change it to describe planned behaviour until that capability is implemented and approved. If an internal screenshot contains tokens, identity evidence or private ops notes, replace it with a safe capture; blurring does not make an exposed credential safe.

## Step 6 — request specification approval and stop at this phase

Show the user:

1. The final draft root `spec.md` and the accepted/pending decision list.
2. The F1–F12 acceptance map and proposed testing boundaries.
3. Remaining launch gates, clearly separated from current implementation blockers.
4. The Phase 0 milestone/weekly documentation packet.

**Prompt for the agent:**

> Present spec.md for my explicit approval. Identify its date/version and summarize accepted decisions and remaining gated dependencies. Do not infer approval from my silence or from agreement with one individual proposal. After I approve this specification, record that approval in root spec.md and mark only that version ready for implementation. Finish Phase 0 and wait for my request for Phase 1; do not scaffold code or proceed to a later phase automatically.

## Phase 0 completion checklist

- [x] Actual project folder supplied and confirmed.
- [x] Review draft placed at its root as `spec.md`.
- [ ] Source provenance retained; original Markdown absence acknowledged.
- [ ] Immediate implementation decisions settled; remaining decisions have explicit feature/launch gates.
- [ ] Prescribed vendors, financial rules, verification rules and human approval requirements preserved.
- [ ] Test boundaries and required acceptance evidence reviewed.
- [ ] Provider/policy/staff/recovery blockers recorded without invented evidence or values.
- [ ] Planning milestone and brief weekly documentation packet prepared for review.
- [x] User explicitly approves the dated specification; status updated on 29 October 2026.
- [ ] User asks to continue before Phase 1 instructions are supplied.

When this phase is finished, tell this chat: “Phase 0 is complete; proceed to Phase 1,” along with any unresolved blocker and the evidence needed to assess it. The next guide will cover the backend/infrastructure foundation only, with exact file/folder targets, coding-agent prompts, expected API/infrastructure behaviour, checks, debugging and documentation tasks. Production frontend instructions follow backend verification and design readiness.
