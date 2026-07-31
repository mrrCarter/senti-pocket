#!/usr/bin/env bash
set -euo pipefail

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
  local port=""
  [[ "$value" =~ ^https://[^/?#[:space:]]+/?$ ]] \
    || fail "$name must be an HTTPS origin with no path, query, fragment, or whitespace"
  [[ "$value" != *"@"* && "$value" != *"%"* && "$value" != *"\\"* ]] \
    || fail "$name must not contain userinfo, percent-encoded host text, or backslashes"
  if printf '%s' "$value" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    fail "$name must not contain control characters"
  fi

  authority="${value#https://}"
  authority="${authority%/}"
  if [[ "$authority" =~ ^\[[^]]+\]:([0-9]+)$ ]]; then
    port="${BASH_REMATCH[1]}"
  elif [[ "$authority" =~ ^[^:]+:([0-9]+)$ ]]; then
    port="${BASH_REMATCH[1]}"
  elif [[ "$authority" == *:* && ! "$authority" =~ ^\[[^]]+\]$ ]]; then
    fail "$name contains an invalid port or unbracketed IPv6 host"
  fi
  if [[ -n "$port" ]] && (( port < 1 || port > 65535 )); then
    fail "$name port must be between 1 and 65535"
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCHEME="SentiPocketApp"

TEAM_ID="${SENTI_APPLE_TEAM_ID:-}"
BUNDLE_ID="${SENTI_BUNDLE_ID:-com.plexaura.sentipocket.app}"
API_URL="${SENTI_API_URL:-}"
GATEWAY_URL="${SENTI_GATEWAY_URL:-}"
MARKETING_VERSION="${SENTI_MARKETING_VERSION:-0.1.0}"
BUILD_NUMBER="${SENTI_BUILD_NUMBER:-1}"
OUTPUT_ROOT="${SENTI_IPA_OUTPUT_DIR:-$REPO_ROOT/build/ios}"

[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] \
  || fail "SENTI_APPLE_TEAM_ID must be the 10-character Developer Program Team ID"
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9.-]+$ ]] \
  || fail "SENTI_BUNDLE_ID is not a valid reverse-DNS bundle identifier"
[[ "$MARKETING_VERSION" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] \
  || fail "SENTI_MARKETING_VERSION must look like 0.1 or 0.1.0"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] \
  || fail "SENTI_BUILD_NUMBER must be a positive integer"
require_https_origin "SENTI_API_URL" "$API_URL"
require_https_origin "SENTI_GATEWAY_URL" "$GATEWAY_URL"

require_command xcodebuild
require_command xcodegen
require_command codesign
require_command ditto
require_command plutil
require_command shasum
require_command unzip
[[ -x /usr/libexec/PlistBuddy ]] || fail "/usr/libexec/PlistBuddy is unavailable"

[[ -z "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=normal)" ]] \
  || fail "the Git worktree must be clean so the IPA can be attributed to an exact commit"

if [[ -n "${SENTI_EXPORT_METHOD:-}" ]]; then
  EXPORT_METHOD="$SENTI_EXPORT_METHOD"
else
  XCODEBUILD_HELP="$(xcodebuild -help 2>&1 || true)"
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
    ;;
  release-testing|ad-hoc|app-store-connect|app-store|enterprise)
    REQUIRED_APS_ENVIRONMENT="production"
    ;;
  *)
    fail "unsupported iOS IPA export method: $EXPORT_METHOD"
    ;;
esac
if [[ -n "${SENTI_APS_ENVIRONMENT:-}" && "$SENTI_APS_ENVIRONMENT" != "$REQUIRED_APS_ENVIRONMENT" ]]; then
  fail "SENTI_APS_ENVIRONMENT conflicts with export method $EXPORT_METHOD (requires $REQUIRED_APS_ENVIRONMENT)"
fi
APS_ENVIRONMENT="$REQUIRED_APS_ENVIRONMENT"

SOURCE_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
SOURCE_TREE="$(git -C "$REPO_ROOT" rev-parse 'HEAD^{tree}')"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-${SOURCE_SHA:0:12}-$$"
RUN_DIR="$OUTPUT_ROOT/$RUN_ID"
SOURCE_ROOT="$RUN_DIR/source"
APP_DIR="$SOURCE_ROOT/apps/SentiPocketApp"
PROJECT_PATH="$APP_DIR/SentiPocketApp.xcodeproj"
ARCHIVE_PATH="$RUN_DIR/SentiPocketApp.xcarchive"
EXPORT_DIR="$RUN_DIR/export"
DERIVED_DATA="$RUN_DIR/DerivedData"
SOURCE_PACKAGES="$OUTPUT_ROOT/SourcePackages"
EXPORT_OPTIONS="$RUN_DIR/ExportOptions.plist"
VERIFY_DIR="$RUN_DIR/verify"

