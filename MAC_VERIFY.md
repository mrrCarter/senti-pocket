# MAC_VERIFY — compile + test the Swift packages on a Mac

**Why this exists:** the packages are authored on Windows (no Swift/Xcode there), so nothing is
compile-verified yet. On any Mac with Xcode command-line tools this is a one-shot, **fail-loud**
verification of every SwiftPM package. macOS has **CryptoKit**, so every `#if canImport(CryptoKit)`
path (SHA-256 hashing, ed25519 bundle/receipt signature verification) actually runs — which is
exactly what cannot run on Windows.

## Prereqs
- macOS with Xcode or the Command Line Tools (`xcode-select --install`). Check: `swift --version`.

## Pin the exact commit — ABORTS on any SHA mismatch (never verifies a moved tip)
Pass the exact **40-char** SHA from the warden's handoff as `EXPECTED_SHA`. The script fetches, checks out that
EXACT commit **detached**, and aborts unless `HEAD` equals it — so a branch tip that moved after the handoff can
never be silently verified. With no `EXPECTED_SHA`, it defaults to the current origin tip and prints an UNPINNED warning.
```bash
set -euo pipefail
git clone https://github.com/mrrCarter/senti-pocket.git 2>/dev/null || true
cd senti-pocket
git fetch --all --prune

if [ -z "${EXPECTED_SHA:-}" ]; then
  EXPECTED_SHA="$(git rev-parse origin/warden/bundle-kav-fix)"
  echo "WARNING: EXPECTED_SHA not set -> defaulting to current origin tip $EXPECTED_SHA (UNPINNED). Pass EXPECTED_SHA=<40-char> from the handoff to pin." >&2
fi
[[ "$EXPECTED_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "ABORT: EXPECTED_SHA must be a full 40-char commit SHA (got '$EXPECTED_SHA')." >&2; exit 1; }

git checkout --detach "$EXPECTED_SHA"
ACTUAL="$(git rev-parse HEAD)"
[ "$ACTUAL" = "$EXPECTED_SHA" ] || { echo "ABORT: HEAD $ACTUAL != EXPECTED_SHA $EXPECTED_SHA." >&2; exit 1; }
echo "OK: pinned + verified at $EXPECTED_SHA"
```
This runbook is committed on `warden/bundle-kav-fix`; verifying any SHA other than the handoff's is meaningless.

## Run EVERY lane — fail loud, swallow nothing
```bash
set -euo pipefail                 # any build/test failure aborts immediately with a non-zero exit
for pkg in PocketContracts PocketCall PocketBriefing PocketUI PocketInference PocketVoice; do
  echo "==== packages/$pkg ===="
  ( cd "packages/$pkg" && swift build && swift test )
done
echo "ALL PACKAGE TESTS PASSED"
```
- `set -e` means the **first** failing package stops the run — that is intended: a green result
  requires **all six** packages to build and pass.
- **Do NOT** wrap `PocketInference` / `PocketVoice` in `|| true` or `|| echo`. They pull heavy
  external deps (LiteRT-LM source, whisper.cpp xcframework); if resolution or a test fails, the run
  MUST fail loudly so the gap is visible — never silently skipped. If they fail on dependency
  resolution specifically, capture the exact error and route it to Echo (owning lane), but the
  overall verification is **not** green until they pass.

## The full app (all packages wired)
```bash
cd apps/SentiPocketApp && xcodegen generate \
  && xcodebuild -scheme SentiPocketApp -destination 'generic/platform=iOS Simulator' build
```

## Expected — all six build clean, 0 test failures. Coverage that MUST pass:
- **PocketContracts**
  - cross-module construction; Codable round-trips; `ActionResultRef` tagged-union Codable + token
    KAVs (`6:action…`, `8:sequence…`); receipt canonical **v4** KAV; proposal canonical **v3** KAV +
    proposalHash `Wk4lhnUOCRAiFMXVaroaDiv2lyHsRGJsmAJg_mjm1NY`; same-content/different-identity hash
    distinctness; injection-proof canonicalization; receipt structural invariants; extreme-date no-trap.
  - **bundle trust anchor + signed KAV (warden/bundle-kav-fix):** the KAV is a bundled test RESOURCE
    (`Tests/PocketContractsTests/Fixtures/bundle_kav.json`, wired in `Package.swift`), loaded via
    `Bundle.module` — the demo key is a REAL random ed25519 keypair; only the PUBLIC key + signature are
    committed (no private key / seed anywhere).
    - `testBundleSignedKAVFromResource` — pinned pubkey == the fixture's; `canonicalBundlePayload()` ==
      the fixture's `pocket.bundle.v1` bytes; the committed real-key signature verifies under the pinned key.
    - `testBundleVerifyRejectsUntrustedIdAndWrongKey` — untrusted `signingKeyId` rejected before crypto;
      a trusted id signed by a THROWAWAY keypair fails the pinned-key check (there is no API to pass a key).
    - `testBundleSignatureRejectsTamper` — summary/evidence/keyId/ordering tamper all fail.
    - `testBundleSemanticValidity` (+ `testSemanticRejectsPerAgentOnlyCitation` /
      `…PerAgentEvidenceMismatch`) — wrong version/schema, inverted/negative range, empty/oversized fields,
      id mismatch, session mismatch, out-of-range/duplicate/foreign evidence, duplicate claim id, per-agent
      evidence not byte-identical to top-level, uncited fact/inference, unsane/sub-ms dates.
- **PocketCall** — flow reducer safety (no-shortcut-into-executing, wrong-session refused, confirm-swap
  refused, wrong/empty-challenge refused, receipt-must-bind, real-ed25519 posted-receipt verify) AND
  `testVerifiedBundleMintsOnPinnedTrust` / `testVerifiedBundleRejectsUnknownIdWrongKeyAndSemanticInvalid`
  (a correctly-signed but semantically-invalid bundle must NOT mint a `VerifiedBundle`).
- **PocketBriefing** — deterministic briefing plan.
- **PocketUI** — evidence resolution, proposal-confirmation gate, receipt presentation, safety states.
- **PocketInference / PocketVoice** — build + tests (fail loud on any dependency or test failure).

## If something fails
Report back the **exact** first error: `file:line` (compile) or the failing XCTest name + assertion.
That is the ground truth that supersedes any static review — paste it verbatim so Atlas can fix the
source. Cross-language note: the bundle/receipt/proposal KAVs are the Swift↔Node contract; if a KAV
assertion fails, the Node gateway (Relay) and the Swift canonicalization have diverged — fix to the KAV.
