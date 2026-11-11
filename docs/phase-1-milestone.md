# Phase 1 local foundation milestone

**Prepared:** 30 October 2026  
**Status:** Local foundation checks verified; Phase 1 remains incomplete because hosted Step 6 was deferred and hosted CI has not run.

## Milestone note

The project now has a repeatable local development setup, a small Cloudflare Workers-compatible runtime probe, a Supabase database rebuilt from committed migrations, client-role permission tests, generated database types, and automated local checks. The local probe confirms infrastructure behaviour only. People cannot yet post jobs, apply for work, message, receive payment, or submit identity documents in this project.

One obstacle was that Docker Desktop exposed local Supabase listeners on wildcard host addresses despite the loopback-only setup. The project uses Supabase's documented native Apple-silicon runtime instead and serves the local Edge Function with the Supabase CLI. This works locally; the native stack remains experimental, and macOS does not verify Linux-specific CPU-time enforcement.

The Bachs holding/refund questions remain open, including the documented NGN bank-transfer refund gap and one-refund-per-payment constraint. Real-money movement and real identity-document intake remain gated. No hosted deployment, hosted CI run, publication or external communication is claimed.

## Brief weekly update — 30 October 2026

- **Completed:** pinned local toolchain and repeatable runtime/database checks; 29 permission assertions and generated types passed; closeout evidence and runbook updated.
- **Working infrastructure:** local SSR/Workers probe and local Supabase foundation only.
- **Planned product features:** marketplace, accounts/verification, messaging, payment flows and staff operations are not built.
- **Next:** continue local foundation work only when requested. Hosted staging is postponed; hosted CI waits for an authorized remote. Do not start Phase 2 automatically.
- **Blockers/live gates:** no staging target or remote; Bachs holding/refund capability and launch approvals; identity/privacy, operations, recovery, provider delivery and performance evidence.
- **Lesson:** local compatibility and permission checks are useful evidence, but do not prove a hosted deployment or a usable marketplace.

## Content opportunities for review

1. **Why permission checks need both access grants and row rules.** Explain that the local test proved anonymous and signed-in roles can read only enabled public job categories, without exposing user data. Keep the example synthetic and avoid claiming marketplace permissions are built.
2. **A successful payment and a bank refund are different capabilities.** Explain that provider support for collection does not settle refund paths; the Bachs gap is still under review. Do not imply that the product currently takes payments.

These are draft opportunities only. Nothing has been sent or published. A feedback question is not needed for this infrastructure milestone; record actual feedback only if a session occurs.

## Safe capture instructions

- If a screenshot is later requested, capture only the terminal's final pass/fail summary from this repository's local checks, with synthetic data.
- Crop out account dashboards, browser profiles, `.env*` files, local Supabase status output, keys, URLs containing credentials, personal paths if unnecessary, and unrelated terminal history.
- Do not use hosted dashboards as evidence for this milestone. The staging checks are deferred. Do not send or publish screenshots or this packet without a separate instruction and review.
