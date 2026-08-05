# Xcode Build & Test Manifest — Senti Pocket

## Superseding execution block — 2026-08-04

Everything below this block is retained as historical lane evidence; where it conflicts, this block is authoritative.

- Gateway Registry V2 source of truth: draft PR #124, exact head
  `9774a4554b8be18d1a0886f03bf881cfd7912310`, direct from `master`. Windows gateway suite: 695/695; hosted Omar Gate:
  green; Relay security review: +1. Keep V2 dark until the distributed body-reading operation-admission proxy is built
  and its boot acknowledgement is proved. Constant-time owner-handle comparison and an explicit expired-signal 410
  vector are tracked low-priority follow-ups.
- Held PR #123 (`efdb431c7b7ce4b543fa3451e9c62df7c6e5eb71`) is phone/demo evidence only. Do not merge it: it contains obsolete
  gateway paths. Publish and build the clean iOS-only foundation from `master`, then the Registry V2 authority PR stacked
  on that foundation. Record `git rev-parse HEAD` and `git status --short` with every result.
- Preserve `com.plexaura.sentipocket.app`, Swift 5.9, automatic signing, tracked entitlements, Debug development/Release
  production APNs environments, `audio` + `voip`, the UI-test target, and `scripts/ios/archive_ipa.sh`. Change the bundle
  ID only to an explicitly registered Push-enabled App ID, with the APNs topic/provider/profile changed in the same atom.

Mac build/test gate:

```bash
cd apps/SentiPocketApp
xcodegen generate
xcodebuild -project SentiPocketApp.xcodeproj -scheme SentiPocketApp \
  -destination 'generic/platform=iOS Simulator' build
DEVICE_ID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
for devices in json.load(sys.stdin).get("devices", {}).values():
    for device in devices:
        if device.get("isAvailable") and device.get("name", "").startswith("iPhone"):
            print(device["udid"]); raise SystemExit(0)
raise SystemExit("no available iPhone simulator")
')"
xcodebuild -project SentiPocketApp.xcodeproj -scheme SentiPocketApp \
  -destination "id=$DEVICE_ID" test
```

The complete app target must include `DeviceRingRegistryStateTests`, `DeviceRingRegistrationClientTests`,
`DeviceRingRegistrarTests`, `DialCoordinatorTests`, `DialHostTests`, `DialHostLifecycleTests`, `SentiCallDecodeTests`,
`GatewayEndpointTests`, `SignInCoordinatorTests`, and `PhoneWriteOutboxDurabilityTests`. Require zero failures. In
particular, prove nested V2 fence preflight and post-report recheck, owner/bearer continuity, idempotent cleanup, stale
revision denial, monotonic lease expiry, UUID-scoped CallKit reporting/audio quarantine, cancellation before irreversible
confirmation, durable post-confirm outcomes, and sign-out ordering (local authority + durable marker before credential).

Phone gate after simulator green:

1. Run `scripts/ios/archive_ipa.sh` from a clean exact commit and retain `IPA_MANIFEST.txt`, provisioning receipt, Team ID,
   bundle-qualified App ID, APNs environment, `audio`/`voip`, signature, and IPA hash evidence.
2. Install on a registered physical iPhone and prove a real PushKit token plus genuine provider-sent VoIP push. A signed
   IPA or DEBUG-local ring does not prove APNs delivery.
3. Run at least five answer → audio activation → speak/listen → hangup cycles, plus revoke-during-report, delayed/missing
   activation, provider reset/background, token rotation, session/auth revocation, and cold-launch restoration.
4. Keep Registry V2 disabled until the admission proxy, gateway, iOS adoption, APNs provider, migration/purge evidence,
   fleet acknowledgements, and rollback drill are all complete.
5. Before App Store submission, reconcile `PrivacyInfo.xcprivacy` and App Store privacy answers against the actual
   backend-retention inventory for installation/APNs identifiers, account identifiers, and confirmed user content. The
   current empty collected-data array is provisional, not release evidence.

---

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

