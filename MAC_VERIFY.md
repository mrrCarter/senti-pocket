# MAC_VERIFY — compile + test the Swift packages on a Mac

**Current truth (2026-08-05):** the clean iOS transport chain through draft PR #130 at
`d0ad4b680a469f08cef04235e5740efb909b82a1` has exact-head hosted macOS package/app build and test evidence. That does
not prove Developer Program signing, exact-device provisioning, installation, PushKit/APNs delivery, or CallKit audio
on a physical phone. This runbook is the attribution gate for those remaining claims. macOS has **CryptoKit**, so every
conditional crypto test path runs; full Xcode is required for device-SDK, signing, archive/export, and phone proof.

## Prereqs
- macOS with full Xcode, XcodeGen, and the authorized Developer Program account signed in under Xcode Settings →
  Accounts. Check `xcodebuild -version`, `xcrun --sdk iphoneos --show-sdk-version`, and `xcodegen --version`.
- The exact intended iPhone attached, unlocked, trusted, and in Developer Mode. Copy its physical provisioning UDID
  from Xcode's Devices and Simulators window; do not post that value to GitHub or Senti.

## Steps
```bash
git clone https://github.com/mrrCarter/senti-pocket.git   # or: git -C senti-pocket pull
cd senti-pocket
git switch <intended-current-branch>
git status --short                          # must be clean for an attributable archive
git rev-parse HEAD

# Logic packages — pure SwiftPM, verify with `swift test` (local path deps resolve automatically).
for pkg in packages/PocketContracts packages/PocketCall packages/PocketBriefing packages/PocketUI; do
  echo "==== $pkg ===="
  ( cd "$pkg" && swift build && swift test )
done

# ML packages — pull heavy EXTERNAL deps; `swift build` fetches them (LiteRT-LM source, whisper.cpp binary xcframework).
# These may be better validated via the app's xcodegen build (iOS SDK) than standalone swift test:
for pkg in packages/PocketInference packages/PocketVoice; do
  echo "==== $pkg (external deps) ===="
  ( cd "$pkg" && swift build )
done
```

## The full app and package graph
Build the generated project, then run the complete hosted app test target:
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

For a signed device archive and verified `.ipa`, use `scripts/ios/archive_ipa.sh` from the clean repository root. The
private Mac shell must already contain the authorized Team ID, exact physical provisioning UDID, and the actual
deployed API/gateway HTTPS origins:

```bash
: "${SENTI_APPLE_TEAM_ID:?export the authorized Apple Team ID first}"
: "${SENTI_DEVICE_UDID:?export the exact intended iPhone provisioning UDID first}"
: "${SENTI_API_URL:?export the exact deployed API HTTPS origin first}"
: "${SENTI_GATEWAY_URL:?export the exact deployed gateway HTTPS origin first}"
export SENTI_APPLE_TEAM_ID SENTI_DEVICE_UDID SENTI_API_URL SENTI_GATEWAY_URL

# Optional external-state actions. Uncomment deliberately; registration is development-export-only.
# Both flags default to 0.
# export SENTI_REGISTER_CONNECTED_DEVICE=1
# export SENTI_INSTALL_CONNECTED_DEVICE=1
scripts/ios/archive_ipa.sh
```

The archive gate requires exact UDID membership in the decoded embedded profile and requires its
`DeveloperCertificates` array to contain the actual signing leaf before an opted-in install can run. The device/OS
remains the authority that verifies Apple's profile CMS trust chain. The script emits `IPA_MANIFEST.json`; retain the
commit, IPA SHA-256, and sanitized manifest. A development/ad-hoc IPA and `.xcarchive` expose the profile's registered-device
list by design, so keep both private and never upload them to GitHub/Senti/CI. Raw signing diagnostics are deleted by
default. A simulator or unsigned hosted Release build does not prove provisioning, APNs entitlements, export,
installation, launch, PushKit/APNs delivery, or CallKit behavior. After an opted-in `devicectl` command succeeds,
confirm the intended installed device in Xcode; the manifest deliberately does not claim a parsed CoreDevice identity.

## Expected
- **Every listed build and test exits zero.** Registry V2 coverage must include
  `DeviceRingRegistryStateTests`, `DeviceRingRegistrationClientTests`, `DeviceRingRegistrarTests`,
  `DialCoordinatorTests`, `DialHostTests`, `DialHostLifecycleTests`, `SentiCallDecodeTests`,
  `GatewayEndpointTests`, and `PhoneWriteOutboxDurabilityTests`.
- Package coverage that MUST pass:
  - **PocketContracts** — cross-module construction; Codable round-trips; `ActionResultRef` tagged-union
    Codable + canonical-token KAVs (`6:action…`, `8:sequence…`); receipt canonical **v4** KAV
    (`pocket.actionreceipt.v4\n…15:8:sequence3:200…`); proposal canonical **v3** KAV +
    proposalHash `Wk4lhnUOCRAiFMXVaroaDiv2lyHsRGJsmAJg_mjm1NY`; same-content/different-identity hash
    distinctness (incl. nil-vs-`""` provenance); injection-proof canonicalization; receipt structural
    invariants; extreme-date no-trap; SignatureState.
  - **PocketCall** — the flow reducer: no-shortcut-into-executing, wrong-session refused, confirm-swap
    refused, wrong/empty-challenge refused, receipt-must-bind, real-ed25519 posted-receipt verify
    (correct key → completed, wrong key → not completed), plan/QA provenance. Uses
    `@testable import PocketCall` for the DEBUG-only `VerifiedBundle.makeUnverifiedForTesting`.
  - **PocketBriefing** — deterministic briefing plan.

## If something fails
Report back the **exact** first error with `file:line` (compile error) or the failing XCTest name +
assertion. That is the ground truth that supersedes any static review — please paste it verbatim into
Senti so Atlas can fix the source.

## Not covered here (needs Xcode, not just `swift test`)
`apps/SentiPocketApp` is an iOS app target built via **XcodeGen** — see `apps/SentiPocketApp/README.md`
(`brew install xcodegen && xcodegen generate && open …`). It requires an iOS simulator; the SwiftPM logic packages
verify separately, but they do not prove the app composition, entitlements, archive, APNs, or CallKit lifecycle.
