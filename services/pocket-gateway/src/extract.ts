import type { RawSentiExport, RawCheckpoint, SentiEvent, SentiAction } from "./contracts.interim.ts";

/** Non-control event types that carry real work content worth summarizing. */
const MATERIAL_EVENTS = new Set(["session_message", "session_reply"]);

export interface ExtractWindow {
  startSequence?: number;
  endSequence?: number;
  materialOnly?: boolean; // default true — drop joins/briefings/control noise
}

/**
 * Project a raw Senti export into a bounded RawCheckpoint for a sequence window.
 * Pure/deterministic. No invention: every event is copied verbatim from the export.
 */
export function extractRawCheckpoint(exp: RawSentiExport, window: ExtractWindow = {}): RawCheckpoint {
  const materialOnly = window.materialOnly !== false;
  const events = (exp.events ?? [])
    .filter((e) => typeof e.sequenceId === "number")
    .filter((e) => (materialOnly ? MATERIAL_EVENTS.has(e.event) : true))
    .filter((e) => inWindow(e.sequenceId, window))
    .sort((a, b) => a.sequenceId - b.sequenceId);

  const start = window.startSequence ?? (events.length ? (events[0] as SentiEvent).sequenceId : 0);
  const end = window.endSequence ?? (events.length ? (events[events.length - 1] as SentiEvent).sequenceId : 0);

  const actions = (exp.actions ?? []).filter(
    (a: SentiAction) => a.targetSequenceId == null || inWindow(a.targetSequenceId, window),
  );

  return {
    sessionId: exp.session?.sessionId ?? "",
    startSequence: start,
    endSequence: end,
    events,
    agents: exp.agents ?? [],
    actions,
    ...(exp.exportedAt ? { sourceExportedAt: exp.exportedAt } : {}),
  };
}

function inWindow(seq: number, w: ExtractWindow): boolean {
  if (w.startSequence != null && seq < w.startSequence) return false;
  if (w.endSequence != null && seq > w.endSequence) return false;
  return true;
}
