# No Broke Dayz — Phase 2: identity, verification and protected operations backend

Prepared: 30 October 2026. Application root: `/Users/mac/Desktop/NoBrokeDayz`.

This is an instruction guide for your coding agent, not application code. Complete one step at a time. Review its output before giving the next prompt. Phase 2 is authorized for local development; hosted staging and hosted CI remain deferred/pending as recorded in Phase 1.

## What you are building

A testable backend for email/password accounts, separate institutional-email and phone verification, student/partner approval, safe profiles, private synthetic evidence and staff-controlled verification. Production screens remain postponed while design work proceeds separately.

By the end, test clients should demonstrate that a synthetic verified student qualifies to hire and work, a synthetic verified partner qualifies to hire only, unverified users remain limited to onboarding/support, and suspended accounts lose ordinary capabilities immediately. No actual job, bank action or payment is implemented here; capability tests are not evidence those later features exist.

## Preserve the foundation already built

- Existing application routes are under `app/`; generated database types are at `lib/database.types.ts`. Use `features/verification/`, `features/profiles/` and `lib/` where cohesive modules need them. Do not create a second `src/` application tree or move the existing app for cosmetic consistency with the original target tree.
- Continue the pinned Node/npm/runtime setup and the working native local Supabase scripts. The native stack is experimental; Functions are served separately through the CLI. Extend that working workflow rather than replacing it with Docker or hosted services.
- Keep the original category migration and its 29 permission assertions passing. Add migrations after it; do not rewrite already recorded foundation history to hide new changes.
- `app_private` is not exposed to the Data API and currently grants no usage to ordinary API roles, including `service_role`. Design narrow authorized access deliberately; an administrative SDK client is not automatically entitled to this schema.
- Public categories remain intentionally public reference data. This does not authorize anonymous/unverified job discovery or access to other users' profiles.
- No hosted deployments, paid services, real IDs, real SMS/email delivery, Bachs integration or live money in this phase. Preserve existing launch/provider blockers.

## Step 1 — agree precise identity contracts and limits

**Create/update:** `docs/identity-contracts.md`, `docs/data-and-permissions.md`, `docs/decisions.md`, and a planned command/test map in `docs/phase-2-evidence.md`.

**Prompt**

> Work in /Users/mac/Desktop/NoBrokeDayz. Implement only Phase 2 Step 1: contract planning, not application behaviour. Read AGENTS.md, approved spec.md, canonical F1/F2 requirements, technical identity/security sections and Phase 1 evidence/runbook. Preserve backend-first, local-only delivery and deferred hosted work. Specify identity facts separately: login email ownership, institutional-email ownership, phone ownership, age confirmation, student/partner type, track approval, suspension and staff capability. Describe safe command inputs/outputs, ownership checks and allowed transitions for registration, phone binding, school challenge, manual submission/review/resubmission, profile edits and suspension. Specify which module owns each protected fact. Propose exact configurable field limits, OTP expiry/resend/attempt limits, signed-URL lifetime and accepted file types; distinguish Supabase-enforced settings from our supplementary school challenge. Preserve the source's 5 MB per verification file engineering limit; the five-file cap belongs to disputes and is not automatically a verification-upload limit. Use synthetic .test school domains locally; actual UNILAG domains remain unconfirmed. Describe how existing-account phone verification avoids accidentally creating a second Auth user. Define what contact changes invalidate and how current Auth facts reconcile with protected account status. Present detailed values/matrices for my approval, as required by the accepted Q8 recommendation. Do not implement dependent behaviour until those details are approved; while waiting, finish the test/command map and documentation. Report the small set of decisions I must approve.

**Expect:** one understandable contract, with user-editable versus system-owned fields clearly separated. Proposed security values are not misrepresented as already approved product rules.

**Check:** normal users cannot edit their user type, approval, capabilities or staff grants through profile updates or Auth metadata. Track A and Track B requirements remain different. Age confirmation supports the 18+ policy without claiming verified age from identity checks that have not occurred.

**Debug:** if the agent wants you to choose every internal implementation detail, ask it to recommend sensible values and explain only meaningful tradeoffs. If it invents real school domains or legal retention periods, replace them with explicit live gates. Continue to Step 2 after the affected contract decisions are accepted.

