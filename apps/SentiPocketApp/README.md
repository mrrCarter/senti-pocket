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
Xcode (`Settings → Accounts`), let Xcode keep its signing identity in the login Keychain, attach and trust the intended
iPhone, enable Developer Mode on it, and copy its exact provisioning UDID from Xcode's Devices and Simulators window.
Set the following values in the private Mac shell; they are intentionally not represented by working-looking example
hosts or device identifiers in this repository:

```bash
: "${SENTI_APPLE_TEAM_ID:?export the authorized 10-character Apple Team ID first}"
: "${SENTI_DEVICE_UDID:?export the exact physical iPhone provisioning UDID first}"
: "${SENTI_API_URL:?export the exact deployed HTTPS API origin first}"
: "${SENTI_GATEWAY_URL:?export the exact deployed HTTPS gateway origin first}"
export SENTI_APPLE_TEAM_ID SENTI_DEVICE_UDID SENTI_API_URL SENTI_GATEWAY_URL
export SENTI_BUNDLE_ID="com.plexaura.sentipocket.app" # override only with an explicitly registered Push-enabled App ID
../../scripts/ios/archive_ipa.sh
```

The script rejects literal loopback/private/reserved IPs and reserved documentation/test hostnames. It proves that the
requested origins are embedded byte-for-byte in the signed app; it does not claim those services are deployed or
healthy. Do not run a phone test until the API and gateway owners have supplied their actual deployed origins. The
gateway deployment runbook currently remains the authority for whether a live public gateway exists.

For an already registered phone, opt in to installation with `SENTI_INSTALL_CONNECTED_DEVICE=1`. To let Xcode attempt
automatic device registration first, also set `SENTI_REGISTER_CONNECTED_DEVICE=1`; that flag is intentionally limited
to a debugging/development export because it may mutate the selected Developer Program team's registered-device and
automatic-signing state. Both flags default to `0`. Installation is attempted only after the signed IPA, signing leaf,
decoded embedded-profile fields, and exact target-UDID membership have all passed. A successful install command is not
evidence that the app launched, registered PushKit, received APNs, or completed a CallKit/audio cycle. Because
`devicectl --device` accepts several selector kinds, confirm the intended installed device in Xcode's Devices and
Simulators window; the manifest records command success, not a parsed CoreDevice identity claim.

The script generates the Xcode project, resolves packages, archives a Release device build with automatic signing,
exports a registered-device IPA, and then verifies the archive contents, code signature, developer Team ID,
bundle-qualified application identifier, bundle ID, APNs environment, `audio`/`voip` background modes, and SHA-256.
It also decodes the embedded provisioning profile and checks its expiry, team and App ID fields, APNs entitlement,
exact intended UDID for device-bound exports, and `DeveloperCertificates` membership for the leaf that actually signed
the app. The device/OS remains the authority that validates Apple's profile CMS trust chain. Each run goes to the
ignored `build/ios/<timestamp>-<commit>/` directory with a structured, sanitized `IPA_MANIFEST.json`. The manifest
records source/toolchain hashes, SDK and OS
versions, certificate fingerprint, profile/device proof booleans, opt-in command results, exact embedded origins, and
artifact hashes without recording a raw UDID, device name, certificate subject, profile name, Apple ID, or absolute
IPA path. It requires a clean Git worktree and builds from that exact detached commit.

A development/ad-hoc IPA inherently contains an embedded profile whose signed payload may list every registered UDID
in that profile. Treat the IPA and `.xcarchive` as private device artifacts: never attach them to a public GitHub PR,
Senti post, or CI artifact. Share only the IPA SHA-256 and sanitized manifest when review evidence is needed. Raw build
diagnostics are deleted by default; `SENTI_RETAIN_PRIVATE_DIAGNOSTICS=1` is an explicit owner-private troubleshooting
mode, and its output must not be uploaded or shared.

On current Xcode, the default export method is `debugging`; older Xcode uses `development`. For another destination,
set `SENTI_EXPORT_METHOD` to a value supported by that Mac's `xcodebuild -help`, set a unique
`SENTI_BUILD_NUMBER`, and let the script enforce the required APNs environment for that export method. The build
always runs from a fresh detached worktree at the recorded commit, so ignored local model files cannot silently enter
an IPA. For a non-device-bound App Store or enterprise export, first run
`unset SENTI_DEVICE_UDID SENTI_REGISTER_CONNECTED_DEVICE SENTI_INSTALL_CONNECTED_DEVICE`; the script rejects device
selectors and device actions for those channels.

No `ggml-base.en.bin` model is tracked in this repository, and the detached build intentionally excludes an ignored
local copy. A fresh signed install therefore degrades the dial path to briefing-only/no capture until the exact pinned
Whisper model is provisioned at the documented Application Support location. Signing/install success is not full voice
demo readiness.

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

- The clean iOS chain through draft PR #130 at `d0ad4b680a469f08cef04235e5740efb909b82a1` has exact-head hosted macOS
  package/app builds and tests; it supersedes the obsolete held #123 evidence branch.
- The remaining release gates are signed archive/export from a clean final descendant, exact-device installation,
  pinned Whisper-model provisioning, genuine PushKit/APNs delivery, and repeated physical CallKit audio-lifecycle
  cycles before activation.
- Windows can verify diffs and non-Swift suites, but Xcode signing and physical-device proof remain Mac-only gates.
