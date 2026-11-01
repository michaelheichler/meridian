#!/usr/bin/env bats

load test_helper
load gate_case_helper
load gate_case_files
load text_case_helper

setup() {
  WORK="$BATS_TEST_TMPDIR/work"
  PHASE="$WORK/.lbwc-planning/phases/01-core"
  mkdir -p "$PHASE" "$BATS_TEST_TMPDIR/home"
  export HOME="$BATS_TEST_TMPDIR/home"
  git init -q "$WORK"
  cd "$WORK"
  VALIDATE="$SCRIPTS_DIR/validate-summary.sh"
  reset_case_failures
}

teardown() {
  await_git_ai
}

summary() {
  local name=$1 status_line=$2
  shift 2
  write_text "$PHASE/$name-SUMMARY.md" "---" "$status_line" "$@" "---" "" \
    "## What Was Built" "" "A thing" "" "## Files Modified" "" "- a.sh"
  printf '%s\n' "$PHASE/$name-SUMMARY.md"
}

plan_with_must_haves() {
  write_text "$PHASE/$1-PLAN.md" "---" "must_haves:" "  - works offline" "---"
}

validate() {
  run bash "$VALIDATE" "$@" <<< "{\"tool_input\": {\"file_path\": \"$FILE\"}}"
}

expect_context() {
  local label=$1 fragment=$2
  expect_status "$label" 0
  expect_jq_output "$label-context" \
    ".hookSpecificOutput.hookEventName == \"PostToolUse\" and (.hookSpecificOutput.additionalContext | contains(\"$fragment\"))"
}

@test "validate-summary stays silent for files it does not own or that pass" {
  FILE="$WORK/README.md"
  write_text "$FILE" "# Readme"
  validate
  expect_case_silent "not-a-summary" 0

  FILE="$PHASE/09-01-SUMMARY.md"
  validate
  expect_case_silent "summary-not-written" 0

  FILE=$(summary 01-01 "status: complete")
  validate
  expect_case_silent "complete-without-plan" 0

  FILE=$(summary 01-02 'status: "partial"')
  validate
  expect_case_silent "quoted-partial" 0

  plan_with_must_haves 01-03
  FILE=$(summary 01-03 "status: failed" "ac_results:" "  - id: AC1" "    verdict: pass" "  - id: AC2" "    verdict: fail")
  validate
  expect_case_silent "valid-ac-verdicts" 0

  write_text "$PHASE/01-04-PLAN.md" "---" "must_haves: []" "---"
  FILE=$(summary 01-04 "status: complete")
  validate
  expect_case_silent "empty-must-haves" 0

  plan_with_must_haves R01
  FILE=$(summary R01 "status: complete")
  validate
  expect_case_silent "remediation-skips-ac-check" 0

  FILE=$(summary 01-05 "status: completed")
  validate PreToolUse
  expect_case_silent "non-post-tool-event" 0

  assert_no_case_failures
}

@test "validate-summary reports each SUMMARY.md contract violation as hook context" {
  FILE="$PHASE/01-01-SUMMARY.md"
  write_text "$FILE" "# Summary" "## What Was Built" "## Files Modified"
  validate
  expect_context "no-frontmatter" "frontmatter"
  expect_output_lacks "no-frontmatter-skips-status-check" "'status'"

  FILE=$(summary 01-02 "phase: 1")
  validate
  expect_context "missing-status" "'status'"

  FILE=$(summary 01-03 "status: completed")
  validate
  expect_context "completed-alias" "'completed'"

  FILE=$(summary 01-04 "status: in_progress")
  validate
  expect_context "in-progress" "'in_progress'"

  FILE=$(summary 01-05 "status: done")
  validate
  expect_context "unknown-status" "'done'"

  FILE="$PHASE/01-06-SUMMARY.md"
  write_text "$FILE" "---" "status: complete" "---"
  validate
  expect_context "missing-built-section" "What Was Built"
  expect_context "missing-files-section" "Files Modified"

  write_text "$PHASE/01-07-PLAN.md" "---" "must_haves: [works offline]" "---"
  FILE=$(summary 01-07 "status: complete")
  validate
  expect_context "inline-must-haves-need-ac-results" "ac_results"

  plan_with_must_haves 01-08
  FILE=$(summary 01-08 "status: complete" "ac_results:" "  - id: AC1" "    verdict: maybe")
  validate
  expect_context "invalid-verdict" "'maybe'"

  assert_no_case_failures
}
