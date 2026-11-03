#!/usr/bin/env bats

load test_helper
load gate_case_helper
load visual_format_helper

setup() {
  setup_temp_dir
  BASELINE="$TEST_TEMP_DIR/old"
  mkdir -p "$BASELINE"
  git -C "$PROJECT_ROOT" archive e3b03cbd82c87d7d313efb82584d0b19cdad0c97 | tar -x -C "$BASELINE"
  SUBJECT="${VISUAL_SUBJECT_ROOT:-$PROJECT_ROOT}"
  export CLAUDE_SESSION_ID=visual-session
  export CLAUDE_CONFIG_DIR="$TEST_TEMP_DIR/claude-config"
  setup_unrelated_git_repo "$TEST_TEMP_DIR/repo"
  cd "$TEST_TEMP_DIR/repo" || return 1
  printf 'initial\n' > dummy
  git add dummy
  git commit -qm fixture
  await_git_ai
  reset_case_failures
}

teardown() {
  cd "$PROJECT_ROOT" || return 1
  await_git_ai
  teardown_temp_dir
}

@test "ASCII rendering replaces display glyphs without changing content bytes or research artifacts" {
  visual_matrix ascii
  assert_no_case_failures
}

@test "Unicode and absent format settings preserve the original emitter bytes" {
  visual_matrix unicode
  visual_matrix missing-key
  visual_matrix missing-config
  assert_no_case_failures
}
