# No Broke Dayz — Revised Product Requirements

> **Transcription of supplied PDF; this is not the original Markdown file.**
>
> Source: `No_Broke_Dayz_Revised_PRD.pdf` — version 2.0, 26 October 2026 (11 pages). Extracted text was checked against rendered PDF pages, including tables, acceptance criteria, formulas and state names.
>
> This is the repository canonical copy of the source baseline. Newer provider findings remain in [`bachs-payments-reference.md`](bachs-payments-reference.md) and have not been merged into this transcription.

Version 2.0 | 26 October 2026 | Implementation baseline

Product owner: Mubarak Salaudeen, Founder and Product Lead

Platform: mobile-first responsive web application and installable PWA

Initial market: University of Lagos closed beta

Companion document: No_Broke_Dayz_Technical_Specification.md

Product behaviour, acceptance criteria and launch responsibilities for the UNILAG web MVP.

## 1 Purpose and decision status
No Broke Dayz connects verified university students to paid campus micro-jobs. Verified students supply the work; verified students and approved non-student partners hire them. Funded jobs, scoped messaging, controlled payment release and accountable dispute handling support trust.

This revision replaces Draft v1.1 as the product baseline. It incorporates the founder's accepted decisions from the review. Development has not started. Design and implementation begin against this version; no provider account, approval, deployment or completed integration is implied.

Bachs is the selected payment provider and Africa's Talking is the selected SMS provider for the initial implementation. Cloudflare hosts the Next.js web app; hosted Supabase Free supplies the backend initially. Zoho CPaaS supplies transactional email. These selections are settled; live capability approval, account-specific fees and real delivery tests remain launch dependencies.

Firm requirements are mobile-first design, fast response on Nigerian mobile networks, exact advertised poster payment, 5% worker-side commission, and no hidden provider charges passed to either party. This document states product behaviour; its companion specifies how to implement and verify it.

## 2 Goals and launch boundaries
The MVP must let a verified student find, apply for, complete and receive payment for a job. A verified poster must be able to publish a funded job, choose workers, coordinate work, confirm completion and rate the worker. Either party must be able to obtain human review when work or payment is contested.

Launch is restricted to UNILAG, NGN and users aged 18 or above. Student accounts can both hire and work. Non-student accounts can hire only. One person has one account. A verified individual may post on behalf of a named student organisation; team membership, shared credentials and multi-user organisation administration are outside MVP scope.

Native apps, multiple campuses, skills testing, automated ranking, featured listings, financial products and recruitment partnerships remain outside MVP. The AI assistant remains Phase 2, after F1-F12 operate reliably. The manual interface must be complete without AI.

### 2.1 Beta measures

```text
 Measure                                    Target or definition
 Verified students                          100
 Funded jobs posted                         At least 60 distinct jobs
                                            At least 30 jobs with at least one paid completed assignment and all funded slots
 Completed jobs
                                            resolved
 Time to first application                  Median below 2 hours after listing becomes discoverable
 Release without dispute                    More than 90% of paid assignments
 Dispute first response                     Median below 24 hours
 Initial dispute decision                   Median below 72 hours; separate from appeal and final movement
 Repeat use                                 More than 25% of active users participate in at least two distinct jobs
 Measure                                    Target or definition
 Commission                                 Record 5% of the worker's awarded gross share, not 5% of net payout
 Contribution margin                        Commission less provider, refund and delivery costs; tracked separately
```
Multi-worker job counts and assignment counts must be reported separately. An initial decision is not a final financial resolution while an appeal hold remains. Track total time to final settlement as well as the original dispute targets.

## 3 Roles and access
```text
 Role                                       Allowed product actions
 Registered but not verified                Complete verification, check its status, request help, manage own login
 Verified student                           Browse, apply, message, work, post, fund, confirm, withdraw and review
 Verified partner                           Browse, post, fund, message applicants, confirm and review; cannot work
 Verification reviewer                      Inspect assigned evidence and approve or reject verification
 Dispute reviewer                           Investigate cases, contact parties and propose decisions
 Financial approver                         Independently approve an admin money decision
 Appeal reviewer                            Review an appeal; must differ from the initial decision reviewer
 Senior ops                                 Sign off decisions involving an unresponsive party and manage escalation
```
Staff permissions are explicit grants. A normal user cannot promote themselves or edit verification, capabilities, balances or ratings. Staff may hold several duties, but the same person cannot provide both approvals or review their own appealed decision.

