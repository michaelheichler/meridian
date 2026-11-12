#!/usr/bin/env bats

load test_helper
load gate_case_helper

setup() {
  setup_temp_dir
  cd "$TEST_TEMP_DIR"
  reset_case_failures
}

teardown() {
  cd "$PROJECT_ROOT"
  teardown_temp_dir
}

marker_state() {
  bash "$SCRIPTS_DIR/mark-milestone-remediated.sh" "$@" || return
  printf 'archived-a=%s\n' "$(cat .meridian/milestones/m1/phases/01-a/.remediated 2>/dev/null)"
  printf 'archived-b=%s\n' "$(cat .meridian/milestones/m1/phases/02-b/.remediated 2>/dev/null)"
  printf 'active-phase=%s\n' "$(cat .meridian/phases/03-c/.remediated 2>/dev/null)"
}

@test "milestone remediation marks only archived phase dirs and rejects missing arguments" {
  local archived=.meridian/milestones/m1/phases
  mkdir -p "$archived/01-a" "$archived/02-b" .meridian/phases/03-c

  run bash "$SCRIPTS_DIR/mark-milestone-remediated.sh" .meridian
  expect_case missing-phase-list 1 "Usage"

  run bash "$SCRIPTS_DIR/mark-milestone-remediated.sh" absent-planning "$archived/01-a"
  expect_case missing-planning-dir 1 "absent-planning"

  run marker_state .meridian "$archived/01-a/|$archived/02-b|.meridian/phases/03-c|$archived/09-gone|"
  expect_case mixed-dirs 0 "marked_count=2"
  expect_case mixed-dirs 0 "skipped_count=2"
  expect_case mixed-dirs 0 "archived-a=acknowledged:start-fresh"
  expect_case mixed-dirs 0 "archived-b=acknowledged:start-fresh"
  expect_case_absent mixed-dirs "active-phase=acknowledged"

  assert_no_case_failures
}
