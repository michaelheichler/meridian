#!/usr/bin/env bats

load test_helper
load gate_case_helper
load gate_case_files

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/remediation-round.sh"
  STATE_API="$REPO_ROOT/scripts/qa-remediation-state.sh"
  TEST_ROOT="$(mktemp -d)"
  cd "$TEST_ROOT"
  reset_case_failures
}

teardown() {
  cd "$REPO_ROOT"
  await_git_ai
  rm -rf "$TEST_ROOT"
}

fresh_phase() {
  PLANNING_DIR="$TEST_ROOT/$1/.lbwc-planning"
  PHASE_DIR="$PLANNING_DIR/phases/01-test"
  QA_STATE="$PHASE_DIR/remediation/qa/.qa-remediation-stage"
  UAT_STATE="$PHASE_DIR/remediation/uat/.uat-remediation-stage"
  mkdir -p "$PHASE_DIR"
}

fresh_git_phase() {
  fresh_phase "$1"
  ( cd "$TEST_ROOT/$1" && git init --quiet && git config user.email t@t && git config user.name T \
    && echo x > f && git add f && git commit -qm init )
  HEAD1=$(git -C "$TEST_ROOT/$1" rev-parse HEAD)
}

write_cap() {
  printf '{"max_uat_remediation_rounds": %s}\n' "$1" > "$PLANNING_DIR/config.json"
}

finish_qa_round() {
  bash "$SCRIPT" stage "$PHASE_DIR" qa execute >/dev/null
  bash "$SCRIPT" stage "$PHASE_DIR" qa verify >/dev/null
  bash "$SCRIPT" stage "$PHASE_DIR" qa done >/dev/null
}

@test "remediation-round open: creates, reuses, advances and caps rounds and anchors QA rounds to HEAD" {
  fresh_phase qa-new
  run bash "$SCRIPT" open "$PHASE_DIR" qa
  expect_case qa-new 0 "round=01"
  expect_output_has qa-new "round_dir=$PHASE_DIR/remediation/qa/round-01"
  expect_output_has qa-new "plan_path=$PHASE_DIR/remediation/qa/round-01/R01-PLAN.md"
  expect_path qa-new "$PHASE_DIR/remediation/qa/round-01"
  expect_file_line qa-new "$QA_STATE" '^stage=plan$'
  expect_file_line qa-new "$QA_STATE" '^round=01$'
  expect_file_line qa-new "$QA_STATE" '^round_started_at_commit='

  fresh_phase qa-reuse
  bash "$SCRIPT" open "$PHASE_DIR" qa >/dev/null
  run bash "$SCRIPT" open "$PHASE_DIR" qa
  expect_case qa-reuse 0 "round=01"
  expect_no_path qa-reuse "$PHASE_DIR/remediation/qa/round-02"

  fresh_phase qa-advance
  bash "$SCRIPT" open "$PHASE_DIR" qa >/dev/null
  finish_qa_round
  run bash "$SCRIPT" open "$PHASE_DIR" qa
  expect_case qa-advance 0 "round=02"
  expect_path qa-advance "$PHASE_DIR/remediation/qa/round-02"

  fresh_phase uat-new
  run bash "$SCRIPT" open "$PHASE_DIR" uat
  expect_case uat-new 0 "round=01"
  expect_file_line uat-new "$UAT_STATE" '^stage=plan$'
  expect_file_line uat-new "$UAT_STATE" '^layout=round-dir$'
  expect_no_file_line uat-new "$UAT_STATE" '^round_started_at_commit='

  fresh_phase uat-cap-reached
  write_cap 1
  bash "$SCRIPT" open "$PHASE_DIR" uat >/dev/null
  bash "$SCRIPT" stage "$PHASE_DIR" uat done >/dev/null
  run bash "$SCRIPT" open "$PHASE_DIR" uat
  expect_case uat-cap-reached 3 "cap_reached=true"
  expect_no_path uat-cap-reached "$PHASE_DIR/remediation/uat/round-02"

  fresh_phase uat-cap-plan-reopen
  write_cap 1
  bash "$SCRIPT" open "$PHASE_DIR" uat >/dev/null
  run bash "$SCRIPT" open "$PHASE_DIR" uat
  expect_case uat-cap-plan-reopen 0 "round=01"
  expect_no_path uat-cap-plan-reopen "$PHASE_DIR/remediation/uat/round-02"

  fresh_git_phase anchor-open
  run bash "$SCRIPT" open "$PHASE_DIR" qa
  expect_status anchor-open 0
  expect_file_line anchor-open "$QA_STATE" "^round_started_at_commit=$HEAD1$"

  fresh_git_phase anchor-kept
  bash "$SCRIPT" open "$PHASE_DIR" qa >/dev/null
  run bash "$SCRIPT" stage "$PHASE_DIR" qa execute
  expect_status anchor-kept 0
  expect_file_line anchor-kept "$QA_STATE" "^round_started_at_commit=$HEAD1$"

  fresh_git_phase anchor-new-round
  bash "$SCRIPT" open "$PHASE_DIR" qa >/dev/null
  finish_qa_round
  ( cd "$TEST_ROOT/anchor-new-round" && echo y >> f && git add f && git commit -qm second )
  HEAD2=$(git -C "$TEST_ROOT/anchor-new-round" rev-parse HEAD)
  run bash "$SCRIPT" open "$PHASE_DIR" qa
  expect_case anchor-new-round 0 "round=02"
  expect_file_line anchor-new-round "$QA_STATE" "^round_started_at_commit=$HEAD2$"

  fresh_git_phase anchor-uat-none
  run bash "$SCRIPT" open "$PHASE_DIR" uat
  expect_status anchor-uat-none 0
  expect_no_file_line anchor-uat-none "$UAT_STATE" '^round_started_at_commit='

  assert_no_case_failures
}

