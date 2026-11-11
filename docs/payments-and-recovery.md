# Payments, ledger and recovery contract — Phase 3 local closeout

Status: Steps 1–10 have local synthetic implementation/test evidence. Collection, payout, settlement and liquidity inspection use only the loopback fake adapter. There is no Bachs adapter, real bank destination or real provider movement. Command-level partial verification and the closeout result are recorded in [phase-3-milestone.md](phase-3-milestone.md).
Prepared: 4 November 2026.

The approved financial promise is the source of truth: poster funds exactly the displayed gross total; worker earnings are calculated per allocation; platform funds processing, payout and refund costs; ledger history is immutable; time and silence never authorize movement. The account chart seeds no spendable user money. Step 4 stores the exact funded terms and collection operation before the simulator boundary; only an authoritative simulator result can post the funding journal, create one held allocation per slot and publish `open` or `expired`. Step 7 completion moves one allocation into the worker's internal available earnings. Step 8 atomically reserves those earnings and a durable payout operation before the local runner calls the fake provider outside the database transaction. Step 9 reconciles simulator liquidity against journal-derived state and provides audited read-only tracing. These are local simulated records and results, not real funds or a bank payment.

## Separate money amounts

Do not conflate these amounts:

| Amount                                          | Meaning                                                                                                                      | Example for one worker                 |
| ----------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- | -------------------------------------- |
| Draft per-worker gross                          | Poster-entered price for one slot, before any commission.                                                                    | `300000` kobo = ₦3,000.00              |
| Poster funding total                            | Exact checkout amount: per-worker gross × funded slots.                                                                      | Three slots: `900000` kobo = ₦9,000.00 |
| Collected gross                                 | Exact customer charge validated against the funding intent. Must equal the displayed total.                                  | `900000` kobo                          |
| Provider fee                                    | Provider's processing cost, recorded as a platform expense. Never added to poster total or deducted from worker entitlement. | If ₦45: `4500` kobo                    |
| Provider net settlement / receivable            | What the provider owes or has actually cleared after its fee. This can be less than collected gross and may not yet be cash. | `895500` kobo before settlement        |
| Funded slot principal                           | One gross allocation for one funded worker slot. Three slots mean three separate `300000` kobo allocations.                  | `300000` kobo                          |
| Worker net after authorized ordinary completion | Gross awarded less the 5% commission rounded once, half-up, in integer kobo.                                                 | `285000` kobo                          |
| Commission                                      | 500 basis points of awarded gross. This belongs to the platform and is not a provider fee.                                   | `15000` kobo                           |
| Withdrawal amount                               | User's requested bank receipt. Provider fees are separate platform expenses.                                                 | `285000` kobo delivered to worker      |

For three slots at ₦3,000, the poster owes exactly ₦9,000. The system creates three ₦3,000 principal allocations. Each ordinary completion records ₦2,850 worker net and ₦150 commission. The provider's collection fee does not change any of those values.

## Money representation and arithmetic

Persist internal NGN values as positive/nonnegative integer bigint kobo. Never use floating-point arithmetic. Validate amount range before multiplication and use integer/bigint operations throughout. In every JSON response, encode each amount as a base-10 integer string, for example `"amount_kobo":"285000"`; never emit a JavaScript `number`, decimal-naira string, exponent notation or formatted display value as the authoritative amount. The UI may format a safe parsed decimal string for display.

Commission is exactly 500 basis points of gross awarded for that allocation:

```text
commission_kobo = floor((gross_awarded_kobo * 500 + 5000) / 10000)
worker_net_kobo = gross_awarded_kobo - commission_kobo
```

This is round-half-up to the nearest kobo and uses integer/bigint arithmetic. Example: ₦3,000 gross (`300000` kobo) gives ₦150 (`15000`) commission and ₦2,850 (`285000`) worker net. A later partial-award workflow must apply this formula to the awarded gross only; no commission is charged on the refunded share. It is disabled in Phase 3.

Reject zero, negative, fractional-kobo, malformed, overflowed and out-of-approved-range values at the HTTP and database boundaries. Compute total with checked bigint multiplication and require exact equality to `gross_per_worker_kobo × slot_count`. Round once per allocation, not once on a job total and not from a binary floating-point intermediate.

## Private account groups and accounting entries

The local private chart is seeded by Step 2. It keeps these values in separate account groups:

