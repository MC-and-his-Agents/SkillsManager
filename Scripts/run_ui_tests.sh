#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PROJECT="$ROOT_DIR/UITests/SkillsManagerUITests.xcodeproj"
SCHEME=SkillsManagerUITests
UI_TEST_BUNDLE_ID=com.mcandhisagents.skillsmanager.uitest
START_STATUS="$(git -C "$ROOT_DIR" status --short)"
PACKAGE_APP_SCRIPT="${PACKAGE_APP_SCRIPT:-$ROOT_DIR/Scripts/package_app.sh}"
LSREGISTER="${LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
HOSTED_CI=0
[[ "${GITHUB_ACTIONS:-}" == "true" ]] && HOSTED_CI=1
GITHUB_RUN_ID_VALUE="${GITHUB_RUN_ID:-unknown}"
source "$ROOT_DIR/Scripts/ui_test_selection.sh"
ui_test_select
MAX_FAILED_IDENTIFIERS=20
MAX_FAILED_IDENTIFIER_LENGTH=200

# UI tests must never consume a developer identity or inherited provisioning
# settings. The explicit xcodebuild settings below are build settings, not
# inherited signing configuration.
unset DEVELOPMENT_TEAM CODE_SIGN_IDENTITY CODE_SIGN_STYLE \
  PROVISIONING_PROFILE PROVISIONING_PROFILE_SPECIFIER
SIGNING_MODE=adhoc
APP_IDENTITY=""
export SIGNING_MODE APP_IDENTITY

umask 077
CONTAINER_HOME="${HOME}/Library/Containers/${UI_TEST_BUNDLE_ID}.xctrunner/Data"
mkdir -p "$CONTAINER_HOME"
RUNNER_ROOT="$(mktemp -d "$CONTAINER_HOME/skillsmanager-ui-XXXXXX")"
RUN_DIR="$(mktemp -d "$RUNNER_ROOT/run-XXXXXX")"
BUILD_LOG="$RUN_DIR/build.log"
DERIVED_DATA=""
PERSIST_RUN=0
FINAL_STATUS=1
FINAL_CATEGORY=unclassified

declare -a ATTEMPT_CATEGORY ATTEMPT_STATUS ATTEMPT_TOTAL
declare -a ATTEMPT_LOG ATTEMPT_XCRESULT ATTEMPT_SUMMARY
declare -a ATTEMPT_FAILED_IDENTIFIERS

printf 'ui-test-selection mode=%s groups=%s selected_test_total=%s\n' \
  "$UI_TEST_SELECTION_MODE" "$UI_TEST_SELECTED_GROUPS" "$UI_TEST_SELECTED_COUNT"

cleanup() {
  local status=$?
  set +e
  local end_status
  end_status=$(git -C "$ROOT_DIR" status --short 2>/dev/null)
  if [[ "$end_status" != "$START_STATUS" ]]; then
    echo "ERROR: UI test runner changed repository status." >&2
    printf 'before:\n%s\nafter:\n%s\n' "$START_STATUS" "$end_status" >&2
    status=1
  fi
  if [[ -n "$DERIVED_DATA" && -d "$DERIVED_DATA" ]]; then
    rm -rf "$DERIVED_DATA"
  fi
  if [[ "$HOSTED_CI" == "1" ]]; then
    rm -rf "$RUNNER_ROOT"
  elif [[ "$PERSIST_RUN" == "1" ]]; then
    printf 'UI test evidence retained: %s\n' "$RUN_DIR"
  else
    printf 'UI test evidence cleaned: %s\n' "$RUN_DIR"
    rm -rf "$RUNNER_ROOT"
  fi
  return "$status"
}
trap cleanup EXIT

admit_owner_only_dir() {
  local directory="$1"
  local uid mode
  uid=$(id -u)
  mode=$(stat -f '%Lp' "$directory")
  [[ -d "$directory" && ! -L "$directory" && "$mode" == "700" \
    && "$(stat -f '%u' "$directory")" == "$uid" ]]
}

if ! chmod 700 "$RUNNER_ROOT" "$RUN_DIR" \
  || ! admit_owner_only_dir "$RUNNER_ROOT" \
  || ! admit_owner_only_dir "$RUN_DIR"; then
  echo "ERROR: runner evidence directory admission failed." >&2
  exit 1
