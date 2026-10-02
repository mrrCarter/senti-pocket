# MAC_VERIFY — compile + test the Swift packages on a Mac

**Why this exists:** Windows cannot compile the Swift/Xcode closure, so every intended head needs
attributable Mac evidence. On any Mac with Xcode command-line tools, this verifies the listed SwiftPM packages and
the `project.yml`-linked app closure. macOS has **CryptoKit**, so every `#if canImport(CryptoKit)` test path
(hashing, ed25519 signature verification) actually runs — which is exactly what can't run on Windows.

## Prereqs
- macOS with Xcode or the Command Line Tools (`xcode-select --install`). Check: `swift --version`.

## Steps
```bash
set -euo pipefail

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

# ML packages — pull heavy EXTERNAL deps (LiteRT-LM and the whisper.cpp binary XCFramework).
# Resolution, compilation, and tests are mandatory; do not downgrade a failure to a warning.
# LiteRT-LM's unrelated repository prebuilt/ files include unavailable Android LFS objects;
# its Apple SwiftPM targets use checksum-verified release XCFrameworks instead.
echo "==== packages/PocketInference (external deps) ===="
( cd packages/PocketInference && \
  GIT_LFS_SKIP_SMUDGE=1 swift build && \
  GIT_LFS_SKIP_SMUDGE=1 swift test )

echo "==== packages/PocketVoice (external deps) ===="
( cd packages/PocketVoice && swift build && swift test )
```

## The production-linked app closure
Build the packages actually linked by `apps/SentiPocketApp/project.yml` via XcodeGen. `PocketInference` remains a
standalone package/device-integration gate here; this app target does not yet link it or `PocketReasoningGemma`.
```bash
cd apps/SentiPocketApp && xcodegen generate && xcodebuild -scheme SentiPocketApp \
  -destination 'generic/platform=iOS Simulator' build
```

For a signed device archive and verified `.ipa`, sign into the authorized Apple Developer account in Xcode and use
`scripts/ios/archive_ipa.sh` from the repository root. It requires the non-secret Team ID, Release API/gateway HTTPS
origins, and optionally an overridden bundle ID/build number; see `apps/SentiPocketApp/README.md`. A simulator build
does not prove provisioning, APNs entitlements, archive export, or installability.

## Expected
- **Every package listed above builds clean and all tests pass** (0 failures). Coverage that MUST pass:
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
  - **PocketInference** — all package tests pass while compiling the real LiteRT-LM engine; a stubbed or excluded
    engine is not valid evidence. Physical-device model preparation, answers, and benchmarks remain a separate gate.

## If something fails
Report back the **exact** first error with `file:line` (compile error) or the failing XCTest name +
assertion. That is the ground truth that supersedes any static review — please paste it verbatim into
Senti so Atlas can fix the source.

## Not covered here (needs Xcode, not just `swift test`)
`apps/SentiPocketApp` is an iOS app target built via **XcodeGen** — see `apps/SentiPocketApp/README.md`
(`brew install xcodegen && xcodegen generate && open …`). It requires an iOS simulator; SwiftPM package tests do
not prove the app's iOS SDK link closure, signing, APNs entitlements, archive export, installability, or device runtime.
