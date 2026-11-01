#!/usr/bin/env bats

load test_helper
load gate_case_helper
load rejection_case_helper

setup() {
  setup_temp_dir
  REPO="$TEST_TEMP_DIR/repo"
  setup_unrelated_git_repo "$REPO"
  cd "$REPO" || return 1
  SCRIPT="$SCRIPTS_DIR/compile-debug-session-context.sh"
  SESSION="$REPO/.lbwc-planning/debug/session.md"
  mkdir -p "$(dirname "$SESSION")"
  EM_DASH=$'\xE2\x80\x94'
}

teardown() {
  cd "$PROJECT_ROOT" || true
  teardown_temp_dir
}

write_session() {
  {
    printf -- '---\nsession_id: 20261101-120000-crash\ntitle: Parser crash\nstatus: %s\n' "$1"
    printf 'qa_round: %s\nqa_last_result: %s\nuat_round: %s\nuat_last_result: %s\n---\n\n' "$2" "$3" "$4" "$5"
    printf '# Debug Session: Parser crash\n\n%s\n' "$6"
  } > "$SESSION"
}

full_body() {
  cat <<'BODY'
## Issue

Parser crashes on empty input.
## Repro
Run parse with no file.

## Source Todo

- **Ref:** abcd1234

## Investigation

### Root Cause

Missing guard in parse_line.

## Plan

Add an empty-input guard.

## Implementation

Guard added to parser.sh.

## QA

### Round 2 - FAIL

Header check failed.

## UAT

### Round 1 - issues_found

Button still misaligned.

## Remediation History

Archived round one.
BODY
}

issue_only_body() {
  printf '## Issue\n\nOnly the issue is known.\n'
}

expect_section() {
  local label="$1" heading="$2" content="$3" rest section
  rest="${output#*"$heading"$'\n'}"
  section="${rest%%$'\n## '*}"
  [[ "$output" == *"$heading"* && "$section" == *"$content"* ]] \
    || record_case_failure "$label" "section [$heading] lacks [$content] output=$output"
}

expect_absent() {
  [[ "$output" != *"$2"* ]] || record_case_failure "$1" "unexpected fragment=[$2] output=$output"
}

@test "the QA context lists the session facts, every recorded section and the prior QA rounds, and the UAT context adds the latest QA result and prior UAT rounds" {
  reset_case_failures

  write_session fix_applied 2 fail 1 issues_found "$(full_body)"
  run bash "$SCRIPT" "$SESSION" qa
  expect_case qa-full 0 "# Debug Session QA Context"
  expect_fragment qa-full "**Session:** 20261101-120000-crash"
  expect_fragment qa-full "**Status:** fix_applied"
  expect_fragment qa-full "**QA Round:** 2 (last result: fail)"
  expect_section qa-full "## Issue Summary" "Parser crashes on empty input."
  expect_fragment qa-full $'## Repro\nRun parse with no file.'
  expect_section qa-full "## Source Todo" "- **Ref:** abcd1234"
  expect_section qa-full "## Root Cause & Investigation" "Missing guard in parse_line."
  expect_section qa-full "## Fix Plan" "Add an empty-input guard."
  expect_section qa-full "## Implementation" "Guard added to parser.sh."
  expect_section qa-full "## Prior QA Rounds" "Header check failed."
  expect_absent qa-full "Button still misaligned."
  expect_absent qa-full "Archived round one."

  run bash "$SCRIPT" "$SESSION"
  expect_case mode-defaults-to-qa 0 "# Debug Session QA Context"

  run bash "$SCRIPT" "$SESSION" uat
  expect_case uat-full 0 "# Debug Session UAT Context"
  expect_fragment uat-full "**UAT Round:** 1 (last result: issues_found)"
  expect_section uat-full "## Latest QA Result" "QA round 2: fail"
  expect_section uat-full "## QA Details" "Header check failed."
  expect_section uat-full "## Prior UAT Rounds" "Button still misaligned."
  expect_absent uat-full "## Fix Plan"

  write_session investigating 0 pending 0 pending "$(issue_only_body)"
  run bash "$SCRIPT" "$SESSION" qa
  expect_case qa-issue-only 0
  expect_section qa-issue-only "## Issue Summary" "Only the issue is known."
  expect_fragment qa-issue-only "No source todo recorded."
  expect_fragment qa-issue-only "No investigation recorded."
  expect_fragment qa-issue-only "No plan recorded."
  expect_fragment qa-issue-only "No implementation recorded."
  expect_absent qa-issue-only "Prior QA Rounds"
  run bash "$SCRIPT" "$SESSION" uat
  expect_case uat-issue-only 0 "QA round 0: pending"
  expect_absent uat-issue-only "QA Details"
  expect_absent uat-issue-only "Prior UAT Rounds"

  write_session complete 1 skipped_no_fix_required 1 skipped_no_fix_required "## Issue"
  run bash "$SCRIPT" "$SESSION" qa
  expect_case qa-skipped-label 0 "(last result: skipped $EM_DASH no fix required)"
  expect_fragment qa-skipped-label "No issue description recorded."
  run bash "$SCRIPT" "$SESSION" uat
  expect_case uat-skipped-label 0 "**UAT Round:** 1 (last result: skipped $EM_DASH no fix required)"

  assert_no_case_failures
}

@test "the context compiler rejects a missing argument, a missing session file and an unknown mode" {
  reset_case_failures
  write_session investigating 0 pending 0 pending "$(issue_only_body)"

  run bash "$SCRIPT"
  expect_rejected no-argument "Usage: compile-debug-session-context.sh <session-file> [qa|uat]"
  run bash "$SCRIPT" "$REPO/absent.md" qa
  expect_rejected missing-file "session file not found: $REPO/absent.md"
  run bash "$SCRIPT" "$SESSION" verify
  expect_rejected unknown-mode "unknown context mode 'verify'. Valid: qa, uat"

  assert_no_case_failures
}
