#!/usr/bin/env bats

load capability_helper
load gate_case_helper

setup() {
  setup_capability_sandbox
  BINARY="$TEST_ROOT/claude"
  make_claude_fixture "$BINARY"
}

teardown() {
  teardown_capability_sandbox
}

refresh_with_fixture() {
  run env CLAUDE_CODE_EXECPATH="$BINARY" bash "$SCRIPT" refresh "$1" </dev/null
}

expect_refresh_refused() {
  local label=$1 fragment=$2
  [ "$status" -ne 0 ] || record_case_failure "$label" "refresh accepted the path output=$output"
  [[ "$output" == *"$fragment"* ]] || record_case_failure "$label" "missing fragment=[$fragment] output=$output"
}

@test "refresh refuses traversal, symlinked state directories and a symlinked catalog without writing through them" {
  local traversal="$TEST_ROOT/project/unused/../.lbwc-planning" label link_name external link catalog_target before
  reset_case_failures

  mkdir -p "$TEST_ROOT/project/unused"
  refresh_with_fixture "$traversal"
  expect_refresh_refused traversal "traversal"
  [ ! -e "$CATALOG" ] || record_case_failure traversal "catalog was written"

  while IFS='|' read -r label link_name; do
    [ -n "$label" ] || continue
    external="$TEST_ROOT/external-$label"
    link="$TEST_ROOT/$link_name"
    mkdir -p "$external" "$(dirname "$link")"
    ln -s "$external" "$link"
    refresh_with_fixture "$link"
    expect_refresh_refused "$label" "state directory boundary must not be a symbolic link"
    [ ! -e "$external/claude-capabilities.json" ] \
      || record_case_failure "$label" "wrote through the link into $external"
  done <<'CASES'
named-planning-link|linked-project/.lbwc-planning
arbitrary-name-link|linked-planning
CASES

  catalog_target="$TEST_ROOT/external.json"
  printf '%s\n' 'external sentinel' > "$catalog_target"
  ln -s "$catalog_target" "$CATALOG"
  before=$(file_sha "$catalog_target")
  refresh_with_fixture "$PLANNING_DIR"
  expect_refresh_refused symlinked-catalog "symbolic link"
  [ "$(file_sha "$catalog_target")" = "$before" ] \
    || record_case_failure symlinked-catalog "catalog target changed"

  assert_no_case_failures
}

@test "refresh accepts the macOS var ancestor symlink" {
  local logical_planning
  printf '%s' "$PLANNING_DIR" | grep -q '^/private/var' || skip 'temporary directory is not under /private/var'
  logical_planning=$(printf '%s' "$PLANNING_DIR" | sed 's|^/private||')

  run env CLAUDE_CODE_EXECPATH="$BINARY" bash "$SCRIPT" refresh "$logical_planning"

  [ "$status" -eq 0 ]
  [ -f "$CATALOG" ]
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
