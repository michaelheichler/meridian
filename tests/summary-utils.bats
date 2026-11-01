#!/usr/bin/env bats

load test_helper
load gate_case_helper

setup() {
  setup_temp_dir
  reset_case_failures
  DOCS="$TEST_TEMP_DIR/phase"
  mkdir -p "$DOCS"
  cd "$TEST_TEMP_DIR" || return 1
}

teardown() {
  cd "$BATS_TEST_DIRNAME" || true
  teardown_temp_dir
}

summary_utils() {
  run bash -c '. "$1"; shift; "$@"' _ "$SCRIPTS_DIR/summary-utils.sh" "$@"
}

doc() {
  local file="$DOCS/$1"
  shift
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$@" > "$file"
}

expect_exact() {
  [ "$status" -eq "$2" ] && [ "$output" = "$3" ] \
    || record_case_failure "$1" "status=$status want=$2 output=[$output] want=[$3]"
}

@test "summary-utils reads the frontmatter status and counts complete, done and terminal summaries" {
  printf '\357\273\277---\r\nstatus: "complete"\r\n---\r\n' > "$DOCS/bom.md"
  summary_utils extract_summary_status "$DOCS/bom.md"
  expect_exact bom-crlf-quoted 0 complete

  doc single.md '' '  ' '---' "status: 'partial' " '---'
  summary_utils extract_summary_status "$DOCS/single.md"
  expect_exact leading-blank-single-quoted 0 partial

  doc body-first.md '# Summary' '---' 'status: complete' '---'
  summary_utils extract_summary_status "$DOCS/body-first.md"
  expect_exact body-before-frontmatter 0 ""

  doc after-fence.md '---' 'plan: 01' '---' 'status: complete'
  summary_utils extract_summary_status "$DOCS/after-fence.md"
  expect_exact status-after-fence 0 ""

  doc unclosed.md '---' 'plan: 01'
  summary_utils extract_summary_status "$DOCS/unclosed.md"
  expect_exact unclosed-without-status 0 ""

  summary_utils extract_summary_status "$DOCS/absent.md"
  expect_exact missing-file 0 ""

  doc counts/01-01-SUMMARY.md '---' 'status: complete' '---'
  doc counts/01-02-SUMMARY.md '---' 'status: completed' '---'
  doc counts/01-03-SUMMARY.md '---' 'status: partial' '---'
  doc counts/01-04-SUMMARY.md '---' 'status: failed' '---'
  doc counts/01-05-SUMMARY.md '---' 'status: in_progress' '---'
  doc counts/SUMMARY.md '---' 'status: complete' '---'
  summary_utils count_complete_summaries "$DOCS/counts"
  expect_exact count-complete 0 3
  summary_utils count_done_summaries "$DOCS/counts"
  expect_exact count-done 0 4
  summary_utils count_terminal_summaries "$DOCS/counts"
  expect_exact count-terminal 0 5

  summary_utils is_valid_summary_status ' failed '
  expect_exact valid-failed 0 ""
  summary_utils is_valid_summary_status completed
  expect_exact valid-rejects-completed 1 ""
  summary_utils is_execution_progress_status partial
  expect_exact progress-partial 0 ""
  summary_utils is_execution_progress_status failed
  expect_exact progress-rejects-failed 1 ""

  assert_no_case_failures
}

@test "summary-utils lists frontmatter and body deviations once and drops placeholders and comments" {
  doc mixed.md '---' 'status: complete' 'deviations:' '  - "**Rule 1**: renamed the config"' '  - "None"' '  - renamed the config' '---' \
    '# Summary' '## Deviations' '<!-- template note' 'spanning lines -->' '- **Auto-fixed**: Added retry wrapper' '- N/A' \
    '- **None**' '- None. Nothing else changed' '- No deviations: all good' '- Added retry wrapper' '' '## Next' '- not a deviation'
  summary_utils extract_summary_deviations "$DOCS/mixed.md"
  expect_exact mixed 0 $'renamed the config\nAdded retry wrapper'

  doc subsection.md '# Summary' '### Deviations' '<!-- one line -->' '- Kept the old API' '### Other' '- unrelated'
  summary_utils extract_summary_deviations "$DOCS/subsection.md"
  expect_exact subsection 0 "Kept the old API"

  summary_utils extract_summary_deviations "$DOCS/absent.md"
  expect_exact missing-file 0 ""

  assert_no_case_failures
}

@test "summary-utils resolves the source plan behind a summary and lists every candidate plan id" {
  doc bare/SUMMARY.md '---' 'status: complete' '---'
  doc bare/PLAN.md '---' "plan: '03-02'" '---'
  summary_utils summary_deviation_canonical_source_plan "$DOCS/bare/SUMMARY.md"
  expect_exact bare-with-plan 0 03-02
  summary_utils summary_deviation_source_plan_candidates "$DOCS/bare/SUMMARY.md"
  expect_exact bare-candidates 0 03-02

  doc orphan/SUMMARY.md '---' 'status: complete' '---'
  summary_utils summary_deviation_canonical_source_plan "$DOCS/orphan/SUMMARY.md"
  expect_exact bare-without-plan 0 unknown

  doc round/R02-SUMMARY.md '---' 'status: complete' '---'
  doc round/R02-PLAN.md '---' 'title: Fix' '---'
  doc round/R02-01-PLAN.md '---' 'plan: "R02-01"' '---'
  summary_utils summary_deviation_canonical_source_plan "$DOCS/round/R02-SUMMARY.md"
  expect_exact round-canonical 0 R02
  summary_utils summary_deviation_source_plan_candidates "$DOCS/round/R02-SUMMARY.md"
  expect_exact round-candidates 0 $'R02\nR02-01'

  doc numbered/01-02-SUMMARY.md '---' 'status: complete' '---'
  doc numbered/01-02-PLAN.md '---' 'round: 3' '---'
  summary_utils summary_deviation_canonical_source_plan "$DOCS/numbered/01-02-SUMMARY.md"
  expect_exact plan-round-key 0 R3

  doc numbered/01-03-SUMMARY.md '---' 'status: complete' '---'
  doc numbered/01-03-PLAN.md '---' 'title: no ids' '---'
  summary_utils summary_deviation_source_plan_candidates "$DOCS/numbered/01-03-SUMMARY.md"
  expect_exact plan-without-ids 0 unknown

  doc numbered/01-04-SUMMARY.md '---' 'status: complete' '---'
  summary_utils summary_deviation_source_plan_candidates "$DOCS/numbered/01-04-SUMMARY.md"
  expect_exact summary-without-plan 0 01-04

  doc numbered/notes.md '# notes'
  summary_utils summary_deviation_source_plan_candidates "$DOCS/numbered/notes.md"
  expect_exact not-a-summary 0 unknown

  summary_utils summary_deviation_source_plan_candidates "$DOCS/absent.md"
  expect_exact missing-file 0 ""

  assert_no_case_failures
}
