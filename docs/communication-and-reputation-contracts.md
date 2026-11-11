# Communication and reputation contracts — Phase 5 Step 1

Status: Step 1 inspection and owner-approved contracts, 10 November 2026. The user approved all five recommendations below. This approval does not replace migration-owned schema changes or the required implementation evidence.

## Settled requirements

- Submission reminders are due at 24 and 48 hours; at 72 hours, give the worker guidance to the dispute route while confirmation remains outstanding. Completion, cancellation and dispute suppress the reminder sequence.
- Schedules and reminders may create notices and delivery intents only. They cannot release earnings, refund, pay out, open or finalize a case, or otherwise move money.
- Each party may submit one immutable 1–5 review in their direction after the assignment is finalized as completed and its dispute/appeal is closed. Text is optional. Worker and poster averages/counts stay separate. No ranking, quality labels or automated moderation decisions.
- A completed job requires at least one paid completion and resolution of all funded slots. Completed assignments and jobs remain separate measures. A final worker award, including a split award, completes its assignment; no-action restores the prior valid assignment state and does not complete it.
- One private, text-only conversation belongs to each application. No general chat, attachments or voice notes. Participants can read retained rejected/withdrawn history; staff investigation access is case-scoped.
- Events are persisted with the source transaction. In-app notices survive email failure. Zoho transactional email is supplementary; do not email every chat message. Ordinary reminders use in-app/email first, with no new SMS reminder channel. Delivery is leased, bounded, retryable and idempotent; an ambiguous external result is reconciled rather than blindly resent. Exact external exactly-once delivery is not promised.

## Inventory: implemented behavior and gaps

| Area                       | Current behavior                                                                                                                                                                                                                                                                                                                                                                      | Gap for Phase 5                                                                                                                                                                                                                                                              |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Messages and thread access | One private thread per application; immutable saved text; sender-scoped client message ID; stable bigint sequence returned as a decimal string; DB rejects changed payload under a reused ID. Poster and applicant are checked on reads, sends and cursor updates. Sending requires the current role capability and an applied/accepted application.                                  | No Realtime topic/client/policy. Message reads support bounded replay pages, but no live subscribe/replay race handling is present. Direct thread reads do not grant case staff access.                                                                                      |
| Read cursors               | One private cursor per reader/thread; update is monotonic and cannot pass the thread's current last sequence.                                                                                                                                                                                                                                                                         | No unread-count projection or socket hint. Existing API/DB tests do not establish Realtime read-state delivery.                                                                                                                                                              |
| In-app notices             | Recipient-only persisted notices cover application decisions, new messages, assignment progress/completion/holds, case/appeal outcomes, refund progress and withdrawals. Event/recipient/type uniqueness prevents duplicate notices. Read state is independently persisted.                                                                                                           | Read projections return a safe type/title/time/read state, but no typed destination. There is no reminder scheduler or transactional email consumer. Identity verification results currently use a separate identity outbox rather than the marketplace notice read surface. |
| Domain events and outboxes | Marketplace events are append-only and written with marketplace transitions. Identity and financial outbox rows have delivery-state columns; payment-operation jobs separately have leased retry/reclaim/exhaustion behavior for the local simulator.                                                                                                                                 | Marketplace outbox is an immutable event record, not a delivery queue. There is no general notice/email claim, lease, retry, ambiguity reconciliation, or exhaustion consumer. Existing financial/identity outbox state columns do not provide those consumers.              |
| Case conversation access   | Case staff receive a bounded conversation snapshot through the case opening sequence in the assigned-reviewer case projection. Party reads and staff reads are separately authorized. Staff needs an active account, current dispute-review grant, AAL2 and the current case assignment; parties are excluded from reviewer access. Financial inspection alone grants no case access. | No staff member can use the ordinary participant thread read route. There is no active case-staff conversation Realtime channel or policy.                                                                                                                                   |
| Profile counters           | Safe profile projection returns null ratings and zero review counts. Completed-work count is currently computed from assignments for which the subject is the worker and work_state is completed. Generic profile input rejects protected counters.                                                                                                                                   | No review table or review commands. No poster completed-work measure, role-specific average, rebuildable review projection, or moderation record exists. Current completed-work predicate needs to be aligned with the finalized-completion contract.                        |
| Staff operations           | Existing identity review, case/appeal queues and commands, case-scoped evidence access, and read-only financial trace/reconciliation have dedicated handlers. Protected staff operations require the relevant current grant and AAL2 at the DB boundary.                                                                                                                              | No review-moderation queue, marketplace metrics endpoint, communication-delivery exception queue, or manual delivery replay route. Financial inspection is not a case or delivery permission.                                                                                |

