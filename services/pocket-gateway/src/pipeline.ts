import type { RawSentiExport, RawCheckpoint, CheckpointSummary, PocketBundle } from "./contracts.interim.ts";
import { extractRawCheckpoint, type ExtractWindow } from "./extract.ts";
import { summarizeCheckpoint, verifyGrounding } from "./summarize.ts";
import { buildPocketBundle } from "./bundle.ts";

export interface PipelineResult {
  raw: RawCheckpoint;
  summary: CheckpointSummary;
  bundle: PocketBundle;
  groundingViolations: string[]; // empty => every cited quote verified against the raw transcript
}

/**
 * The gateway pipeline: RAW export -> bounded RawCheckpoint -> grounded CheckpointSummary ->
 * signed PocketBundle. Deterministic and side-effect free (no network, no writeback).
 */
export function runPipeline(exp: RawSentiExport, window: ExtractWindow = {}): PipelineResult {
  const raw = extractRawCheckpoint(exp, window);
  const summary = summarizeCheckpoint(raw);
  const groundingViolations = verifyGrounding(summary, raw);
  const participants = (raw.agents ?? [])
    .map((a) => a.id ?? a.agentId ?? "")
    .filter((id): id is string => Boolean(id));
  const bundle = buildPocketBundle(summary, participants);
  return { raw, summary, bundle, groundingViolations };
}
