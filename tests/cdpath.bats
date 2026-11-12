#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test_helper
load gate_case_helper

setup() {
  setup_temp_dir
  reset_case_failures
  mkdir -p "$TEST_TEMP_DIR/decoy/scripts" "$TEST_TEMP_DIR/work"
  git -C "$TEST_TEMP_DIR/work" init -q
  ln -s "$SCRIPTS_DIR" "$TEST_TEMP_DIR/work/scripts"
  cd "$TEST_TEMP_DIR/work"
}

teardown() {
  teardown_temp_dir
}

invoke_script() {
  local stdin_payload="$1"
  shift
  printf '%s' "$stdin_payload" | MERIDIAN_PLANNING_DIR="$TEST_TEMP_DIR/.meridian" bash "$@"
}

expect_stdout_ignores_cdpath() {
  local label=$1 baseline baseline_status
  shift

  run --separate-stderr invoke_script "$@"
  baseline="$output"
  baseline_status="$status"

  CDPATH="$TEST_TEMP_DIR/decoy" run --separate-stderr invoke_script "$@"

  [ "$status" -eq "$baseline_status" ] \
    || record_case_failure "$label" "status=$status baseline=$baseline_status"
  [ "$output" = "$baseline" ] \
    || record_case_failure "$label" "stdout=[$output] baseline=[$baseline]"
}

@test "hook and lifecycle scripts keep their stdout when a CDPATH shadows the scripts dir" {
  expect_stdout_ignores_cdpath bash-guard '{"tool_input":{"command":"rm -rf /var/lib/mysql"}}' scripts/bash-guard.sh
  expect_stdout_ignores_cdpath state-updater '{"tool_input":{"file_path":"x.md"}}' scripts/state-updater.sh
  expect_stdout_ignores_cdpath agent-lifecycle '{}' scripts/agent-lifecycle.sh sweep
  expect_stdout_ignores_cdpath todo-lifecycle '' scripts/todo-lifecycle.sh bogus-command

  assert_no_case_failures
}
