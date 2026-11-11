# No Broke Dayz — decisions

Updated: 5 November 2026. Specification status: APPROVED by the user on 29 October 2026; provider/live-use gates remain. Phase 2 Step 1 identity contract decisions were approved on 30 October 2026.

## Confirmed by the user

- Project folder: /Users/mac/Desktop/NoBrokeDayz.
- Whole-product scope; backend implementation, infrastructure measurement and verification first. Designer work can run in parallel; production frontend follows verified backend contracts and design readiness.
- Email/password login with separate institutional-email and phone verification.
- Separate application deadline and work needed-by fields.
- Synthetic data and later sandbox integrations may progress while live provider, policy and staffing gates remain tracked blockers.
- Provide detailed instructions one phase at a time, including agent prompts, checks, debugging and milestone/weekly documentation. The user requests progression between phases.
- Application code begins only after explicit approval of the root specification.

## Baseline requirements

The supplied v2 PRD and technical specification prescribe Next.js/TypeScript, Cloudflare Workers, Supabase, Bachs, Africa's Talking and Zoho CPaaS. Preserve exact poster payments, worker-side 5% commission, platform-funded provider costs, manual withdrawals, per-slot allocations, human-controlled dispute outcomes and independent admin money approvals. Full rules and source provenance are in root spec.md.

## Recommendations accepted on 29 October 2026

The user said: “for all the Proposals and Questions, Use your recommendations.” All section 13 recommendations are accepted:

- Future application deadline no later than the work needed-by time, stored separately.
- Backend-first delivery while designer work proceeds in parallel; approved designs and verified backend contracts guide production frontend implementation.
- No arbitrary platform minimums; verify provider-supported amounts and required policies before enabling affected money actions.
- Unique verified phone/institutional ownership where appropriate, with suspicious duplicates reviewed by humans and permitted matching confirmed before live use.
- One application per worker/job; withdrawn/rejected threads remain read-only; no reapplication until a later approved transition policy.
- Support/reporting remains available after settlement; staff investigate without automatic retroactive wallet debits.
- Bounded inputs and configurable documented limits, explicit allowed transitions and security tests; detailed values/matrices still go through the approval required by that recommendation.

Root spec.md section 13 records the detailed decisions and remaining evidence gates. Provider/account facts, named staff, retention periods, pilot caps, reserve amounts and measured recovery results remain to be obtained; accepting recommendations is not evidence that these dependencies are complete.

The identity input limits, OTP/challenge controls, verification file policy and contact/status transitions were approved separately on 30 October 2026; see the Phase 2 approval record below.

Approved testing boundaries: authorized backend commands/database behaviour, provider contract tests, then complete browser journeys after frontend integration.

## Approval record

The user explicitly approved the complete specification and testing approach on 29 October 2026: “Yes i approve the Specification.” Backend-first phase instructions follow on request. Live-money, detailed contract and policy gates remain.

Subsequent official Bachs research identified no Refund API support for NGN bank transfers and only one refund per payment. Preserve the product refund entitlement and resolve the affected integration before contract freeze/live use; no payment-method or product-scope change has been approved. See docs/bachs-payments-reference.md and root spec.md section 13.

## Phase 2 Step 1 identity contract approval

On 30 October 2026 the user approved all five grouped decisions in `docs/phase-2-evidence.md` as written: profile/submission limits; phone OTP values; school challenge values; evidence formats/count/size and signed-URL lifetimes; and the identity transition/reconciliation rules in `docs/identity-contracts.md`. Phase 2 Step 2 may implement these approved contracts.

The actual UNILAG institutional domain allow-list remains unconfirmed; local tests use synthetic `.test` domains only. No legal retention period is inferred. The source's 5 MB per-file verification engineering limit is preserved; the separate five-file dispute cap does not establish an identity-file count.

## Phase 3 Step 1 contract decisions — approved 3 November 2026

The user approved six recommendations for **local Phase 3 implementation** on 3 November 2026. These decisions authorize local, synthetic implementation only; they do not approve hosted changes, live money, a Bachs adapter, or real bank-data intake.

