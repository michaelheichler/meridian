#!/usr/bin/env bats

load test_helper

@test "an omitted hook target exits 2 with an explicit resolution error" {
  run bash "$SCRIPTS_DIR/hook-wrapper.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"hook target resolution failed"* ]]
}

@test "a missing hook target exits 2 with an explicit resolution error" {
  run env -u CLAUDE_PLUGIN_ROOT bash "$SCRIPTS_DIR/hook-wrapper.sh" no-such-hook.sh
  [ "$status" -eq 2 ]
  [[ "$output" == *"hook target resolution failed"* ]]
  [[ "$output" == *"no-such-hook.sh"* ]]
}

@test "a resolved hook target receives its input and succeeds" {
  local input='{"tool_input":{"command":"git status"}}'
  run bash -c "printf '%s' '$input' | env CLAUDE_PLUGIN_ROOT='$PROJECT_ROOT' bash '$SCRIPTS_DIR/hook-wrapper.sh' validate-commit.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

setup() {
  WRAPPER_ROOT="$(mktemp -d)"
  mkdir -p "$WRAPPER_ROOT/scripts"
  printf 'exit 0\n' > "$WRAPPER_ROOT/scripts/stub-0.sh"
  printf 'exit 1\n' > "$WRAPPER_ROOT/scripts/stub-1.sh"
  printf 'exit 3\n' > "$WRAPPER_ROOT/scripts/stub-3.sh"
  printf 'exit 127\n' > "$WRAPPER_ROOT/scripts/stub-127.sh"
  printf 'echo "policy says no" >&2\nexit 2\n' > "$WRAPPER_ROOT/scripts/stub-2.sh"
}

teardown() {
  rm -rf "$WRAPPER_ROOT"
}

run_wrapper() {
  run env CLAUDE_PLUGIN_ROOT="$WRAPPER_ROOT" bash "$SCRIPTS_DIR/hook-wrapper.sh" "$1"
}

assert_warns_and_exits_1() {
  local rc="$1"
  run_wrapper "stub-$rc.sh"
  [ "$status" -eq 1 ]
  [ "$output" = "meridian hook warning: stub-$rc.sh exited $rc, call allowed" ]
}

@test "a target that exits 0 passes silently" {
  run_wrapper stub-0.sh
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a target runs with CDPATH unset even when the caller exports it" {
  printf 'printf "%%s" "${CDPATH-unset}"\n' > "$WRAPPER_ROOT/scripts/stub-cdpath.sh"

  run env CDPATH=/tmp:. CLAUDE_PLUGIN_ROOT="$WRAPPER_ROOT" bash "$SCRIPTS_DIR/hook-wrapper.sh" stub-cdpath.sh

  [ "$status" -eq 0 ]
  [ "$output" = "unset" ]
}

@test "a target that blocks with exit 2 keeps its stderr and adds no warning" {
  run_wrapper stub-2.sh
  [ "$status" -eq 2 ]
  [ "$output" = "policy says no" ]
}

for rc in 1 3 127; do
  bats_test_function --description "a target failing with exit $rc warns and exits 1 so the call is allowed" -- assert_warns_and_exits_1 "$rc"
done
