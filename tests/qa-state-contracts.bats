#!/usr/bin/env bats

load test_helper
load gate_case_helper

setup() {
  setup_temp_dir
  mkdir -p "$TEST_TEMP_DIR/project/.meridian/phases/01-work"
  cd "$TEST_TEMP_DIR/project"
  git init -q
  git config user.email test@example.invalid
  git config user.name Test
  git -c core.hooksPath=/dev/null commit --allow-empty -qm initial
  PHASE="$(pwd -P)/.meridian/phases/01-work"
  STATE="$PHASE/remediation/qa/.qa-remediation-stage"
  SCRIPT="$SCRIPTS_DIR/qa-remediation-state.sh"
  reset_case_failures
}

teardown() {
  await_git_ai
  cd "$PROJECT_ROOT"
  teardown_temp_dir
}

state_fixture() {
  mkdir -p "$(dirname "$STATE")"
  printf 'stage=%s\nround=03\nround_started_at_commit=%s\n' "$1" "$(git rev-parse HEAD)" > "$STATE"
}

@test "QA stage changes accept only the current stage or the immediate successor" {
  local label current requested expected_status expected_stage
  while IFS='|' read -r label current requested expected_status expected_stage; do
    state_fixture "$current"
    run bash "$SCRIPT" stage "$PHASE" "$requested"
    expect_case "$label" "$expected_status"
    run bash "$SCRIPT" get "$PHASE"
    expect_case "$label-state" 0 "$expected_stage"$'\n''round=03'
  done <<'CASES'
start-execution|plan|execute|0|execute
start-verification|execute|verify|0|verify
finish-round|verify|done|0|done
idempotent-plan|plan|plan|0|plan
idempotent-done|done|done|0|done
cannot-skip-execution|plan|verify|1|plan
cannot-reopen-done|done|plan|1|done
cannot-go-back|verify|execute|1|verify
unknown-stage|plan|garbage|1|plan
CASES
  assert_no_case_failures
}

source_fixture() {
  local failures="$1" known="$2"
  rm -rf "$PHASE/remediation" "$PHASE/known-issues.json" "$PHASE/01-VERIFICATION.md"
  printf -- '---\nresult: FAIL\nfailed: %s\n---\n| ID | Status |\n| F1 | FAIL |\n' "$failures" > "$PHASE/01-VERIFICATION.md"
  [ "$known" = 0 ] || printf '%s\n' '{"schema_version":1,"phase":"01","issues":[{"signature":"abcdef123456","test":"case","file":"app.py","error":"broken"}]}' > "$PHASE/known-issues.json"
}

@test "QA initialization reports whether verification failures and known issues need remediation" {
  local label failures known expected_mode expected_count
  while IFS='|' read -r label failures known expected_mode expected_count; do
    source_fixture "$failures" "$known"
    run bash "$SCRIPT" init "$PHASE"
    expect_case "$label-mode" 0 "input_mode=$expected_mode"
    expect_case "$label-count" 0 "source_fail_count=$expected_count"
    expect_case "$label-source" 0 "source_verification_path=$PHASE/01-VERIFICATION.md"
  done <<'CASES'
verification-only|2|0|verification|2
known-only|0|1|known-issues|0
combined|2|1|both|2
no-inputs|0|0|none|0
fallback-row-count|invalid|0|verification|1
CASES
  assert_no_case_failures
}

@test "QA mutations reclaim abandoned locks without losing the current round" {
  local label owner lock
  lock="$PHASE/remediation/qa/.qa-remediation.lock"
  while IFS='|' read -r label owner; do
    state_fixture plan
    mkdir -p "$lock"
    printf '%s\n' "$owner" > "$lock/pid"
    run bash "$SCRIPT" advance "$PHASE"
    expect_case "$label" 0 'execute'
    expect_case "$label-round" 0 'round=03'
  done <<'CASES'
zero-owner|0
invalid-owner|abandoned
CASES
  state_fixture plan
  mkdir -p "$lock"
  touch -t 200001010000 "$lock"
  run bash "$SCRIPT" advance "$PHASE"
  expect_case old-ownerless-lock 0 'execute'
  assert_no_case_failures
}

@test "opening QA remediation resumes a planning round and caps creation of later rounds" {
  local label current maximum expected_status expected_round
  while IFS='|' read -r label current maximum expected_status expected_round; do
    state_fixture "$current"
    printf '{"max_uat_remediation_rounds":%s}\n' "$maximum" > .meridian/config.json
    run bash "$SCRIPT" open "$PHASE"
    expect_case "$label" "$expected_status"
    run bash "$SCRIPT" get "$PHASE"
    expect_case "$label-round" 0 "round=$expected_round"
  done <<'CASES'
resume-planning-at-cap|plan|3|0|03
next-after-done|done|5|0|04
next-after-verification|verify|5|0|04
cap-preserves-round|done|3|3|03
CASES
  assert_no_case_failures
}

@test "advancing QA stages stops at done and preserves the source commit" {
  local label current expected anchor
  anchor=$(git rev-parse HEAD)
  while IFS='|' read -r label current expected; do
    state_fixture "$current"
    run bash "$SCRIPT" advance "$PHASE"
    expect_case "$label" 0 "$expected"$'\n''round=03'
    expect_case "$label-anchor" 0 "round_started_at_commit=$anchor"
  done <<'CASES'
execute-to-verify|execute|verify
verify-to-done|verify|done
done-stays-done|done|done
CASES
  assert_no_case_failures
}

@test "QA read and mutation commands refuse paths outside active planning phases" {
  local label path
  mkdir -p "$TEST_TEMP_DIR/project/.meridian/milestones/v1/phases/01-old" "$TEST_TEMP_DIR/project/elsewhere"
  while IFS='|' read -r label path; do
    run bash "$SCRIPT" init "$TEST_TEMP_DIR/project/$path"
    expect_case "$label" 1
  done <<'CASES'
archived-milestone|.meridian/milestones/v1/phases/01-old
outside-planning|elsewhere
CASES
  assert_no_case_failures
}
