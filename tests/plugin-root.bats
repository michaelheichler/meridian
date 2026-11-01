#!/usr/bin/env bats

load test_helper
load gate_case_helper
load gate_case_files

setup() {
  setup_temp_dir
  export CLAUDE_SESSION_ID="plugin-root-$$"
  export CLAUDE_CONFIG_DIR="$TEST_TEMP_DIR/.claude"
  mkdir -p "$CLAUDE_CONFIG_DIR"
  export ROOT_LINK="/tmp/.lbwc-plugin-root-link-${CLAUDE_SESSION_ID}"
  rm -rf "$ROOT_LINK"
  PLUGIN_ROOT="$TEST_TEMP_DIR/plugin"
  reset_case_failures
}

teardown() {
  rm -rf "$ROOT_LINK"
  teardown_temp_dir
}

make_plugin_root() {
  mkdir -p "$PLUGIN_ROOT/scripts"
  touch "$PLUGIN_ROOT/scripts/hook-wrapper.sh"
  ln -s "$SCRIPTS_DIR/ensure-plugin-root-link.sh" "$PLUGIN_ROOT/scripts/ensure-plugin-root-link.sh"
  CANONICAL_ROOT=$(cd "$PLUGIN_ROOT" && pwd -P)
}

install_failing_ln() {
  local planted_target="$1"
  mkdir -p "$TEST_TEMP_DIR/bin"
  cat > "$TEST_TEMP_DIR/bin/ln" <<'SHIM'
#!/bin/sh
[ -z "$PLANTED_LINK_TARGET" ] || /bin/ln -s "$PLANTED_LINK_TARGET" "$3"
exit 1
SHIM
  chmod +x "$TEST_TEMP_DIR/bin/ln"
  PLANTED_TARGET="$planted_target"
}

run_ensure_with_failing_ln() {
  run env PATH="$TEST_TEMP_DIR/bin:$PATH" PLANTED_LINK_TARGET="$PLANTED_TARGET" bash "$SCRIPTS_DIR/ensure-plugin-root-link.sh" "$ROOT_LINK" "$PLUGIN_ROOT"
}

expect_output_is() {
  [ "$output" = "$2" ] || record_case_failure "$1" "output=[$output] want=[$2]"
}

expect_link_target() {
  [ "$(readlink "$ROOT_LINK" 2>/dev/null)" = "$2" ] \
    || record_case_failure "$1" "link $ROOT_LINK points to [$(readlink "$ROOT_LINK" 2>/dev/null)] want=[$2]"
}

@test "resolve-plugin-root fails on a missing root, script, argument or link and otherwise prints the first valid root and links the session to it" {
  local cache_root="$CLAUDE_CONFIG_DIR/plugins/cache/lbwc-marketplace/lbwc/local"
  mkdir -p "$cache_root/scripts"
  touch "$cache_root/scripts/hook-wrapper.sh"

  run env -u CLAUDE_PLUGIN_ROOT bash "$SCRIPTS_DIR/resolve-plugin-root.sh"
  expect_case plugin-cache-candidate-ignored 1 "LBWC: plugin root unavailable"
  [ ! -e "$ROOT_LINK" ] || record_case_failure plugin-cache-candidate-ignored "link was created for a cache candidate"

  run env -u CLAUDE_PLUGIN_ROOT bash "$SCRIPTS_DIR/resolve-plugin-root.sh" --nonfatal
  expect_case nonfatal-missing-root 0 ""
  expect_output_is nonfatal-missing-root ""

  make_plugin_root
  run env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$SCRIPTS_DIR/resolve-plugin-root.sh" --require-script absent.sh
  expect_case required-script-absent 1 "LBWC: plugin root unavailable"

  run env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$SCRIPTS_DIR/resolve-plugin-root.sh" --require-script
  expect_case require-script-without-name 2 "Usage: resolve-plugin-root.sh"

  run env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$SCRIPTS_DIR/resolve-plugin-root.sh" --bogus
  expect_case unknown-option 2 "Usage: resolve-plugin-root.sh"

  run env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$SCRIPTS_DIR/resolve-plugin-root.sh" --require-script ../hook-wrapper.sh
  expect_case script-name-with-slash 2 "expects a script name"

  install_failing_ln ""
  run env PATH="$TEST_TEMP_DIR/bin:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$SCRIPTS_DIR/resolve-plugin-root.sh"
  expect_case link-cannot-be-created 1 "LBWC: plugin root link unavailable"

  run env PATH="$TEST_TEMP_DIR/bin:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$SCRIPTS_DIR/resolve-plugin-root.sh" --nonfatal
  expect_case nonfatal-link-failure 0 ""

  rm -rf "$ROOT_LINK"
  run env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$SCRIPTS_DIR/resolve-plugin-root.sh"
  expect_case configured-root 0 ""
  expect_output_is configured-root "$CANONICAL_ROOT"
  [ -L "$ROOT_LINK" ] || record_case_failure configured-root "session link was not created"
  expect_link_target configured-root "$CANONICAL_ROOT"

  run env -u CLAUDE_PLUGIN_ROOT bash "$SCRIPTS_DIR/resolve-plugin-root.sh"
  expect_case session-link-fallback 0 ""
  expect_output_is session-link-fallback "$CANONICAL_ROOT"

  touch "$PLUGIN_ROOT/scripts/other.sh"
  run env CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$SCRIPTS_DIR/resolve-plugin-root.sh" --require-script other.sh
  expect_case require-script-present 0 ""
  expect_output_is require-script-present "$CANONICAL_ROOT"

  assert_no_case_failures
}

