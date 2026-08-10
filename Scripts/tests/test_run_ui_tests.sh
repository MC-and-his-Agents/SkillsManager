#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
TEST_DIR=$(mktemp -d)
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

  write_stub "$stub_dir/swift" '#!/usr/bin/env bash
set -euo pipefail
scratch=""
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == "--scratch-path" ]]; then
    j=$((i + 1))
    scratch="${!j}"
  fi
done
[[ -n "$scratch" ]] || exit 1
mkdir -p "$scratch/bin"
: > "$scratch/bin/SkillsManager"
if [[ " $* " == *" --show-bin-path "* ]]; then
  printf "%s\n" "$scratch/bin"
fi'

  write_stub "$stub_dir/strings" '#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == *swiftpm-ui/* ]]; then
  printf "%s\\n" --skillsmanager-ui-fixture SKILLS_MANAGER_UI_TEST_ROOT SKILLS_MANAGER_UI_TEST_HOME SkillsManagerUITestFixtureEnabled
fi'

  write_stub "$stub_dir/package_app.sh" '#!/usr/bin/env bash
set -euo pipefail
: "${FIXTURE_DIR:?}"
printf "SIGNING_MODE=%s\\nAPP_IDENTITY=%s\\nDEVELOPMENT_TEAM=%s\\nCODE_SIGN_IDENTITY=%s\\nCODE_SIGN_STYLE=%s\\nPROVISIONING_PROFILE=%s\\nPROVISIONING_PROFILE_SPECIFIER=%s\\n" \
  "${SIGNING_MODE-}" "${APP_IDENTITY-}" "${DEVELOPMENT_TEAM-}" "${CODE_SIGN_IDENTITY-}" \
  "${CODE_SIGN_STYLE-}" "${PROVISIONING_PROFILE-}" "${PROVISIONING_PROFILE_SPECIFIER-}" \
  > "$FIXTURE_DIR/package-env"
if [[ "${FIXTURE_MODE:-}" == build ]]; then
  exit 41
fi
mkdir -p "$APP_OUTPUT_DIR/SkillsManagerUITest.app/Contents/MacOS"
: > "$APP_OUTPUT_DIR/SkillsManagerUITest.app/Contents/MacOS/SkillsManager"
chmod +x "$APP_OUTPUT_DIR/SkillsManagerUITest.app/Contents/MacOS/SkillsManager"'

  write_stub "$stub_dir/xcodebuild" '#!/usr/bin/env bash
set -euo pipefail
: "${FIXTURE_DIR:?}"
if [[ "${1:-}" == build-for-testing ]]; then
  printf "DEVELOPMENT_TEAM=%s\\nCODE_SIGN_IDENTITY=%s\\nCODE_SIGN_STYLE=%s\\nPROVISIONING_PROFILE=%s\\nPROVISIONING_PROFILE_SPECIFIER=%s\\n" \
    "${DEVELOPMENT_TEAM-}" "${CODE_SIGN_IDENTITY-}" "${CODE_SIGN_STYLE-}" \
    "${PROVISIONING_PROFILE-}" "${PROVISIONING_PROFILE_SPECIFIER-}" > "$FIXTURE_DIR/xcodebuild-env"
  if [[ "${FIXTURE_MODE:-}" == build ]]; then exit 42; fi
  derived=""
  for ((i = 1; i <= $#; i++)); do
    if [[ "${!i}" == -derivedDataPath ]]; then
      j=$((i + 1)); derived="${!j}"
    fi
  done
  mkdir -p "$derived/Build/Products"
  : > "$derived/Build/Products/SkillsManagerUITests.xctestrun"
  exit 0
fi
if [[ "${1:-}" == test-without-building ]]; then
  count_file="$FIXTURE_DIR/invocations"
  count=0
  [[ -f "$count_file" ]] && count=$(<"$count_file")
  count=$((count + 1))
  printf "%s\n" "$count" > "$count_file"
  result=""
  for ((i = 1; i <= $#; i++)); do
    if [[ "${!i}" == -resultBundlePath ]]; then
      j=$((i + 1)); result="${!j}"
    fi
  done
  mkdir -p "$result"
  case "${FIXTURE_MODE:-}" in
    assertion)
      : > "$result/started"
      printf "%s\\n" "Test Case '-[FixtureTests testAssertion]' failed" "XCTAssertTrue failed"; exit 65 ;;
    runner|runner-real)
      if [[ "$count" == 1 ]]; then
        : > "$result/zero"
        printf "%s\\n" "Timed out while enabling automation mode" "XCTFuture Code=1000"; exit 65
      fi
      : > "$result/started"
      printf "%s\\n" "Test Case '-[FixtureTests testRunner]' passed"; exit 0 ;;
    unknown)
      : > "$result/zero"
      printf "%s\\n" "runner failed for an unknown reason"; exit 65 ;;
    invalid)
      : > "$result/invalid"
      printf "%s\\n" "Timed out while enabling automation mode"; exit 65 ;;
    *)
      exit 43 ;;
  esac