Users must complete the applicable verification track before browsing jobs, viewing job details, applying, posting, funding or messaging. Registration screens, legal information and support remain accessible. Suspension immediately blocks the affected actions, with an explanation and support route; ops must provide access to unresolved financial support without exposing other users' data.

## 4 Scope and priority
P0 means required for beta. P1 means a later enhancement to an already functional core flow.

```text
 ID              Feature                                                                                          Priority
 F1              Authentication and compulsory dual-track verification                                            P0
 F2              Profiles and verified badges                                                                     P0
 F3              Job posting and exact-total funding                                                              P0
 F4              Job discovery, search and filters                                                                P0
 F5              Applications, selection and per-worker assignments                                               P0
 F6              Controlled release, commission and bank payouts                                                  P0
 ID              Feature                                                                                Priority
 F7              Two-sided ratings and reviews                                                          P0
 F8              Wallet balances, withdrawal and essential transaction history                          P0
 F9              Event-driven email and in-app notifications                                            P0
 F10             Disputes, appeals and evidence                                                         P0
 F11             Job/application messaging and read state                                               P0
 F12             Protected admin and ops console                                                        P0
 F13             Conversational AI assistant                                                            Phase 2
```
Rich wallet exports, voice notes, advanced notification preferences and richer analytics are P1. Essential wallet and notification behaviour is promoted from P1 because the P0 payment and dispute flows depend on it.

## 5 Functional requirements
## F1 Authentication and verification
At registration the user selects student or non-student. Student verification uses an allow-listed school email, such as the confirmed UNILAG institutional domain, and a one-time email code. Email ownership verification on an allowed domain completes Track A without manual approval. Users without access to their school email can upload a student ID for manual review.

Track B collects legal name, phone OTP, government ID and campus connection evidence. Accepted connection evidence remains a shop/stall photo with location, staff ID or an attributable endorsement from an already verified student. Every Track B submission receives human review, even when all fields are complete. A vouch is evidence, not automatic approval.

Both tracks require a verified phone number for payout/account security. School-email verification and phone verification remain separate facts. School-email possession is the MVP proxy for student status; it is not presented as a comprehensive identity or current-enrolment check. Student approval does not eliminate Bachs' separate payout identity requirements.

### Acceptance criteria

- Non-student users cannot apply or be accepted as workers, through either interface or direct API calls.
- Student accounts gain work/post privileges only after the full Track A and shared requirements pass.
- Manual-review requests appear in the ops queue within one minute of submission.
- The user sees pending, approved, rejected or needs-information status and the next step.
- Resubmission preserves the prior review history. Staff record rejection reasons.
- No verification document has a public URL. Review access is restricted and audited.
- Age confirmation is required. Account recovery or a phone/email change cannot silently bypass verification.
Any re-verification schedule and the document-retention policies require owner sign-off before launch; they are not invented as new verified institutional arrangements.

## F2 Profiles
Profiles contain display name, photo, campus/faculty where relevant, short bio, skills, simple availability, verified badge, role-specific ratings and completed-work count. Partners can show a business name and location. An organisation label attributes who a person represents without creating a separate team account.

Users edit their own ordinary profile fields. The system owns badges, scores and counts. Shareable profiles exclude private phone, bank, legal identity and verification evidence.

### Acceptance criteria

- Posters can open applicants' profiles from the application list.
- Worker and poster ratings are distinct, each with its review count; no reviews displays as unrated.
- Completed-work counts update once per qualifying finalized assignment.
- Profile edits cannot change role, approval or financial information through a generic update path.

## F3 Job posting and funding
A job records title, description, category, location type/detail, pay per worker, number of workers needed, needed-by time and any agreed start requirements. Default slots is one. Poster sets the price; suggested pricing is deferred until sufficient marketplace data exists.

Pay is explicitly per worker. Display the total before funding: total = pay per worker x slots. For three workers at NGN 3,000 each, the advertised total and poster's payment are NGN 9,000. Each completed worker's NGN 3,000 gross allocation produces NGN 2,850 net earnings and NGN 150 gross commission.

