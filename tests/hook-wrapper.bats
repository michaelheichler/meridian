#!/usr/bin/env bats

load test_helper
load gate_case_helper
load gate_case_files

setup() {
  WRAPPER_ROOT="$(mktemp -d)"
  SESSION_LINK="/tmp/.lbwc-plugin-root-link-hook-wrapper-$$"
  mkdir -p "$WRAPPER_ROOT/scripts"
  printf 'exit 0\n' > "$WRAPPER_ROOT/scripts/stub-0.sh"
  printf 'exit 1\n' > "$WRAPPER_ROOT/scripts/stub-1.sh"
  printf 'exit 3\n' > "$WRAPPER_ROOT/scripts/stub-3.sh"
  printf 'exit 127\n' > "$WRAPPER_ROOT/scripts/stub-127.sh"
  printf 'echo "policy says no" >&2\nexit 2\n' > "$WRAPPER_ROOT/scripts/stub-2.sh"
  reset_case_failures
}

teardown() {
  rm -rf "$WRAPPER_ROOT" "$SESSION_LINK"
}

run_wrapper() {
  run env CLAUDE_PLUGIN_ROOT="$WRAPPER_ROOT" bash "$SCRIPTS_DIR/hook-wrapper.sh" "$@"
}

expect_output_is() {
  [ "$output" = "$2" ] || record_case_failure "$1" "output=[$output] want=[$2]"
}

@test "hook-wrapper resolves and runs its target, fails with exit 2 when none resolves, and downgrades target failures except exit 2" {
  local input='{"tool_input":{"command":"git status"}}'
  run env CLAUDE_PLUGIN_ROOT="$PROJECT_ROOT" bash "$SCRIPTS_DIR/hook-wrapper.sh" validate-commit.sh <<< "$input"
  expect_case real-target-with-stdin 0 ""
  expect_output_is real-target-with-stdin ""

  run_wrapper stub-0.sh
  expect_case exit-0-passes-silently 0 ""
  expect_output_is exit-0-passes-silently ""

  printf 'printf "%%s|" "$@"\n' > "$WRAPPER_ROOT/scripts/stub-args.sh"
  run_wrapper stub-args.sh one "two words"
  expect_case arguments-forwarded 0 ""
  expect_output_is arguments-forwarded "one|two words|"

  printf 'printf "%%s" "${CDPATH-unset}"\n' > "$WRAPPER_ROOT/scripts/stub-cdpath.sh"
  run env CDPATH=/tmp:. CLAUDE_PLUGIN_ROOT="$WRAPPER_ROOT" bash "$SCRIPTS_DIR/hook-wrapper.sh" stub-cdpath.sh
  expect_case cdpath-unset-for-target 0 ""
  expect_output_is cdpath-unset-for-target "unset"

  mkdir -p "$SESSION_LINK/scripts"
  printf 'printf "from-session-link"\n' > "$SESSION_LINK/scripts/stub-link-only.sh"
  run env -u CLAUDE_PLUGIN_ROOT bash "$SCRIPTS_DIR/hook-wrapper.sh" stub-link-only.sh
  expect_case session-link-fallback 0 ""
  expect_output_is session-link-fallback "from-session-link"

  mkdir -p "$WRAPPER_ROOT/self"
  cp "$SCRIPTS_DIR/hook-wrapper.sh" "$WRAPPER_ROOT/self/hook-wrapper.sh"
  printf 'printf "from-own-directory"\n' > "$WRAPPER_ROOT/self/stub-self-only.sh"
  run env -u CLAUDE_PLUGIN_ROOT bash "$WRAPPER_ROOT/self/hook-wrapper.sh" stub-self-only.sh
  expect_case own-directory-fallback 0 ""
  expect_output_is own-directory-fallback "from-own-directory"

  run bash "$SCRIPTS_DIR/hook-wrapper.sh"
  expect_case omitted-target 2 "hook target resolution failed"

  run env -u CLAUDE_PLUGIN_ROOT bash "$SCRIPTS_DIR/hook-wrapper.sh" no-such-hook.sh
  expect_case missing-target-without-root 2 "hook target resolution failed"
  expect_output_has missing-target-without-root "no-such-hook.sh"

  run_wrapper no-such-hook.sh
  expect_case missing-target-under-root 2 "unable to locate 'no-such-hook.sh'"

  run_wrapper stub-2.sh
  expect_case blocking-exit-2 2 ""
  expect_output_is blocking-exit-2 "policy says no"

  run_wrapper stub-1.sh
  expect_case exit-1-warns 1 ""
  expect_output_is exit-1-warns "meridian hook warning: stub-1.sh exited 1, call allowed"

  run_wrapper stub-3.sh
  expect_case exit-3-warns 1 ""
  expect_output_is exit-3-warns "meridian hook warning: stub-3.sh exited 3, call allowed"

  run_wrapper stub-127.sh
  expect_case exit-127-warns 1 ""
  expect_output_is exit-127-warns "meridian hook warning: stub-127.sh exited 127, call allowed"

  assert_no_case_failures
}
