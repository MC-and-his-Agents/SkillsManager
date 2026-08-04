#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/Scripts/load_version_env.sh"
load_version_env "$ROOT/version.env"

EVENT_NAME=${GITHUB_EVENT_NAME:?
"GITHUB_EVENT_NAME is required."}
REF=${GITHUB_REF:?
"GITHUB_REF is required."}
REF_NAME=${GITHUB_REF_NAME:?
"GITHUB_REF_NAME is required."}
SHA=${GITHUB_SHA:?
"GITHUB_SHA is required."}
CANDIDATE_ENABLED=${RELEASE_CANDIDATE_ENABLED:-false}
PUBLISH_REQUESTED=${RELEASE_PUBLISH_REQUESTED:-false}

git fetch --no-tags origin main
main_sha=$(git rev-parse origin/main)

remote_ref_sha() {
  local ref="$1" direct peeled
  direct=$(git ls-remote origin "$ref" | awk 'NR == 1 { print $1 }')
  peeled=$(git ls-remote origin "${ref}^{}" | awk 'NR == 1 { print $1 }')
  printf '%s' "${peeled:-$direct}"
}

if [[ "$EVENT_NAME" == "workflow_dispatch" ]]; then
  if [[ "$PUBLISH_REQUESTED" == "true" ]]; then
    [[ "$REF" == refs/tags/v* && "$REF_NAME" == "v${MARKETING_VERSION}" ]] || {
      echo "Release publishing dispatch requires the matching v* tag." >&2
      exit 1
    }
    [[ "$(remote_ref_sha "$REF")" == "$SHA" ]] || {
      echo "Tag moved after the workflow started." >&2
      exit 1
    }
    git merge-base --is-ancestor "$SHA" "$main_sha" || {
      echo "Tag commit is not reachable from protected main." >&2
      exit 1
    }
    exit 0
  fi
  [[ "$CANDIDATE_ENABLED" == "true" ]] || {
    echo "Release candidates are disabled." >&2
    exit 1
  }
  [[ "$REF" == "refs/heads/main" && "$SHA" == "$main_sha" ]] || {
    echo "Release candidates must run from the current protected main." >&2
    exit 1
  }
  exit 0
fi

[[ "$EVENT_NAME" == "push" && "$REF" == refs/tags/v* ]] || {
  echo "Release publishing requires a v* tag push." >&2
  exit 1
}
[[ "$REF_NAME" == "v${MARKETING_VERSION}" ]] || {
  echo "Tag $REF_NAME does not match version.env (${MARKETING_VERSION})." >&2
  exit 1
}
[[ "$(remote_ref_sha "$REF")" == "$SHA" ]] || {
  echo "Tag moved after the workflow started." >&2
  exit 1
}
git merge-base --is-ancestor "$SHA" "$main_sha" || {
  echo "Tag commit is not reachable from protected main." >&2
  exit 1
}
