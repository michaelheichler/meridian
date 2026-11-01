#!/usr/bin/env bats

load test_helper
load gate_case_helper
load gate_case_files

setup() {
  setup_temp_dir
  reset_case_failures
  SCRIPT="$SCRIPTS_DIR/debug-start-manual.sh"
}

teardown() {
  teardown_temp_dir
}

expect_var() {
  local label=$1 name=$2 want=$3
  [ "${!name-}" = "$want" ] || record_case_failure "$label" "$name=[${!name-}] want=[$want]"
}

run_manual() {
  local planning=$1 input=$2 detail_status=$3 detail_json=$4 ref=$5
  run env DETAIL_STATUS="$detail_status" DETAIL_RESULT_JSON="$detail_json" REF_HASH="$ref" \
    bash -c 'printf %s "$1" | bash "$2" "$3"' _ "$input" "$SCRIPT" "$planning"
}

@test "debug-start-manual starts a session with a normalized description slug and detail" {
  local label input detail_status detail_json ref want_desc want_slug want_context want_files want_ref planning
  local session_file BUG_DESC SLUG MANUAL_REF MANUAL_DETAIL_CONTEXT MANUAL_DETAIL_FILES DETAIL_STATUS
  while IFS='|' read -r label input detail_status detail_json ref want_desc want_slug want_context want_files want_ref; do
    [ -n "$label" ] || continue
    planning="$BATS_TEST_TMPDIR/$label/.lbwc-planning"
    mkdir -p "$planning"
    session_file=""
    run_manual "$planning" "$input" "${detail_status:-none}" "$detail_json" "$ref"
    expect_case "$label" 0 ""
    eval "$output"
    expect_var "$label-desc" BUG_DESC "$want_desc"
    expect_var "$label-slug" SLUG "$want_slug"
    expect_var "$label-ref" MANUAL_REF "$want_ref"
    expect_var "$label-context" MANUAL_DETAIL_CONTEXT "$want_context"
    expect_var "$label-files" MANUAL_DETAIL_FILES "$want_files"
    expect_var "$label-status" DETAIL_STATUS "${detail_status:-none}"
    expect_file_line "$label-session-text" "$session_file" "^- \*\*Text:\*\* $want_desc\$"
    expect_file_line "$label-session-ref" "$session_file" "^- \*\*Ref:\*\* $want_ref\$"
  done <<'CASES'
strips-routing-metadata|  Parser crash (ref:abcd1234) --parallel  |||abcd1234|Parser crash|parser-crash||[]|abcd1234
strips-competing-flag|--competing Parser crash||||Parser crash|parser-crash||[]|none
punctuation-slug|Fix: parser!! (v2)||||Fix: parser!! (v2)|fix-parser-v2||[]|none
slug-cut-without-trailing-dash|alpha beta gamma delta epsilon zeta eta theta abc xyz||||alpha beta gamma delta epsilon zeta eta theta abc xyz|alpha-beta-gamma-delta-epsilon-zeta-eta-theta-abc||[]|none
detail-persisted|Parser crash|ok|{"status":"ok","detail":{"context":"Parser boundary","files":["src/parser.sh","tests/parser.bats"]}}||Parser crash|parser-crash|Parser boundary|["src/parser.sh","tests/parser.bats"]|none
detail-defaults|Parser crash|ok|{"status":"ok","detail":{}}||Parser crash|parser-crash||[]|none
detail-only-uses-debug-slug|--serial|ok|{"status":"ok","detail":{"context":"Parser boundary","files":[]}}|||debug|Parser boundary|[]|none
not-found-status-keeps-description|Parser crash|not_found|||Parser crash|parser-crash||[]|none
error-status-keeps-description|Parser crash|error|||Parser crash|parser-crash||[]|none
CASES

  assert_no_case_failures
}

@test "debug-start-manual rejects bad input without creating a session" {
  local label planning_arg input detail_status detail_json fragment planning
  while IFS='|' read -r label planning_arg input detail_status detail_json fragment; do
    [ -n "$label" ] || continue
    planning="$BATS_TEST_TMPDIR/$label/.lbwc-planning"
    mkdir -p "$planning"
    [ "$planning_arg" = "-" ] && planning=""
    run_manual "$planning" "$input" "${detail_status:-none}" "$detail_json" ""
    expect_case "$label" 1 "$fragment"
    expect_no_path "$label-no-session" "$BATS_TEST_TMPDIR/$label/.lbwc-planning/debugging/.active-session"
    expect_no_path "$label-no-active-dir" "$BATS_TEST_TMPDIR/$label/.lbwc-planning/debugging/active"
  done <<'CASES'
missing-planning-dir|-|Parser crash|||planning directory is required
invalid-detail-status|+|Parser crash|bogus||invalid detail status: bogus
ok-without-json|+|Parser crash|ok||detail status ok requires DETAIL_RESULT_JSON
malformed-files-detail|+|Parser crash|ok|{"status":"ok","detail":{"files":"src/parser.sh"}}|DETAIL_RESULT_JSON is invalid
non-string-file-entries|+|Parser crash|ok|{"status":"ok","detail":{"files":[1]}}|DETAIL_RESULT_JSON is invalid
json-status-not-ok|+|Parser crash|ok|{"status":"error"}|does not have status ok
not-json|+|Parser crash|ok|garbage|DETAIL_RESULT_JSON is invalid
empty-description|+| --competing (ref:abcd1234) |||bug description is empty
empty-description-with-not-found|+|--serial|not_found||bug description is empty
CASES

  assert_no_case_failures
}

@test "debug command delegates complete inline verification protocol" {
  command_file="$PROJECT_ROOT/commands/debug.md"
  reference_file="$PROJECT_ROOT/references/debug-inline-verification.md"

  grep -Fq '@${CLAUDE_PLUGIN_ROOT}/references/debug-inline-verification.md' "$command_file"
  [ "$(wc -l < "$command_file" | tr -d ' ')" -lt 500 ]
  grep -Fq 'Debug QA: Round {qa_round}' "$reference_file"
  grep -Fq 'Debug UAT: Round {uat_round}' "$reference_file"
  grep -Fq 'set status to `uat_pending`' "$reference_file"
  grep -Fq 'set status to `uat_failed`' "$reference_file"
  grep -Fq 'invoke AskUserQuestion as a tool call and wait' "$reference_file"
  grep -Fq 're-enter investigation Step 3' "$reference_file"
}