## Step 2 — add protected records, narrow commands and test fixtures

**Create/update:** new timestamped `supabase/migrations/` files; `supabase/tests/database/002_identity_access.test.sql` or equivalent; `scripts/fixtures/` for local synthetic users; generated `lib/database.types.ts`; `docs/data-and-permissions.md`.

**Records to cover:** safe profile fields, protected account status/type, institutional challenges/ownership, versioned manual requests and reviews, private evidence metadata, staff grants and append-only identity audit/events. Add only the minimal event/outbox support needed for committed identity transitions; broader notifications and payment modules come later.

**Prompt**

> Implement only Phase 2 Step 2 against the approved identity contracts. Write failing boundary tests first for client privilege escalation and cross-user access. Add versioned migrations separating public-safe profile responses from private identity/status/evidence/staff records. Link application identity to auth.users.id; use safe idempotent provisioning with no signup bypass of protected fields. Enforce ownership, uniqueness and permitted transitions in database constraints/controlled transactions; never trust editable user metadata for privileges. Keep private schemas unexposed. Provide narrow own-status/profile commands and a restricted server-only identity command path consistent with the approved technical design. Any security-definer helper must use fixed empty search_path, schema-qualified objects and explicit execute grants. Ensure grants for a server executor are actually available without broadening browser roles or assuming service_role already accesses app_private. Derive the actor from verified authentication, never caller JSON. Create synthetic Auth fixtures through supported local Auth/admin tooling, not ad hoc writes to managed Auth tables. Guard fixture creation and staff bootstrapping against hosted targets; keep credentials ignored and logs redacted. Keep the original 29 foundation assertions passing, regenerate client-safe database types, and document all new permissions. Do not create jobs, journals or wallet records.

**Expect:** synthetic accounts start unverified, their ordinary profile fields are editable only through intended paths, and protected records cannot be changed through generic client writes.

**Check:** actual `anon`/`authenticated` client-role tests deny protected writes and unrelated reads. Private schemas stay absent from client-generated types. Review helpers as well as tables for privilege escalation.

**Debug:** if a policy produces recursion, redesign the smallest permission helper and test it rather than granting unrestricted reads. If fixtures fail, confirm local stack identity and use the actual supported Auth API. If an administrator call fails, inspect its deliberate grants instead of exposing the entire private schema.

## Step 3 — prove email/password authentication and recovery

**Create/update:** cohesive auth client/test support under `lib/`; `scripts/check-identity.mjs` and `tests/integration/identity/`; local `supabase/config.toml`; `.env.example`; `docs/runbook.md`.

**Prompt**

> Implement only Phase 2 Step 3: local email/password Auth and identity provisioning through test clients, without production UI. Use a pinned compatible Supabase client where needed; retain one lockfile. Prove signup, login-email confirmation, signin, refresh, signout and password recovery using the local mail viewer/test tooling. Passwords and sessions belong to Supabase Auth, not custom password tables. Registration selects student/partner once through validated onboarding, records age confirmation and creates no marketplace capability until all required checks pass. Handle failed/retried provisioning safely, including attempts to change account type or metadata afterward. Verify access tokens with the supported Auth verification mechanism; decoding a JWT or trusting getSession's returned user alone is insufficient. Use current authoritative account state for authorization and current Auth records where contact/security freshness is required. Test invalid/expired tokens, duplicate signup and safe error messages without account enumeration. Allow-list local recovery redirects and test hostile redirect input. Document Supabase signout/access-token lifetime behaviour accurately rather than claiming every existing access token is instantly invalidated. No verification privilege may appear merely from password recovery. Do not send real email or configure hosted Auth.

**Expect:** a local test client can create and recover a synthetic account while the product still reports unverified/restricted status.

**Check:** email confirmation proves login-email ownership only. Signing in does not approve a student/partner. Recovery does not bypass school, phone or manual review requirements.

**Debug:** missing confirmation/recovery mail should be investigated in the local mail service and redirect settings. Do not turn off confirmation to make a test pass. Distinguish authentication failure from valid login with insufficient product verification.

## Step 4 — bind and verify a phone on the existing account

**Create/update:** `supabase/functions/send-auth-sms/index.ts`; shared hook-validation and delivery adapter modules under `supabase/functions/_shared/`; local hook configuration; phone integration tests and runbook.

