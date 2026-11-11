# No Broke Dayz — Technical Specification

> **Transcription of supplied PDF; this is not the original Markdown file.**
>
> Source: `No_Broke_Dayz_Technical_Specification.pdf` — version 2.0, 26 October 2026 (17 pages). Extracted text was checked against rendered PDF pages, including tables, acceptance criteria, formulas and state names.
>
> This is the repository canonical copy of the source baseline. Newer provider findings remain in [`bachs-payments-reference.md`](bachs-payments-reference.md) and have not been merged into this transcription.

Version 2.0 | 26 October 2026 | Implementation baseline

Product owner: Mubarak Salaudeen

Implementation owner: founder as frontend and backend developer

Companion document: No_Broke_Dayz_Revised_PRD.md

Status: design complete enough to begin implementation; launch gates remain explicit

Architecture, data contracts, financial integrity and implementation checks for the UNILAG web MVP.

## 1 Purpose and engineering constraints

Implement the revised PRD as a mobile-first Next.js and TypeScript application on Cloudflare, with hosted Supabase as the primary backend. Use Supabase Free initially. Bachs handles approved payment/holding/payout operations, Africa's Talking handles transactional SMS, and Zoho CPaaS handles transactional email.

Keep a single repository, one web application including protected admin routes, and one transactional PostgreSQL database per environment. Use coherent business modules without separate deployments for each domain. No separate NestJS/Django service, Redis, Pusher, search cluster or additional database is needed for the MVP.

The highest priorities are exact financial behaviour, safe authorization, low latency on Nigerian mobile networks, low initial cost and clean handover. Reuse established platform capabilities instead of building authentication or WebSocket infrastructure from scratch. A managed platform does not remove responsibility for application permissions, accounting, testing or recovery.

This document specifies the target design; it does not claim a deployed system, a provider approval or measured production performance. Provider API endpoints, signatures and SDK versions must be verified against current account documentation during implementation. No undocumented escrow endpoint is assumed.

## 2 Service map and data paths

```text
 Service                                    Responsibility
 Cloudflare Workers                         Deploy Next.js, deliver web/admin UI, render pages where needed
 Cloudflare CDN and DNS                     Deliver static assets, HTTPS, domain routing and baseline network protection
 Supabase Auth                              Accounts, sessions, password recovery, email/phone verification and staff MFA
 Supabase PostgreSQL                        Business records, messages, ledger, permissions, job queue and domain events
 Supabase Data API                          Authorized reads and narrow ordinary writes protected by grants and RLS
 Supabase database functions                Atomic selection and state transitions close to data
                                            Authenticated sensitive commands, webhooks, provider integrations and job
 Supabase Edge Functions
                                            consumers
 Supabase Storage                           Private evidence/verification files and controlled profile images
 Supabase Realtime                          Private conversation broadcasts, read-state and user notification updates
 Supabase Cron and durable jobs             Reminders, delivery retries, reconciliation and recovery checks
 Bachs                                      Account-approved collections, held-fund arrangement, refunds and bank payouts
 Africa's Talking                           Delivery of Supabase-generated phone codes and approved security messages
 Zoho CPaaS                                 Transactional school-email codes, notifications and account emails
```

The browser authenticates with Supabase, then reads through RLS-protected Data API queries. Simple permitted writes use narrow grants. Multi-row user commands use a transactional RPC that checks current permissions. Money commands and privileged admin commands pass through Edge Functions that verify the user before invoking server-only database operations. Provider webhooks have separate provider authentication and never rely on user sessions.

Next.js must not duplicate the financial command implementation. Server rendering may read allowed data, but the same backend command enforces the action whether called from web, a future mobile app or Phase 2 AI.

### 2.1 Deployment and region

Use Cloudflare Workers for the dynamic Next.js deployment, not an assumption that Pages runs arbitrary Next.js servers. Pin the Next.js/runtime/adapter combination proven by a small compatibility test before UI build-out. Cloudflare's current documented recommendation is vinext, with OpenNext available for compatibility needs; verify support for routing, cookies, rendering, images and caching before adopting the exact version. Framework choice remains Next.js-compatible React/TypeScript; runtime tooling is an implementation check.

Choose a supported Supabase European region only after testing London, Ireland and Frankfurt routes from actual Nigerian mobile networks. Keep database-intensive Edge Functions near the database when measurements favour it. Avoid browser-to-Cloudflare-to-Edge-to-database forwarding when a single authorized browser-to-backend request is sufficient.

Maintain local development and isolated staging/production. Supabase Free currently permits two active projects; a practical starting layout is local development plus one hosted staging and one hosted production project where account limits allow. Separate Bachs sandbox/live keys, SMS/email configuration, buckets and callback addresses. Preview deployments point to staging, never production credentials.

## 3 Module boundaries and repository

Business modules are identity/verification, profiles, marketplace, assignments, messaging, payments/ledger, wallet, disputes, notifications and admin. Each module owns its rules, queries and tests; shared components serve repeated UI patterns. Do not abstract every one-off component or construct speculative future services.

### 3.1 Web application

README.md AGENTS.md .env.example package.json lockfile src/

```text
  app/                                      routes and protected admin entry points
  features/
     verification/
     profiles/
     jobs/
     assignments/
     messaging/
     payments/
     wallet/
     disputes/
     notifications/
     admin/
  components/ui/                            reusable visual controls
  lib/                                      small clients, validation helpers, generated types
```

