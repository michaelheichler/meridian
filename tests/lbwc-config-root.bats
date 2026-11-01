#!/usr/bin/env bats

load test_helper
load gate_case_helper

setup() {
  mkdir -p "$BATS_TEST_TMPDIR/work" "$BATS_TEST_TMPDIR/home"
  export HOME="$BATS_TEST_TMPDIR/home"
  WORK=$(CDPATH="" cd -- "$BATS_TEST_TMPDIR/work" && pwd -P)
  LIB="$SCRIPTS_DIR/lib/lbwc-config-root.sh"
  reset_case_failures
}

teardown() {
  await_git_ai
}

lbwc_project() {
  mkdir -p "$1/.lbwc-planning"
  printf '{}\n' > "$1/.lbwc-planning/config.json"
}

find_root_from() {
  local cwd=$1
  shift
  run env -u LBWC_CONFIG_ROOT -u LBWC_PLANNING_DIR -u LBWC_CLAUDE_SIDECHAIN_HOST_ROOT \
    bash -c 'CDPATH="" cd -- "$2" || exit 9
      . "$1"
      shift 2
      find_lbwc_root "$@"
      printf "%s|%s|%s" "$LBWC_CONFIG_ROOT" "$LBWC_PLANNING_DIR" "${LBWC_CLAUDE_SIDECHAIN_HOST_ROOT:-}"' \
    _ "$LIB" "$cwd" "$@"
}

expect_root() {
  local label=$1 root=$2 host=${3:-}
  [ "$status" -eq 0 ] && [ "$output" = "$root|$root/.lbwc-planning|$host" ] \
    || record_case_failure "$label" "status=$status output=[$output] want=[$root|$root/.lbwc-planning|$host]"
}

@test "find_lbwc_root resolves the project root from cwd, a start directory or a Claude worktree" {
  local host_tree="$WORK/host/.claude/worktrees/agent-abc"
  lbwc_project "$WORK/proj"
  lbwc_project "$WORK/host"
  lbwc_project "$host_tree"
  mkdir -p "$WORK/proj/src/deep" "$WORK/proj/agent-y" "$host_tree/sub" \
    "$WORK/fake/.claude/worktrees/agent-x" "$WORK/bare/dir"

  run env LBWC_CONFIG_ROOT=/custom bash -c '. "$1"; find_lbwc_root; printf "%s|%s" "$LBWC_CONFIG_ROOT" "$LBWC_PLANNING_DIR"' _ "$LIB"
  expect_case "preset-root-wins" 0 "/custom|/custom/.lbwc-planning"

  find_root_from "$WORK/proj/src/deep"
  expect_root "walks-up-from-cwd" "$WORK/proj"
  find_root_from "$host_tree/sub"
  expect_root "worktree-prefers-host" "$WORK/host" "$WORK/host"
  find_root_from "$WORK/proj/agent-y"
  expect_root "agent-dir-outside-worktrees" "$WORK/proj"
  find_root_from "$WORK/fake/.claude/worktrees/agent-x"
  expect_root "worktree-host-without-config" "$WORK/fake/.claude/worktrees/agent-x"
  find_root_from "$WORK/bare/dir"
  expect_root "no-root-falls-back-to-cwd" "$WORK/bare/dir"

  find_root_from "$WORK/bare/dir" "$WORK/proj/src"
  expect_root "start-dir-used-when-cwd-has-no-root" "$WORK/proj"
  find_root_from "$WORK/proj/src/deep" "$WORK/bare/dir"
  expect_root "cwd-root-beats-start-dir" "$WORK/proj"
  find_root_from "$host_tree/sub" "$WORK/proj"
  expect_root "worktree-host-beats-start-dir" "$WORK/host" "$WORK/host"
  find_root_from "$WORK/bare/dir" "$WORK/absent"
  expect_root "missing-start-dir-falls-back-to-cwd" "$WORK/bare/dir"

  assert_no_case_failures
}
