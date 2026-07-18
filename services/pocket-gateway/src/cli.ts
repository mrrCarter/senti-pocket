/**
 * Runnable pipeline entry.
 *   node --experimental-strip-types src/cli.ts <raw-export.json> [startSeq] [endSeq]
 *
 * Reads a `sl session export … --json` file, runs extract -> summarize -> bundle, prints the
 * PocketBundle and a grounding report, and EXITS NON-ZERO if any cited quote fails verification.
 * That non-zero exit is the P1 grounding gate in miniature.
 */
import { readFile } from "node:fs/promises";
import { parseExport } from "./senti-source.ts";
import { runPipeline } from "./pipeline.ts";
import type { ExtractWindow } from "./extract.ts";

async function main(): Promise<void> {
  const [, , path, startArg, endArg] = process.argv;
  if (!path) {
    console.error("usage: cli.ts <raw-export.json> [startSeq] [endSeq]");
    process.exit(2);
  }
  const window: ExtractWindow = {};
  if (startArg) window.startSequence = Number(startArg);
  if (endArg) window.endSequence = Number(endArg);

  const exp = parseExport(JSON.parse(await readFile(path, "utf8")));
  const { raw, summary, bundle, groundingViolations } = runPipeline(exp, window);

  console.log("── PocketBundle ──────────────────────────────────────────");
  console.log(`bundleId       ${bundle.bundleId}`);
  console.log(`session        ${bundle.sessionId}`);
  console.log(`sourceRange    #${bundle.sourceRange.startSequence}-${bundle.sourceRange.endSequence}`);
  console.log(`participants   ${bundle.participants.join(", ") || "(none)"}`);
  console.log(`grounding      ${summary.grounding}  (summarizer=${summary.summarizerVersion})`);
  console.log(`claims         ${summary.claims.length} FACT (per-agent, evidence-cited)`);
  console.log(`evidence refs  ${bundle.evidence.length} (deduped)`);
  console.log(`signature      ${bundle.signature.alg}:${bundle.signature.value.slice(0, 16)}…`);
  console.log("");
  console.log("── Grounding check ───────────────────────────────────────");
  if (groundingViolations.length === 0) {
    console.log(`PASS: all ${bundle.evidence.length} cited quotes verified against raw events #${raw.startSequence}-${raw.endSequence}`);
  } else {
    console.log(`FAIL: ${groundingViolations.length} grounding violation(s):`);
    for (const v of groundingViolations.slice(0, 20)) console.log(`  - ${v}`);
  }

  if (process.env.POCKET_EMIT_BUNDLE === "1") {
    console.log("\n── bundle.json ───────────────────────────────────────────");
    console.log(JSON.stringify(bundle, null, 2));
  }

  process.exit(groundingViolations.length === 0 ? 0 : 1);
}

main().catch((err: unknown) => {
  console.error("pipeline error:", err instanceof Error ? err.message : err);
  process.exit(2);
});
