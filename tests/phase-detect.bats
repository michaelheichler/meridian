#!/usr/bin/env bats

load phase-detect-helpers

setup() { pd_setup; }
teardown() { pd_teardown; }

sc_no_planning() { rm -rf "$PD_PLAN_DIR"; }

sc_project_no_phases() {
  pd_project
  mkdir -p "$PD_PHASES"
}

sc_golden() {
  bash "$PD_FIXTURE_BUILDER" "$1"
}

sc_noncanonical_plan() {
  pd_plan 01-test 1
  touch "$PD_PHASES/01-test/not-a-PLAN.md"
}

sc_dotfile_plan() {
  pd_done 01-test
  touch "$PD_PHASES/01-test/.01-02-PLAN.md"
}

sc_noncanonical_dir() {
  mkdir -p "$PD_PHASES/misc-notes" "$PD_PHASES/01-real"
}

sc_numeric_sort() {
  local slug
  for slug in 11-eleven 100-hundred; do
    pd_done "$slug"
    pd_uat "$PD_PHASES/$slug/$(pd_phase_number "$slug")-UAT.md" issues_found major "$(pd_phase_number "$slug")"
  done
}

sc_active_file_ignored() {
  mkdir -p "$PD_PHASES/01-root-phase" "$PD_MILESTONES/old/phases/01-milestone-phase"
  echo "old" > "$PD_PLAN_DIR/ACTIVE"
}

sc_orphan_uat() {
  mkdir -p "$PD_PHASES/01-test"
  pd_uat "$PD_PHASES/01-test/01-UAT.md" issues_found major 01
}

sc_mid_execution_uat() {
  pd_plan 01-partial 1
  pd_plan 01-partial 2
  pd_summary "$PD_PHASES/01-partial/01-01-SUMMARY.md"
  pd_uat "$PD_PHASES/01-partial/01-UAT.md" issues_found major 01
}

sc_legacy_plan_files() {
  mkdir -p "$PD_PHASES/01-legacy"
  touch "$PD_PHASES/01-legacy/PLAN.md"
  pd_summary "$PD_PHASES/01-legacy/SUMMARY.md"
  printf '%s\n' 'phase: 01' 'status: issues_found' > "$PD_PHASES/01-legacy/01-UAT.md"
}

sc_later_phase_uat() {
  local slug="$1" severity="$2"
  pd_done "$slug"
  pd_uat "$PD_PHASES/$slug/$(pd_phase_number "$slug")-UAT.md" issues_found "$severity" "$(pd_phase_number "$slug")"
}

sc_priority() {
  case "$1" in
    mid_remediation)
      pd_plan 02-feature 1
      pd_summary "$PD_PHASES/02-feature/02-01-SUMMARY.md"
      pd_plan 02-feature 2
      echo "execute" > "$PD_PHASES/02-feature/.uat-remediation-stage"
      pd_uat "$PD_PHASES/02-feature/02-UAT.md" issues_found major 02
      sc_later_phase_uat 03-polish major
      ;;
    mid_execution)
      pd_plan 02-feature 1
      pd_summary "$PD_PHASES/02-feature/02-01-SUMMARY.md"
      pd_plan 02-feature 2
      sc_later_phase_uat 03-polish major
      ;;
    unplanned)
      mkdir -p "$PD_PHASES/01-setup"
      sc_later_phase_uat 02-feature critical
      ;;
    undiscussed)
      pd_config .require_phase_discussion=true
      mkdir -p "$PD_PHASES/01-setup"
      sc_later_phase_uat 02-feature major
      ;;
    discussed)
      pd_config .require_phase_discussion=true
      mkdir -p "$PD_PHASES/01-setup"
      touch "$PD_PHASES/01-setup/01-CONTEXT.md"
      sc_later_phase_uat 02-feature major
      ;;
  esac
}

sc_discuss() {
  pd_config .require_phase_discussion=true
  case "$1" in
    undiscussed) mkdir -p "$PD_PHASES/01-test" ;;
    discussed)
      mkdir -p "$PD_PHASES/01-test"
      touch "$PD_PHASES/01-test/01-CONTEXT.md"
      ;;
    planned) pd_plan 01-test 1 ;;
    foreign_context)
      mkdir -p "$PD_PHASES/01-test"
      touch "$PD_PHASES/01-test/NOTES-CONTEXT.md"
      ;;
    multi_phase)
      pd_done 01-first
      touch "$PD_PHASES/01-first/01-CONTEXT.md"
      mkdir -p "$PD_PHASES/02-second"
      ;;
  esac
}