## Owner-approved decisions and alternatives considered

The user approved the bold recommendation in each of the five sections on 10 November 2026. Other numbered alternatives are recorded for context and are not selected. The approval summary is in [decisions.md](decisions.md).

### 1. Reminder recipients and downtime catch-up

The timer starts at the committed submission event, using server time. The 72-hour submission guidance is distinct from the separate 72-hour case-appeal window.

**Approved:** the poster receives the 24/48-hour reminders, the worker receives 72-hour dispute guidance, and downtime catch-up coalesces to the latest due stage once.

**Recipient choices**

1. **Poster at 24/48 hours; worker at 72 hours (recommended).** The poster receives the action reminder while confirmation is pending. The worker receives the dispute-route guidance at 72 hours. This follows F9.2's worker waiting story and minimizes repeat notices.
2. **Both parties at 24/48 hours; worker at 72 hours.** The poster gets an action prompt, while the worker gets a neutral status notice. This provides symmetry but increases volume.
3. **Poster at 24/48 hours; both parties at 72 hours.** The worker receives the route guidance; the poster gets a neutral notice that the route is available. This makes the 72-hour state visible to both.

**Downtime choices**

1. **Coalesce to the latest overdue stage once (recommended).** When the worker returns, recheck server state and deliver only the latest due stage. At 30 hours late, deliver the 24-hour stage; at 80 hours late, deliver the 72-hour stage and skip 24/48 so the user does not receive a burst.
2. **Catch up every overdue stage once, in order.** This preserves every scheduled touch but can deliver a burst after a long outage.
3. **Expire overdue stages after an owner-set grace period.** This avoids stale notices, but requires an additional value and can omit useful guidance.

In every option, a confirmation, cancellation or dispute committed before dispatch suppresses pending work. If the state change races an already-claimed delivery, recheck immediately before the external dispatch; an already-sent message cannot be recalled. The recipient and catch-up decision must be stored under a stable assignment/terms-version/stage key so restart cannot duplicate a stage.

### 2. Whether no-action case closure restarts reminders

Opening a case suppresses the pending sequence. A finalized no-action case restores the assignment's prior valid state; when that state was submitted, a reminder policy is still unresolved.

**Approved:** restart the sequence from no-action finalization only when the restored state is submitted.

1. **Keep reminders suppressed after no action.** Case closure is the only follow-up; parties use the assignment and support routes without another clock.
2. **Start a fresh 24/48/72-hour sequence from no-action finalization (recommended).** Apply only if the restored assignment state is submitted. Use the finalization timestamp and a new case/finalization generation key. Do not run it for an assigned or in-progress state.
3. **Resume only original stages whose due times are still in the future.** Past stages stay suppressed; this preserves original timing but can produce a short or incomplete sequence.

No option authorizes a financial transition. A no-action outcome stays distinct from completion and does not unlock a review unless the assignment independently qualifies as finalized completed work.

### 3. Review text and moderation

The score and one-review-per-direction eligibility are settled. The text bound, content policy, publication timing, reporting access and effect of hidden reviews on public totals are not.

**Approved:** use the bold 500-character, report-driven human moderation recommendation below. A user who can see the review may report it. Only a qualified human moderator may hide it; hiding is audited and never edits or deletes the original.

**Text and publication choices**

1. **Optional text up to 500 characters, published after eligible submission, then human moderation only when reported (recommended).** Prohibit threats/harassment, slurs, private identity/contact/bank information and URLs. Normalize whitespace and reject out-of-bound text at the database command. No automated moderation judgment.
2. **Optional text up to 1,000 characters with the same prohibited categories.** More detail is available, with greater moderation and privacy exposure.
3. **Hold every text review for human approval before publication.** No unreviewed text is public, but reviews may be delayed and staff workload increases.

**Reporting and hiding choices**

1. Any authenticated user who can see a review may report it; a human with a dedicated current moderation capability and AAL2 may hide it after recording a reason. The review author and subject cannot moderate it (recommended).
2. Only the review subject may report it; same moderation controls as above.
3. Reports never hide automatically; every hide is an explicit human decision. Keep review text immutable and preserve an append-only moderation record.

For public averages/counts, choose whether a hidden review (a) is excluded from both score and count, (b) keeps its score in the aggregate but hides its text, or (c) remains counted only as a submitted review. **Recommendation: exclude a hidden review from both public average and count; retain it privately for audit, and keep its one-review slot consumed.** Show null/unrated when no visible qualifying review remains. Do not expose staff notes or reporter identity publicly.

