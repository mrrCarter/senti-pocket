#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVE_SCRIPT="$(cd "$SCRIPT_DIR/.." && pwd)/archive_ipa.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
VALIDATION_OUTPUT_ROOT="/tmp/senti-pocket-archive-validation-$$"
INITIAL_WORKTREE_STATE=""
WORKTREE_STATE_CHECK_AVAILABLE=false
if INITIAL_WORKTREE_STATE="$(git -C "$REPO_ROOT" status --porcelain=v1 --untracked-files=all 2>/dev/null)"; then
  WORKTREE_STATE_CHECK_AVAILABLE=true
fi
PASS_COUNT=0

POLICY_DEBUGGING='export_method=debugging; aps_environment=development; profile_class=development; device_bound=true'
POLICY_DEVELOPMENT='export_method=development; aps_environment=development; profile_class=development; device_bound=true'
POLICY_RELEASE_TESTING='export_method=release-testing; aps_environment=production; profile_class=ad-hoc; device_bound=true'
POLICY_AD_HOC='export_method=ad-hoc; aps_environment=production; profile_class=ad-hoc; device_bound=true'
POLICY_APP_STORE_CONNECT='export_method=app-store-connect; aps_environment=production; profile_class=app-store; device_bound=false'
POLICY_APP_STORE='export_method=app-store; aps_environment=production; profile_class=app-store; device_bound=false'
POLICY_ENTERPRISE='export_method=enterprise; aps_environment=production; profile_class=enterprise; device_bound=false'

[[ ! -e "$VALIDATION_OUTPUT_ROOT" ]] \
  || { printf 'FAIL validation output sentinel already exists: %s\n' "$VALIDATION_OUTPUT_ROOT" >&2; exit 1; }

