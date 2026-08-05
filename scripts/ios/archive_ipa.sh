#!/usr/bin/env bash
set -euo pipefail

umask 077

fail() {
  printf 'archive_ipa: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

require_https_origin() {
  local name="$1"
  local value="$2"
  local authority
  local host
  local port=""
  local port_number=0
  local label
  local labels=()
  local octet
  local octets=()
  local ipv4_a=0
  local ipv4_b=0
  local ipv4_c=0
  [[ "$value" =~ ^https://[^/?#[:space:]]+/?$ ]] \
    || fail "$name must be an HTTPS origin with no path, query, fragment, or whitespace"
  if printf '%s' "$value" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    fail "$name must not contain control characters"
  fi

  authority="${value#https://}"
  authority="${authority%/}"
  if [[ "$authority" =~ ^([A-Za-z0-9.-]+)(:([0-9]{1,5}))?$ ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[3]}"
    [[ ${#host} -le 253 && "$host" != .* && "$host" != *. && "$host" != *..* ]] \
      || fail "$name contains an invalid DNS host"
    IFS='.' read -r -a labels <<<"$host"
    for label in "${labels[@]}"; do
      [[ ${#label} -le 63 && "$label" =~ ^([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]{0,61}[A-Za-z0-9])$ ]] \
        || fail "$name contains an invalid DNS label"
    done
  else
    fail "$name must use an ASCII DNS or IPv4 host with an optional numeric port"
  fi
  if [[ -n "$port" ]]; then
    port_number=$((10#$port))
    (( port_number >= 1 && port_number <= 65535 )) \
      || fail "$name port must be between 1 and 65535"
  fi

  host="$(printf '%s' "$host" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  if [[ "$host" =~ ^[0-9.]+$ ]]; then
    IFS='.' read -r -a octets <<<"$host"
    (( ${#octets[@]} == 4 )) || fail "$name contains an invalid IPv4 address"
    for octet in "${octets[@]}"; do
      [[ "$octet" =~ ^[0-9]{1,3}$ ]] || fail "$name contains an invalid IPv4 address"
      [[ ${#octet} -eq 1 || "$octet" != 0* ]] \
        || fail "$name contains an ambiguous leading-zero IPv4 address"
      (( 10#$octet <= 255 )) || fail "$name contains an invalid IPv4 address"
    done
    ipv4_a=$((10#${octets[0]}))
    ipv4_b=$((10#${octets[1]}))
    ipv4_c=$((10#${octets[2]}))
    if (( ipv4_a == 0 || ipv4_a == 10 || ipv4_a == 127 || ipv4_a >= 224 ||
          (ipv4_a == 100 && ipv4_b >= 64 && ipv4_b <= 127) ||
          (ipv4_a == 169 && ipv4_b == 254) ||
          (ipv4_a == 172 && ipv4_b >= 16 && ipv4_b <= 31) ||
          (ipv4_a == 192 && ipv4_b == 0) ||
          (ipv4_a == 192 && ipv4_b == 88 && ipv4_c == 99) ||
          (ipv4_a == 192 && ipv4_b == 168) ||
          (ipv4_a == 198 && (ipv4_b == 18 || ipv4_b == 19)) ||
          (ipv4_a == 198 && ipv4_b == 51 && ipv4_c == 100) ||
          (ipv4_a == 203 && ipv4_b == 0 && ipv4_c == 113) )); then
      fail "$name must be a deployed HTTPS origin, not a private, loopback, or reserved IP address"
    fi
  else
    [[ "$host" == *.* ]] || fail "$name must use a fully qualified deployed DNS host"
    case "$host" in
      localhost|*.localhost|local|*.local|home.arpa|*.home.arpa|example|*.example|example.com|*.example.com|example.net|*.example.net|example.org|*.example.org|invalid|*.invalid|test|*.test)
        fail "$name must be a deployed HTTPS origin, not a loopback or reserved documentation/test host"
        ;;
    esac
  fi
}

require_binary_flag() {
  local name="$1"
  local value="$2"
  [[ "$value" == "0" || "$value" == "1" ]] || fail "$name must be exactly 0 or 1"
}

sha256_text() {
  printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
}

VALIDATE_INPUTS_ONLY=false
case "$#" in
  0) ;;
  1)
    [[ "$1" == "--validate-inputs-only" ]] \
      || fail "usage: scripts/ios/archive_ipa.sh [--validate-inputs-only]"
    VALIDATE_INPUTS_ONLY=true
    ;;
  *) fail "usage: scripts/ios/archive_ipa.sh [--validate-inputs-only]" ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCHEME="SentiPocketApp"

TEAM_ID="${SENTI_APPLE_TEAM_ID:-}"
BUNDLE_ID="${SENTI_BUNDLE_ID:-com.plexaura.sentipocket.app}"
API_URL="${SENTI_API_URL:-}"
GATEWAY_URL="${SENTI_GATEWAY_URL:-}"
DEVICE_UDID="${SENTI_DEVICE_UDID:-}"
REGISTER_CONNECTED_DEVICE="${SENTI_REGISTER_CONNECTED_DEVICE:-0}"
INSTALL_CONNECTED_DEVICE="${SENTI_INSTALL_CONNECTED_DEVICE:-0}"
RETAIN_PRIVATE_DIAGNOSTICS="${SENTI_RETAIN_PRIVATE_DIAGNOSTICS:-0}"
MARKETING_VERSION="${SENTI_MARKETING_VERSION:-0.1.0}"
BUILD_NUMBER="${SENTI_BUILD_NUMBER:-1}"
OUTPUT_ROOT="${SENTI_IPA_OUTPUT_DIR:-$REPO_ROOT/build/ios}"

[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] \
  || fail "SENTI_APPLE_TEAM_ID must be the 10-character Developer Program Team ID"
[[ ${#BUNDLE_ID} -le 255 && "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] \
  || fail "SENTI_BUNDLE_ID is not a valid reverse-DNS bundle identifier"
[[ "$MARKETING_VERSION" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] \
  || fail "SENTI_MARKETING_VERSION must look like 0.1 or 0.1.0"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] \
  || fail "SENTI_BUILD_NUMBER must be a positive integer"
require_https_origin "SENTI_API_URL" "$API_URL"
require_https_origin "SENTI_GATEWAY_URL" "$GATEWAY_URL"
require_binary_flag "SENTI_REGISTER_CONNECTED_DEVICE" "$REGISTER_CONNECTED_DEVICE"
require_binary_flag "SENTI_INSTALL_CONNECTED_DEVICE" "$INSTALL_CONNECTED_DEVICE"
require_binary_flag "SENTI_RETAIN_PRIVATE_DIAGNOSTICS" "$RETAIN_PRIVATE_DIAGNOSTICS"
if [[ -n "$DEVICE_UDID" ]]; then
  [[ "$DEVICE_UDID" =~ ^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16})$ ]] \
    || fail "SENTI_DEVICE_UDID must be a physical-device provisioning UDID"
  DEVICE_UDID="$(printf '%s' "$DEVICE_UDID" | LC_ALL=C tr '[:lower:]' '[:upper:]')"
fi
[[ "$OUTPUT_ROOT" == /* && "$OUTPUT_ROOT" != "/" ]] \
  || fail "SENTI_IPA_OUTPUT_DIR must be an absolute path below a named directory"
if [[ "$OUTPUT_ROOT" == *$'\n'* || "$OUTPUT_ROOT" == *$'\r'* ]] || \
    printf '%s' "$OUTPUT_ROOT" | LC_ALL=C grep -q '[[:cntrl:]]'; then
  fail "SENTI_IPA_OUTPUT_DIR must not contain control characters"
fi
if [[ "$VALIDATE_INPUTS_ONLY" == "true" ]]; then
  printf 'archive_ipa: input syntax validation passed; no build or external action was performed\n'
  exit 0
fi

require_command xcodebuild
require_command xcodegen
require_command codesign
require_command base64
require_command openssl
require_command security
require_command ditto
require_command plutil
require_command shasum
require_command sw_vers
require_command unzip
require_command xcrun
[[ -x /usr/libexec/PlistBuddy ]] || fail "/usr/libexec/PlistBuddy is unavailable"

[[ -z "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=normal)" ]] \
  || fail "the Git worktree must be clean so the IPA can be attributed to an exact commit"

XCODEBUILD_HELP="$(xcodebuild -help 2>&1 || true)"
if [[ -n "${SENTI_EXPORT_METHOD:-}" ]]; then
  EXPORT_METHOD="$SENTI_EXPORT_METHOD"
else
  if grep -Eq '(^|[^[:alnum:]])debugging([^[:alnum:]]|$)' <<<"$XCODEBUILD_HELP"; then
    EXPORT_METHOD="debugging"
  else
    # Xcode 14 and earlier use the legacy name for the same registered-device export.
    EXPORT_METHOD="development"
  fi
fi
[[ "$EXPORT_METHOD" =~ ^[A-Za-z0-9-]+$ ]] \
  || fail "SENTI_EXPORT_METHOD contains unsupported characters"

case "$EXPORT_METHOD" in
  debugging|development)
    REQUIRED_APS_ENVIRONMENT="development"
    REQUIRED_PROFILE_CLASS="development"
    ;;
  release-testing|ad-hoc)
    REQUIRED_APS_ENVIRONMENT="production"
    REQUIRED_PROFILE_CLASS="ad-hoc"
    ;;
  app-store-connect|app-store)
    REQUIRED_APS_ENVIRONMENT="production"
    REQUIRED_PROFILE_CLASS="app-store"
    ;;
  enterprise)
    REQUIRED_APS_ENVIRONMENT="production"
    REQUIRED_PROFILE_CLASS="enterprise"
    ;;
  *)
    fail "unsupported iOS IPA export method: $EXPORT_METHOD"
    ;;
esac
if [[ -n "${SENTI_APS_ENVIRONMENT:-}" && "$SENTI_APS_ENVIRONMENT" != "$REQUIRED_APS_ENVIRONMENT" ]]; then
  fail "SENTI_APS_ENVIRONMENT conflicts with export method $EXPORT_METHOD (requires $REQUIRED_APS_ENVIRONMENT)"
fi
APS_ENVIRONMENT="$REQUIRED_APS_ENVIRONMENT"
DEVICE_BOUND_PROFILE=false
if [[ "$REQUIRED_PROFILE_CLASS" == "development" || "$REQUIRED_PROFILE_CLASS" == "ad-hoc" ]]; then
  DEVICE_BOUND_PROFILE=true
  [[ -n "$DEVICE_UDID" ]] \
    || fail "SENTI_DEVICE_UDID is required for a device-bound $EXPORT_METHOD export"
elif [[ -n "$DEVICE_UDID" || "$REGISTER_CONNECTED_DEVICE" == "1" || "$INSTALL_CONNECTED_DEVICE" == "1" ]]; then
  fail "connected-device attribution is supported only for debugging/development or release-testing/ad-hoc exports"
fi
if [[ "$REGISTER_CONNECTED_DEVICE" == "1" ]] && \
    ! grep -q -- '-allowProvisioningDeviceRegistration' <<<"$XCODEBUILD_HELP"; then
  fail "this Xcode does not support opt-in command-line device registration"
fi
if [[ "$REGISTER_CONNECTED_DEVICE" == "1" && "$REQUIRED_PROFILE_CLASS" != "development" ]]; then
  fail "SENTI_REGISTER_CONNECTED_DEVICE=1 is supported only for debugging/development exports; register the device in Xcode before an ad-hoc export"
fi
if [[ "$INSTALL_CONNECTED_DEVICE" == "1" ]]; then
  xcrun --find devicectl >/dev/null 2>&1 \
    || fail "SENTI_INSTALL_CONNECTED_DEVICE=1 requires Xcode devicectl"
  xcrun devicectl help device install app >/dev/null 2>&1 \
    || fail "this Xcode devicectl does not support device install app"
fi
TARGET_DEVICE_COMMITMENT_SALT="not-applicable"
TARGET_DEVICE_COMMITMENT_SHA256="not-applicable"
if [[ -n "$DEVICE_UDID" ]]; then
  TARGET_DEVICE_COMMITMENT_SALT="$(openssl rand -hex 16)"
  [[ "$TARGET_DEVICE_COMMITMENT_SALT" =~ ^[0-9a-f]{32}$ ]] || fail "failed to create device commitment salt"
  TARGET_DEVICE_COMMITMENT_SHA256="$(sha256_text "senti-pocket-target-device-v1|$TARGET_DEVICE_COMMITMENT_SALT|$DEVICE_UDID")"
fi

SOURCE_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
SOURCE_TREE="$(git -C "$REPO_ROOT" rev-parse 'HEAD^{tree}')"
BUILD_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
XCODE_VERSION="$(xcodebuild -version | tr '\n' ';')"
XCODE_VERSION="${XCODE_VERSION%;}"
XCODEGEN_VERSION="$(xcodegen --version | tr '\n' ';')"
XCODEGEN_VERSION="${XCODEGEN_VERSION%;}"
XCODEGEN_BINARY_SHA256="$(shasum -a 256 "$(command -v xcodegen)" | awk '{print $1}')"
SWIFT_VERSION="$(xcrun swift --version 2>&1 | head -n 1)"
IOS_SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"
IOS_SDK_BUILD="$(xcrun --sdk iphoneos --show-sdk-build-version)"
MACOS_VERSION="$(sw_vers -productVersion)"
MACOS_BUILD="$(sw_vers -buildVersion)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-${SOURCE_SHA:0:12}-$$"
RUN_DIR="$OUTPUT_ROOT/$RUN_ID"
SOURCE_ROOT="$RUN_DIR/source"
APP_DIR="$SOURCE_ROOT/apps/SentiPocketApp"
PROJECT_PATH="$APP_DIR/SentiPocketApp.xcodeproj"
ARCHIVE_PATH="$RUN_DIR/SentiPocketApp.xcarchive"
FINAL_EXPORT_DIR="$RUN_DIR/export"
SOURCE_PACKAGES="$OUTPUT_ROOT/SourcePackages"
EXPORT_OPTIONS="$RUN_DIR/ExportOptions.plist"
PRIVATE_VERIFICATION_DIR="$RUN_DIR/private-verification"
PRIVATE_DIAGNOSTICS_DIR="$RUN_DIR/private-diagnostics"
EXPORT_DIR="$PRIVATE_VERIFICATION_DIR/export"
DERIVED_DATA="$PRIVATE_VERIFICATION_DIR/DerivedData"
VERIFY_DIR="$PRIVATE_VERIFICATION_DIR/verify"
SIGNING_CERT_DIR="$PRIVATE_VERIFICATION_DIR/signing-certificate"
PRIVATE_DEVICE_OUTPUT=""
FINAL_IPA_PATH=""
MANIFEST_PATH=""
FINAL_IPA_MOVED=false
FINALIZATION_COMPLETE=false

mkdir -p \
  "$RUN_DIR" \
  "$FINAL_EXPORT_DIR" \
  "$SOURCE_PACKAGES" \
  "$EXPORT_DIR" \
  "$VERIFY_DIR" \
  "$SIGNING_CERT_DIR" \
  "$PRIVATE_DIAGNOSTICS_DIR"
chmod 700 "$RUN_DIR" "$PRIVATE_VERIFICATION_DIR" "$PRIVATE_DIAGNOSTICS_DIR"

WORKTREE_ADDED=false
cleanup() {
  if [[ -n "$PRIVATE_DEVICE_OUTPUT" ]]; then
    rm -f "$PRIVATE_DEVICE_OUTPUT" >/dev/null 2>&1 || true
  fi
  if [[ "$WORKTREE_ADDED" == "true" ]]; then
    git -C "$REPO_ROOT" worktree remove --force "$SOURCE_ROOT" >/dev/null 2>&1 || true
  fi
  if [[ "$FINALIZATION_COMPLETE" != "true" ]]; then
    [[ "$FINAL_IPA_MOVED" != "true" ]] || rm -f "$FINAL_IPA_PATH" >/dev/null 2>&1 || true
    [[ -z "$MANIFEST_PATH" ]] || rm -f "$MANIFEST_PATH" >/dev/null 2>&1 || true
  fi
  rm -rf "$PRIVATE_VERIFICATION_DIR" >/dev/null 2>&1 || true
  if [[ "$RETAIN_PRIVATE_DIAGNOSTICS" != "1" ]]; then
    rm -rf "$PRIVATE_DIAGNOSTICS_DIR" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

fail_build_step() {
  local step="$1"
  if [[ "$RETAIN_PRIVATE_DIAGNOSTICS" == "1" ]]; then
    fail "$step failed; owner-only diagnostics were retained at $PRIVATE_DIAGNOSTICS_DIR"
  fi
  fail "$step failed; rerun with SENTI_RETAIN_PRIVATE_DIAGNOSTICS=1 only if owner-private diagnostics are required"
}

# Build only tracked bytes from the recorded commit. The developer checkout may contain ignored model weights
# (for example Resources/ggml-base.en.bin); a detached worktree prevents those bytes from entering a mislabeled IPA.
git -C "$REPO_ROOT" worktree add --detach "$SOURCE_ROOT" "$SOURCE_SHA" \
  >"$PRIVATE_DIAGNOSTICS_DIR/worktree.log" 2>&1 \
  || fail_build_step "detached exact-source worktree creation"
WORKTREE_ADDED=true
ARCHIVE_SCRIPT_SHA256="$(shasum -a 256 "$SOURCE_ROOT/scripts/ios/archive_ipa.sh" | awk '{print $1}')"
PROJECT_SPEC_SHA256="$(shasum -a 256 "$APP_DIR/project.yml" | awk '{print $1}')"

if ! (
  cd "$APP_DIR"
  xcodegen generate
) >"$PRIVATE_DIAGNOSTICS_DIR/xcodegen.log" 2>&1; then
  fail_build_step "Xcode project generation"
fi
[[ -d "$PROJECT_PATH" ]] || fail "XcodeGen did not create $PROJECT_PATH"

if ! xcodebuild \
  -resolvePackageDependencies \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
  >"$PRIVATE_DIAGNOSTICS_DIR/resolve-packages.log" 2>&1; then
  fail_build_step "Swift package resolution"
fi

COMMON_BUILD_SETTINGS=(
  "APS_ENVIRONMENT=$APS_ENVIRONMENT"
  "CODE_SIGN_STYLE=Automatic"
  "CURRENT_PROJECT_VERSION=$BUILD_NUMBER"
  "DEVELOPMENT_TEAM=$TEAM_ID"
  "MARKETING_VERSION=$MARKETING_VERSION"
  "PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID"
  "SENTI_API_URL=$API_URL"
  "SENTI_GATEWAY_URL=$GATEWAY_URL"
)

DEVICE_REGISTRATION_BUILD_SUCCEEDED=false
DEVICE_INSTALL_COMMAND_SUCCEEDED=false

if [[ "$REGISTER_CONNECTED_DEVICE" == "1" ]]; then
  # Explicit opt-in only: this may register the connected device and refresh automatic signing assets in the selected
  # Developer Program team. The later embedded-profile check is the authority that proves the exact UDID was included.
  if ! xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "platform=iOS,id=$DEVICE_UDID" \
    -derivedDataPath "$PRIVATE_VERIFICATION_DIR/DeviceDerivedData" \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    "CODE_SIGN_STYLE=Automatic" \
    "CURRENT_PROJECT_VERSION=$BUILD_NUMBER" \
    "DEVELOPMENT_TEAM=$TEAM_ID" \
    "MARKETING_VERSION=$MARKETING_VERSION" \
    "PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID" \
    "APS_ENVIRONMENT=development" \
    "SENTI_API_URL=$API_URL" \
    "SENTI_GATEWAY_URL=$GATEWAY_URL" \
    build >"$PRIVATE_DIAGNOSTICS_DIR/device-registration-build.log" 2>&1; then
    fail_build_step "automatic development device-registration build"
  fi
  DEVICE_REGISTRATION_BUILD_SUCCEEDED=true
fi

if ! xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
  -allowProvisioningUpdates \
  "${COMMON_BUILD_SETTINGS[@]}" \
  archive >"$PRIVATE_DIAGNOSTICS_DIR/archive.log" 2>&1; then
  fail_build_step "signed Release archive"
fi

[[ -d "$ARCHIVE_PATH" ]] || fail "xcodebuild reported success without creating the archive"

cp "$APP_DIR/ExportOptions.example.plist" "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c "Set :method $EXPORT_METHOD" "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c "Set :teamID $TEAM_ID" "$EXPORT_OPTIONS"
plutil -lint "$EXPORT_OPTIONS" >/dev/null

if ! xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates \
  >"$PRIVATE_DIAGNOSTICS_DIR/export.log" 2>&1; then
  fail_build_step "signed IPA export"
fi

IPA_COUNT="$(find "$EXPORT_DIR" -maxdepth 1 -type f -name '*.ipa' | wc -l | tr -d '[:space:]')"
[[ "$IPA_COUNT" == "1" ]] || fail "expected exactly one exported IPA, found $IPA_COUNT"
IPA_PATH="$(find "$EXPORT_DIR" -maxdepth 1 -type f -name '*.ipa' -print -quit)"
unzip -tq "$IPA_PATH" >/dev/null
ditto -x -k "$IPA_PATH" "$VERIFY_DIR"

APP_COUNT="$(find "$VERIFY_DIR/Payload" -maxdepth 1 -type d -name '*.app' | wc -l | tr -d '[:space:]')"
[[ "$APP_COUNT" == "1" ]] || fail "expected exactly one Payload/*.app bundle, found $APP_COUNT"
APP_PATH="$(find "$VERIFY_DIR/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
if ! codesign --verify --deep --strict "$APP_PATH" \
    >"$PRIVATE_DIAGNOSTICS_DIR/codesign-verify.log" 2>&1; then
  fail_build_step "strict code-signature verification"
fi

SIGNED_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist")"
[[ "$SIGNED_BUNDLE_ID" == "$BUNDLE_ID" ]] \
  || fail "signed bundle id is $SIGNED_BUNDLE_ID, expected $BUNDLE_ID"
SIGNED_MARKETING_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Info.plist")"
[[ "$SIGNED_MARKETING_VERSION" == "$MARKETING_VERSION" ]] \
  || fail "signed marketing version is $SIGNED_MARKETING_VERSION, expected $MARKETING_VERSION"
SIGNED_BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Info.plist")"
[[ "$SIGNED_BUILD_NUMBER" == "$BUILD_NUMBER" ]] \
  || fail "signed build number is $SIGNED_BUILD_NUMBER, expected $BUILD_NUMBER"
SIGNED_API_URL="$(/usr/libexec/PlistBuddy -c 'Print :SENTI_API_URL' "$APP_PATH/Info.plist")"
[[ "$SIGNED_API_URL" == "$API_URL" ]] \
  || fail "the signed app's SENTI_API_URL does not match the requested Release origin"
SIGNED_GATEWAY_URL="$(/usr/libexec/PlistBuddy -c 'Print :SENTI_GATEWAY_URL' "$APP_PATH/Info.plist")"
[[ "$SIGNED_GATEWAY_URL" == "$GATEWAY_URL" ]] \
  || fail "the signed app's SENTI_GATEWAY_URL does not match the requested Release origin"
SIGNED_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Info.plist")"
[[ "$SIGNED_EXECUTABLE" =~ ^[A-Za-z0-9._+-]+$ && -f "$APP_PATH/$SIGNED_EXECUTABLE" ]] \
  || fail "the signed app has an invalid or missing CFBundleExecutable"
SIGNED_ARCHITECTURES="$(xcrun lipo -archs "$APP_PATH/$SIGNED_EXECUTABLE")"
case " $SIGNED_ARCHITECTURES " in
  *" arm64 "*) ;;
  *) fail "the signed app executable does not contain arm64" ;;
esac
SIGNED_MINIMUM_OS_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$APP_PATH/Info.plist")"
[[ "$SIGNED_MINIMUM_OS_VERSION" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] \
  || fail "the signed app has an invalid MinimumOSVersion"

(
  cd "$SIGNING_CERT_DIR"
  codesign --display --extract-certificates "$APP_PATH" >/dev/null 2>&1
) || fail "the signing certificate chain could not be extracted from the signed app"
SIGNING_LEAF_CERTIFICATE="$SIGNING_CERT_DIR/codesign0"
[[ -s "$SIGNING_LEAF_CERTIFICATE" ]] || fail "codesign did not extract the signing leaf certificate"
openssl x509 -inform DER -in "$SIGNING_LEAF_CERTIFICATE" -checkend 0 -noout >/dev/null 2>&1 \
  || fail "the signing leaf certificate is expired or invalid"
SIGNING_LEAF_CERTIFICATE_SHA256="$(shasum -a 256 "$SIGNING_LEAF_CERTIFICATE" | awk '{print $1}')"
SIGNING_LEAF_CERTIFICATE_NOT_AFTER="$(openssl x509 -inform DER -in "$SIGNING_LEAF_CERTIFICATE" -enddate -noout | sed 's/^notAfter=//')"
[[ -n "$SIGNING_LEAF_CERTIFICATE_NOT_AFTER" ]] || fail "the signing leaf certificate has no validity end date"

SIGNED_ENTITLEMENTS="$PRIVATE_VERIFICATION_DIR/signed-entitlements.plist"
codesign -d --entitlements :- "$APP_PATH" >"$SIGNED_ENTITLEMENTS" 2>/dev/null
plutil -lint "$SIGNED_ENTITLEMENTS" >/dev/null
SIGNED_TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "$SIGNED_ENTITLEMENTS")"
[[ "$SIGNED_TEAM_ID" == "$TEAM_ID" ]] \
  || fail "signed developer team is $SIGNED_TEAM_ID, expected $TEAM_ID"
SIGNED_APPLICATION_ID="$(/usr/libexec/PlistBuddy -c 'Print :application-identifier' "$SIGNED_ENTITLEMENTS")"
# Older Developer Program memberships can have an App ID prefix (bundle seed ID) distinct from the Team ID.
# The explicit team entitlement above is authoritative; the application identifier must still bind this bundle ID.
[[ "$SIGNED_APPLICATION_ID" == *".$BUNDLE_ID" ]] \
  || fail "signed application identifier is $SIGNED_APPLICATION_ID and does not bind bundle id $BUNDLE_ID"
SIGNED_APS_ENVIRONMENT="$(/usr/libexec/PlistBuddy -c 'Print :aps-environment' "$SIGNED_ENTITLEMENTS")"
[[ "$SIGNED_APS_ENVIRONMENT" == "$APS_ENVIRONMENT" ]] \
  || fail "signed aps-environment is $SIGNED_APS_ENVIRONMENT, expected $APS_ENVIRONMENT"

# The exported IPA must carry a decodable provisioning profile whose fields bind this exact app, team, capability set,
# signing leaf, and distribution channel. The device/OS remains the authority that verifies Apple's CMS trust chain.
EMBEDDED_PROFILE="$APP_PATH/embedded.mobileprovision"
[[ -f "$EMBEDDED_PROFILE" ]] || fail "exported app is missing embedded.mobileprovision"
PROFILE_CMS_SHA256="$(shasum -a 256 "$EMBEDDED_PROFILE" | awk '{print $1}')"
PROFILE_PLIST="$PRIVATE_VERIFICATION_DIR/embedded-profile.plist"
if ! security cms -D -i "$EMBEDDED_PROFILE" -o "$PROFILE_PLIST" \
    >"$PRIVATE_DIAGNOSTICS_DIR/profile-cms-decode.log" 2>&1; then
  fail_build_step "embedded provisioning profile CMS decode"
fi
plutil -lint "$PROFILE_PLIST" >/dev/null

PROFILE_UUID="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$PROFILE_PLIST")"
[[ -n "$PROFILE_UUID" ]] || fail "embedded provisioning profile has no UUID"
PROFILE_EXPIRATION="$(plutil -extract ExpirationDate raw -o - "$PROFILE_PLIST")"
PROFILE_EXPIRATION_EPOCH="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$PROFILE_EXPIRATION" '+%s' 2>/dev/null)" \
  || fail "embedded provisioning profile has an unparseable ExpirationDate: $PROFILE_EXPIRATION"
(( PROFILE_EXPIRATION_EPOCH > $(date -u '+%s') )) \
  || fail "embedded provisioning profile expired at $PROFILE_EXPIRATION"

PROFILE_TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$PROFILE_PLIST")"
[[ "$PROFILE_TEAM_ID" == "$TEAM_ID" ]] \
  || fail "provisioning profile team is $PROFILE_TEAM_ID, expected $TEAM_ID"
PROFILE_ENTITLEMENT_TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' "$PROFILE_PLIST")"
[[ "$PROFILE_ENTITLEMENT_TEAM_ID" == "$TEAM_ID" ]] \
  || fail "provisioning profile entitlement team is $PROFILE_ENTITLEMENT_TEAM_ID, expected $TEAM_ID"
PROFILE_APPLICATION_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$PROFILE_PLIST")"
[[ "$PROFILE_APPLICATION_ID" == "$SIGNED_APPLICATION_ID" ]] \
  || fail "provisioning profile application identifier does not match the signed app"
PROFILE_APS_ENVIRONMENT="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:aps-environment' "$PROFILE_PLIST")"
[[ "$PROFILE_APS_ENVIRONMENT" == "$SIGNED_APS_ENVIRONMENT" ]] \
  || fail "provisioning profile APNs environment does not match the signed app"

PROFILE_GET_TASK_ALLOW="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:get-task-allow' "$PROFILE_PLIST" 2>/dev/null || printf 'false')"
SIGNED_GET_TASK_ALLOW="$(/usr/libexec/PlistBuddy -c 'Print :get-task-allow' "$SIGNED_ENTITLEMENTS" 2>/dev/null || printf 'false')"
[[ "$PROFILE_GET_TASK_ALLOW" == "$SIGNED_GET_TASK_ALLOW" ]] \
  || fail "signed get-task-allow does not match the provisioning profile"
DECODED_PROFILE_CONTAINS_SIGNING_CERTIFICATE=false
PROFILE_DEVELOPER_CERTIFICATE_COUNT=0
PROFILE_CERTIFICATE_DER="$PRIVATE_VERIFICATION_DIR/profile-developer-certificate.der"
while plutil -extract "DeveloperCertificates.$PROFILE_DEVELOPER_CERTIFICATE_COUNT" raw -o - "$PROFILE_PLIST" 2>/dev/null \
    | base64 -D >"$PROFILE_CERTIFICATE_DER" 2>/dev/null; do
  [[ -s "$PROFILE_CERTIFICATE_DER" ]] || fail "the provisioning profile contains an empty developer certificate"
  PROFILE_CERTIFICATE_SHA256="$(shasum -a 256 "$PROFILE_CERTIFICATE_DER" | awk '{print $1}')"
  if [[ "$PROFILE_CERTIFICATE_SHA256" == "$SIGNING_LEAF_CERTIFICATE_SHA256" ]]; then
    DECODED_PROFILE_CONTAINS_SIGNING_CERTIFICATE=true
  fi
  PROFILE_DEVELOPER_CERTIFICATE_COUNT=$((PROFILE_DEVELOPER_CERTIFICATE_COUNT + 1))
done
rm -f "$PROFILE_CERTIFICATE_DER"
(( PROFILE_DEVELOPER_CERTIFICATE_COUNT > 0 )) \
  || fail "the provisioning profile has no developer certificates"
[[ "$DECODED_PROFILE_CONTAINS_SIGNING_CERTIFICATE" == "true" ]] \
  || fail "the decoded embedded provisioning profile does not list the app's signing leaf certificate"
PROFILE_HAS_DEVICES=false
PROFILE_DEVICE_COUNT=0
PROFILE_CONTAINS_TARGET_DEVICE=false
while PROFILE_DEVICE="$(/usr/libexec/PlistBuddy -c "Print :ProvisionedDevices:$PROFILE_DEVICE_COUNT" "$PROFILE_PLIST" 2>/dev/null)"; do
  PROFILE_HAS_DEVICES=true
  PROFILE_DEVICE_CANONICAL="$(printf '%s' "$PROFILE_DEVICE" | LC_ALL=C tr '[:lower:]' '[:upper:]')"
  if [[ -n "$DEVICE_UDID" && "$PROFILE_DEVICE_CANONICAL" == "$DEVICE_UDID" ]]; then
    PROFILE_CONTAINS_TARGET_DEVICE=true
  fi
  PROFILE_DEVICE_COUNT=$((PROFILE_DEVICE_COUNT + 1))
done
PROFILE_ALL_DEVICES="$(/usr/libexec/PlistBuddy -c 'Print :ProvisionsAllDevices' "$PROFILE_PLIST" 2>/dev/null || printf 'false')"

case "$REQUIRED_PROFILE_CLASS" in
  development)
    [[ "$PROFILE_GET_TASK_ALLOW" == "true" && "$PROFILE_HAS_DEVICES" == "true" && "$PROFILE_ALL_DEVICES" != "true" ]] \
      || fail "debugging/development export did not contain a device-bound development profile"
    ;;
  ad-hoc)
    [[ "$PROFILE_GET_TASK_ALLOW" != "true" && "$PROFILE_HAS_DEVICES" == "true" && "$PROFILE_ALL_DEVICES" != "true" ]] \
      || fail "release-testing/ad-hoc export did not contain a device-bound distribution profile"
    ;;
  app-store)
    [[ "$PROFILE_GET_TASK_ALLOW" != "true" && "$PROFILE_HAS_DEVICES" == "false" && "$PROFILE_ALL_DEVICES" != "true" ]] \
      || fail "App Store Connect export did not contain a non-device-bound distribution profile"
    ;;
  enterprise)
    [[ "$PROFILE_GET_TASK_ALLOW" != "true" && "$PROFILE_ALL_DEVICES" == "true" ]] \
      || fail "enterprise export did not contain an all-devices distribution profile"
    ;;
esac
if [[ "$DEVICE_BOUND_PROFILE" == "true" && "$PROFILE_CONTAINS_TARGET_DEVICE" != "true" ]]; then
  fail "the embedded provisioning profile does not contain the exact SENTI_DEVICE_UDID"
fi

HAS_AUDIO_BACKGROUND_MODE=false
HAS_VOIP_BACKGROUND_MODE=false
BACKGROUND_MODE_INDEX=0
while BACKGROUND_MODE="$(/usr/libexec/PlistBuddy -c "Print :UIBackgroundModes:$BACKGROUND_MODE_INDEX" "$APP_PATH/Info.plist" 2>/dev/null)"; do
  case "$BACKGROUND_MODE" in
    audio) HAS_AUDIO_BACKGROUND_MODE=true ;;
    voip) HAS_VOIP_BACKGROUND_MODE=true ;;
  esac
  BACKGROUND_MODE_INDEX=$((BACKGROUND_MODE_INDEX + 1))
done
[[ "$HAS_AUDIO_BACKGROUND_MODE" == "true" ]] || fail "signed app is missing UIBackgroundModes audio"
[[ "$HAS_VOIP_BACKGROUND_MODE" == "true" ]] || fail "signed app is missing UIBackgroundModes voip"

if [[ "$INSTALL_CONNECTED_DEVICE" == "1" ]]; then
  PRIVATE_DEVICE_OUTPUT="$PRIVATE_VERIFICATION_DIR/device-install-result.json"
  if ! xcrun devicectl device install app \
    --device "$DEVICE_UDID" \
    "$APP_PATH" \
    --quiet \
    --json-output "$PRIVATE_DEVICE_OUTPUT" \
    >/dev/null 2>&1; then
    rm -f "$PRIVATE_DEVICE_OUTPUT"
    PRIVATE_DEVICE_OUTPUT=""
    fail "signed-app installation failed; confirm the exact device is connected, unlocked, trusted, and in Developer Mode"
  fi
  rm -f "$PRIVATE_DEVICE_OUTPUT"
  PRIVATE_DEVICE_OUTPUT=""
  DEVICE_INSTALL_COMMAND_SUCCEEDED=true
fi

IPA_BASENAME="$(basename "$IPA_PATH")"
FINAL_IPA_PATH="$FINAL_EXPORT_DIR/$IPA_BASENAME"
[[ ! -e "$FINAL_IPA_PATH" ]] || fail "refusing to overwrite an existing finalized IPA"
mv "$IPA_PATH" "$FINAL_IPA_PATH"
FINAL_IPA_MOVED=true
IPA_PATH="$FINAL_IPA_PATH"
IPA_SHA256="$(shasum -a 256 "$IPA_PATH" | awk '{print $1}')"
IPA_BYTE_COUNT="$(wc -c <"$IPA_PATH" | tr -d '[:space:]')"
BUILD_FINISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
MANIFEST_PLIST="$PRIVATE_VERIFICATION_DIR/IPA_MANIFEST.plist"
MANIFEST_PATH="$RUN_DIR/IPA_MANIFEST.json"

manifest_string() {
  plutil -insert "$1" -string "$2" "$MANIFEST_PLIST"
}

manifest_bool() {
  local value
  case "$2" in
    true|1) value=true ;;
    false|0) value=false ;;
    *) fail "internal manifest boolean is invalid for $1" ;;
  esac
  plutil -insert "$1" -bool "$value" "$MANIFEST_PLIST"
}

manifest_integer() {
  plutil -insert "$1" -integer "$2" "$MANIFEST_PLIST"
}

plutil -create xml1 "$MANIFEST_PLIST"
manifest_string source_sha "$SOURCE_SHA"
manifest_string source_tree "$SOURCE_TREE"
manifest_string archive_script_sha256 "$ARCHIVE_SCRIPT_SHA256"
manifest_string project_spec_sha256 "$PROJECT_SPEC_SHA256"
manifest_string build_started_at "$BUILD_STARTED_AT"
manifest_string build_finished_at "$BUILD_FINISHED_AT"
manifest_string xcode_version "$XCODE_VERSION"
manifest_string xcodegen_version "$XCODEGEN_VERSION"
manifest_string xcodegen_binary_sha256 "$XCODEGEN_BINARY_SHA256"
manifest_string swift_version "$SWIFT_VERSION"
manifest_string iphoneos_sdk_version "$IOS_SDK_VERSION"
manifest_string iphoneos_sdk_build "$IOS_SDK_BUILD"
manifest_string macos_version "$MACOS_VERSION"
manifest_string macos_build "$MACOS_BUILD"
manifest_string bundle_id "$SIGNED_BUNDLE_ID"
manifest_string developer_team_id "$SIGNED_TEAM_ID"
manifest_string application_identifier "$SIGNED_APPLICATION_ID"
manifest_string marketing_version "$SIGNED_MARKETING_VERSION"
manifest_string build_number "$SIGNED_BUILD_NUMBER"
manifest_string export_method "$EXPORT_METHOD"
manifest_string provisioning_profile_class "$REQUIRED_PROFILE_CLASS"
manifest_string provisioning_profile_expiration "$PROFILE_EXPIRATION"
manifest_string provisioning_profile_cms_sha256 "$PROFILE_CMS_SHA256"
manifest_string aps_environment "$SIGNED_APS_ENVIRONMENT"
manifest_bool strict_codesign_verified true
manifest_string signed_architectures "$SIGNED_ARCHITECTURES"
manifest_string signed_minimum_os_version "$SIGNED_MINIMUM_OS_VERSION"
manifest_string signing_leaf_certificate_sha256 "$SIGNING_LEAF_CERTIFICATE_SHA256"
manifest_string signing_leaf_certificate_not_after "$SIGNING_LEAF_CERTIFICATE_NOT_AFTER"
manifest_bool decoded_profile_contains_signing_certificate "$DECODED_PROFILE_CONTAINS_SIGNING_CERTIFICATE"
manifest_integer provisioning_profile_device_count "$PROFILE_DEVICE_COUNT"
manifest_bool provisioning_profile_all_devices "$PROFILE_ALL_DEVICES"
manifest_bool target_device_required "$DEVICE_BOUND_PROFILE"
manifest_string target_device_commitment_salt "$TARGET_DEVICE_COMMITMENT_SALT"
manifest_string target_device_commitment_sha256 "$TARGET_DEVICE_COMMITMENT_SHA256"
manifest_bool decoded_profile_contains_target_device "$PROFILE_CONTAINS_TARGET_DEVICE"
manifest_bool device_registration_requested "$REGISTER_CONNECTED_DEVICE"
manifest_bool device_registration_build_succeeded "$DEVICE_REGISTRATION_BUILD_SUCCEEDED"
manifest_bool device_install_requested "$INSTALL_CONNECTED_DEVICE"
manifest_bool device_install_command_succeeded "$DEVICE_INSTALL_COMMAND_SUCCEEDED"
manifest_string embedded_api_origin "$SIGNED_API_URL"
manifest_string embedded_gateway_origin "$SIGNED_GATEWAY_URL"
manifest_bool embedded_api_origin_matches_requested true
manifest_bool embedded_gateway_origin_matches_requested true
manifest_bool endpoint_liveness_probed false
manifest_bool private_device_artifact "$DEVICE_BOUND_PROFILE"
manifest_bool private_diagnostics_retained "$RETAIN_PRIVATE_DIAGNOSTICS"
manifest_string ipa_sha256 "$IPA_SHA256"
manifest_integer ipa_byte_count "$IPA_BYTE_COUNT"
manifest_string ipa_basename "$IPA_BASENAME"
plutil -convert json -o "$MANIFEST_PATH" "$MANIFEST_PLIST"
plutil -lint "$MANIFEST_PATH" >/dev/null
MANIFEST_SHA256="$(shasum -a 256 "$MANIFEST_PATH" | awk '{print $1}')"
FINALIZATION_COMPLETE=true

printf 'Signed IPA verified.\n'
printf 'IPA: %s\n' "$IPA_PATH"
printf 'SHA-256: %s\n' "$IPA_SHA256"
printf 'Manifest: %s\n' "$MANIFEST_PATH"
printf 'Manifest SHA-256: %s\n' "$MANIFEST_SHA256"
if [[ "$DEVICE_INSTALL_COMMAND_SUCCEEDED" == "true" ]]; then
  printf 'Signed app installation command succeeded for the requested profile-authorized selector; confirm the installed device in Xcode.\n'
fi
