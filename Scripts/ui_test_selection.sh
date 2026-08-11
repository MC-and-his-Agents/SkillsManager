#!/usr/bin/env bash

UI_TEST_TARGET_PREFIX=SkillsManagerUITests/SkillsManagerUITests/
UI_TEST_REGISTERED_METHODS=(
  testSM168UI01Baseline
  testSM168UI02Filters
  testSM168UI03Pagination
  testSM168UI04ClawHubFailure
  testSM168UI04SkillsShFailure
  testSM168UI04RepositoryFailure
  testSM168UI05BatchImport
  testSM168UI06ArchiveSubsetImport
  testSM168UI06ArchiveCancelZeroWrite
  testSM168UI07RepositoryInstall
  testSM168UI07RepositoryCancelZeroWrite
  testSM168UI08EmptyKeyboardAndFocus
  testSM183UI09DetailActionBar
  testSM184UI10FilterBarAndRows
  testSM185UI11FeedbackBadgesAndBanner
  testSM194UI12NativeLocalization
  testSM194UI12NativeLocalizationEnglish
  testSM194UI12NativeLocalizationError
  testSM194UI12NativeLocalizationFeedbackDistribution
  testSM194UI12NativeLocalizationUnsupportedFallback
)

ui_test_group_is_registered() {
  case "$1" in
    core-smoke|local-skill|remote-install|update-distribution|localization-accessibility|full) return 0 ;;
    *) return 1 ;;
  esac
}

ui_test_group_methods() {
  case "$1" in
    core-smoke)
      printf '%s\n' testSM168UI01Baseline testSM168UI02Filters testSM168UI08EmptyKeyboardAndFocus \
        testSM183UI09DetailActionBar testSM184UI10FilterBarAndRows
      ;;
    local-skill)
      printf '%s\n' testSM168UI05BatchImport testSM168UI06ArchiveSubsetImport \
        testSM168UI06ArchiveCancelZeroWrite testSM168UI08EmptyKeyboardAndFocus \
        testSM183UI09DetailActionBar
      ;;
    remote-install)
      printf '%s\n' testSM168UI03Pagination testSM168UI04ClawHubFailure \
        testSM168UI04SkillsShFailure testSM168UI04RepositoryFailure \
        testSM168UI07RepositoryInstall testSM168UI07RepositoryCancelZeroWrite
      ;;
    update-distribution)
      printf '%s\n' testSM185UI11FeedbackBadgesAndBanner \
        testSM194UI12NativeLocalizationFeedbackDistribution
      ;;
    localization-accessibility)
      printf '%s\n' testSM184UI10FilterBarAndRows testSM194UI12NativeLocalization \
        testSM194UI12NativeLocalizationEnglish testSM194UI12NativeLocalizationError \
        testSM194UI12NativeLocalizationFeedbackDistribution \
        testSM194UI12NativeLocalizationUnsupportedFallback
      ;;
    full) printf '%s\n' "${UI_TEST_REGISTERED_METHODS[@]}" ;;
  esac
}

ui_test_identifier_is_registered() {
  local method
  for method in "${UI_TEST_REGISTERED_METHODS[@]}"; do
    [[ "$1" == "$UI_TEST_TARGET_PREFIX$method" ]] && return 0
  done
  return 1
}

ui_test_add_method() {
  local method="$1" argument existing
  argument="-only-testing:$UI_TEST_TARGET_PREFIX$method"
  for existing in "${UI_TEST_ARGUMENTS[@]}"; do
    [[ "$existing" == "$argument" ]] && return 0
  done
  UI_TEST_ARGUMENTS+=("$argument")
}

ui_test_add_group_name() {
  local group="$1"
  case ",${UI_TEST_SELECTED_GROUPS}," in
    *,"$group",*) return 0 ;;
  esac
  [[ -n "$UI_TEST_SELECTED_GROUPS" ]] && UI_TEST_SELECTED_GROUPS+=,
  UI_TEST_SELECTED_GROUPS+="$group"
}

ui_test_select() {
  local groups="${UI_TEST_GROUPS:-}" tests="${UI_TEST_ONLY_TESTING:-}"
  local item method
  local -a requested
  UI_TEST_ARGUMENTS=()
  UI_TEST_SELECTION_MODE=full
  UI_TEST_SELECTED_GROUPS=full
  UI_TEST_SELECTED_COUNT=${#UI_TEST_REGISTERED_METHODS[@]}

  if [[ -n "$groups" && -n "$tests" ]]; then
    echo "ERROR: set only one of UI_TEST_GROUPS or UI_TEST_ONLY_TESTING." >&2
    return 1
  fi
  if [[ -z "$groups" && -z "$tests" ]]; then
    return 0
  fi
  if [[ "$groups" == ,* || "$groups" == *, || "$groups" == *,,* \
    || "$tests" == ,* || "$tests" == *, || "$tests" == *,,* ]]; then
    echo "ERROR: UI test selectors must not contain empty values." >&2
    return 1
  fi

  UI_TEST_SELECTED_GROUPS=""
  if [[ -n "$groups" ]]; then
    UI_TEST_SELECTION_MODE=groups
    IFS=',' read -r -a requested <<< "$groups"
    for item in "${requested[@]}"; do
      if [[ -z "$item" ]] || ! ui_test_group_is_registered "$item"; then
        echo "ERROR: unknown UI test group." >&2
        return 1
      fi
      ui_test_add_group_name "$item"
      while IFS= read -r method; do
        ui_test_add_method "$method"
      done < <(ui_test_group_methods "$item")
    done
  else
    UI_TEST_SELECTION_MODE=tests
    UI_TEST_SELECTED_GROUPS=none
    IFS=',' read -r -a requested <<< "$tests"
    for item in "${requested[@]}"; do
      if [[ -z "$item" ]] || ! ui_test_identifier_is_registered "$item"; then
        echo "ERROR: unknown UI test identifier." >&2
        return 1
      fi
      ui_test_add_method "${item#"$UI_TEST_TARGET_PREFIX"}"
    done
  fi
  UI_TEST_SELECTED_COUNT=${#UI_TEST_ARGUMENTS[@]}
}
