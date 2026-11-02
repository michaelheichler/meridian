#!/usr/bin/env bats

load test_helper
load gate_case_helper
load gate_case_files
load isolated_case_helper

setup() {
  setup_temp_dir
  cd "$TEST_TEMP_DIR" || return 1
  git init -q
  reset_case_failures
  PLANNING_DIR="$TEST_TEMP_DIR/dir with space/.lbwc-planning"
  mkdir -p "$PLANNING_DIR/debugging/active"
  SN_SCRIPTS="$BATS_TEST_TMPDIR/scripts"
  cp -R "$SCRIPTS_DIR" "$SN_SCRIPTS"
  printf '#!/bin/bash\ncat "${SN_PD_FIXTURE:-/dev/null}" 2>/dev/null\n' > "$SN_SCRIPTS/phase-detect.sh"
}

teardown() {
  cd "$BATS_TEST_DIRNAME" || true
  teardown_temp_dir
}

write_debug_session() {
  local session_status="$1" session_name="20260101-000000-bug.md"
  printf -- '---\nstatus: %s\n---\n' "$session_status" > "$PLANNING_DIR/debugging/active/$session_name"
  printf '%s\n' "$session_name" > "$PLANNING_DIR/debugging/.active-session"
}

project() {
  ROOT="$BATS_TEST_TMPDIR/rows/$1"
  PLANNING_DIR="$ROOT/.lbwc-planning"
  PHASES="$PLANNING_DIR/phases"
  mkdir -p "$PHASES"
  printf '# Shop\n' > "$PLANNING_DIR/PROJECT.md"
  : > "$ROOT/pd.out"
}

bare_project() {
  project "$1"
  rm -f "$PLANNING_DIR/PROJECT.md"
}

debug_project() {
  project "$1"
  mkdir -p "$PLANNING_DIR/debugging/active"
  write_debug_session "$2"
}

phase_detect_says() {
  printf '%s\n' phase_detect_complete=true "$@" > "$ROOT/pd.out"
}

configure() {
  printf '%s\n' "$1" > "$PLANNING_DIR/config.json"
}

add_plan() {
  local dir="$PHASES/$1"
  mkdir -p "$dir"
  printf -- '---\nplan: %s\n---\n' "$2" > "$dir/$2-PLAN.md"
  [ "$3" = none ] && return 0
  printf -- '---\nstatus: %s\ndeviations: %s\n---\n' "$3" "${4:-0}" > "$dir/$2-SUMMARY.md"
}

add_doc() {
  mkdir -p "$(dirname "$PHASES/$1/$2")"
  printf -- '---\n%s\n---\n%s\n' "$3" "${4:-}" > "$PHASES/$1/$2"
}

shipped_phase() {
  add_plan "$1" "$2" complete "${3:-0}"
  add_doc "$1" "${2%%-*}-UAT.md" 'status: complete'
}

next_up() {
  cd "$ROOT" || return 1
  run env SN_PD_FIXTURE="$ROOT/pd.out" LBWC_PLANNING_DIR="$PLANNING_DIR" /bin/bash "$SN_SCRIPTS/suggest-next.sh" "$@"
}

suggest_debug_without_phases() {
  [ -x "$SCRIPTS_DIR/debug-session-state.sh" ]

  write_debug_session qa_pending
  run env LBWC_PLANNING_DIR="$PLANNING_DIR" bash "$SCRIPTS_DIR/suggest-next.sh" fix
  [ "$status" -eq 0 ]
  [[ "$output" == *"/lbwc:debug --resume -- Address remaining issues"* ]]

  write_debug_session uat_failed
  run env LBWC_PLANNING_DIR="$PLANNING_DIR" bash "$SCRIPTS_DIR/suggest-next.sh" debug
  [ "$status" -eq 0 ]
  [[ "$output" == *"Address UAT issues"* ]]
}

