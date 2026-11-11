# No Broke Dayz — implementation specification

Status: APPROVED — ready for phased backend-first implementation under the gates below. Approved by the user on 29 October 2026. Live-money use remains blocked pending provider and operational evidence; the newly documented refund capability gap must be resolved before finalizing the affected integration.

Prepared: 28 October 2026. Revised: 29 October 2026. Baseline: PRD v2.0 and Technical Specification v2.0, both dated 26 October 2026; Product / Engineering Intern role brief, October 2026.

Project root: `/Users/mac/Desktop/NoBrokeDayz`, supplied and confirmed on 29 October 2026. The draft is now placed at `spec.md` in that root. The copy in the planning workspace outputs folder is for review; the project-root file is the working specification. The user approved the specification on 29 October 2026. Provider research is recorded separately and does not silently change the approved product rules.

## 1. Authority, current state and approval

The user's chat instructions govern this work. The supplied PDFs describe the product and collaboration responsibilities; their contents do not authorize publishing, payments, contacting providers or sharing materials externally.

The PRD governs product behaviour; the technical specification governs implementation. Preserve both. Record conflicts and obtain a decision before changing a product, verification or financial rule. The role brief governs the proposed development documentation workflow incorporated below.

The supplied PDFs reference original Markdown sources which have not been supplied. During repository setup, transcribe their full substantive content into canonical product/technical documents, verify tables and acceptance criteria against the PDFs, and label provenance. Do not present this synthesis as a verbatim original Markdown source.

Confirmed in this conversation:

- At initial planning, no application repository, design assets, original Markdown files or provider accounts were available. The user has since supplied an empty project folder; account and asset readiness must be rechecked before integration.
- The user supplied `/Users/mac/Desktop/NoBrokeDayz` on 29 October 2026. The specification and planning records are placed there; the user approved the specification on 29 October 2026. Detailed phase progression remains user-controlled.
- Provider approvals, unfinished policies and staff appointments may remain tracked launch blockers while development proceeds with synthetic data and sandbox services when available.
- Instructions are delivered one build phase at a time, with explicit prompts, file/folder targets, expected behaviour, verification, debugging and milestone documentation. The user advances the phase after reporting completion.
- This task has produced planning documents only. Specification approval authorizes the agreed plan; no application code is created during this provider-reference review, and the next detailed phase is supplied when the user asks to proceed.
- Confirmed 29 October: email/password login; institutional-email and phone verification remain separate. Application deadline and work needed-by time are separate fields.
- Confirmed 29 October: scope remains the whole product. Build and verify the backend first, including infrastructure measurements and reliability checks; postpone production frontend implementation while the designer prepares designs. Design work can progress in parallel. Use automated command/API tests and synthetic test clients for backend evidence; complete real browser/mobile acceptance after frontend integration.

Approval gates:

1. **Specification — passed 29 October 2026:** the user explicitly approved this specification, including the testing approach. Section 13 recommendations are accepted. Feature-specific detailed values and new capability conflicts still follow their stated evidence/decision gates.
2. **Phase:** finish and verify the current phase, summarize evidence and wait for the user's instruction before supplying the next phase's detailed build guide.
3. **Real identity intake:** signed privacy, retention, file safety and staff-access arrangements precede real identity documents. Synthetic documents are used in development.
4. **Live money:** all section 12 launch gates must pass. Sandbox success alone cannot authorize a live launch.

A provider's unavailable capability is a blocker to be resolved with the owner, not permission to silently replace Bachs or weaken payment protections.

## 2. Problem and solution

Verified UNILAG students need a trustworthy way to find small paid jobs, agree terms, demonstrate completion and receive their earnings. Student and non-student posters need verified workers, funded commitments, private coordination and accountable help when work is contested.

Deliver a mobile-first responsive web application and installable PWA. Verify users before marketplace access. Publish jobs only after exact funding is confirmed. Assign workers against individual funded slots. Keep payment release separate from bank withdrawal. Provide private application conversations, human-reviewed disputes and appeals, and an operational console with enforced independent financial approvals.

## 3. Scope and user stories

### Beta boundary

UNILAG only; NGN only; ages 18 and above; one person per account. Verified students may hire and work. Verified non-student partners may hire only. An individual may attribute a post to an organisation, while remaining personally accountable; shared/team accounts are excluded.

All F1–F12 are required before beta. The build phases below are delivery stages and must not be confused with the PRD's later product “Phase 2” AI feature.

### User stories and acceptance coverage

