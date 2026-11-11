import assert from "node:assert/strict";
import { createHash, generateKeyPairSync } from "node:crypto";
import {
  chmodSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, relative, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import {
  createCheckpoint,
  publicKeyFingerprint,
  signCheckpoint,
  verifyCheckpointAgainstChain,
} from "./audit-checkpoint-core.mjs";
import { localSupabaseEnv } from "./local-supabase-env.mjs";

const root = resolve(import.meta.dirname, "..");
const cli = resolve(root, "node_modules/.bin/supabase");
const env = localSupabaseEnv();

function runCli(args) {
  const result = spawnSync(cli, args, {
    cwd: root,
    env,
    encoding: "utf8",
    maxBuffer: 4 * 1024 * 1024,
  });
  if (result.error || result.status !== 0)
    throw new Error("local_supabase_command_failed");
  return result.stdout.trim();
}

function parseJsonOutput(output) {
  try {
    return JSON.parse(output);
  } catch {
    const lines = output.split("\n").filter(Boolean);
    if (!lines.length) throw new Error("local_supabase_json_missing");
    return lines.map((line) => JSON.parse(line));
  }
}

function findSnapshot(value) {
  if (Array.isArray(value)) {
    for (const item of value) {
      const found = findSnapshot(item);
      if (found) return found;
    }
    return null;
  }
  if (typeof value === "string") {
    try {
      return findSnapshot(JSON.parse(value));
    } catch {
      return null;
    }
  }
  if (!value || typeof value !== "object") return null;
  if (value.snapshot) {
    const found = findSnapshot(value.snapshot);
    if (found) return found;
  }
  if (value.format === "nbd.financial-audit-snapshot.v1") return value;
  for (const child of Object.values(value)) {
    const found = findSnapshot(child);
    if (found) return found;
  }
  return null;
}

function auditSnapshotSql(anchorPosition) {
  let anchorSql;
  if (anchorPosition === "head") {
    anchorSql = `(
      select pg_catalog.jsonb_build_object(
        'position',h.chain_position::text,'event_id',h.event_id::text,
        'event_hash',pg_catalog.encode(h.event_hash,'hex'))
      from app_private.financial_audit_integrity h
      order by h.chain_position desc limit 1
    )`;
  } else if (anchorPosition === null) {
    anchorSql = "null::jsonb";
  } else {
    if (!/^(0|[1-9][0-9]*)$/.test(anchorPosition))
      throw new Error("invalid_checkpoint_position");
    anchorSql = `(
      select pg_catalog.jsonb_build_object(
        'position',h.chain_position::text,'event_id',h.event_id::text,
        'event_hash',pg_catalog.encode(h.event_hash,'hex'))
      from app_private.financial_audit_integrity h
      where h.chain_position=${anchorPosition}::bigint
    )`;
  }
  const headSql = (where = "") => `(
    select pg_catalog.jsonb_build_object(
      'position',h.chain_position::text,'event_id',h.event_id::text,
      'event_hash',pg_catalog.encode(h.event_hash,'hex'),
      'event_count',(select pg_catalog.count(*)::text
        from app_private.financial_audit_integrity prior
        where prior.chain_position<=h.chain_position))
    from app_private.financial_audit_integrity h ${where}
    order by h.chain_position desc limit 1
  )`;

  return `select pg_catalog.jsonb_build_object(
    'format','nbd.financial-audit-snapshot.v1',
    'chain_valid',app_private.financial_audit_integrity_valid(),
    'event_count',(select pg_catalog.count(*)::text from app_private.financial_audit_integrity),
    'head',${headSql()},
    'previous_head',${headSql("where h.chain_position < (select pg_catalog.max(chain_position) from app_private.financial_audit_integrity)")},
    'anchor_head',${anchorSql}
  ) as snapshot`;
}

function querySnapshot(anchorPosition) {
  const output = runCli([
    "db",
    "query",
    "--local",
    "--output-format",
    "json",
    auditSnapshotSql(anchorPosition),
  ]);
  const snapshot = findSnapshot(parseJsonOutput(output));
  if (
    !snapshot ||
    snapshot.format !== "nbd.financial-audit-snapshot.v1" ||
    typeof snapshot.chain_valid !== "boolean" ||
    !/^(0|[1-9][0-9]*)$/.test(snapshot.event_count)
  )
    throw new Error("local_audit_snapshot_invalid");
  return snapshot;
}

function flipHash(hash) {
  if (hash === null) return null;
  return `${hash[0] === "0" ? "1" : "0"}${hash.slice(1)}`;
}

function rollbackSnapshot(snapshot) {
  const previous = snapshot.previous_head;
  return {
    format: snapshot.format,
    chain_valid: true,
    event_count: previous?.event_count ?? "0",
    head: previous
      ? {
          position: previous.position,
          event_id: previous.event_id,
          event_hash: previous.event_hash,
        }
      : null,
    anchor_head: null,
  };
}

function ensureLocalStack() {
  const status = parseJsonOutput(runCli(["status", "--output-format", "json"]));
  const apiUrl = new URL(status.env?.API_URL ?? "http://invalid.test");
  if (
    status.runtime !== "native" ||
    !["127.0.0.1", "localhost"].includes(apiUrl.hostname) ||
    apiUrl.port !== "54321"
  )
    throw new Error("requires_native_loopback_supabase");
}

function ensureOutsideRepository(path) {
  const rel = relative(root, path);
  if (rel === "" || (!rel.startsWith("..") && !rel.startsWith("/")))
    throw new Error("checkpoint_test_output_must_be_outside_repository");
}

function saveSignedCheckpoint(snapshot, privateKey, publicKey) {
  const externalDir = mkdtempSync(join(tmpdir(), "nbd-audit-checkpoint-"));
  ensureOutsideRepository(externalDir);
  const trustDir = join(externalDir, "trust");
  const retainedDir = join(externalDir, "retained");
  mkdirSync(trustDir, { mode: 0o700 });
  mkdirSync(retainedDir, { mode: 0o700 });
  const trustPath = join(trustDir, "trusted-public.pem");
  const retainedPath = join(retainedDir, "retained-checkpoint.json");
  writeFileSync(trustPath, publicKey.export({ type: "spki", format: "pem" }), {
    mode: 0o644,
    flag: "wx",
  });
  chmodSync(trustPath, 0o644);
  const signed = signCheckpoint(createCheckpoint(snapshot), privateKey);
  writeFileSync(retainedPath, `${JSON.stringify(signed, null, 2)}\n`, {
    mode: 0o600,
    flag: "wx",
  });
  chmodSync(retainedPath, 0o600);
  return { directory: externalDir, retainedPath, trustPath, signed };
}

function verifyRetainedCheckpoint(directory, requireAdvance = false) {
  const resolvedDir = resolve(directory);
  ensureOutsideRepository(resolvedDir);
  const retainedPath = join(
    resolvedDir,
    "retained",
    "retained-checkpoint.json",
  );
  const trustPath = join(resolvedDir, "trust", "trusted-public.pem");
  const retained = JSON.parse(readFileSync(retainedPath, "utf8"));
  const trustedPublicKey = readFileSync(trustPath, "utf8");
  const anchorPosition = retained.checkpoint.head?.position ?? null;
  const current = querySnapshot(anchorPosition);
  const result = verifyCheckpointAgainstChain({
    candidate: retained,
    retained,
    current,
    trustedPublicKey,
  });
  if (!result.ok) throw new Error(result.reason);
  const retainedCount = BigInt(retained.checkpoint.event_count);
  const currentCount = BigInt(current.event_count);
  if (requireAdvance && currentCount <= retainedCount)
    throw new Error("later_audit_event_not_observed");
  return { retained, current, advanced: currentCount > retainedCount };
}

function exportCheckpoint(requireEvents) {
  ensureLocalStack();
  const snapshot = querySnapshot("head");
  assert.equal(snapshot.chain_valid, true, "local audit chain must verify");
  if (requireEvents && snapshot.event_count === "0")
    throw new Error("populated_audit_chain_required");
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const saved = saveSignedCheckpoint(snapshot, privateKey, publicKey);
  const checked = verifyRetainedCheckpoint(saved.directory);
  const digest = createHash("sha256")
    .update(readFileSync(saved.retainedPath))
    .digest("hex");
  console.log(
    `AUDIT_CHECKPOINT_RESULT:${JSON.stringify({
      directory: saved.directory,
      event_count: checked.retained.checkpoint.event_count,
      head_position: checked.retained.checkpoint.head?.position ?? "0",
      checkpoint_sha256: digest,
      trusted_key_sha256: publicKeyFingerprint(publicKey),
    })}`,
  );
  console.log(
    `PASS signed checkpoint verified: ${checked.retained.checkpoint.event_count} audit event(s), head position ${checked.retained.checkpoint.head?.position ?? "0"}`,
  );
}

function verifyCommand(directory, requireAdvance) {
  ensureLocalStack();
  const checked = verifyRetainedCheckpoint(directory, requireAdvance);
  const data = {
    retained_event_count: checked.retained.checkpoint.event_count,
    current_event_count: checked.current.event_count,
    retained_head_position: checked.retained.checkpoint.head?.position ?? "0",
    current_head_position: checked.current.head?.position ?? "0",
    later_event_verified: checked.advanced,
  };
  console.log(`AUDIT_CHECKPOINT_VERIFICATION:${JSON.stringify(data)}`);
  console.log(
    requireAdvance
      ? `PASS retained checkpoint remains valid after later event(s): ${data.retained_event_count} -> ${data.current_event_count}`
      : `PASS retained checkpoint matches current audit chain: ${data.current_event_count} event(s)`,
  );
}

function selfTest() {
  ensureLocalStack();
  const initialSnapshot = querySnapshot("head");
  assert.equal(
    initialSnapshot.chain_valid,
    true,
    "local audit chain must verify",
  );

  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const saved = saveSignedCheckpoint(initialSnapshot, privateKey, publicKey);
  const retained = JSON.parse(readFileSync(saved.retainedPath, "utf8"));
  const trustedKey = readFileSync(saved.trustPath, "utf8");
  const currentSnapshot = querySnapshot(
    retained.checkpoint.head?.position ?? null,
  );
  const valid = verifyCheckpointAgainstChain({
    candidate: retained,
    retained,
    current: currentSnapshot,
    trustedPublicKey: trustedKey,
  });
  assert.equal(valid.ok, true, "valid checkpoint must verify");

  const tampered = structuredClone(retained);
  if (tampered.checkpoint.head) {
    tampered.checkpoint.head.event_hash = flipHash(
      tampered.checkpoint.head.event_hash,
    );
  } else {
    tampered.checkpoint.event_count = "1";
  }
  assert.equal(
    verifyCheckpointAgainstChain({
      candidate: tampered,
      retained,
      current: currentSnapshot,
      trustedPublicKey: trustedKey,
    }).reason,
    "checkpoint_signature_invalid",
    "edited checkpoint data must fail its signature",
  );

  const forgedPair = generateKeyPairSync("ed25519");
  const forged = signCheckpoint(retained.checkpoint, forgedPair.privateKey);
  assert.equal(
    verifyCheckpointAgainstChain({
      candidate: forged,
      retained,
      current: currentSnapshot,
      trustedPublicKey: trustedKey,
    }).reason,
    "checkpoint_signature_invalid",
    "signature from an untrusted key must fail",
  );

  const recomputedTamper = structuredClone(currentSnapshot);
  if (recomputedTamper.head) {
    recomputedTamper.head.event_hash = flipHash(
      recomputedTamper.head.event_hash,
    );
    recomputedTamper.anchor_head = structuredClone(recomputedTamper.head);
  } else {
    recomputedTamper.event_count = "1";
    recomputedTamper.head = {
      position: "1",
      event_id: "00000000-0000-0000-0000-000000000001",
      event_hash: "1".repeat(64),
    };
    recomputedTamper.anchor_head = structuredClone(recomputedTamper.head);
  }
  assert.equal(
    verifyCheckpointAgainstChain({
      candidate: retained,
      retained,
      current: recomputedTamper,
      trustedPublicKey: trustedKey,
    }).reason,
    "retained_anchor_mismatch",
    "a recomputed but changed chain head must not match the retained signature",
  );

  let rollback = rollbackSnapshot(initialSnapshot);
  let rollbackRetained = retained;
  let rollbackCandidate = signCheckpoint(
    createCheckpoint(rollback),
    privateKey,
  );
  let rollbackProofSource = "database chain prefix";
  if (!initialSnapshot.head) {
    const retainedHead = {
      position: "2",
      event_id: "00000000-0000-0000-0000-000000000002",
      event_hash: "a".repeat(64),
    };
    const priorHead = {
      position: "1",
      event_id: "00000000-0000-0000-0000-000000000001",
      event_hash: "b".repeat(64),
    };
    const syntheticRetained = signCheckpoint(
      createCheckpoint(
        {
          format: initialSnapshot.format,
          chain_valid: true,
          event_count: "2",
          head: retainedHead,
        },
        "2026-11-09T00:00:00.000Z",
      ),
      privateKey,
    );
    rollback = {
      format: initialSnapshot.format,
      chain_valid: true,
      event_count: "1",
      head: priorHead,
      anchor_head: null,
    };
    rollbackRetained = syntheticRetained;
    rollbackCandidate = signCheckpoint(
      createCheckpoint(rollback, "2026-11-08T00:00:00.000Z"),
      privateKey,
    );
    rollbackProofSource = "two-position synthetic signed-history fixture";
  }
  assert.equal(
    verifyCheckpointAgainstChain({
      candidate: rollbackCandidate,
      retained: rollbackRetained,
      current: rollback,
      trustedPublicKey: trustedKey,
    }).reason,
    "database_rollback_past_checkpoint",
    "an older signed prefix must fail below the retained checkpoint",
  );

  const head = initialSnapshot.head;
  const shortHash = head?.event_hash.slice(0, 12) ?? "empty-chain";
  const fingerprint = publicKeyFingerprint(publicKey).slice(0, 16);
  const evidenceDigest = createHash("sha256")
    .update(readFileSync(saved.retainedPath))
    .digest("hex")
    .slice(0, 16);
  console.log(
    `PASS local financial audit chain: ${initialSnapshot.event_count} event(s), head position ${head?.position ?? "0"}, hash prefix ${shortHash}`,
  );
  console.log(
    "PASS signed checkpoint verified using a separate trusted public-key file",
  );
  console.log(
    "PASS edited checkpoint and untrusted forged signature were rejected",
  );
  console.log(
    "PASS recomputed chain tampering and rollback before retained checkpoint were rejected",
  );
  console.log(`Rollback proof used: ${rollbackProofSource}`);
  console.log(
    `Trust-key fingerprint: ${fingerprint}; checkpoint digest: ${evidenceDigest}`,
  );
  console.log(
    `Retained public trust file and signed checkpoint: ${saved.directory}`,
  );
}

try {
  const [command = "self-test", ...args] = process.argv.slice(2);
  if (command === "self-test") selfTest();
  else if (command === "export")
    exportCheckpoint(args.includes("--require-events"));
  else if (command === "verify") {
    const directory = args.find((arg) => !arg.startsWith("--"));
    if (!directory) throw new Error("checkpoint_directory_required");
    verifyCommand(directory, args.includes("--require-advance"));
  } else {
    throw new Error("invalid_audit_checkpoint_command");
  }
} catch (error) {
  console.error(
    `FAIL audit checkpoint: ${error instanceof Error ? error.message : "checkpoint check failed"}`,
  );
  process.exitCode = 1;
}
