#!/usr/bin/env bats

load test_helper

setup() {
  setup_temp_dir
  PLANNING_DIR="$TEST_TEMP_DIR/dir with space/.lbwc-planning"
  mkdir -p "$PLANNING_DIR/debugging/active"
}

teardown() {
  teardown_temp_dir
}

write_debug_session() {
  local session_status="$1" session_name="20260101-000000-bug.md"
  printf -- '---\nstatus: %s\n---\n' "$session_status" > "$PLANNING_DIR/debugging/active/$session_name"
  printf '%s\n' "$session_name" > "$PLANNING_DIR/debugging/.active-session"
}

@test "suggest-next offers the debug resume suggestion when no phases exist" {
  [ -x "$SCRIPTS_DIR/debug-session-state.sh" ]

  write_debug_session qa_pending
  run env LBWC_PLANNING_DIR="$PLANNING_DIR" bash "$SCRIPTS_DIR/suggest-next.sh" fix
  [ "$status" -eq 0 ]
  [[ "$output" == *"/lbwc:debug --resume -- Address remaining issues"* ]]

  write_debug_session uat_failed
  run env LBWC_PLANNING_DIR="$PLANNING_DIR" bash "$SCRIPTS_DIR/suggest-next.sh" debug
  [ "$status" -eq 0 ]
  [[ "$output" == *"Address UAT issues"* ]]
}
