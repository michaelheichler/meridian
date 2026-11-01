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
  HOOK="$SCRIPTS_DIR/pre-push-hook.sh"
  reset_case_failures
}

teardown() {
  await_git_ai
}

plugin_repo() {
  local dir="$WORK/$1" name=$2 verifier=$3
  mkdir -p "$dir"
  git init -q "$dir"
  [ -z "$name" ] || write_text "$dir/.claude-plugin/plugin.json" "{\"name\": \"$name\"}"
  case "$verifier" in
    pass) write_text "$dir/scripts/version-bump.sh" '[ "$1" = "--verify" ] || exit 9' 'echo "all versions match"' ;;
    mismatch) write_text "$dir/scripts/version-bump.sh" '[ "$1" = "--verify" ] || exit 9' \
      'echo "checking"' 'echo "MISMATCH: VERSION 1.0.1 vs plugin.json 1.0.0"' 'exit 1' ;;
  esac
  printf '%s\n' "$dir"
}

push_in() {
  run bash -c 'CDPATH="" cd -- "$1" && bash "$2" origin' _ "$1" "$HOOK"
}

@test "pre-push-hook blocks a push only when the lbwc version files disagree" {
  mkdir -p "$WORK/plain"
  push_in "$WORK/plain"
  expect_status "outside-repo" 0
  expect_output_nonempty "outside-repo-warns"

  push_in "$(plugin_repo no-verifier lbwc none)"
  expect_case_silent "no-version-bump-script" 0

  push_in "$(plugin_repo no-manifest "" mismatch)"
  expect_case_silent "no-plugin-manifest" 0

  push_in "$(plugin_repo other-plugin other mismatch)"
  expect_case_silent "other-plugin" 0

  push_in "$(plugin_repo in-sync lbwc pass)"
  expect_case_silent "versions-in-sync" 0

  push_in "$(plugin_repo out-of-sync lbwc mismatch)"
  expect_case "versions-out-of-sync" 1 "MISMATCH: VERSION 1.0.1 vs plugin.json 1.0.0"

  assert_no_case_failures
}