@test "ensure-plugin-root-link creates or repairs the session symlink and fails on bad arguments, a foreign link name, a missing target or a link that cannot be made" {
  mkdir -p "$PLUGIN_ROOT" "$ROOT_LINK"
  touch "$ROOT_LINK/stale"
  run bash "$SCRIPTS_DIR/ensure-plugin-root-link.sh" "$ROOT_LINK" "$PLUGIN_ROOT"
  expect_case stale-directory-replaced 0 ""
  [ -L "$ROOT_LINK" ] || record_case_failure stale-directory-replaced "link path is not a symlink"
  expect_link_target stale-directory-replaced "$PLUGIN_ROOT"

  run bash "$SCRIPTS_DIR/ensure-plugin-root-link.sh" "$ROOT_LINK" "$PLUGIN_ROOT"
  expect_case already-correct-link 0 ""
  expect_link_target already-correct-link "$PLUGIN_ROOT"

  mkdir -p "$TEST_TEMP_DIR/old"
  rm -f "$ROOT_LINK"
  ln -s "$TEST_TEMP_DIR/old" "$ROOT_LINK"
  run bash "$SCRIPTS_DIR/ensure-plugin-root-link.sh" "$ROOT_LINK" "$PLUGIN_ROOT"
  expect_case link-to-other-target-repointed 0 ""
  expect_link_target link-to-other-target-repointed "$PLUGIN_ROOT"
  expect_no_path link-to-other-target-repointed "$TEST_TEMP_DIR/old/plugin"

  rm -f "$ROOT_LINK"
  install_failing_ln "$PLUGIN_ROOT"
  run_ensure_with_failing_ln
  expect_case racing-winner-already-linked-target 0 ""
  expect_link_target racing-winner-already-linked-target "$PLUGIN_ROOT"

  rm -rf "$ROOT_LINK" "$TEST_TEMP_DIR/bin/ln"
  run bash "$SCRIPTS_DIR/ensure-plugin-root-link.sh"
  expect_case missing-arguments 1 "Usage: ensure-plugin-root-link.sh"

  run bash "$SCRIPTS_DIR/ensure-plugin-root-link.sh" "/tmp/.not-lbwc-plugin-root-link-${CLAUDE_SESSION_ID}" "$PLUGIN_ROOT"
  expect_case non-lbwc-link-name 1 "unexpected link path basename"

  run bash "$SCRIPTS_DIR/ensure-plugin-root-link.sh" "$ROOT_LINK" "$TEST_TEMP_DIR/missing"
  expect_case target-directory-missing 1 "target directory does not exist"

  mkdir -p "$TEST_TEMP_DIR/elsewhere"
  install_failing_ln "$TEST_TEMP_DIR/elsewhere"
  run_ensure_with_failing_ln
  expect_case ln-fails-link-points-elsewhere 1 "could not link $ROOT_LINK to $PLUGIN_ROOT"

  rm -f "$ROOT_LINK"
  install_failing_ln ""
  run_ensure_with_failing_ln
  expect_case ln-fails-no-link-exists 1 "could not link $ROOT_LINK to $PLUGIN_ROOT"
  [ ! -e "$ROOT_LINK" ] && [ ! -L "$ROOT_LINK" ] || record_case_failure ln-fails-no-link-exists "a link exists after the failure"

  rm -f "$ROOT_LINK"
  mkdir -p "$TEST_TEMP_DIR/old"
  ln -s "$TEST_TEMP_DIR/old" "$ROOT_LINK"
  printf '#!/bin/sh\nexit 0\n' > "$TEST_TEMP_DIR/bin/rm"
  chmod +x "$TEST_TEMP_DIR/bin/rm"
  rm -f "$TEST_TEMP_DIR/bin/ln"
  run env PATH="$TEST_TEMP_DIR/bin:$PATH" bash "$SCRIPTS_DIR/ensure-plugin-root-link.sh" "$ROOT_LINK" "$PLUGIN_ROOT"
  expect_no_path link-never-created-inside-old-target "$TEST_TEMP_DIR/old/plugin"
  expect_status link-never-created-inside-old-target 1

  assert_no_case_failures
}
