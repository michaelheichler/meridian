#!/usr/bin/env bats

load test_helper
load gate_case_helper

setup() {
  setup_temp_dir
  export TMPDIR="$TEST_TEMP_DIR"
  reset_case_failures
}

teardown() {
  cd "$PROJECT_ROOT"
  teardown_temp_dir
}

fresh_phases() {
  local dir="$TEST_TEMP_DIR/$1"
  mkdir -p "$dir/.lbwc-planning/phases"
  cd "$dir" || return 1
}

rich_summary() {
  mkdir -p ".lbwc-planning/phases/$1"
  printf '%s\n' '---' "phase: \"$2\"" 'plan: 01' 'title: Parser setup' "status: $3" 'deviations: 1' 'commit_hashes: [abc123, def456]' '---' \
    '## What Was Built' '- Added the parser' '- Wired the CLI' '## Files Modified' '- a.sh' '- b.sh' '## Notes' '- ignored' \
    > ".lbwc-planning/phases/$1/$2-01-SUMMARY.md"
}

bare_summary() {
  mkdir -p ".lbwc-planning/phases/$1"
  printf '%s\n' '---' 'status: complete' '---' 'Body without sections' > ".lbwc-planning/phases/$1/$2-01-SUMMARY.md"
}

rolling_context() {
  bash "$SCRIPTS_DIR/compile-rolling-summary.sh" "$@" || return
  cat "$2" 2>/dev/null
}

@test "rolling summary compiles completed phase plans into the context file" {
  fresh_phases no-phases-dir
  run rolling_context .lbwc-planning/absent .lbwc-planning/ROLLING-CONTEXT.md
  expect_case no-phases-dir 0 "No prior completed phases."

  fresh_phases single-summary
  rich_summary 01-setup 01 complete
  run rolling_context .lbwc-planning/phases .lbwc-planning/ROLLING-CONTEXT.md
  expect_case single-summary 0 "No prior completed phases."

  fresh_phases none-complete
  rich_summary 01-setup 01 in-progress
  rich_summary 02-api 02 partial
  run rolling_context .lbwc-planning/phases .lbwc-planning/ROLLING-CONTEXT.md
  expect_case none-complete 0 "No prior completed phases."

  fresh_phases completed-plans
  rich_summary 01-setup 01 complete
  rich_summary 02-api 02 '"completed"'
  rich_summary 03-ui 03 in-progress
  run rolling_context .lbwc-planning/phases .lbwc-planning/ROLLING-CONTEXT.md
  expect_case completed-plans 0 "Compiled from 2 completed phase plan(s)"
  expect_case completed-plans 0 "## Phase 02 Plan 01: Parser setup"
  expect_case completed-plans 0 "Built: Added the parser"
  expect_case completed-plans 0 "Files: a.sh,b.sh"
  expect_case completed-plans 0 "Deviations: 1"
  expect_case completed-plans 0 "Commit: abc123"
  expect_case_absent completed-plans "## Phase 03"

  fresh_phases missing-fields
  bare_summary 01-setup 01
  bare_summary 02-api 02
  run rolling_context .lbwc-planning/phases .lbwc-planning/ROLLING-CONTEXT.md
  expect_case missing-fields 0 "## Phase ? Plan ?: Untitled"
  expect_case missing-fields 0 "Built: (no details)"
  expect_case missing-fields 0 "Files: (none listed)"
  expect_case missing-fields 0 "Deviations: 0"
  expect_case missing-fields 0 "Commit: none"

  fresh_phases unwritable-output
  rich_summary 01-setup 01 complete
  rich_summary 02-api 02 complete
  run bash "$SCRIPTS_DIR/compile-rolling-summary.sh" .lbwc-planning/phases absent-dir/ROLLING-CONTEXT.md
  expect_case unwritable-output 0 "WARNING"

  fresh_phases unwritable-empty-output
  run bash "$SCRIPTS_DIR/compile-rolling-summary.sh" .lbwc-planning/phases absent-dir/ROLLING-CONTEXT.md
  expect_case unwritable-empty-output 0 "WARNING"

  assert_no_case_failures
}