suggest_after_vibe() {
  project fail-names-plan
  add_plan 01-setup 01-01 failed
  next_up vibe fail
  expect_case fail-names-plan 0 "/lbwc:fix -- Fix plan 01-01 (failed verification)"
  expect_output_has fail-names-plan "/lbwc:vibe -- Re-run verification"

  project partial-plan-named
  add_plan 01-setup 01-01 partial
  next_up vibe fail
  expect_case partial-plan-named 0 "/lbwc:fix -- Fix plan 01-01 (failed verification)"

  project partial-keeps-going
  add_plan 01-setup 01-01 none
  next_up vibe partial
  expect_case partial-keeps-going 0 "/lbwc:fix -- Address partial failures"
  expect_output_has partial-keeps-going "/lbwc:vibe -- Continue to next phase"

  project done-clean
  shipped_phase 01-setup 01-01
  next_up vibe
  expect_case done-clean 0 "/lbwc:vibe --archive -- All phases complete, zero deviations"
  expect_output_lacks done-clean "Verify"

  project done-with-deviations
  shipped_phase 01-setup 01-01 2
  add_plan 01-setup 01-02 complete '[renamed the config file]'
  next_up vibe
  expect_case done-with-deviations 0 "Archive completed work (3 deviation(s) logged)"
  expect_output_has done-with-deviations "/lbwc:vibe -- Review before archiving"

  project source-uat-is-not-verification
  add_plan 01-setup 01-01 complete
  add_doc 01-setup 01-SOURCE-UAT.md 'status: complete'
  next_up vibe
  expect_case source-uat-is-not-verification 0 "/lbwc:vibe -- Verify completed work before continuing"

  project round-uat-counts-as-verification
  add_plan 01-setup 01-01 complete
  add_doc 01-setup remediation/uat/round-01/R01-UAT.md 'status: passed'
  next_up vibe
  expect_case round-uat-counts-as-verification 0 "zero deviations"
  expect_output_lacks round-uat-counts-as-verification "Verify"

  project names-unverified-phase
  add_plan 01-setup 01-01 complete
  phase_detect_says first_unverified_phase=1 first_unverified_slug=01-cart-setup
  next_up vibe
  expect_case names-unverified-phase 0 "/lbwc:vibe -- Verify 1 (cart setup) before continuing"

  project reverify
  shipped_phase 01-setup 01-01
  phase_detect_says next_phase_state=needs_reverification next_phase=1
  next_up vibe
  expect_case reverify 0 "/lbwc:vibe -- Re-verify Phase 1 after remediation"

  project blocked-verify
  shipped_phase 01-setup 01-01
  phase_detect_says next_phase_state=needs_verification uat_blocking_phase=1 next_phase=1
  next_up vibe
  expect_case blocked-verify 0 "/lbwc:vibe -- Resume Verify for Phase 1"

  project milestone-recovery
  shipped_phase 01-setup 01-01 1
  phase_detect_says milestone_uat_issues=true milestone_uat_slug=m1 milestone_uat_count=2
  next_up vibe
  expect_case milestone-recovery 0 "Milestone UAT recovery pending (m1, 2 phase(s))"
  expect_output_has milestone-recovery "/lbwc:vibe -- Review remediation scope"

  project uat-issues-round
  shipped_phase 01-setup 01-01
  phase_detect_says uat_issues_phase=1 uat_issues_slug=setup uat_issues_major_or_higher=true uat_round_count=1
  next_up vibe
  expect_case uat-issues-round 0 "/lbwc:vibe -- Remediate UAT issues for Phase 1 (setup), Round 2"

  project discuss-first
  shipped_phase 01-setup 01-01
  mkdir -p "$PHASES/02-build"
  phase_detect_says config_require_phase_discussion=true
  next_up vibe
  expect_case discuss-first 0 "/lbwc:discuss 02 -- Discuss phase before planning"

  project preseeded
  shipped_phase 01-setup 01-01
  add_doc 02-build 02-CONTEXT.md 'pre_seeded: true'
  phase_detect_says config_require_phase_discussion=true
  next_up vibe
  expect_case preseeded 0 "/lbwc:vibe -- Plan Phase 02: build (discussion pre-seeded from UAT)"

  project unbuilt-before-unplanned
  shipped_phase 01-setup 01-01
  add_plan 02-build-cart 02-01 none
  add_doc 03-ship 03-CONTEXT.md 'owner: shop'
  phase_detect_says config_require_phase_discussion=true
  next_up vibe
  expect_case unbuilt-before-unplanned 0 "/lbwc:vibe -- Continue to Phase 02: build cart"

  project skipped-verify
  shipped_phase 01-setup 01-01
  add_plan 02-build 02-01 none
  next_up vibe skipped
  expect_case skipped-verify 0 "/lbwc:vibe -- Continue to next phase"
  expect_output_has skipped-verify "/lbwc:vibe -- Verify completed work"

  assert_no_case_failures
}

