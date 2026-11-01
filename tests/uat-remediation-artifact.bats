#!/usr/bin/env bats

load test_helper
load gate_case_helper
load gate_case_files

setup() {
  setup_temp_dir
  reset_case_failures
  VALIDATOR="$SCRIPTS_DIR/validate-uat-remediation-artifact.sh"
  mkdir -p "$TEST_TEMP_DIR/repo"
  cd "$TEST_TEMP_DIR/repo" || return 1
  TEST_ROOT=$(pwd -P)
  git init -q
}

teardown() {
  cd "$BATS_TEST_DIRNAME" || true
  teardown_temp_dir
}

phase_dir() {
  printf '%s/%s/.lbwc-planning/phases/01-checkout\n' "$TEST_ROOT" "$1"
}

research_lines() {
  printf '%s\n' '---' 'phase: 1' 'round: 1' 'title: Checkout fix' 'type: remediation-research' '---' \
    '## Findings' 'The cart drops items.' '## Root Cause Assessment' 'A stale cache.'
}

plan_lines() {
  printf '%s\n' '---' 'phase: 1' "round: ${DOC_ROUND:-1}" 'title: Checkout fix' 'type: remediation' 'fail_classifications: [code]' \
    'known_issues_input: []' 'known_issue_resolutions: []' '---' '<tasks>' '</tasks>' '<verification>' '</verification>'
}

summary_lines() {
  printf '%s\n' '---' 'phase: 1' 'round: 1' 'title: Checkout fix' 'type: remediation' 'status: complete' \
    'tasks_completed: 2' 'tasks_total: 2' 'known_issue_outcomes: []' '---' '# Summary'
}

write_doc() {
  mkdir -p "$(dirname "$1")"
  "$2" | grep -v -e "${3:-^$}" > "$1" || true
}

write_state() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "${@:2}" > "$1"
}

validate() {
  run bash "$VALIDATOR" "$1" "$2"
}

