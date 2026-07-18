# Senti Pocket Product Specification

Status: active Sunday demo contract

This document is the canonical review binding for the repository. The detailed operating order and technical baseline remain in [`docs/FIRST_SENTI_MESSAGE_POCKET.md`](docs/FIRST_SENTI_MESSAGE_POCKET.md); ownership and integration boundaries remain in [`OWNERSHIP.md`](OWNERSHIP.md). A change that conflicts with either document must update this specification explicitly.

## Product Outcome

Senti Pocket turns a real Senti checkpoint into a signed, evidence-backed iPhone briefing that can be interrupted, questioned, and acted on by voice. Briefing and grounded Q&A continue after sync with the network disabled. Every write targets the original Senti thread, requires explicit human confirmation of the exact rendered content and target, and returns a verifiable receipt.

## Safety Invariants

1. Model output is data, never authority. A model cannot choose or invoke an unconstrained tool, mutate a target, bypass confirmation, or execute a write directly.
2. Every factual briefing or Q&A answer cites admitted checkpoint evidence. Without supporting evidence, the response is exactly `I do not have evidence for that.` with no citations.
3. Bundle and posted-receipt signatures are cryptographically verified. Signature presence alone is never treated as verification.
4. The confirmed proposal hash binds the exact action kind, session, sequence, rendered preview, creation time, and provenance. Stale, replayed, tampered, malformed, or wrong-session proposals fail closed.
5. Offline writes are `pendingConnectivity`; they are never represented as posted. A pending action can flush once after reconnect, and only a terminal posted receipt is idempotently reusable.
6. Model and speech artifacts are accepted only after exact filename, byte-count, and SHA-256 verification. Downloads require HTTPS, an explicit host allowlist, no credentials in the URL, no redirects, and a bounded response.
7. Provider API secrets never ship to the phone. Premium speech is authorized by an approved first-party gateway; offline AVSpeech remains available without network access.
8. Cancellation, barge-in, supersession, route changes, and interruptions cannot revive stale inference or playback generations.
9. Product claims distinguish source-level checks, simulator checks, and physical-device evidence. Unmeasured latency, WER, thermal, and memory results are never presented as measured.

## Locked Technical Baseline

- Swift 5.9; iOS 16 and macOS 13 package baselines.
- `PocketContracts` is the cross-lane schema and canonicalization owner.
- Local Q&A uses Gemma 4 E2B-compatible `.litertlm` artifacts through LiteRT-LM `0.13.0`, with GPU preferred and CPU explicit.
- Speech recognition uses whisper.cpp `1.9.1` with the pinned `base.en` descriptor.
- Premium speech uses first-party-gateway streaming PCM S16LE mono at 24 kHz with ElevenLabs `eleven_flash_v2_5`; AVSpeech is the offline fallback.
- Senti is the source of truth for checkpoint evidence, governed writes, returned sequences, and team handoffs.

## Acceptance Criteria

1. A physical iPhone receives a real signed checkpoint bundle and renders its source sequence range, participants, risks, blockers, and cited evidence.
2. The user answers the incoming briefing, hears it, interrupts it, asks a question, receives a grounded structured answer, and inspects its exact evidence citations.
3. With network access disabled after sync, cached briefing and Q&A remain functional and visibly honest about offline state.
4. Microphone capture produces bounded 16 kHz mono PCM, whisper.cpp returns a nonempty transcript, and speech-start barge-in cancels both active narration and inference without stale playback resuming.
5. Premium speech streams through the approved gateway when online; gateway, authorization, transport, format, or playback failures fall back to AVSpeech unless the request was explicitly cancelled or superseded.
6. A dictated supported action becomes a typed preview. The user sees and hears the exact target and message, explicitly confirms it, and the gateway posts once to that target.
7. The resulting posted receipt includes the actual Senti sequence and verifies against the trusted gateway Ed25519 public key. Invalid or unsigned receipts never render as sent.
8. Wrong-session, stale-confirmation, replay, delimiter injection, prompt/tool injection, malformed artifact, oversized input/output, and offline false-success tests pass.
9. `swift test` passes for every Swift package on a macOS runner. The local review scan has no P1/P2 findings, and Omar Gate has no P0/P1 findings; repository-readiness P2 findings are resolved or explicitly adjudicated.
10. Five consecutive physical-device runs complete the full loop without deadlock, uncontrolled speech, false listening state, uncited answers, duplicate writes, or false success.

## Merge And Evidence Gate

Integration requires an exact-head `claude-warden` approval plus a second distinct-role sign-off. The handoff must include the commit SHA, tests and scans actually run, integration steps, and honest host/device limitations. CI or billing outages do not weaken this gate; they are recorded and the missing evidence is rerun when service returns.

## Non-Goals

- Destructive, deployment, shell, or free-form tool actions.
- Silent cloud fallback presented as offline inference.
- Training, fine-tuning, or autonomous browsing on the phone.
- Treating user-agent strings, unverified signatures, or model assertions as identity or authorization.
