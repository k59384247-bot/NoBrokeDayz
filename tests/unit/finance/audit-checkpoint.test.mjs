import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import test from "node:test";
import {
  createCheckpoint,
  signCheckpoint,
  verifyCheckpointAgainstChain,
} from "../../../scripts/audit-checkpoint-core.mjs";

const snapshot = {
  format: "nbd.financial-audit-snapshot.v1",
  chain_valid: true,
  event_count: "2",
  head: {
    position: "2",
    event_id: "00000000-0000-0000-0000-000000000002",
    event_hash: "a".repeat(64),
  },
  anchor_head: {
    position: "2",
    event_id: "00000000-0000-0000-0000-000000000002",
    event_hash: "a".repeat(64),
  },
};

function fixture() {
  const trusted = generateKeyPairSync("ed25519");
  const checkpoint = createCheckpoint(snapshot, "2026-11-09T00:00:00.000Z");
  const retained = signCheckpoint(checkpoint, trusted.privateKey);
  return { trusted, checkpoint, retained };
}

test("a signed local audit checkpoint verifies against the trusted key and chain", () => {
  const { trusted, retained } = fixture();
  assert.deepEqual(
    verifyCheckpointAgainstChain({
      candidate: retained,
      retained,
      current: snapshot,
      trustedPublicKey: trusted.publicKey,
    }),
    { ok: true, reason: "verified" },
  );
});

test("edited checkpoint content fails its original signature", () => {
  const { trusted, retained } = fixture();
  const edited = structuredClone(retained);
  edited.checkpoint.head.event_hash = `${edited.checkpoint.head.event_hash.slice(0, -1)}b`;
  assert.equal(
    verifyCheckpointAgainstChain({
      candidate: edited,
      retained,
      current: snapshot,
      trustedPublicKey: trusted.publicKey,
    }).reason,
    "checkpoint_signature_invalid",
  );
});

test("a signature from another key is not trusted", () => {
  const { trusted, checkpoint, retained } = fixture();
  const attacker = generateKeyPairSync("ed25519");
  assert.equal(
    verifyCheckpointAgainstChain({
      candidate: signCheckpoint(checkpoint, attacker.privateKey),
      retained,
      current: snapshot,
      trustedPublicKey: trusted.publicKey,
    }).reason,
    "checkpoint_signature_invalid",
  );
});

test("a recomputed chain head cannot replace the retained signed anchor", () => {
  const { trusted, retained } = fixture();
  const changed = structuredClone(snapshot);
  changed.head.event_hash = `${changed.head.event_hash.slice(0, -1)}b`;
  changed.anchor_head = structuredClone(changed.head);
  assert.equal(
    verifyCheckpointAgainstChain({
      candidate: retained,
      retained,
      current: changed,
      trustedPublicKey: trusted.publicKey,
    }).reason,
    "retained_anchor_mismatch",
  );
});

test("an older validly signed database prefix fails below the retained checkpoint", () => {
  const { trusted, retained } = fixture();
  const olderSnapshot = {
    ...snapshot,
    event_count: "1",
    head: {
      position: "1",
      event_id: "00000000-0000-0000-0000-000000000001",
      event_hash: "b".repeat(64),
    },
    anchor_head: null,
  };
  const older = signCheckpoint(
    createCheckpoint(olderSnapshot, "2026-11-08T00:00:00.000Z"),
    trusted.privateKey,
  );
  assert.equal(
    verifyCheckpointAgainstChain({
      candidate: older,
      retained,
      current: olderSnapshot,
      trustedPublicKey: trusted.publicKey,
    }).reason,
    "database_rollback_past_checkpoint",
  );
});

test("an invalid database hash chain cannot verify even with a valid signature", () => {
  const { trusted, retained } = fixture();
  assert.equal(
    verifyCheckpointAgainstChain({
      candidate: retained,
      retained,
      current: { ...snapshot, chain_valid: false },
      trustedPublicKey: trusted.publicKey,
    }).reason,
    "database_hash_chain_invalid",
  );
});