@test "remediation-round stage and current: move stages, report state, reject bad input and malformed invocations" {
  fresh_phase uat-execute
  bash "$SCRIPT" open "$PHASE_DIR" uat >/dev/null
  run bash "$SCRIPT" stage "$PHASE_DIR" uat execute
  expect_case uat-execute 0 "stage=execute"
  expect_file_line uat-execute "$UAT_STATE" '^stage=execute$'
  expect_file_line uat-execute "$UAT_STATE" '^round=01$'

  fresh_phase current-readonly
  bash "$SCRIPT" open "$PHASE_DIR" qa >/dev/null
  bash "$SCRIPT" stage "$PHASE_DIR" qa execute >/dev/null
  bash "$SCRIPT" stage "$PHASE_DIR" qa verify >/dev/null
  run bash "$SCRIPT" current "$PHASE_DIR" qa
  expect_case current-readonly 0 "stage=verify"
  expect_output_has current-readonly "round=01"
  expect_file_line current-readonly "$QA_STATE" '^stage=verify$'

  fresh_phase current-no-round
  run bash "$SCRIPT" current "$PHASE_DIR" qa
  expect_case current-no-round 1 "no active round"

  fresh_phase qa-skipped-stage
  bash "$SCRIPT" open "$PHASE_DIR" qa >/dev/null
  run bash "$SCRIPT" stage "$PHASE_DIR" qa verify
  expect_case qa-skipped-stage 1 "illegal QA stage transition: plan -> verify"
  expect_file_line qa-skipped-stage "$QA_STATE" '^stage=plan$'

  fresh_phase uat-unknown-stage
  bash "$SCRIPT" open "$PHASE_DIR" uat >/dev/null
  run bash "$SCRIPT" stage "$PHASE_DIR" uat sideways
  expect_case uat-unknown-stage 1 "unknown stage: sideways"
  expect_file_line uat-unknown-stage "$UAT_STATE" '^stage=plan$'

  fresh_phase uat-stage-without-round
  run bash "$SCRIPT" stage "$PHASE_DIR" uat execute
  expect_case uat-stage-without-round 1 "no active round"
  expect_no_path uat-stage-without-round "$UAT_STATE"

  fresh_phase usage-too-few-args
  run bash "$SCRIPT" open "$PHASE_DIR"
  expect_case usage-too-few-args 1 "usage: remediation-round.sh"

  fresh_phase usage-bad-kind
  run bash "$SCRIPT" open "$PHASE_DIR" bogus
  expect_case usage-bad-kind 1 "usage: remediation-round.sh"

  fresh_phase usage-missing-phase
  run bash "$SCRIPT" open "$TEST_ROOT/does-not-exist" uat
  expect_case usage-missing-phase 1 "no phase dir"

  fresh_phase usage-bad-action
  run bash "$SCRIPT" rewind "$PHASE_DIR" uat
  expect_case usage-bad-action 1 "usage: remediation-round.sh"

  assert_no_case_failures
}

@test "qa-remediation-state lifecycle: driver and state API share one stage file" {
  fresh_phase api-lifecycle
  run bash "$STATE_API" open "$PHASE_DIR"
  expect_case api-open 0 "stage=plan"
  expect_output_has api-open "round=01"

  run bash "$SCRIPT" stage "$PHASE_DIR" qa execute
  expect_case driver-execute 0 "stage=execute"

  run bash "$STATE_API" stage "$PHASE_DIR" verify
  expect_case api-verify 0 "stage=verify"

  run bash "$SCRIPT" current "$PHASE_DIR" qa
  expect_case driver-current 0 "stage=verify"
  expect_output_has driver-current "round=01"

  fresh_phase api-cap-plan-reopen
  write_cap 1
  bash "$STATE_API" open "$PHASE_DIR" >/dev/null
  run bash "$STATE_API" open "$PHASE_DIR"
  expect_case api-cap-plan-reopen 0 "round=01"
  expect_no_path api-cap-plan-reopen "$PHASE_DIR/remediation/qa/round-02"

  assert_no_case_failures
}

