#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PROJECT="$ROOT_DIR/UITests/SkillsManagerUITests.xcodeproj"
SCHEME=SkillsManagerUITests
UI_TEST_BUNDLE_ID=com.mcandhisagents.skillsmanager.uitest
START_STATUS=$(git -C "$ROOT_DIR" status --short)
RESULT_BUNDLE=""
# The sandboxed XCTRunner can only write inside its own container; the runner
# root must live there so tests can create/remove child homes.
CONTAINER_HOME="${HOME}/Library/Containers/${UI_TEST_BUNDLE_ID}.xctrunner/Data"
mkdir -p "$CONTAINER_HOME"
RUNNER_ROOT=$(mktemp -d "${CONTAINER_HOME}/skillsmanager-ui-XXXXXX")
export SKILLS_MANAGER_UI_TEST_ROOT="$RUNNER_ROOT"

cleanup() {
  local end_status
  end_status=$(git -C "$ROOT_DIR" status --short)
  if [[ "$end_status" != "$START_STATUS" ]]; then
    echo "ERROR: UI test runner changed repository status." >&2
    printf 'before:\n%s\nafter:\n%s\n' "$START_STATUS" "$end_status" >&2
    rm -rf "$RUNNER_ROOT"
    exit 1
  fi
  if [[ -d "$RESULT_BUNDLE" ]]; then
    echo "UI test result bundle: $RESULT_BUNDLE"
  fi
  rm -rf "$RUNNER_ROOT"
}
trap cleanup EXIT

[[ -d "$PROJECT" ]] || { echo "ERROR: missing UI test project: $PROJECT" >&2; exit 1; }
chmod 700 "$RUNNER_ROOT"
ROOT_UID=$(id -u)
ROOT_MODE=$(stat -f '%Lp' "$RUNNER_ROOT")
[[ "$ROOT_MODE" == "700" && "$(stat -f '%u' "$RUNNER_ROOT")" == "$ROOT_UID" \
  && ! -L "$RUNNER_ROOT" ]] || {
  echo "ERROR: runner root admission failed." >&2
  exit 1
}

build_marker_check() {
  local configuration="$1" scratch="$2" expected="$3"
  mkdir -p "$scratch"
  swift build -c "$configuration" --arch arm64 --scratch-path "$scratch"
  local bin_dir
  bin_dir=$(swift build -c "$configuration" --arch arm64 --scratch-path "$scratch" --show-bin-path)
  local binary="$bin_dir/SkillsManager"
  [[ -f "$binary" ]] || { echo "ERROR: missing $binary" >&2; exit 1; }
  local literal
  for literal in \
    --skillsmanager-ui-fixture \
    SKILLS_MANAGER_UI_TEST_ROOT \
    SKILLS_MANAGER_UI_TEST_HOME \
    SkillsManagerUITestFixtureEnabled; do
    if [[ "$expected" == "present" ]]; then
      strings "$binary" | grep -F -- "$literal" >/dev/null || {
        echo "ERROR: UI fixture marker missing: $literal" >&2
        exit 1
      }
    else
      if strings "$binary" | grep -F -- "$literal" >/dev/null; then
        echo "ERROR: fixture marker leaked into $configuration binary: $literal" >&2
        exit 1
      fi
    fi
  done
}

build_marker_check debug "$RUNNER_ROOT/swiftpm-default-debug" absent
build_marker_check release "$RUNNER_ROOT/swiftpm-default-release" absent

APP_DIR="$RUNNER_ROOT/app"
SCRATCH_DIR="$RUNNER_ROOT/swiftpm-ui"
DERIVED_DATA="$RUNNER_ROOT/derived-data"
RESULT_BUNDLE="$RUNNER_ROOT/xcresult"
ENTITLEMENTS="$RUNNER_ROOT/app/SkillsManagerUITest.entitlements"
mkdir -p "$APP_DIR" "$SCRATCH_DIR"
UI_TEST_BUILD=1 \
APP_NAME=SkillsManagerUITest \
APP_DISPLAY_NAME="Skills Manager UI Test" \
EXECUTABLE_NAME=SkillsManager \
BUNDLE_ID=com.mcandhisagents.skillsmanager.uitest \
ARCHES=arm64 \
APP_OUTPUT_DIR="$APP_DIR" \
SWIFT_SCRATCH_PATH="$SCRATCH_DIR" \
APP_ENTITLEMENTS="$ENTITLEMENTS" \
  "$ROOT_DIR/Scripts/package_app.sh" debug

