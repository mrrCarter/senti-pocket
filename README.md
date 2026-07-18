# Senti Pocket

**Your agents work while you are gone — you answer the call.**

A native iPhone app that turns a Senti **checkpoint** into a signed, evidence-backed voice briefing you can interrupt, question, and act on by voice — with every write governed, confirmed, and receipted back into the original Senti thread. Offline-first: briefing + Q&A work in airplane mode after sync; writes queue as `PENDING_CONNECTIVITY` and are never faked.

Sunday hackathon build. Four-agent swarm coordinated in the Senti room **`senti pocket mobile app`** (SID `6cf7e861-546a-4b9f-b937-39182a5bd395`).

## The demo loop
Senti checkpoint → bounded signed **PocketBundle** → phone caches it → "Senti is calling" → spoken briefing → interrupt + ask (answered from cached evidence) → dictate a decision → typed **ActionProposal** + read-back → **explicit confirm** → posts via existing Senti MCP/API into the original checkpoint thread → real sequence + signed **DecisionReceipt**.

## The differentiator — checkpoints
The unit of work is the checkpoint, not a chat message. Two-stage, grounded:
`RawCheckpoint` (actual events, no invention) → `CheckpointSummary` (per-agent, FACT vs INFERENCE vs RECOMMENDATION, preserves disagreement) → `PocketBundle` (summary + bounded EvidenceRefs + risks + blockers + source sequence range + signature). Every briefing claim must cite exact evidence; raw→summary ships with a hallucination/grounding eval.

## Voice
Pluggable `SpeechSynthesizer`:
- **Online premium:** ElevenLabs streaming — ultra-fast (sub-second first-audio target), sidecar agents tone-tag each utterance (Ornella pattern, `Consulting/fencesngatesnextjs/apps/voice-agent`).
- **Offline fallback:** `AVSpeechSynthesizer` so airplane mode still speaks.

## Locked tech baseline
SwiftUI · Gemma 4 E2B Instruct via LiteRT-LM (GPU) · whisper.cpp `base.en` · SQLite/FTS5 retrieval · deterministic VAD for barge-in. See `docs/FIRST_SENTI_MESSAGE_POCKET.md` (the pinned, independently-audited baseline) and `docs/LESSONS.md` (per-message room protocol).

## Team & ownership
See `OWNERSHIP.md`. Every agent has a soul in `agents/<id>.soul.md` — read yours + the pinned baseline before touching code.

## Governance
`claude-warden` gates every integration: audit vs `SWE_excellence_framework` + a security scan (confirmation-bypass, replay/stale confirm, wrong-session write, prompt/tool injection from checkpoint content, offline false-success, secret leakage). Nothing merges to the demo branch without a warden +1 **and** a second distinct-role sign-off — CI/billing being down does not lower the bar.

## Node note
The CLI needs Node 22 (`~/AppData/Roaming/nvm/v22.15.0/node.exe`). Default `node` is v26 = unsupported and crashes the CLI.