@test "validate-uat-remediation-artifact checks research artifacts and rejects non-canonical or misplaced paths" {
  local round_dir legacy_dir
  round_dir="$(phase_dir rd)/remediation/uat/round-01"
  write_doc "$round_dir/R01-RESEARCH.md" research_lines
  validate research "$round_dir/R01-RESEARCH.md"
  expect_case valid-round-dir 0 "artifact_valid=true"

  write_doc "$round_dir/R01-RESEARCH.md" research_lines '^type:'
  validate research "$round_dir/R01-RESEARCH.md"
  expect_case missing-type 1 "research artifact type must be remediation-research"

  write_doc "$round_dir/R01-RESEARCH.md" research_lines '^## Findings'
  validate research "$round_dir/R01-RESEARCH.md"
  expect_case missing-findings 1 "research artifact missing Findings section"

  write_doc "$round_dir/R01-RESEARCH.md" research_lines '^## Root Cause'
  validate research "$round_dir/R01-RESEARCH.md"
  expect_case missing-root-cause 1 "research artifact missing Root Cause Assessment section"

  write_doc "$round_dir/R01-RESEARCH.md" research_lines '^---'
  validate research "$round_dir/R01-RESEARCH.md"
  expect_case no-frontmatter 1 "artifact missing YAML frontmatter"

  write_doc "$round_dir/R01-RESEARCH.md" research_lines '^phase:'
  validate research "$round_dir/R01-RESEARCH.md"
  expect_case missing-phase 1 "artifact frontmatter missing numeric phase"

  write_doc "$round_dir/R01-RESEARCH.md" research_lines '^round:'
  validate research "$round_dir/R01-RESEARCH.md"
  expect_case missing-round 1 "artifact frontmatter missing numeric round"

  write_doc "$round_dir/R01-RESEARCH.md" research_lines '^title:'
  validate research "$round_dir/R01-RESEARCH.md"
  expect_case missing-title 1 "artifact frontmatter missing title"

  write_doc "$(phase_dir rd)/remediation/uat/round-02/R02-RESEARCH.md" research_lines
  validate research "$(phase_dir rd)/remediation/uat/round-02/R02-RESEARCH.md"
  expect_case round-mismatch 1 "artifact frontmatter round must match round directory"

  : > "$round_dir/R01-RESEARCH.md"
  validate research "$round_dir/R01-RESEARCH.md"
  expect_case empty-file 1 "artifact file is empty"

  rm -f "$round_dir/R01-RESEARCH.md"
  validate research "$round_dir/R01-RESEARCH.md"
  expect_case missing-file 1 "artifact file does not exist"

  validate research "rd/R01-RESEARCH.md"
  expect_case relative-path 1 "artifact path must be absolute"

  validate research "$TEST_ROOT/absent/R01-RESEARCH.md"
  expect_case missing-parent 1 "parent directory does not exist or cannot be canonicalized"

  write_doc "$round_dir/R01-RESEARCH.md" research_lines
  ln -s "$TEST_ROOT/rd" "$TEST_ROOT/rd-link"
  validate research "$TEST_ROOT/rd-link/.lbwc-planning/phases/01-checkout/remediation/uat/round-01/R01-RESEARCH.md"
  expect_case symlinked-dir 1 "artifact path must be the exact canonical host path"

  write_doc "$round_dir/notes.md" research_lines
  ln -s notes.md "$round_dir/R09-RESEARCH.md"
  validate research "$round_dir/R09-RESEARCH.md"
  expect_case relative-file-link 1 "artifact path must be the exact canonical host path"

  ln -s "$round_dir/notes.md" "$round_dir/R08-RESEARCH.md"
  validate research "$round_dir/R08-RESEARCH.md"
  expect_case absolute-file-link 1 "artifact path must be the exact canonical host path"

  ln -s R06-RESEARCH.md "$round_dir/R07-RESEARCH.md"
  ln -s R07-RESEARCH.md "$round_dir/R06-RESEARCH.md"
  validate research "$round_dir/R07-RESEARCH.md"
  expect_case link-loop 1 "parent directory does not exist or cannot be canonicalized"

  write_doc "$TEST_ROOT/side/.claude/worktrees/agent-x1/.lbwc-planning/phases/01-c/remediation/uat/round-01/R01-RESEARCH.md" research_lines
  validate research "$TEST_ROOT/side/.claude/worktrees/agent-x1/.lbwc-planning/phases/01-c/remediation/uat/round-01/R01-RESEARCH.md"
  expect_case sidechain 1 "artifact path points at a Claude sidechain"

  write_doc "$(phase_dir rd)/remediation/uat/round-1/R01-RESEARCH.md" research_lines
  validate research "$(phase_dir rd)/remediation/uat/round-1/R01-RESEARCH.md"
  expect_case unpadded-round-dir 1 "artifact path must match the expected round-dir RESEARCH filename shape"

  write_doc "$(phase_dir rd)/remediation/uat/round-1a/R01-RESEARCH.md" research_lines
  validate research "$(phase_dir rd)/remediation/uat/round-1a/R01-RESEARCH.md"
  expect_case non-numeric-round-dir 1 "artifact path must match the expected round-dir RESEARCH filename shape"

  validate research "$round_dir/notes.md"
  expect_case wrong-file-name 1 "artifact path must match the expected round-dir RESEARCH filename shape"

  write_doc "$round_dir/R03-RESEARCH.md" research_lines
  validate research "$round_dir/R03-RESEARCH.md"
  expect_case file-round-mismatch 1 "artifact round token must match round directory"

  write_doc "$(phase_dir rd)/remediation/qa/round-01/R01-RESEARCH.md" research_lines
  validate research "$(phase_dir rd)/remediation/qa/round-01/R01-RESEARCH.md"
  expect_case qa-research 1 "QA remediation validation currently supports plan artifacts only"

  legacy_dir=$(phase_dir legacy)
  write_state "$legacy_dir/.uat-remediation-stage" stage=research
  write_doc "$legacy_dir/01-RESEARCH.md" research_lines
  validate research "$legacy_dir/01-RESEARCH.md"
  expect_case legacy-phase-level 0 "artifact_valid=true"

  write_doc "$legacy_dir/01-01-RESEARCH.md" research_lines
  write_doc "$legacy_dir/01-02-RESEARCH.md" research_lines
  validate research "$legacy_dir/01-01-RESEARCH.md"
  expect_case legacy-stale 1 "legacy artifact is stale; expected canonical path $legacy_dir/01-02-RESEARCH.md"

  write_doc "$legacy_dir/notes/01-RESEARCH.md" research_lines
  validate research "$legacy_dir/notes/01-RESEARCH.md"
  expect_case legacy-nested 1 "legacy phase-root artifacts must be direct children of the active phase directory"

  write_doc "$legacy_dir/RESEARCH.md" research_lines
  validate research "$legacy_dir/RESEARCH.md"
  expect_case legacy-bad-name 1 "artifact path must match the expected legacy RESEARCH filename shape"

  write_doc "$(phase_dir no-state)/01-RESEARCH.md" research_lines
  validate research "$(phase_dir no-state)/01-RESEARCH.md"
  expect_case legacy-without-state 1 "legacy phase-root artifacts require layout=legacy"

  write_doc "$TEST_ROOT/loose/R01-RESEARCH.md" research_lines
  validate research "$TEST_ROOT/loose/R01-RESEARCH.md"
  expect_case outside-phases 1 "artifact path must point at an active .lbwc-planning/phases/ artifact"

  validate notes "$round_dir/R01-RESEARCH.md"
  expect_case unknown-type 1 "Usage: validate-uat-remediation-artifact.sh"

  validate research ""
  expect_case missing-path 1 "Usage: validate-uat-remediation-artifact.sh"

  assert_no_case_failures
}

