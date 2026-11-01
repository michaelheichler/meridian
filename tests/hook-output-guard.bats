#!/usr/bin/env bats

load test_helper
load gate_case_helper

setup() {
  mkdir -p "$BATS_TEST_TMPDIR/home"
  export HOME="$BATS_TEST_TMPDIR/home"
  cd "$BATS_TEST_TMPDIR"
  GUARD="$SCRIPTS_DIR/lib/hook-output-guard.sh"
  reset_case_failures
}

@test "hook-output-guard allows output only for events that accept hook context" {
  run bash "$GUARD" SessionStart
  expect_case_silent "session-start" 0
  run bash "$GUARD" PostToolUse
  expect_case_silent "post-tool-use" 0
  run bash "$GUARD" PreCompact
  expect_case_silent "pre-compact" 0
  run bash "$GUARD" Stop
  expect_case_silent "stop" 1
  run bash "$GUARD"
  expect_case_silent "no-event" 1

  run bash -c '. "$1"; should_emit_hook_output SubagentStop; printf "sourced-rc=%s" "$?"' _ "$GUARD"
  expect_case "sourced-returns-without-exit" 0 "sourced-rc=1"

  assert_no_case_failures
}