suggest_after_plan() {
  project counted
  add_plan 01-setup 01-01 none
  add_plan 01-setup 01-02 none
  configure '{"effort":"thorough"}'
  next_up plan
  expect_case counted 0 "/lbwc:vibe -- Execute 2 plans (thorough effort)"
  expect_jq counted "$PLANNING_DIR/config.json" '.model_profile == "quality" and .effort == "thorough"'

  project nothing-planned
  next_up plan
  expect_case nothing-planned 0 "/lbwc:vibe -- Execute the planned phase"

  assert_no_case_failures
}

suggest_after_qa() {
  debug_project debug-qa-failed-result qa_pending
  next_up qa fail
  expect_case debug-qa-failed-result 0 "/lbwc:debug --resume -- Address QA failures"

  debug_project debug-uat-pending uat_pending
  next_up qa
  expect_case debug-uat-pending 0 "/lbwc:debug --resume -- Continue to UAT verification"

  debug_project debug-fix-applied fix_applied
  next_up qa
  expect_case debug-fix-applied 0 "/lbwc:debug --resume -- Continue to QA verification"

  debug_project debug-qa-failed qa_failed
  next_up qa
  expect_case debug-qa-failed 0 "/lbwc:debug --resume -- Address QA failures"

  debug_project debug-investigating investigating
  next_up qa
  expect_case debug-investigating 0 "/lbwc:vibe -- Continue building"

  project pass-from-verification-file
  shipped_phase 01-setup 01-01
  add_doc 01-setup 01-VERIFICATION.md 'result: PASS'
  next_up qa
  expect_case pass-from-verification-file 0 "/lbwc:vibe --archive -- All phases complete, zero deviations"

  project pass-with-deviations
  shipped_phase 01-setup 01-01 4
  next_up qa pass
  expect_case pass-with-deviations 0 "Archive completed work (4 deviation(s) logged)"

  project pass-reverify
  shipped_phase 01-setup 01-01
  phase_detect_says next_phase_state=needs_reverification next_phase=1
  next_up qa pass
  expect_case pass-reverify 0 "Re-verify Phase 1"

  project pass-blocked
  shipped_phase 01-setup 01-01
  phase_detect_says next_phase_state=needs_verification uat_blocking_phase=1 next_phase=1
  next_up qa pass
  expect_case pass-blocked 0 "Resume Verify for Phase 1"

  project pass-milestone-phase
  shipped_phase 01-setup 01-01
  phase_detect_says milestone_uat_issues=true milestone_uat_slug=m1 milestone_uat_phase=3 milestone_uat_count=1
  next_up qa pass
  expect_case pass-milestone-phase 0 "Milestone UAT recovery pending (m1, Phase 3)"

  project pass-minor-uat
  shipped_phase 01-setup 01-01
  phase_detect_says uat_issues_phase=1
  next_up qa pass
  expect_case pass-minor-uat 0 "/lbwc:fix -- Fix minor UAT issues in Phase 1"

  project pass-discuss
  shipped_phase 01-setup 01-01
  mkdir -p "$PHASES/02-build"
  phase_detect_says config_require_phase_discussion=true
  next_up qa pass
  expect_case pass-discuss 0 "/lbwc:discuss 02"

  project pass-preseeded
  shipped_phase 01-setup 01-01
  add_doc 02-build 02-CONTEXT.md 'pre_seeded: "true"'
  phase_detect_says config_require_phase_discussion=true
  next_up qa pass
  expect_case pass-preseeded 0 "Plan Phase 02: build (discussion pre-seeded from UAT)"

  project pass-continue
  shipped_phase 01-setup 01-01
  add_plan 02-build 02-01 none
  next_up qa pass
  expect_case pass-continue 0 "/lbwc:vibe -- Continue to Phase 02: build"
  expect_output_has pass-continue "/lbwc:vibe -- Verify completed work"

  project fail
  add_plan 01-setup 01-01 none
  next_up qa fail
  expect_case fail 0 "/lbwc:fix -- Fix the failing checks"

  project partial
  add_plan 01-setup 01-01 partial
  next_up qa partial
  expect_case partial 0 "/lbwc:fix -- Fix plan 01-01 (partial failure)"
  expect_output_has partial "/lbwc:vibe -- Continue despite warnings"

  project no-result
  next_up qa
  expect_case no-result 0 "/lbwc:vibe -- Continue building"

  assert_no_case_failures
}

