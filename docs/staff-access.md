# Local staff access and suspension

Phase 2 Step 8 adds a local-only test path for staff identity. Later Phase 4 steps add local investigation and decision-proposal/approval commands; they do not add a production staff screen, hosted staff team or money-finalization command.

## Local bootstrap

Use Node `22.23.2` from `.nvmrc`. The bootstrap requires a running native Supabase stack whose API is `127.0.0.1:54321` or `localhost:54321`; it refuses other targets. It provisions four fixed `@identity.test` accounts through Supabase's supported local Auth admin API, then provisions each application identity through the account's own authenticated registration command. The fixture user metadata deliberately contains forged `staff` and capability values to ensure they are ignored.

`npm run bootstrap:local-staff` grants only the synthetic reviewer `verification_review`, `identity_suspend`, and `identity_unsuspend`. Grants are inserted through the guarded local database CLI path, attributed to a separate synthetic bootstrap operator, and written to the append-only identity audit stream by a database trigger. The operator is a local fixture only, is not a reviewer and is not an independent human approver. No browser role or Auth metadata can create or change a grant. Grant revocation is also audited.

Auth passwords and local TOTP seeds are kept only in ignored `.supabase-home/step8-staff.json`, created with mode `0600`. Do not copy this file into source control or logs. The local test uses synthetic email accounts only; it sends no email or SMS.

Run the complete local check with:

```sh
npm run check:staff-access
```

The check starts the native local stack, applies migrations without resetting the database, creates and later removes only the marked baseline Auth fixtures used by pgTAP, preserves the synthetic staff accounts and MFA factors for repeat runs, runs database tests, and stops the stack. It does not contact a linked or hosted project.

## Staff authorization

| Capability                     | Purpose                                                                                                          | Required for                                                                                                                                    |
| ------------------------------ | ---------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `verification_review`          | Review identity submissions                                                                                      | Candidate list, assignment, private queue and decisions; AAL2 and current assignment are also checked where required                            |
| `identity_suspend`             | Suspend an account                                                                                               | Reasoned suspension command at AAL2                                                                                                             |
| `identity_unsuspend`           | Restore an account                                                                                               | Reasoned unsuspension command at AAL2; current prerequisites are re-evaluated before any capability is restored                                 |
| `identity_correct_user_type`   | Reserved                                                                                                         | No correction command is implemented here                                                                                                       |
| `identity_staff_admin`         | Reserved                                                                                                         | No grant-management command is implemented here                                                                                                 |
| `dispute_review`               | Review case queue, self-assign or transfer a case, read current case details, investigate and propose a decision | Phase 4 Steps 2, 4 and 5; active account, current grant, AAL2 and current case assignment are rechecked on every protected action               |
| `case_senior_signoff`          | Independently confirm a case non-response assessment and sign off that assessment on a decision version          | Phase 4 Steps 4 and 5; active human account, current grant, AAL2, not a party, and separate from assigned reviewer/proposer                     |
| `financial_approve`            | Propose and independently approve case decision versions                                                         | Phase 4 Step 5; active human account and current grant, AAL2, not a party; two distinct people total and approvals bind to an immutable version |
| `financial_initiate`           | Reserved for manual finalization                                                                                 | No finalization command is implemented                                                                                                          |
| `notification_delivery_review` | Review safe transactional email delivery exceptions                                                              | Phase 5 Step 4 status queue; active account, current grant and AAL2 are rechecked; the migration grants it to nobody                            |

Protected commands require both a valid Auth access token at AAL2 and the relevant current grant for an active staff account. TOTP enrollment by itself has no authority. The Edge handler validates the access token with Auth `/user`; only then does it read the token's assurance claim and derive the actor from the verified Auth user. Its request body rejects actor IDs, AAL, staff flags and unknown fields. The service executor can execute only named public RPCs and has no `app_private` schema access. Those RPCs recheck current account state and grants in the database, so token claims cannot preserve a revoked capability.

Phase 4 Step 2 adds a private case review queue, explicit reviewer assignment, participant-safe timeline reads, and assigned-reviewer detail reads. Step 4 adds scoped investigation: triage, manual contact records, targeted information/evidence requests, fact findings, private notes and non-response assessment. Safety cases are queued first, but categories do not decide money. Contact records always say `simulated_manual_log`; they do not prove that a real contact happened. Two logged no-response attempts across two channels and substantive reasoning are required before assessment. A different, non-party senior with the current `case_senior_signoff` grant and AAL2 must approve that contact snapshot. A new attempt invalidates the snapshot.

