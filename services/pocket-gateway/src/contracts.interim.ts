/**
 * INTERIM contracts for the Pocket gateway pipeline.
 *
 * SOURCE OF TRUTH ORDER:
 *   1. `RawSentiExport` / `SentiEvent` / `SentiCheckpoint` below mirror REAL, live-verified
 *      Senti CLI output (see CHECKPOINT_ACCESS.md). These are FACTS, not guesses.
 *   2. `RawCheckpoint`, `CheckpointSummary`, `EvidenceRef`, `PocketBundle` are Atlas's FROZEN
 *      contracts (`packages/PocketContracts` v0.1). The definitions here are INTERIM and MUST be
 *      replaced by an import of Atlas's types at freeze. They are intentionally shaped to match
 *      the pinned baseline (summary + bounded EvidenceRefs + risks + blockers + source range +
 *      signature) so alignment is a re-type, not a redesign. DO NOT diverge from Atlas's fixture.
 *
 * Erasable-syntax only (runs under `node --experimental-strip-types`): no enums/namespaces.
 */

/* ───────────────────────── Real Senti shapes (verified live) ───────────────────────── */

export interface SentiAgent {
  agentId?: string;
  id?: string;
  model?: string;
  displayName?: string;
  provider?: string;
  clientKind?: string;
  role?: string;
}

export interface SentiEvent {
  stream: string;
  event: string; // session_message | session_reply | agent_join | context_briefing | session_action | ...
  agent: SentiAgent;
  payload: {
    to?: string[];
    channel?: string;
    message?: string;
    mentions?: unknown[];
    firstMessage?: boolean;
    targetSequenceId?: number;
    actionType?: string;
    [k: string]: unknown;
  };
  sessionId: string;
  idempotencyToken?: string;
  cursor: string; // "0000000230731:0003854b"
  sequenceId: number; // GLOBAL canonical sequence
  ts: string;
  timestamp?: string;
}

export interface SentiAction {
  id: string;
  sessionId: string;
  targetSequenceId: number | null;
  targetCursor: string | null;
  targetActionId: string | null;
  actionType: string; // reply | ack | like | dislike | working_on | disregard | view
  actorId: string;
  actorRole?: string;
  note?: string;
  idempotencyKey: string;
  createdAt: string;
}

export interface SentiCheckpointSections {
  workCompleted?: string[];
  agentContributions?: Array<{ agentId: string; summary: string }>;
  evidence?: Array<{ label?: string; value?: string }>;
  risks?: string[];
  nextSteps?: string[];
}

export interface SentiCheckpoint {
  checkpointId: string;
  kind: string;
  title: string;
  summary: string;
  createdByAgentId?: string;
  startSequence: number;
  endSequence: number;
  tokenRange?: { start: number | null; end: number | null } | null;
  grade?: string;
  gradeScore?: number;
  gradeReasons?: Array<{ message?: string; code?: string }>;
  summarySections?: SentiCheckpointSections;
  cursor?: string;
  createdAt?: string;
}

/** Full `sl session export <SID> --json` payload (top-level keys verified live). */
export interface RawSentiExport {
  command?: string;
  exportedAt?: string;
  session: { sessionId: string; title?: string; [k: string]: unknown };
  agents: SentiAgent[];
  participants: SentiAgent[];
  actions: SentiAction[];
  actionProjection?: unknown;
  actionEvents?: unknown[];
  events: SentiEvent[];
  tasks: unknown[];
  counts?: Record<string, number>;
  totals?: Record<string, number | null | string[]>;
}

/* ───────────────────────── Pocket contracts (INTERIM — align to PocketContracts v0.1) ───────────────────────── */

/** A claim's provenance. `quote` MUST be substring-verifiable in events[sequenceId].payload.message. */
export interface EvidenceRef {
  sequenceId: number;
  cursor: string;
  quote: string;
  agentId?: string;
}

/** FACT = observed in the transcript. INFERENCE = derived. RECOMMENDATION = proposed action. */
export type ClaimKind = "FACT" | "INFERENCE" | "RECOMMENDATION";

export interface GroundedClaim {
  kind: ClaimKind;
  text: string;
  evidence: EvidenceRef[]; // >=1 for FACT; INFERENCE/RECOMMENDATION cite the facts they rest on
  agentId?: string; // which agent asserted it (per-agent attribution, preserved)
}

/** Two agents disagreeing must NOT be flattened into one consensus line. */
export interface Disagreement {
  topic: string;
  positions: Array<{ agentId: string; stance: string; evidence: EvidenceRef[] }>;
}

/** RAW checkpoint = the exact events/agents/actions in a sequence window. No invention. */
export interface RawCheckpoint {
  sessionId: string;
  startSequence: number;
  endSequence: number;
  events: SentiEvent[];
  agents: SentiAgent[];
  actions: SentiAction[];
  sourceExportedAt?: string;
}

export type SummaryGrounding = "grounded" | "baseline_unverified";

/** Bounded, per-agent, grounded projection of a RawCheckpoint. */
export interface CheckpointSummary {
  sessionId: string;
  startSequence: number;
  endSequence: number;
  grounding: SummaryGrounding; // "baseline_unverified" until the real summarizer verifies every quote
  claims: GroundedClaim[];
  disagreements: Disagreement[];
  risks: GroundedClaim[];
  blockers: GroundedClaim[];
  nextSteps: GroundedClaim[];
  summarizerVersion: string;
}

/** What the phone caches and briefs from. */
export interface PocketBundle {
  bundleId: string; // stable hash of (sessionId, range, summary)
  sessionId: string;
  sourceRange: { startSequence: number; endSequence: number };
  summary: CheckpointSummary;
  evidence: EvidenceRef[]; // bounded, de-duplicated union of all cited evidence
  risks: GroundedClaim[];
  blockers: GroundedClaim[];
  participants: string[]; // agentIds
  builtAt: string;
  builderVersion: string;
  signature: Signature; // integrity of the bundle (see DESIGN.md)
}

export interface Signature {
  alg: string; // interim: "sha256-unsigned"; P3: ed25519 detached signature over canonical JSON
  value: string;
  keyId?: string;
}
