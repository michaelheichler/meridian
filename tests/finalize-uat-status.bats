#!/usr/bin/env bats

load test_helper
load gate_case_helper
load gate_case_files

setup() {
  setup_temp_dir
  reset_case_failures
  FINALIZE="$SCRIPTS_DIR/finalize-uat-status.sh"
  PHASE_DIR="$TEST_TEMP_DIR/repo/.meridian/phases/01-checkout"
  UAT_FILE="$PHASE_DIR/01-UAT.md"
  mkdir -p "$PHASE_DIR"
  cd "$TEST_TEMP_DIR/repo" || return 1
  git init -q
}

teardown() {
  cd "$BATS_TEST_DIRNAME" || true
  teardown_temp_dir
}

write_uat() {
  printf '%s\n' "$@" > "$UAT_FILE"
}

finalize() {
  run bash "$FINALIZE" "$UAT_FILE"
}

@test "finalize-uat-status derives the UAT status and counts from checkpoint results and rewrites the frontmatter" {
  write_uat '---' 'status: in_progress' 'completed:' 'passed: 0' 'skipped: 0' 'issues: 0' 'total_tests: 0' 'owner: shop' '---' \
    '### P1: Cart' '- **Result:** PASS' '### P2-T1: Pay' '- **Result:** skipped' '## Notes' 'free text'
  finalize
  expect_case complete 0 "status=complete passed=1 skipped=1 issues=0 total=2"
  expect_file_line complete "$UAT_FILE" '^status: complete$'
  expect_file_line complete "$UAT_FILE" '^completed: [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$'
  expect_file_line complete "$UAT_FILE" '^total_tests: 2$'
  expect_file_line complete "$UAT_FILE" '^owner: shop$'
  expect_file_line complete "$UAT_FILE" '^free text$'

  write_uat '---' 'status: in_progress' '---' '### P1: Cart' '- **Result:** pass' '### D1: Drift' '- **Result:** Partial fix'
  finalize
  expect_case issues 0 "status=issues_found passed=1 skipped=0 issues=1 total=2"
  expect_file_line issues "$UAT_FILE" '^issues: 1$'
  expect_file_line issues "$UAT_FILE" '^passed: 1$'
  expect_file_line issues "$UAT_FILE" '^skipped: 0$'
  expect_file_line issues "$UAT_FILE" '^completed: [0-9]'

  write_uat '---' 'status: complete' 'completed: 2026-01-01' '---' '### P1: Cart' '- **Result:** pass' '### P2: Pay' '- **Result:** {pass|skip|issue}'
  finalize
  expect_case placeholder-reopens 0 "status=in_progress passed=1"
  expect_file_line placeholder-reopens "$UAT_FILE" '^status: in_progress$'
  expect_file_line placeholder-reopens "$UAT_FILE" '^completed:$'

  write_uat '---' 'status: complete' '---' '# No checkpoints'
  finalize
  expect_case no-checkpoints 0 "status=in_progress passed=0 skipped=0 issues=0 total=0"
  expect_file_line no-checkpoints "$UAT_FILE" '^completed:$'

  write_uat '---' 'status: in_progress' '---' '### P1: Cart' '- **Result:** maybe later'
  finalize
  expect_case unknown-result 1 "unrecognized Result value: maybe later"
  expect_file_line unknown-result "$UAT_FILE" '^status: in_progress$'

  write_uat '---' 'status: in_progress' '---' '### P1: Cart' '### Notes'
  finalize
  expect_case missing-result-before-heading 1 "missing Result line in test block"

  write_uat '# UAT' '### P1: Cart' '- **Result:** pass'
  finalize
  expect_case no-frontmatter 1 "missing YAML frontmatter block"

  write_uat '---' 'status: in_progress'
  finalize
  expect_case unclosed-frontmatter 1 "missing YAML frontmatter block"

  run bash "$FINALIZE" "$PHASE_DIR/absent-UAT.md"
  expect_case missing-file 1 "UAT file not found"

  assert_no_case_failures
}