| ID | User story | Required observable result |
| --- | --- | --- |
| F1.1 | As a new user, I want to register as a student or partner so that the right verification track is shown. | Registration records account type and age confirmation; marketplace access remains denied until the full track and phone requirement pass. |
| F1.2 | As a student, I want to prove school-email ownership so that I can qualify without unnecessary manual review. | An allow-listed institutional address is bound to the existing account using an expiring, single-use challenge; phone and age remain separate prerequisites. |
| F1.3 | As a student without school-email access, I want an ID review so that I can still seek verification. | A private synthetic-ID submission reaches the review queue within 60 seconds; pending/needs-information/rejected/approved states and review history are visible appropriately. |
| F1.4 | As a partner, I want human review of my identity and campus connection so that I can hire legitimately. | Legal name, phone, government ID and accepted connection evidence are reviewed; a student vouch never auto-approves. |
| F1.5 | As a user, I want secure login and recovery so that changing contact details cannot bypass verification. | Recovery/contact changes preserve or explicitly re-establish required checks; codes expire, are rate-limited and cannot be reused. |
| F1.6 | As a suspended user, I want an explanation and financial support route so that unresolved money remains addressable. | Marketplace actions are blocked immediately by backend checks; private help remains available without exposing other users. |
| F2.1 | As a user, I want to edit my ordinary profile so that others understand my skills and availability. | Display name, photo, faculty/campus where relevant, bio, skills, availability and partner business details are editable; protected fields are not. |
| F2.2 | As a poster, I want to inspect applicants' profiles so that I can make an informed selection. | Profiles show badges, role-specific ratings/counts and completed-work count; private identity, phone and bank details are excluded. |
| F3.1 | As a poster, I want to set pay per worker and slots so that the full funding commitment is clear. | Total equals per-worker gross × slots; NGN 3,000 × 3 displays and charges NGN 9,000 with no extra surcharge. |
| F3.2 | As a poster, I want accurate checkout status so that I do not accidentally pay twice. | Pending, failed, cancelled and unknown are distinct; browser return never proves payment; uncertain prior attempts are checked before another collection. |
| F3.3 | As a participant, I want funded terms preserved so that agreed scope and payment cannot change underneath me. | Immutable terms snapshots bind funding, assignment and cases; material edits use explicit replacement/cancellation. |
| F4.1 | As a verified user, I want useful search and filters so that I can find available campus jobs. | Funded open jobs with available slots and an unexpired application deadline appear newest first; keyword/category/pay/location/date filters combine and survive back navigation. |
| F4.2 | As a worker, I want to see my deduction before applying so that I know what I will earn. | Details disclose gross, 5% commission and exact net; protection claims remain disabled until provider arrangements support them. |
| F5.1 | As a student, I want to apply once with a short note so that the poster can consider me. | One application per job; self-application and partner applications fail through UI and direct API; applying reserves no slot. |
| F5.2 | As a poster, I want to select applicants so that each worker has an individually funded assignment. | Atomic acceptance cannot exceed slot capacity; one allocation binds once; accepted terms and next actions are shown to both parties. |
| F5.3 | As a worker, I want to start and submit my assignment so that its progress is explicit. | Assigned → in progress → submitted uses authorized transitions; only that worker submits; submission does not release funds. |
| F6.1 | As a poster, I want to confirm submitted work so that the worker earns the agreed amount. | Only the owning poster confirms an eligible submitted assignment; 95% net becomes available and 5% is recorded as commission exactly once. |
| F6.2 | As a participant, I want cancellations and disputes to respect actual work so that funds cannot move unfairly. | Unassigned-slot cancellation is explicit; accepted pre-start cancellation requires mutual consent except worker abandonment; after-start contests use a case. |
| F6.3 | As a participant, I want correct partial awards so that both sides receive their approved share. | A NGN 2,000 gross award from NGN 3,000 produces NGN 1,900 worker net, NGN 100 commission and NGN 1,000 refund. |
| F7.1 | As a participant, I want to review completed work so that trust is based on actual transactions. | One 1–5 review per party per finalized completed assignment; optional text; immutable in MVP; reportable and auditable moderation. |
| F8.1 | As a worker, I want an understandable wallet so that I can distinguish available earnings from money still held. | Available, pending allocations, appeal-held and withdrawal-processing amounts and history are separate; balance changes require authoritative ledger transitions. |
| F8.2 | As a worker, I want to request a bank withdrawal so that earnings reach my verified Nigerian bank account. | Fresh confirmation binds amount/destination; reservation is atomic; bank receipt equals requested amount; only authoritative success marks it paid. |
| F8.3 | As a poster, I want refund tracking so that I know whether a refund actually settled. | Authorized, processing, unknown, failed and completed refunds are distinguishable; a refund is not a general wallet top-up. |
| F9.1 | As a user, I want persistent event notifications so that I can follow important changes. | In-app notices survive email failures and deep-link correctly; Zoho handles relevant transactional email with deduplication. |
| F9.2 | As a worker waiting for confirmation, I want helpful reminders so that I know my next option. | Reminders at 24/48 hours; dispute guidance at 72 hours; completion/cancellation/dispute suppresses reminders; no timer moves money. |
| F10.1 | As either assignment party, I want to report a funded assignment so that a human can investigate. | Report entry points appear on assignment, thread, held wallet and help; opening a case atomically freezes only its allocation. |
| F10.2 | As a participant, I want a fair case timeline and a written outcome so that I understand the decision. | Party-visible history excludes private notes and unrelated conversations; non-response requires two attempts across two channels plus senior sign-off. |
| F10.3 | As either party, I want one timely appeal so that a different reviewer can reconsider the decision. | Each party may appeal once before the server deadline; timely appeals retain the hold; initial reviewer cannot review their own appealed decision. |
| F10.4 | As a participant, I want finalization to respect approvals so that no one staff member can decide and execute money alone. | All beta admin money outcomes require two distinct authorized human approvals, bound to an immutable decision version; manual finalization checks appeals and eligibility atomically. |
| F11.1 | As an applicant or poster, I want a private job conversation so that I can clarify and coordinate work. | Each application creates one thread; acceptance retains it; only participants and specifically authorized case staff gain access. |
| F11.2 | As a user on an unreliable connection, I want saved messages and read state so that conversation history remains trustworthy. | Persist before sent acknowledgement; visible pending state; unique client IDs, ordered replay and monotonic read cursors avoid gaps/duplicates. |
| F12.1 | As a reviewer, I want a protected operations console so that I can verify users and handle cases. | Server-granted capabilities, staff MFA, review queues, evidence access, contact logs, approvals and escalation are functional screens. |
| F12.2 | As financial ops, I want searchable exceptions and immutable records so that uncertain payments can be resolved safely. | Ledger/provider references, unknown operations, balances and retry history are inspectable; replay preserves original operation identity. |
| F12.3 | As the owner, I want accurate marketplace measures so that I can evaluate the pilot. | Server-backed users/jobs/assignments/GMV/commission/costs/margin/dispute metrics are separated appropriately, including poster type. |
| N1 | As a mobile user, I want usable screens under slow or interrupted connectivity so that I can complete core tasks. | 320–430 px journeys, keyboard support, clear empty/loading/denied/pending/offline/error/success states, and network-only sensitive actions. |
| N2 | As the delivery team, I want reproducible operations so that the product can be maintained without private chat context. | Setup, migrations, commands, deployments, payment tracing, backup restoration and runbooks work from repository documentation. |