1. **Local job validation bounds:** title 3–100 characters; description 20–5,000; start requirements up to 1,000; optional location detail 2–160; application note up to 500; slots 1–10; per-worker gross 1–100,000,000 kobo; per-job gross total up to 1,000,000,000 kobo; schedule horizon up to 180 days; location values `on_campus`, `remote`, `hybrid`. These are local validation limits only, not beta-wide or live exposure limits. The fake provider's separate test-only input guard is 10,000,000,000 kobo. No arbitrary product/provider minimum is introduced; Bachs limits remain unverified.
2. **Application deadline:** at `now >= application_deadline_at`, stop discovery and new applications. A poster may still accept a valid application submitted before the cutoff while funded unassigned principal remains. Deadline or needed-by passage never releases/refunds funds or changes an assignment automatically.
3. **Fresh sensitive-action confirmation:** require fresh password confirmation and a one-use server-bound proof lasting five minutes. Bind it to actor, action, amount where relevant, and exact destination ID/version. Each withdrawal keeps its destination snapshot immutable. Updating a saved destination creates a new version and never retargets an existing withdrawal.
4. **Liquidity queue:** once valid worker earnings are reserved for a withdrawal, show `queued_for_liquidity` clearly while cleared provider cash/platform fee reserve is insufficient. Make no provider call until the exact worker receipt plus provider fee is covered. Do not consume another job's reserved principal. Timers cannot release the reservation.
5. **Suspended-user financial status:** permit a suspended user to read only their own safe wallet and unresolved transaction status. Deny marketplace writes, bank changes, withdrawals and other money movement.
6. **Ops inspection:** use a distinct read-only `financial_inspect` capability, separate from `financial_initiate` and `financial_approve`. Require active staff status, current grant, AAL2, operation scope and an audit record. No financial outcome or approval workflow is added in Step 2.

The existing approved model also remains in force: exact poster funding, separate listing and assignment states, immutable funded/accepted terms, one allocation per slot, integer-kobo JSON strings, half-up 500-basis-point commission, platform-funded costs, durable idempotency and unknown-result recovery.

## Phase 3 Step 8 local implementation approval — 4 November 2026

The user approved implementing Step 8 locally with synthetic accounts and a loopback-only fake provider. This authorizes own-wallet status, immutable versioned synthetic recipient destinations, same-user fresh password confirmation with five-minute single-use proof, atomic worker-earnings reservation, durable simulated payout/reconciliation, and a visible liquidity queue. The user confirmed that the local request bounds are not live exposure caps and that a queued withdrawal must not spend another job's reserved principal. Suspended users may read only their own safe financial status; they cannot change destinations or move money. The separate `financial_inspect` grant remains read-only and is not a Step 8 ops route.

The local database validates a single withdrawal at no more than `1000000000` kobo. This is only an engineering test bound, not a live aggregate exposure limit or a provider minimum.

No platform withdrawal fee or minimum was added. A simulator-reported provider cost is charged separately to platform expense and may use only explicitly recorded platform capital/reserve; it never reduces poster funding or worker receipt. Synthetic destination ownership is labelled `simulator_only`, not Bachs KYC. This approval does not enable a Bachs adapter, real account/bank data, hosted services, live movement, a live exposure/reserve limit, deposits, transfers, automatic payout, refunds, or case/appeal resolution. Those provider, finance, policy and Phase 4 gates remain open.

For the local fake only, a reversal returns the payout principal to provider cash and restores the same worker earnings; the fake has no fee-refund result, so the provider fee remains a platform expense. This avoids assuming a fee refund from a generic reversed status and makes no statement about Bachs.

## Phase 3 Step 9 local implementation approval — 4 November 2026

The user approved Step 9 local work for durable recipient-only in-app notices, persisted authorized-operation recovery, read-only AAL2 financial inspection using the separate current `financial_inspect` grant, reconciliation, attributable audit records and reference-tracing/pause documentation. The implementation adds no staff money outcome, journal mutation, held-case release, refund, appeal or new payment identity. Reconciliation records discrepancies for review and does not correct balances or authorize movement.

Local financial audit rows are chained with SHA-256 for integrity checks. This is a database-local tamper check, not an independent signed audit checkpoint; the API reports `signed_checkpoint_proven:false`. The financial outbox records delivery work, but Step 9 implements no Zoho/SMS sender or reminder scheduler. Durable in-app notice state is independent from transport success.

The inspection route is available only in local simulator configuration. It reads synthetic operation records and the loopback fake provider's normalized liquidity snapshot. The fake provider's cash, fee, settlement, reference and signature behavior remains test-only and is never attributed to Bachs.

## Phase 3 local closeout record — 4 November 2026

Local Phase 3 acceptance and regression evidence is recorded in `docs/phase-3-evidence.md` and `docs/phase-3-milestone.md`. This closeout adds no product or financial policy decision. It does not authorize Phase 4, production UI, hosted services, Bachs integration, real identity intake or live money movement. Draft editing and application reject/withdraw commands remain partial at the actual Edge HTTP layer until covered by a local journey.

## Live-service and policy blockers remain