**Prompt**

> Implement only Phase 2 Step 4. Add phone binding/verification for the already signed-in email/password account using the supported Supabase update-and-verify flow. Check the pinned/current documentation for the correct phone-change challenge type; do not implement a separate phone signup or custom phone OTP authority. Supabase generates and validates the code; the Send SMS Hook delivers it. Validate the hook's documented authentication/signature with its own secret, normalize Nigerian numbers consistently and test duplicate ownership/race cases. Use a local capture/fake delivery adapter with synthetic numbers only. Prove the supported local hook path if possible; if the native runtime cannot exercise it, record the exact limitation and separate real Auth phone tests from simulated adapter tests. Keep test codes inside local test tooling, never normal logs/responses or a deployable debug endpoint. Enforce approved resend/expiry/attempt limits and safe delivery failure/pending states. Set phone_verified_at or equivalent from authoritative successful confirmation of the current number, never client fields or hook success alone. Phone changes invalidate the old binding until the new number is verified. Do not contact Africa's Talking, incur SMS cost or claim Nigerian network/DND delivery.

**Expect:** verified phone ownership belongs to the same user ID as the email account. It still does not establish school ownership or partner approval.

**Check:** wrong/expired/reused OTPs fail; delivery acceptance alone cannot verify a number. A changed phone cannot inherit the old number's verified status. No leaked general-purpose test verification endpoint exists.

**Debug:** inspect whether the account is in phone-change versus signin flow. Treat unavailable local SMS configuration as an explicit test gap; do not fabricate an Auth success by directly setting a verified field.

## Step 5 — implement separate school-email challenges and automatic Track A qualification

**Create/update:** `features/verification/` contracts if shared; identity command handlers under `supabase/functions/commands/`; supplementary email challenge/delivery support under `_shared/`; `supabase/functions/send-auth-email/` if used for Auth delivery; school verification database/integration tests.

**Prompt**

> Implement only Phase 2 Step 5. Bind a supplementary institutional email to the existing account with a separate one-time challenge; do not replace its personal login email or create another Auth user. Use an explicit synthetic-domain allow-list in local fixtures and validate exact domain matching, normalization and ownership uniqueness. Generate challenges cryptographically, store protected verification digests bound to actor/address/version, enforce approved expiry/attempt/resend limits atomically and consume a successful challenge once. Protect low-entropy code digests against offline guessing with an appropriate server-held secret. A resend must handle prior challenges according to the approved contract. Deliver through local email capture; keep the delivery adapter compatible with the eventual Zoho path, without claiming real Zoho/school-mailbox delivery. Distinguish supplementary school challenge from Supabase login confirmation/recovery and their hook authentication. Do not expose codes through ordinary API responses, logs or browser-readable tables. Only when student track, current school proof or approved ID fallback, current phone proof and age confirmation all pass may a single transaction grant Track A capabilities and record audit/event history. Recheck suspension independently; verification success never unsuspends an account. Test parallel submissions/consumption, wrong-address/account replay and unique ownership conflicts without leaking who owns an address.

**Expect:** a synthetic allow-listed student becomes qualified automatically after all shared checks pass. Pending phone or age requirements keep them restricted. Email possession is presented as the MVP proxy, not proof of full identity/current enrolment.

**Check:** `student.school.test.attacker.test` does not match `school.test`. Race two challenge confirmations and prove one effect. A verified school address on one user cannot silently qualify another.

**Debug:** if every email confirms automatically, inspect test configuration leakage. If state disagrees with Auth contact facts, repair the authoritative synchronization path; do not make the client choose which status to trust.

## Step 6 — add private synthetic-document intake

**Create/update:** private verification bucket configuration/migrations; upload authorization/finalization handlers; restricted evidence metadata; synthetic fixtures under `tests/fixtures/verification/`; storage integration tests; `docs/verification-files.md`.

**Prompt**