sc_flat_uat() {
  pd_done 01-test
  case "$1" in
    major) pd_uat_issue "$PD_PHASES/01-test/01-UAT.md" 01 issues_found "something is broken" major ;;
    minor) pd_uat_issue "$PD_PHASES/01-test/01-UAT.md" 01 issues_found "cosmetic" minor ;;
    bold)
      pd_md "$PD_PHASES/01-test/01-UAT.md" '---' 'phase: 01' 'status: issues_found' '---' '' '## Tests' '' \
        '### P01-T1: sample' '' '- **Result:** issue' '- **Issue:** sample' '  - **Severity:** major'
      ;;
    unparseable)
      pd_md "$PD_PHASES/01-test/01-UAT.md" '---' 'phase: 01' 'status: issues_found' 'issues: 1' '---' '' \
        '## Tests' '' 'Some text without parseable test headers.'
      ;;
    resolved_with_round)
      pd_uat "$PD_PHASES/01-test/01-UAT.md" complete - 01
      echo "round 1" > "$PD_PHASES/01-test/01-UAT-round-01.md"
      ;;
    terminal_missing_qa) pd_uat "$PD_PHASES/01-test/01-UAT.md" complete - 01 ;;
  esac
}

sc_unplanned_uat_free() {
  pd_plan 01-test 1
}

sc_round_dir_uat() {
  pd_done 01-test
  pd_md "$PD_PHASES/01-test/remediation/uat/.uat-remediation-stage" 'round=01' 'layout=round-dir'
  pd_uat_issue "$PD_PHASES/01-test/remediation/uat/round-01/R01-UAT.md" 01 issues_found "round-dir broken" critical
}

pd_recurring_uat() {
  local file="$1" issues_line="$2" description="$3"
  pd_md "$file" '---' 'phase: 03' 'status: issues_found' $issues_line '---' '' '## Tests' '' \
    '### P03-T2: recurring issue' '' '- **Result:** issue' '- **Issue:**' "  - Description: $description" '  - Severity: major'
}

sc_recurring_rounds() {
  local dir="$1" description="$2"
  pd_recurring_uat "$dir/03-UAT-round-01.md" "" "$description"
  pd_recurring_uat "$dir/03-UAT-round-02.md" "" "$description"
  pd_recurring_uat "$dir/03-UAT.md" "issues: 1" "$description"
}

sc_inline_recurrence() {
  pd_done 03-feature
  sc_recurring_rounds "$PD_PHASES/03-feature" "still broken"
}

sc_five_rounds() {
  local round
  pd_done 03-feature
  for round in 01 02 03 04 05; do
    printf 'round %s\n' "$round" > "$PD_PHASES/03-feature/03-UAT-round-${round}.md"
  done
  pd_uat "$PD_PHASES/03-feature/03-UAT.md" issues_found major 03
}

sc_uat_phase_list() {
  case "$1" in
    multiple)
      pd_done 01-first
      pd_uat "$PD_PHASES/01-first/01-UAT.md" complete -
      pd_done 02-second
      pd_uat "$PD_PHASES/02-second/02-UAT.md" issues_found major
      pd_done 03-third
      pd_uat "$PD_PHASES/03-third/03-UAT.md" issues_found major
      ;;
    single)
      pd_done 01-only
      pd_uat "$PD_PHASES/01-only/01-UAT.md" issues_found minor
      ;;
    none)
      pd_done 01-clean
      pd_uat "$PD_PHASES/01-clean/01-UAT.md" complete -
      ;;
  esac
}

sc_source_uat() {
  case "$1" in
    active_scan)
      pd_done 01-remediate-test
      touch "$PD_PHASES/01-remediate-test/01-CONTEXT.md"
      pd_uat "$PD_PHASES/01-remediate-test/01-SOURCE-UAT.md" issues_found major 01
      ;;
    later_real_uat)
      pd_done 01-remediate-first
      pd_uat "$PD_PHASES/01-remediate-first/01-SOURCE-UAT.md" issues_found major 01
      pd_done 02-executed
      pd_uat "$PD_PHASES/02-executed/02-UAT.md" issues_found critical 02
      ;;
    higher_numbered_beside_real)
      pd_done 01-remediate-test
      pd_uat "$PD_PHASES/01-remediate-test/01-UAT.md" passed - 01
      pd_uat "$PD_PHASES/01-remediate-test/02-SOURCE-UAT.md" issues_found major 01
      ;;
    unplanned_neighbour)
      mkdir -p "$PD_PHASES/01-remediate-unresolved"
      touch "$PD_PHASES/01-remediate-unresolved/01-CONTEXT.md"
      pd_uat "$PD_PHASES/01-remediate-unresolved/01-SOURCE-UAT.md" issues_found critical 01
      pd_done 02-remediate-done
      pd_uat "$PD_PHASES/02-remediate-done/02-SOURCE-UAT.md" issues_found major 02
      ;;
  esac
}