No aggregate live exposure cap or platform reserve amount has been approved. Bachs conditional holding/custody, student-worker onboarding, fee/reserve funding, eligible destination ownership, settlement behavior and refund compatibility require current account-specific evidence. Public Bachs research reports that its published refund flow excludes NGN bank transfers and permits one successful refund per payment. Preserve the product refund entitlement; do not change the payment rail/product promise or attribute fake-provider behavior to Bachs without a further explicit resolution. Hosted CI/services, real identity intake and real bank details remain gated.

## Phase 4 Step 1 contract decisions — 5–6 November 2026

The owner approved all three decisions below. The detailed contract and command-by-command acceptance map are in [case-and-cancellation-contracts.md](case-and-cancellation-contracts.md).

1. **Approved: approval count / initiator conflict:** require two distinct qualified approval records total. A qualified decision proposer may record the first; a different qualified human must record the second. Both approvals bind to the exact decision version. This owner decision resolves the older conflicting wording in `AGENTS.md` and the payment note; neither allows one person to supply both records.
2. **Approved 6 November 2026: no-action accounting:** append an immutable balanced journal restoring only the internal classification from dispute-held to assigned principal after case finalization. It creates no worker award, poster refund, payout or external payment. The allocation remains committed to the assignment; this is not a poster refund.
3. **Approved 6 November 2026: mixed batch cancellation:** return per-slot results for explicitly selected unassigned allocations. A slot that is no longer eligible does not block another eligible slot. Each successful slot creates only its own refund payable; external settlement remains separate.

Also proposed: case closure/appeal completion stays distinct from refund settlement; the poster continues to see an unsettled payable/processing/unknown/failed refund until authoritative settlement. Suspended users retain only their own narrow unresolved-case support path. Neither proposal invents a statutory retention period or changes the Bachs/payment-rail blocker.

These decisions resolve only the Step 1 choices. Other detailed planning defaults remain recommendations and no implementation or provider capability is implied by this approval.

## Phase 4 Step 5 local implementation approval — 6 November 2026

The owner approved implementing case decision proposals and the already approved two-person approval model locally. The approved Step 5 boundary is proposal, independent approval, separate version-bound senior sign-off when non-response is relied on, and safe staff/participant projections. No decision publication, appeal clock, finalization, journal movement, award release, refund payable, provider operation or external payment is authorized by Step 5. Those remain later Phase 4 steps.

## Phase 5 Step 1 owner approval — 10 November 2026

The user approved all five recommendations in the Phase 5 Step 1 decision summary on 10 November 2026. This approves local backend contract implementation only; it does not authorize production UI, live delivery, hosted provisioning or real-money actions. The detailed contract and evidence map are in [communication-and-reputation-contracts.md](communication-and-reputation-contracts.md) and [phase-5-evidence.md](phase-5-evidence.md).

1. **Approved — reminders:** send 24/48-hour action reminders to the poster and 72-hour dispute-route guidance to the worker. After downtime, send only the latest due stage once. Suppress pending reminders after confirmation, cancellation or dispute. No schedule may move money.
2. **Approved — no-action closure:** if no-action finalization restores an assignment to submitted, begin a fresh 24/48/72-hour sequence from finalization. Other restored states do not receive that sequence.
3. **Approved — review text/moderation:** permit optional text up to 500 characters and publish an eligible review on submission. A user who can see it may report it. Only an authorized human moderator may hide it, with an immutable audit record. Hidden reviews are excluded from public averages and counts; the one-review slot remains consumed.
4. **Approved — metric summary:** show rolling 30-day and pilot-to-date measures. Count verified job funding once and show refunds separately. Measure first response from case opening to the first staff update visible to the party, and initial decision when published. Report case finalization separately from actual refund arrival. Repeat use means participation in at least two distinct funded jobs, among users with at least one qualifying participation in that same 30-day period. Preserve F12 poster-type splits and report numerators with denominators.
5. **Approved — Realtime revocation:** use private server-generated invalidation broadcasts with authorization generations; after permission changes, advance the generation and suppress delivery to stale topics. Recheck current permission for every durable read. Join-time authorization or cooperative client unsubscribe alone is insufficient.

These approvals preserve the settled 24/48/72-hour timing, no money movement from schedules, private application-only chat, immutable one-review-per-direction eligibility after finalized completion, and separate worker/poster averages. The realtime and reminder designs still require the actual local boundary evidence stated in the Phase 5 guide before they can be claimed complete.

## Phase 5 Step 4 implementation authorization — 11 November 2026

The user approved the Phase 5 Step 4 implementation locally after clarifying that delivery exceptions belong on the authorized administrator/operations side. This authorizes durable in-app/email intents, a loopback-only synthetic email capture, retry/reconciliation state, and status-only operations access under a distinct current AAL2 grant. It does not authorize Zoho, a real mailbox, live delivery, SMS, hosting, or a production screen. The local retry/lease numbers are implementation settings, not a new product promise.
