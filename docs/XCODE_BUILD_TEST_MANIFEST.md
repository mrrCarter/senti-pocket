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
- Atlas (contracts / PocketCall / integration / app):
  - BUILD SOURCE = `atlas/pocket-contracts-v0.1 @9e2a4ae` — CONVERGENCE DONE: 85e17cb full-lane integration + warden's audited verifier (894ca69) adopted + PocketCall v0.4 F1 skip-verification fix + reconciled to the no-key pinned trust model. Build THIS head (supersedes the earlier @f50e6e5 / separate @894ca69).
  - FORGE-DAY app-fixture signing (BLOCKS the on-device demo; needs the Mac): `apps/SentiPocketApp/Resources/canonical_checkpoint.json` is UNSIGNED with an untrusted `signingKeyId` → `VerifiedBundle.verify` rejects it (correct, fail-closed). warden's demo private key was discarded, so sign THIS fixture under a NEW key WITHOUT touching warden's KAV: (1) in Swift generate an ed25519 keypair; (2) set the fixture `signingKeyId="pocket-demo-app-fixture"`, compute `PocketBundle.canonicalBundlePayload()` on the decoded fixture, sign it, write the base64url signature into the fixture; (3) add `"pocket-demo-app-fixture": <new base64url pubkey>` to `pocketTrustedGatewayKeys` in PocketContracts.swift; (4) DISCARD the private key (never commit it); (5) confirm `VerifiedBundle.verify(fixture) != nil`. warden's `bundle_kav.json`/`pocket-demo-phase-a` stays untouched.
  - F2 cap-parity: pin `PocketBundle.maxTotalElements`/`maxTotalBytes` to Relay's EXACT gateway max (pending Relay's number; currently 5000/2MB — demo fixture passes).
  - PocketContracts `swift test`: `testBundleCanonicalKAV` = TWO exact `pocket.bundle.v1` vectors (empty + populated) Relay's Node mirror MUST match; proposal-v3 KAV hash `Wk4lhnUOCRAiFMXVaroaDiv2lyHsRGJsmAJg_mjm1NY`; receipt canon v4 + ActionResultRef token KAVs; same-content/different-id + nil-vs-`""` provenance distinctness.
  - PocketCall `swift test` (`@testable`): v0.4 skip-verification closure (live states hold `VerifiedBundle` → a live call state is unconstructable from a raw bundle); confirm-swap + wrong-challenge + empty-challenge refused; receipt-must-bind; real-ed25519 posted-receipt verify (correct key completes / wrong key does not).
  - App: `apps/SentiPocketApp` wires all 6 packages. RootView is still a placeholder — `fixture → verify → PocketRootView` wiring is pending the signed fixture + Pulse's `PocketUIState`-from-verified-bundle entry.
  - Runbook: `MAC_VERIFY.md` (@atlas branch) = turnkey `swift build && swift test` for the logic packages + the xcodegen app build.
  - GAPS forge will surface: nothing compile-verified (authored on Windows); verifier cap-parity (#2, caps < Relay's 20000) + fail-fast/predecode (#3); Echo's LiteRT-LM SOURCE dep may block the app build → stub behind a Phase-A deterministic-fixture path if so.
- Pulse (PocketUI):
- Echo (PocketInference/Voice):
- Relay (gateway/clients):

## 6. Echo append (2026-07-19; append-only)
- **Exact stacked source:** build `echo/pocket-evidence-audio-hardening-v2 @18965ade13edaed13665169bb549e4a500363097`. Its direct parent MUST be signed-fixture recovery `365294c9f11a65dd2ad44e684a8a81459435d2f2`; abort if either SHA differs. PR #4 must converge first, then PR #5 may retarget `atlas/pocket-contracts-v0.1` without rewriting the PR #5 head.
- **Signed app fixture gate:** both `apps/SentiPocketApp/Resources/canonical_checkpoint.json` and `packages/PocketContracts/Fixtures/canonical_checkpoint.json` MUST resolve to git blob `9890457612d748701ecc9fdfb47907683680bd73`. Run `PocketUIUnitTests/CanonicalFixtureTests`: app/package byte parity, ISO-8601 decode, `VerifiedBundle.verify != nil`, and the semantically-valid `sequenceEnd + 1` tamper MUST be rejected. Swift canonical payload MUST be 1888 bytes with SHA-256 `51d9db4d56dc1ee49e9ca1fbb6825aef3bc5951259891885568b184fcc0053d8` under `signingKeyId=pocket-demo-app-fixture`; any mismatch is a HOLD.
- **Canonical KAV gate:** `PocketContractsTests` MUST reproduce a 354-byte `pocket.bundle.v1` canonical with SHA-256 `be4c9e360624c1bab4f2ad13afeda10c87e2f680ada48e2aa020f0afb069e9e3`, verify its committed signature under `signingKeyId=pocket-demo-phase-a`, and reject the committed crypto-valid/semantic-invalid negative KAV. Do not ship on any byte/hash/signature/semantic mismatch.
- **PocketInference:** `swift test --package-path packages/PocketInference` MUST compile the new PocketCall dependency and run all 22 source XCTest methods. Required regressions: the public request accepts `VerifiedBundle` only; caller evidence is an exact subset; default selection is deterministic and retains the most-recent 32 entries; forged replacement evidence and duplicate/foreign/out-of-range evidence are rejected. Then load the pinned LiteRT-LM model on the physical device and record model load, TTFT, tok/s, memory, and thermal metrics.
- **PocketVoice:** `swift test --package-path packages/PocketVoice` MUST run all 28 source XCTest methods. Required regressions: callback order is preserved without per-frame Tasks; `.bufferingOldest(8)` accepts eight frames then terminates with explicit overflow on the ninth; stale capture generations cannot affect the active stream. On a physical iPhone, stress permission denial, start/stop/restart, route removal, interruption, media-services reset, slow-consumer overflow, and verify no stale frames cross captures.
- **Failed-start audio cleanup:** after the PR #5 build, apply `echo/pocket-audio-session-cleanup @2833abf6b31923d213e56c89c7915f512df32c0e` (direct parent MUST be `18965ade13edaed13665169bb549e4a500363097`). Compile both iOS failure paths and induce a microphone start failure on-device; the activated `AVAudioSession` MUST deactivate, other audio MUST resume, and the app MUST NOT remain in a false-listening state.
- **App integration acceptance:** a typed loader MUST decode then mint `VerifiedBundle`; raw `PocketBundle` content MUST NOT drive `PocketUIState` or narration. A main-actor coordinator must be the sole `PocketCall` reducer, build `BriefingBuilder.plan`, sequence TTS, and bind barge-in to stopping speech plus cancelling inference. Offline Q&A is allowed only after exact SHA/size verification and preparation of both Whisper and LiteRT model artifacts; absent models render an explicit unavailable state, never fake answers.
