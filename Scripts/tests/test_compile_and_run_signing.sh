#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/compile-and-run-signing.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

write_stub() {
  local path="$1"
  shift
  printf '%s\n' "$*" > "$path"
  chmod +x "$path"
}

make_stubs() {
  local stub_dir="$1"
  mkdir -p "$stub_dir"
  write_stub "$stub_dir/pkill" '#!/usr/bin/env bash
printf "%s\n" "$*" >> "$FIXTURE_DIR/pkill-calls"
exit 0'
  write_stub "$stub_dir/pgrep" '#!/usr/bin/env bash
: > "$FIXTURE_DIR/pgrep-called"
exit 0'
  write_stub "$stub_dir/open" '#!/usr/bin/env bash
: > "$FIXTURE_DIR/open-called"
exit 0'
  write_stub "$stub_dir/swift" '#!/usr/bin/env bash
printf "%s\n" "$*" >> "$FIXTURE_DIR/swift-calls"
printf "SIGNING_MODE=%s\nAPP_IDENTITY=%s\nDEVELOPMENT_TEAM=%s\nCODE_SIGN_IDENTITY=%s\nCODE_SIGN_STYLE=%s\nPROVISIONING_PROFILE=%s\nPROVISIONING_PROFILE_SPECIFIER=%s\n" "${SIGNING_MODE-}" "${APP_IDENTITY-}" "${DEVELOPMENT_TEAM-}" "${CODE_SIGN_IDENTITY-}" "${CODE_SIGN_STYLE-}" "${PROVISIONING_PROFILE-}" "${PROVISIONING_PROFILE_SPECIFIER-}" > "$FIXTURE_DIR/swift-env"
exit 0'
  write_stub "$stub_dir/security" '#!/usr/bin/env bash
: > "$FIXTURE_DIR/security-called"
exit 90'
  write_stub "$stub_dir/codesign" '#!/usr/bin/env bash
: > "$FIXTURE_DIR/codesign-called"
exit 90'
  write_stub "$stub_dir/package_app.sh" '#!/usr/bin/env bash
set -euo pipefail
: > "$FIXTURE_DIR/package-called"
printf "%s\n" "$@" > "$FIXTURE_DIR/package-args"
printf "SIGNING_MODE=%s\nAPP_IDENTITY=%s\nDEVELOPMENT_TEAM=%s\nCODE_SIGN_IDENTITY=%s\nCODE_SIGN_STYLE=%s\nPROVISIONING_PROFILE=%s\nPROVISIONING_PROFILE_SPECIFIER=%s\n" "${SIGNING_MODE-}" "${APP_IDENTITY-}" "${DEVELOPMENT_TEAM-}" "${CODE_SIGN_IDENTITY-}" "${CODE_SIGN_STYLE-}" "${PROVISIONING_PROFILE-}" "${PROVISIONING_PROFILE_SPECIFIER-}" > "$FIXTURE_DIR/package-env"'
}

run_case() {
  local name="$1"
  local expected_status="$2"
  local mode="$3"
  local identity="$4"
  local case_dir="$TEST_DIR/$name"
  local stub_dir="$case_dir/stubs"
  local status
  mkdir -p "$case_dir"
  make_stubs "$stub_dir"

  set +e
  if [[ "$mode" == "unset" ]]; then
    env -i \
      PATH="$stub_dir:/usr/bin:/bin" \
      HOME="$case_dir/home" \
      PACKAGE_APP_SCRIPT="$stub_dir/package_app.sh" \
      FIXTURE_DIR="$case_dir" \
      APP_NAME=Fixture EXECUTABLE_NAME=Fixture \
      APP_IDENTITY="$identity" \
      DEVELOPMENT_TEAM=inherited-team \
      CODE_SIGN_IDENTITY=inherited-identity \
      CODE_SIGN_STYLE=Automatic \
      PROVISIONING_PROFILE=inherited-profile \
      PROVISIONING_PROFILE_SPECIFIER=inherited-specifier \
      "$ROOT/Scripts/compile_and_run.sh" --test > "$case_dir/output" 2>&1
    status=$?
  else
    env -i \
      PATH="$stub_dir:/usr/bin:/bin" \
      HOME="$case_dir/home" \
      PACKAGE_APP_SCRIPT="$stub_dir/package_app.sh" \
      FIXTURE_DIR="$case_dir" \
      APP_NAME=Fixture EXECUTABLE_NAME=Fixture \
      SIGNING_MODE="$mode" APP_IDENTITY="$identity" \
      DEVELOPMENT_TEAM=inherited-team \
      CODE_SIGN_IDENTITY=inherited-identity \
      CODE_SIGN_STYLE=Automatic \
      PROVISIONING_PROFILE=inherited-profile \
      PROVISIONING_PROFILE_SPECIFIER=inherited-specifier \
      "$ROOT/Scripts/compile_and_run.sh" --test > "$case_dir/output" 2>&1
    status=$?
  fi
  set -e
  [[ "$status" == "$expected_status" ]] || {
    cat "$case_dir/output" >&2
    fail "$name returned $status, expected $expected_status"
  }
}

