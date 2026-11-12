#!/usr/bin/env bats

load gate_case_helper
load gate_case_files
load rejection_case_helper

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  SCRIPT="$REPO_ROOT/scripts/tmux-preflight.sh"
  TEST_ROOT="$(mktemp -d)"
  PROJECT_ROOT="$TEST_ROOT/project"
  CONTROL_ROOT="$PROJECT_ROOT/.meridian"
  BIN_DIR="$TEST_ROOT/bin"
  mkdir -p "$CONTROL_ROOT" "$BIN_DIR"
  printf '%s\n' '{}' > "$CONTROL_ROOT/config.json"
  cat > "$BIN_DIR/tmux" <<'SCRIPT'
#!/usr/bin/env bash
[ "$1" = '-V' ] && { printf '%s\n' 'tmux 3.5'; exit 0; }
[ "$1" = 'has-session' ] && exit 1
exit 1
SCRIPT
  cat > "$BIN_DIR/claude" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
  chmod +x "$BIN_DIR/tmux" "$BIN_DIR/claude"
}

teardown() {
  rm -rf "$TEST_ROOT"
}

run_preflight() {
  run env -u TMUX -u TMUX_PANE PATH="$BIN_DIR:$PATH" bash "$SCRIPT" --project-root "$PROJECT_ROOT" --control-root "$CONTROL_ROOT" --main-id main-session
}

@test "preflight probes the runtime parent and never leaves runtime state behind" {
  reset_case_failures

  run_preflight
  expect_case probe-succeeds 0 ""
  expect_no_path probe-succeeds-leaves-no-runtime "$CONTROL_ROOT/.runtime"

  cat > "$BIN_DIR/python3" <<'SCRIPT'
#!/usr/bin/env bash
exit 1
SCRIPT
  chmod +x "$BIN_DIR/python3"
  run_preflight
  expect_rejected probe-fails ""
  expect_no_path probe-fails-removes-created-parent "$CONTROL_ROOT/.runtime"

  assert_no_case_failures
}
