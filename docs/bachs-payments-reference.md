# Bachs payments reference — NoBrokeDayz

Checked: **29 October 2026**. Official public documentation reviewed, starting from the API introduction identified in Safari. This is an evidence note for implementation planning, not Bachs approval of NoBrokeDayz or proof of tested integration. No account settings, API calls, payments or provider communications were performed. Links below were checked on this date unless noted otherwise.

## 1. What the public documentation establishes

### Collections and exact amounts

Bachs uses major-unit **decimal strings**, not integer minor units: `"75000.00"` means ₦75,000.00. The published API uses separate sandbox and production hosts, scoped Bearer secret keys and `/v1/` routes. Keys belong on the server. [API standards](https://docs.bachs.io/api-reference/api-standards)

**NoBrokeDayz recommendation:** retain integer kobo internally and make the provider adapter convert exactly at its boundary: 7,500,000 kobo becomes `"75000.00"` NGN. Never send the raw internal integer or calculate money with binary floating-point. Test round trips, fractional naira, maximum amounts and currency mismatches.

An existing catalog product can receive a per-checkout fixed-price override in `product_cart[].pricing`; the override uses its primary currency and does not change the catalog. `POST /v1/checkout-sessions` returns the checkout ID, amount, currency and hosted URL. This supports a server-computed job funding total without a new product per job. [Ad-hoc pricing](https://docs.bachs.io/guides/checkout/adhoc-pricing)

Collection confirmation uses `collection.succeeded`. Its payload distinguishes gross amount, settlement amount and processing fee; correlate checkout/reference, currency and amount with the stored funding instruction before crediting the ledger. Deduplicate event IDs. A `charge_id` can be null in test/legacy/manual-reconciliation scenarios. Virtual-account deposits lack checkout/order references and require separate matching. [Collection event](https://docs.bachs.io/guides/webhooks/events/collection-succeeded)

**Recommendation:** use fixed, server-priced checkout sessions for MVP job funding. Treat redirects as display/navigation only. Unexpected sums, unmatched payments and null IDs enter reconciliation rather than silently funding a job.

### Delayed awards: separate transfers are the better candidate

The generic marketplace guide chooses a destination charge: the platform collects, and the recipient's share moves automatically when the charge settles. This timing is different from NoBrokeDayz's completion/dispute/approval conditions. [Marketplace guide](https://docs.bachs.io/connect/marketplaces/overview)

Bachs also documents a platform charge followed by standalone transfers, including splitting one charge across several recipients on the platform's schedule. The platform retains whatever it does not transfer; this shape does not use a moving `platform_fee` field. Supply `transfer_group` to correlate operations, but Bachs does not enforce charge-to-transfer linkage or funding allocation for you; the guide also says this is not a transfer-list query filter. [Separate transfers](https://docs.bachs.io/connect/split-payments/separate-transfers)

Transfers consume available funds, not pending funds. Collections can succeed before settlement; an early transfer fails for insufficient balance. `X-Account-Id` selects an account when acting on its behalf. [Money movement](https://docs.bachs.io/connect/money-movement)

**Architecture inference:** collect into the platform, record each job's reserved funds in NoBrokeDayz's ledger, and transfer authorized worker awards only after both provider settlement and product release conditions. A ledger reservation is not a provider escrow account. Keep per-job allocation and commission reconciliation locally; pooled provider availability alone must never authorize spending another job's reserved money.

### Capabilities, identity and live approval

Connect supplies separate financial identities and balances for recipients. Workers need not independently sign up for a Bachs account. [Connect overview](https://docs.bachs.io/connect/overview)

Capabilities belong to `merchant` or `recipient` configurations; applying a persona does not prove its capabilities are active. Read returned capability statuses and requirements. Request only required capabilities. [Capabilities](https://docs.bachs.io/connect/capabilities)

Live Connect requires registered-business compliance and active production `connect`. Sandbox access does not authorize live use; secrets/endpoints are environment-specific. [Take Connect live](https://docs.bachs.io/connect/go-live)

Sandbox can grant capabilities without exercising full live verification and makes settlement immediate; live may have settlement delays and review. Therefore a successful sandbox scenario does not establish acceptable KYC or live holding permission. [Testing Connect](https://docs.bachs.io/connect/testing)

**Still unconfirmed:** NoBrokeDayz's exact worker identity requirements, treatment of student/minor accounts, beneficial ownership/custody, permissible conditional holding and maximum holding duration, dispute/appeal freezes, reserves, and provider intervention rights. Do not label this model legally or contractually approved escrow based on API capability alone.

### Payouts and funding provider fees

Withdrawals require active `payouts`, completed identity checks, an approved usable destination belonging to that account holder, and sufficient available funds including fees. Thus paying workers from the platform to arbitrary third-party bank accounts should not be assumed equivalent to withdrawing each worker recipient's balance. [Payout overview](https://docs.bachs.io/guides/payouts/overview)

Manual payouts are supported through the dashboard and API. Track completion rather than interpreting creation as delivery. [Create a payout](https://docs.bachs.io/guides/payouts/payout-using-api)

Automatic schedules cover eligible settled customer collections, excluding transfer-funded credits. Configure affected platform currencies as manual so schedules cannot drain job funding; verify actual account settings. Worker balances funded by separate transfers are not automatically paid by that schedule mechanism. [Automatic payouts](https://docs.bachs.io/guides/payouts/payout-schedules)

Published default NGN rates are 1.5% capped at ₦2,000 for checkout bank transfers, 2% for local cards, and ₦50 for bank withdrawals. Account-specific pricing can differ. Withdrawal fees are added to the withdrawal debit; reconcile `total_debited`. The fee page lists NGN settlement as immediate, but build against actual available balance. [Fees](https://docs.bachs.io/for-you/fees)

Checkout `customer_bears_fee: false` makes the collecting account absorb processing costs. `fee_preference` is the account write setting; `fee_handling` is its read representation. Connected-account `responsibilities.fees.collector` is a different, creation-only control for direct-charge processing costs; it does not establish platform subsidy of withdrawal fees. Read actual payment fees rather than guessing. [Processing fees](https://docs.bachs.io/connect/processing-fees)

**Recommendation:** preserve the promised worker net amount and exact poster total. Maintain platform-funded reserves for processing, withdrawals and refunds. Confirm how to fund a recipient's withdrawal fee without granting spendable worker income accidentally. No specific NGN payout minimum was established in the reviewed pages; query actual account/route requirements and test boundaries. The route guide confirms NGN-to-Nigerian-bank support, not unrestricted account eligibility. [Supported payout routes](https://docs.bachs.io/guides/payouts/global-payouts)

### Refunds and chargebacks: material limitations

The refund guide supports full or partial refunds, but **NGN bank-transfer payments are listed as non-refundable through this refund flow**. One payment takes one refund: after a successful partial refund, the remainder cannot be refunded later through another refund. Failed refunds do not count. Check `is_refundable`; refund currency follows settlement currency. Omit amount for full refund; use a decimal string for partial refund. [Refund guide](https://docs.bachs.io/guides/refunds)

For platform-owned collections, refunds debit the platform; prior transfers and fees do not automatically unwind. Returning a recipient's available funds is a **new transfer**, not reversal of the original movement. Withdrawn funds cannot be automatically recovered through this mechanism. [Connect refunds](https://docs.bachs.io/connect/refunds)

Chargebacks are separate from NoBrokeDayz job disputes. Opening a provider dispute sets aside disputed funds and incurs a fee; a loss can create a negative platform balance and block transfers/withdrawals across currencies. [Connect disputes](https://docs.bachs.io/connect/disputes)

**Launch blockers:** obtain an approved NGN bank-transfer repayment path and policy for repeated partial outcomes, confirm fee coverage and reserve requirements, and test them. Do not claim every payment rail supports the same refund behavior. Do not automatically debit a settled worker's application wallet to conceal a provider loss.

### Idempotency and uncertain outcomes

Public `/v1/` POST/PATCH operations accept `Idempotency-Key`. Bachs caches successful JSON responses for 24 hours per API key/acting account. GET/DELETE are outside this middleware. Keep the same key and exact request on retries; changed fingerprints cause `IDEMPOTENCY_CONFLICT`, while overlapping execution can return `IDEMPOTENCY_IN_PROGRESS`. Cache hits do not extend retention. A timeout/5xx can still mean the operation happened; unsuccessful responses are not cached. Reconcile via stored provider IDs and documented retrieval/list routes before retrying, particularly after expiry. If outcome remains unknown, investigate with the provider request ID rather than issuing a fresh operation. [Idempotency](https://docs.bachs.io/guides/idempotency)

**Recommendation:** persist operation intent, request fingerprint, acting account, key, provider IDs and unknown-result status before external writes. Keep ledger effects unique independently of provider caching.

### Webhook verification and delivery

Use the endpoint signing secret, not the API secret. The signature is hexadecimal HMAC-SHA256 over timestamp, a period and the **unchanged raw body**. Legacy headers are `X-Bachs-Timestamp` and `X-Bachs-Signature`; new integrations should prefer `X-Bachs-Signature-V2` containing `t=` and one or more `v1=` signatures. Accept any valid rotation signature with constant-time comparison. The published example uses 300-second timestamp tolerance; rotation normally overlaps for 24 hours. Parse JSON after verification. Return 2xx after durable receipt, within 10 seconds. Delivery has five attempts; persistent failures can disable an endpoint. Set `event_source: all` or `connect` for recipient events. Relevant types include `collection.succeeded/failed/underpaid`, `payout.created/paid/failed`, `refund.created/paid/failed`, `dispute.created/updated` and `capability.updated`. [Webhook guide](https://docs.bachs.io/guides/webhooks/overview)

Replay creates another delivery attempt for an existing event, not a new financial operation. The replay route is `POST /v1/webhooks/replay`, supporting event/charge/reference lookups. [Replay guide](https://docs.bachs.io/guides/webhooks/replay-events)

**Tests required:** raw-body mutation, wrong secret, stale/future timestamps, repeated `v1`, rotation, duplicate and out-of-order events, recipient-account mismatch, unrecognized event, crash after durable receipt, retry exhaustion, disabled endpoints and reconciliation after missing delivery.

## 2. Evidence gates before production

1. **Published documentation:** this note establishes candidate shapes and constraints, not an implementation guarantee. Two specialist pages (destination charges and Connect payouts) were unavailable through the research fetcher; related accessible official guides support the conclusions above.
2. **Account-specific written acceptance:** confirm the full NoBrokeDayz money lifecycle, holding duration/custody, worker KYC, freezes, fees, refunds and chargebacks. Record the provider reply and applicable terms. Public docs do not close this gate.
3. **Sandbox integration evidence:** pin actual endpoint schemas/event payloads, test exact totals and unit conversion, multi-worker releases, unknown writes, refund limitations and fee subsidy. Do not invent undocumented routes or import another provider's signature algorithm.
4. **Controlled live verification:** only after account approval, validate real capabilities, usable destinations, settlement, fee accounting, signatures and authorized small-value payout/refund paths. Keep approvals, sanitized request IDs, ledger reconciliation and test results with the payments milestone documentation.

The approved product scope stays intact. The refund and holding findings are unresolved provider compatibility constraints requiring explicit resolution before live money, rather than silent changes to the product promise.