### 3.2 Backend tests and handover

supabase/ config.toml

```text
  migrations/                               schema, constraints, grants, RLS, SQL functions
  functions/
    commands/                               sensitive user and admin command entry points
    bachs-webhook/
    send-auth-sms/
    send-auth-email/
    process-jobs/
    _shared/                                authentication, validation and provider adapters
  tests/                                    database invariants and allow/deny policies
  seed.sql                                  synthetic data only
```

tests/ integration/ e2e/ docs/

```text
  product.md                                canonical PRD in the implementation repository
  technical.md                              canonical technical specification
  decisions.md
  data-and-permissions.md
  payments-and-recovery.md
  runbook.md
```

.github/workflows/

This is a target repository structure, not a claim that an application repository already exists. Put the delivered Markdown documents into docs/product.md and docs/technical.md when initializing the real repository. PDF exports are review copies, not an independent source of truth.

Page files must stay at or below 300 lines. Split cohesive screen sections, data access or validation when needed; avoid artificial fragments created only to satisfy the count. AGENTS.md must record mobile-first design, these file-size/reuse standards, trust boundaries, financial invariants, required tests and canonical document pointers. Write it when the application repository is created, rather than creating agent instructions in the current document workspace.

Use SQL migrations as the schema source of truth and generate TypeScript database types. Pin dependencies and provide repeatable scripts for local start, type checking, linting, tests and deployment. No production schema changes only through a dashboard.

## 4 Identity authorization and secrets

### 4.1 Identity model

Supabase Auth owns credentials and sessions. An application profile references auth.users.id. Separate login email ownership, institutional email verification, phone verification, user type, verification approval and account suspension. Editable user metadata cannot determine staff or financial permission.

Authorize every request against current authoritative status. A stale JWT containing an old verified flag cannot bypass a later suspension. JWT claims can assist UI rendering, but sensitive commands recheck the database. For authenticated users with insufficient verification, allow only the narrow onboarding/help paths.

Student Track A completes only when the allow-listed school email is verified and shared phone/age requirements pass, or a staff reviewer approves the ID fallback and those shared requirements pass. Track B always requires staff approval of ID/campus evidence. Record each review, reason and reviewer. Institutional domain ownership is the agreed student proxy, not a claim of full identity proof.

Before launch verify school-email allow-list values and delivery to real school mailboxes. An additional institutional email must be bound to the existing account with a one-time challenge; do not create a duplicate auth user merely to verify school status. Support personal login email plus separate school-email challenge where needed.

### 4.2 Authorization layers

1. Table/schema grants control which operations a client role can attempt.
2. Row-level security controls which rows the authenticated account can access.
3. Column privileges or protected writes prevent changes to server-owned fields.
4. Command functions enforce ownership, role, state, financial invariants and idempotency.
5. Storage and Realtime have their own participant/staff authorization policies.
   Browser publishable keys are expected to be visible. Secret keys, provider secrets, signing keys and database credentials remain in server-side secrets. Supabase administrative credentials bypass RLS; every use therefore requires explicit identity/authorization checks.

Place financial ledger and private identity tables in unexposed schemas. Sensitive Edge Functions connect through a suitable pooled Postgres connection using a dedicated restricted server role to invoke private transactional functions. Its execution grants are narrow; it is not an unrestricted browser-accessible database login. The verified actor ID is derived from the validated access token, never accepted as authority from request JSON. Financial functions independently validate the actor's current capability and command preconditions.

If an implementation instead chooses a service-only Data API RPC gateway, prove equivalent grants and actor validation with allow/deny tests before use. Do not expose a privileged function callable by ordinary authenticated clients simply because its name includes internal.

Privileged SQL functions require a fixed empty search_path, schema-qualified objects and explicit execute grants; prefer invoker security where sufficient. RLS views must respect underlying policies, and public response shapes must exclude private columns.

### 4.3 Staff and sensitive actions

Require MFA for staff and fresh authentication for bank-detail changes, withdrawals and high-risk recovery. Supabase phone verification is not assumed equivalent to paid phone-MFA features; use supported Auth/session-assurance mechanisms and an explicit short-lived step-up challenge where needed. Single-use confirmation proofs bind actor, operation, amount and destination; changing any field invalidates the proof.

Staff role grants are audited and not self-service. Two-person decisions bind to an immutable decision version/hash; editing amount, recipient or reason invalidates approvals. The second approver must differ from the initiator. Appeal reviewer must differ from the original reviewer. A service account never counts as an independent human approver.

## 5 Domain data model

Use UUID primary keys, timestamptz timestamps stored in UTC and integer bigint kobo for NGN. Display local times with Africa/Lagos and explicit labels. Validate amounts without floating-point arithmetic; handle bigint serialization safely across JavaScript/JSON.

### 5.1 Identity and marketplace

**Entity Core fields and constraints**

user_id, display fields, campus_id, user_type, organisation_label; protected profiles system fields separated

user_id, verified_track, approval_state, phone_verified_at, age_confirmed_at, account_status suspended_at

**Entity Core fields and constraints**

user_id, normalized_email, domain, challenge_hash, expires_at, consumed_at; institutional_email_checks unique active ownership rules

user_id, track, method, state, evidence IDs, reviewer, reason, timestamps; verification_requests immutable review history

