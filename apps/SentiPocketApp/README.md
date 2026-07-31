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
export SENTI_BUNDLE_ID="com.plexaura.sentipocket.app" # override only if this ID is unavailable on the team
../../scripts/ios/archive_ipa.sh
```

The script generates the Xcode project, resolves packages, archives a Release device build with automatic signing,
exports a registered-device IPA, and then verifies the archive contents, code signature, bundle ID, APNs environment,
`audio`/`voip` background modes, and SHA-256. Each run goes to the ignored `build/ios/<timestamp>-<commit>/` directory
with an `IPA_MANIFEST.txt`; no credential or provisioning private key is written to the repository. It requires a
clean Git worktree and records both commit and tree hashes so an IPA cannot be mislabeled as code it did not build.

On current Xcode, the default export method is `debugging`; older Xcode uses `development`. For another destination,
set `SENTI_EXPORT_METHOD` to a value supported by that Mac's `xcodebuild -help`, set a unique
`SENTI_BUILD_NUMBER`, and let the script enforce the required APNs environment for that export method. The build
always runs from a fresh detached worktree at the recorded commit, so ignored local model files cannot silently enter
an IPA.

## Watchability

Every screen ships a `#Preview` wired to `Resources/canonical_checkpoint.json` (the same canonical
PocketBundle the swarm builds against), so the Xcode canvas shows each screen live the moment you pull.
The placeholder `RootView` decodes the fixture end-to-end (proves the contract + fixture load on-device)
and renders the headline + grounded claims (`[FACT]`/`[INFER]`/`[REC]`) + evidence count.

## Wiring a lane's package

Uncomment its entry under `packages:` in `project.yml`, add it to the target `dependencies:`, re-run
`xcodegen generate`. Only Atlas edits `project.yml` and app-composition files (per OWNERSHIP.md).

## Status

- v0.1.2 contracts linked (PocketContracts). Placeholder RootView only — Pulse's PocketUI screens replace it.
- Requires a Mac + Xcode to build/run/preview (authored on Windows; not built here — unvalidated until `xcodegen generate` + build on macOS).
