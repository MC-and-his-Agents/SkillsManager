#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

select_tests() (
  UI_TEST_GROUPS="$1"
  UI_TEST_ONLY_TESTING="$2"
  source "$ROOT/Scripts/ui_test_selection.sh"
  ui_test_select || return 1
  printf 'selection=%s|%s|%s\n' \
    "$UI_TEST_SELECTION_MODE" "$UI_TEST_SELECTED_GROUPS" "$UI_TEST_SELECTED_COUNT"
  printf '%s\n' "${UI_TEST_ARGUMENTS[@]}"
)

default=$(select_tests "" "")
[[ "$default" == 'selection=full|full|20' ]] || fail "empty selection was not full"
unset_default=$(unset UI_TEST_GROUPS UI_TEST_ONLY_TESTING; source "$ROOT/Scripts/ui_test_selection.sh"; \
  ui_test_select; printf 'selection=%s|%s|%s\n' \
    "$UI_TEST_SELECTION_MODE" "$UI_TEST_SELECTED_GROUPS" "$UI_TEST_SELECTED_COUNT")
[[ "$unset_default" == "$default" ]] || fail "unset selection was not full"

source_methods=$(sed -nE \
  's/^[[:space:]]*func (test[A-Za-z0-9_]+)\(\).*/SkillsManagerUITests\/SkillsManagerUITests\/\1/p' \
  "$ROOT/UITests/SkillsManagerUITests/SkillsManagerUITests.swift")
registered=$(source "$ROOT/Scripts/ui_test_selection.sh"; for method in "${UI_TEST_REGISTERED_METHODS[@]}"; do
  printf '%s%s\n' "$UI_TEST_TARGET_PREFIX" "$method"
done)
[[ "$registered" == "$source_methods" ]] || fail "UI test registry does not match the XCTest source"

groups=$(select_tests 'core-smoke,local-skill,core-smoke' "")
grep -Fxq 'selection=groups|core-smoke,local-skill|8' <<< "$groups" \
  || fail "group selection or deduplication mismatch"
[[ "$(grep -c '^-only-testing:' <<< "$groups")" == 8 ]] || fail "selected tests were duplicated"

for group_count in \
  core-smoke:5 \
  local-skill:5 \
  remote-install:6 \
  update-distribution:2 \
  localization-accessibility:6 \
  full:20; do
  group=${group_count%:*}
  count=${group_count#*:}
  selected=$(select_tests "$group" "")
  grep -Fxq "selection=groups|$group|$count" <<< "$selected" \
    || fail "$group group mismatch"
done

identifier='SkillsManagerUITests/SkillsManagerUITests/testSM185UI11FeedbackBadgesAndBanner'
explicit=$(select_tests "" "$identifier")
grep -Fxq 'selection=tests|none|1' <<< "$explicit" || fail "explicit selection summary mismatch"
grep -Fxq -- "-only-testing:$identifier" <<< "$explicit" || fail "explicit identifier missing"

if select_tests unknown "" >/dev/null 2>&1; then fail "unknown group was accepted"; fi
if select_tests '../full' "" >/dev/null 2>&1; then fail "unsafe group was accepted"; fi
if select_tests 'core-smoke,' "" >/dev/null 2>&1; then fail "empty group was accepted"; fi
if select_tests "" 'SkillsManagerUITests/OtherTests/testUnknown' >/dev/null 2>&1; then
  fail "unknown identifier was accepted"
fi
if select_tests core-smoke "$identifier" >/dev/null 2>&1; then
  fail "ambiguous selectors were accepted"
fi

echo "PASS: UI test selection fixtures"