| Class                      | Logical account                                                                                                                                                         |
| -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Assets                     | `provider_collection_receivable`, `provider_available_cash`, `platform_fee_reserve_cash`                                                                                |
| Held principal liabilities | `job_principal_unassigned`, `job_principal_assigned`, and a separately tagged `job_principal_dispute_held` subaccount                                                   |
| Worker liabilities         | `worker_earnings_available`, `worker_withdrawal_reserved`                                                                                                               |
| Poster liability           | `poster_refund_payable` for an explicitly authorized later refund only; no Phase 3 command creates one                                                                  |
| Income                     | `platform_commission_revenue`                                                                                                                                           |
| Expenses                   | `provider_processing_fee_expense`, `provider_payout_fee_expense`, `provider_refund_fee_expense`, `provider_delivery_fee_expense` and `provider_chargeback_loss_expense` |

The ledger uses immutable balanced journal transactions. Each row carries a business-effect identity; a posted journal cannot be edited or deleted. Corrections append a compensating journal with its own reason, actor/operation and original-effect reference. Account balances are transactionally updated and rebuildable from journal history; clients and the generic service role cannot set them or write financial rows. The controlled posting function validates balance and integer-string amounts before inserting entries, projections, audit and outbox records in one transaction. `record_exact_funding` accepts an already-recorded exact successful result, then atomically creates one allocation per slot, posts the collection/fee/receivable effect and marks the immutable intent succeeded. Both helpers are executable by `postgres` only; no Edge or client gateway is exposed in Step 2.

The chart includes a `platform_capital_contributed` source account. It and all user accounts start at zero; test capital entries are transaction-scoped synthetic setup only. No account is credited with user-spendable earnings until a later authorized marketplace command. The database tests use a synthetic provider-operation fixture to exercise exact gross/fee/net accounting; this is not the Step 3 fake adapter or a Bachs capability.

| Event                                                                                                        | Balanced journal / state effect                                                                                                                                                                                                                                                   |
| ------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Exact charge succeeds for gross `P`; provider fee `F` is authoritative and net amount `N=P-F` is receivable. | Dr `provider_collection_receivable` `N`; Dr `provider_processing_fee_expense` `F`; Cr `job_principal_unassigned` `P`. This records gross principal without pretending net settlement equals gross. If already settled, debit `provider_available_cash` instead of the receivable. |
| Provider settles the receivable.                                                                             | Dr `provider_available_cash` `N`; Cr `provider_collection_receivable` `N`. Settlement changes asset state only; it creates no second principal credit.                                                                                                                            |
| Poster accepts an application.                                                                               | Dr `job_principal_unassigned` `P`; Cr `job_principal_assigned` `P`. The same allocation ID remains attached to one assignment; no principal is duplicated.                                                                                                                        |
| A participant opens a hold.                                                                                  | Dr `job_principal_assigned` `P`; Cr `job_principal_dispute_held` `P`. This balanced internal reclassification creates no new principal, worker credit or external movement; only that allocation is blocked and its prior assignment work state is preserved.                     |
| Poster confirms submitted assignment gross `P`; commission `C`; net `W=P-C`.                                 | Dr `job_principal_assigned` `P`; Cr `worker_earnings_available` `W`; Cr `platform_commission_revenue` `C`. One effect per assignment.                                                                                                                                             |
| Worker requests withdrawal `W`.                                                                              | Dr `worker_earnings_available` `W`; Cr `worker_withdrawal_reserved` `W`. This is a reservation, not proof of provider submission or bank receipt.                                                                                                                                 |
| Provider confirms payout `W` and charges fee `Q`.                                                            | Dr `worker_withdrawal_reserved` `W`; Dr `provider_payout_fee_expense` `Q`; Cr `provider_available_cash` `W+Q`. The user still receives exactly `W`; the fee is separately funded by platform reserve/cash.                                                                        |
| Platform moves fee reserve into the provider account to cover a known fee/shortfall.                         | Dr `provider_available_cash` `Q`; Cr `platform_fee_reserve_cash` `Q`. This is an asset transfer from platform funds, not job funding or an increase in principal.                                                                                                                 |

Every journal transaction balances. For each slot allocation:

```text
held_principal
+ worker_net_allocated
+ commission_allocated
+ poster_refund_allocated
= funded_principal
```

