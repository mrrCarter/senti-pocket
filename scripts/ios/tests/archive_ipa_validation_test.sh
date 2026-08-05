#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVE_SCRIPT="$(cd "$SCRIPT_DIR/.." && pwd)/archive_ipa.sh"
PASS_COUNT=0

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
    export SENTI_IPA_OUTPUT_DIR="/tmp/senti-pocket-archive-validation"

    while (( $# > 0 )); do
      variable="$1"
      value="$2"
      shift 2
      export "$variable=$value"
    done

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
  local output
  local status
  shift

  set +e
  output="$(invoke_validation "$@" 2>&1)"
  status=$?
  set -e

  if (( status != 0 )); then
    printf 'FAIL %s: valid input was rejected:\n%s\n' "$name" "$output" >&2
    exit 1
  fi
  if ! grep -Fq "input syntax validation passed" <<<"$output"; then
    printf 'FAIL %s: validation-only success marker was absent\n' "$name" >&2
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
run_rejection build-number "must be a positive integer" \
  SENTI_BUILD_NUMBER "0"
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

run_acceptance modern-udid-and-dns
run_acceptance legacy-udid \
  SENTI_DEVICE_UDID "0123456789abcdef0123456789abcdef01234567"
run_acceptance public-ipv4-and-port \
  SENTI_API_URL "https://8.8.8.8:443"

printf 'archive_ipa_validation_test: %d acceptance/rejection vectors passed\n' "$PASS_COUNT"
