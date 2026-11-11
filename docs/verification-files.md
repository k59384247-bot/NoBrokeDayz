# Private verification file pipeline — Phase 2 Step 6

## Scope and current state

This is a local-only pipeline for synthetic test files. It does not accept real identity documents or use a hosted Storage bucket. The fixtures in `tests/fixtures/verification/` contain no personal data.

Users can request a five-minute upload ticket for one position on their own pending verification submission. The server checks ownership, creates a random object key, and returns a one-use token bound to the signed-in Auth user and that upload intent. The file bytes go through the `verification-evidence` Edge Function; browsers have no direct access to either evidence bucket. The server stores the bytes in `verification-quarantine` with overwrite disabled, reads them back, checks their size/type/signature, and records the SHA-256 digest in the private evidence row.

The `verification-quarantine` and `verification-private` buckets are both private. A restrictive `storage.objects` policy blocks `anon` and `authenticated` roles from reading, listing, uploading, changing or deleting objects in either bucket. This protects the file objects themselves; private evidence-table permissions do not replace these Storage policies. A separate avatar-derivative bucket is not created by this step. Never place identity originals in a profile-photo path.

## Accepted input and what local checks prove

The limit is **5,000,000 bytes per file**. At most three files attach to one verification submission, using evidence positions 1–3. Accepted declared and detected types are `image/jpeg`, `image/png` and `application/pdf`. SVG, HTML, archives, office files and other active-content formats are rejected.

The upload handler checks the actual body length, exact declared MIME type, and format markers. It checks PNG signature/chunk boundaries, JPEG start/end markers, and PDF header/EOF markers. It rejects common raw PDF active-content markers such as JavaScript, launch actions, embedded files and automatic actions. It reads the stored object again and hashes those stored bytes. It rejects traversal or caller-selected object keys because the database creates the key from the authenticated user, submission and evidence IDs.

The local pipeline has no malware scanner, PDF sanitizer, image decoder or safe re-encoder. The PDF marker check cannot find active content hidden in compressed or encoded structures. A signature and a hash prove format hints and byte integrity only; they do not prove a file is safe. Therefore **all successfully uploaded files stay in `quarantined` state and are not reviewable**. No command in this step can mark them ready. Add and verify a scanner/sanitizer before any evidence can move to `verification-private` or become reviewable. The real-file intake gate remains closed.

The committed PNG is a generated one-pixel image. The PDF is synthetic, contains no personal data and passes local `pdfinfo` structure inspection. Those inspections validate only the fixtures; the upload service does not invoke `pdfinfo` or any scanner.

## Upload and download access

The upload ticket is a bearer secret with a five-minute expiry, bound to the owner, pending submission, evidence position, expected MIME type and expected byte count. It is returned once, stored only as a SHA-256 token digest, and consumed atomically. An Auth session is also required. A retry after consumption fails; a new intent uses a different server-generated object key. Failed or mismatched uploads are rejected and cannot become evidence.

The upload endpoint is server-mediated. This avoids exposing a long-lived Storage signed upload token: the pinned Supabase client documentation currently says signed upload URLs work without further authentication for two hours. [Supabase `createSignedUploadUrl`](https://supabase.com/docs/reference/javascript/storage-from-createsigneduploadurl)

The reviewer command can create an **approved 10-minute application-signed download link** only when the current Auth token has verified `aal2`, the account is active, a current `verification_review` grant exists, and the evidence row is `ready`. A random local HMAC secret signs a token containing only the generated private object key, its allowed MIME type and its issue/expiry times. The link reaches the Edge Function, which reads the private object using its server-only Storage credential and returns it as an attachment with `nosniff`, sandbox CSP, no-store and frame-denial headers. It does not expose a Supabase Storage signed URL. The application link is a bearer credential: anyone who receives it can use it until expiry. Changing a database grant or signing out does not revoke an already-issued link; immediate revocation is not claimed. [Private bucket access](https://supabase.com/docs/guides/storage/buckets/fundamentals)

The local Storage test uploads to the actual local private bucket, retrieves the bytes through the application-signed proxy, checks safe headers and confirms the link fails after its approved 10-minute expiry using an injected test clock. This proves local proxy expiry, not immediate revocation. A future scanner must promote safe bytes to a new unique key in `verification-private`; it must never overwrite a finalized object. The client roles cannot write to either bucket, and the server uses insert-only upload (`upsert: false`).

## Private records and cleanup

`app_private.verification_upload_intents` stores one-use token digests and upload state. `app_private.verification_evidence` stores the object key, private bucket, actual type, byte count, content hash and quarantine state. `app_private.verification_file_access_events` is append-only and records intent issue/claim, rejection, quarantine finalization, allowed/denied reviewer-link requests, each successful proxied download and hashed object-key references for orphan cleanup. These tables are absent from client types and cannot be read directly by browser roles or `service_role`.

Run `npm run cleanup:verification-orphans` only while this repository's local native stack is running. It selects only unreferenced quarantine objects older than 24 hours, checks their generated key shape, excludes any evidence row and any live/finalized intent, then deletes the remaining objects. It does not delete metadata, finalized evidence, or objects from the private bucket. The 24-hour threshold is an operational orphan-cleanup delay, not an identity-document retention period. No legal retention period is set here.

## Verification

`npm run check:verification-files` starts the local stack, applies pending migrations without resetting the database, creates supported synthetic Auth fixtures, runs pgTAP, command boundary tests and local Auth/Storage integration tests, cleans its fixtures, and stops the stack. It preserves unrelated local records. It proves that public URLs, anonymous reads, owner direct reads, unrelated reads and direct browser writes fail; valid synthetic upload requests stay quarantined; token substitution fails; unsafe signatures/MIME and oversize requests fail; reviewer access without AAL2/current grant fails in database tests; and the application-signed download proxy returns safe headers and rejects expired links. The integration adapter simulates reviewer AAL2/current grant only to exercise byte proxying; it is not evidence of a real staff login or grant. Deno gateway routing is separately smoke-tested; successful authenticated function operations remain unproved.

The shared Edge handler and Storage service are exercised under Node against local Auth and Storage. The native CLI reports the Edge Runtime listener on port 8081, but that port is not host-reachable in this setup; function requests must go through the local Supabase API gateway on port 54321. Reproduction confirmed POST without a bearer returns the handler's 401 `authentication_required`, and GET with an invalid signed token returns its 403 `download_unavailable`. This proves Deno Edge HTTP routing and handler execution, but not a successful Auth-backed upload or reviewer download through Deno. No hosted bucket, real school file, real ID, real mail or hosted reviewer account is used.
