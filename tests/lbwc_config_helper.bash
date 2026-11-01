#!/bin/bash
set -u

config_fixture_setup() {
  local test_root
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/lbwc-config.sh"
  MIGRATE="$REPO_ROOT/scripts/migrate-config.sh"
  test_root=$(mktemp -d)
  TEST_ROOT="$(cd "$test_root" && pwd -P)"
  PLANNING_DIR="$TEST_ROOT/.lbwc-planning"
  reset_case_failures
}

config_fixture_teardown() {
  rm -rf "$TEST_ROOT"
}

run_config() {
  run bash "$SCRIPT" "$@"
}

config_digest() {
  shasum -a 256 "$1/config.json" | awk '{print $1}'
}

expect_config_jq() {
  local label="$1" dir="$2" program="$3"
  jq -e "$program" "$dir/config.json" >/dev/null \
    || record_case_failure "$label" "config did not satisfy: $program"
}

init_config() {
  run_config init "$1"
  expect_case "init-$1" 0
}

set_accepted_row() {
  local label="$1" dir="$2" setting="$3" literal="$4" program="$5"
  run_config set "$dir" "$setting" "$literal"
  expect_case "$label" 0
  expect_config_jq "$label" "$dir" "$program"
}

reject_unchanged_row() {
  local label="$1" dir="$2" fragment="$3" before
  shift 3
  before=$(config_digest "$dir")
  run_config "$@"
  [ "$status" -ne 0 ] || record_case_failure "$label" "expected a failing status output=$output"
  [[ "$output" == *"$fragment"* ]] \
    || record_case_failure "$label" "missing fragment=[$fragment] output=$output"
  [ "$before" = "$(config_digest "$dir")" ] || record_case_failure "$label" "configuration changed"
}
