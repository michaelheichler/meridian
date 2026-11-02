#!/usr/bin/env bats

load test_helper
load gate_case_helper
load isolated_case_helper

setup() {
  setup_temp_dir
  cd "$TEST_TEMP_DIR" || return 1
  git init --quiet
  await_git_ai
  export CLAUDE_SESSION_ID="verify-load-$$-$RANDOM"
  export CLAUDE_PLUGIN_ROOT="$PROJECT_ROOT"
  printf -v SESSION_LINK '/tmp/.lbwc-plugin-root-link-%s' "$CLAUDE_SESSION_ID"
  printf -v DETECT_CACHE '/tmp/.lbwc-phase-detect-%s.txt' "$CLAUDE_SESSION_ID"
  ln -s "$PROJECT_ROOT" "$SESSION_LINK"
  mkdir -p .lbwc-planning/phases/07-checkout
  printf '%s\n' '{}' > .lbwc-planning/config.json
  printf '%s\n' '# Checkout' > .lbwc-planning/PROJECT.md
  printf '%s\n' 'Phase: 07' 'Status: ready for verification' > .lbwc-planning/STATE.md
  printf '%s\n' '# Checkout plan' > .lbwc-planning/phases/07-checkout/07-01-PLAN.md
  printf '%s\n' '---' 'status: complete' '---' > .lbwc-planning/phases/07-checkout/07-01-SUMMARY.md
}

teardown() {
  rm -f "$SESSION_LINK" "$DETECT_CACHE"
  rm -rf "/tmp/.lbwc-phase-detect-live-${CLAUDE_SESSION_ID}.lock"
  await_git_ai
  cd "$PROJECT_ROOT" || return 1
  teardown_temp_dir
}

load_section() {
  run bash "$SCRIPTS_DIR/verify-load-context.sh" "$1"
  [ "$status" -eq 0 ]
}

cache_target() {
  printf 'next_phase_state=%s\nnext_phase_slug=07-checkout\nfirst_unverified_slug=%s\n' \
    "$1" "$2" > "$DETECT_CACHE"
}

state_lines() {
  load_section state
  [[ "$output" == *$'Phase: 07\nStatus: ready for verification'* ]]
}

phase_listing() {
  mkdir -p .lbwc-planning/phases/11-receipts
  load_section phases
  [[ "$output" == *07-checkout* ]]
  [[ "$output" == *11-receipts* ]]
}

phase_detection() {
  load_section phase-state
  [[ "$output" == *next_phase_state=all_done* ]]
  [[ "$output" == *phase_count=1* ]]
  [[ "$output" == *first_unverified_phase=07* ]]
  [[ "$output" == *first_unverified_slug=07-checkout* ]]
}

phase_detection_root_fallback() {
  rm "$SESSION_LINK"
  phase_detection
}

compact_warning() {
  printf '%s|99|100000\n' "$CLAUDE_SESSION_ID" > .lbwc-planning/.context-usage
  load_section compact
  [[ "$output" == *99%* ]]
  [[ "$output" == *1000* ]]
}

qa_results() {
  printf '%s\n' '---' 'result: passed' 'passed: 3' 'failed: 0' 'total: 3' '---' \
    '✓ **Checkout preserves cart**' \
    > .lbwc-planning/phases/07-checkout/07-VERIFICATION.md
  load_section qa-summary
  [[ "$output" == *'Checkout preserves cart'* ]]
  [[ "$output" == *'3/3'* ]]
}

hint_verification() {
  cache_target needs_verification 03-account
  load_section verify-context
  [[ "$output" == *verify_target_slug=07-checkout* ]]
  [[ "$output" != *verify_target_slug=03-account* ]]
}

hint_reverification() {
  cache_target needs_reverification 03-account
  load_section verify-context
  [[ "$output" == *verify_target_slug=07-checkout* ]]
}