suggest_after_fix() {
  debug_project debug-qa-failed qa_failed
  next_up fix
  expect_case debug-qa-failed 0 "/lbwc:debug --resume -- Address QA failures"

  debug_project debug-uat-pending uat_pending
  next_up fix
  expect_case debug-uat-pending 0 "/lbwc:debug --resume -- Run UAT on the debug fix"

  debug_project debug-uat-failed uat_failed
  next_up fix
  expect_case debug-uat-failed 0 "/lbwc:debug --resume -- Address UAT issues"

  debug_project debug-investigating investigating
  next_up fix
  expect_case debug-investigating 0 "/lbwc:debug --resume -- Continue investigation"

  debug_project debug-unknown-status on_hold
  next_up fix
  expect_case debug-unknown-status 0 "/lbwc:vibe -- Verify the fix"

  project fresh-marker
  add_plan 01-setup 01-01 complete
  configure '{"auto_uat":true}'
  touch "$PLANNING_DIR/.last-fix-commit"
  next_up fix
  expect_case fresh-marker 0 "/lbwc:verify -- Run UAT on the fix"
  expect_output_has fresh-marker "/lbwc:vibe -- Continue building"

  project stale-marker
  add_plan 01-setup 01-01 complete
  configure '{"auto_uat":true}'
  touch -t 202001010000 "$PLANNING_DIR/.last-fix-commit"
  next_up fix
  expect_case stale-marker 0 "/lbwc:vibe -- Verify the fix"
  expect_output_lacks stale-marker "Run UAT on the fix"

  assert_no_case_failures
}

suggest_after_verify() {
  debug_project debug-uat-failed uat_failed
  next_up verify pass
  expect_case debug-uat-failed 0 "/lbwc:debug --resume -- Address UAT issues"

  debug_project debug-other-status qa_failed
  next_up verify pass
  expect_case debug-other-status 0 "/lbwc:vibe -- Continue to next phase"

  project pass-reverify
  shipped_phase 01-setup 01-01
  phase_detect_says next_phase_state=needs_reverification next_phase=1
  next_up verify pass
  expect_case pass-reverify 0 "Re-verify Phase 1"

  project pass-blocked
  shipped_phase 01-setup 01-01
  phase_detect_says next_phase_state=needs_verification uat_blocking_phase=1 next_phase=1
  next_up verify pass
  expect_case pass-blocked 0 "Resume Verify for Phase 1"

  project pass-ship
  shipped_phase 01-setup 01-01
  next_up verify pass
  expect_case pass-ship 0 "/lbwc:vibe --archive -- All verified, ready to ship"

  project pass-milestone
  shipped_phase 01-setup 01-01
  phase_detect_says milestone_uat_issues=true
  next_up verify pass
  expect_case pass-milestone 0 "/lbwc:vibe -- Milestone UAT recovery pending"
  expect_output_lacks pass-milestone "ready to ship"

  project named-critical-phase
  add_plan 01-setup 01-01 complete
  add_doc 01-setup 01-UAT.md 'status: issues_found' '- **Severity:** critical'
  next_up verify issues_found 01
  expect_case named-critical-phase 0 "/lbwc:vibe -- Remediate UAT issues for Phase 1"

  project found-minor-phase
  add_plan 01-setup 01-01 complete
  add_doc 01-setup 01-UAT.md 'status: issues_found' '- **Severity:** minor'
  add_plan 02-build 02-01 complete
  add_doc 02-build 02-UAT.md 'status: complete'
  next_up verify issues_found
  expect_case found-minor-phase 0 "/lbwc:fix -- Fix minor issues found during UAT"

  project untagged-issues
  add_plan 01-setup 01-01 complete
  add_doc 01-setup 01-UAT.md 'status: issues_found' '- **Result:** issue'
  next_up verify issues_found
  expect_case untagged-issues 0 "/lbwc:vibe -- Remediate UAT issues for Phase 1"

  project named-phase-without-uat
  add_plan 02-build 02-01 complete
  next_up verify issues_found 2
  expect_case named-phase-without-uat 0 "/lbwc:vibe -- Remediate UAT issues for Phase 2"

  project unknown-result
  next_up verify
  expect_case unknown-result 0 "/lbwc:vibe -- Continue building"

  assert_no_case_failures
}