### Deferred scope

F13 AI; native apps; multiple campuses; skills testing; automated ranking; suggested pricing; featured listings; financial products; recruitment partnerships; organisation team administration; voice notes; general chat; chat attachments; rich wallet exports; advanced notification preferences and richer analytics.

Future AI must use the same authorized business commands and human confirmations for irreversible actions; it may not decide disputes or bypass ops. No AI implementation is included in this build plan.

## 4. Settled architecture and constraints

Use one repository, one Next.js-compatible React/TypeScript web application including protected admin routes, and one transactional Supabase PostgreSQL database per environment.

| Layer | Responsibility and boundary |
| --- | --- |
| Cloudflare Workers/CDN/DNS | Dynamic Next.js hosting, static assets and routing. Prove and pin framework/adapter versions before UI expansion. Do not assume Cloudflare Pages supports arbitrary dynamic Next.js servers. |
| Supabase Auth | Credentials, sessions, recovery, phone verification and supported staff MFA. Institutional ownership and product verification are separate application facts. |
| PostgreSQL/Data API | RLS-protected reads, narrow ordinary writes and atomic transactional commands with schema constraints. |
| Supabase Edge Functions | Authenticated money/admin commands, provider integrations, auth delivery hooks, provider webhooks and background consumers. |
| Storage/Realtime | Private identity/case evidence, controlled profile images, private thread/notification broadcasts; permissions are tested independently. |
| Cron/durable jobs | Reminder delivery, retries and reconciliation of existing authorizations. Schedules never authorize money movement. |
| Bachs | Account-approved collection, holding, refund and payout model. Exact endpoints/signatures/KYC/fees require current official/account evidence. |
| Africa's Talking | Supabase-generated OTP delivery and approved security messages through a Nigerian transactional route. |
| Zoho CPaaS | Transactional auth/school-email delivery and event emails through a supported integration. |

Keep identity, profiles, jobs, assignments, messaging, payments/ledger, wallet, disputes, notifications and admin as coherent modules in this application. Next.js must not reimplement backend financial rules. Separate NestJS/Django services, Redis, Pusher, extra databases and a search cluster are outside the MVP architecture.

Use SQL migrations as schema authority and generated TypeScript types. Pin dependency versions after compatibility checks. Page files stay at or below 300 lines with cohesive extraction and shared reusable controls. The application repository's future AGENTS.md records canonical sources, mobile rules, trust boundaries, financial invariants and required tests.

Use local development with isolated hosted staging and production, subject to confirmed account limits. Previews use staging. Verify supported European regions using Nigerian network measurements before choosing a region; the PDFs' vendor recommendations, versions, prices and quotas are dated source assertions, not newly verified facts.

## 5. Data model and ownership

Use UUID IDs, UTC `timestamptz`, Africa/Lagos display labels and integer bigint kobo. Serialize large monetary values safely across JavaScript/JSON; no floating-point money calculations.

| Domain | Records and invariants |
| --- | --- |
| Identity | Profiles, protected account status, institutional email checks, verification requests/review history and staff grants. Separate login email, school ownership, phone, user type, age, approval and suspension. |
| Marketplace | Categories, jobs, immutable job-terms versions, applications, assignments and reviews. Unique job/worker application; unique assignment/application; reviews unique per assignment/rater. |
| Principal | Funding intents, checkout attempts and one principal allocation per funded slot. Unassigned slots remain funded; acceptance binds one allocation. |
| Accounting | Ledger accounts, immutable journal transactions/entries, transactional rebuildable wallet projections, withdrawal/refund requests, provider operations, webhook receipts and idempotency records. |
| Messaging | One thread per application; persisted messages with unique sender/client message identity and stable sequence; participant read cursors. |
| Cases | Disputes, versioned evidence, contact attempts, immutable decisions, version-bound approvals and one appeal per decision/party. Separate visible timelines and restricted notes. |
| Delivery/audit | Domain events and durable outbox in business transactions; append-only audit with deterministic hash chains and independent signed checkpoints. |