hint_first_unverified() {
  cache_target mid_execution 03-account
  load_section verify-context
  [[ "$output" == *verify_target_slug=03-account* ]]
}

hint_without_first_unverified() {
  cache_target mid_execution ''
  load_section verify-context
  [[ "$output" == *verify_target_slug=07-checkout* ]]
}

resume_metadata() {
  printf '%s\n' '---' 'status: testing' '---' '### P1: Add an item' \
    '- **Result:** pass' '### P2: Submit checkout' \
    '- **Scenario:** Submit a saved cart' '- **Expected:** Receipt contains both items' \
    > .lbwc-planning/phases/07-checkout/07-UAT.md
  load_section uat-resume
  [[ "$output" == *uat_resume_target_slug=07-checkout* ]]
  [[ "$output" == *uat_path=.lbwc-planning/phases/07-checkout/07-UAT.md* ]]
  [[ "$output" == *'uat_resume=P2 uat_completed=1 uat_total=2'* ]]
  [[ "$output" == *uat_resume_scenario='Submit a saved cart'* ]]
  [[ "$output" == *uat_resume_expected='Receipt contains both items'* ]]
}

resume_root_fallback() {
  rm "$SESSION_LINK"
  resume_metadata
}

resume_none() {
  load_section uat-resume
  [[ "$output" == *uat_resume_target_slug=07-checkout* ]]
  [[ "$output" == *uat_resume=none* ]]
}

missing_state() {
  rm .lbwc-planning/STATE.md
  load_section state
  [ -n "$output" ]
  [[ "$output" != *'Phase: 07'* ]]
}

missing_phases() {
  rm -rf .lbwc-planning/phases
  load_section phases
  [ -n "$output" ]
  [[ "$output" != *07-checkout* ]]
}

missing_resolver() {
  rm "$SESSION_LINK"
  export CLAUDE_PLUGIN_ROOT="$TEST_TEMP_DIR/missing-plugin"
}

failed_phase_detection() {
  missing_resolver
  printf '%s\n' 'next_phase_slug=stale-phase' > "$DETECT_CACHE"
  load_section phase-state
  [[ "$output" == *phase_detect_error=true* ]]
}

unavailable_hint() {
  load_section verify-context
  [[ "$output" == *verify_target_slug=unavailable* ]]
}

sentinel_hint() {
  printf '%s\n' phase_detect_error=true > "$DETECT_CACHE"
  unavailable_hint
}

blank_hint() {
  printf ' \n\t\n' > "$DETECT_CACHE"
  unavailable_hint
}

unavailable_resume() {
  missing_resolver
  load_section uat-resume
  [[ "$output" == *uat_resume=unavailable* ]]
}

resume_without_target() {
  rm -rf .lbwc-planning/phases/07-checkout
  load_section uat-resume
  [[ "$output" == *uat_resume=unavailable* ]]
}

load_invalid_section() {
  bash "$SCRIPTS_DIR/verify-load-context.sh" not-a-section \
    > "$TEST_TEMP_DIR/stdout" 2> "$TEST_TEMP_DIR/usage"
}

unknown_section() {
  run load_invalid_section
  [ "$status" -eq 2 ]
  [ ! -s "$TEST_TEMP_DIR/stdout" ]
  grep -Fq "$SCRIPTS_DIR/verify-load-context.sh" "$TEST_TEMP_DIR/usage"
}

@test "verify load context reports fixture state, target hints, QA evidence and resumable checkpoints" {
  run_scenario_cases state_lines phase_listing phase_detection phase_detection_root_fallback \
    compact_warning qa_results hint_verification hint_reverification hint_first_unverified \
    hint_without_first_unverified resume_metadata resume_root_fallback resume_none
}

@test "verify load context degrades safely when inputs or helpers are unavailable and rejects invalid sections" {
  run_scenario_cases missing_state missing_phases failed_phase_detection unavailable_hint \
    sentinel_hint blank_hint unavailable_resume resume_without_target unknown_section
}
