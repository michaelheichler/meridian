#!/usr/bin/env bats

load test_helper
load todo_helper

setup() {
  setup_temp_dir
  create_test_config
  cd "$TEST_TEMP_DIR"
}

teardown() {
  teardown_temp_dir
}

create_state_with_todos() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'EOF'
# LBWC State

**Project:** Test
**Status:** Active

## Todos
- Fix bug in parser (added 2026-01-15)
- [HIGH] Refactor auth module (added 2026-02-01)
- [low] Update docs (added 2026-02-10)

## Recent Activity
- 2026-02-10: Updated docs
EOF
}

build_layout() {
  rm -rf .lbwc-planning state-source
  mkdir -p .lbwc-planning
  case "$1" in
    archived-milestone)
      create_state_with_todos ".lbwc-planning/milestones/default/STATE.md"
      ;;
    milestones-without-state)
      mkdir -p .lbwc-planning/milestones
      ;;
    symlinked-root)
      create_state_with_todos "state-source/STATE.md"
      ln -s "$TEST_TEMP_DIR/state-source/STATE.md" .lbwc-planning/STATE.md
      ;;
  esac
}

@test "lists root todos with count and stable mutation metadata" {
  create_state_with_todos ".lbwc-planning/STATE.md"

  run bash "$SCRIPTS_DIR/list-todos.sh"
  expect_status root 0

  expect_json root '.count' 3
  expect_json root '.items[0].section_index' 1
  expect_json root '.items[1].section_index' 2
  expect_json root '.items[0].normalized_text' "Fix bug in parser"
  expect_json root '.items[1].display_identity' "[HIGH] Refactor auth module"
  expect_json root '.items[1].command_text' "Refactor auth module"
  expect_json root '.items[1].section' "## Todos"
  expect_json root '.items[0].identity_occurrence' 1
  expect_json root '.items[0].identity_total' 1
}

@test "list-todos errors unless a writable root STATE.md exists and leaves other state untouched" {
  while IFS='|' read -r label layout filter message; do
    [ -n "$label" ] || continue
    build_layout "$layout"
    run bash "$SCRIPTS_DIR/list-todos.sh" $filter
    expect_status "$label" 0
    expect_json "$label" '.status' error
    expect_json_unless_dash "$label" '.message | contains("'"$message"'")' true
    [ ! -f .lbwc-planning/milestones/default/STATE.md ] || expect_file_has "$label" .lbwc-planning/milestones/default/STATE.md "Refactor auth module"
  done <<'CASES'
archived-milestone-without-root|archived-milestone||Writable root STATE.md not found
no-state-anywhere|milestones-without-state||-
filtered-request-without-root|archived-milestone|high|-
symlinked-root|symlinked-root||-
CASES
}