@test "validate-uat-remediation-artifact checks UAT, QA and legacy plan artifacts" {
  local uat_dir qa_dir legacy_dir
  uat_dir="$(phase_dir uat)/remediation/uat/round-02"
  DOC_ROUND=02 write_doc "$uat_dir/R02-PLAN.md" plan_lines '^known_issue'
  validate plan "$uat_dir/R02-PLAN.md"
  expect_case uat-plan-without-qa-metadata 0 "artifact_valid=true"

  DOC_ROUND=2 write_doc "$uat_dir/R02-PLAN.md" plan_lines '^type:'
  validate plan "$uat_dir/R02-PLAN.md"
  expect_case missing-type 1 "plan artifact type must be remediation"

  qa_dir="$(phase_dir qa)/remediation/qa/round-01"
  write_doc "$qa_dir/R01-PLAN.md" plan_lines
  validate plan "$qa_dir/R01-PLAN.md"
  expect_case qa-plan 0 "artifact_valid=true"

  write_doc "$qa_dir/R01-PLAN.md" plan_lines '^fail_classifications:'
  validate plan "$qa_dir/R01-PLAN.md"
  expect_case missing-classifications 1 "plan artifact missing fail_classifications metadata"

  write_doc "$qa_dir/R01-PLAN.md" plan_lines '^known_issues_input:'
  validate plan "$qa_dir/R01-PLAN.md"
  expect_case qa-missing-input 1 "plan artifact missing known_issues_input metadata"

  write_doc "$qa_dir/R01-PLAN.md" plan_lines '^known_issue_resolutions:'
  validate plan "$qa_dir/R01-PLAN.md"
  expect_case qa-missing-resolutions 1 "plan artifact missing known_issue_resolutions metadata"

  write_doc "$qa_dir/R01-PLAN.md" plan_lines '^<tasks>'
  validate plan "$qa_dir/R01-PLAN.md"
  expect_case missing-tasks 1 "plan artifact missing tasks block"

  write_doc "$qa_dir/R01-PLAN.md" plan_lines '^<verification>'
  validate plan "$qa_dir/R01-PLAN.md"
  expect_case missing-verification 1 "plan artifact missing verification block"

  write_doc "$qa_dir/R02-PLAN.md" plan_lines
  validate plan "$qa_dir/R02-PLAN.md"
  expect_case qa-round-mismatch 1 "QA remediation plan round token must match round directory"

  write_doc "$(phase_dir qa)/remediation/qa/R01-PLAN.md" plan_lines
  validate plan "$(phase_dir qa)/remediation/qa/R01-PLAN.md"
  expect_case qa-outside-round 1 "artifact path must match the expected QA remediation plan filename shape"

  legacy_dir=$(phase_dir legacy)
  write_state "$legacy_dir/remediation/uat/.uat-remediation-stage" stage=plan round=01 layout=legacy
  write_doc "$legacy_dir/01-03-PLAN.md" plan_lines
  validate plan "$legacy_dir/01-03-PLAN.md"
  expect_case legacy-plan 0 "artifact_valid=true"

  write_doc "$legacy_dir/remediation/uat/round-01/R01-PLAN.md" plan_lines
  validate plan "$legacy_dir/01-03-PLAN.md"
  expect_case legacy-round-dir-plan-wins 1 "expected canonical path $legacy_dir/remediation/uat/round-01/R01-PLAN.md"

  assert_no_case_failures
}

@test "validate-uat-remediation-artifact requires a finished round-dir summary with task and known-issue metadata" {
  local round_dir
  round_dir="$(phase_dir sum)/remediation/uat/round-01"
  write_doc "$round_dir/R01-SUMMARY.md" summary_lines
  validate summary "$round_dir/R01-SUMMARY.md"
  expect_case valid 0 "artifact_valid=true"

  write_doc "$round_dir/R01-SUMMARY.md" summary_lines '^type:'
  validate summary "$round_dir/R01-SUMMARY.md"
  expect_case missing-type 1 "summary artifact type must be remediation"

  write_doc "$round_dir/R01-SUMMARY.md" summary_lines '^status:'
  validate summary "$round_dir/R01-SUMMARY.md"
  expect_case unfinished 1 "summary artifact status must be complete, partial, or failed"

  write_doc "$round_dir/R01-SUMMARY.md" summary_lines '^tasks_completed:'
  validate summary "$round_dir/R01-SUMMARY.md"
  expect_case missing-completed 1 "summary artifact missing tasks_completed metadata"

  write_doc "$round_dir/R01-SUMMARY.md" summary_lines '^tasks_total:'
  validate summary "$round_dir/R01-SUMMARY.md"
  expect_case missing-total 1 "summary artifact missing tasks_total metadata"

  write_doc "$round_dir/R01-SUMMARY.md" summary_lines '^known_issue_outcomes:'
  validate summary "$round_dir/R01-SUMMARY.md"
  expect_case missing-outcomes 1 "summary artifact missing known_issue_outcomes metadata"

  write_doc "$(phase_dir sum)/01-01-SUMMARY.md" summary_lines
  validate summary "$(phase_dir sum)/01-01-SUMMARY.md"
  expect_case phase-root 1 "summary artifacts must use the round-dir layout"

  assert_no_case_failures
}