```text
 staff_grants                               user_id, capability, grantor, valid/revoked times
 categories                                 controlled slug, label, enabled flag
                                            poster_id, campus_id, immutable published scope, gross_per_worker,
 jobs
                                            funded_slot_count, needed_by, listing_state, version
 applications                               job_id, worker_id, note, state; unique job_id plus worker_id
                                            job_id, application_id, worker_id, gross_kobo, state, prior_state,
 assignments
                                            start/submission/completion times; unique application_id
 job_terms_versions                         immutable snapshot/hash attached to funding, acceptance and cases
                                            assignment_id, rater_id, ratee_id, role, score and text; unique assignment_id plus
 reviews
                                            rater_id
```

A campus_id prepares the data model without exposing multi-campus behaviour. Role capabilities are computed from protected approval state. A normal profile update cannot alter can_work, verification, ratings or completed counts.

### 5.2 Money and provider records

```text
 Entity                                     Core purpose
                                            server-generated reference, job, expected gross/currency, idempotency key and
 funding_intents
                                            current funding state
 payment_attempts                           individual Bachs checkout attempts, provider IDs and verified results
                                            funded job-slot principal, optional assignment_id, held/allocated/refund outcome
 escrow_allocations
                                            and dispute hold
                                            provider clearing, escrow liability, worker liability, pending withdrawal/refund,
 ledger_accounts
                                            revenue and expense accounts
 journal_transactions                       immutable business operation, actor and reference; unique business effect identity
 journal_entries                            transaction/account, debit or credit kobo; transaction must balance
 wallet_balances                            rebuildable transactional projection of available/reserved amounts; versioned
 withdrawal_requests                        user, amount, destination version, reserved state and stable provider reference
                                            requested/unknown/succeeded/failed/reversed external operations with attempts
 provider_operations
                                            and reconciliation status
 refund_requests                            allocation/source-payment mapping, amount, authorization and provider progress
 Entity                                     Core purpose
                                            verified provider event identity/hash, receipt time, processing state and
 webhook_receipts
                                            deduplication key
 idempotency_records                        actor/command/key, input hash, in-flight/final response and expiry rules
```

Create one principal allocation per funded slot, initially unassigned. Selecting a worker binds an available allocation; replacing a pre-start withdrawn worker reuses held principal without another charge. Distinguish refund authorization from actual refund settlement. The wallet is an accounting view, not a bank account or independently licensed custody product.

### 5.3 Messaging disputes and delivery

```text
 Entity                                     Core purpose
 message_threads                            unique application_id, job and poster/applicant participant references
                                            thread, sender, client_message_id, immutable body and server sequence/time;
 messages
                                            unique sender/client_message_id
 thread_read_cursors                        participant plus last_read_sequence; monotonic update
 notifications                              user, event, destination, read time; unique user/event/type
 domain_events                              immutable event ID, actor, aggregate, event type, safe payload and sequence
                                            durable event/action delivery, available_at, attempt count, lease, status and error
 outbox_jobs
                                            category
                                            assignment/allocation, opener/respondent, current/previous assignment state,
 disputes
                                            case stage and assigned reviewer
                                            restricted object reference, submitting party, content hash, submission/version
 dispute_evidence
                                            time
 contact_attempts                           case, party, channel, staff, time, result and note
                                            immutable proposed amounts/reason/version, reviewer and
 dispute_decisions
                                            notified_at/appeal_deadline
 approvals                                  decision_version, approver, capability, timestamp and signed/checkpoint reference
 appeals                                    decision, appellant, reviewer, evidence, status; unique decision/appellant
 audit_events                               append-only identity/access/decision/financial actions and tamper-evidence chain
```

Store party-visible case events separately from internal investigation notes. Public case endpoints must never return private staff notes or unrelated conversations. AgentAction is Phase 2 only; present domain_events already provides the future attribution seam.

## 6 State transitions and concurrency

### 6.1 Listing and assignment states

Listing states are draft, awaiting_payment, open, filled, expired and cancelled. Discovery checks funded principal, open state, remaining slots, campus and deadline. Jobs are filled only when no slot is available; expiry closes discovery without authorizing refunds. Deadline extensions apply only to remaining unassigned slots through a new prospective terms version; accepted assignment snapshots remain unchanged.

Assignment states are assigned, in_progress, submitted, completed and cancelled. Dispute status is a separate hold/case dimension retaining the prior valid state. UI can display Disputed while retaining the underlying work stage. Parent job summaries derive from assignments and available slots rather than overwriting every worker's status.

```text
 Command                          Preconditions                               Atomic result
                                  Verified student, open slot, not own job,
 apply                                                                        Application and private thread; event
                                  no duplicate
                                  Verified owning poster, applied             Lock job/allocation; bind assignment; decrement
 accept_application
                                  candidate, available allocation             available slots; event
                                  Assigned worker, no blocking
 start_work                                                                   Record in_progress and terms version; event
                                  hold/cancellation
                                  Assigned worker in progress, no
 submit_work                                                                  Record submitted and reminder schedule; event
                                  terminal/blocked state
                                  Owning poster, submitted, funded, no        Lock allocation; release ledger once; mark
 confirm_completion
                                  hold                                        completed; event
                                  Participant, assigned through submitted,    Lock allocation; create one active case and hold;
 open_dispute
                                  held principal                              event
                                  Final eligible decision, required           Apply outcome, journal and external-operation
 finalize_case
                                  approvals, no unresolved appeal             authorization once
                                  Freshly confirmed user, verified bank,      Reserve balance and create one withdrawal
 request_withdrawal
                                  sufficient available earnings               operation
```