@test "qa-remediation-state lock: reclaims a dead writer lock and keeps a live one" {
  local lock_dir writer_pid

  fresh_phase lock-stale
  lock_dir="$PHASE_DIR/remediation/qa/.qa-remediation.lock"
  mkdir -p "$lock_dir"
  printf '%s\n' '999999' > "$lock_dir/pid"
  touch -t 200001010000 "$lock_dir"
  run env QA_REMEDIATION_LOCK_STALE_SECONDS=0 bash "$STATE_API" open "$PHASE_DIR"
  expect_case lock-stale 0 "stage=plan"
  expect_path lock-stale "$QA_STATE"
  expect_no_path lock-stale "$lock_dir"

  fresh_phase lock-pidless-aged
  lock_dir="$PHASE_DIR/remediation/qa/.qa-remediation.lock"
  mkdir -p "$lock_dir"
  touch -t 200001010000 "$lock_dir"
  run env QA_REMEDIATION_LOCK_STALE_SECONDS=5 bash "$STATE_API" open "$PHASE_DIR"
  expect_case lock-pidless-aged 0 "stage=plan"
  expect_no_path lock-pidless-aged "$lock_dir"

  fresh_phase lock-pidless-fresh
  lock_dir="$PHASE_DIR/remediation/qa/.qa-remediation.lock"
  mkdir -p "$lock_dir"
  run env QA_REMEDIATION_LOCK_STALE_SECONDS=3600 bash "$STATE_API" open "$PHASE_DIR"
  expect_case lock-pidless-fresh 1 "timed out acquiring QA remediation lock"
  expect_path lock-pidless-fresh "$lock_dir"

  fresh_phase lock-live
  lock_dir="$PHASE_DIR/remediation/qa/.qa-remediation.lock"
  sleep 30 &
  writer_pid=$!
  mkdir -p "$lock_dir"
  printf '%s\n' "$writer_pid" > "$lock_dir/pid"
  touch -t 200001010000 "$lock_dir"
  run env QA_REMEDIATION_LOCK_STALE_SECONDS=0 bash "$STATE_API" open "$PHASE_DIR"
  kill "$writer_pid" 2>/dev/null || true
  wait "$writer_pid" 2>/dev/null || true
  expect_case lock-live 1 "timed out acquiring QA remediation lock"
  expect_path lock-live "$lock_dir"
  expect_no_path lock-live "$QA_STATE"

  assert_no_case_failures
}

@test "qa-remediation-state init: records verification and known-issue inputs" {
  local real

  fresh_phase init-verification
  printf '%s\n' '---' 'result: FAIL' 'failed: 1' '---' '### P1' '- **Result:** fail' > "$PHASE_DIR/01-VERIFICATION.md"
  real="$(cd "$PHASE_DIR" && pwd -P)"
  run bash "$STATE_API" init "$PHASE_DIR"
  expect_case init-verification 0 "source_verification_path=$real/01-VERIFICATION.md"
  expect_output_has init-verification "source_fail_count=1"
  expect_output_has init-verification "input_mode=verification"
  expect_file_line init-verification "$QA_STATE" "^source_verification_path=$real/01-VERIFICATION.md$"

  fresh_phase init-completed-round
  mkdir -p "$PHASE_DIR/remediation/qa/round-01"
  printf '%s\n' 'stage=done' 'round=01' > "$QA_STATE"
  printf '%s\n' '---' 'result: FAIL' 'failed: 2' '---' > "$PHASE_DIR/remediation/qa/round-01/R01-VERIFICATION.md"
  real="$(cd "$PHASE_DIR" && pwd -P)"
  run bash "$STATE_API" open "$PHASE_DIR"
  expect_case init-completed-round 0 "round=02"
  expect_file_line init-completed-round "$QA_STATE" "^source_verification_path=$real/remediation/qa/round-01/R01-VERIFICATION.md$"
  expect_file_line init-completed-round "$QA_STATE" '^source_fail_count=2$'

  fresh_phase init-known-issues
  printf '%s\n' '{"schema_version":1,"phase":"01","issues":[{"signature":"0123456789ab","disposition":"unresolved"}]}' > "$PHASE_DIR/known-issues.json"
  run bash "$STATE_API" init "$PHASE_DIR"
  expect_case init-known-issues 0 "known_issues_status=present"
  expect_output_has init-known-issues "known_issues_count=1"
  expect_output_has init-known-issues "input_mode=known-issues"

  fresh_phase init-both
  printf '%s\n' '---' 'result: FAIL' 'failed: 1' '---' > "$PHASE_DIR/01-VERIFICATION.md"
  printf '%s\n' '{"schema_version":1,"phase":"01","issues":[{"signature":"0123456789ab","disposition":"unresolved"}]}' > "$PHASE_DIR/known-issues.json"
  run bash "$STATE_API" init "$PHASE_DIR"
  expect_case init-both 0 "source_fail_count=1"
  expect_output_has init-both "known_issues_count=1"
  expect_output_has init-both "input_mode=both"

  assert_no_case_failures
}