fi
exit 44'

  write_stub "$stub_dir/xcrun" '#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != xcresulttool ]]; then exit 1; fi
result=""
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == --path ]]; then
    j=$((i + 1)); result="${!j}"
  fi
done
if [[ -f "$result/started" ]]; then
  printf "%s\n" "{\"testsCount\":1,\"testIdentifier\":\"FixtureTests/test\"}"
elif [[ -f "$result/zero" ]]; then
  if [[ "${FIXTURE_MODE:-}" == runner-real ]]; then
    printf "%s\n" "{\"totalTestCount\":1,\"failedTests\":1,\"testFailures\":[{\"testIdentifier\":1,\"testIdentifierString\":\"SkillsManagerUITests-Runner (1) encountered an error\",\"testName\":\"SkillsManagerUITests-Runner (1) encountered an error\"}]}"
  else
    printf "%s\n" "{\"testsCount\":0}"
  fi
else
  printf "%s\n" "not-json"
fi'

  write_stub "$stub_dir/plutil" '#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *" -convert xml1 "*)
    file="${@: -1}"
    grep -q "^{" "$file" ;;
  *" -extract testsCount raw "*)
    file="${@: -1}"
    sed -nE "s/.*\\\"testsCount\\\"[[:space:]]*:[[:space:]]*([0-9]+).*/\\1/p" "$file" | head -1 ;;
  *" -insert "*)
    exit 0 ;;
  *)
    exit 0 ;;
esac'

  write_stub "$stub_dir/lsregister" '#!/usr/bin/env bash
exit 0'
}

run_case() {
  local mode="$1" expected_status="$2" hosted="${3:-false}"
  local case_dir="$TEST_DIR/$mode-$hosted" home_dir="$TEST_DIR/home-$mode-$hosted" tmp_dir="$TEST_DIR/tmp-$mode-$hosted"
  local output status
  mkdir -p "$case_dir" "$home_dir" "$tmp_dir"
  make_stubs "$case_dir/stubs"
  set +e
  env \
    HOME="$home_dir" \
    TMPDIR="$tmp_dir" \
    PATH="$case_dir/stubs:$PATH" \
    PACKAGE_APP_SCRIPT="$case_dir/stubs/package_app.sh" \
    LSREGISTER="$case_dir/stubs/lsregister" \
    FIXTURE_DIR="$case_dir" \
    FIXTURE_MODE="$mode" \
    UI_TEST_RECOVERY_SLEEP=0 \
    DEVELOPMENT_TEAM=forbidden-team \
    CODE_SIGN_IDENTITY=forbidden-identity \
    CODE_SIGN_STYLE=Automatic \
    PROVISIONING_PROFILE=forbidden-profile \
    PROVISIONING_PROFILE_SPECIFIER=forbidden-specifier \
    APP_IDENTITY=forbidden-app-identity \
    SIGNING_MODE=developer-id \
    GITHUB_ACTIONS="$hosted" \
    GITHUB_RUN_ID=195fixture \
    "$ROOT/Scripts/run_ui_tests.sh" >"$case_dir/output" 2>&1
  status=$?
  set -e
  [[ "$status" == "$expected_status" ]] || fail "$mode/$hosted returned $status, expected $expected_status"
  output="$case_dir/output"
  printf '%s\n' "$case_dir"
}

