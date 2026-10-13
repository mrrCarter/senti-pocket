# Jev assessment seam for Pocket

This change adds an **opt-in**, provider-independent evaluation step to existing gateway `/answer` and `/brief`
drafting. It does not implement or assume a private Jev network protocol. A local function, local process, or
reviewed hosted adapter can implement `assessReasoning`; no API key is required for the hermetic tests.

## Roles and limits

Gemma drafts human-readable text. Jev can assess whether each segment is supported by its cited excerpts and
whether the deploy-owned required sources were covered. Deterministic code checks citation membership,
required-source coverage, the exact text spoken/displayed, response structure, and context/draft hashes.

`evaluated` means **model-assessed support**, not independently verified truth. Input must be a structurally valid
signed `PocketBundle`; direct adapter callers must verify it against their trusted key before use. The wrapper binds
the full signature canonical hash, contracts version, sequence range, key identity, signature and creation time into
the assessment context. This binding is not itself trust-anchor verification. A real citation may describe an
agent's report without establishing its truth: "agent reports deployment" must not become "deployment proven."
No evaluator can infer missing room history, unobserved agent actions, actual deployment, or complete semantic
coverage from an excerpt budget. The returned coverage is evidence counts, not a percentage of all work completed.
Jev scores are uncalibrated provider ratings until measured on labeled, held-out examples. Missing draft-model
confidence remains `null` with `confidenceProvenance: unavailable` at `/answer`; a supplied finite rating is explicitly
marked `model-self-reported-uncalibrated`, never replaced by an invented 1.0.

This wrapper has **no dial, tool, merge, or governed-write capability**. An accepted briefing does not authorize an
action, alter the ring threshold, or substitute for the owner's exact read-back and explicit confirmation. Changing
an action/question after approval still requires a new proposal and confirmation in the existing write pipeline.

## Wiring

Existing `createProdGateway(env, deps)` accepts the following new optional, deploy-owned dependencies:

```js
createProdGateway(env, {
  ...productionDeps,
  // reason/brief can be the existing Gemma functions or another reviewed drafting backend.
  assessReasoning: async ({ context, candidate, contextHash, candidateHash, signal }) => {
    // Pass these bounded inputs to your reviewed Jev adapter. Honor signal for cancellation.
    // Return the model's actual verdicts; never hard-code "supported" in a live adapter.
    return jevAdapter.assess({ context, candidate, contextHash, candidateHash, signal });
  },
  // The resolver is configured by operators; HTTP callers/model text cannot choose the requirement set.
  requiredReasoningEvidenceFor: ({ mode, sessionId, checkpointId, question }) =>
    criticalEvidencePolicy.forCheckpoint({ mode, sessionId, checkpointId, question }),
  reasoningAssessmentPolicy: { maxAttempts: 2, timeoutMs: 10000, maxEvidence: 24, minSupportScore: 0.8 },
});
```

Both existing Gemma paths receive only the selected citation IDs in their prompt. Drafting and assessment share one
projection of at most 24 excerpts and 280 Unicode code points per excerpt, including the same agent/sequence/time.
Truncation is reported per excerpt and as `coverage.truncatedEvidence`; truncated or omitted text is not reviewed.
The wrapper snapshots/freeze-binds
the request, selects required evidence before optional evidence, and passes only safe policy feedback on a retry.
`maxEvidence` is capped at 24 in composition and the wrapper so the assessor cannot see a larger context than Gemma.
Required sources that exceed the budget are rejected rather than
silently dropped. The default requirement set is empty; production must explicitly define critical-source policy.
This seam does not yet derive that policy from raw room semantics or enlarge the signed bundle's evidence selection.

### Local adapter interface

`context` includes mode, session/checkpoint identity, question, signed-bundle binding, the shared selected evidence
projection (ID, sequence, agent, timestamp, snippet, truncation metadata), and required IDs. `candidate` is the complete
array of segments that would be displayed and spoken. Both are immutable. Required-source coverage counts cited
selected IDs; it does not prove every assertion in the full original source was covered.

```json
{
  "contextHash": "<echo exact request SHA-256>",
  "candidateHash": "<echo exact request SHA-256>",
  "verdicts": [
    { "index": 0, "support": "supported", "supportScore": 0.9 }
  ]
}
```