Reservations, receivables, settlement and payout are states/subaccounts within these values; they do not add another copy of principal. A later permitted refund can only reclassify a held allocation into `poster_refund_payable`, then clear it on an authoritative provider result. The one-charge/multiple-refund compatibility issue is unresolved, so all refund commands and outcomes stay disabled.

### Cash, receivable and fee availability

`provider_collection_receivable` is not cash and cannot support a new payout. A successful collection may fund the internal job liability while net settlement remains receivable; it does not prove immediate withdrawable liquidity. A withdrawal request with enough worker earnings and a valid confirmation is accepted and atomically reserved. If cleared provider cash or platform fee reserve is not yet sufficient, its durable operation remains `queued_for_liquidity`; no provider write is made until the existing user authorization can be executed safely. When liquidity is sufficient, the operation can be dispatched using that recorded authorization. This queue is visible to the worker and ops; no age-based timer automatically releases it. Platform fee reserve is separate from every job allocation. Never take another job's reserved principal, reduce worker amount, add a poster fee, or report a failed provider movement without evidence. A failed operation can restore the worker reserve only after authoritative failure.

The conceptual dispatch check is:

```text
cleared provider cash
- cash ring-fenced for every other unresolved job allocation
- cash reserved for already-authorized provider operations
+ platform fee reserve explicitly available to this operation
>= exact worker receipt + known provider fee
```

Receivables are excluded. If the provider's pooled balance cannot be reconciled to this check, do not dispatch; leave the authorized request queued for human/settlement reconciliation. A provider's pooled balance by itself never unlocks another unresolved allocation.

The operations check must reconcile provider cash/receivables, platform fee reserve, all held allocations, withdrawal reservations and unresolved operations. The provider balance is pooled externally; local authorization remains tied to the specific assignment/allocation and exact user payout. Pooled provider balance alone does not authorize spending any other job's held principal. Actual account funding and custody arrangements remain a Bachs live gate.

## Durable idempotency and unknown-result recovery

Keep application and provider progress dimensions separate. A funding intent uses `pending`, `unknown`, `succeeded`, `failed`, `cancelled`, or `exception`; `exception` covers a reported amount/currency/reference mismatch and blocks publication. Provider settlement is a separate `pending`/`available` fact. A withdrawal operation uses `queued_for_liquidity`, `processing`, `unknown`, `paid`, `failed`, or `reversed`. `failed` and `reversed` are recorded only from authoritative evidence. A user-visible `processing` amount is not called paid.

All state-changing user commands take an idempotency UUID. Scope uniqueness by authenticated actor and command; persist a canonical request fingerprint. The same actor/command/key and identical input returns the original safe response. Reusing that key with different input returns `idempotency_conflict`/`stale_state` and creates no effect. Different users do not share idempotency scope.

Before any external provider write, commit an immutable operation intent with operation ID, exact request/fingerprint, actor or business authorization, amount, currency, allocation/effect IDs, destination version when relevant, and one stable provider idempotency key. The provider call is outside the SQL transaction. A browser redirect, client assertion, timeout, 5xx or missing callback cannot be interpreted as success or failure.

| Condition                                                                     | Required behavior                                                                                                                                                                                                                                                 |
| ----------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Funding pending                                                               | Keep listing `awaiting_payment`; do not create allocations or publish. Reuse the same funding intent for status checks.                                                                                                                                           |
| Funding unknown / timeout after possible acceptance                           | Mark local result unknown; lookup the original provider reference/key before retrying. Do not create another charge or change its fingerprint. No publication.                                                                                                    |
| Funding exact success                                                         | Validate merchant/account, reference, currency and gross against the server-created intent; record one collection effect and one allocation per slot. Deduplicate both provider event ID and business effect.                                                     |
| Funding definitively failed/cancelled                                         | Only after authoritative terminal evidence with no possible success, return the unfunded job to `draft`; preserve the old attempt and terms version. A later attempt gets a new operation/idempotency key. Never use this path for unknown or mismatched amounts. |
| Funding mismatch, underpayment, overpayment, duplicate or unmatched reference | Keep job blocked and create a restricted ops exception. Never silently apply extra or partial funds to a job.                                                                                                                                                     |
| Provider payout pending or unknown                                            | Keep the exact amount in `worker_withdrawal_reserved`; query the original operation/reference. Do not create a new payout or restore funds.                                                                                                                       |
| Authoritative payout failure                                                  | Append one compensating journal to restore the reservation. A retry is a new operation only after the first is definitively failed and user intent is reconfirmed.                                                                                                |
| Authoritative payout success                                                  | Record bank delivery only from the provider's authoritative result; settle the reserved liability once. A request acceptance or client redirect is not success.                                                                                                   |
| Later authoritative reversal                                                  | Record a separate incident and compensating financial event once. Never silently debit unrelated workers or rewrite the original success.                                                                                                                         |
| Duplicate/out-of-order callback                                               | Store receipt once, compare provider object and current operation state, ignore duplicates without a second journal; terminal state cannot regress.                                                                                                               |