> Implement only Phase 2 Step 6. Build a private verification evidence pipeline with synthetic sample images/PDFs only. Use purpose-bound, owner-bound, short-lived upload/download access and explicit Storage policies; table RLS alone does not secure file objects. Validate approved types, actual file signatures, size, key ownership and finalized content hash. Keep uploads quarantined until appropriate safety validation; unvalidated content must not become reviewable or approval evidence. Prevent overwriting finalized evidence with a still-valid upload URL by using immutable/versioned finalized objects or equivalent proven controls. Reject active-content formats, forged MIME types, traversal keys, oversized uploads and cross-user object substitution. Use safe download headers; no arbitrary inline HTML/SVG. A filename extension or hash is not a malware scan. Document exactly which image/PDF checks work locally; if scanner/sanitizer capability is unavailable, keep that input quarantined/rejected and record the real-file gate rather than silently accepting it. Separate avatar derivatives from private identity originals. Retain access logs and clean orphaned uploads without deleting finalized review history. Document that signed URLs are bearer access during their remaining lifetime, with a bounded expiry and tested expiry behaviour. Do not claim immediate revocation of already-issued links unless explicitly implemented/tested. No real IDs or hosted buckets.

**Expect:** the submitting user can safely provide a synthetic file, unrelated users cannot fetch it, and an authorized reviewer can request time-limited access after the file passes applicable checks.

**Check:** public URLs fail; anonymous/unrelated reads and ungranted reviewer reads fail; tampered/unsafe files remain unavailable. Rejection/resubmission does not overwrite old finalized evidence.

**Debug:** if upload succeeds but review fails, check metadata finalization, quarantine status and reviewer authorization separately. Never fix access by making the bucket public or extending every URL indefinitely.

## Step 7 — implement manual student fallback and partner review workflows

**Create/update:** verification submission/review commands, restricted queue/status projections, review-history migrations/tests and identity domain events/audit.

**Prompt**

> Implement only Phase 2 Step 7 against approved transitions. A student without school-email access may submit a private synthetic student-ID fallback for review. A partner submits synthetic legal name, government-ID and accepted campus connection evidence, with phone and age requirements. Accepted connection evidence includes shop/stall photo with location, staff ID or attributable endorsement by an already verified student; a vouch is evidence, never automatic approval. Backend review supports pending, needs-information, rejected and approved status with reasons and preserved submission/review/evidence versions. Define reviewer assignment and current capability checks so unrelated staff cannot inspect the queue's private evidence. Requests must appear in an authorized local queue query within 60 seconds of committed submission; record measured results rather than claiming realtime UI. Approving a fallback/partner submission does not bypass missing phone/age checks. Review rejection/revocation, contradictory duplicate decisions and resubmission are transactional and idempotent; conflicts return a safe stale-state response. Append audit/domain events in the same transaction and preserve an inspectable delivery request for verification-result notices. Full notification product delivery is later; email delivery failure must not undo a committed review or fabricate a notice success. Do not create dispute/financial approvals or production staff screens yet.

**Expect:** a test client can submit, inspect own status, receive needs-information/rejection and resubmit. A granted reviewer can record a reasoned decision; a partner always needs this review.

**Check:** Track A school-email route needs no manual reviewer; fallback does. Partners cannot acquire work capability even after review. A student endorsement cannot approve its recipient. Decision retries do not duplicate events or corrupt history.

**Debug:** if a review says approved but user remains restricted, inspect all prerequisite facts—this can be correct. If resubmission destroys prior evidence, fix versioning before moving on.

## Step 8 — prove staff MFA, grant boundaries and suspension

**Create/update:** restricted staff/suspension commands and tests; safe local staff-bootstrap script; `docs/staff-access.md`; audit access queries.

**Prompt**

> Implement only Phase 2 Step 8. Provide a local-only audited bootstrap for synthetic staff; no client may self-promote. Require both a current explicit capability grant and a verified MFA assurance level for protected staff commands/records. Prove real local Supabase TOTP enrollment/challenge yielding an authenticated AAL2 session, not only fabricated claim tests. Test missing MFA, wrong grant, revoked grant, unrelated review scope and malformed/expired tokens. MFA enrolment/signature alone is not authorization. Use trusted verified actor/session context across Edge and database boundaries; a client-supplied aal, actor ID or staff flag must never work. Define authorized suspension/unsuspension with reason and audit trail. A previously issued token must lose ordinary app capabilities immediately after authoritative suspension or grant revocation is committed. Suspension/changes must not destroy records, grant privileges through recovery, or block the narrow private help route required for unresolved support. Invalidate verification bindings as defined when phone/school identity changes; test backend access using the old token, including direct Data API attempts. Document existing signed-file URL expiry limitations separately. Reserve distinct staff grants for later dispute/money workflows without implementing financial finalization. No hosted staff account or real-person grant changes.