assert_package_env() {
  local case_dir="$1"
  local expected_mode="$2"
  local expected_identity="$3"
  [[ -e "$case_dir/package-called" ]] || fail "package was not called for $case_dir"
  grep -Fxq "SIGNING_MODE=$expected_mode" "$case_dir/package-env" \
    || fail "package signing mode mismatch for $case_dir"
  grep -Fxq "APP_IDENTITY=$expected_identity" "$case_dir/package-env" \
    || fail "package identity mismatch for $case_dir"
  grep -Fxq 'DEVELOPMENT_TEAM=' "$case_dir/package-env" \
    || fail "package inherited team for $case_dir"
  grep -Fxq 'CODE_SIGN_IDENTITY=' "$case_dir/package-env" \
    || fail "package inherited identity for $case_dir"
  grep -Fxq 'CODE_SIGN_STYLE=' "$case_dir/package-env" \
    || fail "package inherited style for $case_dir"
  grep -Fxq 'PROVISIONING_PROFILE=' "$case_dir/package-env" \
    || fail "package inherited profile for $case_dir"
  grep -Fxq 'PROVISIONING_PROFILE_SPECIFIER=' "$case_dir/package-env" \
    || fail "package inherited profile specifier for $case_dir"
  [[ "$(<"$case_dir/package-args")" == release ]] \
    || fail "package mode argument mismatch for $case_dir"
  [[ "$(wc -l < "$case_dir/swift-calls" | tr -d ' ')" == 1 ]] \
    || fail "swift test was not reached exactly once for $case_dir"
  grep -Fxq 'SIGNING_MODE=adhoc' "$case_dir/swift-env" \
    || fail "swift test signing mode was not ad-hoc for $case_dir"
  grep -Fxq 'APP_IDENTITY=' "$case_dir/swift-env" \
    || fail "swift test inherited identity for $case_dir"
  grep -Fxq 'DEVELOPMENT_TEAM=' "$case_dir/swift-env" \
    || fail "swift test inherited team for $case_dir"
  grep -Fxq 'CODE_SIGN_IDENTITY=' "$case_dir/swift-env" \
    || fail "swift test inherited identity variable for $case_dir"
  grep -Fxq 'CODE_SIGN_STYLE=' "$case_dir/swift-env" \
    || fail "swift test inherited style for $case_dir"
  grep -Fxq 'PROVISIONING_PROFILE=' "$case_dir/swift-env" \
    || fail "swift test inherited profile for $case_dir"
  grep -Fxq 'PROVISIONING_PROFILE_SPECIFIER=' "$case_dir/swift-env" \
    || fail "swift test inherited profile specifier for $case_dir"
  [[ ! -e "$case_dir/security-called" && ! -e "$case_dir/codesign-called" ]] \
    || fail "keychain/signing tool was invoked for $case_dir"
}

run_case unset 0 unset inherited-app
assert_package_env "$TEST_DIR/unset" adhoc ""

run_case empty 0 "" inherited-app
assert_package_env "$TEST_DIR/empty" adhoc ""

run_case adhoc 0 adhoc inherited-app
assert_package_env "$TEST_DIR/adhoc" adhoc ""

run_case developer-id 0 developer-id "Developer ID Application: Fixture"
assert_package_env "$TEST_DIR/developer-id" developer-id "Developer ID Application: Fixture"

run_case unknown 1 unknown inherited-app
grep -Fq 'Unsupported SIGNING_MODE: unknown' "$TEST_DIR/unknown/output" \
  || fail "unknown mode error missing"
[[ ! -e "$TEST_DIR/unknown/swift-calls" && ! -e "$TEST_DIR/unknown/package-called" \
  && ! -e "$TEST_DIR/unknown/pkill-calls" ]] \
  || fail "unknown mode reached a build/package/process phase"

run_case missing-identity 1 developer-id ""
grep -Fq 'requires a non-empty APP_IDENTITY' "$TEST_DIR/missing-identity/output" \
  || fail "missing identity error missing"
[[ ! -e "$TEST_DIR/missing-identity/swift-calls" \
  && ! -e "$TEST_DIR/missing-identity/package-called" \
  && ! -e "$TEST_DIR/missing-identity/pkill-calls" ]] \
  || fail "missing identity reached a build/package/process phase"

echo "PASS: compile_and_run signing fixtures"
