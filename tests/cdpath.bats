#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test_helper

setup() {
  setup_temp_dir
  mkdir -p "$TEST_TEMP_DIR/decoy/scripts"
  cd "$PROJECT_ROOT"
}

teardown() {
  teardown_temp_dir
}

invoke_script() {
  local stdin_payload="$1"
  shift
  printf '%s' "$stdin_payload" | LBWC_PLANNING_DIR="$TEST_TEMP_DIR/.lbwc-planning" bash "$@"
}

assert_stdout_ignores_cdpath() {
  local baseline baseline_status

  run --separate-stderr invoke_script "$@"
  baseline="$output"
  baseline_status="$status"

  CDPATH="$TEST_TEMP_DIR/decoy" run --separate-stderr invoke_script "$@"

  [ "$status" -eq "$baseline_status" ]
  [ "$output" = "$baseline" ]
}

bats_test_function --description "bash-guard stdout is unchanged by a CDPATH that shadows the scripts dir" -- assert_stdout_ignores_cdpath '{"tool_input":{"command":"rm -rf /var/lib/mysql"}}' scripts/bash-guard.sh
bats_test_function --description "state-updater stdout is unchanged by a CDPATH that shadows the scripts dir" -- assert_stdout_ignores_cdpath '{"tool_input":{"file_path":"x.md"}}' scripts/state-updater.sh
bats_test_function --description "agent-lifecycle stdout is unchanged by a CDPATH that shadows the scripts dir" -- assert_stdout_ignores_cdpath '{}' scripts/agent-lifecycle.sh sweep
bats_test_function --description "todo-lifecycle stdout is unchanged by a CDPATH that shadows the scripts dir" -- assert_stdout_ignores_cdpath '' scripts/todo-lifecycle.sh bogus-command
