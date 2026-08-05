# iOS unsigned Release bundle gate

`scripts/ios/verify_unsigned_release.py` verifies bounded, reusable evidence from an unsigned device build when it is
invoked. It consumes the exact generated Xcode project and target-specific `xcodebuild -showBuildSettings -json`
output, binds `TARGET_BUILD_DIR` to an independently supplied products root, and verifies the built Release `.app`.
The same commands can run in hosted CI or on Forge's Mac without an Apple account or signing material.

## What the gate proves

- Debug resolves the development APNs build setting and Release resolves production.
- Debug defines the Swift `DEBUG` compilation condition; Release proves `DEBUG` absent from both resolved
  `SWIFT_ACTIVE_COMPILATION_CONDITIONS` and `OTHER_SWIFT_FLAGS`. The generated app project must contain no per-file
  `COMPILER_FLAGS`, closing the source-level Swift condition surface that build settings do not expose.
- Signing is explicitly disabled, the Team ID is empty, and the intended bundle/version/build/origins resolve exactly.
- Release excludes the canonical DEBUG fixture before compilation.
- The built `.app` contains the expected expanded `Info.plist`, a structurally bounded executable-mode thin arm64
  `MH_EXECUTE` Mach-O with a file-backed `__TEXT` segment, exact `audio` + `voip` background modes, and a type-sensitive
  semantic copy of the source privacy manifest.
- The unsigned bundle contains no symlink and no path whose case-insensitive basename or suffix matches the gate's
  enumerated fixture, model, provisioning, signing, environment, or credential filename patterns (including
  `canonical_checkpoint.json`, `ggml-*.bin`, `*whisper*.bin`, `.gguf`, `.tflite`, `.litertlm`, `.task`,
  `embedded.mobileprovision`, `_CodeSignature`, `.p8`, `.p12`, `.pfx`, `.pkcs12`, profile suffixes, `.env`,
  `credentials.json`, and `*.credentials.json`).

The artifact check is deliberately a bounded filename policy, not a content classifier: it does not prove that bytes
copied under an unrelated filename are absent. Signing inputs and private model files must remain outside the app target;
this verifier provides no content-level assurance beyond the enumerated filename patterns.

The `https://*.ci.invalid` origins used by hosted CI are compile-time sentinels. This gate proves exact expansion only;
it does not claim that those hosts are reachable or deployed. Privacy-manifest equality proves resource packaging, not
that the provisional collected-data inventory or App Store privacy answers have received product/legal approval.
The verifier does not authenticate how its JSON was produced. CI command provenance, the independently supplied
products root, and use of the same explicit `-derivedDataPath` for settings capture and build link the evidence to the
Xcode invocation.
The script does not prove that a hosted workflow invoked it; the workflow step and its terminal result are separate CI
evidence.

## What the gate cannot prove

It does **not** prove a signing identity, signed entitlements, provisioning-profile eligibility, Push-enabled App ID,
archive/export success, installation, launch, PushKit registration, provider-sent APNs delivery, CallKit presentation,
audio lifecycle, App Store acceptance, or physical-device behavior. Those remain the signed archive and phone gates in
`MAC_VERIFY.md` and `apps/SentiPocketApp/README.md`.

## Commands

Generate the untracked Xcode project first (`xcodegen generate` from `apps/SentiPocketApp`), as described in the app
README. Then capture settings with the exact same unsigned overrides used by the build. Use `development` for Debug and
`production` for Release:

```bash
(cd apps/SentiPocketApp && xcodegen generate)

if [[ -n "${RUNNER_TEMP:-}" ]]; then
  scratch_root="$RUNNER_TEMP"
else
  scratch_root="$(mktemp -d "${TMPDIR:-/tmp}/senti-pocket-release.XXXXXX")"
fi
derived_data="$scratch_root/SentiPocket-ReleaseDeviceDerivedData"
products_root="$derived_data/Build/Products"
settings_json="$scratch_root/SentiPocketApp-Release-settings.json"

xcodebuild -quiet \
  -project apps/SentiPocketApp/SentiPocketApp.xcodeproj \
  -scheme SentiPocketApp \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= ONLY_ACTIVE_ARCH=NO \
  PRODUCT_BUNDLE_IDENTIFIER=com.plexaura.sentipocket.app \
  MARKETING_VERSION=0.1.0 CURRENT_PROJECT_VERSION=4242 \
  SENTI_API_URL=https://api.ci.invalid SENTI_GATEWAY_URL=https://gateway.ci.invalid \
  -showBuildSettings -json >"$settings_json"
```

Verify resolved settings:

```bash
python3 scripts/ios/verify_unsigned_release.py settings \
  --settings-json "$settings_json" \
  --project-file apps/SentiPocketApp/SentiPocketApp.xcodeproj/project.pbxproj \
  --configuration Release --aps-environment production \
  --bundle-id com.plexaura.sentipocket.app \
  --marketing-version 0.1.0 --build-number 4242 \
  --api-url https://api.ci.invalid --gateway-url https://gateway.ci.invalid \
  --products-root "$products_root"
```

Build through the same derived-data path and exact overrides:

```bash
xcodebuild -quiet \
  -project apps/SentiPocketApp/SentiPocketApp.xcodeproj \
  -scheme SentiPocketApp \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= ONLY_ACTIVE_ARCH=NO \
  PRODUCT_BUNDLE_IDENTIFIER=com.plexaura.sentipocket.app \
  MARKETING_VERSION=0.1.0 CURRENT_PROJECT_VERSION=4242 \
  SENTI_API_URL=https://api.ci.invalid SENTI_GATEWAY_URL=https://gateway.ci.invalid \
  build
```

Then verify its `.app` (the verifier derives the final path from the bound settings record):

```bash
python3 scripts/ios/verify_unsigned_release.py bundle \
  --settings-json "$settings_json" \
  --project-file apps/SentiPocketApp/SentiPocketApp.xcodeproj/project.pbxproj \
  --source-privacy apps/SentiPocketApp/Resources/PrivacyInfo.xcprivacy \
  --configuration Release --aps-environment production \
  --bundle-id com.plexaura.sentipocket.app \
  --marketing-version 0.1.0 --build-number 4242 \
  --api-url https://api.ci.invalid --gateway-url https://gateway.ci.invalid \
  --products-root "$products_root"
```

The cross-platform synthetic regression suite requires only Python 3:

```bash
python3 scripts/ios/tests/verify_unsigned_release_test.py
```
