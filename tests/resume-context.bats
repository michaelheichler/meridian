#!/usr/bin/env bats

load test_helper
load gate_case_helper
load isolated_case_helper
load resume_context_helper

setup() {
  unset LBWC_CONTROL_ROOT LBWC_PROJECT_ROOT LBWC_PLANNING_DIR
  export LBWC_PLANNING_DIR="$BATS_TEST_TMPDIR/planning"
  mkdir -p "$LBWC_PLANNING_DIR"
}

teardown() { await_git_ai; }

@test "resume reports only commits since the journal and stays quiet at the same HEAD" {
  run_scenario_cases unchanged_history advanced_history
}

@test "resume falls back safely when journal history is unavailable and retains the working diff" {
  run_scenario_cases unknown_history missing_history divergent_history absent_journal
}

@test "resume selects only active phase evidence across layouts and keeps recovery context small" {
  run_scenario_cases numbered_evidence legacy_evidence custom_planning discovered_planning
}

@test "resume suppresses clean consistency output and retains actionable drift" {
  run_scenario_cases clean_consistency drift_consistency
}

@test "compaction preserves recovery context and surfaces phase detection failures" {
  run_scenario_cases worker_compaction orchestrator_compaction failed_phase_detection failed_compaction
}