Step 5 allows an assigned reviewer to propose full worker award, full poster refund, a split or no action. The proposer must have current `dispute_review` and `financial_approve`, AAL2, active account status and a trusted human principal; the proposer cannot be a party. Proposal creates approval record one. A different qualified human with current `financial_approve` supplies record two. The database treats two grants held by one account as one person. Decision edits create new versions and invalidate old approvals. A separate senior sign-off is required when a decision relies on non-response; it is tied to that exact decision version and excludes the party, assigned reviewer and proposer.

These are local decision records only. Step 5 sends no decision notice, starts no appeal deadline, releases no earnings, creates no refund payable and changes no journal. Participants do not see decision details until Step 6 notification. `financial_inspect` remains read-only. The `staff_principal_kind=human` value is trusted Auth app metadata set by the local test fixture; synthetic fixtures prove authorization checks, not staffed live operations.

Participants can answer only an open request sent to their own role. Active and suspended participants keep that narrow case-support path; suspension does not restore marketplace actions. Participant reads include only their own requests, replies and uploaded file metadata. Staff detail includes the exact accepted terms, only the assigned case's own application conversation through the opening snapshot, investigation records and private notes. Reviewer IDs, private notes, other-party replies and storage details stay out of participant responses. Case and metadata reads are audited separately from byte downloads. Financial inspection does not grant case access.

Case file bytes use a private case-only bucket and do not share identity reviewer grants. The configurable defaults are five case files and 5,000,000 bytes each, separate from identity's three-file limit. Actual uploads remain quarantined because the local project has no safety scanner. Signature/type checks are not a scanner. There is no staff or browser command to mark files safe; only isolated `synthetic_test` fixtures can represent ready evidence in tests. Each download rechecks the current assigned reviewer, AAL2 and case scope. No public file URL is returned.

The existing local staff bootstrap still grants no case or financial capability. Database tests create and roll back synthetic grants; the marketplace Edge journey uses synthetic local accounts and does not create a hosted or persistent reviewer team. Case decisions/approvals have Step 5 local routes; appeals, decision notification, refunds and manual finalization remain unavailable.

The local integration test uses Supabase JS `auth.mfa.enroll`, a real generated TOTP challenge, and `auth.mfa.challengeAndVerify`; it confirms `getAuthenticatorAssuranceLevel().currentLevel === "aal2"`. It separately tests a password-only AAL1 session and a TOTP-verified account with no grant. The test submits a synthetic verification request, assigns it, confirms only assigned submissions appear in that reviewer's detailed queue, records `needs_information`, and verifies that revoking the review grant immediately denies the same still-valid AAL2 token. While the applicant is suspended, it also completes Supabase password recovery through local Mailpit and confirms the new recovery session remains suspended and cannot read the profile.

The native Supabase stack in this repository test is started with Edge Functions excluded. Integration tests execute the same Edge shared handler against real local Auth `/user` and PostgREST RPC boundaries; the Deno Edge server itself is not running in this Step 8 check. The function entrypoint and its narrow server RPC are present, but successful Deno-hosted staff requests remain an explicit runtime verification gap.

## Suspension behavior

The staff command takes a subject, action, 20–500 character reason and idempotency key. It derives the actor and AAL from the verified request, then transactionally updates current status, revokes derived capabilities on suspension, appends suspension history and audit, and stores the idempotent result. Repeated requests return the original result; conflicting reuse returns a safe stale-state response. Unsuspension does not blindly restore capabilities: it reruns current eligibility checks and never restores a stale grant.

RLS checks current account status on every `public.profiles` read and update. The local test keeps the subject's original access token, suspends the account, then confirms direct Data API profile reads and edits return no rows immediately. The subject can still use `get_my_identity_help_context()` for the narrow own-account support route. Unsuspension restores access through the same old token after the authoritative account state changes. Profiles, submissions and evidence history are preserved. Existing phone and institutional-email synchronization invalidates dependent verification capability when those facts change; recovery and Auth metadata cannot unsuspend an account or restore a grant.

## Signed-file links

Suspension, grant revocation and signout do not revoke an already-issued verification download link. A signed link is a bearer credential and remains usable until its existing 10-minute expiry; this limit is separate from immediate database and Data API authorization checks. The test does not claim immediate signed-link revocation.

## Local evidence

`npm run check:staff-access` passed 243 pgTAP assertions (including the original 29 foundation assertions), three handler-boundary tests, and one local Auth/MFA/database integration scenario. The integration proves AAL1 denial, AAL2 with and without grants, assigned review scope, immediate grant revocation, suspension and unsuspension through a still-valid subject token, support access, password recovery without privilege restoration, and natural rejection after the local 60-second access-token expiry. All users and uploaded/test data are synthetic. Hosted Auth, human staff grants, external email, financial decisions, and Deno Edge hosting are not tested.
