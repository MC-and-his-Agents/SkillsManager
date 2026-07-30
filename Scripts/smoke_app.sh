#!/usr/bin/env bash
set -euo pipefail

APP=${1:?"Usage: smoke_app.sh <app> [seconds]"}
DURATION=${2:-10}

[[ -d "$APP" && "$DURATION" =~ ^[1-9][0-9]*$ ]] || {
  echo "A valid app bundle and positive duration are required." >&2
  exit 1
}

executable=$(plutil -extract CFBundleExecutable raw -o - "$APP/Contents/Info.plist")
log=$(mktemp -t skills-manager-smoke.XXXXXX)
env -u APP_STORE_CONNECT_API_KEY_P8 -u SPARKLE_PRIVATE_KEY_FILE \
  "$APP/Contents/MacOS/$executable" >"$log" 2>&1 &
app_pid=$!

cleanup() {
  kill -TERM "$app_pid" 2>/dev/null || true
  for _ in {1..5}; do
    if ! kill -0 "$app_pid" 2>/dev/null; then
      wait "$app_pid" 2>/dev/null || true
      rm -f "$log"
      return
    fi
    sleep 1
  done
  kill -KILL "$app_pid" 2>/dev/null || true
  wait "$app_pid" 2>/dev/null || true
  rm -f "$log"
}
trap cleanup EXIT

for ((attempt = 0; attempt < DURATION; attempt++)); do
  sleep 1
  if ! kill -0 "$app_pid" 2>/dev/null; then
    cat "$log" >&2
    exit 1
  fi
done

echo "app_smoke=pass"
