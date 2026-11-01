#!/usr/bin/env bats

load test_helper
load gate_case_helper

setup() {
  setup_temp_dir
  mkdir -p "$TEST_TEMP_DIR/project/.lbwc-planning/phases/01-work"
  cd "$TEST_TEMP_DIR/project"
  git init -q
  git config user.email test@example.invalid
  git config user.name Test
  git -c core.hooksPath=/dev/null commit --allow-empty -qm initial
  PHASE="$(pwd -P)/.lbwc-planning/phases/01-work"
  printf '{"max_uat_remediation_rounds":9}\n' > .lbwc-planning/config.json
  reset_case_failures
}

teardown() {
  await_git_ai
  cd "$PROJECT_ROOT"
  teardown_temp_dir
}

prepare_fixture() {
  local location="$1" contents="$2"
  rm -rf "$PHASE"
  mkdir -p "$PHASE/$(dirname "$location")"
  printf '%b\n' "$contents" > "$PHASE/$location"
  printf -- '---\nphase: 01\nstatus: issues_found\n---\n### P1: Checkout\n- **Result:** issue\n' > "$PHASE/01-UAT.md"
}

@test "reverification migrates legacy stage layouts and stages the archived UAT in its repository" {
  local label location contents
  while IFS='|' read -r label location contents; do
    prepare_fixture "$location" "$contents"
    run bash "$SCRIPTS_DIR/prepare-reverification.sh" "$PHASE/"
    expect_case "$label" 0 'round_file=01-UAT-round-01.md'
    run git diff --cached --name-only -- "$PHASE/01-UAT-round-01.md"
    expect_case "$label-archive-staged" 0 '01-UAT-round-01.md'
    run bash "$SCRIPTS_DIR/uat-remediation-state.sh" current-round "$PHASE"
    expect_case "$label-next-round" 0 '02'
  done <<'CASES'
intermediate-scalar|remediation/.uat-remediation-stage|verify
root-scalar|.uat-remediation-stage|done
root-key-value|.uat-remediation-stage|stage=verify\nround=01
CASES
  assert_no_case_failures
}

@test "reverification finalizes answered checkpoints before archiving and opening the next round" {
  prepare_fixture .uat-remediation-stage 'stage=verify\nround=01'
  printf -- '---\nphase: 01\nstatus: in_progress\n---\n## Tests\n### P1: Checkout\n- **Result:** issue\n### P2: Receipt\n- **Result:** pass\n' > "$PHASE/01-UAT.md"
  run bash "$SCRIPTS_DIR/prepare-reverification.sh" "$PHASE"
  expect_case finalized-transition 0 'round_file=01-UAT-round-01.md'
  run awk '/^(passed|issues|total_tests):/ { print }' "$PHASE/01-UAT-round-01.md"
  expect_case archived-pass-count 0 'passed: 1'
  expect_case archived-issue-count 0 'issues: 1'
  expect_case archived-total-count 0 'total_tests: 2'
  assert_no_case_failures
}