- Codex Pocket Pulse (authenticated Activity/checkpoints + signed-IPA readiness):
  - Build exact local commit `eed910dd3dc50978e8db3be50fc2f368e5841e28` or a descendant. Run the hosted app tests, including `SelectedSessionDetailCoordinatorTests`, and `PocketSyncClient`'s `SessionHTTPTransportTests`. Expected: compile succeeds; every test passes; stale same-session principal-A 401/403 responses neither publish nor revoke principal B.
  - Confirm the Activity tab loads only the exact row selected from the authenticated Sessions allowlist; events/actions appear atomically; room checkpoints remain membership-authorized and never receive a signed-bundle badge; changing session or authentication epoch immediately clears the old content/navigation.
  - Simulator proof: `cd apps/SentiPocketApp && xcodegen generate && xcodebuild -project SentiPocketApp.xcodeproj -scheme SentiPocketApp -destination 'generic/platform=iOS Simulator' build`.
  - Signed development IPA proof: sign into the authorized Developer Program account in Xcode, then provide `SENTI_APPLE_TEAM_ID`, `SENTI_API_URL`, and `SENTI_GATEWAY_URL` to `scripts/ios/archive_ipa.sh`. Expected: one verified IPA plus `IPA_MANIFEST.txt`; signed `aps-environment=development`; Info.plist contains `audio` and `voip`; bundle ID equals the configured ID; `codesign --verify --deep --strict` and ZIP integrity both pass.
  - Registry V2 app tests: run the complete `SentiPocketAppTests` target, including `DeviceRingBindingStoreTests`, `DeviceRingRegistrationClientTests`, `DeviceRingRegistrarTests`, `SentiCallDecodeTests`, and `DialHydrationTests`. Expected: Keychain identity/generation transitions compile; exact proof admits only the current unexpired binding; stale/partial/V1 pushes fail closed; a typed stale-generation 409 receives one forced retry; capacity/unknown conflicts never churn generations.
  - Registry V2 gateway parity: `cd services/pocket-gateway && node --test` → **525/525** on this Windows checkpoint. Re-run on the archive commit and require zero failures before device testing. The total includes V1/V2 full-principal isolation, pre-head capacity reservation, same-generation-fenced synchronous loser rollback, stale-unregister/activation races, concurrent last-slot ownership, global scoped-token claims, matching-V1 migration fencing, and injected crash/retry phases.
  - Signed-account attribution: the archive script must verify `com.apple.developer.team-identifier == SENTI_APPLE_TEAM_ID` and that `application-identifier` ends in the configured bundle ID (legacy accounts can use an App ID prefix distinct from Team ID); both values must appear in `IPA_MANIFEST.txt`. It must also decode `embedded.mobileprovision` and verify its expiry, team, application identifier, APNs entitlement, and export-method-specific device/profile class. This proves the exported app used the intended Developer Program team and a profile eligible for the requested channel without storing Apple credentials in the repository.
  - Physical device: install the IPA only on a device registered to that team/profile. Confirm PushKit returns a VoIP token and CallKit reports a genuine incoming VoIP push promptly. This requires the separate APNs provider credential/backend registry; a signed IPA alone does not prove server-side delivery.
  - CallKit lifecycle closure: run `swift test --package-path packages/PocketCall`, `swift test --package-path packages/PocketVoice`, `swift test --package-path packages/PocketDialVoice`, then the complete hosted `SentiPocketAppTests` target (including `DialHostLifecycleTests`, `DialCoordinatorTests`, `SentiCallDecodeTests`, `GatewayEndpointTests`, and `PhoneWriteOutboxDurabilityTests`). Expected: PushKit completion/hydration wait for successful CallKit reporting; answer + audio activation start exactly once for the same UUID; end/reset/auth/selection/binding/deactivation close write authority; call A's late deactivation cannot affect call B; reset releases CallKit audio ownership; hangup before confirm queues nothing; hangup after explicit confirm leaves exactly one posted-or-durably-pending operation; a later call cannot erase that earlier outbox.
  - CallKit physical-device race loop: complete at least five answer → speak/listen → hangup cycles plus one revoke-during-ring and one provider-reset/background cycle. Expected: no duplicate native rings, no speech before `provider(_:didActivate:)`, no audio after end/deactivation, no stuck audio session on the next call, no draft/post from a stale transcript, and every explicitly confirmed operation has one signed receipt or one retained outbox record for idempotent reconciliation.
  - Missing-audio callback recovery: suppress/delay `provider(_:didActivate:)` beyond the 8-second answer deadline. Expected: the governed flow and native call end once; the expired UUID remains the sole provider-wide callback quarantine, so later answers fail closed until that UUID drains through activation+deactivation or `providerDidReset`. If neither system callback nor reset arrives, availability intentionally remains closed (never reassign the UUID-less callback); capture a sysdiagnose and restart the app/provider lifecycle rather than weakening attribution.