fi
export SKILLS_MANAGER_UI_TEST_ROOT="$RUNNER_ROOT"

sha256_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    printf 'missing'
  fi
}

failed_identifier_is_safe() {
  local value="$1"
  [[ -n "$value" && "${#value}" -le "$MAX_FAILED_IDENTIFIER_LENGTH" ]] || return 1
  [[ "$value" =~ ^[A-Za-z_][A-Za-z0-9_.:/-]*$ ]] || return 1
  [[ "$value" != /* && "$value" != *..* && "$value" != *://* ]] || return 1
  [[ ! "$value" =~ \.(swift|m|mm|h|c|cc|cpp|json|plist|log|xcresult)(:[0-9]+)?$ ]] || return 1
}

collect_failed_identifiers() {
  local candidates="$1" candidate identifiers="" count=0
  while IFS= read -r candidate; do
    if [[ -n "$candidate" ]] && failed_identifier_is_safe "$candidate"; then
      case ",$identifiers," in *,"$candidate",*) continue ;; esac
      [[ -n "$identifiers" ]] && identifiers+=","
      identifiers+="$candidate"; count=$((count + 1))
      [[ "$count" -ge "$MAX_FAILED_IDENTIFIERS" ]] && break
    fi
  done <<< "$candidates"
  [[ -n "$identifiers" ]] && printf '%s' "$identifiers" || printf 'unknown'
}

extract_failed_identifiers() {
  local summary="$1" failure_xml candidates
  [[ -f "$summary" ]] || { printf 'unknown'; return 0; }
  failure_xml=$(plutil -extract testFailures xml1 -o - "$summary" 2>/dev/null || true)
  [[ -n "$failure_xml" ]] || { printf 'unknown'; return 0; }
  candidates=$(printf '%s\n' "$failure_xml" | awk '/<key>testIdentifier(String)?<\/key>/ { capture=1; next } capture && /<string>/ { value=$0; sub(/^.*<string>/, "", value); sub(/<\/string>.*$/, "", value); print value; capture=0; next } capture && /<key>|<\/dict>|<\/array>/ { capture=0 }')
  collect_failed_identifiers "$candidates"
}

extract_failed_identifiers_from_log() {
  local log="$1" candidates
  [[ -f "$log" ]] || { printf 'unknown'; return 0; }
  candidates=$(sed -nE "s#^[[:space:]]*Test Case '-\[([A-Za-z_][A-Za-z0-9_.:-]*) ([A-Za-z_][A-Za-z0-9_.:-]*)\]' failed( \([0-9]+([.][0-9]+)? seconds?\))?[.]?[[:space:]]*\$#\1/\2#p" "$log")
  collect_failed_identifiers "$candidates"
}

print_attempt() {
  local attempt="$1"
  if [[ "$HOSTED_CI" == "1" ]]; then
    if [[ "${ATTEMPT_CATEGORY[$attempt]}" == "test-failure" ]]; then
      printf 'ui-test-attempt=%s category=%s exit_status=%s test_total=%s failed_test_identifiers=%s log_sha256=%s xcresult_summary_sha256=%s github_run_id=%s\n' \
        "$attempt" "${ATTEMPT_CATEGORY[$attempt]}" "${ATTEMPT_STATUS[$attempt]}" \
        "${ATTEMPT_TOTAL[$attempt]}" "${ATTEMPT_FAILED_IDENTIFIERS[$attempt]:-unknown}" \
        "$(sha256_file "${ATTEMPT_LOG[$attempt]}")" \
        "$(sha256_file "${ATTEMPT_SUMMARY[$attempt]}")" "$GITHUB_RUN_ID_VALUE"
    else
      printf 'ui-test-attempt=%s category=%s exit_status=%s test_total=%s log_sha256=%s xcresult_summary_sha256=%s github_run_id=%s\n' \
        "$attempt" "${ATTEMPT_CATEGORY[$attempt]}" "${ATTEMPT_STATUS[$attempt]}" \
        "${ATTEMPT_TOTAL[$attempt]}" "$(sha256_file "${ATTEMPT_LOG[$attempt]}")" \
        "$(sha256_file "${ATTEMPT_SUMMARY[$attempt]}")" "$GITHUB_RUN_ID_VALUE"
    fi
  else
    printf 'UI test attempt %s: category=%s exit_status=%s test_total=%s log=%s xcresult=%s summary=%s\n' \
      "$attempt" "${ATTEMPT_CATEGORY[$attempt]}" "${ATTEMPT_STATUS[$attempt]}" \
      "${ATTEMPT_TOTAL[$attempt]}" "${ATTEMPT_LOG[$attempt]}" \
      "${ATTEMPT_XCRESULT[$attempt]}" "${ATTEMPT_SUMMARY[$attempt]}"
  fi
}

print_not_run() {
  local attempt="${1:-2}"
  if [[ "$HOSTED_CI" == "1" ]]; then
    printf 'ui-test-attempt=%s category=not-run exit_status=not-run test_total=not-run log_sha256=not-run xcresult_summary_sha256=not-run github_run_id=%s\n' \
      "$attempt" "$GITHUB_RUN_ID_VALUE"
  else
    printf 'UI test attempt %s: category=not-run exit_status=not-run test_total=not-run log=not-run xcresult=not-run summary=not-run\n' \
      "$attempt"
  fi
}

build_marker_check() {
  local configuration="$1" scratch="$2" expected="$3"
  mkdir -p "$scratch"
  if ! swift build -c "$configuration" --arch arm64 --scratch-path "$scratch"; then
    return 1
  fi
  local bin_dir
  if ! bin_dir=$(swift build -c "$configuration" --arch arm64 --scratch-path "$scratch" --show-bin-path); then
    return 1
  fi
  local binary="$bin_dir/SkillsManager"
  [[ -f "$binary" ]] || { echo "ERROR: missing $binary" >&2; return 1; }
  local literal
  for literal in \
    --skillsmanager-ui-fixture \
    SKILLS_MANAGER_UI_TEST_ROOT \
    SKILLS_MANAGER_UI_TEST_HOME \
    SkillsManagerUITestFixtureEnabled; do
    if [[ "$expected" == "present" ]]; then
      if ! strings "$binary" | grep -F -- "$literal" >/dev/null; then
        echo "ERROR: UI fixture marker missing: $literal" >&2
        return 1
      fi
    elif strings "$binary" | grep -F -- "$literal" >/dev/null; then
      echo "ERROR: fixture marker leaked into $configuration binary: $literal" >&2
      return 1
    fi
  done
}

expand_xctestrun_path() {
  local raw_path="$1" test_root="$2" test_host="$3"
  raw_path="${raw_path//__TESTROOT__/$test_root}"
  raw_path="${raw_path//__TESTHOST__/$test_host}"
  printf '%s\n' "$raw_path"
}

validate_bundle_reference() {
  local label="$1" bundle="$2" info executable_name executable
  [[ -d "$bundle" ]] || {
    echo "ERROR: $label bundle is missing." >&2
    return 1
  }
  info="$bundle/Contents/Info.plist"
  [[ -f "$info" ]] || {
    echo "ERROR: $label Info.plist is missing." >&2
    return 1
  }
  executable_name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" \
    "$info" 2>/dev/null || true)
  [[ -n "$executable_name" ]] || {
    echo "ERROR: $label CFBundleExecutable is missing." >&2
    return 1
  }
  executable="$bundle/Contents/MacOS/$executable_name"
  [[ -f "$executable" && -x "$executable" ]] || {
    echo "ERROR: $label executable is missing or not runnable." >&2
    return 1
  }
}

validate_xctestrun_references() {
  local test_root runner_canonical host_raw bundle_raw host_path bundle_path
  local host_canonical bundle_canonical
  test_root=$(cd "$(dirname "$XCTESTRUN")" && pwd -P)
  runner_canonical=$(cd "$RUNNER_APP" && pwd -P)
  host_raw=$(plutil -extract "$SCHEME.TestHostPath" raw -o - "$XCTESTRUN" 2>/dev/null || true)
  [[ -n "$host_raw" ]] || {
    echo "ERROR: xctestrun TestHostPath is missing for $SCHEME." >&2
    return 1
  }
  [[ "$host_raw" != *..* ]] || {
    echo "ERROR: xctestrun TestHostPath contains traversal." >&2
    return 1
  }
  host_path=$(expand_xctestrun_path "$host_raw" "$test_root" "")
  validate_bundle_reference TestHostPath "$host_path" || return 1
  host_canonical=$(cd "$host_path" && pwd -P)
  [[ "$host_canonical" == "$runner_canonical" ]] || {
    echo "ERROR: xctestrun TestHostPath does not identify Runner.app." >&2
    return 1
  }

  bundle_raw=$(plutil -extract "$SCHEME.TestBundlePath" raw -o - "$XCTESTRUN" 2>/dev/null || true)
  [[ -n "$bundle_raw" ]] || {
    echo "ERROR: xctestrun TestBundlePath is missing for $SCHEME." >&2
    return 1
  }
  [[ "$bundle_raw" != *..* ]] || {
    echo "ERROR: xctestrun TestBundlePath contains traversal." >&2
    return 1
  }
  bundle_path=$(expand_xctestrun_path "$bundle_raw" "$test_root" "$host_path")
  validate_bundle_reference TestBundlePath "$bundle_path" || return 1
  bundle_canonical=$(cd "$bundle_path" && pwd -P)
  case "$bundle_canonical" in
    "$host_canonical/Contents/PlugIns/"*) ;;
    *)
      echo "ERROR: xctestrun TestBundlePath escapes Runner.app." >&2
      return 1
      ;;
  esac
}

APP_DIR="$RUNNER_ROOT/app"
SCRATCH_DIR="$RUN_DIR/swiftpm-ui"
DERIVED_DATA="$(mktemp -d "${TMPDIR:-/tmp}/skillsmanager-ui-derived-XXXXXX")"
ENTITLEMENTS="$APP_DIR/SkillsManagerUITest.entitlements"
TEST_APP_PATH="$APP_DIR/SkillsManagerUITest.app"
RUNNER_APP="$DERIVED_DATA/Build/Products/Debug/SkillsManagerUITests-Runner.app"
XCTESTRUN=""

preflight() {
  [[ -d "$PROJECT" ]] || { echo "ERROR: missing UI test project." >&2; return 1; }
  build_marker_check debug "$RUN_DIR/swiftpm-default-debug" absent || return 1
  build_marker_check release "$RUN_DIR/swiftpm-default-release" absent || return 1
  mkdir -p "$APP_DIR" "$SCRATCH_DIR"

  SIGNING_MODE=adhoc APP_IDENTITY="" \
    UI_TEST_BUILD=1 \
    APP_NAME=SkillsManagerUITest \
    APP_DISPLAY_NAME="Skills Manager UI Test" \
    EXECUTABLE_NAME=SkillsManager \
    BUNDLE_ID=com.mcandhisagents.skillsmanager.uitest \
    ARCHES=arm64 \
    APP_OUTPUT_DIR="$APP_DIR" \
    SWIFT_SCRATCH_PATH="$SCRATCH_DIR" \
    APP_ENTITLEMENTS="$ENTITLEMENTS" \
    "$PACKAGE_APP_SCRIPT" debug || return 1

  UI_BIN_DIR=$(swift build -c debug --arch arm64 --scratch-path "$SCRATCH_DIR" --show-bin-path) || return 1
  for literal in \
    --skillsmanager-ui-fixture \
    SKILLS_MANAGER_UI_TEST_ROOT \
    SKILLS_MANAGER_UI_TEST_HOME \
    SkillsManagerUITestFixtureEnabled; do
    strings "$UI_BIN_DIR/SkillsManager" | grep -F -- "$literal" >/dev/null || {
      echo "ERROR: fixture marker missing from UI binary: $literal" >&2
      return 1
    }
  done
  [[ -f "$TEST_APP_PATH/Contents/MacOS/SkillsManager" \
    && -x "$TEST_APP_PATH/Contents/MacOS/SkillsManager" ]] || {
    echo "ERROR: test App executable is missing." >&2
    return 1
  }

  DEVELOPMENT_TEAM= CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
    xcodebuild build-for-testing \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -destination 'platform=macOS,arch=arm64' \
      -derivedDataPath "$DERIVED_DATA" || return 1

  [[ -d "$RUNNER_APP" ]] || {
    echo "ERROR: Runner.app is missing from derived data." >&2
    return 1
  }
  local runner_info="$RUNNER_APP/Contents/Info.plist"
  [[ -f "$runner_info" ]] || {
    echo "ERROR: Runner.app Info.plist is missing." >&2
    return 1
  }
  [[ -d "$RUNNER_APP/Contents/MacOS" ]] || {
    echo "ERROR: Runner.app executable directory is missing." >&2
    return 1
  }
  local runner_exec_name runner_exec actual_exec
  runner_exec_name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" \
    "$runner_info" 2>/dev/null || true)
  [[ -n "$runner_exec_name" ]] || {
    echo "ERROR: Runner.app CFBundleExecutable is missing." >&2
    return 1
  }
  runner_exec="$RUNNER_APP/Contents/MacOS/$runner_exec_name"
  if [[ ! -x "$runner_exec" ]]; then
    actual_exec=$(find "$RUNNER_APP/Contents/MacOS" -maxdepth 1 -type f -perm -111 | head -1)
    if [[ -n "$actual_exec" ]]; then
      mv "$actual_exec" "$runner_exec"
      codesign --force --sign - "$RUNNER_APP" || return 1
    else
      echo "ERROR: Runner.app contains no executable." >&2
      return 1
    fi
  fi
  [[ -f "$runner_exec" && -x "$runner_exec" ]] || {
    echo "ERROR: Runner.app executable is not runnable." >&2
    return 1
  }

  XCTESTRUN=$(find "$DERIVED_DATA/Build/Products" -maxdepth 1 -name '*.xctestrun' | head -1)
  [[ -n "$XCTESTRUN" && -f "$XCTESTRUN" ]] || {
    echo "ERROR: xctestrun file not found under derived data." >&2
    return 1
  }
  validate_xctestrun_references || return 1
  "$LSREGISTER" -f "$RUNNER_APP" 2>/dev/null || true
  plutil -insert "SkillsManagerUITests.EnvironmentVariables.SKILLS_MANAGER_UI_TEST_ROOT" \
    -string "$RUNNER_ROOT" "$XCTESTRUN" || return 1
  plutil -insert "SkillsManagerUITests.EnvironmentVariables.TEST_APP_PATH" \
    -string "$TEST_APP_PATH" "$XCTESTRUN" || return 1
}

run_attempt() {
  local attempt="$1"
  local log="$RUN_DIR/attempt-${attempt}.log"
  local result="$RUN_DIR/attempt-${attempt}.xcresult"
  local summary="$RUN_DIR/attempt-${attempt}.summary.json"
  local summary_stderr="$RUN_DIR/attempt-${attempt}.summary.stderr"
  local status summary_valid=0 test_total=unknown test_started=0 allowlisted=0 category
  local -a test_arguments

  : > "$log"
  : > "$summary_stderr"
  test_arguments=(-resultBundlePath "$result")
  if [[ "$UI_TEST_SELECTION_MODE" != full ]]; then
    test_arguments=("${UI_TEST_ARGUMENTS[@]}" "${test_arguments[@]}")
  fi
  set +e
  DEVELOPMENT_TEAM= CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
    xcodebuild test-without-building \
      -xctestrun "$XCTESTRUN" \
      -destination 'platform=macOS,arch=arm64' \
      "${test_arguments[@]}" >"$log" 2>&1
  status=$?
  set -e

  if [[ -d "$result" ]] \
    && xcrun xcresulttool get test-results summary --path "$result" \
      >"$summary" 2>"$summary_stderr" \
    && [[ -s "$summary" ]] \
    && plutil -convert xml1 -o /dev/null "$summary" >/dev/null 2>&1; then
    summary_valid=1
    test_total=$(plutil -extract testsCount raw -o - "$summary" 2>/dev/null || true)
    if ! [[ "$test_total" =~ ^[0-9]+$ ]]; then
      test_total=$(plutil -extract totalTestCount raw -o - "$summary" 2>/dev/null || true)
    fi
    [[ "$test_total" =~ ^[0-9]+$ ]] || test_total=unknown
  fi

  if [[ "$summary_valid" == "1" ]]; then
    if grep -Eiq '"testIdentifier"[[:space:]]*:[[:space:]]*"[^"]+"' "$summary" \
      || grep -Eiq '"failureSummaries"[[:space:]]*:[[:space:]]*\[[[:space:]]*\{' "$summary" \
      || grep -Eiq '"assertionFailure(s)?"[[:space:]]*:[[:space:]]*(true|[1-9]|"[^"]+")' "$summary" \
      || grep -Eiq 'Test Case .*(passed|failed)|XCTAssert|assertion failure' "$log"; then
      test_started=1
    elif grep -Eiq '"testIdentifierString"[[:space:]]*:[[:space:]]*"[^"]+"' "$summary" \
      && ! grep -Eiq '"testIdentifierString"[[:space:]]*:[[:space:]]*"[^"]*(Runner|runner)[^"]*encountered an error' "$summary"; then
      test_started=1
    fi
  fi
  if grep -Fq 'The test runner failed to initialize for UI testing' "$log" \
    || grep -Fq 'Timed out while enabling automation mode' "$log" \
    || grep -Fq 'XCTFuture Code=1000' "$log" \
    || grep -Fq 'Launch Services OSStatus -10827' "$log"; then
    allowlisted=1
  fi

  if [[ "$allowlisted" == "1" && "$test_started" == "0" \
    && "$test_total" != "0" ]] \
    && grep -Eiq '"testIdentifierString"[[:space:]]*:[[:space:]]*"[^"]*(Runner|runner)[^"]*"' "$summary"; then
    test_total=0
  fi

  if [[ "$test_started" == "1" ]]; then
    if [[ "$status" == "0" ]]; then category=success; else category=test-failure; fi
  elif [[ "$status" != "0" && "$allowlisted" == "1" && "$summary_valid" == "1" \
    && "$test_total" == "0" ]]; then
    category=runner-initialization
  else
    category=unclassified
  fi

  if [[ "$category" == "test-failure" && "$HOSTED_CI" == "1" ]]; then
    ATTEMPT_FAILED_IDENTIFIERS[$attempt]=$(extract_failed_identifiers "$summary")
    if [[ "${ATTEMPT_FAILED_IDENTIFIERS[$attempt]}" == "unknown" ]]; then
      ATTEMPT_FAILED_IDENTIFIERS[$attempt]=$(extract_failed_identifiers_from_log "$log")
    fi
  else
    ATTEMPT_FAILED_IDENTIFIERS[$attempt]=unknown
  fi

  ATTEMPT_CATEGORY[$attempt]="$category"
  ATTEMPT_STATUS[$attempt]="$status"
  ATTEMPT_TOTAL[$attempt]="$test_total"
  ATTEMPT_LOG[$attempt]="$log"
  ATTEMPT_XCRESULT[$attempt]="$result"
  ATTEMPT_SUMMARY[$attempt]="$summary"
  [[ "$category" == "success" ]] || PERSIST_RUN=1
  [[ "$attempt" -gt 1 ]] && PERSIST_RUN=1
  return 0
}

if ! preflight >"$BUILD_LOG" 2>&1; then
  PERSIST_RUN=1
  FINAL_CATEGORY=build-or-package-failure
  FINAL_STATUS=1
  if [[ "$HOSTED_CI" == "1" ]]; then
    printf 'ui-test-preflight category=%s exit_status=1 build_log_sha256=%s github_run_id=%s\n' \
      "$FINAL_CATEGORY" "$(sha256_file "$BUILD_LOG")" "$GITHUB_RUN_ID_VALUE"
  else
    printf 'UI test preflight: category=%s exit_status=1 build_log=%s\n' \
      "$FINAL_CATEGORY" "$BUILD_LOG"
  fi
  print_not_run 1
  print_not_run 2
  exit "$FINAL_STATUS"
fi

run_attempt 1
if [[ "${ATTEMPT_CATEGORY[1]}" == "runner-initialization" ]]; then
  "$LSREGISTER" -f "$RUNNER_APP" >>"$BUILD_LOG" 2>&1 || true
  recovery_sleep="${UI_TEST_RECOVERY_SLEEP:-3}"
  [[ "$recovery_sleep" =~ ^[0-9]+$ ]] || recovery_sleep=3
  sleep "$recovery_sleep"
  run_attempt 2
fi

if [[ -n "${ATTEMPT_CATEGORY[2]+set}" ]]; then
  FINAL_CATEGORY="${ATTEMPT_CATEGORY[2]}"
else
  FINAL_CATEGORY="${ATTEMPT_CATEGORY[1]}"
fi
if [[ "$FINAL_CATEGORY" == "success" ]]; then FINAL_STATUS=0; else FINAL_STATUS=1; fi

print_attempt 1
if [[ -n "${ATTEMPT_CATEGORY[2]+set}" ]]; then print_attempt 2; else print_not_run; fi
exit "$FINAL_STATUS"