sc_auto_uat() {
  pd_config '. + {effort:"balanced",auto_uat:true,auto_commit:true,planning_tracking:"manual",auto_push:"never"}'
  pd_project
  case "$1" in
    all_pass)
      pd_done_flat 01-feature
      pd_md "$PD_PHASES/01-feature/01-UAT.md" '---' 'phase: 01' 'status: all_pass' 'total_tests: 3' 'passed: 3' 'issues: 0' '---' \
        'All tests passed.'
      ;;
    passed)
      pd_done_flat 01-feature
      pd_uat "$PD_PHASES/01-feature/01-UAT.md" passed - 01
      ;;
    skip_verified)
      pd_done_flat 01-setup
      pd_uat "$PD_PHASES/01-setup/01-UAT.md" passed - 01
      pd_done_flat 02-polish
      ;;
  esac
}

sc_active_round_uat() {
  local slug="$1" kind="$2" later="${3:-}" dir
  dir="$PD_PHASES/$slug/remediation/uat"
  pd_done "$slug"
  pd_md "$dir/.uat-remediation-stage" 'stage=verify' 'round=06' 'layout=round-dir'
  case "$kind" in
    progress)
      pd_md "$dir/round-06/R06-UAT.md" '---' 'phase: 01' 'status: in_progress' '---' '## Tests' '' \
        '### PR06-T01: Completed checkpoint' '' '- **Result:** pass' '' '### PR06-T02: Next incomplete checkpoint' '' '- **Result:**'
      ;;
    nostatus)
      pd_md "$dir/round-06/R06-UAT.md" '---' 'phase: 01' '---' 'UAT exists but has no authoritative status yet.'
      ;;
    running)
      pd_md "$dir/round-06/R06-UAT.md" '---' "phase: $(pd_phase_number "$slug")" 'status: in_progress' '---' 'UAT is still running.'
      ;;
  esac
  [ -z "$later" ] || mkdir -p "$PD_PHASES/$later"
}

sc_active_round_over_issues() {
  local dir="$PD_PHASES/01-test/remediation"
  pd_done 01-test
  pd_uat_issue "$dir/round-02/R02-UAT.md" 01 issues_found "stale legacy round" major
  pd_md "$dir/.uat-remediation-stage" 'stage=verify' 'round=02'
  pd_md "$dir/uat/round-02/R02-UAT.md" '---' 'phase: 01' 'status: in_progress' '---' 'UAT is still running.'
}

sc_shipped_with_uat() {
  local slug="$1" severity="$2"
  pd_shipped v1
  pd_done "$slug" "$PD_MILESTONES/v1/phases"
  pd_uat "$PD_MILESTONES/v1/phases/$slug/$(pd_phase_number "$slug")-UAT.md" issues_found "$severity" "$(pd_phase_number "$slug")"
}

sc_milestone() {
  case "$1" in
    shipped_only)
      mkdir -p "$PD_PHASES"
      pd_shipped foundation
      ;;
    legacy_default) mkdir -p "$PD_MILESTONES/default/phases/01-legacy-phase" ;;
    source_uat_only)
      pd_done 01-done
      pd_shipped v1
      pd_done 01-shipped "$PD_MILESTONES/v1/phases"
      pd_uat "$PD_MILESTONES/v1/phases/01-shipped/01-SOURCE-UAT.md" issues_found major 01
      ;;
    referenced_by_remediation)
      pd_done 01-remediate-v1-setup
      pd_md "$PD_PHASES/01-remediate-v1-setup/01-CONTEXT.md" '---' 'phase: 01' 'source_milestone: v1' 'source_phase: 01-setup' \
        'pre_seeded: true' '---'
      sc_shipped_with_uat 01-setup major
      ;;
    unreferenced)
      pd_done 01-feature
      sc_shipped_with_uat 01-setup major
      ;;
    over_discussion)
      pd_config .require_phase_discussion=true
      pd_done 01-done
      touch "$PD_PHASES/01-done/01-CONTEXT.md"
      sc_shipped_with_uat 01-shipped major
      ;;
  esac
}