invoke_validation() {
  local variable
  local value
  (
    unset \
      SENTI_APS_ENVIRONMENT \
      SENTI_EXPORT_METHOD \
      SENTI_RETAIN_PRIVATE_DIAGNOSTICS
    export SENTI_APPLE_TEAM_ID="ABCDEFGHIJ"
    export SENTI_BUNDLE_ID="com.plexaura.sentipocket.app"
    export SENTI_API_URL="https://api.plexaura.dev"
    export SENTI_GATEWAY_URL="https://gateway.plexaura.dev"
    export SENTI_DEVICE_UDID="00008110-0012345678901234"
    export SENTI_REGISTER_CONNECTED_DEVICE="0"
    export SENTI_INSTALL_CONNECTED_DEVICE="0"
    export SENTI_MARKETING_VERSION="0.1.0"
    export SENTI_BUILD_NUMBER="1"
    export SENTI_IPA_OUTPUT_DIR="$VALIDATION_OUTPUT_ROOT"

    while (( $# > 0 )); do
      variable="$1"
      value="$2"
      shift 2
      export "$variable=$value"
    done

    poison_external_command() {
      printf 'unexpected build or stateful command during validation: %s\n' "$1" >&2
      return 97
    }
    xcodebuild() { poison_external_command xcodebuild; }
    xcodegen() { poison_external_command xcodegen; }
    codesign() { poison_external_command codesign; }
    openssl() { poison_external_command openssl; }
    security() { poison_external_command security; }
    ditto() { poison_external_command ditto; }
    plutil() { poison_external_command plutil; }
    xcrun() { poison_external_command xcrun; }
    git() { poison_external_command git; }
    mkdir() { poison_external_command mkdir; }
    cp() { poison_external_command cp; }
    mv() { poison_external_command mv; }
    rm() { poison_external_command rm; }
    export -f \
      poison_external_command \
      xcodebuild \
      xcodegen \
      codesign \
      openssl \
      security \
      ditto \
      plutil \
      xcrun \
      git \
      mkdir \
      cp \
      mv \
      rm

    "$ARCHIVE_SCRIPT" --validate-inputs-only
  )
}

run_rejection() {
  local name="$1"
  local expected="$2"
  local output
  local status
  shift 2

  set +e
  output="$(invoke_validation "$@" 2>&1)"
  status=$?
  set -e

  if (( status == 0 )); then
    printf 'FAIL %s: archive unexpectedly succeeded\n' "$name" >&2
    exit 1
  fi
  if ! grep -Fq "$expected" <<<"$output"; then
    printf 'FAIL %s: expected %q in output, got:\n%s\n' "$name" "$expected" "$output" >&2
    exit 1
  fi
  PASS_COUNT=$((PASS_COUNT + 1))
}

run_acceptance() {
  local name="$1"
  local expected_policy="$2"
  local expected_output
  local output
  local status
  shift 2

  expected_output="archive_ipa: input and export-policy validation passed; $expected_policy; no build or external action was performed"

  set +e
  output="$(invoke_validation "$@" 2>&1)"
  status=$?
  set -e

  if (( status != 0 )); then
    printf 'FAIL %s: valid input was rejected:\n%s\n' "$name" "$output" >&2
    exit 1
  fi
  if [[ "$output" != "$expected_output" ]]; then
    printf 'FAIL %s: expected exact output:\n%s\ngot:\n%s\n' "$name" "$expected_output" "$output" >&2
    exit 1
  fi
  PASS_COUNT=$((PASS_COUNT + 1))
}

run_rejection team-id "10-character Developer Program Team ID" \
  SENTI_APPLE_TEAM_ID "short"
run_rejection bundle-id "valid reverse-DNS bundle identifier" \
  SENTI_BUNDLE_ID 'com.plexaura.$(HOME)'
run_rejection marketing-version "must look like 0.1 or 0.1.0" \
  SENTI_MARKETING_VERSION "1.2.3.4"
run_rejection build-number-zero "must be a positive integer" \
  SENTI_BUILD_NUMBER "0"
run_rejection build-number-leading-zero "must be a positive integer" \
  SENTI_BUILD_NUMBER "01"
run_rejection build-number-dotted "must be a positive integer" \
  SENTI_BUILD_NUMBER "1.2"
run_rejection http-origin "must be an HTTPS origin" \
  SENTI_API_URL "http://api.plexaura.dev"
run_rejection origin-query "must be an HTTPS origin" \
  SENTI_GATEWAY_URL "https://gateway.plexaura.dev/?token=forged"
run_rejection origin-command-syntax "must use an ASCII DNS or IPv4 host" \
  SENTI_API_URL 'https://$(HOME)'
run_rejection malformed-ipv6 "must use an ASCII DNS or IPv4 host" \
  SENTI_API_URL "https://[:::]"
run_rejection malformed-ipv4 "contains an invalid IPv4 address" \
  SENTI_API_URL "https://999.999.999.999"
run_rejection ambiguous-ipv4 "ambiguous leading-zero IPv4 address" \
  SENTI_API_URL "https://012.0.0.1"
run_rejection private-ipv4 "private, loopback, or reserved IP address" \
  SENTI_API_URL "https://10.0.0.1"
run_rejection shared-ipv4 "private, loopback, or reserved IP address" \
  SENTI_API_URL "https://100.64.0.1"
run_rejection benchmark-ipv4 "private, loopback, or reserved IP address" \
  SENTI_API_URL "https://198.18.0.1"
run_rejection reserved-host "reserved documentation/test host" \
  SENTI_API_URL "https://api.example.com"
run_rejection invalid-port "port must be between 1 and 65535" \
  SENTI_API_URL "https://api.plexaura.dev:65536"
run_rejection registration-flag "must be exactly 0 or 1" \
  SENTI_REGISTER_CONNECTED_DEVICE "yes"
run_rejection installation-flag "must be exactly 0 or 1" \
  SENTI_INSTALL_CONNECTED_DEVICE "2"
run_rejection modern-udid-near-miss "physical-device provisioning UDID" \
  SENTI_DEVICE_UDID "00008110-00123456789012345"
run_rejection simulator-uuid "physical-device provisioning UDID" \
  SENTI_DEVICE_UDID "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
run_rejection relative-output-root "absolute path below a named directory" \
  SENTI_IPA_OUTPUT_DIR "relative/build"
run_rejection filesystem-root "absolute path below a named directory" \
  SENTI_IPA_OUTPUT_DIR "/"
run_rejection newline-output-root "must not contain control characters" \
  SENTI_IPA_OUTPUT_DIR $'/tmp/senti-pocket\nforged'

run_rejection export-method-unknown "unsupported iOS IPA export method" \
  SENTI_EXPORT_METHOD "not-a-method"
run_rejection export-method-characters "contains unsupported characters" \
  SENTI_EXPORT_METHOD 'debugging;echo-forged'
run_rejection development-aps-conflict "requires development" \
  SENTI_EXPORT_METHOD "debugging" \
  SENTI_APS_ENVIRONMENT "production"
run_rejection production-aps-conflict "requires production" \
  SENTI_EXPORT_METHOD "app-store-connect" \
  SENTI_APS_ENVIRONMENT "development" \
  SENTI_DEVICE_UDID ""
run_rejection development-missing-udid "required for a device-bound development export" \
  SENTI_EXPORT_METHOD "development" \
  SENTI_DEVICE_UDID ""
run_rejection ad-hoc-missing-udid "required for a device-bound ad-hoc export" \
  SENTI_EXPORT_METHOD "ad-hoc" \
  SENTI_DEVICE_UDID ""
run_rejection app-store-device-selector "connected-device attribution is supported only" \
  SENTI_EXPORT_METHOD "app-store-connect"
run_rejection app-store-registration "connected-device attribution is supported only" \
  SENTI_EXPORT_METHOD "app-store" \
  SENTI_DEVICE_UDID "" \
  SENTI_REGISTER_CONNECTED_DEVICE "1"
run_rejection enterprise-installation "connected-device attribution is supported only" \
  SENTI_EXPORT_METHOD "enterprise" \
  SENTI_DEVICE_UDID "" \
  SENTI_INSTALL_CONNECTED_DEVICE "1"
run_rejection ad-hoc-registration "supported only for debugging/development exports" \
  SENTI_EXPORT_METHOD "release-testing" \
  SENTI_REGISTER_CONNECTED_DEVICE "1"

run_acceptance implicit-debugging-modern-udid-and-dns "$POLICY_DEBUGGING"
run_acceptance legacy-udid \
  "$POLICY_DEBUGGING" \
  SENTI_DEVICE_UDID "0123456789abcdef0123456789abcdef01234567"
run_acceptance public-ipv4-and-port \
  "$POLICY_DEBUGGING" \
  SENTI_API_URL "https://8.8.8.8:443"
run_acceptance five-digit-build-number \
  "$POLICY_DEBUGGING" \
  SENTI_BUILD_NUMBER "10000"
run_acceptance debugging-registration \
  "$POLICY_DEBUGGING" \
  SENTI_EXPORT_METHOD "debugging" \
  SENTI_APS_ENVIRONMENT "development" \
  SENTI_REGISTER_CONNECTED_DEVICE "1"
run_acceptance debugging-installation \
  "$POLICY_DEBUGGING" \
  SENTI_EXPORT_METHOD "debugging" \
  SENTI_APS_ENVIRONMENT "development" \
  SENTI_INSTALL_CONNECTED_DEVICE "1"
run_acceptance legacy-development-development-aps \
  "$POLICY_DEVELOPMENT" \
  SENTI_EXPORT_METHOD "development" \
  SENTI_APS_ENVIRONMENT "development"
run_acceptance release-testing-production-aps \
  "$POLICY_RELEASE_TESTING" \
  SENTI_EXPORT_METHOD "release-testing" \
  SENTI_APS_ENVIRONMENT "production"
run_acceptance release-testing-installation \
  "$POLICY_RELEASE_TESTING" \
  SENTI_EXPORT_METHOD "release-testing" \
  SENTI_APS_ENVIRONMENT "production" \
  SENTI_INSTALL_CONNECTED_DEVICE "1"
run_acceptance legacy-ad-hoc-production-aps \
  "$POLICY_AD_HOC" \
  SENTI_EXPORT_METHOD "ad-hoc" \
  SENTI_APS_ENVIRONMENT "production"
run_acceptance app-store-connect-production-aps \
  "$POLICY_APP_STORE_CONNECT" \
  SENTI_EXPORT_METHOD "app-store-connect" \
  SENTI_APS_ENVIRONMENT "production" \
  SENTI_DEVICE_UDID ""
run_acceptance legacy-app-store-production-aps \
  "$POLICY_APP_STORE" \
  SENTI_EXPORT_METHOD "app-store" \
  SENTI_APS_ENVIRONMENT "production" \
  SENTI_DEVICE_UDID ""
run_acceptance enterprise-production-aps \
  "$POLICY_ENTERPRISE" \
  SENTI_EXPORT_METHOD "enterprise" \
  SENTI_APS_ENVIRONMENT "production" \
  SENTI_DEVICE_UDID ""
run_acceptance private-diagnostics-flag \
  "$POLICY_DEBUGGING" \
  SENTI_RETAIN_PRIVATE_DIAGNOSTICS "1"

[[ ! -e "$VALIDATION_OUTPUT_ROOT" ]] \
  || { printf 'FAIL validation-only mode created its output directory: %s\n' "$VALIDATION_OUTPUT_ROOT" >&2; exit 1; }
if [[ "$WORKTREE_STATE_CHECK_AVAILABLE" == "true" ]]; then
  FINAL_WORKTREE_STATE="$(git -C "$REPO_ROOT" status --porcelain=v1 --untracked-files=all)"
  [[ "$FINAL_WORKTREE_STATE" == "$INITIAL_WORKTREE_STATE" ]] \
    || { printf 'FAIL validation-only mode changed the Git worktree\n' >&2; exit 1; }
fi

CANONICAL_SWIFT_RESPONSE_SETTING='SWIFT_RESPONSE_FILE_PATH=$(SWIFT_RESPONSE_FILE_PATH_$(variant)_$(arch))'
grep -Fq "'$CANONICAL_SWIFT_RESPONSE_SETTING'" "$ARCHIVE_SCRIPT" \
  || { printf 'FAIL archive does not pin the canonical Swift response-file expansion\n' >&2; exit 1; }
if grep -Fq '"SWIFT_RESPONSE_FILE_PATH="' "$ARCHIVE_SCRIPT"; then
  printf 'FAIL archive suppresses Xcode Swift response-file expansion\n' >&2
  exit 1
fi
PASS_COUNT=$((PASS_COUNT + 1))

grep -Fq '"PRODUCT_SPECIFIC_LDFLAGS="' "$ARCHIVE_SCRIPT" \
  || { printf 'FAIL archive does not pin product-specific linker flags empty\n' >&2; exit 1; }
if grep -Fq 'PRODUCT_SPECIFIC_LDFLAGS=$(inherited)' "$ARCHIVE_SCRIPT"; then
  printf 'FAIL archive inherits unreviewed product-specific linker flags\n' >&2
  exit 1
fi
PASS_COUNT=$((PASS_COUNT + 1))

printf 'archive_ipa_validation_test: %d acceptance/rejection vectors passed\n' "$PASS_COUNT"