Use one database transaction for each result. Row locks and conditional version checks serialize conflicting commands. Unique constraints prevent duplicate applications, assignment bindings, journal effects and reviews. Return conflict/already-completed responses rather than racing browser state.

Idempotency keys are scoped to actor and command. Reuse with different inputs is rejected. Network retries with identical input return the original result, not another effect. Concurrent withdrawal requests lock the same wallet-account projection and cannot spend the same available amount.

### 6.2 Cancellation and deadlines

An owning poster can explicitly cancel an unassigned funded slot/job and authorize its refund. Before work starts, accepted-assignment cancellation needs both parties' agreement; contested cancellation uses a case. Record each consent against the same terms/version. A worker abandoning a pre-start assignment cancels their assignment and reopens the slot with its funds still held; this is withdrawal from work, not a bank withdrawal. Repeated abandonment can be reviewed by ops.

After work starts, unilateral financial cancellation is unavailable. Late listings expire from discovery and prompt reschedule/cancellation. Notifications and deadline checks do not move funds. For multi-worker jobs, cancel/refund

only allocations eligible under their individual states; never refund principal still owed against another worker's active assignment.

### 6.3 Appeals and final execution

Initial decisions record a 72-hour deadline from durable notification to both parties. In-app notice is durable notification; email is an additional channel, so email failure does not erase the notice. Keep the financial hold until the deadline and any timely appeals are resolved. Both parties' allowed appeal requests must be accounted for before finalization.

Finalization acquires a decision/allocation lock, checks current time and absence of unresolved eligible appeals, verifies independent approvals, and records the outcome. An appeal and finalization racing at the boundary cannot both win. Use one server clock and an explicit rule: appeal is timely when received by the server before the stored deadline. The client clock has no authority.

Cron can mark a case ready for human attention. An authenticated admin must initiate the financial finalization; expiry alone never releases or refunds money. If an appeal changes the outcome, approvals bind to the new outcome/version. A final award to a worker, including a split for partly completed work, marks that assignment completed; a full refund marks it cancelled. Review eligibility follows completed assignments only. Parent completion requires at least one paid completion and all funded allocations resolved, including unused-slot refunds. A no-action final decision removes the hold without journal movement and restores the prior valid state.

## 7 Ledger and exact money rules

### 7.1 Principal and fee policy

gross_total_kobo = gross_per_worker_kobo x slot_count. Snapshot 500 basis points on each funded allocation. Compute commission as round-half-up(gross_awarded_kobo x 500 / 10000) using exact integer arithmetic; worker_net = gross_awarded - commission. The calculation runs once per finalized award version and never on the refund share. Validate all amounts positive/nonnegative as appropriate and within configured pilot exposure limits.

Per-allocation conservation is held_principal + worker_net_allocated + commission_allocated + poster_refund_allocated = funded_principal. Reservations and external settlement stages are subaccounts within those allocated amounts; do not count bank transfers again as new allocation. Across each journal transaction, sum(debits) = sum(credits).

Provider processing charges are platform expenses. They never alter expected funding, add a poster surcharge or reduce worker earnings. Platform operating cash/reserves must cover provider fees and full refunds even when gross principal exceeds provider net settlement.

### 7.2 Accounting examples

For a NGN 3,000 job collected through a route charging NGN 45, record debit provider clearing NGN 2,955, debit processing expense NGN 45, and credit held-job liability NGN 3,000. Provider settlement accounting can use an intermediate receivable before cash clears; match the real account flow rather than treating every success as immediately withdrawable cash.

On authorized ordinary completion, debit held-job liability NGN 3,000, credit worker available liability NGN 2,850 and credit commission revenue NGN 150. This is the worker's earnings release, not proof of a completed bank transfer.

On a NGN 2,850 withdrawal request, debit worker available liability and credit pending-withdrawal liability by NGN 2,850. On confirmed successful bank settlement, debit pending-withdrawal liability and credit provider clearing by that amount. Record a NGN 50 transfer fee separately as processing expense/clearing, based on the provider's actual charging stage.

On a permitted full cancellation, reclassify NGN 3,000 held liability to refund payable, then clear that payable only when the refund is confirmed. Original collection fees remain a platform cost if not returned. Refund cash may need a platform top-up. Refund fee/reversal costs are separate entries.

Every correction is a compensating journal, never an edit or deletion. Provider chargebacks after a paid assignment create an explicit risk/receivable or loss workflow; do not silently debit unrelated users' available balances. Ops controls and provider cases are distinct from marketplace work disputes.

### 7.3 Ledger enforcement and reconciliation

Validate balanced journals inside controlled transaction functions; clients cannot insert journal rows directly. Use a deferred constraint/commit check or a function-enforced equivalent with tests so a partial journal cannot commit. Rebuild cached balances from the journal and compare routinely. Totals across accounts, provider balances/receivables, unresolved transfers and held liabilities must reconcile.

Show ops missing callbacks, unknown operations, provider shortages, duplicate/excess collections and unmatched refunds. Quarantine mismatches for human resolution. Reconciliation may update knowledge of an already-authorized provider operation, but cannot invent authorization for a new release/refund.

## 8 Bachs integration contract