mkdir -p "$RUN_DIR" "$EXPORT_DIR" "$SOURCE_PACKAGES" "$VERIFY_DIR"

WORKTREE_ADDED=false
cleanup_worktree() {
  if [[ "$WORKTREE_ADDED" == "true" ]]; then
    git -C "$REPO_ROOT" worktree remove --force "$SOURCE_ROOT" >/dev/null 2>&1 || true
  fi
}
trap cleanup_worktree EXIT

# Build only tracked bytes from the recorded commit. The developer checkout may contain ignored model weights
# (for example Resources/ggml-base.en.bin); a detached worktree prevents those bytes from entering a mislabeled IPA.
git -C "$REPO_ROOT" worktree add --detach "$SOURCE_ROOT" "$SOURCE_SHA" \
  | tee "$RUN_DIR/worktree.log"
WORKTREE_ADDED=true

(
  cd "$APP_DIR"
  xcodegen generate
)
[[ -d "$PROJECT_PATH" ]] || fail "XcodeGen did not create $PROJECT_PATH"

xcodebuild \
  -resolvePackageDependencies \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
  | tee "$RUN_DIR/resolve-packages.log"

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

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
  -allowProvisioningUpdates \
  "${COMMON_BUILD_SETTINGS[@]}" \
  archive \
  | tee "$RUN_DIR/archive.log"

[[ -d "$ARCHIVE_PATH" ]] || fail "xcodebuild reported success without creating the archive"

cp "$APP_DIR/ExportOptions.example.plist" "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c "Set :method $EXPORT_METHOD" "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c "Set :teamID $TEAM_ID" "$EXPORT_OPTIONS"
plutil -lint "$EXPORT_OPTIONS" >/dev/null

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates \
  | tee "$RUN_DIR/export.log"

IPA_COUNT="$(find "$EXPORT_DIR" -maxdepth 1 -type f -name '*.ipa' | wc -l | tr -d '[:space:]')"
[[ "$IPA_COUNT" == "1" ]] || fail "expected exactly one exported IPA, found $IPA_COUNT"
IPA_PATH="$(find "$EXPORT_DIR" -maxdepth 1 -type f -name '*.ipa' -print -quit)"
unzip -tq "$IPA_PATH" >/dev/null
ditto -x -k "$IPA_PATH" "$VERIFY_DIR"

APP_PATH="$(find "$VERIFY_DIR/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
[[ -n "$APP_PATH" ]] || fail "the IPA does not contain a Payload/*.app bundle"
codesign --verify --deep --strict "$APP_PATH"

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

SIGNED_ENTITLEMENTS="$RUN_DIR/signed-entitlements.plist"
codesign -d --entitlements :- "$APP_PATH" >"$SIGNED_ENTITLEMENTS" 2>/dev/null
plutil -lint "$SIGNED_ENTITLEMENTS" >/dev/null
SIGNED_APS_ENVIRONMENT="$(/usr/libexec/PlistBuddy -c 'Print :aps-environment' "$SIGNED_ENTITLEMENTS")"
[[ "$SIGNED_APS_ENVIRONMENT" == "$APS_ENVIRONMENT" ]] \
  || fail "signed aps-environment is $SIGNED_APS_ENVIRONMENT, expected $APS_ENVIRONMENT"

BACKGROUND_MODES="$(/usr/libexec/PlistBuddy -c 'Print :UIBackgroundModes' "$APP_PATH/Info.plist")"
grep -q 'audio' <<<"$BACKGROUND_MODES" || fail "signed app is missing UIBackgroundModes audio"
grep -q 'voip' <<<"$BACKGROUND_MODES" || fail "signed app is missing UIBackgroundModes voip"

IPA_SHA256="$(shasum -a 256 "$IPA_PATH" | awk '{print $1}')"
MANIFEST_PATH="$RUN_DIR/IPA_MANIFEST.txt"
{
  printf 'source_sha=%s\n' "$SOURCE_SHA"
  printf 'source_tree=%s\n' "$SOURCE_TREE"
  printf 'bundle_id=%s\n' "$SIGNED_BUNDLE_ID"
  printf 'marketing_version=%s\n' "$SIGNED_MARKETING_VERSION"
  printf 'build_number=%s\n' "$SIGNED_BUILD_NUMBER"
  printf 'release_origins_verified=true\n'
  printf 'export_method=%s\n' "$EXPORT_METHOD"
  printf 'aps_environment=%s\n' "$SIGNED_APS_ENVIRONMENT"
  printf 'ipa_sha256=%s\n' "$IPA_SHA256"
  printf 'ipa_path=%s\n' "$IPA_PATH"
} >"$MANIFEST_PATH"

printf 'Signed IPA verified.\n'
printf 'IPA: %s\n' "$IPA_PATH"
printf 'SHA-256: %s\n' "$IPA_SHA256"
printf 'Manifest: %s\n' "$MANIFEST_PATH"