The poster pays exactly the displayed total. No processing, platform or payout surcharge is added. Bachs payment fees are platform expenses. Processing fees may reduce provider cash received, but never reduce the poster's funded principal or worker entitlement in the internal records; platform funds cover the difference.

### Acceptance criteria

- Jobs remain draft/awaiting payment until server-verified successful funding for the exact expected NGN total.
- The poster sees one clear total without a fee line added to it; per-worker price and worker count explain that total.
- Failed, pending and cancelled payment attempts have distinct states. Unknown status is checked before offering
a potentially duplicate payment.
- Retries and duplicate provider callbacks cannot publish or credit a job twice.
- A funded job's agreed scope, price and slots cannot be changed in place. Material changes require an explicit
replacement/cancellation flow; jobs with accepted workers require consent or ops review. An application deadline extension for still-unassigned slots records a new prospective terms version and never changes accepted workers' terms.

## F4 Discovery and categories
Only verified users see discoverable funded jobs with unfilled slots and an unexpired application deadline. Default order is newest first within UNILAG. Filters combine keyword, category, pay per worker, location and needed-by date without full page reloads.

Initial categories are errands, tutoring, design and creative work, writing and editing, tech help, event support and other permitted campus services. Tutoring, feedback and editing are distinguished from completing assessed academic work for another person. Prohibited work and conduct rules must be visible in posting and reporting flows.

Cards show title, gross pay per worker, slots remaining, category, location, poster badge, posted time and payment-protection status. The detail view shows the worker's 5% deduction and exact net amount before application/acceptance. Protection wording goes live only after the Bachs arrangement supports that promise.

### Acceptance criteria

- Unfunded, cancelled, expired and fully filled listings never appear as available.
- A partially filled job remains discoverable for its remaining slots.
- Stale results fail safely if another applicant fills the final slot.
- Filtering updates the URL or equivalent restorable state and preserves usable back navigation.

## F5 Applications and assignments
Workers apply with an optional short note. Applying does not reserve a slot or permit starting work. Posters select applicants. Each accepted application creates a separate assignment with a reserved gross allocation, its own work status and private conversation.

Assignment lifecycle is Assigned, In progress, Submitted and Completed, with Cancelled and an attached dispute hold where applicable. A job listing separately has draft, awaiting-payment, open, filled, expired or cancelled visibility. This separation allows one worker to be in progress while another slot is still open.

### Acceptance criteria

- A worker can have only one application per job and cannot apply to their own job.
- Simultaneous acceptance attempts never exceed slots or reserve the same funds twice.
- Acceptance notifies both parties and presents the agreed scope, amount and next action.
- A worker explicitly marks work started; parties can contest an incorrect start through ops.
- Only the assigned worker can submit that assignment; only its poster can confirm ordinary completion.
- Submission does not release funds. The poster confirms or reports a problem.
- A completed assignment cannot be submitted, paid or reviewed twice.

## F6 Payment release and provider costs
Funds remain held until an authorized outcome. Valid authorizations are poster confirmation of submitted work, a permitted explicit pre-start cancellation/refund, or a final admin dispute decision. Time, silence, reminders, deadlines and background processing never authorize release or refund.

Poster confirmation credits 95% of that assignment's gross amount to the worker's available earnings and records 5% gross commission. Bank withdrawal is a separate user action. Any external movement executes only against a durable recorded authorization.

For a partial settlement with a NGN 3,000 allocation and NGN 2,000 gross awarded to the worker: NGN 1,900 goes to the worker, NGN 100 is commission, and NGN 1,000 returns to the poster. No fee is charged on the refunded share. Platform absorbs provider/refund costs.

### Acceptance criteria

- No release without verified funded principal and an authorized transition.
- A dispute freezes the affected assignment allocation, including unfinalized refund portions, without freezing other
assignments or unrelated available earnings.
- Opening a dispute and confirming completion cannot both succeed against the same allocation.
- Provider fees cannot reduce the worker's promised net payout or add poster charges.
- Monetary amounts use integer kobo with a single disclosed rounding policy.
- Unknown, reversed, failed and completed external movements remain distinguishable and reconciled.

## F7 Ratings and reviews
Each completed assignment permits one worker-to-poster review and one poster-to-worker review, scored 1-5 with optional text. Reviews cannot be edited in MVP; users can report them. Eligible reviews unlock only after the assignment is finalized and any dispute/appeal is closed.

