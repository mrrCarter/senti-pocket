# Ownership & lock map

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
| `packages/PocketSessionClient` | **claude-pocket-relay** | Client-side auth + session-READ transport per ratified docs/auth-fetch-contract.md (15c83561, V11): CredentialBroker + AuthProviding + SessionTransport + SessionRepository + frozen §4 types (SessionID/RepositorySnapshot/…) + internal SessionRequestSpec + fixtures. Standalone until Atlas's shell consumes it. |
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
