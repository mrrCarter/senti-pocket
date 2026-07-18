import type { CheckpointSummary, PocketBundle, EvidenceRef, Signature } from "./contracts.interim.ts";
import { sha256Hex } from "./hash.ts";

const BUILDER_VERSION = "relay-bundle-0";

/**
 * Build the bounded PocketBundle the phone caches. Deterministic: same summary -> same bundleId.
 * Signature is INTERIM (sha256 integrity digest, alg="sha256-unsigned"). P3 replaces with an
 * ed25519 detached signature over the canonical bundle so ReceiptVerifier can validate offline.
 */
export function buildPocketBundle(summary: CheckpointSummary, participants: string[]): PocketBundle {
  const evidence = dedupeEvidence(collectEvidence(summary));
  const core = {
    sessionId: summary.sessionId,
    sourceRange: { startSequence: summary.startSequence, endSequence: summary.endSequence },
    summary,
    evidence,
    risks: summary.risks,
    blockers: summary.blockers,
    participants: [...new Set(participants)].sort(),
    builderVersion: BUILDER_VERSION,
  };
  const bundleId = `pb_${sha256Hex(core).slice(0, 24)}`;
  const signature: Signature = { alg: "sha256-unsigned", value: sha256Hex({ bundleId, ...core }) };
  return { bundleId, ...core, builtAt: new Date().toISOString(), signature };
}

function collectEvidence(summary: CheckpointSummary): EvidenceRef[] {
  const all: EvidenceRef[] = [];
  for (const c of [...summary.claims, ...summary.risks, ...summary.blockers, ...summary.nextSteps]) {
    all.push(...c.evidence);
  }
  for (const d of summary.disagreements) for (const p of d.positions) all.push(...p.evidence);
  return all;
}

function dedupeEvidence(refs: EvidenceRef[]): EvidenceRef[] {
  const seen = new Map<string, EvidenceRef>();
  for (const r of refs) {
    const key = `${r.sequenceId}:${r.quote}`;
    if (!seen.has(key)) seen.set(key, r);
  }
  return [...seen.values()].sort((a, b) => a.sequenceId - b.sequenceId);
}