Show role-specific averages with counts and underlying reviews. Do not add automated recommendation ranking, response-speed badges or quality labels at launch. Start with explainable evidence, not unsupported reputation claims. Admin moderation retains an audit record.

## F8 Wallet and manual withdrawal
The wallet shows available earnings, pending job allocations, appeal-held amounts, withdrawal processing amounts and transaction history. Posters also see funds held for their jobs and refunds. Worker earnings are not available before authorized release.

Manual withdrawals to a verified Nigerian bank account are required. The platform adds no arbitrary withdrawal minimum or withdrawal fee. A provider-imposed minimum must be confirmed and disclosed before launch. A lower available balance remains visible and does not disappear. Encourage combining withdrawals without forcing accumulation.

### Acceptance criteria

- Worker bank receipt equals the requested available withdrawal amount; platform separately covers provider fees.
- A withdrawal atomically reserves available earnings before calling Bachs; concurrent attempts cannot overspend.
- Pending bank transfers are shown as processing, not successful. Success requires authoritative provider
confirmation.
- Failed transfers restore the reserved amount only after failure is established; uncertain results stay under
reconciliation.
- Duplicate clicks, retries and repeated webhooks never create duplicate bank payments.
- Refund status is shown to posters until completed. A refund is not automatically a spendable general-purpose
wallet top-up.

## F9 Notifications and reminders
Use durable domain events to create in-app notifications and request transactional Zoho email. Events cover new application, acceptance, submission, payment release, withdrawal result, verification result and the dispute/appeal timeline. A chat conversation remains the source for messages; avoid an email for every message.

Submission reminders default to 24 and 48 hours while confirmation is outstanding; at 72 hours direct the affected user to the dispute route. Suppress reminders after confirmation, cancellation or dispute. These are notification timings, not financial deadlines. SMS is limited to phone verification, sensitive account/payout actions and individually justified urgent messages.

### Acceptance criteria

- Notifications deep-link to the relevant assignment, application, wallet item or case.
- In-app notifications persist independently of email delivery.
- Repeated events/retries do not create duplicate notifications or uncontrolled SMS charges.
- Users get a clear pending or retry state if a code cannot be sent; OTP dispatch is immediate, not delayed to a
reminder batch.

## F10 Disputes and appeals
Either party can report a funded assignment from Assigned through Submitted. Keep Report a problem visible on assignment detail, in the conversation header, beside held wallet amounts and in the Help/Dispute Center. An unfunded job cannot be disputed as an escrow case.

The report captures reason, narrative, evidence, desired outcome and follow-up details. Reasons include payment not released, incomplete work, work not as described, unresponsive/no-show, conduct/safety and other. The system attaches the relevant agreed job terms and conversation history. Rival applicants' conversations are not disclosed.

Case stages are Open, Under review, Contacting other party, Verifying, Decision made, Appeal and Closed. Both parties see the same case status and party-visible timeline; internal staff notes and third-party/private identity material remain restricted.

**Ops procedure:**

1. Triage and acknowledge; conduct/safety concerns take priority. First-response target remains 24 hours.
2. Review evidence, agreed scope and the relevant conversation.
3. Contact the other party in-app, then by phone or approved in-person visit where practical. Log at least two
attempts across two channels before classifying a party as unresponsive.
4. Verify facts and attributable third-party evidence where helpful.
5. Record the proposed outcome and written reason. Non-response decisions require senior sign-off; silence alone
never decides a case.
6. Notify both parties and keep the disputed allocation held during the appeal stage.
7. An authorized admin finalizes and executes the outcome after required approvals; then notify and close.
Outcomes are full worker award, full poster refund, split, or no action. No action ultimately removes the hold and restores the prior valid assignment state, without moving money. Financial actions need a reason code, written note and two distinct staff approvals for every amount during beta. This replaces the undecided threshold with an all-amount beta rule.

Each party may appeal once within 72 hours of notification of the initial decision. An appeal uses a different reviewer. The allocation stays held until the appeal decision is final. A final worker award, including a partial-work award, completes that assignment; a full refund cancels it. Only completed assignments unlock reviews. A job counts as completed only after at least one paid completion and resolution of all funded slots, including refunds of unused slots. Without an appeal, expiry of the window makes the case eligible for manual finalization; a timer never releases/refunds funds. A user may add evidence before the initial decision and through an appeal evidence request; decision records and their evidence versions remain preserved.

