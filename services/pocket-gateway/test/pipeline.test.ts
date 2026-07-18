import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { runPipeline } from "../src/pipeline.ts";
import { parseExport } from "../src/senti-source.ts";

const fixturePath = fileURLToPath(new URL("../fixtures/raw_export.sample.json", import.meta.url));
const loadFixture = async () => parseExport(JSON.parse(await readFile(fixturePath, "utf8")));

test("extract drops control events, keeps material messages in-order", async () => {
  const { raw } = runPipeline(await loadFixture());
  assert.equal(raw.events.length, 3, "3 session_message events (agent_join + context_briefing filtered)");
  const seqs = raw.events.map((e) => e.sequenceId);
  assert.deepEqual(seqs, [...seqs].sort((a, b) => a - b), "events sorted by sequence");
  assert.equal(raw.startSequence, 1001);
  assert.equal(raw.endSequence, 1004);
});

test("summary is per-agent and every FACT cites verifiable evidence", async () => {
  const exp = await loadFixture();
  const { summary, groundingViolations } = runPipeline(exp);
  assert.equal(groundingViolations.length, 0, `grounding violations: ${groundingViolations.join("; ")}`);
  assert.ok(summary.claims.every((c) => c.evidence.length >= 1), "every claim cites evidence");
  const agents = new Set(summary.claims.map((c) => c.agentId));
  assert.ok(agents.has("agent-alpha") && agents.has("agent-bravo"), "per-agent attribution preserved");
  assert.equal(summary.grounding, "baseline_unverified", "stub is honest about grounding");
});

test("bundle is deterministic and signed", async () => {
  const exp = await loadFixture();
  const a = runPipeline(exp).bundle;
  const b = runPipeline(exp).bundle;
  assert.equal(a.bundleId, b.bundleId, "same input -> same bundleId");
  assert.match(a.bundleId, /^pb_[0-9a-f]{24}$/);
  assert.equal(a.signature.alg, "sha256-unsigned");
  assert.ok(a.evidence.length >= 3, "evidence union populated");
});

test("tampering with a cited quote is caught by grounding check", async () => {
  const exp = await loadFixture();
  const { summary, raw } = runPipeline(exp);
  // Simulate a hallucinated quote that is not in any raw event.
  summary.claims[0]!.evidence[0]!.quote = "THIS TEXT WAS NEVER SAID BY ANY AGENT";
  const { verifyGrounding } = await import("../src/summarize.ts");
  const violations = verifyGrounding(summary, raw);
  assert.ok(violations.length >= 1, "fabricated quote must fail verification");
});