Private identity and financial tables live in unexposed schemas. Wallet projections update inside the financial transaction and can be rebuilt from journals. Ratings/counts must update once and support rebuilding. A campus ID prepares schema consistency without enabling multiple campuses in the UI.

## 6. Authorization and trust boundaries

Apply grants, RLS, protected-column writes, command preconditions, Storage policies and Realtime membership policies together. UI hiding is not authorization. A normal user cannot change verification, roles, badges, balances, scores, counts or staff grants.

Derive actor identity from validated credentials, never client JSON. Sensitive commands recheck current authoritative database status so suspension takes effect despite stale JWT claims. Staff capabilities are explicit audited grants, protected by MFA.

Financial Edge Functions use a restricted server role and narrow private transactions. Privileged SQL functions use an empty fixed search path, schema-qualified objects and explicit execute grants. Any alternative service-only RPC gateway must prove equivalent authorization before adoption.

Require fresh confirmation for withdrawals, bank changes and high-risk recovery. Single-use proofs bind actor, operation, amount and destination version. Supported phone verification is not automatically staff MFA or a paid phone-MFA capability.

Two-person approvals bind to the exact decision hash/version; changes invalidate prior approvals. The initiator cannot second-approve; appeal reviewer differs from initial reviewer; automated accounts never count as independent people.

## 7. State transitions and data flows

### Verification

Register → confirm age/phone → school-email ownership or manual student fallback; partners always submit identity/connection evidence for human review → approved capabilities. Needs-information/rejection/resubmission preserve history. Personal login email plus a supplementary school address uses one account. Actual allow-list domains require evidence and owner approval.

### Funding, discovery and assignment

Draft terms → server-created exact-amount funding intent → Bachs checkout → browser returns to pending → authenticated webhook/authoritative lookup validates merchant, reference, amount, currency and successful status → one database transaction journals funding, creates slot allocations, publishes job and appends domain event/outbox.

Listing states: draft, awaiting payment, open, filled, expired, cancelled. Discovery also checks funding, remaining slots, UNILAG and application deadline. Expiry hides a listing without refunding it. Prospective deadline extensions apply only to unassigned slots through a new terms version.

Apply → one application/private thread → poster accepts transactionally → one assignment bound to one allocation → worker explicitly starts → worker submits → poster confirms or a participant opens a dispute.

Assignment states: assigned, in progress, submitted, completed, cancelled. Dispute is an additional hold, preserving the prior work state. Row locks, conditional versions and unique constraints serialize final-slot acceptance, confirmation/dispute and cancellation races.

### Release, bank withdrawal and refund

Authorized poster confirmation or final case award → internal ledger credit to available earnings and commission → independent user bank-withdrawal request → atomically reserve earnings and persist operation identity → call provider outside DB transaction → settle only from authoritative provider outcome.

Unknown/timeouts remain under reconciliation; look up the original reference before any retry. Authoritative failure/reversal compensates once. Invalid, mismatched, duplicate/excess payments enter an ops exception queue rather than publishing a job or silently reallocating money.

Explicit eligible cancellation → refund authorization/payable → provider operation mapped to original charge → authoritative settled refund. Track cumulative refunds against collected principal. Never convert this into a spendable poster deposit balance.

### Cancellations and cases

- Poster may explicitly cancel/refund an unassigned slot.
- Accepted assignment pre-start cancellation requires both parties' consent bound to matching terms. Contested cancellation goes to ops.
- Worker pre-start abandonment cancels their assignment and reopens the still-funded slot; it does not refund the poster automatically.
- After-start financial disputes require case handling. One allocation's dispute does not freeze unrelated assignments or available earnings.
- Case flow: open → under review → contacting other party → verifying → decision made → appeal if applicable → closed after permitted finalization.
- Record reason, narrative, evidence, desired outcome, agreed terms and relevant thread. Contact a nonresponding party at least twice across two channels; senior sign-off is required for that outcome.
- Initial decision notification creates durable in-app notices for both parties and a stored 72-hour deadline. Email supplements the notice.
- Each party may appeal once, received by the server strictly before the stored deadline. Preserve initial and appealed evidence/decision versions and use a different reviewer.
- Hold funds during the appeal window and timely appeals. After expiry, a human may finalize an eligible approved decision; a timer cannot execute it.
- Full/partial worker award completes the assignment; full refund cancels it; no action lifts the hold and restores the prior state without money movement.
- Ordinary confirmed completions have no blanket appeal delay. A job counts completed only with at least one paid completed assignment and all funded allocations resolved.

### Messaging and notifications

