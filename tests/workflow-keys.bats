#!/usr/bin/env bats

load test_helper
load gate_case_helper
load workflow_keys_helper
load workflow_milestone_helper

setup() {
  local scripts_dir
  scripts_dir=$(CDPATH='' cd -- "$BATS_TEST_DIRNAME/../scripts" && pwd -P)
  printf -v SCRIPTS_DIR '%s' "$scripts_dir"
  export SCRIPTS_DIR
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL=/dev/null
}

teardown() {
  await_git_ai
}

@test "research routing respects opt in and reuses only unambiguous phase research" {
  workflow_cases research missing false balanced-off thorough-off required turbo canonical legacy multiple
}

@test "milestone branches preserve work and offer completion without merging" {
  workflow_cases milestone missing false clean planning custom-planning symlink tracked staged untracked repeat repeat-dirty complete complete-disabled unmanaged derived finish restart
}

@test "plain summaries honor visibility and reject empty enabled summaries" {
  workflow_cases summary missing true false empty
}

@test "QA routing skips only sole eligible owners and retains review evidence" {
  workflow_cases qa missing explicit-empty alternative mixed unknown empty empty-input malformed malformed-json all-skip
}