Bachs is the chosen provider. Start with checkout bank transfer and eligible local card methods. Do not choose fixed virtual-account deposits merely for a lower rate: current refund limitations and account-specific support need validation. No user-visible gateway surcharge is permitted; explicitly configure platform fee bearing.

### 8.1 Before live money

Obtain written confirmation for conditional holding of marketplace funds, beneficial ownership, holding-duration limits, student-worker onboarding/KYC, commission, multi-worker allocation, dispute/appeal freezes, full/partial refunds, chargebacks, manual withdrawals and fee funding. Confirm live Connect capabilities and whether funds can remain under platform control until authorized award. Sandbox access is not live approval.

The application ledger labels amounts held according to the product contract; provider acceptance determines the actual custody structure. Do not advertise licensed escrow or guaranteed recovery solely because an API exposes balances/subaccounts.

Bachs published NGN payout fees are added above the sent amount and may differ per account. A connected worker balance containing exactly net earnings may not also cover that fee. Confirm and implement platform-funded fee coverage before withdrawals; preserve the user's full requested bank amount. Keep a provider reserve and avoid disbursing money that is not actually available.

### 8.2 Collection flow

1. Server validates verified owning poster, immutable job terms and exact total, then creates a funding
   intent/idempotency reference.
2. Server initializes Bachs checkout for the fixed NGN total. Browser receives only safe checkout information.
3. Browser callback shows pending and asks the backend for status; it never credits the job itself.
4. Verify callback/webhook authenticity, server-created reference, payment identity, merchant/account, amount,
   currency and authoritative provider status.
5. In one transaction, record one funding effect, create funded-slot allocations, journal receipt and publish the job;
   append notifications through the outbox.
6. On mismatch, excess duplicate payment or unknown status, keep the job safely blocked and create an ops
   exception. Do not silently apply a wrong amount or start another charge while the first may have succeeded.

### 8.3 Release withdrawal and refund flow

Create a durable authorization and provider-operation row before any external call. Release to available earnings is an internal accounting transition after a valid confirmation/final decision; any required provider balance transfer follows that recorded authorization. Withdrawal is an independent authenticated user command.

For a provider movement, persist a stable reference, intended amount, destination version and effect identity, then call Bachs outside the DB transaction. If the request times out, mark unknown; query the original reference before retrying. Use provider idempotency where documented. If an endpoint lacks a safe deduplication/lookup mechanism, unknown results require manual reconciliation before another request.

State remains processing until confirmed, failed only after authoritative failure, and reversed when an established prior success is reversed. Compensate internal reservations only once and according to the observed provider result. Partial refunds must map back to original charges with cumulative refund limits.

### 8.4 Webhooks and retries

Verify the current documented Bachs signature against the required raw request bytes and active secret; do not reuse Paystack's signature algorithm by assumption. Reject invalid/oversized bodies, validate event type and store a durable receipt before acknowledging acceptance. Deduplicate both event receipt and business effect; providers can send several different events about the same operation.

After durable receipt, return promptly and process with a reliable job consumer. Store minimal encrypted/restricted payload data, redacting unnecessary identity information from logs. Retried, late and out-of-order events must not regress terminal financial state; fetch authoritative provider status when necessary. Delivery is at-least-once; exactly-once external side effects are not assumed.

## 9 Messaging and realtime

Persist text in messages and read state in thread_read_cursors. A unique application creates one private thread. A worker cannot read rival applicants' threads; staff access is limited to permitted investigation. Validate current verification and membership for sending, reading, subscribing and read updates.

Use Supabase Realtime private Broadcast channels, for example thread:<id> and user:<id>:notifications. The channel name is not authorization; Realtime policies must prove membership. Avoid subscriptions to the complete messages table, global feed or every conversation. The browser subscribes only to active/relevant channels and cleans up on navigation/logout.

A send request uses a client message UUID. The DB validates, persists and assigns a stable sequence, then a trigger/outbox emits a minimal broadcast. Sender pending UI becomes sent after persistence acknowledgement. On reconnect, request messages after the last persisted sequence and merge by ID. Transport events are hints, not the permanent history.

Read cursors move forward only within messages the participant may read. Update once per batch/view progression, not one write for every message on screen. Typing/online indicators are optional ephemeral data and are not evidence that a person saw a message. Rejected or withdrawn applications retain read-only history; completed threads are read-only unless the case workflow permits further messages.

Text-only chat is sufficient for MVP. Evidence files are uploaded through the dispute flow, not silently added as an unbounded chat attachment product. Voice notes remain P1.

## 10 Event delivery and notifications

Each successful business transaction writes its domain event and outbox job in the same commit. This closes the gap where data succeeds but an email call is lost. Use a logged durable queue, not an in-memory promise or unlogged queue for important work. Internal job consumers are not exposed to clients.

Claim jobs with leases and SKIP LOCKED or equivalent queue visibility semantics. Retry transient errors with exponential backoff and jitter; bound attempts, classify permanent errors, and expose exhausted jobs to ops. Expired leases are reclaimable; each consumer is idempotent. Notification uniqueness uses user/event/channel/type. External email or SMS may still duplicate if a provider lacks idempotency after an ambiguous result; limit blind retries and reconcile delivery IDs.

Submission reminders use PRD timing and recheck state before sending. Maintain per-user channel limits and notification suppression after dispute/completion/cancellation. Financial jobs execute existing durable authorizations only. A schedule can never decide who deserves the money.

### 10.1 Email

