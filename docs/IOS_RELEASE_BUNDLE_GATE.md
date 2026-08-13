# iOS unsigned Release bundle gate

`scripts/ios/verify_unsigned_release.py` verifies bounded, reusable evidence from an unsigned device build when it is
invoked. It consumes the exact generated Xcode project and target-specific `xcodebuild -showBuildSettings -json`
output, binds the generated script-free `SentiPocketAppRelease` scheme and `TARGET_BUILD_DIR` to independent inputs,
and verifies the built Release `.app`.
The same commands can run in hosted CI or on Forge's Mac without an Apple account or signing material.

## What the gate proves

- Debug resolves the development APNs build setting and Release resolves production.
- Debug defines the Swift `DEBUG` compilation condition; Release proves `DEBUG` absent from both resolved
  `SWIFT_ACTIVE_COMPILATION_CONDITIONS` and `OTHER_SWIFT_FLAGS`. The generated app project must contain no per-file
  `COMPILER_FLAGS`, closing the source-level Swift condition surface that build settings do not expose.
- Signing is explicitly disabled, the Team ID is empty, and the intended bundle/version/build/origins resolve exactly.
- The resolved compiler, linker, Swift driver, toolchain, SDK, and command-search path are bound to the independently
  selected Xcode. Conditional selectors, compiler launchers, response files, and nonempty Release pass-through flag
  families are rejected so the verified build cannot silently load an unreviewed compiler/plugin executable.
- The generated target resolves `ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon` and the build setting
  `TARGETED_DEVICE_FAMILY=1`. The project-bound source asset catalog must use the approved single-image schema, and its
  PNG must be a bounded, CRC-valid, non-animated 1024x1024 opaque 8-bit RGB file with no transparency chunk. Its IDAT
  stream must inflate exactly once to 1024 RGB scanlines with legal PNG filter bytes and no trailing compressed data.
- The shared Release scheme's BuildAction builds only the verified app target, disables implicit target dependencies,
  contains no pre/post executable actions, and its ArchiveAction selects Release. This is the scheme used by the
  unsigned gate and signed archive/export script; unrelated IDE action metadata is outside this proof.
- Release excludes the canonical DEBUG fixture before compilation.
- The built `.app` contains the expected expanded `Info.plist`, a structurally bounded executable-mode thin arm64
  `MH_EXECUTE` Mach-O with a file-backed `__TEXT` segment, exact `audio` + `voip` background modes, and a type-sensitive
  semantic copy of the source privacy manifest. Its `UIDeviceFamily` is type-exact `[1]`; the generic primary icon names
  `AppIcon`; and optional iPad compatibility metadata remains primary-only and either omits `CFBundleIconName` or names
  the same `AppIcon`. The exact standalone-icon behavior is pinned to Xcode's `default`. The required iPhone 120x120
  `AppIcon60x60@2x.png` and, when iPad compatibility metadata is emitted, 152x152
  `AppIcon76x76@2x~ipad.png` are structurally decoded. Every additional present declared loose rendition is also decoded;
  other declared renditions may remain solely in the bounded `Assets.car` under Xcode's `default` behavior.
- The unsigned bundle contains no symlink and no path whose case-insensitive basename or suffix matches the gate's
  enumerated fixture, model, provisioning, signing, environment, or credential filename patterns (including
  `canonical_checkpoint.json`, `ggml-*.bin`, `*whisper*.bin`, `.gguf`, `.tflite`, `.litertlm`, `.task`,
  `embedded.mobileprovision`, `_CodeSignature`, `.p8`, `.p12`, `.pfx`, `.pkcs12`, profile suffixes, `.env`,
  `credentials.json`, and `*.credentials.json`).

The artifact check is deliberately a bounded filename policy, not a content classifier: it does not prove that bytes
copied under an unrelated filename are absent. Signing inputs and private model files must remain outside the app target;
this verifier provides no content-level assurance beyond the enumerated filename patterns.

