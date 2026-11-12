#!/usr/bin/env bats

load test_helper
load gate_case_helper
load tmux_restriction_cases

setup() {
  mkdir -p "$BATS_TEST_TMPDIR/repo"
  cd "$BATS_TEST_TMPDIR/repo"
  git init -q
  export HOME="$BATS_TEST_TMPDIR/home"
  export MERIDIAN_PLANNING_DIR="$PWD/.meridian"
  export MERIDIAN_TMUX_CONTROL_ROOT="$MERIDIAN_PLANNING_DIR"
  export MERIDIAN_TMUX_AGENT=1 TMUX=fixture TMUX_PANE=%42
  unset MERIDIAN_TMUX_AGENT_ID
  mkdir -p "$HOME" "$MERIDIAN_PLANNING_DIR/phases/one"
}

teardown() {
  await_git_ai
}

@test "frozen git restrictions deny executable writes without blocking ordinary arguments or reads" {
  restriction_git_rows
}

@test "worker restrictions fail closed and preserve frozen authority across guard entry points" {
  restriction_policy_rows
}
