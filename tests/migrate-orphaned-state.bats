#!/usr/bin/env bats

load test_helper
load gate_case_helper

setup() {
  setup_temp_dir
  export CLAUDE_SESSION_ID="covw2-migrate-$$"
  reset_case_failures
}

teardown() {
  cd "$PROJECT_ROOT"
  teardown_temp_dir
}

fresh_planning() {
  local dir="$TEST_TEMP_DIR/$1"
  mkdir -p "$dir/.lbwc-planning"
  cd "$dir" || return 1
}

archive_state() {
  mkdir -p ".lbwc-planning/milestones/$1"
  printf '%s\n' "# State" "$2" "## Todos" "- Carry this todo" > ".lbwc-planning/milestones/$1/STATE.md"
}

root_state_after_migrate() {
  bash "$SCRIPTS_DIR/migrate-orphaned-state.sh" "$@" || return
  cat .lbwc-planning/STATE.md 2>/dev/null || printf 'no-root-state\n'
}

@test "orphan migration rebuilds root STATE.md from the newest archived milestone only when it is missing" {
  fresh_planning no-planning-dir
  run root_state_after_migrate absent-planning
  expect_case no-planning-dir 0 "no-root-state"

  fresh_planning root-state-present
  printf 'keep this root state\n' > .lbwc-planning/STATE.md
  archive_state 01-old '**Project:** Archived'
  run root_state_after_migrate .lbwc-planning
  expect_case root-state-present 0 "keep this root state"
  expect_case_absent root-state-present "Archived"

  fresh_planning no-archived-state
  mkdir -p .lbwc-planning/milestones/01-empty
  run root_state_after_migrate .lbwc-planning
  expect_case no-archived-state 0 "no-root-state"

  fresh_planning newest-archive-wins
  archive_state 01-old '**Project:** Older'
  touch -t 202001010000 .lbwc-planning/milestones/01-old/STATE.md
  archive_state 02-new '**Project:** Fresh'
  run root_state_after_migrate .lbwc-planning
  expect_case newest-archive-wins 0 "**Project:** Fresh"
  expect_case newest-archive-wins 0 "- Carry this todo"

  fresh_planning archive-without-project
  archive_state 01-only 'no project line'
  run root_state_after_migrate .lbwc-planning
  expect_case archive-without-project 0 "**Project:** Unknown"

  assert_no_case_failures
}