### Acceptance criteria

- Opening a case atomically establishes the hold before any competing release can complete.
- All admin money outcomes have independent approvals and tamper-evident audit records.
- A timely appeal prevents initial-outcome execution. Both parties receive the final written reason.
- Ordinary poster-confirmed completions do not inherit a blanket 72-hour delay.
- Repeated unfounded claims can trigger documented warnings or suspension after human review.

## F11 Job messaging
Create one private thread for each application when it is submitted. Poster and applicant can clarify the job before selection; the accepted thread continues through completion. There is no general user-to-user chat. Text and read/unread state are P0; voice notes are deferred.

### Acceptance criteria

- Only the verified poster, that applicant and specifically authorized case staff access a thread.
- Messages persist before the sender receives confirmed delivery acknowledgement.
- Online delivery and read-state changes arrive in near real time.
- Reconnection reloads missed messages without duplicates; pending messages are visibly distinct from saved
messages.
- Chat evidence remains available to authorized dispute handling. Withdrawal/rejection cannot erase it.
- Closed threads are read-only unless a case is active; support/report access remains available.

## F12 Admin and ops console
Use a protected section of the same application. Include Track A fallback and Track B queues, jobs and funding inspection, financial ledger views, withdrawal/refund exceptions, dispute triage and metrics. Case views combine parties' submissions, relevant chat, evidence, contact logs, approvals and held allocation state.

The console supports requests for information, assignment to reviewers, senior escalation, proposed outcomes, independent approval, appeal review and final execution. The UI must not replace these workflows with an export button or a hidden privileged action on an ordinary page.

### Acceptance criteria

- Staff access is server-authorized, logged and protected by MFA.
- The initiator cannot second-approve their own action or review their own appeal.
- Staff cannot silently edit ledger entries, remove evidence or release funds without a valid case.
- Failed/unknown provider movements are clearly actionable; manual replay reuses the original operation identity.
- Metrics include users, funded jobs, assignments, GMV, commission, provider expenses, contribution margin and
dispute performance, split by poster type.

## 6 Mobile experience and performance
Mobile-first is mandatory, not a later responsive adjustment. Design the primary journeys at 320-430 CSS pixels, then expand them to desktop up to 1440 pixels. Use readable type, touch-friendly actions, accessible focus, adequate contrast and keyboard-accessible core flows. The designer supplies loading, empty, denied, pending, offline, failure and success states for every core journey.

The baseline remains key pages usable within three seconds on a defined mid-range Android and representative 3G/4G test profiles. Measure actual Nigerian-network behaviour and retain both cold and warm results. Additional acceptance targets are p75 LCP at most 2.5 seconds, INP at most 200 ms and CLS at most 0.1; p95 feed/filter response at most 500 ms under the agreed load profile; and p95 saved-message arrival below two seconds while both clients are connected. Targets require measurement, not a vendor promise.

### Acceptance criteria

- Avoid unnecessary full reloads, large initial scripts, duplicate reads and unbounded lists.
- Lazy-load the admin interface and optional screens; optimize uploaded display images.
- Money actions remain pending until server/provider confirmation; optimistic UI never fabricates balances.
- PWA installation and cached app assets work. Sensitive data and money actions do not become uncontrolled
offline caches or replay queues.
- Include not-found, access-denied, offline, maintenance and recoverable error pages with clear next steps.
- Error messages explain what happened and what to do, without exposing SQL, secrets or raw provider failures.

## 7 Reliability privacy and safeguards
The beta availability target remains 99%, measured across core user journeys and including provider dependencies in incident analysis. There is no contractual SLA implied by the Free backend plan. Restore procedures and money reconciliation must be tested before live funds.

Collect only needed identity data. Use restricted private storage, time-limited file access, auditable staff access and a signed retention/deletion policy. Account deletion requests must distinguish removable profile data from records retained for a lawful financial/dispute purpose; indefinite retention is not the default. Privacy ownership, cross-border processing basis, document retention periods and breach response are launch sign-offs.

Passwords and sessions are managed by Supabase Auth. Card data stays with Bachs. Rate limits, OTP resend controls, suspicious-withdrawal alerts and secure bank-detail changes protect the core flows. A verified status never permits arbitrary backend access.