Zoho CPaaS sends auth and transactional email through authenticated SMTP or HTTPS APIs as supported by the chosen integration. Verify sender domain, SPF/DKIM and applicable DMARC policy; separate auth templates from ordinary notifications. Supabase's default trial mail sender is not the production delivery solution.

Keep school-email OTP separate from login-email recovery. Hash and expire supplementary institutional challenges, rate-limit attempts and bind them to account/email. Consume each challenge once. Do not log codes or embed confidential case evidence in email; deep-link to authenticated views.

### 10.2 SMS

Africa's Talking is selected. Implement Supabase's Send SMS Hook in a secured Edge Function; Supabase generates/verifies the phone OTP and the hook only delivers it. Validate hook signatures, normalize +234 numbers, use the approved transactional sender ID and record delivery status without storing plaintext codes in general logs.

Nigeria DND delivery requires telco approval of a transactional sender ID. Begin onboarding early; official guidance states at least two weeks and business-document requirements. Do not use promotional routes for verification. Test MTN, Airtel, Glo and T2, including DND-enabled numbers.

OTP dispatch is immediate, not a five-minute cron batch. Resend and verification attempts have server rate limits and expiry; protect against SMS pumping. Measure dispatch-to-delivery and successful verification, not just provider acceptance. Ordinary job reminders use email/in-app first. Zoho SMS is not the Nigerian SMS path.

## 11 Private files and privacy

Use private buckets for identity evidence and dispute evidence. Separate public-safe avatar derivatives from private originals. The backend authorizes a short-lived upload/download URL by purpose and participant/reviewer permission; object keys or URL possession must not create indefinite access. Limit verification photos/images/PDFs to a practical small size below Free's maximum; start with a 5 MB product limit per file and up to five dispute files, configurable by documented policy. These engineering defaults can be revised without changing financial rules.

Validate file signatures, MIME types, size and ownership; reject executable/active-content formats. Serve downloads with safe headers and avoid rendering arbitrary HTML/SVG. Quarantine uploads pending malware/content checks appropriate to the permitted file types; image re-encoding and PDF safety controls do not imply a universal malware guarantee. Keep storage and DB metadata consistent with cleanup of orphaned uploads.

Retain content hashes and access logs for evidence. Restrict service credentials and staff access. Exclude raw identity documents, phone numbers, bank data, tokens and OTPs from application telemetry. Analytics use pseudonymous IDs and minimal event fields.

Before live identity intake, sign off a retention schedule for approved/rejected IDs, verification reviews, case evidence, messages, financial records and backups. Include legal holds, deletion requests, expired signed URLs and deletion propagation. Do not invent a statutory retention duration. Record the applicable cross-border processing basis and provider data terms; foreign region selection alone neither proves nor prevents compliance.

## 12 Auditability

Append immutable audit events for verification decisions, staff grants, evidence access, all financial authorizations, ordinary poster confirmations/cancellations, provider outcomes, approvals and appeals. Not every money event has a dispute ID; ordinary poster confirmation and allowed cancellation do not require fictitious cases.

Use a per-stream hash chain with deterministic serialization, prior hash, event hash and immutable sequence. Privileged admins must not be able to rewrite evidence of their own actions through normal tools. Retain signed checkpoints/exports under separately controlled storage/access and verify them regularly. Append-only table permissions alone are insufficient tamper evidence against a database owner; independent checkpoints reduce that risk and define the boundary of the claim.

Financial journals and audit entries must be queryable by operation/case/reference without exposing secret provider payloads. Corrections append new records. Application audit retention is independent of Supabase's short operational log retention.

## 13 Performance and efficient data access

### 13.1 Acceptance measurements

```text
 Measure                                    Target and test condition
                                            Usable within 3 seconds on a defined mid-range Android under agreed 3G/4G
 Primary page readiness
                                            profiles
 Core Web Vitals                            p75 LCP <=2.5 s, INP <=200 ms, CLS <=0.1 on measured mobile traffic
                                            p95 <=500 ms end-to-end from Nigerian test clients on stable 4G, excluding
 Feed/filter API response
                                            deliberate typing debounce
 Chat delivery                              p95 <2 s from accepted saved send to online recipient display
 Verification queue visibility              <=60 s from committed submission
                                            No duplicate journal/payment or negative available earnings under concurrency
 Financial correctness
                                            tests
```

Record the exact device, network throughput/RTT/loss, region, dataset and build with every benchmark. Assess cold sessions and reconnects separately from warm navigation. Use representative synthetic data: 1,000 users, 10,000 jobs, 50,000 applications and 250,000 short messages as an initial query/load-test fixture, checking it fits local/staging capacity. This is an engineering test dataset, not a claim of Free production capacity. Start at 50 concurrent active clients with mixed feed/chat/write actions; add a controlled higher-concurrency scenario before expansion. Keep staging tests from exhausting production quotas.

### 13.2 Query design

Return 20 feed records initially with essential poster summary in one indexed query. Use a stable `(created_at, job_id)` cursor and deterministic filter ordering; do not perform one profile request per card. Avoid exact total counts on each keystroke, SELECT * responses and unbounded history loads. Debounce keyword input around 250 ms and cancel obsolete requests.

Start with PostgreSQL full-text search for title/description. Add a GIN index on the selected search vector and targeted B-tree/partial indexes based on query plans. Initial access paths include jobs(campus_id, created_at DESC, job_id DESC) for open funded listings, applications(job_id, worker_id) uniqueness and applicant-list lookup, assignments(worker_id, state), messages(thread_id, sequence), notifications(user_id, created_at DESC), and

