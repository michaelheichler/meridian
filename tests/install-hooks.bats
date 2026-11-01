#!/usr/bin/env bats

load test_helper
load gate_case_helper
load gate_case_files
load text_case_helper

setup() {
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK" "$BATS_TEST_TMPDIR/home"
  export HOME="$BATS_TEST_TMPDIR/home"
  export GIT_CEILING_DIRECTORIES="$WORK"
  unset GIT_DIR GIT_WORK_TREE
  INSTALL="$SCRIPTS_DIR/install-hooks.sh"
  reset_case_failures
}

teardown() {
  await_git_ai
}

repo() {
  local dir="$WORK/$1"
  mkdir -p "$dir"
  git init -q "$dir"
  printf '%s\n' "$dir"
}

install_in() {
  run bash -c 'CDPATH="" cd -- "$1" && bash "$2"' _ "$1" "$INSTALL"
}

@test "install-hooks writes a managed pre-push hook and leaves foreign hooks alone" {
  local dir hook fresh before

  mkdir -p "$WORK/plain"
  install_in "$WORK/plain"
  expect_case_silent "outside-repo" 0
  expect_no_path "outside-repo-creates-no-git-dir" "$WORK/plain/.git"

  dir=$(repo fresh)
  hook="$dir/.git/hooks/pre-push"
  rm -f "$hook"
  install_in "$dir"
  expect_case "fresh" 0 "Installed"
  [ -x "$hook" ] || record_case_failure "fresh-executable" "hook is not executable"
  expect_file_line "fresh-delegates-to-plugin" "$hook" "scripts/pre-push-hook.sh"
  fresh=$(file_digest "$hook")

  install_in "$dir"
  expect_status "rerun" 0
  expect_same_digest "rerun-keeps-same-hook" "$hook" "$fresh"

  dir=$(repo legacy)
  hook="$dir/.git/hooks/pre-push"
  write_text "$hook" '#!/usr/bin/env bash' '_lbwc_find_script() { :; }'
  install_in "$dir"
  expect_status "legacy" 0
  expect_same_digest "legacy-upgraded-to-current" "$hook" "$fresh"
  [ -x "$hook" ] || record_case_failure "legacy-executable" "hook is not executable"

  dir=$(repo foreign)
  hook="$dir/.git/hooks/pre-push"
  write_text "$hook" '#!/bin/sh' 'echo mine'
  before=$(file_digest "$hook")
  install_in "$dir"
  expect_status "foreign" 0
  expect_same_digest "foreign-untouched" "$hook" "$before"

  dir=$(repo foreign-link)
  hook="$dir/.git/hooks/pre-push"
  write_text "$dir/custom-hook" '#!/bin/sh' 'echo custom'
  before=$(file_digest "$dir/custom-hook")
  ln -s "$dir/custom-hook" "$hook"
  install_in "$dir"
  expect_status "foreign-link" 0
  [ -L "$hook" ] || record_case_failure "foreign-link-still-link" "hook is no longer a symlink"
  expect_same_digest "foreign-link-target-untouched" "$dir/custom-hook" "$before"

  assert_no_case_failures
}
