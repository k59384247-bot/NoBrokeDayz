import { createHash, sign, verify } from "node:crypto";

export const CHECKPOINT_FORMAT = "nbd.financial-audit-checkpoint.v1";
export const AUDIT_CHAIN = "app_private.financial_audit_integrity";

function sortedJsonValue(value) {
  if (Array.isArray(value)) return value.map(sortedJsonValue);
  if (value && typeof value === "object")
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, sortedJsonValue(value[key])]),
    );
  return value;
}

export function canonicalJson(value) {
  return JSON.stringify(sortedJsonValue(value));
}

export function createCheckpoint(
  snapshot,
  exportedAt = new Date().toISOString(),
) {
  if (!snapshot || snapshot.format !== "nbd.financial-audit-snapshot.v1")
    throw new Error("invalid_audit_snapshot");
  return {
    format: CHECKPOINT_FORMAT,
    chain: AUDIT_CHAIN,
    exported_at: exportedAt,
    chain_valid: snapshot.chain_valid,
    event_count: snapshot.event_count,
    head: snapshot.head,
  };
}

export function signCheckpoint(checkpoint, privateKey) {
  const bytes = Buffer.from(canonicalJson(checkpoint));
  return {
    checkpoint,
    signature_base64: sign(null, bytes, privateKey).toString("base64"),
  };
}

export function publicKeyFingerprint(publicKey) {
  return createHash("sha256")
    .update(publicKey.export({ type: "spki", format: "der" }))
    .digest("hex");
}

function validDecimal(value) {
  return typeof value === "string" && /^(0|[1-9][0-9]*)$/.test(value);
}

function validHead(head) {
  if (head === null) return true;
  return (
    head !== null &&
    typeof head === "object" &&
    validDecimal(head.position) &&
    typeof head.event_id === "string" &&
    /^[0-9a-f-]{36}$/i.test(head.event_id) &&
    typeof head.event_hash === "string" &&
    /^[0-9a-f]{64}$/.test(head.event_hash)
  );
}

function validCheckpoint(checkpoint) {
  return (
    checkpoint?.format === CHECKPOINT_FORMAT &&
    checkpoint.chain === AUDIT_CHAIN &&
    checkpoint.chain_valid === true &&
    validDecimal(checkpoint.event_count) &&
    validHead(checkpoint.head) &&
    (checkpoint.head === null
      ? checkpoint.event_count === "0"
      : BigInt(checkpoint.head.position) > 0n &&
        BigInt(checkpoint.event_count) > 0n)
  );
}

function signedByTrustedKey(signedCheckpoint, trustedPublicKey) {
  if (
    !signedCheckpoint ||
    typeof signedCheckpoint.signature_base64 !== "string" ||
    !validCheckpoint(signedCheckpoint.checkpoint)
  )
    return false;
  try {
    return verify(
      null,
      Buffer.from(canonicalJson(signedCheckpoint.checkpoint)),
      trustedPublicKey,
      Buffer.from(signedCheckpoint.signature_base64, "base64"),
    );
  } catch {
    return false;
  }
}

function sameHead(left, right) {
  if (left === null || right === null) return left === right;
  return (
    left.position === right.position &&
    left.event_id === right.event_id &&
    left.event_hash === right.event_hash
  );
}

export function verifyCheckpointAgainstChain({
  candidate,
  retained,
  current,
  trustedPublicKey,
}) {
  if (!signedByTrustedKey(candidate, trustedPublicKey))
    return { ok: false, reason: "checkpoint_signature_invalid" };
  if (!signedByTrustedKey(retained, trustedPublicKey))
    return { ok: false, reason: "retained_checkpoint_signature_invalid" };
  if (!validCheckpoint(retained.checkpoint))
    return { ok: false, reason: "retained_checkpoint_invalid" };
  if (
    !current ||
    current.format !== "nbd.financial-audit-snapshot.v1" ||
    current.chain_valid !== true ||
    !validDecimal(current.event_count) ||
    !validHead(current.head)
  )
    return { ok: false, reason: "database_hash_chain_invalid" };

  const retainedHead = retained.checkpoint.head;
  const retainedPosition = retainedHead ? BigInt(retainedHead.position) : 0n;
  const currentPosition = current.head ? BigInt(current.head.position) : 0n;
  const candidatePosition = candidate.checkpoint.head
    ? BigInt(candidate.checkpoint.head.position)
    : 0n;

  if (currentPosition < retainedPosition)
    return { ok: false, reason: "database_rollback_past_checkpoint" };
  if (candidatePosition < retainedPosition)
    return { ok: false, reason: "checkpoint_precedes_retained" };
  if (!sameHead(current.anchor_head, retainedHead))
    return { ok: false, reason: "retained_anchor_mismatch" };
  if (
    currentPosition === retainedPosition &&
    current.event_count !== retained.checkpoint.event_count
  )
    return { ok: false, reason: "retained_anchor_mismatch" };
  if (
    candidatePosition === currentPosition &&
    (!sameHead(candidate.checkpoint.head, current.head) ||
      candidate.checkpoint.event_count !== current.event_count)
  )
    return { ok: false, reason: "checkpoint_head_mismatch" };
  return { ok: true, reason: "verified" };
}