### 4. Metric definitions, periods and denominators

F12 requires server-backed users, funded jobs, assignments, GMV, commission, provider expenses, contribution margin and dispute performance by poster type. Product beta targets add first application, release without dispute, first response, initial decision, final settlement and repeat participation.

**Approved:** use rolling 30-day and pilot-to-date reporting; count funding once and show refunds separately; measure first response from case opening to the first staff update visible to the party; measure initial decision when it is published; report case finalization and refund arrival separately; and define repeat use as participation in at least two different funded jobs among users with at least one qualifying participation in that same 30-day period.

| Measure                     | Approved implementation definition                                                                                                                                                                                                                                               |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Reporting window            | Rolling 30 days plus pilot-to-date. Use server event times; display dates in Africa/Lagos.                                                                                                                                                                                       |
| Poster type                 | Attribute jobs and money measures to the poster type on the funded job.                                                                                                                                                                                                          |
| Users                       | Report currently active verified students/partners separately from new verification approvals in the window.                                                                                                                                                                     |
| Funded jobs / assignments   | Count distinct successfully funded jobs once. Count each accepted assignment separately and report completed/cancelled/unresolved states separately.                                                                                                                             |
| GMV                         | Sum verified gross job collections once; show refunds as a separate measure. Do not add assignment allocation amounts to GMV.                                                                                                                                                    |
| Commission / costs / margin | Use immutable commission postings and recorded provider, refund and delivery expense postings. Contribution margin is commission less those recorded costs. Show unknown or unsettled costs separately until authoritative amounts are recorded.                                 |
| First application           | Measure from when a funded listing becomes discoverable to its first committed application; show jobs with no applications separately.                                                                                                                                           |
| Release without dispute     | Completion-released assignments with no case opened, divided by all completion-released assignments in the period.                                                                                                                                                               |
| First case response         | Case open to first human staff update visible to a party. For the median, show the responded count and total opened cohort; also show unresolved and overdue cases.                                                                                                              |
| Initial decision            | Case open to the first published decision notice. Show decision count, total opened cohort, unresolved count and overdue cases.                                                                                                                                                  |
| Finalization / refund       | Report case finalization time and external refund settlement time separately. A case can finalize without an external settlement.                                                                                                                                                |
| Repeat use                  | In a rolling 30-day window, users with qualifying participation in two or more distinct funded jobs divided by users with at least one qualifying participation. Qualifying participation means poster of a funded job or worker on an accepted assignment, not merely applying. |

### 5. Realtime design for existing connections after permission changes