The source icon check proves the exact catalog schema, the pinned SHA-256 bytes of the approved artwork, and bounded
chunk/decoded-scanline PNG structure. The digest is a tamper-evidence boundary, not a substitute for product review of
the artwork represented by those bytes; an intentional artwork change must update both under review.

Before XcodeGen or SwiftPM is allowed to execute, the source-only preflight pins the LF-canonical SHA-256 of the exact
`project.yml` and all seven Release `Package.swift` manifests. This makes XcodeGen command/include changes and SwiftPM
plugin, macro, unsafe-flag, dependency, or binary-target changes review-gated executable-input changes. The approved
`PocketVoice` manifest includes the reviewed whisper binary URL and checksum; SwiftPM download availability and the
runtime behavior of those binary bytes remain outside this verifier's proof.

The `Assets.car` check proves only a bounded regular CoreUI-looking artifact with the expected `BOMStore` signature.
It does not independently decode or inventory every rendition in that private-format archive. The stronger icon-input
boundary is the exact pinned source catalog, generated-project resource graph, compiler settings, absence of alternate
icon inputs/scripts/build rules, the exact required loose representatives above, and structural decoding of every
additional declared loose rendered PNG that Xcode emits.

Security-sensitive JSON, plist, PBX, scheme, PNG, CoreUI, and Mach-O reads use final-component no-follow file descriptors,
are bounded by `fstat`, and reject observable path or inode changes during verification. Checked final directories and
their enumerated descendants reject indirection; intermediate ancestor indirection is outside the proof. The PBX project
is converted from a private copy of the bytes that were actually inspected, rather than reopening the source path in
`plutil`. A process that can concurrently rewrite evidence in place and restore all filesystem metadata is outside this
gate's threat model;
run it in a quiescent checkout and products directory on a trusted build host.

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
installation, launch, PushKit registration, provider-sent APNs delivery, CallKit presentation, audio lifecycle,
App Store acceptance, or physical-device behavior. `archive_ipa.sh` reuses the icon/privacy/bundle-content verifier on
the exported signed `.app`, then applies its signing/profile/archive evidence; the remaining phone gates live in
`MAC_VERIFY.md` and `apps/SentiPocketApp/README.md`.

## Commands

Bind the selected Xcode and iPhoneOS SDK, run the source preflight **before** XcodeGen, then verify the generated project
before package resolution or any project-consuming Xcode command. Capture settings with the exact same toolchain and
unsigned overrides used by the build. Use `development` for Debug and `production` for Release:

