#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  COMMAND="$REPO_ROOT/commands/import.md"
}

@test "import command resolves plugin and project roots in one self-contained directive" {
  run grep -c '^!`' "$COMMAND"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
  grep -F 'scripts/resolve-plugin-root.sh' "$COMMAND" >/dev/null
  grep -F 'lbwc-target-root.sh' "$COMMAND" >/dev/null
  grep -F '{LINK}/scripts/plan-import.sh' "$COMMAND" >/dev/null
  grep -F '{PROJECT_ROOT}' "$COMMAND" >/dev/null
}