Provider webhook receipts and ledger business-effect uniqueness are separate protections. Reconciliation may update knowledge about an existing authorized operation; it cannot invent authorization for a new release, refund or payout. Timers, cron and reminders may request reconciliation and surface an exception only.

## Fresh confirmation and exact destination binding — implemented locally

The Step 8 routes use current Supabase Auth `/user` identity and a separate fresh-password grant. The returned Auth tokens are discarded and never put in a response or log. A valid check issues a random one-use proof whose SHA-256 digest is stored privately with actor, action, exact amount where relevant, destination ID/version and a five-minute expiry. `confirmed: true`, timestamps, caller identity and provider status are not accepted as substitutes.

Destination-change authorization binds the current destination version, next version and allow-listed synthetic recipient code. Confirmation consumes that proof and appends a new immutable version. A withdrawal proof binds the exact positive integer-kobo amount, destination ID and exact current version. The final request rechecks current student `can_work`, destination version and available earnings; it consumes the proof, reserves earnings from their source allocations, records the withdrawal snapshot and writes the stable payout operation/job in one database transaction. Replay, expiry, changed amount/recipient/destination/version, same-key altered input or a concurrent overspend fails without a second effect. A later destination version never retargets an existing withdrawal.

The only destination values in this step are synthetic local labels and masked `SIM-*` references with `ownership_verification:"simulator_only"`. There is no account number, bank-detail storage, real ownership check, KYC or Bachs endpoint. Real destination intake and verification remain live-service blockers. The five-minute fresh-password mechanism and immutable destination version rules are local Phase 3 decisions recorded in [decisions.md](decisions.md).

## Withdrawal reservation and payout accounting — implemented locally

An authorized request is always visible as `queued_for_liquidity` until the saved exact receipt plus expected provider fee can be covered. Once liquidity is sufficient, the existing operation becomes `processing`; the operation runner calls the simulator outside the SQL transaction and looks up its original client reference before any retry. The request never consumes another job's principal, never shrinks the worker's exact requested receipt and cannot pay a changed actor or destination. Receivables are not cash. A timer does not release or retry authorization.

The Step 8 accounting reclassifies only worker earnings from the exact originating allocation to withdrawal reserve. On authoritative success it clears that worker reserve, records the fake recipient's exact requested amount, expenses the separately reported provider fee and reduces provider cash by amount plus fee. A fee shortfall may move explicitly contributed platform fee-reserve capital into provider cash; neither job principal nor worker income funds the provider cost. The local Edge journey uses a synthetic `20000`-kobo provider fee configuration and a separate `5000`-kobo platform capital contribution to cover its fee gap; these are test values, not a platform fee, minimum, live reserve recommendation or Bachs price. In the wallet response, the total withdrawal-reserved bucket includes its queued/processing/unknown status slices; poster-held principal and worker allocation buckets are separate perspectives and must not be added together.

Unknown results retain the full worker reserve and retry by original operation identity. Only authoritative failure restores the same earnings once; a later authoritative reversal appends a compensating journal once and restores the exact source earnings. The normalized local fake reports the payout fee charged but has no separate fee-refund fact, so reversal returns only the payout principal and leaves the fee as platform expense. Do not infer fee reimbursement for Bachs. Duplicate callbacks schedule lookup and do not set status or change amount/destination. Full refunds, partial awards, chargeback debits, case resolution, appeals and automatic releases remain disabled.

## Fake provider contract — local only

The normalized fake adapter is `supabase/functions/_shared/payment-adapter.mjs`. It supports:

```text
initializeCollection(operation) -> NormalizedOperation | null
lookupOriginalOperation(operation) -> NormalizedOperation | null
createPayout(operation) -> NormalizedOperation | safe failure
lookupPayout(operation) -> NormalizedOperation | null
createRefund(operation) -> NormalizedOperation | safe failure
lookupRefund(operation) -> NormalizedOperation | null
verifyEvent(rawBody, headers) -> a verified simulator event, or null

NormalizedOperation = {
  reference, clientReference, operationType, status, amountKobo, feeKobo,
  currency, merchantIdentity, destinationId, destinationVersion,
  settlementStatus, sourceReference
}
```

For collections, `merchantIdentity` is fixed to the synthetic `fake_nbd_local_merchant_v1` and bound to the saved funding intent; it is not a real merchant account or a browser field. For payouts, the adapter result includes the exact destination ID and immutable version alongside requested amount and provider fee. Refund results include the saved original charge reference. Results are checked against saved operation identity, amount, currency and destination/source. Mismatches create restricted reconciliation exceptions and cannot publish a job, settle a withdrawal or clear a refund payable. All kobo values cross JSON as decimal strings. The application operation row is saved first; its insert creates one durable job in the same transaction. The server builds the operation from its saved identity, amount, type, destination snapshot or source charge mapping. The browser cannot choose the adapter or submit a provider status. `payment-operation-runner` accepts only an internal bearer secret and an empty request body; it claims a saved operation, looks up its original simulator identity first, and uses the same idempotency key if it must initialize. It records provider status only through the controlled result RPC, which applies the matching authorized funding, payout or refund effect. It never claims operations queued for liquidity.

The fake HTTP provider lives in `tests/fixtures/payments/simulator.mjs` and binds to IPv4 loopback. It creates one provider reference per operation idempotency key. Test code can program `pending`, `success`, `known_failure`, `unknown`, `reversal`, or `timeout_after_acceptance` outcomes and synthetic payout/refund fees. It can simulate collection/refund settlement and reversal directly through fixture controls; refunds require a successfully settled source collection and cumulative refunds cannot exceed that charge. It has no browser-accessible route for choosing an outcome or injecting callbacks. A lost response after acceptance leaves the app operation `unknown`; a restarted runner looks up the same key and does not create a second collection, payout or refund. A completed payout receipt carries the exact requested amount plus destination ID/version; any provider fee is separately reported and charged to platform expense/reserve. A refund's exact principal remains owed to the poster while processing or unknown; refund acceptance alone is not settlement or bank receipt.

Simulator callbacks use a separate server-only HMAC secret over the raw body, event ID and timestamp. This is a local simulator protocol, not evidence of Bachs webhook verification. The callback handler has no user-auth path. It verifies the event, stores a digest-only receipt through one narrow server RPC, then acknowledges. Duplicate IDs with the same body are idempotent; altered signatures fail; a valid event with an unexpected provider reference becomes a reconciliation exception. Callback event status never changes the operation. A new receipt only schedules a lookup of the authoritative simulator operation, so duplicate or out-of-order events cannot authorize money movement.

`NBD_PAYMENT_MODE` defaults to `disabled`. `local_simulator` starts only when both `SUPABASE_URL` and `NBD_SIMULATOR_URL` are plain HTTP loopback URLs and the separate request, webhook and runner secrets are present. The fake mode rejects nonlocal endpoints and is not a Bachs mode. The fake adapter has a separate `10,000,000,000` kobo (₦100,000,000) local test-input guard; a job's `1,000,000,000` kobo (₦10,000,000) total and withdrawal's `1,000,000,000` kobo (₦10,000,000) amount are local validation limits only. None is an approved live exposure cap or provider limit/minimum. Test secrets are generated in memory. The simulator uses no bank details, real account, external service, Bachs integration or real funds. A synthetic destination token is only an opaque test value.

Jobs use 30-second leases and at most five claims. Retry delays are 2, 4, 8 and 16 seconds; an unresolved result stays unknown and stops automatically after the fifth claim. A newly verified simulator event may start another bounded lookup cycle for the same operation. No retry creates a new authorization or operation identity.

## Step 9 notices, operations inspection and reconciliation