sc_milestone_extract() {
  local dir="$PD_MILESTONES/m01-test/phases"
  mkdir -p "$PD_PHASES"
  pd_shipped m01-test
  case "$1" in
    zero_issue)
      pd_done 01-alpha "$dir"
      pd_md "$dir/01-alpha/01-UAT.md" '---' 'phase: 01' 'status: issues_found' 'issues: 0' '---' '' '## Tests' '' \
        '### P01-T1: all good' '' '- **Result:** pass'
      ;;
    major_issue)
      pd_done 01-alpha "$dir"
      pd_uat_issue "$dir/01-alpha/01-UAT.md" 01 issues_found "milestone broken" major
      ;;
    recurrence)
      pd_done 03-feature "$dir"
      sc_recurring_rounds "$dir/03-feature" "milestone still broken"
      ;;
    noncanonical_dir)
      mkdir -p "$dir/setup-api"
      touch "$dir/setup-api/03-01-PLAN.md"
      pd_summary "$dir/setup-api/03-01-SUMMARY.md"
      pd_md "$dir/setup-api/03-UAT.md" '---' 'phase: 03' 'status: issues_found' 'issues: 1' '---' '' '## Tests' '' \
        '### P03-T1: recovered number' '' '- **Result:** issue' '- **Issue:**' \
        '  - Description: non-canonical dir still reports phase 03' '  - Severity: major'
      ;;
    source_uat_only_name)
      mkdir -p "$dir/setup-api"
      pd_md "$dir/setup-api/PLAN.md" '---' 'plan: legacy' 'title: Setup' '---'
      pd_summary "$dir/setup-api/SUMMARY.md"
      pd_md "$dir/setup-api/old-SOURCE-UAT.md" '---' 'phase: 03' 'status: issues_found' 'issues: 1' '---'
      pd_md "$dir/setup-api/remediation/uat/.uat-remediation-stage" stage=verify round=01 layout=round-dir
      pd_uat_issue "$dir/setup-api/remediation/uat/round-01/R01-UAT.md" "" issues_found "no phase header" major
      ;;
    noncanonical_rounds | noncanonical_round_one)
      mkdir -p "$dir/setup-api/remediation/uat/round-01"
      pd_md "$dir/setup-api/PLAN.md" '---' 'phase: 03' 'plan: legacy' 'title: Setup' '---'
      pd_summary "$dir/setup-api/SUMMARY.md"
      if [ "$1" = "noncanonical_rounds" ]; then
        pd_md "$dir/setup-api/remediation/uat/.uat-remediation-stage" stage=verify round=02 layout=round-dir
        pd_recurring_uat "$dir/setup-api/remediation/uat/round-01/R01-UAT.md" "" "broke before"
        pd_recurring_uat "$dir/setup-api/remediation/uat/round-02/R02-UAT.md" "issues: 1" "broke again"
      else
        pd_md "$dir/setup-api/remediation/uat/.uat-remediation-stage" stage=verify round=01 layout=round-dir
        pd_recurring_uat "$dir/setup-api/remediation/uat/round-01/R01-UAT.md" "issues: 1" "broke first time"
      fi
      ;;
  esac
}

@test "project tree reports its identity, defaults and next phase state" {
  pd_table <<'CASES'
no-planning-directory#sc_no_planning#planning_dir_exists=false~uat_round_count=0~qa_attention_reason=none~qa_reason=none
planning-without-phases-dir#:#planning_dir_exists=true~project_exists=false
bare-planning-defaults#mkdir -p .lbwc-planning/phases#planning_dir_exists=true~project_exists=false~phase_count=0~phases_dir=.lbwc-planning/phases~has_shipped_milestones=false~needs_milestone_rename=false~config_effort=balanced~config_autonomy=standard~config_require_phase_discussion=false~phase_detect_complete=true~!active_milestone=
project-without-phases#sc_project_no_phases#project_exists=true~qa_status=none~qa_reason=none~qa_attention_reason=none~qa_round=00
unplanned-phase#mkdir -p .lbwc-planning/phases/01-test#next_phase_state=needs_plan_and_execute
planned-phase#pd_plan 01-test 1#next_phase_state=needs_execute
finished-phase#pd_done 01-test#next_phase_state=all_done
CASES
}

