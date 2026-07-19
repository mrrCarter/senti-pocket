# Xcode Build & Test Manifest — Senti Pocket

pocket-forge (Mac agent) is NOT available yet (Carter's 2015 MacBook Pro is being set up with Node + the sentinelayer CLI; ready ~tomorrow). **forge is NOT a blocker** — all lanes keep building. forge will build + test EVERYTHING here in one pass when the Mac is ready.

**RULE: every agent APPENDS to this file whenever they add anything new. This list only gets LONGER. Never shrink it.** Each item = something forge must build or test on the Mac. Include the exact command / target / expected result.

---
## 0. Prereqs (Mac)
- `brew install xcodegen`
- Node 22 + `npm i -g sentinelayer-cli` (only needed to run the LAN gateway for Phase-B).
- Merge/build the bundle-KAV: `warden/bundle-kav-fix @ 894ca69` (`EXPECTED_SHA=894ca693ec09e5793b562c6fa866091365cc031a`) into the contract branch, or build a branch that contains it.

## 1. Build (source of truth)
- Branch `atlas/pocket-contracts-v0.1 @85e17cb` (wired app + all packages) **+ the bundle-KAV fix**.
- `cd apps/SentiPocketApp && xcodegen generate && open SentiPocketApp.xcodeproj` → build (⌘B), then run (⌘R).
- Per-package: run `MAC_VERIFY.md` with `EXPECTED_SHA=894ca69…` (it aborts unless HEAD matches; builds+tests all 6 packages, fails loud).

## 2. Swift build + test — per package
- **PocketContracts** — `swift test`: KAV positive + negative (crypto-valid/semantic-invalid rejected), field-cap parity vs gateway `SUMMARY_CAPS`, bounds (UTF-8 byte, strictly-positive/non-inverted range, non-empty evidence, dup-id reject), total element(5000)+byte(2MB) budget, identity (dup-agentId, nested-evidence-agent-binding, trimmed ids), consumer-parity acceptance.
- **PocketCall** — state machine + ingress + `VerifiedBundle.verify` (pinned key, unknown-id reject pre-crypto, negative-KAV reject).
- **PocketUI** — `#Preview` renders for every screen against the fixture; UI tests; a11y (VoiceOver, Dynamic Type).
- **PocketInference** — Gemma 4 E2B via LiteRT load + schema-valid answer; measured tok/s, TTFT, memory, thermal on the real device.
- **PocketVoice** — whisper.cpp base.en transcript; AVAudioSession; VAD/barge-in; TTS (AVSpeech offline + ElevenLabs adapter).
- **services/pocket-gateway** — Node tests (already green on Windows); run the LAN server for Phase-B.

## 3. Demo loop — on device (physical iPhone)
- Ring ("Senti is calling") → spoken briefing → interrupt/barge-in → cached Q&A (cited evidence) → dictate a decision → EXACT read-back → confirmation UI (single-use, bound to proposalHash) → [Phase B, gated] real write-back → real sequence + signed receipt.
- Offline/PENDING states render distinctly; a write offline shows PENDING_CONNECTIVITY, never "posted".
- Airplane mode after sync: briefing + Q&A still work.

## 4. Security on device (must hold)
- Confirmation FAILS CLOSED (isValidForConfirmation without CryptoKit → not confirmable).
- SignatureState: tampered/unsigned bundle → UNVERIFIED, and MUST NOT be spoken / used for briefing or Q&A (rejected, not just labeled).
- No "posted" receipt for a non-posted/mock write (false-attestation guard).
- Bundle verifies ONLY under the pinned demo pubkey (`tbiyPLuR…` / current); an unknown signingKeyId is rejected before crypto.

## 5. Per-lane build/test items
_(each lane appends here)_
- Atlas:
- Pulse (PocketUI):
- Echo (PocketInference/Voice):
- Relay (gateway/clients):
