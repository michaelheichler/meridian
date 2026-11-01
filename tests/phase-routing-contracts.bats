#!/usr/bin/env bats

load phase-detect-helpers
load gate_case_helper

setup() {
  pd_setup
  reset_case_failures
  PD_SCRIPTS_DIR="$SCRIPTS_DIR"
  PD_PATH_PREFIX=""
  PD_RAW=""
}

teardown() {
  await_git_ai
  pd_teardown
}

cutover_fixture() {
  local stage="$1" uat_status="$2" location="$3"
  rm -rf "$PD_PHASES"
  pd_project
  pd_done_flat 01-work
  pd_md "$PD_PHASES/01-work/01-VERIFICATION.md" '---' 'result: FAIL' 'writer: write-verification.sh' '---'
  pd_md "$PD_PHASES/01-work/remediation/qa/.qa-remediation-stage" "stage=$stage" 'round=04'
  pd_uat "$PD_PHASES/01-work/$location" "$uat_status" - 01
  case "$location" in
    remediation/uat/round-01/R01-UAT.md)
      pd_md "$PD_PHASES/01-work/remediation/uat/.uat-remediation-stage" 'stage=verify' 'round=01' 'layout=round-dir'
      ;;
  esac
}

@test "UAT cutover keeps stale QA remediation dormant across terminal and active UAT layouts" {
  local label stage uat_status location expected
  while IFS='|' read -r label stage uat_status location expected; do
    cutover_fixture "$stage" "$uat_status" "$location"
    pd_run
    expect_case "$label" 0 "next_phase_state=$expected"
    expect_case "$label-dormant" 0 'qa_after_uat_dormant=true'
    expect_case_absent "$label-no-qa-reentry" 'next_phase_state=needs_qa_remediation'
  done <<'CASES'
complete-root|plan|complete|01-UAT.md|all_done
active-root|verify|in_progress|01-UAT.md|needs_verification
complete-round|execute|complete|remediation/uat/round-01/R01-UAT.md|all_done
active-round|plan|in_progress|remediation/uat/round-01/R01-UAT.md|needs_verification
CASES
  assert_no_case_failures
}

@test "unrecognized and missing QA outcomes remain pending with an actionable reason" {
  local label fields reason
  while IFS='|' read -r label fields reason; do
    rm -rf "$PD_PHASES"
    pd_project
    pd_done_flat 01-work
    printf -- '---\nwriter: write-verification.sh\n%b\n---\n' "$fields" > "$PD_PHASES/01-work/01-VERIFICATION.md"
    pd_run
    expect_case "$label" 0 'qa_status=pending'
    expect_case "$label-reason" 0 "qa_reason=$reason"
  done <<'CASES'
legacy-unknown|status: undecided|verification_result_unrecognized
legacy-blank|status:|verification_result_missing
missing-outcome|phase: 01|verification_result_missing
result-overrides-legacy|result:\nstatus: PASS|verification_result_missing
unknown-result|result: undecided|verification_result_unrecognized
CASES
  assert_no_case_failures
}

@test "QA resume reads padded CRLF state values without changing the stored round" {
  pd_project
  pd_done_flat 01-work
  pd_md "$PD_PHASES/01-work/01-VERIFICATION.md" '---' 'result: FAIL' '---'
  mkdir -p "$PD_PHASES/01-work/remediation/qa"
  printf 'stage=  execute \r\nround=  07 \r\n' > "$PD_PHASES/01-work/remediation/qa/.qa-remediation-stage"
  pd_run
  expect_case padded-stage 0 'next_phase_state=needs_qa_remediation'
  expect_case padded-round 0 'qa_round=07'
  assert_no_case_failures
}