@test "full output matches the golden file for each canonical project state" {
  local name
  while read -r name; do
    pd_reset
    sc_golden "$name"
    bash "$SCRIPTS_DIR/phase-detect.sh" > "$TEST_TEMP_DIR/actual-output.txt" < /dev/null
    pd_golden_matches "$name" || return 1
  done <<'CASES'
no-planning
unplanned
incomplete
all-done
uat-issues
qa-remediation
milestone-recovery
CASES
}

pd_golden_matches() {
  local expected="$BATS_TEST_DIRNAME/fixtures/phase-detect-output/$1.txt"
  grep -qx 'phase_detect_complete=true' "$TEST_TEMP_DIR/actual-output.txt" \
    || { printf 'golden=%s missing completion marker\n' "$1" >&2; return 1; }
  cmp -s "$expected" "$TEST_TEMP_DIR/actual-output.txt" \
    || { printf 'golden=%s differs\n' "$1" >&2; diff -u "$expected" "$TEST_TEMP_DIR/actual-output.txt" >&2; return 1; }
}

@test "phase directory scan counts only canonical artifacts and picks the first unfinished phase" {
  pd_table <<'CASES'
noncanonical-plan-file-ignored#sc_noncanonical_plan#next_phase_state=needs_execute~next_phase_plans=1
dotfile-plan-ignored#sc_dotfile_plan#next_phase_state=all_done
noncanonical-phase-dir-skipped#sc_noncanonical_dir#phase_count=1~next_phase=01~next_phase_slug=01-real~next_phase_state=needs_plan_and_execute
numeric-sort-not-lexicographic#sc_numeric_sort#uat_issues_phase=11~next_phase=11
active-file-ignored#sc_active_file_ignored#phase_count=1~phases_dir=.lbwc-planning/phases
mid-remediation-beats-later-uat#sc_priority mid_remediation#next_phase=02~next_phase_state=needs_execute~next_phase_plans=2~next_phase_summaries=1
mid-execution-beats-later-uat#sc_priority mid_execution#next_phase=02~next_phase_state=needs_execute~next_phase_plans=2~next_phase_summaries=1
unplanned-beats-later-uat#sc_priority unplanned#next_phase=01~next_phase_state=needs_plan_and_execute
undiscussed-beats-later-uat#sc_priority undiscussed#next_phase=01~next_phase_state=needs_discussion
discussed-beats-later-uat#sc_priority discussed#next_phase=01~next_phase_state=needs_plan_and_execute
CASES
}

@test "phase discussion requirement gates only unplanned phases" {
  pd_table <<'CASES'
flag-true-reported#pd_config .require_phase_discussion=true#config_require_phase_discussion=true
undiscussed-phase#sc_discuss undiscussed#next_phase_state=needs_discussion~next_phase=01
canonical-context-satisfies#sc_discuss discussed#next_phase_state=needs_plan_and_execute
planned-phase-skips-discussion#sc_discuss planned#next_phase_state=needs_execute
foreign-context-does-not-satisfy#sc_discuss foreign_context#next_phase_state=needs_discussion
first-undiscussed-phase-targeted#sc_discuss multi_phase#next_phase_state=needs_discussion~next_phase=02~next_phase_slug=02-second
CASES
}