No Realtime implementation or permission policy exists yet. Supabase currently evaluates channel policies on join and caches them for the connection. Its documentation says that removing a grant can leave an existing connection receiving messages until a new JWT is sent or expires; therefore a join-time RLS check alone cannot prove immediate revocation safety. See [Realtime Authorization](https://supabase.com/docs/guides/realtime/authorization#updating-rls-policies). Supabase recommends Broadcast for scalable, secure database event delivery; see [Subscribing to Database Changes](https://supabase.com/docs/guides/realtime/subscribing-to-database-changes#using-broadcast).

**Approved:** use private Broadcast invalidation topics with authorization generations, rotate generations after a permission change, suppress new delivery to stale topics and recheck authorization for every durable read.

**Recommended design for owner approval**

- Use only private Broadcast topics, with RLS authorization based on current membership/capability, account status, case assignment and the exact topic. Disable public-channel access. Deny all client Broadcast writes; messages and read cursors remain authoritative only through the existing Edge/database commands.
- Make broadcasts server-generated invalidation hints only, such as “thread changed” or “notifications changed.” Do not include a message body, notice row, case narrative, identity evidence, money data or provider reference. Topic membership is not authorization for a follow-up read; every replay/notice/case request rechecks current database permission.
- Give each permission-sensitive topic an authorization generation. Thread access changes rotate its generation; case staff access has its own case/reviewer generation; user notification topics rotate on account-level access changes. After a committed revocation/downgrade, dispatch only to the current generation and never emit new protected hints to the stale topic. A still-connected revoked user may retain data already delivered, but receives no further protected hints on the old generation. This bounds revocation without relying on a cooperative client unsubscribe or JWT expiry.
- The server dispatcher checks current recipient eligibility before sending. Access revocation and generation change are atomic with the business permission change; hint dispatch is after commit. An outbox row with a stale generation is suppressed.
- On connection, subscribe first, buffer hints, fetch durable history after the last saved sequence, then merge and replay by exact decimal-string sequence/message ID. Reconcile the subscribe/replay race and deduplicate overlap. On logout or thread change, remove channels; cleanup is not the authorization mechanism.
- A case reviewer does not join a participant thread. The case route returns only the current scoped case snapshot/detail and its own invalidation topic. Financial inspection grants no case topic access.

This design handles future delivery after a permission change. A still-connected revoked user may retain data already received; the old connection must receive no further protected hints. A short JWT expiry alone is not an immediate revocation design.

**Evidence boundary:** test on the pinned local stack with actual Auth-backed clients and actual sockets. Join-time denial, database-only RLS tests, mocked events, client unsubscribe and API-only reconnect tests are not evidence for already-connected revocation. See the exact boundaries in [Phase 5 evidence](phase-5-evidence.md).

## Destination and delivery contracts for later steps

These are proposed safe response contracts, not existing behavior.

| Destination kind | Target identifier                        | Authorization on open                                                                                                                                    |
| ---------------- | ---------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| application      | application ID                           | Owning poster or that applicant only; the application read checks current identity/capability and poster ownership.                                      |
| thread           | thread ID                                | That application's poster or applicant only, with current thread-read permission. Case staff use the case route instead.                                 |
| assignment       | assignment ID                            | One of the assignment parties; the assignment/status query applies its current participant and suspension rules.                                         |
| case             | case ID                                  | A party to that case, or the currently assigned staff reviewer with active account, current grants and AAL2. Financial inspection alone is insufficient. |
| wallet_item      | A wallet operation/withdrawal identifier | The owning user through their own wallet route. A staff trace uses the separate scoped AAL2 financial-inspection route.                                  |

Never return an arbitrary URL, route, user-supplied path or free-form object key. Keep the notice itself minimal and return only an allow-listed kind plus opaque ID. Clicking it is a fresh read and must be authorized by the destination's owning handler/database command.

Proposed durable outbound delivery state:

1. Persist per-recipient/channel intent atomically with the source event, keyed uniquely by recipient, event, channel and message type.
2. Claim as leased with a random token, expiry and incremented attempt count. Reclaim expired leases; only the current lease token may complete a claim.
3. Classify results as retry-wait, provider-accepted, delivered (only when the provider confirms delivery), permanent failure, unknown (external acceptance is ambiguous), exhausted, or suppressed (for a reminder invalidated by terminal state). A local capture proves capture/acceptance only, not mailbox delivery. Keep in-app notice/read state independent of this state.
4. Use bounded exponential backoff with jitter for known transient failures. Reconcile unknown outcomes before another send; an external provider may still duplicate after an ambiguous timeout. Expose safe failure codes/IDs to ops and keep credentials, OTPs, private case evidence and bank details out of ordinary templates/logs.

The Phase 5 guide already requires leased claims, bounded retry/backoff, expired-lease reclaim, permanent failure and exhausted/unknown visibility. It does not approve numeric retry or lease values. Step 4 should propose local synthetic values and prove them with a fake clock/capture adapter; no live email/SMS sender is part of Phase 5.

## Phase 5 Step 4 delivery implementation — 11 November 2026

- Existing marketplace transitions already create application, acceptance, submission, completion/release, withdrawal and case/appeal notices in their source transaction. Financial withdrawal and refund transitions already use the financial notice helper. The migration adds verification notices from the existing identity outbox and backfills those durable in-app notices without sending historical email.
- Each future eligible notice creates one email intent in the same transaction. Message notices and frequent case updates do not create email. The notice/read record is independent of the delivery row. The read API returns only one of the approved destination kinds and an opaque ID; the destination handler must still authorize each open.
- The delivery table uses a stable delivery ID, a 60-second default lease, five claim attempts, reclaim of expired leases, exponential retry starting at 30 seconds with a one-hour cap and small random jitter. Unknown outcomes are reconciled by lookup after 60 seconds; retry is allowed only after the adapter confirms that stable ID is absent. A local capture is `provider_accepted`, never `delivered`.
- The delivery worker is exercised by a host-side local check and accepts only `@identity.test` recipients and authenticated `127.0.0.1` capture. It does not use Zoho, a real mailbox, SMS, identity evidence, money details, OTPs or live credentials. There is no UI or manual resend endpoint.
- `ops-notification-delivery` pages through only permanent-failure, unknown and exhausted status metadata with a stable timestamp/ID cursor. The database checks a current AAL2 `notification_delivery_review` grant; this grant is distinct from financial inspection. The migration grants it to nobody.
- These retry values govern the local email queue only; notification scheduling and reminder timing continue to have their own approved 24/48/72-hour rules. The local tests use a one-second lease to exercise recovery quickly.
