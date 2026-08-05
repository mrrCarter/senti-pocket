# SentiPocketApp — runbook (Atlas-owned)

Native SwiftUI iPhone app shell for Senti Pocket. Atlas owns the Xcode project + integration; feature
lanes hand up their Swift packages and Atlas wires them into `project.yml`.

## Open it on a Mac (all Carter needs)

```bash
brew install xcodegen          # one-time
cd apps/SentiPocketApp
xcodegen generate              # generates SentiPocketApp.xcodeproj from project.yml (no hand-edited .pbxproj)
open SentiPocketApp.xcodeproj
# Xcode: select an iOS Simulator (or a device) and Cmd-R. The canvas #Preview renders without running.
```

`git pull` + the three commands above is the whole loop. The `.xcodeproj` is intentionally **not** in
git (only `project.yml` + Swift sources are) so there are no project-file merge conflicts between lanes.

## Export a signed development IPA

The repository never accepts an Apple ID password. Sign into the authorized Developer Program account once in
Xcode (`Settings → Accounts`), let Xcode keep its signing identity in the login Keychain, then run:

```bash
export SENTI_APPLE_TEAM_ID="YOUR10CHARTEAMID"
export SENTI_API_URL="https://api.example.com"
export SENTI_GATEWAY_URL="https://gateway.example.com"
export SENTI_BUNDLE_ID="com.plexaura.sentipocket.app" # override only with an explicitly registered Push-enabled App ID
../../scripts/ios/archive_ipa.sh
```

The script generates the Xcode project, resolves packages, archives a Release device build with automatic signing,
exports a registered-device IPA, and then verifies the archive contents, code signature, developer Team ID,
bundle-qualified application identifier, bundle ID, APNs environment, `audio`/`voip` background modes, and SHA-256.
It also decodes the embedded provisioning profile and proves it is unexpired, belongs to the requested team and App
ID, carries the same APNs entitlement, and has the device/debugging/distribution shape required by the export method.
Each run goes to the ignored `build/ios/<timestamp>-<commit>/` directory with an `IPA_MANIFEST.txt`; no credential or
provisioning private key is written to the repository. It requires a clean Git worktree and records both commit and
tree hashes so an IPA cannot be mislabeled as code it did not build.

On current Xcode, the default export method is `debugging`; older Xcode uses `development`. For another destination,
set `SENTI_EXPORT_METHOD` to a value supported by that Mac's `xcodebuild -help`, set a unique
`SENTI_BUILD_NUMBER`, and let the script enforce the required APNs environment for that export method. The build
always runs from a fresh detached worktree at the recorded commit, so ignored local model files cannot silently enter
an IPA.

If the bundle ID changes, the registered App ID, provisioning profile, APNs topic, and provider configuration must all
change together. A local signing override alone cannot produce a working VoIP route.

Registry V2 device bindings are installation-owned. The stable random installation identity and replaceable registry
state are separate `AfterFirstUnlockThisDeviceOnly` Keychain records; an independent Application Support continuity
marker fails closed if those stores diverge. A ring is actionable only when its nested V2 fence matches the selected
session, current bearer fingerprint, current PushKit-token digest, accepted server binding, and monotonic lease. Token,
selection, authentication, owner, or lease changes close local call/write authority before cleanup. Sign-out persists
the revoke marker synchronously, performs exact cleanup with the old bearer, and deletes that bearer only after the
registry reaches an empty reconciled state.

Registry V2 remains rollout-gated. Do not enable it until the gateway, distributed operation-admission proxy, iOS
client, APNs provider path, and physical-device evidence are all deployed and acknowledged.

## Watchability

The DEBUG fixture surface and reusable screens ship `#Preview` coverage against canonical fixtures. Release uses the
real authentication gate and repository-backed Sessions, Pocket, and Activity composition; it does not expose the
authenticated root until a real credential is present.

## Wiring a lane's package

Uncomment its entry under `packages:` in `project.yml`, add it to the target `dependencies:`, re-run
`xcodegen generate`. Only Atlas edits `project.yml` and app-composition files (per OWNERSHIP.md).

## Status

- The held PR #123 head has green hosted simulator tests, but it is evidence-only and must not merge because it carries
  obsolete gateway files. The publishable replacement is a clean iOS-only foundation plus a stacked Registry V2 PR.
- The reconciled Registry V2 stack still requires an exact-head Mac compile/test, signed archive/export, install on a
  registered iPhone, genuine PushKit/APNs delivery, and repeated CallKit audio-lifecycle cycles before activation.
- Windows can verify diffs and non-Swift suites, but Xcode signing and physical-device proof remain Mac-only gates.