Persist a message before acknowledgement/broadcast. Use private authorized channels, stable server sequences and client message IDs. On reconnect fetch after the last saved sequence and merge by ID. Read cursors are monotonic. Closed/rejected/withdrawn threads retain read-only evidence unless an active case permits messages.

Each business transaction appends an event and durable outbox job in the same commit. Lease workers, reclaim expired leases, retry with bounded exponential backoff/jitter, deduplicate consumers and expose exhausted jobs to ops. In-app notification success is independent of email success. Financial jobs execute recorded authorizations only.

## 8. Financial invariants

1. Poster pays exactly gross per worker × funded slots. No platform/processing/payout surcharge is passed on.
2. Snapshot 500 basis points on funded allocations. Commission is round-half-up of awarded gross × 500 / 10,000 in integer arithmetic. Worker net is awarded gross minus commission. Charge no commission on the refund share.
3. For every allocation: held principal + worker net allocated + commission allocated + poster refund allocated = funded principal. Settlement/reservation subaccounts must not count an allocation twice.
4. Every journal transaction balances debits and credits. Corrections append compensating journals; no financial edits/deletions.
5. Collection, transfer, refund and delivery costs are platform expenses. Provider net collection cannot reduce funded principal or promised earnings. Confirm actual cash/reserve availability before disbursement.
6. No release without verified funding and valid authorization. Time, silence, deadlines and cron never authorize release/refund.
7. Idempotency binds actor, command and input hash. Same request returns the original result; altered input with the same key fails. Receipt deduplication and business-effect deduplication are both required.
8. Withdrawal reservations are atomic. A request timeout is not a failure; uncertain operations remain reserved until reconciled.
9. Provider chargebacks use an explicit risk/receivable/loss workflow. Do not silently debit unrelated user earnings.
10. No arbitrary withdrawal minimum or fee. Confirm/disclose any actual provider minimum; small available balances remain visible.

Required example: three slots at NGN 3,000 collect NGN 9,000. Each ordinary completion allocates NGN 2,850 net and NGN 150 commission. A NGN 2,000 partial gross award allocates NGN 1,900 net, NGN 100 commission and NGN 1,000 poster refund. A bank request for NGN 2,850 must deliver NGN 2,850, with its provider fee separately funded by the platform.

## 9. Private files, UI and nonfunctional requirements

Private identity/case buckets require purpose-bound authorized upload/download and expiring URLs. Validate file signatures, MIME, ownership and size; quarantine pending appropriate safety checks. Start with the technical document's configurable 5 MB per file and five dispute-file limits. Safely process avatars separately from private originals; reject active-content formats. Retain evidence hashes/access logs and clean orphaned uploads.

Sign off retention by record type, legal holds, deletion/backup propagation and cross-border processing basis before real identity intake. Never invent a statutory retention duration. Telemetry/fixtures/content demos exclude real IDs, bank details, phones, tokens, OTPs and secrets.

Every core journey needs loading, empty, denied, pending, offline, recoverable failure and success states. Support 320–430 CSS px first, up to 1440 px desktop, readable type, touch-friendly controls, contrast, keyboard and focus behaviour. Include support, not-found, maintenance and denied pages. Pending provider states must not fabricate success or balances.

Targets from the approved source baseline, to measure rather than claim:

- Key pages usable in three seconds on a defined mid-range Android with documented 3G/4G profiles.
- Mobile p75 LCP ≤2.5 seconds, INP ≤200 ms, CLS ≤0.1.
- Feed/filter end-to-end p95 ≤500 ms on stable Nigerian 4G, excluding typing debounce.
- Saved-message-to-online-display p95 <2 seconds.
- Review submissions visible within 60 seconds; beta availability target 99% across core journeys, not a vendor SLA.

Begin feeds with 20 rows, deterministic cursor pagination and joined safe poster summaries. PostgreSQL full-text search and measured indexes are sufficient. Debounce search around 250 ms and cancel superseded requests. Avoid unbounded lists, per-card extra requests and unnecessary exact counts.

PWA caches allow-listed assets and safe support pages. Auth, private files, chats and financial commands are network-only; money is never replayed by offline background sync. Private/authenticated/staff responses avoid shared caching; client caches are user-scoped and clear on logout.

## 10. Testing decisions and acceptance evidence

Proposed test boundaries for user approval: test business behaviour at the authorized command/database boundary for money and permissions, and at browser journey level for complete user flows. Add provider-adapter contract checks where external delivery/verification cannot be represented by the DB alone. Existing test infrastructure does not yet exist.

Use test-first development for risky business logic and database permissions: write a failing behaviour test, implement the smallest passing change, and preserve the regression check. Routine visual composition does not require test-first ceremony. Avoid tests mirroring implementation details or an arbitrary coverage target.

