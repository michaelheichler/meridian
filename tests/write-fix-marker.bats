#!/usr/bin/env bats

load test_helper
load gate_case_helper

setup() {
  setup_temp_dir
  reset_case_failures
}

teardown() {
  cd "$PROJECT_ROOT"
  await_git_ai
  teardown_temp_dir
}

repo_with_fix_commit() {
  local repo="$TEST_TEMP_DIR/$1"
  mkdir -p "$repo/.meridian" "$repo/src"
  cd "$repo" || return 1
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  printf 'fixed\n' > src/parser.sh
  git add src/parser.sh
  git commit -q -m "fix: repair parser"
}

marker_after_run() {
  bash "$SCRIPTS_DIR/write-fix-marker.sh" "$@" || return
  cat .meridian/.last-fix-commit 2>/dev/null || printf 'no-marker\n'
}

marker_after_run_without_git() {
  local bash_bin
  bash_bin=$(command -v bash)
  mkdir -p "$TEST_TEMP_DIR/no-git-bin"
  env PATH="$TEST_TEMP_DIR/no-git-bin" "$bash_bin" "$SCRIPTS_DIR/write-fix-marker.sh" .meridian || return
  cat .meridian/.last-fix-commit 2>/dev/null || printf 'no-marker\n'
}

@test "fix marker records the HEAD commit for inline QA and stays silent without a repo" {
  local head

  repo_with_fix_commit default-description
  head=$(git rev-parse HEAD)
  run marker_after_run .meridian
  expect_case default-description 0 "commit=$head"
  expect_case default-description 0 "description=fix: repair parser"
  expect_case default-description 0 "files=src/parser.sh"

  repo_with_fix_commit custom-description
  run marker_after_run .meridian $'first line\nsecond line'
  expect_case custom-description 0 "description=first line second line"
  expect_case custom-description 0 "message=fix: repair parser"

  repo_with_fix_commit missing-planning-dir
  run marker_after_run absent-planning-dir
  expect_case missing-planning-dir 0 "no-marker"

  repo_with_fix_commit git-unavailable
  run marker_after_run_without_git
  expect_case git-unavailable 0 "no-marker"

  mkdir -p "$TEST_TEMP_DIR/plain/.meridian"
  cd "$TEST_TEMP_DIR/plain"
  run marker_after_run .meridian
  expect_case outside-git-repo 0 "no-marker"

  assert_no_case_failures
}