**Expect:** a staff test user at AAL1 is denied; the same appropriately granted user at AAL2 can review authorized submissions. Revocation/suspension takes effect without waiting for a new login token.

**Check:** a forged role in request JSON or user metadata fails. Ordinary authenticated clients cannot call privileged internal functions directly. No service account is counted as a future independent human reviewer.

**Debug:** if MFA-enrolled staff still fail, inspect actual session assurance after completing the challenge. If authorization stays valid after revocation, remove reliance on stale claims/cached capabilities and test current-state checks.

## Step 9 — add safe profile editing and role capability responses

**Create/update:** `features/profiles/`, narrow profile/capability APIs or RPCs, validation tests and the profile section of the data dictionary. Reuse the existing `app/` and `lib/` conventions only where needed; no screens.

**Prompt**

> Implement only Phase 2 Step 9. Support display name, safe photo reference, relevant faculty/campus, bio, skills, simple availability and organisation attribution; partners may expose business name/location. Bound editable inputs by the approved contract. Return a client-safe own-status/capability response and a restricted safe-profile projection for authorized verified viewers, preserving the separate onboarding access of unverified users. Public-safe profile fields do not mean anonymous full-profile discovery is approved. Keep legal identity, phone, bank information, school-email proof and verification files out of shared responses. User type, verified badge, capability, rating/count and completed-work fields are system-owned. Ratings should truthfully show unrated/count zero and completed-work zero until later assignment/review modules exist; users cannot set or invent them. Derive student work/post and partner post-only capabilities from current protected status and suspension. Test mass assignment, overlong fields, cross-user edits, guessed profile IDs and stale-token access. Return stable safe error categories and correlation IDs without SQL or private details. Do not create a fake job endpoint merely to claim marketplace authorization is complete.

**Expect:** users can edit their own ordinary profiles, see clear qualification status and safely inspect allowed profiles. Student/partner capabilities differ, while marketplace features remain unbuilt.

**Check:** generic profile updates cannot grant staff/student approval or change counts. No response accidentally serializes a whole private database row.

**Debug:** if badges disappear after ordinary edits, separate system status from editable profile storage/update paths. If private data leaks through a view, test underlying grants/RLS/view security and response shape together.

## Step 10 — run the complete local acceptance suite and document the milestone

**Create/update:** identity test runner(s), relevant `package.json` check/lint/format scripts, `.github/workflows/ci.yml` configuration, `docs/phase-2-evidence.md`, `docs/phase-2-milestone.md`, `README.md`, `docs/runbook.md`, development/feedback/launch records.

**Prompt**

> Close Phase 2 locally only. Run the existing foundation checks and the new command/database/Auth/Storage identity integration tests with the pinned toolchain. Extend check/lint/format coverage to new features, lib, test and Edge Function files rather than assuming the old app/scripts-only globs cover them; use tooling appropriate to each runtime. Preserve local-only reset safeguards and explicit native-runtime/Functions startup limitations. Configure future CI checks but do not create a remote, push, deploy or claim hosted CI execution. Require the acceptance cases below and show actual results with synthetic actor roles. Prove real Auth session/phone/MFA paths where the local runtime supports them; separate isolated simulations from end-to-end evidence, and record any inability as pending rather than verified. Rebuild from migrations and regenerate types, include a failing-then-fixed permission check, verify cleanup and redact logs. Update docs/phase-2-evidence.md with commands, build/revision, versions, dataset, pass/fail/blocked results and live gates. Prepare docs/phase-2-milestone.md with the role-brief packet below. Do not start jobs, payments or Phase 3 automatically. Report remaining gaps before declaring the local phase verified.

### Required acceptance evidence

