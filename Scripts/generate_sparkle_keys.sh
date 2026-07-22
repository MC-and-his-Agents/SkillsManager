#!/usr/bin/env bash
set -euo pipefail

OUT_FILE=${1:-}
ACCOUNT=${SPARKLE_KEY_ACCOUNT:-codexskillmanager}
if [[ -z "$OUT_FILE" ]]; then
  echo "Usage: $0 /path/to/sparkle-private-key.txt" >&2
  exit 1
fi

GENERATOR_BIN=$(command -v generate_keys || true)
TEMP_DIR=""

cleanup() {
  if [[ -n "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi
}
trap cleanup EXIT

if [[ -z "$GENERATOR_BIN" ]]; then
  TEMP_DIR=$(mktemp -d /tmp/sparkle.XXXXXX)
  curl -sL -o "$TEMP_DIR/sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/2.8.1/Sparkle-2.8.1.tar.xz"
  tar -xf "$TEMP_DIR/sparkle.tar.xz" -C "$TEMP_DIR" ./bin/generate_keys
  GENERATOR_BIN="$TEMP_DIR/bin/generate_keys"
fi

if ! "$GENERATOR_BIN" --account "$ACCOUNT" >/dev/null 2>&1; then
  echo "Failed to generate Sparkle keys." >&2
  exit 1
fi

PUBLIC_KEY=$("$GENERATOR_BIN" --account "$ACCOUNT" -p | tr -d '\r')
if [[ -z "$PUBLIC_KEY" ]]; then
  echo "Failed to read Sparkle public key." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT_FILE")"
if ! "$GENERATOR_BIN" --account "$ACCOUNT" -x "$OUT_FILE" >/dev/null 2>&1; then
  echo "Failed to export Sparkle private key." >&2
  exit 1
fi
chmod 600 "$OUT_FILE"

echo "Sparkle public key (SUPublicEDKey):"
echo "$PUBLIC_KEY"
echo ""
echo "Private key saved to: $OUT_FILE"