## 8 Delivery and ownership
The founder handles frontend/backend implementation. The designer owns visual and interaction design with implementation collaboration. The admin team owns verification, investigations and appeals; distinct staff must be available for approvals and appeal review. In-person visits use vetted staff/ambassadors with logged access and escalation rules.

Implementation sequence:

1. Resolve provider live capabilities and launch policies; complete schema, state transitions and permission design.
2. Establish repository, migrations, local development, isolated staging, CI and core access tests.
3. Deliver a full sandbox journey from verification and funding through assignment, release and bank withdrawal,
with essential admin inspection.
4. Complete cancellation/refunds, disputes/splits, appeal holds and independent approvals, plus chat, notifications
and ratings.
5. Test races, duplicate callbacks, provider failures, reconnection, access denial, Nigerian mobile performance and
recovery.
6. Rehearse ops and launch a small capped real-money cohort, then expand to 100 verified students and initial
partners.
7. Iterate from metrics. Scope F13 only after F1-F12 are stable.
A feature is complete only when its screens, permissions, error paths, essential tests, events and handover notes work together. The release date depends on measured implementation progress, not an invented schedule.

## 9 Phase 2 AI boundary
The assistant may search jobs, draft posts, apply and inspect the user's own status through the same business commands as the manual UI. It has no privileged database channel. Publishing, acceptance, funding, release and other irreversible actions need explicit human confirmation. Record attribution, authorization and execution result.

The assistant can help open a dispute and read allowed status; it cannot decide a case or trigger an ops release/refund. Add rate limits and retain the complete manual experience. Native apps and multi-campus expansion are separately approved phases.

## 10 Launch dependencies and unresolved operating values
These are checks to complete, not reversals of settled vendor choices.

```text
 Item                                Owner                             Required evidence before live use
                                                                       Written accepted funds flow, capabilities, holding
 Bachs holding and payouts           Founder and provider
                                                                       duration, refunds/splits and fee funding
 Provider minimums and                                                 Account-specific rate card and minimum payout;
                                     Founder
 fees                                                                  exact-price/net-payout tests
                                                                       Approved transactional sender ID and delivered OTP
 Africa's Talking SMS                Founder and provider
                                                                       tests across four Nigerian networks including DND
                                                                       Zoho domain authentication and verified email/code
 Email                               Founder
                                                                       delivery
                                                                       Named reviewers, independent approver, appeal
 Ops coverage                        Founder and admin lead
                                                                       reviewer and senior escalation
                                                                       Retention periods, legal holds, age rules, permitted
 Privacy and job policy              Founder and appropriate adviser
                                                                       work and data-transfer arrangements
                                                                       Tested DB/file backup and restore, reconciliation and
 Recovery                            Implementer and ops
                                                                       recovery-time/data-loss objectives
                                                                       Documented pilot job/withdrawal exposure caps and
 Real-money limits                   Founder and ops
                                                                       suspension procedure
```
Use Supabase Free during development and potentially beta while verified capacity/recovery requirements permit. Review usage weekly, investigate at 70% of quotas and plan action before 85%. The infrastructure planning target is USD 10/month initially, with USD 25 held as an upgrade reserve; payment costs, SMS and staff time are separate. Upgrade based on capacity, latency or recovery needs rather than user count alone.

## 11 Revision record and references
Version 2.0 preserves the original marketplace, verification and human dispute model. Changes include per-worker pricing, separate assignments, P0 wallet/notifications, platform-funded provider costs, manual withdrawals, explicit cancellation rules, disputed-allocation appeal holds, all-amount independent admin approvals, 18+ beta and individually accountable organisation posting.

Source of original requirements: No_Broke_Dayz_PRD_Web_MVP.pdf, Draft v1.1, October 2026, supplied by the founder. Product decisions approved in the accompanying review conversation; providers confirmed on 26 October 2026.

External implementation references, checked 26 October 2026:

- Supabase pricing
- Bachs Connect
- Bachs fees
- Africa's Talking transactional approval
- Zoho CPaaS
- Web performance thresholds
The technical specification owns implementation contracts and operational procedures. This PRD owns user-visible behaviour. If the two disagree, record and resolve the conflict before implementation; do not silently change financial or verification rules.