outbox(status, available_at). Index RLS join/membership keys. Do not blindly index every filter combination; measure read benefit against write/storage cost.

Maintain rating totals/counts and completed counters transactionally or through deduplicated events, with a rebuild job. Financial balance projections update in the money transaction, not eventually through an unreliable notification callback.

### 13.3 Frontend and caching

Use small route bundles, server rendering where beneficial, lazy admin routes, optimized responsive images and limited third-party scripts. Cache static assets at Cloudflare. Never shared-cache private feed results, profiles with restricted columns, wallet/ledger views, signed file URLs, staff responses or session-dependent pages. Authenticated data has explicit cache headers and per-user client-cache keys, with clearing on logout.

PWA service-worker caches are allow-listed for app assets and safe public support pages. Financial commands, auth endpoints, private documents and chats are network-only. Do not replay money actions as offline background sync. Display offline/pending state and recover through idempotent user retry.

Realtime connections and query caching reduce redundant reads but consume quotas; one active socket can carry several authorized subscriptions. Unsubscribe inactive channels, cap presence use and avoid treating the 50,000-MAU allowance as a throughput guarantee.

## 14 User-facing errors and operational visibility

Return stable error categories with safe messages and a correlation ID. Categories include verification_required, permission_denied, stale_state, slot_filled, insufficient_available_balance, payment_pending, provider_unavailable, rate_limited and retry_later. HTTP semantics and UI wording are documented together. Raw SQL, stack traces and provider secrets stay in redacted internal diagnostics.

Add deployment health checks, structured error logs and alerts for callback failures, queue backlog, stale unknown payments, unreconciled amounts, approaching capacity and expired auth delivery credentials. Report money exceptions separately from ordinary UI errors. Include staff runbooks for each actionable alert.

Track PRD events from server-side transitions where possible: verification approval, funded publication, first application, acceptance, submission, authorized release, withdrawal success, case response/decision/finalization, appeal and repeat participation. Frontend analytics must not be the sole source of financial measures.

## 15 Testing strategy and acceptance coverage

Use TDD for risky business logic and database permissions. Write the failing behavioural test before implementing commission calculation, authorization boundaries, acceptance capacity, dispute/release races, refunds, withdrawals and webhook deduplication. Routine visual component composition does not need test-first ceremony.

Required checks:

- RLS allow/deny matrix for anonymous, unverified, student, partner, suspended, unrelated user and staff
  capabilities.
- Users cannot edit verification/role/balance fields or read others' identity, banks, conversations or evidence.
- Multiple simultaneous acceptance calls fill at most the available slots and bind each allocation once.
- Concurrent confirmation/dispute/cancellation produces one valid state and no unbalanced journal.
- Commission and split rounding reconcile exactly, including kobo amounts.
- Duplicate/out-of-order callbacks, duplicate clicks and retried jobs preserve one effect.
- Timeout after provider acceptance does not lead to a second transfer/refund.
- Concurrent withdrawals cannot overspend; verified failure/reversal compensation runs once.

- Appeal versus finalization boundary and independent-review/approval restrictions are enforced.
- Chat persistence, reconnect replay, duplicate send IDs and read cursors work with network interruption.
- Direct upload/download URLs enforce restricted access and expiry; unsafe files fail clearly.
- Email/SMS failure, throttling, expired/reused OTP and all four Nigerian network routes are exercised.
- Full worker/poster/partner/admin journeys work at 320 px and desktop with keyboard/accessibility checks.
- Restore tests recover DB/files together and reconcile against Bachs before reopening writes.

```text
 PRD features                               Minimum acceptance evidence
 F1-F2                                      Both verification tracks, access denial, profile privacy and system-owned fields
 F3-F5                                      Exact total, pending funding, partial fill, atomic acceptance, per-worker stages
                                            Balanced ledger, exact 95%, refunds/splits, manual withdrawals and review
 F6-F8
                                            eligibility
 F9-F11                                     Durable notifications, dispute/appeal holds, private persistent chat and replay
 F12                                        Staff separation, approvals, tamper checks, exception queue and metrics
 Nonfunctional                              Mobile performance measurements, security tests, backups and ops rehearsal
```

CI runs formatting/type/lint checks, relevant unit/DB/integration tests and critical journey tests before merge/deployment. Use migration tests against a clean database and a representative prior schema. Do not require brittle tests mirroring every implementation detail or an arbitrary coverage percentage.

## 16 Delivery operations and cost control

### 16.1 Milestones

1. Freeze v2 product rules, vendor integration contracts, schema and permission/state matrices. Validate
   Cloudflare compatibility and Nigerian network region options.
2. Establish repository, local fixtures, CI, migrations and isolated environments; deliver verification and protected
   admin access.
3. Build one complete Bachs sandbox path through funded job, application, assignment, confirmation, wallet credit
   and manual bank withdrawal. Include essential event/audit/exception visibility from the start.
4. Complete multi-worker cancellation/refunds, splits, dispute appeal holds, independent approvals, chat,
   notifications and ratings.
5. Run security/concurrency/failure/recovery/mobile checks. Complete privacy, provider and ops launch gates.
6. Operate a capped live pilot after approval, then expand to the PRD beta. Record real delivery, fees, latency and
   support load. Do not defer financial/ops controls to cosmetic hardening. No real-money release until state/ledger invariants, idempotency and reviewer controls pass.

