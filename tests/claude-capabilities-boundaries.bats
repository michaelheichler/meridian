#!/usr/bin/env bats

load capability_helper

setup() {
  setup_capability_sandbox
  BINARY="$TEST_ROOT/claude"
  make_claude_fixture "$BINARY"
}

teardown() {
  teardown_capability_sandbox
}

@test "refresh rejects traversal components before path normalization" {
  local traversal="$TEST_ROOT/project/unused/../.lbwc-planning"
  mkdir -p "$TEST_ROOT/project/unused"

  run env CLAUDE_CODE_EXECPATH="$BINARY" bash "$SCRIPT" refresh "$traversal"

  [ "$status" -ne 0 ]
  [[ "$output" == *"traversal"* ]]
  [ ! -e "$CATALOG" ]
}

@test "refresh rejects a symlink at the state directory boundary without writing its target" {
  while IFS='|' read -r label link_name; do
    [ -n "$label" ] || continue
    local external="$TEST_ROOT/external-$label" link="$TEST_ROOT/$link_name"
    mkdir -p "$external" "$(dirname "$link")"
    ln -s "$external" "$link"

    run env CLAUDE_CODE_EXECPATH="$BINARY" bash "$SCRIPT" refresh "$link" </dev/null

    [ "$status" -ne 0 ] || { case_fail "$label" "refresh accepted $link"; return 1; }
    [[ "$output" == *"state directory boundary must not be a symbolic link"* ]] \
      || { case_fail "$label" "missing boundary message"; return 1; }
    [ ! -e "$external/claude-capabilities.json" ] \
      || { case_fail "$label" "wrote through the link into $external"; return 1; }
  done <<'CASES'
named-planning-link|linked-project/.lbwc-planning
arbitrary-name-link|linked-planning
CASES
}

@test "refresh accepts the macOS var ancestor symlink" {
  local logical_planning
  printf '%s' "$PLANNING_DIR" | grep -q '^/private/var' || skip 'temporary directory is not under /private/var'
  logical_planning=$(printf '%s' "$PLANNING_DIR" | sed 's|^/private||')

  run env CLAUDE_CODE_EXECPATH="$BINARY" bash "$SCRIPT" refresh "$logical_planning"

  [ "$status" -eq 0 ]
  [ -f "$CATALOG" ]
}

@test "refresh rejects a symlinked catalog without changing its target" {
  local external="$TEST_ROOT/external.json" before after
  printf '%s\n' 'external sentinel' > "$external"
  ln -s "$external" "$CATALOG"
  before=$(file_sha "$external")

  run env CLAUDE_CODE_EXECPATH="$BINARY" bash "$SCRIPT" refresh "$PLANNING_DIR"

  [ "$status" -ne 0 ]
  [[ "$output" == *"symbolic link"* ]]
  after=$(file_sha "$external")
  [ "$before" = "$after" ]
}

@test "an explicit executable path beats PATH discovery and records its physical target" {
  local physical="$TEST_ROOT/physical/claude" link="$TEST_ROOT/bin/claude"
  local fallback="$TEST_ROOT/fallback/claude" fallback_marker="$TEST_ROOT/fallback-used"
  make_claude_fixture "$physical"
  mkdir -p "$(dirname "$link")"
  ln -s "$physical" "$link"
  write_claude_fixture \
    "$fallback" \
    '1.0.0 (Fallback Fixture)' \
    'fallback-only' \
    '[{id:"claude-fallback",family:"fallback",display_name:"Fallback"}]' \
    '' \
    '' \
    "$fallback_marker"

  run env PATH="$(dirname "$fallback"):$PATH" CLAUDE_CODE_EXECPATH="$link" bash "$SCRIPT" refresh "$PLANNING_DIR"

  [ "$status" -eq 0 ]
  run jq -e --arg physical "$(realpath "$physical")" '.source.binary_path == $physical' "$CATALOG"
  [ "$status" -eq 0 ]
  [ ! -e "$fallback_marker" ]
}
