#!/usr/bin/env bats

load test_helper
load gate_case_helper
load gate_case_files
load text_case_helper

setup() {
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK" "$BATS_TEST_TMPDIR/home"
  export HOME="$BATS_TEST_TMPDIR/home"
  unset MERIDIAN_PLANNING_DIR
  CHECK="$SCRIPTS_DIR/check-claude-md-staleness.sh"
  INSTALLED=$(jq -r '.version' "$PROJECT_ROOT/.claude-plugin/plugin.json")
  reset_case_failures
}

teardown() {
  await_git_ai
}

project() {
  local dir="$WORK/$1"
  mkdir -p "$dir/.meridian"
  git init -q "$dir"
  printf '%s\n' "$dir"
}

check_in() {
  local dir=$1
  shift
  run bash -c 'CDPATH="" cd -- "$1" && shift && bash "$@"' _ "$dir" "$CHECK" "$@"
}

@test "check-claude-md-staleness reports a missing project, a missing CLAUDE.md and missing sections" {
  local dir
  dir="$WORK/plain"
  mkdir -p "$dir"
  git init -q "$dir"
  check_in "$dir"
  expect_case_silent "no-project" 0
  check_in "$dir" --json
  expect_status "no-project-json" 0
  expect_jq_output "no-project-json-body" '.stale == false and .reason == "no_project"'

  dir=$(project no-claude-md)
  check_in "$dir"
  expect_case_silent "no-claude-md" 1
  check_in "$dir" --json
  expect_status "no-claude-md-json" 1
  expect_jq_output "no-claude-md-json-body" '.stale == true and .reason == "no_claude_md"'
  check_in "$dir" --fix
  expect_status "no-claude-md-fix" 2

  dir=$(project missing)
  write_text "$dir/CLAUDE.md" "# App" "" "## Active Context" "" "Prefer LSP over grep for lookups."
  check_in "$dir"
  expect_status "missing-text" 1
  expect_output_has "missing-text-lists-rules" "- ## MERIDIAN Rules"
  expect_output_has "missing-text-lists-isolation" "- ## Plugin Isolation"
  expect_output_lacks "missing-text-prose-counts-as-code-intelligence" "## Code Intelligence"
  expect_output_has "missing-text-reports-unrecorded-version" "installed=$INSTALLED"
  check_in "$dir" --json
  expect_status "missing-json" 1
  expect_jq_output "missing-json-body" \
    '.reason == "missing_sections" and .version_mismatch == true and .marker_version == "none"
      and (.missing_sections | index("## MERIDIAN Rules") and index("## Plugin Isolation") and (index("## Code Intelligence") | not))'

  dir=$(project fenced)
  write_text "$dir/CLAUDE.md" '```' "## Active Context" "## MERIDIAN Rules" "## Code Intelligence" \
    "## Plugin Isolation" "Prefer LSP over grep" '```'
  printf '%s\n' "$INSTALLED" > "$dir/.meridian/.claude-md-version"
  check_in "$dir" --json
  expect_status "fenced-headings" 1
  expect_jq_output "fenced-headings-do-not-count" '.missing_sections | length == 4'

  assert_no_case_failures
}

@test "check-claude-md-staleness --fix refreshes MERIDIAN sections in place and records the version" {
  local dir before

  dir=$(project fix-text)
  write_text "$dir/CLAUDE.md" "# App" "" "user line"
  check_in "$dir" --fix
  expect_case "fix-text" 0 "$INSTALLED"
  expect_exact_line "fix-text-keeps-user-line" "$dir/CLAUDE.md" "user line"
  expect_headings "fix-text-adds-sections" "$dir/CLAUDE.md" \
    $'## Active Context\n## MERIDIAN Rules\n## Code Intelligence\n## Plugin Isolation'
  expect_file_equals "fix-text-records-version" "$dir/.meridian/.claude-md-version" "$INSTALLED"

  dir=$(project fix-json)
  write_text "$dir/CLAUDE.md" "# App"
  check_in "$dir" --fix --json
  expect_status "fix-json" 0
  expect_jq_output "fix-json-body" \
    ".fixed == true and .previous_marker == \"none\" and .installed_version == \"$INSTALLED\""

  dir=$(project fix-fails)
  write_text "$dir/CLAUDE.md" "# App"
  before=$(file_digest "$dir/CLAUDE.md")
  write_text "$WORK/failing-bin/mktemp" '#!/bin/sh' 'exit 1'
  chmod +x "$WORK/failing-bin/mktemp"
  PATH="$WORK/failing-bin:$PATH" check_in "$dir" --fix
  expect_status "fix-fails" 2
  expect_same_digest "fix-fails-keeps-file" "$dir/CLAUDE.md" "$before"
  expect_no_path "fix-fails-writes-no-marker" "$dir/.meridian/.claude-md-version"

  assert_no_case_failures
}
