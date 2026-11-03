#!/usr/bin/env bats

load test_helper
load gate_case_helper
load isolated_case_helper
load status_card_cases

setup() {
  mkdir -p "$BATS_TEST_TMPDIR/repo"
  cd "$BATS_TEST_TMPDIR/repo"
  git init -q
  export HOME="$BATS_TEST_TMPDIR/home"
  export LBWC_PLANNING_DIR="$PWD/.lbwc-planning"
  mkdir -p "$HOME" "$LBWC_PLANNING_DIR"
  printf '{}\n' > "$LBWC_PLANNING_DIR/config.json"
  printf 'next_phase=build\nphase_detect_complete=true\nphase_detect_error=false\n' > phase
  jq -n '{status:"done",product:"Sample product",step:"Implement parser",plan:"Parser plan",changed_files:["parser.sh","parser.md"],lines_changed:{added:12,deleted:3},tests:"Parser checks pass",commands:[{command:"check parser",exit_code:0,main_session:true}],open_questions:[],next:{command:"/sample:qa",step:"Review parser"},cause:"hidden cause",details:["hidden detail"],fix:"hidden fix"}' > result
}

teardown() {
  await_git_ai
}

@test "feedback preserves status scope facts proof and next actions" {
  run_scenario_cases card_done card_running card_needs_you card_failed card_ascii_done card_ascii_running card_ascii_needs_you card_ascii_failed card_questions card_clipping card_rendered_contracts card_qa_handoff
}

@test "feedback rejects invalid results and unavailable inputs without claiming completion" {
  run_scenario_cases card_malformed card_multiple card_wrong_types card_missing_main card_null_main card_string_main card_string_exit card_negative_exit card_fraction_exit card_large_exit card_float_lines card_no_commands card_open_done card_nonzero card_missing_phase card_empty_phase card_phase_error card_missing_args card_unreadable card_no_jq
}

@test "feedback renders untrusted text as inert cells without terminal controls" {
  run_scenario_cases card_controls card_phase_controls card_markup card_command_injection
}