assert_signing_scrubbed() {
  local case_dir="$1"
  [[ -s "$case_dir/package-env" ]] || fail "package signing evidence missing"
  grep -Fxq 'SIGNING_MODE=adhoc' "$case_dir/package-env" || fail "package was not ad-hoc"
  grep -Fxq 'APP_IDENTITY=' "$case_dir/package-env" || fail "package identity was not cleared"
  grep -Fxq 'DEVELOPMENT_TEAM=' "$case_dir/package-env" || fail "package inherited team"
  grep -Fxq 'CODE_SIGN_IDENTITY=' "$case_dir/package-env" || fail "package inherited identity"
  grep -Fxq 'CODE_SIGN_STYLE=' "$case_dir/package-env" || fail "package inherited style"
  grep -Fxq 'PROVISIONING_PROFILE=' "$case_dir/package-env" || fail "package inherited profile"
  grep -Fxq 'PROVISIONING_PROFILE_SPECIFIER=' "$case_dir/package-env" || fail "package inherited profile specifier"
  grep -Fxq 'DEVELOPMENT_TEAM=' "$case_dir/xcodebuild-env" || fail "xcodebuild inherited team"
  grep -Fxq 'CODE_SIGN_IDENTITY=-' "$case_dir/xcodebuild-env" || fail "xcodebuild was not ad-hoc"
  grep -Fxq 'CODE_SIGN_STYLE=Manual' "$case_dir/xcodebuild-env" || fail "xcodebuild style was not explicit"
  grep -Fxq 'PROVISIONING_PROFILE=' "$case_dir/xcodebuild-env" || fail "xcodebuild inherited profile"
  grep -Fxq 'PROVISIONING_PROFILE_SPECIFIER=' "$case_dir/xcodebuild-env" || fail "xcodebuild inherited profile specifier"
}

assert_local_artifacts() {
  local case_dir="$1" expected_first="$2" expected_second="${3:-not-run}"
  local output="$case_dir/output" log1 log2 result1 result2
  grep -Fq "category=$expected_first" "$output" || fail "missing first category $expected_first"
  grep -Fq "category=$expected_second" "$output" || fail "missing second category $expected_second"
  log1=$(sed -n 's/.*attempt 1:.* log=\([^ ]*\) xcresult=.*/\1/p' "$output")
  result1=$(sed -n 's/.*attempt 1:.* xcresult=\([^ ]*\) summary=.*/\1/p' "$output")
  [[ -s "$log1" && -d "$result1" ]] || fail "first attempt evidence missing"
  if [[ "$expected_second" != not-run ]]; then
    log2=$(sed -n 's/.*attempt 2:.* log=\([^ ]*\) xcresult=.*/\1/p' "$output")
    result2=$(sed -n 's/.*attempt 2:.* xcresult=\([^ ]*\) summary=.*/\1/p' "$output")
    [[ -s "$log2" && -d "$result2" ]] || fail "second attempt evidence missing"
    [[ "$log1" != "$log2" && "$result1" != "$result2" ]] || fail "attempt artifacts were reused"
  fi
}

assertion_dir=$(run_case assertion 1)
assert_local_artifacts "$assertion_dir" test-failure not-run
[[ "$(<"$assertion_dir/invocations")" == 1 ]] || fail "assertion failure retried"
assert_signing_scrubbed "$assertion_dir"

runner_dir=$(run_case runner 0)
assert_local_artifacts "$runner_dir" runner-initialization success
[[ "$(<"$runner_dir/invocations")" == 2 ]] || fail "runner initialization did not retry once"
assert_signing_scrubbed "$runner_dir"

runner_real_dir=$(run_case runner-real 0)
assert_local_artifacts "$runner_real_dir" runner-initialization success
[[ "$(<"$runner_real_dir/invocations")" == 2 ]] || fail "real runner summary did not retry once"

unknown_dir=$(run_case unknown 1)
assert_local_artifacts "$unknown_dir" unclassified not-run
[[ "$(<"$unknown_dir/invocations")" == 1 ]] || fail "unknown failure retried"

invalid_dir=$(run_case invalid 1)
assert_local_artifacts "$invalid_dir" unclassified not-run
[[ "$(<"$invalid_dir/invocations")" == 1 ]] || fail "invalid result retried"

build_dir=$(run_case build 1)
grep -Fq 'category=build-or-package-failure' "$build_dir/output" || fail "build failure was not classified"
[[ ! -e "$build_dir/invocations" ]] || fail "build failure invoked tests"

hosted_dir=$(run_case runner 0 true)
grep -Fq 'github_run_id=195fixture' "$hosted_dir/output" || fail "hosted run ID missing"
grep -Fq 'log_sha256=' "$hosted_dir/output" || fail "hosted log hash missing"
grep -Fq 'xcresult_summary_sha256=' "$hosted_dir/output" || fail "hosted summary hash missing"
if grep -Fq "$hosted_dir" "$hosted_dir/output"; then
  fail "hosted output leaked a local path"
fi

echo "PASS: run_ui_tests fixtures"
