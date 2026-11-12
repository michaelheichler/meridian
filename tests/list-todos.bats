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
  printf '%s\n' \
    '# MERIDIAN State' \
    '' \
    '**Project:** Test' \
    '**Status:** Active' \
    '' \
    '## Todos' \
    '- Fix bug in parser (added 2026-01-15)' \
    '- [HIGH] Refactor auth module (added 2026-02-01)' \
    '- [low] Update docs (added 2026-02-10)' \
    '' \
    '## Recent Activity' \
    '- 2026-02-10: Updated docs' > "$path"
}

build_layout() {
  rm -rf .meridian state-source
  mkdir -p .meridian
  case "$1" in
    archived-milestone)
      create_state_with_todos ".meridian/milestones/default/STATE.md"
      ;;
    milestones-without-state)
      mkdir -p .meridian/milestones
      ;;
    symlinked-root)
      create_state_with_todos "state-source/STATE.md"
      ln -s "$TEST_TEMP_DIR/state-source/STATE.md" .meridian/STATE.md
      ;;
  esac
}

expect_error_message() {
  local label="$1" message="$2"
  if [ "$message" != - ]; then
    expect_json "$label" '.message | contains("'"$message"'")' true
  fi
}

@test "list-todos lists root todos with stable mutation metadata and errors unless a writable root STATE.md exists" {
  create_state_with_todos ".meridian/STATE.md"

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

  while IFS='|' read -r label layout filter message; do
    [ -n "$label" ] || continue
    build_layout "$layout"
    run bash "$SCRIPTS_DIR/list-todos.sh" $filter
    expect_status "$label" 0
    expect_json "$label" '.status' error
    expect_error_message "$label" "$message"
    [ ! -f .meridian/milestones/default/STATE.md ] || expect_file_has "$label" .meridian/milestones/default/STATE.md "Refactor auth module"
  done <<'CASES'
archived-milestone-without-root|archived-milestone||Writable root STATE.md not found
no-state-anywhere|milestones-without-state||-
filtered-request-without-root|archived-milestone|high|-
symlinked-root|symlinked-root||-
CASES
}
