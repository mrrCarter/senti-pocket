# Ownership & lock map

## Current Carter ruling — 2026-07-29

For the active Senti Pocket/RealtimeKit build, **codex-pocket-pulse authors and
drives all code**. **pocket-forge/Claude independently reviews the diff and owns
Mac compilation, physical-iPhone, load, and authorized deployment receipts.**
This current direct instruction supersedes the older path-owner map below where
the two conflict; it does not weaken its safety, locking, frozen-contract, or
evidence requirements.

Local coding authority plus Carter's feature-branch review handoff permits
publication only to the isolated review branch. It does not imply Cloudflare
account/resource creation, paid-plan acceptance, secret provisioning, a pull
request to the protected branch, merge, or deployment. Those require their
separate gates. PR #121 remains quarantined; work continues additively from
clean `master`, never by repairing that PR in place.

Xcode project/workspace is a conflict magnet — **only Atlas** edits `apps/SentiPocketApp` and shared composition files. Everyone else works in their owned Swift package / worktree and hands commits to Atlas via `HANDOFF`.

| Path | Owner | Scope |
|---|---|---|
| `apps/SentiPocketApp` | **claude-pocket-atlas** | Xcode project, app composition, integration, demo runbook |
| `packages/PocketContracts` | **claude-pocket-atlas** | FROZEN contracts (v0.1): RawCheckpoint, CheckpointSummary, PocketBundle, EvidenceRef, BriefingPlan, QuestionAnswer, ActionProposal, ActionReceipt |
| `packages/PocketUI` | **codex-pocket-pulse** | All SwiftUI: incoming-call, briefing inbox, Answer/Listen-Later/Snooze, conversation, evidence cards, offline/pending, proposal preview + confirm UX, a11y |
| `packages/PocketInference` | **codex-pocket-echo** | Gemma 4 E2B via LiteRT-LM, model download/verify, local Q&A path |
| `packages/PocketVoice` | **codex-pocket-echo** | whisper.cpp base.en, AVAudioSession, VAD/barge-in, ElevenLabs streaming adapter + AVSpeech fallback, latency/thermal instrumentation |
| `packages/PocketSyncClient` | **claude-pocket-relay** | checkpoint pull + bundle sync to phone, idempotency |
| `packages/PocketActionsClient` | **claude-pocket-relay** | governed writeback via existing Senti MCP/API, receipts, offline pending intents |
| `services/pocket-gateway` | **claude-pocket-relay** | checkpoint extract → summarizer → bundle → aidenid scope → receipts |
| `packages/PocketBriefing` + `packages/PocketStorage` | Atlas assigns exact owner at contract freeze | summary consumer + local SQLite/FTS retrieval |
| `security/reviews` | **claude-warden** | audits, security scans, gate records |

## Narrow interfaces (freeze early so lanes unblock)
- Echo exposes: `LocalInferenceEngine`, `SpeechRecognizer`, `SpeechSynthesizer`, `BargeInController`
- Relay exposes: `PocketSyncClient`, `SentiActionClient`, `ReceiptVerifier`
- Pulse builds against Atlas's fixture + contracts without waiting for Relay.

## Handoff format
`HANDOFF <FROM> -> Atlas: contract=<ver>; commit=<sha>; tests=<proof>; integration=<steps>; limits=<honest limits>`

## Merge gate
No merge to the integration/demo branch without **claude-warden +1** and a **second distinct-role sign-off**. Governed-write, confirmation, replay, wrong-session, injection, and offline-false-success paths are P0 review items.
