// routing-worker — the "who-hears-what" core of the Gemma routing worker.
//
// Per docs/CALL_ME_AND_VOICE_CONTRACT.md §2 and bundle's requirement: the routing POLICY
// is DATA in, not code, so bundle's B3 receipt layer bolts on cleanly. This module is the
// pure decision function: given one transcribed turn + a RoutingPolicy, decide which agents
// hear it and whether they get the full text or a summary. That is the token/inference-
// efficiency lever — only the matched slice reaches an agent's expensive model.
//
// This is the DECISION core only. The Gemma model integration (VAD → diarize → transcribe)
// produces the `input` this consumes; the media plane (Cloudflare Realtime SFU) carries the
// audio. Both are out of scope here — this stays a pure, deterministic, testable function.
//
// Types (JSDoc, not enforced — policy is data):
//   RoutingInput  { roomId, speaker:{id,kind}, ts, transcript, addressedTo?:string[], topic?, floorState? }
//   RoutingPolicy { version?, members:[{id,kind?,lanes?:string[],hearMode:'all'|'addressed'|'lane-match'|'none'}],
//                   floor?:{mode,graceMs}, transcribe?:{...},
//                   route?:{rules?:[{when:{addressedTo?:true,laneMatch?:string,topic?:string}, to:string[], as?:'text'|'summary'}]},
//                   budget?:{maxTokensPerTurnPerAgent?, summarizeOverChars?} }
//   RoutingDecision { turnId, transcript, policyVersion, policyHash,
//                     deliveries:[{to, payload:'text'|'summary', reason}], dropped:[{to, reason}] }

import { createHash } from "node:crypto";

/** Deterministic canonical JSON (sorted keys) so policyHash is stable across key order. */
function canonical(value) {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  const keys = Object.keys(value).sort();
  return `{${keys.map((k) => `${JSON.stringify(k)}:${canonical(value[k])}`).join(",")}}`;
}

/** sha256 of the canonical policy — pins WHICH policy produced a decision (AMEND-3). */
export function policyHash(policy) {
  return createHash("sha256").update(canonical(policy ?? {}), "utf8").digest("hex");
}

function asArray(v) {
  return Array.isArray(v) ? v : [];
}

/**
 * Base hearing decision from a member's hearMode. Returns { hears, reason }.
 * `none` is a HARD mute — route rules cannot override it (opt-out wins, fail-quiet).
 */
function baseHears(member, input) {
  const addressedTo = asArray(input.addressedTo);
  switch (member.hearMode) {
    case "all":
      return { hears: true, reason: "all" };
    case "none":
      return { hears: false, reason: "hearMode:none" };
    case "addressed":
      return addressedTo.includes(member.id)
        ? { hears: true, reason: "addressed" }
        : { hears: false, reason: "not-addressed" };
    case "lane-match": {
      if (input.topic && asArray(member.lanes).includes(input.topic)) return { hears: true, reason: "lane" };
      if (addressedTo.includes(member.id)) return { hears: true, reason: "addressed" };
      return { hears: false, reason: "no-lane-match" };
    }
    default:
      // Unknown hearMode fails quiet — never blast an agent by default.
      return { hears: false, reason: "unknown-hearmode" };
  }
}

/** Does a route rule FIRE for this turn? (turn-level match, independent of any member.) */
function ruleFires(rule, input) {
  const when = rule?.when || {};
  if (when.addressedTo === true && asArray(input.addressedTo).length > 0) return true;
  if (when.topic && input.topic === when.topic) return true;
  if (when.laneMatch && input.topic === when.laneMatch) return true;
  return false;
}

/**
 * Evaluate one turn against a policy. Pure + deterministic.
 * @param {object} input   RoutingInput
 * @param {object} policy  RoutingPolicy
 * @param {{now?:()=>number, hash?:string}} [deps]
 * @returns {object} RoutingDecision
 */
export function evaluateRouting(input, policy, deps = {}) {
  if (!input || typeof input !== "object") throw new Error("routing: input required");
  if (!policy || typeof policy !== "object") throw new Error("routing: policy required");
  const members = asArray(policy.members);
  const speakerId = input.speaker?.id;
  const transcript = typeof input.transcript === "string" ? input.transcript : "";
  const summarizeOver = Number(policy.budget?.summarizeOverChars) || Infinity;
  const rules = asArray(policy.route?.rules);
  const hash = deps.hash || policyHash(policy);
  const now = deps.now || (() => Date.now());
  const turnId = input.turnId || `turn-${now().toString(36)}`;

  // Members a fired rule wants to reach, with an optional forced payload.
  const ruleTargets = new Map(); // id -> { as?:'text'|'summary' }
  for (const rule of rules) {
    if (!ruleFires(rule, input)) continue;
    for (const to of asArray(rule.to)) {
      const prev = ruleTargets.get(to) || {};
      // If any firing rule forces 'text', that wins (least-lossy).
      if (rule.as === "text" || prev.as === "text") prev.as = "text";
      else if (rule.as) prev.as = rule.as;
      ruleTargets.set(to, prev);
    }
  }

  const deliveries = [];
  const dropped = [];

  for (const member of members) {
    if (!member || !member.id) continue;
    if (member.id === speakerId) continue; // never echo the speaker to itself

    const base = baseHears(member, input);
    const ruleHit = ruleTargets.has(member.id);

    // Hard mute cannot be overridden by a rule.
    if (member.hearMode === "none") {
      dropped.push({ to: member.id, reason: "hearMode:none" });
      continue;
    }

    if (!base.hears && !ruleHit) {
      dropped.push({ to: member.id, reason: base.reason });
      continue;
    }

    const reason = base.hears ? base.reason : "rule";
    // Payload: a firing rule's forced payload wins; otherwise summarize long turns to save tokens.
    const forced = ruleTargets.get(member.id)?.as;
    const payload = forced || (transcript.length > summarizeOver ? "summary" : "text");
    deliveries.push({ to: member.id, payload, reason });
  }

  return {
    turnId,
    transcript,
    policyVersion: String(policy.version ?? "1"),
    policyHash: hash,
    deliveries,
    dropped,
  };
}
