#!/usr/bin/env bash
# Kill running instances, package, relaunch, verify.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME=${APP_NAME:-SkillsManager}
EXECUTABLE_NAME=${EXECUTABLE_NAME:-SkillsManager}
APP_BUNDLE="${ROOT_DIR}/${APP_NAME}.app"
APP_PROCESS_PATTERN="${APP_NAME}.app/Contents/MacOS/${EXECUTABLE_NAME}"
DEBUG_PROCESS_PATTERN="${ROOT_DIR}/.build/debug/${EXECUTABLE_NAME}"
RELEASE_PROCESS_PATTERN="${ROOT_DIR}/.build/release/${EXECUTABLE_NAME}"
PACKAGE_APP_SCRIPT="${PACKAGE_APP_SCRIPT:-$ROOT_DIR/Scripts/package_app.sh}"
RUN_TESTS=0
RELEASE_ARCHES=""

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for arg in "$@"; do
  case "${arg}" in
    --test|-t) RUN_TESTS=1 ;;
    --release-universal) RELEASE_ARCHES="arm64 x86_64" ;;
    --release-arches=*) RELEASE_ARCHES="${arg#*=}" ;;
    --help|-h)
      log "Usage: $(basename "$0") [--test] [--release-universal] [--release-arches=\"arm64 x86_64\"]"
      exit 0
      ;;
  esac
done

# Local builds are ad-hoc by default. A Developer ID identity is an explicit
# opt-in; every other signing input is cleared before invoking package_app.
SIGNING_MODE_VALUE="adhoc"
APP_IDENTITY_VALUE=""
case "${SIGNING_MODE:-}" in
  ""|adhoc)
    ;;
  developer-id)
    [[ -n "${APP_IDENTITY:-}" ]] || {
      fail "SIGNING_MODE=developer-id requires a non-empty APP_IDENTITY."
    }
    SIGNING_MODE_VALUE="developer-id"
    APP_IDENTITY_VALUE="${APP_IDENTITY}"
    ;;
  *)
    fail "Unsupported SIGNING_MODE: ${SIGNING_MODE}"
    ;;
esac

log "==> Killing existing ${APP_NAME} instances"
pkill -f "${APP_PROCESS_PATTERN}" 2>/dev/null || true
pkill -f "${DEBUG_PROCESS_PATTERN}" 2>/dev/null || true
pkill -f "${RELEASE_PROCESS_PATTERN}" 2>/dev/null || true
pkill -x "${EXECUTABLE_NAME}" 2>/dev/null || true

if [[ "${RUN_TESTS}" == "1" ]]; then
  log "==> swift test"
  # SwiftPM tests never need a signing identity; keep this build ad-hoc too.
  SIGNING_MODE="adhoc" \
  APP_IDENTITY="" \
  DEVELOPMENT_TEAM="" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_STYLE="" \
  PROVISIONING_PROFILE="" \
  PROVISIONING_PROFILE_SPECIFIER="" \
    swift test -q
fi

HOST_ARCH="$(uname -m)"
ARCHES_VALUE="${HOST_ARCH}"
if [[ -n "${RELEASE_ARCHES}" ]]; then
  ARCHES_VALUE="${RELEASE_ARCHES}"
fi

log "==> package app"
SIGNING_MODE="${SIGNING_MODE_VALUE}" \
APP_IDENTITY="${APP_IDENTITY_VALUE}" \
DEVELOPMENT_TEAM="" \
CODE_SIGN_IDENTITY="" \
CODE_SIGN_STYLE="" \
PROVISIONING_PROFILE="" \
PROVISIONING_PROFILE_SPECIFIER="" \
ARCHES="${ARCHES_VALUE}" \
  "${PACKAGE_APP_SCRIPT}" release

log "==> launch app"
if ! open "${APP_BUNDLE}"; then
  log "WARN: open failed; launching binary directly."
  "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}" >/dev/null 2>&1 &
  disown
fi

for _ in {1..10}; do
  if pgrep -f "${APP_PROCESS_PATTERN}" >/dev/null 2>&1; then
    log "OK: ${APP_NAME} is running."
    exit 0
  fi
  sleep 0.4
done
fail "App exited immediately. Check crash logs in Console.app (User Reports)."
