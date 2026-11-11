# Repository instructions

## Authority and delivery

- Follow the approved root [`spec.md`](spec.md), the canonical [`docs/product.md`](docs/product.md) and [`docs/technical.md`](docs/technical.md), and the active phase guide. Product and financial rules must not be silently changed. Keep newer provider research in [`docs/bachs-payments-reference.md`](docs/bachs-payments-reference.md) and surface conflicts for an explicit decision.
- Deliver backend foundations and prove permissions, state transitions and operational recovery before production UI work. Design may proceed in parallel. When UI implementation begins, design mobile-first at 320–430 CSS px before expanding to desktop.
- Keep each page file at or below 300 lines; extract cohesive sections and reuse shared controls without artificial fragmentation.
- Use narrow, least-privilege permissions. Treat migrations as the schema source of truth; dashboard-only schema changes are not authoritative.
- Verify and pin backend runtime, framework and adapter versions through compatibility checks before relying on them.

## Financial and trust invariants

- Store internal NGN amounts as integer kobo; never use floating-point money arithmetic.
- Fund jobs for exactly the poster-displayed total: gross per worker multiplied by funded slots. Platform funds cover provider processing, payout and refund costs; do not add provider charges to the poster or reduce promised worker earnings.
- Keep journals immutable. Correct mistakes with compensating entries; do not edit or delete posted journal history.
- Timers, silence, reminders and cron may prompt review or reconciliation but never authorize money movement.
- Require two distinct qualified human approval records for every beta admin money outcome. A qualified decision proposer may provide the first approval; a different qualified human must provide the second. Both records bind to the immutable decision version, and neither may be a case party or service account.
- Keep real-money movement and real identity-document intake gated until their documented provider, privacy, operational and approval requirements pass. Use synthetic fixtures meanwhile.

## Verification

- Add tests for risky rules and trust boundaries, including authorization, financial arithmetic, idempotency, concurrency, state transitions, provider uncertainty and independent approvals.
- Do not claim a rule is enforced without evidence from its command/database boundary. Never use privileged-owner-only checks as proof of client permissions.
- Keep credentials, real identity data, bank details, OTPs and customer data out of source control, fixtures and logs.