suggest_after_debug() {
  debug_project qa-pending qa_pending
  next_up debug
  expect_case qa-pending 0 "/lbwc:debug --resume -- Continue to QA verification"

  debug_project qa-failed qa_failed
  next_up debug
  expect_case qa-failed 0 "/lbwc:debug --resume -- Address QA failures"

  debug_project uat-pending uat_pending
  next_up debug
  expect_case uat-pending 0 "/lbwc:debug --resume -- Continue to UAT verification"

  debug_project investigating investigating
  next_up debug
  expect_case investigating 0 "/lbwc:debug --resume -- Continue investigation"
  expect_output_has investigating "/lbwc:fix -- Apply the fix"

  project no-session
  next_up debug
  expect_case no-session 0 "/lbwc:fix -- Apply the fix"
  expect_output_has no-session "/lbwc:vibe -- Continue building"

  assert_no_case_failures
}

suggest_after_setup() {
  project init
  shipped_phase 01-setup 01-01
  printf '{"issues":[{"id":1}]}\n' > "$PHASES/01-setup/known-issues.json"
  next_up init
  expect_case init 0 "/lbwc:vibe -- Define your project and start building"
  expect_output_lacks init "known issue"
  expect_output_lacks init "/lbwc:map"

  project map
  add_plan 01-setup 01-01 none
  next_up map
  expect_case map 0 "/lbwc:status -- View project state"
  expect_output_lacks map "/lbwc:map -- Map your codebase"

  project archive
  next_up archive
  expect_case archive 0 "/lbwc:vibe -- Start new work"

  project discuss
  next_up discuss
  expect_case discuss 0 "/lbwc:vibe --plan -- Plan this phase"

  project assumptions
  next_up assumptions
  expect_case assumptions 0 "/lbwc:vibe -- Plan and execute in one flow"

  project config-with-project
  next_up config
  expect_case config-with-project 0 "/lbwc:status -- View project state"

  bare_project config-without-project
  next_up config
  expect_case config-without-project 0 "/lbwc:vibe -- Define your project and start building"

  project placeholder-project
  printf '# {project-name}\n' > "$PLANNING_DIR/PROJECT.md"
  next_up
  expect_case placeholder-project 0 "/lbwc:vibe -- Start a new project"

  project default-with-project
  next_up
  expect_case default-with-project 0 "/lbwc:vibe -- Continue building"
  expect_output_has default-with-project "/lbwc:status -- View project progress"

  assert_no_case_failures
}

suggest_after_status() {
  project reverify
  shipped_phase 01-setup 01-01
  phase_detect_says next_phase_state=needs_reverification next_phase=1
  next_up status
  expect_case reverify 0 "Re-verify Phase 1"

  project unverified-named
  shipped_phase 01-setup 01-01
  phase_detect_says next_phase_state=needs_verification first_unverified_phase=2 first_unverified_slug=02-build
  next_up status
  expect_case unverified-named 0 "/lbwc:vibe -- Verify 2 (build) before continuing"

  project done-clean
  shipped_phase 01-setup 01-01
  next_up status
  expect_case done-clean 0 "All phases complete, zero deviations"

  project done-deviations
  shipped_phase 01-setup 01-01 1
  next_up status
  expect_case done-deviations 0 "/lbwc:vibe --archive -- Archive completed work"

  project done-milestone
  shipped_phase 01-setup 01-01
  phase_detect_says milestone_uat_issues=true milestone_uat_slug=m2 milestone_uat_count=3
  next_up status
  expect_case done-milestone 0 "Milestone UAT recovery pending (m2, 3 phase(s))"

  project uat-issues
  shipped_phase 01-setup 01-01
  phase_detect_says uat_issues_phase=1 uat_issues_major_or_higher=true
  next_up status
  expect_case uat-issues 0 "/lbwc:vibe -- Remediate UAT issues for Phase 1"

  project auto-uat-unverified
  add_plan 01-setup 01-01 complete
  add_plan 02-build 02-01 none
  configure '{"auto_uat":true}'
  phase_detect_says has_unverified_phases=true
  next_up status
  expect_case auto-uat-unverified 0 "/lbwc:vibe -- Verify completed phases before continuing"

  project continue-discuss
  mkdir -p "$PHASES/01-setup"
  phase_detect_says config_require_phase_discussion=true
  next_up status
  expect_case continue-discuss 0 "/lbwc:discuss 01"

  project continue-preseeded
  add_doc 01-setup 01-CONTEXT.md 'pre_seeded: true'
  phase_detect_says config_require_phase_discussion=true
  next_up status
  expect_case continue-preseeded 0 "Plan Phase 01: setup (discussion pre-seeded from UAT)"

  project continue-plain
  add_plan 01-setup 01-01 none
  next_up status
  expect_case continue-plain 0 "/lbwc:vibe -- Continue Phase 01: setup"
  expect_output_has continue-plain "/lbwc:map -- Map your codebase"

  project no-numbered-phase
  mkdir -p "$PHASES/notes"
  next_up status
  expect_case no-numbered-phase 0 "/lbwc:vibe -- Start building"
  expect_output_lacks no-numbered-phase "/lbwc:map"

  project known-issues
  shipped_phase 01-setup 01-01
  printf '{"issues":[{"id":1},{"id":2}]}\n' > "$PHASES/01-setup/known-issues.json"
  next_up status
  expect_case known-issues 0 "Note: 2 known issue(s) deferred across phases"

  project unknown-map-commit
  shipped_phase 01-setup 01-01
  setup_unrelated_git_repo "$ROOT"
  mkdir -p "$PLANNING_DIR/codebase"
  printf 'git_hash: 0123456789abcdef0123456789abcdef01234567\nfile_count: 5\n' > "$PLANNING_DIR/codebase/META.md"
  next_up status
  await_git_ai
  expect_case unknown-map-commit 0 "/lbwc:map --incremental -- Codebase map is 100% stale"

  assert_no_case_failures
}

