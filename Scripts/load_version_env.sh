#!/usr/bin/env bash

load_version_env() {
  local version_file=${1:?"version.env path is required."}
  local line value
  local marketing_seen=0 build_seen=0

  MARKETING_VERSION=
  BUILD_NUMBER=

  [[ -f "$version_file" ]] || {
    echo "Missing version file: $version_file" >&2
    return 1
  }

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" && "$line" != *$'\r'* ]] || {
      echo "version.env contains a blank or CRLF line." >&2
      return 1
    }
    case "$line" in
      MARKETING_VERSION=*)
        ((marketing_seen == 0)) || {
          echo "MARKETING_VERSION must appear exactly once." >&2
          return 1
        }
        value=${line#MARKETING_VERSION=}
        [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
          echo "MARKETING_VERSION must be a stable numeric SemVer." >&2
          return 1
        }
        MARKETING_VERSION=$value
        marketing_seen=1
        ;;
      BUILD_NUMBER=*)
        ((build_seen == 0)) || {
          echo "BUILD_NUMBER must appear exactly once." >&2
          return 1
        }
        value=${line#BUILD_NUMBER=}
        [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
          echo "BUILD_NUMBER must be a positive integer." >&2
          return 1
        }
        BUILD_NUMBER=$value
        build_seen=1
        ;;
      *)
        echo "version.env contains an unknown or malformed entry." >&2
        return 1
        ;;
    esac
  done < "$version_file"

  ((marketing_seen == 1 && build_seen == 1)) || {
    echo "version.env must define MARKETING_VERSION and BUILD_NUMBER." >&2
    return 1
  }
  export MARKETING_VERSION BUILD_NUMBER
}