| Scenario | Expected observable result |
| --- | --- |
| Anonymous and invalid credentials | No private records/commands; safe auth/help/public taxonomy only. |
| Registered but unverified | Own onboarding/status/profile/help only; no general marketplace or other users' profiles. |
| Student school route | School ownership alone is insufficient; school + current phone + age qualifies without manual approval. |
| Student fallback | Synthetic ID reviewer decision + current phone + age qualifies; complete history retained. |
| Partner route | Always human-reviewed, hire-only capability, even with a student vouch. |
| Challenge attacks | Wrong actor/address/code, expired/reused code, brute-force/resend attempts and concurrent consumption fail safely. |
| Contact change/recovery | No old verification silently attaches to new ownership; recovery never grants extra privileges. |
| Evidence access | Private owner/reviewer scope; expiry, quarantine, size/type and finalized-content immutability are tested. |
| Privilege escalation | Metadata/profile/JSON mass assignment and direct privileged-function calls cannot alter approval, roles or counts. |
| Staff MFA and grants | Real local AAL2 plus current scoped grant required; AAL1, wrong scope/revocation denied. |
| Suspension | Old token loses ordinary capabilities immediately; private help route remains available. |
| Retry/concurrency | Duplicate signup/submission/decision/challenge confirmation produces one valid result and preserved history. |
| Queue and audit | Submission queryable within 60 seconds; decision/access/grant/suspension events attributable and appropriately append-only. |
| Regression | Original 29 assertions, runtime probe, new identity tests, type/lint/format checks all pass. |

Staff financial approvals, full tamper-evident checkpoint exports and future job/payment permission enforcement remain later-phase work. Establish appropriate identity audit records now without claiming all F12 or financial audit requirements complete.

### Documentation and sharing packet

After each major milestone (Auth, school challenge, manual review, staff protection), append a brief evidence note. At phase close, prepare:

- **Safe evidence:** redacted pass/fail summary, or a short synthetic test-client demonstration of unverified → verification → approved status and denial of an unrelated actor. No production screen exists yet; never label this a finished user interface.
- **Plain-language explanation:** what local backend capability works, why students benefit and what is still unbuilt or simulated.
- **Weekly update:** completed, in progress, planned, blocker and one real lesson. Include one or two content opportunities per week, not two posts per test.
- **Possible content:** why confirming a phone differs from confirming student status; why a business account can hire but cannot work.
- **Feedback question:** what should a needs-information or rejection explanation tell someone so they know their next step? Ask only when useful; record actual feedback and product decisions, not invented research results.
- **Review status:** internal draft for Community and Growth review; nothing sent or published by the agent. Do not expose school-domain policies, abuse thresholds, staff details, codes, keys or private documents in public captures.

### What done looks like

All implemented local flows pass the relevant allow/deny and replay/concurrency checks; actual Auth/Storage/MFA evidence is distinguished from adapter simulations; types and setup are reproducible; residual runtime/provider/privacy gates are clear. Nobody claims successful Nigerian delivery, approved real-ID intake, hosted security or a working marketplace from these tests.

If any core local verification path remains blocked, report Phase 2 as partially verified and name the exact missing evidence. Intentionally deferred hosted checks remain a separate tracked debt, as approved; do not provision hosted services just to close them.

Return `docs/phase-2-evidence.md`, `docs/phase-2-milestone.md` and the agent's summary here. We review results before you ask to proceed to Phase 3.

## Official implementation references

Checked 30 October 2026. Recheck behaviour against the pinned local versions; these references do not replace contract approval or actual tests.

- [Verified Auth claims](https://supabase.com/docs/reference/javascript/auth-getclaims) and [server-side identity methods](https://supabase.com/docs/guides/auth/server-side/creating-a-client): verified identity and fresh user lookup have different roles.
- [Phone verification and changes](https://supabase.com/docs/guides/auth/phone-login) and [Send SMS Hook](https://supabase.com/docs/guides/auth/auth-hooks/send-sms-hook): use the existing account and Supabase-generated codes.
- [Auth rate limits](https://supabase.com/docs/guides/auth/rate-limits): platform limits remain relevant alongside application limits.
- [MFA assurance](https://supabase.com/docs/guides/auth/auth-mfa) and [TOTP](https://supabase.com/docs/guides/auth/auth-mfa/totp): prove actual second-factor sessions and enforce staff authorization separately.
- [Edge Function security](https://supabase.com/docs/guides/functions/auth) and [Storage access control](https://supabase.com/docs/guides/storage/security/access-control): apply authentication and object permissions at their actual boundaries.