suggest_map_staleness() {
  project half-changed
  shipped_phase 01-setup 01-01
  setup_unrelated_git_repo "$ROOT"
  mkdir -p "$PLANNING_DIR/codebase"
  printf 'git_hash: %s\nfile_count: 2\n' "$(git -C "$ROOT" rev-parse HEAD)" > "$PLANNING_DIR/codebase/META.md"
  printf 'changed\n' > "$ROOT/unrelated.txt"
  git -C "$ROOT" commit -qam change
  next_up status
  await_git_ai
  expect_case half-changed 0 "/lbwc:map --incremental -- Codebase map is 50% stale"

  printf 'git_hash: %s\nfile_count: 10\n' "$(git -C "$ROOT" rev-parse HEAD~1)" > "$PLANNING_DIR/codebase/META.md"
  next_up status
  await_git_ai
  expect_case mostly-fresh 0 "All phases complete"
  expect_output_lacks mostly-fresh "/lbwc:map"

  assert_no_case_failures
}

@test "suggest-next routes each command from project, verification and debug state" {
  run_scenario_cases suggest_debug_without_phases suggest_after_vibe suggest_after_plan \
    suggest_after_qa suggest_after_fix suggest_after_verify suggest_after_debug \
    suggest_after_setup suggest_after_status suggest_map_staleness suggest_after_resume
}

suggest_after_resume() {
  project reverify
  shipped_phase 01-setup 01-01
  phase_detect_says next_phase_state=needs_reverification next_phase=1
  next_up resume
  expect_case reverify 0 "Re-verify Phase 1"
  expect_output_has reverify "/lbwc:status -- View current progress"

  project unverified-fallback
  shipped_phase 01-setup 01-01
  phase_detect_says next_phase_state=needs_verification
  next_up resume
  expect_case unverified-fallback 0 "/lbwc:vibe -- Verify completed phases before continuing"

  project uat-issues
  shipped_phase 01-setup 01-01
  phase_detect_says uat_issues_phase=1 uat_issues_slug=setup
  next_up resume
  expect_case uat-issues 0 "/lbwc:fix -- Fix minor UAT issues in Phase 1 (setup)"

  project done-clean
  shipped_phase 01-setup 01-01
  next_up resume
  expect_case done-clean 0 "All phases complete, zero deviations"

  project done-deviations
  shipped_phase 01-setup 01-01 2
  next_up resume
  expect_case done-deviations 0 "Archive completed work (2 deviation(s) logged)"

  project done-milestone
  shipped_phase 01-setup 01-01
  phase_detect_says milestone_uat_issues=true milestone_uat_slug=none
  next_up resume
  expect_case done-milestone 0 "/lbwc:vibe -- Milestone UAT recovery pending"

  project auto-uat-unverified
  add_plan 01-setup 01-01 none
  configure '{"auto_uat":true}'
  phase_detect_says has_unverified_phases=true
  next_up resume
  expect_case auto-uat-unverified 0 "/lbwc:vibe -- Verify completed phases before continuing"

  project continue
  add_plan 01-setup 01-01 none
  next_up resume
  expect_case continue 0 "/lbwc:vibe -- Continue Phase 01: setup"

  project empty
  next_up resume
  expect_case empty 0 "/lbwc:vibe -- Continue building"
  expect_output_has empty "/lbwc:status -- View current progress"

  assert_no_case_failures
}
