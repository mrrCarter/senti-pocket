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
  - Node gateway suite (pre-req, any Node 20 — NOT Xcode): `cd services/pocket-gateway && node --test` → **165/165**.
  - **APP FIXTURE: SIGNED + MERGED (supersedes the FORGE-DAY signing under Atlas above — that instruction is now DONE, do NOT re-apply).** `canonical_checkpoint.json` is signed under `pocket-demo-app-fixture` and merged via PR #4 (`365294c`, warden+Echo+Pulse verified: both copies = blob `9890457`, v0.1.8, `verify=true`, sha `51d9db4d…`, `pocketTrustedGatewayKeys` has `pocket-demo-app-fixture -> SehNmI_dP9…`). Forge does NOT patch/sign the fixture. Forge MUST verify-gate it in the loader (`FixtureLoader -> VerifiedBundle.verify`, per §5 Atlas integration) — the app currently raw-decodes it, so the fix isn't enforced until that lands. Re-sign ONLY if the fixture content changes: `node services/pocket-gateway/scripts/sign-app-fixture.mjs`.
  - **F2: CLOSED** (Echo key#1 + Pulse key#2 + warden `node --test` 165/165). `PocketBundle.maxTotalElements/maxTotalBytes` = **20000 / 1048576** (`@5882855`, == gateway `BUNDLE_BUDGET` in `src/bundle.mjs`). `signBundle` enforces the 512KiB ceiling (`MAX_BUNDLE_BYTES=524288`) < 1MiB phone budget → egress ⊆ phone acceptance BY CONSTRUCTION. Per-field caps == `SUMMARY_CAPS` (256/128/512/8192/8000/…). Forge inherits it; no action.
  - KAV produce-stability: `node scripts/gen-kav.mjs` → `git diff` empty. Cross-lang KAV fixtures consumed by Swift PocketContracts §2 (`pocket_bundle_kav_swift.json` + `_negative`).
  - LAN Phase-B gateway: `node scripts/local-server.mjs` (loopback default; `LAN=1` opt-in) → prints pairing token + raw pubkey. Live-writeback proof: `SENTINELAYER_TOKEN=… node scripts/live-writeback-proof.mjs`. Briefing content demo: `node scripts/briefing-demo.mjs`. Gateway API contract for Swift clients: `services/pocket-gateway/API.md` (do NOT wire the obsolete `relay/gateway-augment` stubs).
