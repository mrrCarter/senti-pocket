# MAC_VERIFY — compile + test the Swift packages on a Mac

**Why this exists:** the packages are authored on Windows (no Swift/Xcode there), so nothing is
compile-verified yet. On any Mac with Xcode command-line tools, this is a one-shot verification of
the three SwiftPM packages. macOS has **CryptoKit**, so every `#if canImport(CryptoKit)` test path
(hashing, ed25519 signature verification) actually runs — which is exactly what can't run on Windows.

## Prereqs
- macOS with Xcode or the Command Line Tools (`xcode-select --install`). Check: `swift --version`.

## Steps
```bash
git clone https://github.com/mrrCarter/senti-pocket.git   # or: git -C senti-pocket pull
cd senti-pocket
git checkout atlas/pocket-contracts-v0.1     # verify HEAD is 7e1cfbe (or later)
git rev-parse --short HEAD

# Each package is independent (PocketCall + PocketBriefing depend on PocketContracts via a local path).
for pkg in packages/PocketContracts packages/PocketCall packages/PocketBriefing; do
  echo "==== $pkg ===="
  ( cd "$pkg" && swift build && swift test )
done
```

## Expected
- **All three build clean and all tests pass** (0 failures). Coverage that MUST pass:
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
(`brew install xcodegen && xcodegen generate && open …`). It requires an iOS simulator; the three
packages above are the logic/contract core and verify without the simulator.
