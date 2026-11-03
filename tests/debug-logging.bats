#!/usr/bin/env bats

load test_helper
load gate_case_helper
load isolated_case_helper
load debug_logging_cases

setup() {
  mkdir -p "$BATS_TEST_TMPDIR/repo"
  cd "$BATS_TEST_TMPDIR/repo"
  git init -q
  export HOME="$BATS_TEST_TMPDIR/home"
  export LBWC_PLANNING_DIR="$PWD/.lbwc-planning"
  mkdir -p "$HOME" "$LBWC_PLANNING_DIR"
  printf '{"debug_logging":true}\n' > "$LBWC_PLANNING_DIR/config.json"
}

teardown() {
  chmod -R u+w "$LBWC_PLANNING_DIR" 2>/dev/null || true
  await_git_ai
}

@test "optional decision logging preserves hook results and excludes tool payloads" {
  run_scenario_cases logging_missing logging_off logging_allow logging_deny logging_error logging_timeout logging_payload logging_readonly logging_missing_dir logging_slow logging_ignored
}

@test "decision logs rotate only after the size limit and serialize concurrent appends" {
  run_scenario_cases logging_exact_limit logging_rotate logging_concurrent
}

@test "config audit reports undocumented and unread keys while accepting stored settings" {
  run_scenario_cases config_matching config_unread config_undocumented config_stored config_real
}