| Test group | Required acceptance evidence |
| --- | --- |
| Access | Anonymous/unverified/student/partner/suspended/unrelated/staff allow/deny matrix, direct API attempts, protected columns, private Storage URLs and Realtime membership. |
| Verification | Both tracks, manual history, approved-domain challenge, phone OTP expiry/reuse/throttling, recovery and contact-change boundaries, queue visibility. |
| Money/state | Exact totals, integer/half-up kobo examples, balanced journals, allocation conservation, immutable terms and nonnegative available balances. |
| Concurrency | Last-slot simultaneous acceptance; dispute versus confirmation/cancellation; parallel withdrawals; appeal versus finalization at deadline. |
| Provider reliability | Duplicate/out-of-order webhooks, wrong signature/merchant/amount/currency, repeated clicks, timeout after accepted transfer, missing callback, authoritative failure/reversal and once-only compensation. |
| Cases/admin | All-amount two-human approvals, changed-decision invalidation, different appeal reviewer, nonresponse escalation, held refund portions and no-action outcome. |
| Chat/events | Persist-before-sent, interrupted reconnect replay, duplicate client IDs, monotonic reads, closed-thread evidence, queue lease recovery and exhausted jobs. |
| Delivery | Zoho delivery to real school mailboxes; Africa's Talking to MTN/Airtel/Glo/T2 including DND; OTP dispatch immediately rather than reminder batching. External tests wait for accounts/approved routes. |
| UI/accessibility | Student/poster/partner/admin journeys at 320 px and desktop; keyboard/focus; all error/pending/offline states; PWA sensitive-cache restrictions. |
| Recovery | Isolated restore of DB and files together, lost credentials/project scenario, ledger/provider reconciliation, and prevention of replaying already-paid operations. |

CI checks formatting/types/lint, relevant unit/DB/integration tests, migration from clean and representative previous schema, and critical journey tests before merge/deployment. Test local/synthetic first, then sandbox contract verification. Label fake-provider evidence accurately; it is not proof of a Bachs integration.

Use the technical source's initial synthetic performance fixture of 1,000 users, 10,000 jobs, 50,000 applications and 250,000 short messages only where capacity permits. Start measured mixed workload at 50 concurrent active clients; add a controlled higher-load scenario before expansion. Record device, RTT/throughput/loss, dataset, region, build, and cold/warm results. These fixtures are test conditions, not promises of Free production capacity.

## 11. Implementation sequence

This is a dependency map. Only the current phase receives a detailed execution guide; later phases remain overview items until requested. No fixed release date is invented.

Backend-first delivery is confirmed. Phases 1–6 emphasize infrastructure, backend contracts, automated tests, measured performance and recovery. A small deployment compatibility probe or synthetic test client is verification tooling, not production interface implementation. Designer work may proceed in parallel. Production UI and full browser acceptance are completed in phases 7–8; backend-only evidence cannot establish mobile usability or production ops-screen completion.

| Build phase | Deliverable and dependencies | Exit evidence |
| --- | --- | --- |
| 0 — planning and decisions | Confirm actual folder, canonical source handling, proposed decisions, test boundaries and outstanding owner/provider gates; approve root spec. Start provider onboarding checklist without secrets. | User-approved dated root spec; decision/blocker register; documentation workflow agreed. |
| 1 — foundation and deployment proof | Repository, canonical docs, agent rules, pinned framework/Cloudflare compatibility proof, local DB/migrations, synthetic fixtures, isolated configuration and CI. | Reproducible local start and clean migrations; verified staging deployment for routing/cookies/rendering/assets/caching; preview isolation. |
| 2 — identity and protected operations backend | F1–F2 backend contracts, staff capabilities/MFA checks, verification-queue queries/commands, private file pipeline, basic audit/events. | Both tracks work through synthetic API/command tests; direct access-denial matrix passes; production screens and real intake remain gated. |
| 3 — first complete sandbox backend transaction | F3–F6/F8 commands: exact funding → discovery → apply/accept → start/submit → poster confirmation → wallet → manual bank withdrawal. Include persisted application thread, in-app notification records and authorized ops inspection endpoints. | API/test-client Bachs sandbox journey when access is available; balanced accounting and deduplication/reservation tests. Before then, explicitly labelled fake-provider journey only; full browser acceptance comes later. |
| 4 — multi-worker and contested outcomes | Complete per-slot cancellation/refunds, splits, disputes, evidence, appeals, independent approvals, exception handling and audit checkpoints. | Races and appeal holds pass; no unrelated allocation freezes; manual finalization and replay are safe. |
| 5 — communication and marketplace backend completion | F7/F9/F11 backend, private realtime replay/read state, transactional delivery/reminders, rating/counter rebuilds and F12 metrics/ops contracts. | Backend F1–F12 acceptance map passes; notification destinations, suppression, private access and connection replay are tested. Screen/deep-link browser evidence remains pending frontend integration. |
| 6 — backend verification and measured optimization | Security/concurrency/failure/load checks, query/region/queue/provider measurements, reconciliation and isolated DB/file restore drills; tune demonstrated bottlenecks and document API contracts/runbooks. | Recorded backend benchmark conditions/results, critical invariant tests and recovery evidence; clearly list provider tests still blocked by unavailable accounts. No claim of measured UI performance. |
| 7 — designer-led frontend and integration | Approved mobile designs for student/poster/partner/staff screens, wired to verified backend commands. Implement all loading/empty/denied/pending/offline/error/success states and PWA behaviour. | Functional F1–F12 product screens and protected ops console; browser journeys, notification deep links and accessible interactions work without duplicating backend rules. |
| 8 — whole-product readiness and rehearsal | Nigerian mobile/page performance, PWA/accessibility, full security/failure/recovery regression, complete handover, provider contracts, budgets, staffing and owner policies. | Full F1–F12 acceptance evidence, launch sign-offs and safe ops rehearsal; no money/authorization invariant waived. |
| 9 — capped live pilot, then beta | Owner approves specific money exposure and cohort; observe delivery, fees, reconciliation, latency and support before expansion. | Pilot reconciles without unresolved unsafe failures; owner approves expansion; beta targets tracked separately. |

