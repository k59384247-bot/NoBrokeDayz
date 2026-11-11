# No Broke Dayz

Mobile-first UNILAG micro-jobs product. The approved plan and product/technical baselines are documented here. Phases 1–3 have local implementation evidence; hosted readiness, production UI and live money movement remain gated.

## Phase 1 status

Local foundation checks are verified. Phase 1 is **not complete**: hosted Step 6 staging checks are deferred by the user's decision, and hosted CI is pending because no Git remote is configured. No hosted services were provisioned or changed. These are backend foundation checks, not marketplace features. Real-money movement and real identity-document intake remain gated.

## Phase 2 status

Steps 1–9 have local synthetic evidence: protected identity commands, local email/password Auth, same-account phone verification, supplementary school challenge, quarantined evidence, manual review, real local TOTP/AAL2 staff checks, suspension, and safe profile/capability responses. The updated `npm run check:phase2` suite passed locally end-to-end on 3 November, including actual Deno Edge HTTP authorization and queue timing. Phase 2 remains partially verified because the approved phone wrong-attempt limit and file scanning remain gates. Actual UNILAG domains, real email/SMS delivery, malware scanning and real identity-file intake remain unconfirmed or gated. See [`docs/phase-2-evidence.md`](docs/phase-2-evidence.md), [`docs/identity-contracts.md`](docs/identity-contracts.md), [`docs/verification-files.md`](docs/verification-files.md) and [`docs/phase-2-milestone.md`](docs/phase-2-milestone.md).

## Phase 3 status

The local synthetic backend journey for job funding, discovery, applications, assignment work, poster confirmation, wallet reads and manual simulated withdrawals passed the full `npm run check:phase3` run on 4 November. This is local simulator evidence; it is not a real payment, Bachs integration, production UI or hosted launch. Draft editing has database command coverage; application rejection and withdrawal have database/shared-handler coverage. None has a direct Edge HTTP journey in the final acceptance runner, so these command boundaries remain partially verified. Full refunds, splits, appeals and independent financial decisions are not implemented. See [`docs/phase-3-evidence.md`](docs/phase-3-evidence.md), [`docs/phase-3-milestone.md`](docs/phase-3-milestone.md) and [`docs/runbook.md`](docs/runbook.md).

## Local setup and checks

Use Node `v22.23.2` (`.nvmrc`) and npm `10.9.8` (`packageManager`):

```sh
source ~/.nvm/nvm.sh
nvm use
node --version
npm --version
npm ci
npm run format:check
npm run typecheck
npm run typecheck:edge
npm run lint
npm run check:phase2
npm run check:phase3
npm run cleanup:verification-orphans
```

Expected versions are Node `v22.23.2`, npm `10.9.8` and Deno `2.1.4` (pinned through the single npm lockfile). `npm run check:phase2` runs format, lint, Workers and Edge type/build/runtime checks, identity command-boundary tests, local Auth, phone, school-email, Storage, profile/staff tests, actual local Deno Edge HTTP authorization and queue timing, then finishes with a clean migration rebuild and permission/type check. It resets this project's local database in the documented identity, school and final cleanup paths; do not run it when you need to preserve local test data. The phone stage takes about five minutes plus startup because it waits for Supabase's real OTP expiry. The command redacts test output and refuses another Node/npm version. It does not contact hosted services. `npm run cleanup:verification-orphans` is an explicit local-only command for stale, unreferenced quarantine objects.

To start interactive local development:

```sh
npm run dev
npm run supabase:start
npm run supabase:status
```

Run `npm run supabase:functions` in a second terminal for the JWT-protected runtime probe, or `npm run supabase:functions:identity` to serve the Auth-validated local registration handler. Stop that process with Ctrl-C, then run `npm run supabase:stop`. Normal shutdown retains local data. The native Supabase runtime is experimental; it is used because Docker Desktop did not honor the project's loopback-only port binding. Do not expose local services or connect real provider bindings.

The GitHub Actions workflow defines future checks without production secrets. Hosted CI has not run and no Git remote is configured. See [`docs/runbook.md`](docs/runbook.md), [`docs/environments.md`](docs/environments.md), and `.env.example` for setup and environment boundaries.

## Canonical references

- [`spec.md`](spec.md) — approved plan and gates.
- [`docs/product.md`](docs/product.md) — transcription of the supplied v2 Product Requirements PDF.
- [`docs/technical.md`](docs/technical.md) — transcription of the supplied v2 Technical Specification PDF.
- [`docs/bachs-payments-reference.md`](docs/bachs-payments-reference.md) — newer provider evidence, separate from the source baseline.
- [`docs/phase-1-backend-foundation-guide.md`](docs/phase-1-backend-foundation-guide.md) — phased workflow.
- [`docs/runtime-compatibility.md`](docs/runtime-compatibility.md) — tested versions, runtime evidence and limitations.
- [`docs/phase-1-evidence.md`](docs/phase-1-evidence.md) — step statuses, exact local results and deferred hosted checks.
- [`docs/phase-1-milestone.md`](docs/phase-1-milestone.md) — internal milestone and unpublished weekly update.
- [`docs/identity-contracts.md`](docs/identity-contracts.md) — approved identity facts, limits and command boundaries.
- [`docs/verification-files.md`](docs/verification-files.md) — private synthetic file pipeline, quarantine and live safety gate.
- [`docs/phase-2-evidence.md`](docs/phase-2-evidence.md) — local Phase 2 results, evidence limits and remaining gates.
- [`docs/phase-3-evidence.md`](docs/phase-3-evidence.md) — local Phase 3 command/test evidence and boundaries.
- [`docs/phase-3-milestone.md`](docs/phase-3-milestone.md) — internal Phase 3 closeout and unpublished weekly packet.