@test "UAT reports route flat layouts and fill the routing fields" {
  pd_table <<'CASES'
major-issue-routes-remediation#sc_flat_uat major#next_phase_state=needs_uat_remediation~next_phase=01~next_phase_slug=01-test~uat_issues_phase=01~uat_issues_major_or_higher=true~uat_file=01-UAT.md~uat_issues_count=1~uat_round_count=0~!---UAT_EXTRACT_START---
minor-only-clears-major-flag#sc_flat_uat minor#next_phase_state=needs_uat_remediation~uat_issues_major_or_higher=false
bold-severity-counts-as-major#sc_flat_uat bold#next_phase_state=needs_uat_remediation~uat_issues_major_or_higher=true
unparseable-body-still-routes#sc_flat_uat unparseable#next_phase_state=needs_uat_remediation~uat_file=01-UAT.md~!---UAT_EXTRACT_START---
no-remediation-no-marker#sc_unplanned_uat_free#!---UAT_EXTRACT_START---~uat_file=none
round-dir-path-is-relative#sc_round_dir_uat#uat_file=remediation/uat/round-01/R01-UAT.md~uat_issues_count=1~!---UAT_EXTRACT_START---
recurrence-counts-archived-rounds#sc_inline_recurrence#next_phase_state=needs_uat_remediation~uat_issues_count=1~uat_file=03-UAT.md~uat_round_count=2~!---UAT_EXTRACT_START---
five-archived-rounds#sc_five_rounds#uat_round_count=5
resolved-uat-resets-round-count#sc_flat_uat resolved_with_round#uat_round_count=0
terminal-uat-without-qa-stays-done#sc_flat_uat terminal_missing_qa#uat_issues_phase=none~next_phase=none~next_phase_state=all_done~qa_status=none
orphan-uat-ignored#sc_orphan_uat#uat_issues_phase=none~next_phase_state=needs_plan_and_execute
mid-execution-uat-not-routed#sc_mid_execution_uat#uat_issues_phase=none~next_phase_state=needs_execute~next_phase_plans=2~next_phase_summaries=1
legacy-plan-files-route#sc_legacy_plan_files#next_phase_state=needs_uat_remediation~next_phase=01~uat_issues_phase=01
multiple-phases-listed#sc_uat_phase_list multiple#uat_issues_phase=02~next_phase=02~next_phase_state=needs_uat_remediation~uat_issues_phases=02,03~uat_issues_count=2
single-phase-listed#sc_uat_phase_list single#uat_issues_phase=01~uat_issues_phases=01~uat_issues_count=1
no-issues-listed-empty#sc_uat_phase_list none#uat_issues_phase=none~uat_issues_phases=~uat_issues_count=0
source-uat-not-a-report#sc_source_uat active_scan#uat_issues_phase=none~next_phase_state=all_done
source-uat-skipped-for-later-real-uat#sc_source_uat later_real_uat#uat_issues_phase=02~next_phase_state=needs_uat_remediation
higher-numbered-source-uat-does-not-replace-real-uat#sc_source_uat higher_numbered_beside_real#uat_issues_phase=none~next_phase_state=all_done
source-uat-does-not-block-unplanned#sc_source_uat unplanned_neighbour#uat_issues_phase=none~next_phase=01~next_phase_state=needs_plan_and_execute
all-pass-status-counts-as-verified#sc_auto_uat all_pass#has_unverified_phases=false~next_phase_state=all_done~qa_status=none
passed-status-counts-as-verified#sc_auto_uat passed#has_unverified_phases=false
verified-phase-skipped-for-unverified#sc_auto_uat skip_verified#has_unverified_phases=true~first_unverified_phase=02~first_unverified_slug=02-polish~next_phase=02~next_phase_state=needs_verification
CASES
}

@test "an in-progress round-dir UAT blocks archive routing and later phases" {
  pd_table <<'CASES'
progress-checkpoints#sc_active_round_uat 01-test progress#next_phase=01~next_phase_slug=01-test~next_phase_state=needs_verification~uat_blocking_phase=01~uat_blocking_status=active~uat_blocking_file=remediation/uat/round-06/R06-UAT.md~!next_phase_state=all_done
missing-status#sc_active_round_uat 01-test nostatus#next_phase=01~next_phase_slug=01-test~next_phase_state=needs_verification~uat_blocking_phase=01~uat_blocking_status=active~uat_blocking_file=remediation/uat/round-06/R06-UAT.md~!next_phase_state=all_done
boundary-phase-08#sc_active_round_uat 08-active-uat running 09-next#next_phase=08~next_phase_slug=08-active-uat~next_phase_state=needs_verification~uat_blocking_phase=08~uat_blocking_status=active~uat_blocking_file=remediation/uat/round-06/R06-UAT.md~!next_phase=09
boundary-phase-09#sc_active_round_uat 09-active-uat running 10-next#next_phase=09~next_phase_slug=09-active-uat~next_phase_state=needs_verification~uat_blocking_phase=09~uat_blocking_status=active~uat_blocking_file=remediation/uat/round-06/R06-UAT.md~!next_phase=10
active-round-over-issues-found-uat#sc_active_round_over_issues#next_phase=01~next_phase_state=needs_verification~!next_phase_state=needs_reverification~!next_phase_state=needs_uat_remediation
CASES
}