Marketplace and wallet business transactions save domain events, durable outbox rows and their financial effects in the same database transaction. Application/acceptance/submission/release notices use those existing immutable marketplace events. Withdrawal request, processing, unknown, paid, failed, reversed and exception notices use immutable financial audit events. A notice is unique per recipient/event/type. `/functions/v1/notifications-read` derives the recipient from Auth and supports a stable 20-row cursor plus recipient-only first-read acknowledgement. Its projection contains only notice ID/type, a safe title and timestamps.

The financial outbox is durable local recordkeeping; Step 9 adds no email/SMS sender or scheduled reminder delivery. A transport failure cannot remove a notice or roll back money, and no successful email/SMS is inferred. Real Zoho/SMS delivery and full reminder scheduling remain later work.

`/functions/v1/ops-financial-inspection` offers only `trace` and `reconcile` in local simulator configuration. Each request validates Auth `/user`; the caller must be active, hold the current `financial_inspect` grant and have AAL2. The SQL boundary repeats the active-account and grant check. Trace accepts a saved operation ID, local `sim-...` provider reference, funding intent, withdrawal, journal, job or reconciliation-run ID. Results are bounded to related operations, allocations, journals, exceptions, reconciliation findings, marketplace/financial outbox state and safe audit fields. Full bank data, identity evidence, raw provider payloads, secrets, tokens and lease values are excluded. Inspection adds an attributable access event and cannot post journals, release held funds or make case decisions.

Reconciliation takes cash and collection receivables from the server-authenticated local simulator adapter; the browser cannot supply or override them. It compares those figures with journal-derived ledger balances/projections, held principal liabilities, unresolved provider operations and audit-chain integrity. Each immutable run stores its result and findings; a later trace by run ID retrieves them. A mismatch is evidence for review only; reconciliation does not correct balances, change an operation, create a new payment identity or authorize money movement.

Financial audit events are append-only and receive an internal SHA-256 chain entry. The integrity check detects edits or missing rows relative to that chain. It is not an independent signed checkpoint, and no external witness or key-management assurance is claimed. `signed_checkpoint_proven` is always false in the reconciliation response until that later workflow exists.

## Bachs adapter — not implemented

There is no Bachs adapter, API request, account connection or live/sandbox integration in this phase. The normalized contract above describes only the local fake. The separately maintained [Bachs payments reference](bachs-payments-reference.md) records public-documentation research only. It reports candidate fixed-price checkout sessions, collection event fields that distinguish gross/settlement/fee, documented provider idempotency and webhook signing, separate transfers and manual payouts. Those public facts still require current account-specific verification and do not establish No Broke Dayz's holding, KYC, fee, reserve or live approval arrangements.

The same research records material refund uncertainty: the published refund guide excludes NGN bank-transfer payments from that refund flow and permits only one successful refund per payment. It also describes transfers as requiring available funds. The approved product refund entitlement stays intact, but payment rail, refund mapping and any alternative must be explicitly resolved before a Bachs adapter or live money can be enabled. Do not map fake-provider status names, query behavior, immediate settlement, fee rules, reversal behavior, destination tokens, callbacks or idempotency guarantees onto Bachs without evidence.

## Disabled financial outcomes

Phase 3 by itself has no job/assignment cancellation, refund or partial refund, dispute decision, appeal, admin release/refund, chargeback recovery debit, or automated movement after a deadline. Phase 4 Steps 1–8 now add local synthetic cancellation, case outcome and refund-settlement workflows. The owner-approved rule remains two qualified approval records total for beta admin money decisions, with the proposer permitted as the first and a different human as the second. Local synthetic provider behavior does not establish a Bachs capability.

## Phase 4 owner decisions and Step 8 local refunds

On 5–6 November 2026, the owner approved two distinct qualified approval records total; a qualified proposer may supply the first, and a different qualified human supplies the second. The owner also approved a balanced internal hold-classification restoration for no-action outcomes; it authorizes no award or refund. Required grants, AAL2, case-party conflicts and version binding still apply.

Phase 4 Step 8 extends the same local queue and simulator to process only already-authorized cancellation or finalized-case refund payables. Immutable mappings preserve the source collection and exact allocation. Cleared principal must be present; a platform fee reserve can cover provider fees without reducing the poster's promised amount. `processing`/`unknown` does not clear a payable; only confirmed settlement does. A verified reversal creates a separate reconciliation incident without rewriting the settlement journal. This local extension does not resolve the Bachs route; no provider compatibility or real bank receipt is claimed.