UI_BIN_DIR=$(swift build -c debug --arch arm64 --scratch-path "$SCRATCH_DIR" --show-bin-path)
for literal in \
  --skillsmanager-ui-fixture \
  SKILLS_MANAGER_UI_TEST_ROOT \
  SKILLS_MANAGER_UI_TEST_HOME \
  SkillsManagerUITestFixtureEnabled; do
  strings "$UI_BIN_DIR/SkillsManager" | grep -F -- "$literal" >/dev/null || {
    echo "ERROR: fixture marker missing from UI binary: $literal" >&2
    exit 1
  }
done

TEST_APP_PATH="$APP_DIR/SkillsManagerUITest.app"
[[ -x "$TEST_APP_PATH/Contents/MacOS/SkillsManager" ]] || {
  echo "ERROR: test App executable is missing." >&2
  exit 1
}

xcodebuild build-for-testing \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA"

# Some Xcode runner templates (e.g. 26.4) emit a CFBundleExecutable that differs
# from the actual binary name, which makes LaunchServices fail with -10827.
# Align the executable name with the Info.plist and re-sign when needed.
RUNNER_APP="$DERIVED_DATA/Build/Products/Debug/SkillsManagerUITests-Runner.app"
if [[ -d "$RUNNER_APP" ]]; then
  RUNNER_EXEC_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" \
    "$RUNNER_APP/Contents/Info.plist" 2>/dev/null || true)
  echo "Runner CFBundleExecutable: ${RUNNER_EXEC_NAME:-unreadable}"
  echo "Runner Contents/MacOS: $(ls -la "$RUNNER_APP/Contents/MacOS" 2>/dev/null | tr '\n' ' ')"
  if [[ -n "$RUNNER_EXEC_NAME" ]]; then
    RUNNER_EXEC="$RUNNER_APP/Contents/MacOS/$RUNNER_EXEC_NAME"
    if [[ -x "$RUNNER_EXEC" ]]; then
      echo "Runner executable arches: $(lipo -archs "$RUNNER_EXEC" 2>&1)"
    fi
    if [[ ! -x "$RUNNER_EXEC" ]]; then
      ACTUAL_EXEC=$(find "$RUNNER_APP/Contents/MacOS" -maxdepth 1 -type f -perm -111 | head -1)
      if [[ -n "$ACTUAL_EXEC" ]]; then
        mv "$ACTUAL_EXEC" "$RUNNER_EXEC"
        codesign --force --sign - "$RUNNER_APP"
        echo "Aligned Runner executable: $(basename "$ACTUAL_EXEC") -> $RUNNER_EXEC_NAME"
      else
        echo "ERROR: Runner.app contains no executable." >&2
        exit 1
      fi
    fi
  fi
fi

XCTESTRUN=$(find "$DERIVED_DATA/Build/Products" -maxdepth 1 -name '*.xctestrun' | head -1)
[[ -n "$XCTESTRUN" && -f "$XCTESTRUN" ]] || {
  echo "ERROR: xctestrun file not found under $DERIVED_DATA/Build/Products" >&2
  exit 1
}
# Register the Runner with LaunchServices so a fresh container or a stale
# launch-services cache cannot fail the launch with OSStatus -10827.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -f "$RUNNER_APP" 2>/dev/null || true
plutil -insert "SkillsManagerUITests.EnvironmentVariables.SKILLS_MANAGER_UI_TEST_ROOT" \
  -string "$RUNNER_ROOT" "$XCTESTRUN"
plutil -insert "SkillsManagerUITests.EnvironmentVariables.TEST_APP_PATH" \
  -string "$TEST_APP_PATH" "$XCTESTRUN"

xcodebuild test-without-building \
  -xctestrun "$XCTESTRUN" \
  -destination 'platform=macOS,arch=arm64' \
  -resultBundlePath "$RESULT_BUNDLE"
