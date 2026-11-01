#!/usr/bin/env bats

load test_helper
load gate_case_helper
load gate_case_files
load text_case_helper

setup() {
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK" "$BATS_TEST_TMPDIR/home"
  export HOME="$BATS_TEST_TMPDIR/home"
  git init -q "$WORK"
  cd "$WORK"
  REFRESH="$SCRIPTS_DIR/refresh-claude-md-lbwc-sections.sh"
  reset_case_failures
}

teardown() {
  await_git_ai
}

@test "refresh-claude-md-lbwc-sections rewrites only LBWC-owned sections" {
  local file before

  run bash "$REFRESH"
  expect_case "no-argument" 1 "Usage: refresh-claude-md-lbwc-sections.sh"
  run bash "$REFRESH" "$WORK/a.md" "$WORK/b.md"
  expect_case "two-arguments" 1 "Usage: refresh-claude-md-lbwc-sections.sh"
  run bash "$REFRESH" "$WORK/absent.md"
  expect_status "missing-file" 1
  expect_no_path "missing-file-not-created" "$WORK/absent.md"

  file="$WORK/blank.md"
  write_text "$file" "" "   " ""
  run bash "$REFRESH" "$file"
  expect_case_silent "blank-file" 0
  head -n 1 "$file" > "$WORK/blank-first-line"
  expect_file_equals "blank-file-starts-with-sections" "$WORK/blank-first-line" "## Active Context"

  file="$WORK/legacy.md"
  write_text "$file" "# App" "" \
    "## State" "" 'Planning directory: `.lbwc-planning/`' "" \
    "## Project Conventions" "" "None yet. Run /lbwc:teach to add project conventions." "" \
    "## Commands" "" "Run /lbwc:status for current progress." "Run /lbwc:help for all available commands." "" \
    "## Active Context" "" "old context" "" \
    "## Deploy" "" "ship it" '````md' "## LBWC Rules" '```' "still fenced" '````' "" \
    "## Runbook" "" "Run /lbwc:status for current progress." "" \
    "## Team State" "" "our state machine"
  run bash "$REFRESH" "$file"
  expect_case_silent "legacy" 0
  expect_headings "legacy-strips-generated-sections" "$file" \
    $'## Deploy\n## LBWC Rules\n## Runbook\n## Team State\n## Active Context\n## LBWC Rules\n## Code Intelligence\n## Plugin Isolation'
  expect_exact_line "legacy-keeps-title" "$file" "# App"
  expect_exact_line "legacy-keeps-fence-body" "$file" "still fenced"
  expect_exact_line "legacy-keeps-user-runbook" "$file" "Run /lbwc:status for current progress."
  expect_no_exact_line "legacy-drops-old-context" "$file" "old context"
  expect_no_file_line "legacy-drops-planning-state" "$file" "Planning directory"
  expect_no_file_line "legacy-drops-convention-template" "$file" "None yet"

  before=$(file_digest "$file")
  run bash "$REFRESH" "$file"
  expect_case_silent "second-run" 0
  expect_same_digest "second-run-is-idempotent" "$file" "$before"

  file="$WORK/owned.md"
  write_text "$file" "# App" "" "## Code Intelligence" "" "old tools" "" "## Plugin Isolation" "" "old isolation"
  run bash "$REFRESH" "$file"
  expect_case_silent "owned-sections" 0
  expect_line_count "owned-code-intelligence-once" "$file" "## Code Intelligence" 1
  expect_no_exact_line "owned-old-body-replaced" "$file" "old tools"
  expect_no_exact_line "owned-old-isolation-replaced" "$file" "old isolation"

  file="$WORK/variant.md"
  write_text "$file" "# App" "" "### LBWC Rules" "" "custom rules" "" "Prefer LSP over grep for lookups."
  run bash "$REFRESH" "$file"
  expect_case_silent "variant-titles" 0
  expect_no_exact_line "variant-prose-replaces-code-intelligence" "$file" "## Code Intelligence"
  expect_exact_line "variant-keeps-custom-rules" "$file" "custom rules"

  assert_no_case_failures
}