@test "shipped milestones report rename and UAT recovery state" {
  pd_table <<'CASES'
shipped-milestone-detected#sc_milestone shipped_only#has_shipped_milestones=true
legacy-default-reported-not-renamed#sc_milestone legacy_default#phase_detect_complete=true~needs_milestone_rename=true~+.lbwc-planning/milestones/default~+.lbwc-planning/milestones/default/phases/01-legacy-phase
source-uat-excluded-from-milestone-scan#sc_milestone source_uat_only#milestone_uat_issues=false
remediation-reference-suppresses-recovery#sc_milestone referenced_by_remediation#next_phase_state=all_done~milestone_uat_issues=false
unreferenced-issues-trigger-recovery#sc_milestone unreferenced#milestone_uat_issues=true~milestone_uat_slug=v1
recovery-outranks-discussion#sc_milestone over_discussion#next_phase_state=all_done~milestone_uat_issues=true~milestone_uat_slug=v1
CASES
}

@test "milestone recovery emits the extractor block for the shipped phase" {
  pd_table <<'CASES'
issue-block-emitted#sc_milestone_extract major_issue#---MILESTONE_UAT_EXTRACT_START---~---MILESTONE_UAT_EXTRACT_END---~P01-T1|major|milestone broken
zero-issue-matches-standalone-extractor#sc_milestone_extract zero_issue#%.lbwc-planning/milestones/m01-test/phases/01-alpha~uat_phase=01 uat_issues_total=0~!uat_extract_error=true
recurrence-matches-standalone-extractor#sc_milestone_extract recurrence#%.lbwc-planning/milestones/m01-test/phases/03-feature
noncanonical-dir-uses-resolved-number#sc_milestone_extract noncanonical_dir#milestone_uat_issues=true~milestone_phase_dir=.lbwc-planning/milestones/m01-test/phases/setup-api~uat_phase=03 uat_issues_total=1 uat_round=1 uat_file=03-UAT.md
noncanonical-round-dir-resolves-latest-round#sc_milestone_extract noncanonical_rounds#milestone_uat_issues=true~milestone_phase_dir=.lbwc-planning/milestones/m01-test/phases/setup-api~uat_phase=03 uat_issues_total=1 uat_round=2 uat_file=R02-UAT.md~P03-T2|major|broke again|1,2
source-uat-name-cannot-supply-phase-number#sc_milestone_extract source_uat_only_name#milestone_uat_issues=false
noncanonical-round-one-parity#sc_milestone_extract noncanonical_round_one#milestone_uat_issues=true~uat_phase=03 uat_issues_total=1 uat_round=1 uat_file=R01-UAT.md~P03-T2|major|broke first time|1
CASES
}

sc_late_failure() {
  mkdir -p "$PD_PHASES"
  printf '%s\n' '# Fixture Project' > "$PD_PLAN_DIR/PROJECT.md"
  export PD_SCRIPTS_DIR="$TEST_TEMP_DIR/scripts-late-failure"
  cp -R "$SCRIPTS_DIR" "$PD_SCRIPTS_DIR"
  awk '/echo "milestone_uat_issues=\$MILESTONE_UAT_ISSUES"/ && !injected { print "exit 23"; injected=1 } { print }' \
    "$SCRIPTS_DIR/lib/phase-detect-milestone-recovery.sh" > "$PD_SCRIPTS_DIR/lib/phase-detect-milestone-recovery.sh"
  chmod +x "$PD_SCRIPTS_DIR/lib/phase-detect-milestone-recovery.sh"
  export PD_RAW=1
}

sc_source_failure() {
  pd_shim source-failure lib/phase-detect-support.sh 'return 23'
  export PD_RAW=1
}

@test "an internal failure emits only the stable error marker" {
  pd_table <<'CASES'
late-failure-after-partial-output#sc_late_failure#=phase_detect_error=true
library-fails-to-source#sc_source_failure#=phase_detect_error=true
CASES
}

@test "phase-detect reports a stable setup error when its output file cannot be created" {
  pd_reset
  export PD_SCRIPTS_DIR="$TEST_TEMP_DIR/scripts-setup-failure"
  cp -R "$SCRIPTS_DIR" "$PD_SCRIPTS_DIR"
  pd_fake_bin mktemp 'exit 1'

  run env PATH="$PD_PATH_PREFIX:$PATH" bash "$PD_SCRIPTS_DIR/phase-detect.sh"

  [ "$status" -ne 0 ]
  [ "$output" = $'phase_detect_error=true\nphase_detect_reason=setup_failed' ]
}
