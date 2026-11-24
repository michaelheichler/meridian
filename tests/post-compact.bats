#!/usr/bin/env bats

load gate_case_helper

setup() {
  unset CDPATH TMUX TMUX_PANE MERIDIAN_PLANNING_DIR
  POST_COMPACT="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd -P)/post-compact.sh"
  PROJECT="$BATS_TEST_TMPDIR/project"
  mkdir -p "$PROJECT"
  git -C "$PROJECT" init -q
  PYTHON_LOG="$BATS_TEST_TMPDIR/python3.calls"
  RECORDER_BIN="$BATS_TEST_TMPDIR/recorder-bin"
  install_python_recorder
  reset_case_failures
}

install_python_recorder() {
  local real_python
  real_python=$(command -v python3)
  mkdir -p "$RECORDER_BIN"
  printf '%s\n' '#!/bin/sh' "printf '%s\\n' \"\$*\" >> '$PYTHON_LOG'" "exec '$real_python' \"\$@\"" > "$RECORDER_BIN/python3"
  chmod +x "$RECORDER_BIN/python3"
}

run_post_compact() {
  (cd "$PROJECT" && printf '%s' '{"session_id":"s1"}' | PATH="$RECORDER_BIN:$PATH" bash "$POST_COMPACT")
}

@test "post compact stays silent and skips the usage reset in a project without a planning dir" {
  run run_post_compact

  expect_case_silent no-planning-dir 0
  [ ! -e "$PYTHON_LOG" ] || record_case_failure no-planning-dir "python3 ran with [$(cat "$PYTHON_LOG")]"
  [ ! -e "$PROJECT/.meridian" ] || record_case_failure no-planning-dir "planning dir was created"
  assert_no_case_failures
}

@test "post compact records a usage reset baseline in a project with a planning dir" {
  mkdir "$PROJECT/.meridian"

  run run_post_compact

  expect_case with-planning-dir 0
  [ -s "$PYTHON_LOG" ] || record_case_failure with-planning-dir "python3 recorder saw no call"
  [ -e "$PROJECT/.meridian/.context-usage-reset" ] || record_case_failure with-planning-dir "no reset baseline"
  assert_no_case_failures
}