Every segment requires exactly one verdict. Allowed support values are `supported`, `unsupported`, `inconclusive`.
Missing/duplicate indices, invalid/low scores, unknown citations, missing required citations, different spoken text,
or stale hashes prevent the candidate from being returned. Provider explanations are not injected into prompts.
The hashes bind the evaluation to inputs, including signed-bundle identity; they are not an attestation of evaluator
identity or a signed flight record.

`/answer` and `/brief` retain their previous shapes and add optional `assessment` metadata when the wrapper is
configured. Status is `evaluated`, `inconclusive`, or `unavailable`, with a reason and evidence counts. If absent,
assessment was **not evaluated**; do not display absence as a pass. This new metadata is not part of the existing
signed `PocketBundle`. If it is persisted as a flight record later, authenticate the worker and sign a distinct
versioned receipt binding model/adapter version, these hashes, policy version, and timestamp.

## Failure, offline and phone behavior

Default is two draft/evaluation attempts, with one total ten-second caller budget (configurable, capped at three
attempts and sixty seconds). Abort is signaled to adapters. JavaScript cannot kill a non-cooperative adapter; use
process isolation or a reviewed transport that honors abort to enforce compute/resource limits.

An outage/timeout/rejection returns no generated prose, plus honest metadata. Existing iOS on-device Gemma is a
separate `GemmaReasoningProvider` and remains unchanged. To use assessment offline, implement the same bounded
contract locally in Swift and validate it on a Mac/physical phone. A cloud-only Jev cannot evaluate while offline.
If local assessment is unavailable, offer cached signature-verified source excerpts labeled **unassessed source
reports**, or the existing deterministic briefing; do not silently mark a model draft evaluated or permit writes.
Remote messages, sync, cloud receipts, and remote call delivery inherently need connectivity; local dictation,
cached reading/Q&A/TTS and an explicit pending outbox can work offline. This patch does not change the mobile UI to
display these metadata or implement the offline fallback; those are separately owned Swift follow-ups.

The signed checkpoint currently chooses up to five spread excerpts per agent. The existing baseline's `fact` claims
are quotes of messages, which are reports rather than proof of external outcomes. A critical-evidence selector must
run **before** summarization/signing to preserve decisions, contradictions, owner requests and later corrections.
Do not have Gemma or Jev claim it covered messages absent from that signed bundle. Maintain source-range/gap counters.

Urgency should be a separate policy over a typed need (human decision, deadline, risk), evidence, freshness, duplicate
suppression, membership and an atomic ring budget. Keep semantic support scores separate from need-classification
confidence, uncertainty and severity. The existing best-effort `ring-owner` limit remains unchanged and requires its
own atomic/store-outage overhaul. Assessment success never rings the phone by itself.

## Validation and remaining work

Hermetic tests cover valid citations with unsupported prose, forged citations, omitted required evidence, stale
hashes, per-segment assessment coverage, alternate spoken words, immutable context, response bounds, outages/timeouts,
and prompt selection/feedback. None proves a real Jev/Gemma model's accuracy or production notification delivery.

Before activation: measure unsupported-claim escape rate, false rejection and critical-evidence omission on labeled
room transcripts; hold out rooms/agents; include later corrections and source-vs-production distinctions; compare
Gemma alone, Jev alone, and the combined pipeline. Calibrate escalation thresholds per decision type. Retain the
candidate/verdict evidence with access control; sensitive room excerpts must not be sent to a third party by default.

Swift follow-ups: assessment metadata display; local evaluator parity; source-quote fallback; signed model/bundle
manifest and two resource-capped local agents using one shared verified model/runtime; serialized generation under
memory/thermal budget; no background daemon guarantee; durable cache/outbox/auth-change cleanup; offline device tests.

Notification follow-ups: ordinary alert categories + bundled distinctive sound and time-sensitive interruption
policy with user authorization; actual conversational calls through CallKit/PushKit only if they meet platform
requirements; physical-device locked/background tests; respect Focus/mute rather than promise guaranteed ringing.
Current `SentiCallKit.swift` has no custom `ringtoneSound`, and the inspected tree has no normal
`UNUserNotificationCenter` notification-category implementation. Provider credentials/entitlements/Registry V2
activation and APNs/device proof are still independent release gates. A source-only read does not establish delivery.
