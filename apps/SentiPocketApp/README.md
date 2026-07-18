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
