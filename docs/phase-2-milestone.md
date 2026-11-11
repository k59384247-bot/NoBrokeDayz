# Phase 2 milestone — internal review draft

**Status:** Partially verified locally as of 3 November 2026. Internal review only; nothing has been sent or published.

## Plain-language summary

The local backend keeps student and partner accounts restricted until their required checks pass. Phone confirmation shows control of a phone; it does not prove student status. A school-email challenge is only an MVP school-proof proxy for synthetic `.test` addresses. Partners can qualify to post work, not take student work. Staff actions require a current grant and a real second-factor session. Review files remain private and quarantined because there is no working scanner and sanitizer.

The complete updated `npm run check:phase2` suite passed locally on 3 November. The Deno Edge server accepts a real authorized reviewer request and denies invalid tokens, missing MFA, unrelated users and revoked grants. A synthetic submission appeared in the authorized reviewer candidate list in **74 ms** and in the assigned queue in **150 ms** during this run; both were inside the 60-second target. The approved limit of five wrong phone codes per challenge is still not enforced by Supabase's supported phone-change flow, so Phase 2 is not fully verified.

## What passed locally

- Deno `2.1.4` is pinned in the npm lockfile; all eight Edge entrypoints pass `npm run typecheck:edge`.
- Actual requests through the local API gateway reached Deno Edge handlers. Invalid token returned 401; insufficient MFA, unrelated identity and revoked grant returned 403; a granted TOTP/AAL2 reviewer received an authorized queue response.
- Real local Supabase Auth `phone_change` tests passed for wrong, reused and expired codes, same-account binding, duplicate/racing ownership, resend spacing, replacement invalidation and failed delivery.
- Durable phone send caps passed in concurrent signed-hook tests: five sends accepted and the sixth denied. Native Auth called the local Node hook in the real `phone_change` flow; the Deno `send-sms` route passed with synthetic Auth-signed hook events. This does not prove hosted Auth-to-Deno hook delivery.
- A fresh local reset applied all 22 migrations, passed 319 pgTAP assertions and four registration tests, matched regenerated public types, removed temporary Auth fixtures and stopped the stack.
- The full wrapper completed every configured local check together, including final cleanup. Hosted CI was not run.
- Checks used synthetic actors, `.test` school addresses, synthetic phone values and generated sample files. No hosted services, real SMS/email, real identity files or human staff accounts were used.

## Remaining gates

| Status       | Item                                                | Evidence or next requirement                                                                                                                                                                                                                                                                                                                                                             |
| ------------ | --------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Blocked      | Five invalid phone-change codes per challenge       | Supabase's `/auth/v1/verify` limit is IP-scoped, and its MFA Verification Hook does not cover `phone_change`. Keep this rule as a launch blocker until a supported phone-change attempt control exists, or design and prove an Auth gateway that sees every attempt, forwards OTP validation to Supabase Auth, and prevents direct bypass. No replacement OTP authority was implemented. |
| Blocked      | Evidence review promotion                           | There is no local malware scanner, PDF sanitizer or image decode/re-encode validation. Evidence stays quarantined; synthetic metadata tests do not prove a real file is safe.                                                                                                                                                                                                            |
| Deferred     | Hosted Auth, Storage, Edge, CI and operational load | No remote is configured and no hosted check was run. The 74/150 ms queue timing is one synthetic local sample, not a hosted or load-test guarantee.                                                                                                                                                                                                                                      |
| Deferred     | Real school, email and SMS services                 | Actual UNILAG domains and mailbox ownership remain unconfirmed; Zoho and carrier delivery are not configured or tested.                                                                                                                                                                                                                                                                  |
| Out of scope | UI, jobs, payments, Phase 3                         | Not started. No financial or marketplace capability is claimed by these checks.                                                                                                                                                                                                                                                                                                          |

The local native Supabase stack does not expose its Functions worker directly on its advertised port `8081`; those requests were refused. The successful tests use the API gateway on loopback port `54321`, which routes to a separately served Deno process. Hosted Edge behavior remains deferred.

## Internal weekly update draft

- **Completed:** Local Auth and identity checks, durable phone send caps, actual local Deno Edge authorization, a measured queue visibility sample, and a 22-migration/319-assertion rebuild.
- **Still open:** Supabase-supported enforcement for five failed phone-change codes per challenge and a scanner/sanitizer path before any evidence can be reviewed.
- **Not done:** Hosted deployment or CI, real contact delivery, production UI, jobs, payments or Phase 3.

## Review and sharing limits

- Audience: internal Community and Growth review only.
- No message, post, email or public demo has been sent or published.
- Use the redacted results in [Phase 2 evidence](phase-2-evidence.md); there is no production UI to demonstrate.
- Do not share staff identities, grants, OTPs, keys, private documents or unredacted local logs.
- Phase 1 hosted staging remains deferred. This milestone does not authorize hosted deployment or changes.
