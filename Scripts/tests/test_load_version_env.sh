#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
source "$ROOT/Scripts/load_version_env.sh"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

printf 'MARKETING_VERSION=0.2.1\nBUILD_NUMBER=3\n' > "$TEST_DIR/valid.env"
load_version_env "$TEST_DIR/valid.env"
[[ "$MARKETING_VERSION" == "0.2.1" && "$BUILD_NUMBER" == "3" ]]

NEVER_FILE="$TEST_DIR/never"
invalid_inputs=(
  "MARKETING_VERSION=\$(touch $NEVER_FILE)|BUILD_NUMBER=3"
  'MARKETING_VERSION=0.2.1-beta|BUILD_NUMBER=3'
  'MARKETING_VERSION=0.2.1|BUILD_NUMBER=0'
  'MARKETING_VERSION=0.2.1|BUILD_NUMBER=3|EXTRA=value'
  'MARKETING_VERSION=0.2.1|MARKETING_VERSION=0.2.2'
)

for input in "${invalid_inputs[@]}"; do
  printf '%s\n' "${input//|/$'\n'}" > "$TEST_DIR/invalid.env"
  if (load_version_env "$TEST_DIR/invalid.env") 2>/dev/null; then
    echo "Invalid version.env was accepted: $input" >&2
    exit 1
  fi
done

[[ ! -e "$NEVER_FILE" ]]