```bash
repository_root="$(pwd -P)"
developer_dir="$(cd "$(xcode-select -p)" && pwd -P)"
sdk_root="$(cd "$(DEVELOPER_DIR="$developer_dir" xcrun --sdk iphoneos --show-sdk-path)" && pwd -P)"
sdk_version="$(DEVELOPER_DIR="$developer_dir" xcrun --sdk iphoneos --show-sdk-version)"
safe_xcode_path="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin:$developer_dir/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin"
swift_tools_dir="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin"
export DEVELOPER_DIR="$developer_dir"

python3 scripts/ios/verify_unsigned_release.py preflight \
  --repository-root "$repository_root"
(cd apps/SentiPocketApp && xcodegen generate)
python3 scripts/ios/verify_unsigned_release.py source \
  --project-file apps/SentiPocketApp/SentiPocketApp.xcodeproj/project.pbxproj

if [[ -n "${RUNNER_TEMP:-}" ]]; then
  scratch_root="$RUNNER_TEMP"
else
  scratch_root="$(mktemp -d "${TMPDIR:-/tmp}/senti-pocket-release.XXXXXX")"
fi
derived_data="$scratch_root/SentiPocket-ReleaseDeviceDerivedData"
products_root="$derived_data/Build/Products"
settings_json="$scratch_root/SentiPocketApp-Release-settings.json"

env PATH="$safe_xcode_path" "$developer_dir/usr/bin/xcodebuild" -quiet \
  -project apps/SentiPocketApp/SentiPocketApp.xcodeproj \
  -scheme SentiPocketAppRelease \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= ONLY_ACTIVE_ARCH=NO \
  PRODUCT_BUNDLE_IDENTIFIER=com.plexaura.sentipocket.app \
  MARKETING_VERSION=0.1.0 CURRENT_PROJECT_VERSION=4242 \
  SENTI_API_URL=https://api.ci.invalid SENTI_GATEWAY_URL=https://gateway.ci.invalid \
  "PATH=$safe_xcode_path" "SDKROOT=$sdk_root" \
  "ASSETCATALOG_EXEC=$developer_dir/usr/bin/actool" \
  CODESIGN=/usr/bin/codesign \
  "CODESIGN_ALLOCATE=$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/codesign_allocate" \
  COMPILATION_CACHE_ENABLE_PLUGIN=NO COMPILATION_CACHE_PLUGIN_PATH= \
  SWIFT_ENABLE_COMPILE_CACHE=NO ALL_OTHER_LDFLAGS= ALTERNATE_LINKER= \
  ALTERNATE_LINKER_PATH= CLANG_ALTERNATE_LINKER= CLANG_ALTERNATE_LINKER_PATH= \
  LD_FLAGS= PRODUCT_SPECIFIC_LDFLAGS= SECTORDER_FLAGS= \
  SWIFTC_ALTERNATE_LINKER= SWIFTC_ALTERNATE_LINKER_PATH= \
  "SWIFT_TOOLS_DIR=$swift_tools_dir" SWIFT_TOOLCHAIN_FLAGS= \
  'SWIFT_RESPONSE_FILE_PATH=$(SWIFT_RESPONSE_FILE_PATH_$(variant)_$(arch))' \
  SWIFT_USE_INTEGRATED_DRIVER=YES \
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
  --products-root "$products_root" \
  --developer-dir "$developer_dir" --sdk-root "$sdk_root" \
  --sdk-version "$sdk_version"
```

Build through the same derived-data path and exact overrides:

```bash
env PATH="$safe_xcode_path" "$developer_dir/usr/bin/xcodebuild" -quiet \
  -project apps/SentiPocketApp/SentiPocketApp.xcodeproj \
  -scheme SentiPocketAppRelease \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= ONLY_ACTIVE_ARCH=NO \
  PRODUCT_BUNDLE_IDENTIFIER=com.plexaura.sentipocket.app \
  MARKETING_VERSION=0.1.0 CURRENT_PROJECT_VERSION=4242 \
  SENTI_API_URL=https://api.ci.invalid SENTI_GATEWAY_URL=https://gateway.ci.invalid \
  "PATH=$safe_xcode_path" "SDKROOT=$sdk_root" \
  "ASSETCATALOG_EXEC=$developer_dir/usr/bin/actool" \
  CODESIGN=/usr/bin/codesign \
  "CODESIGN_ALLOCATE=$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/codesign_allocate" \
  COMPILATION_CACHE_ENABLE_PLUGIN=NO COMPILATION_CACHE_PLUGIN_PATH= \
  SWIFT_ENABLE_COMPILE_CACHE=NO ALL_OTHER_LDFLAGS= ALTERNATE_LINKER= \
  ALTERNATE_LINKER_PATH= CLANG_ALTERNATE_LINKER= CLANG_ALTERNATE_LINKER_PATH= \
  LD_FLAGS= PRODUCT_SPECIFIC_LDFLAGS= SECTORDER_FLAGS= \
  SWIFTC_ALTERNATE_LINKER= SWIFTC_ALTERNATE_LINKER_PATH= \
  "SWIFT_TOOLS_DIR=$swift_tools_dir" SWIFT_TOOLCHAIN_FLAGS= \
  'SWIFT_RESPONSE_FILE_PATH=$(SWIFT_RESPONSE_FILE_PATH_$(variant)_$(arch))' \
  SWIFT_USE_INTEGRATED_DRIVER=YES \
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
  --products-root "$products_root" \
  --developer-dir "$developer_dir" --sdk-root "$sdk_root" \
  --sdk-version "$sdk_version"
```

The cross-platform synthetic regression suite requires only Python 3:

```bash
python3 scripts/ios/tests/verify_unsigned_release_test.py
```