Financial controls, essential events and ops visibility accompany the first money implementation. They are not deferred to final visual polish.

## 12. Operations, launch gates and measurement

Before live money, obtain written Bachs acceptance of conditional holding, ownership/custody, holding duration, worker KYC, allocations, freezes, full/partial refunds, chargebacks, commissions, manual withdrawals, lookup/idempotency and platform-funded fees. Verify each exact endpoint/event/raw-body signature with official/account documentation; do not assume another provider's signature or an undocumented escrow API.

Before production OTP, verify Africa's Talking transactional sender approval and Nigerian network/DND delivery. Start account onboarding early; the source warns approval can take at least two weeks, but actual timing must be confirmed. Verify Zoho sender/domain authentication and real school-mailbox delivery. No provider access exists at drafting time.

Before taking live funds:

- Named verification/case reviewers, independent financial approvers, appeal reviewer, senior ops and support coverage are available. Multiple synthetic test users are never a substitute for separate live humans.
- Pilot maximum per-slot/job/withdrawal and overall held exposure, cash fee reserve and suspension procedure are signed off; values remain open rather than invented.
- Privacy, retention, age, prohibited work/academic integrity, terms, data processing and incident responsibilities are approved by the owner with appropriate advice.
- Automated encrypted offsite DB exports and separately protected Storage contents are active; restore drills and reconciliation meet approved objectives. The source's proposed engineering objectives are ≤1 hour financial data loss and ≤4 hours core service restoration, subject to measurement/sign-off. Evidence/chat objectives also need explicit agreement.
- No included Free backup, PITR or Storage protection is assumed. Determine a viable recovery setup and cost before launch; budget does not override financial safety.
- Alerts/runbooks cover callback failure, queue backlog, unknown movements, mismatches, capacity and expired delivery credentials. Audit checkpoints have independent storage/control.
- Deploy migrations with reviewed backward-compatible changes and tested recovery/forward-fix. UI rollback is not DB rollback. Keep webhook identity/endpoints stable and never reset journals to repair a screen.

Weekly quota review: investigate at 70% and plan action before 85% of confirmed quotas. The source budgets USD 10/month initially plus a USD 25 potential upgrade reserve, excluding payment/delivery/recovery/staff costs. These are planning targets, not current quoted prices or spending approval. Verify live plans before provisioning. Upgrade by measured latency/capacity/recovery need; do not simulate usage to avoid pausing.

Beta targets: 100 verified students, ≥60 distinct funded jobs, ≥30 completed jobs under the all-slots-resolved definition; median first application <2 hours; >90% release without dispute; median first dispute response <24 hours and initial decision <72 hours; >25% active users participating in two distinct jobs. Define the active-user reporting denominator before publishing repeat-use results. Separately track assignments, final settlement time, GMV, commission, provider/refund/delivery costs and contribution margin by poster type.

## 13. Decision register and gated follow-ups

### Confirmed decisions

D01: Use the v2 PDF baselines, not the earlier draft. D02: Keep prescribed vendors and stack. D03: No accounts/assets/application repository were available at initial planning; confirm any changes before integration. D04: Actual project folder is `/Users/mac/Desktop/NoBrokeDayz`, supplied on 29 October 2026; it was empty when inspected. D05: Development can use synthetic data and later sandbox services while live gates remain blocked. D06: No application code before specification approval; one phase guide at a time thereafter. D07: Email/password login, with separate school-email and phone verification. D08: Separate application deadline and work needed-by fields. D09: Whole-product scope with backend-first implementation and verification; production frontend follows verified backend contracts and designer readiness. D10: All section 13 recommendations accepted on 29 October 2026, with their stated evidence and detailed-approval gates preserved. The user subsequently approved the whole specification, including the testing approach, on 29 October 2026.

### Recommendations approved by the user — 29 October 2026

The user approved all recommendations in this section. The decisions below are accepted; any provider evidence, detailed limits, visual choices or policy approvals explicitly required by a recommendation remain gated. This approval does not assert those dependencies are complete or constitute approval of the entire specification.

