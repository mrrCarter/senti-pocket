import { test } from "node:test";
import assert from "node:assert/strict";

import { evaluateRouting, policyHash } from "./routing-worker.mjs";

const speaker = { id: "human-carter", kind: "human" };
function input(over = {}) {
  return { roomId: "r1", speaker, ts: "2026-09-01T00:00:00Z", transcript: "ship the deploy", ...over };
}

test("hearMode:all delivers to every non-speaker member; speaker never echoes", () => {
  const policy = { members: [
    { id: "human-carter", hearMode: "all" },
    { id: "claude-forge", hearMode: "all" },
    { id: "claude-warden", hearMode: "all" },
  ] };
  const d = evaluateRouting(input(), policy);
  const to = d.deliveries.map((x) => x.to).sort();
  assert.deepEqual(to, ["claude-forge", "claude-warden"]);
  assert.equal(d.deliveries.every((x) => x.reason === "all"), true);
});

test("hearMode:none is a hard mute — a firing rule cannot override it", () => {
  const policy = {
    members: [{ id: "claude-forge", hearMode: "none" }],
    route: { rules: [{ when: { addressedTo: true }, to: ["claude-forge"], as: "text" }] },
  };
  const d = evaluateRouting(input({ addressedTo: ["claude-forge"] }), policy);
  assert.equal(d.deliveries.length, 0);
  assert.deepEqual(d.dropped, [{ to: "claude-forge", reason: "hearMode:none" }]);
});

test("hearMode:addressed only hears when in addressedTo", () => {
  const policy = { members: [
    { id: "claude-forge", hearMode: "addressed" },
    { id: "claude-warden", hearMode: "addressed" },
  ] };
  const d = evaluateRouting(input({ addressedTo: ["claude-forge"] }), policy);
  assert.deepEqual(d.deliveries.map((x) => x.to), ["claude-forge"]);
  assert.deepEqual(d.dropped, [{ to: "claude-warden", reason: "not-addressed" }]);
});

test("hearMode:lane-match hears on topic∈lanes or when addressed", () => {
  const policy = { members: [
    { id: "claude-forge", hearMode: "lane-match", lanes: ["voice", "ios"] },
    { id: "respawn-machine", hearMode: "lane-match", lanes: ["infra"] },
    { id: "claude-warden", hearMode: "lane-match", lanes: ["security"] },
  ] };
  const d = evaluateRouting(input({ topic: "voice", addressedTo: ["claude-warden"] }), policy);
  const byId = Object.fromEntries(d.deliveries.map((x) => [x.to, x.reason]));
  assert.equal(byId["claude-forge"], "lane");     // topic in lanes
  assert.equal(byId["claude-warden"], "addressed"); // not the lane, but addressed
  assert.deepEqual(d.dropped, [{ to: "respawn-machine", reason: "no-lane-match" }]);
});

test("route rule fires on topic and adds a delivery with reason 'rule'", () => {
  const policy = {
    members: [{ id: "claude-forge", hearMode: "addressed" }],
    route: { rules: [{ when: { topic: "standup" }, to: ["claude-forge"], as: "summary" }] },
  };
  // not addressed, but the standup rule fires:
  const d = evaluateRouting(input({ topic: "standup" }), policy);
  assert.deepEqual(d.deliveries, [{ to: "claude-forge", payload: "summary", reason: "rule" }]);
});

test("budget: long transcript summarizes; short stays text; a rule forcing text overrides", () => {
  const long = "x".repeat(50);
  const policyAll = { members: [{ id: "a", hearMode: "all" }], budget: { summarizeOverChars: 10 } };
  assert.equal(evaluateRouting(input({ transcript: long }), policyAll).deliveries[0].payload, "summary");
  assert.equal(evaluateRouting(input({ transcript: "hi" }), policyAll).deliveries[0].payload, "text");

  const policyForceText = {
    members: [{ id: "a", hearMode: "all" }],
    budget: { summarizeOverChars: 10 },
    route: { rules: [{ when: { addressedTo: true }, to: ["a"], as: "text" }] },
  };
  const d = evaluateRouting(input({ transcript: long, addressedTo: ["a"] }), policyForceText);
  assert.equal(d.deliveries[0].payload, "text"); // forced text beats summarize-by-budget
});

test("unknown hearMode fails quiet (dropped, never blasted)", () => {
  const policy = { members: [{ id: "a", hearMode: "whoknows" }] };
  const d = evaluateRouting(input(), policy);
  assert.equal(d.deliveries.length, 0);
  assert.deepEqual(d.dropped, [{ to: "a", reason: "unknown-hearmode" }]);
});

test("decision carries policyVersion + a stable policyHash (AMEND-3)", () => {
  const p1 = { version: "3", members: [{ id: "a", hearMode: "all" }], budget: { summarizeOverChars: 100 } };
  const p2 = { budget: { summarizeOverChars: 100 }, members: [{ id: "a", hearMode: "all" }], version: "3" }; // reordered keys
  const d = evaluateRouting(input(), p1);
  assert.equal(d.policyVersion, "3");
  assert.match(d.policyHash, /^[0-9a-f]{64}$/);
  assert.equal(policyHash(p1), policyHash(p2)); // key-order independent
  assert.equal(d.policyHash, policyHash(p1));
});

test("validates its input", () => {
  assert.throws(() => evaluateRouting(null, { members: [{ id: "a", hearMode: "all" }] }), /input required/);
});

test("refuses an absent or empty policy rather than pinning nothing (bundle #156)", () => {
  // evaluateRouting refuses missing / non-object / empty-members policies:
  assert.throws(() => evaluateRouting(input(), null), /valid policy with at least one member/);
  assert.throws(() => evaluateRouting(input(), {}), /valid policy with at least one member/);
  assert.throws(() => evaluateRouting(input(), { members: [] }), /valid policy with at least one member/);
  // policyHash never silently hashes {} for a missing/empty policy:
  assert.throws(() => policyHash(undefined), /valid policy/);
  assert.throws(() => policyHash({}), /valid policy/);
  assert.throws(() => policyHash({ members: [] }), /valid policy/);
});
