import { readFile } from "node:fs/promises";
import type { RawSentiExport, SentiCheckpoint } from "./contracts.interim.ts";

/**
 * Data ingress adapter. The gateway reads REAL Senti data through the `sl` CLI (which owns auth
 * via `sl auth login`; the gateway never holds raw Senti credentials or a phone-side MCP client).
 *
 * These are the exact, live-verified commands (see CHECKPOINT_ACCESS.md). The skeleton loads from
 * a file so it is testable offline; wiring `execFile("sl", …)` behind the same interface is a
 * mechanical step done under the warden gate (it touches auth + live data).
 */
export const SENTI_READ_COMMANDS = {
  /** Non-mutating RAW source of truth: full transcript + agents + actions + tasks + totals. */
  export: (sid: string) => ["session", "export", sid, "--json"],
  /** Durable, daemon-minted summarized checkpoints (baseline summarySections + grade). */
  checkpointList: (sid: string, limit = 100) => ["session", "checkpoint", "list", sid, "--limit", String(limit), "--json"],
  /** Mint a checkpoint from the next uncheckpointed window (min 20 events). */
  checkpointGenerate: (sid: string) => ["session", "checkpoint", "generate", sid, "--json"],
  /** Lightweight deterministic recap (owners/locks/tasks). */
  recapNow: (sid: string) => ["session", "recap", "now", sid, "--remote", "--json"],
} as const;

export interface SentiSource {
  loadExport(sessionId: string): Promise<RawSentiExport>;
  loadCheckpoints(sessionId: string): Promise<SentiCheckpoint[]>;
}

/** File-backed source for tests/fixtures. Never commit real exports (they hold private transcripts). */
export function fileSource(exportPath: string, checkpointsPath?: string): SentiSource {
  return {
    async loadExport() {
      return JSON.parse(await readFile(exportPath, "utf8")) as RawSentiExport;
    },
    async loadCheckpoints() {
      if (!checkpointsPath) return [];
      const parsed = JSON.parse(await readFile(checkpointsPath, "utf8")) as { checkpoints?: SentiCheckpoint[] };
      return parsed.checkpoints ?? [];
    },
  };
}

/** Parse an already-loaded export object (used by the CLI entry). */
export function parseExport(raw: unknown): RawSentiExport {
  const exp = raw as RawSentiExport;
  if (!exp || typeof exp !== "object" || !Array.isArray(exp.events)) {
    throw new Error("not a Senti export: missing events[]. Produce with `sl session export <SID> --json`.");
  }
  return exp;
}