| ID | Topic | Approved decision | Remaining evidence or follow-up |
| --- | --- | --- | --- |
| Q2 | Application timing | Application deadline must be in the future when publishing and no later than the work needed-by time. Store/display both separately, with Lagos time labels. | Test boundaries and versioned extensions; future timing changes require an explicit product decision. |
| Q3 | Design and delivery | Designer prepares mobile flows and all non-happy-path states in parallel with backend work. Define backend response/error contracts first; production screens follow verified relevant backend contracts and approved designs. | Actual design handoff and visual choices remain pending; backend work is not blocked by design availability. |
| Q4 | Minimum amounts and rounding | Add no arbitrary platform price or withdrawal minimum. Verify Bachs-supported minimums and obtain any required owner policy before enabling unsupported amounts; enforce explicit integer money validation. | Account-specific minimums and edge-case policy must be evidenced before the funding/withdrawal contract is finalized. |
| Q5 | Duplicate identities | Enforce unique verified phone/institutional ownership where appropriate and send suspicious duplicates to human review. Confirm permitted identity matching with owner/provider; do not claim this guarantees one unique person. | Detailed matching/ownership/recovery policy before live verification. |
| Q6 | Application closure/reapplication | Maintain one application record per worker/job. After withdrawal/rejection preserve read-only conversation history. Reapplication remains unavailable until a later explicitly approved transition policy. | Document/test application and thread transitions; any later reapplication is a product change. |
| Q7 | Post-settlement reports | Keep support/reporting available. Staff handle post-settlement conduct/provider exceptions explicitly; reports do not automatically reopen funds or retroactively debit wallets. | Operational handling/escalation details before the live pilot. |
| Q8 | Validation and transitions | Specify bounded inputs, allowed state transitions and configurable documented limits, supported by security tests. Present detailed values/matrices in foundation/identity planning for approval before the affected implementation. | Exact lengths, expiry/retry limits and transition matrices are not invented or approved by this general recommendation approval. |

Provider accounts, named staff, actual allow-list domains, retention periods, funding reserve, pilot caps, recovery configuration and repeat-use metric definition remain evidence-backed owner/launch decisions. They need not all be answered to approve a sandbox-oriented build plan, but each affected live capability remains blocked until resolved.

### Provider-reference finding after specification approval — 29 October 2026

Official Bachs documentation states that NGN bank-transfer payments cannot be refunded through its Refund API, and a payment supports only one refund (a failed refund does not count); a successful partial refund prevents a later refund of the remainder. This conflicts with assuming that one multi-slot collection supports independently timed slot refunds. Source: https://docs.bachs.io/guides/refunds (checked 29 October 2026).

Preserve the approved product refund entitlements. Resolve the exact provider-supported return-of-funds route and multi-slot refund strategy with evidence and explicit owner approval before freezing affected payment contracts or enabling live funding. Neither disabling refunds, restricting the product to a single worker, switching the collection method nor treating a new payout as an equivalent refund is approved by this research. Foundation and unrelated synthetic backend work may proceed under the phased plan. See docs/bachs-payments-reference.md for researched capabilities, limitations and required confirmation; it is a reference, not a completed integration or provider approval.

## 14. Development documentation and community workflow

The role brief requires one brief weekly product update, relevant screenshots/recordings when available, and one or two content opportunities per week. Significant milestones also need evidence. These activities should fit development work without reducing quality or delaying delivery.

Use this workflow: build → document → explain → prepare material for Community and Growth review → record feedback and return relevant findings to product decisions. This plan prepares material only; the user chooses when and how to send it. Nothing is published or sent by this planning task.

Every phase guide must include:

1. **Milestone evidence:** requirement IDs, what works, test result/build reference, remaining limitations and a genuine lesson/challenge.
2. **Safe capture:** synthetic/demo accounts, non-sensitive screen/recording, no IDs/bank details/tokens/private notes; distinguish prototype, fake provider, sandbox integration and live capability.
3. **Plain-language note:** what was built, why it matters to students, and an honest completed/in-progress/planned status.
4. **Content opportunities:** one or two weekly ideas grounded in actual progress; do not force two public posts at every milestone.
5. **Feedback:** one or two usability/user-need questions; log observation, affected feature, decision and rationale. Feedback is not automatically approved scope.
6. **Review gate:** prepare the handoff for Community and Growth; seek the appropriate approval before sensitive material or internal documents are shared. Public claims, dates and capabilities require owner approval.

Even a week without a major completion gets a short accurate update: progress, blocker, lesson and next work. Do not manufacture a milestone or publish internal specs to fill a content quota.

## 15. Definition of done and handover

A feature is done when the UI, authorization, state/ledger rules, error/retry paths, required tests, durable events, operational inspection and handover notes work together. A screen or fake-provider test alone cannot establish an integrated financial feature as complete.

Each phase closes with its actual evidence, unresolved issues, milestone documentation packet and user confirmation. Completing a build phase does not automatically approve live money or public communications.

Repository handover must allow a new developer to set up synthetic local data, run critical tests, deploy to staging, trace a payment reference, investigate an exhausted job and restore DB/files without private conversational context. Maintain canonical product/technical docs, decision log, permission/data dictionary, provider/recovery guide, runbook, deployment rollback instructions and service ownership inventory with no secrets in Git.

Approval record: **APPROVED by the user on 29 October 2026**, following acceptance of all section 13 recommendations. The user explicitly stated “Yes i approve the Specification” in response to approval of the complete specification and testing approach. Recorded scope: whole-product, backend first; frontend after relevant backend verification and designer readiness. The provider-reference finding above is a gated capability conflict, not an approved change to product requirements. No live launch, external communication or automatic progression to another build phase is implied.