### 16.2 Deployment and rollback

Apply reviewed versioned migrations through CI. Prefer backward-compatible expand/migrate/contract changes. Validate health and core journeys after deployment. A frontend rollback is not a database rollback; destructive migrations require a tested restoration/forward-fix plan. Keep webhook URLs reachable across frontend deployments. Preserve stable provider-operation IDs and never reset ledger data to repair UI state.

Store a provider map and endpoint/event contract in docs/payments-and-recovery.md after sandbox validation. Keep sandbox secrets separate from live and rotate exposed credentials. Founder-owned service accounts, domain/DNS access and recovery codes need a handover inventory without putting secrets in Git.

### 16.3 Backups and incident recovery

Supabase Free has no included automatic DB backups. Automate encrypted offsite logical exports and separately protect Storage object contents before taking live funds. Document backup frequency, retention, keys, access and restore steps. Daily exports alone can lose up to a day of data; provider reconciliation cannot reconstruct lost chat/evidence or unexported internal decisions.

For a money-handling launch, use an initial engineering recovery objective of at most one hour of financial DB loss and four hours to restore core service, subject to measured restore drills and founder sign-off. Adjust backup frequency/architecture or buy appropriate recovery capability to meet the agreed exposure; do not claim Free automatically provides this. Evidence/message recovery objectives must also be documented and tested. These are engineering objectives, not statutory requirements or vendor guarantees.

During a money incident, suspend affected commands, preserve receipts/logs and reconcile unresolved references. Restore into an isolated target, compare ledger/projections/provider balances, and prevent replay of already-paid operations. Reopen only after ops approval. Test project/credential loss as well as accidental table deletion. Pro daily DB backups still exclude Storage objects; PITR is a separate paid capability.

### 16.4 Usage and budget

Published Free allowances include 500 MB database, 1 GB files, 5 GB egress plus 5 GB cached egress, 200 peak Realtime connections, two million Realtime messages and 500,000 Edge Function invocations monthly. Confirm current plan values at deployment. These are quotas, not capacity promises; DB rows, message fanout, evidence size and network usage often constrain growth before MAUs.

Review weekly and alert at 70%, plan action before 85%, and track actual latency alongside quotas. Optimize unnecessary usage; do not simulate activity merely to evade pausing. Free can pause after a week of inactivity; the business must accept that behaviour or upgrade before it becomes unacceptable.

Cloudflare Workers Paid currently starts at USD 5/month. The accepted initial infrastructure planning target is USD 10/month, with USD 25 reserved for a potential Supabase Pro upgrade. This excludes SMS/email usage, payment processing, recovery storage and staff time. It is a planning target, not a production cost guarantee or automatic spend authorization. Upgrade on measured need, and never stop financial recovery to preserve an arbitrary small bill.

## 17 Handover and future changes

README explains local setup and standard commands. Keep a concise decision log for financial/product changes. Maintain the data dictionary, permission matrix, provider references, backup/restore guide, deployment/rollback guide and admin incident runbook in the same repository. Update tests and docs with each behaviour change.

A new developer must be able to set up a synthetic local system, run the critical tests, deploy to staging, trace a payment reference, find a failed job and follow a restore drill without private conversational context. The designer's handoff includes mobile states and error/confirmation behaviour. No secrets, real IDs or customer data belong in fixtures.

Future AI, native apps and additional campuses call the existing authorized command boundaries. Add new fields/services only for approved requirements and measure before introducing caches, replicas or separate services. Simplicity means explicit ownership and invariants, not an attempt to prebuild every future feature.

## 18 Production readiness checklist

- Product v2 and matching financial/state rules reviewed; UI clearly shows per-worker price and exact poster total.
- Bachs approves the exact holding/payout/refund model; live capabilities and platform fee coverage verified.
- Africa's Talking sender ID approved, OTP delivered across networks/DND; Zoho auth/email delivered to real
  school accounts.
- RLS, private storage, staff MFA, two-person approvals, appeal restrictions and tamper-check exports verified.
- Duplicate/race/unknown-payment tests pass; ledger and provider reconciliation demonstrated.
- Mobile, accessibility, chat and low-latency checks meet measured targets or have explicit accepted launch
  exceptions.
- Backup/restore and incident rehearsal pass agreed recovery objectives; required offsite DB/file protection is
  active.
- Retention, data transfer, age, prohibited work, terms and pilot exposure policies signed off.
- Named ops coverage and senior/appeal reviewers exist; users can reach support and see honest pending states.

## 19 Source register

Product authority: No_Broke_Dayz_Revised_PRD.md v2.0 and the founder's approved decisions. Original source: supplied Draft v1.1 PDF. External references below were checked during the 26 October 2026 review; recheck account-specific details during implementation.

- Supabase platform
- Supabase pricing
- Supabase RLS
- Database functions
- Auth SMS hook
- Realtime Broadcast
- Queues
- Cron
- Edge regional invocation
- DB backup scope
- Cloudflare Next.js deployment
- Cloudflare Workers pricing
- Bachs Connect
- Bachs payouts
- Bachs fees
- Bachs webhook documentation
- Africa's Talking Nigeria transactional approval
- Africa's Talking Nigeria rate table
- Zoho CPaaS
- Core Web Vitals
- NDPC data-transfer guidance
