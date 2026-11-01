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
  BOOT="$SCRIPTS_DIR/bootstrap/bootstrap-claude.sh"
  REFRESH="$SCRIPTS_DIR/refresh-claude-md-lbwc-sections.sh"
  ALL_SECTIONS=$'## Active Context\n## LBWC Rules\n## Code Intelligence\n## Plugin Isolation'
  reset_case_failures
}

teardown() {
  await_git_ai
}

merge_existing() {
  run bash "$BOOT" "$1/CLAUDE.md" "Other" "Other value" "$1/CLAUDE.md"
}

write_decisions_claude_md() {
  write_text "$1/CLAUDE.md" "# App" "" "## Key Decisions" "" \
    "| Decision | Rationale |" "|----------|-----------|" \
    "| Use Postgres | Mature |" "| Use REST | Simple |" "" \
    "## Notes" "" "user notes"
}

@test "bootstrap-claude validates arguments and writes a new CLAUDE.md with every LBWC section" {
  local out="$WORK/new/CLAUDE.md"

  run bash "$BOOT" "$out" "App"
  expect_case "too-few-arguments" 1 "Usage: bootstrap-claude.sh"
  expect_no_path "too-few-arguments-writes-nothing" "$WORK/new"

  run bash "$BOOT" "$out" "" "Fast feedback"
  expect_status "empty-project-name" 1
  expect_no_path "empty-project-name-writes-nothing" "$WORK/new"

  run bash "$BOOT" "$out" "App" "Fast feedback"
  expect_case_silent "fresh-file" 0
  expect_exact_line "fresh-title" "$out" "# App"
  expect_exact_line "fresh-core-value" "$out" "**Core value:** Fast feedback"
  expect_headings "fresh-sections-in-order" "$out" "$ALL_SECTIONS"

  write_text "$WORK/empty/CLAUDE.md" ""
  bash "$REFRESH" "$WORK/empty/CLAUDE.md"
  tail -n +5 "$out" > "$WORK/fresh-sections.md"
  expect_file_equals "fresh-sections-match-refresh" "$WORK/fresh-sections.md" "$(cat "$WORK/empty/CLAUDE.md")"

  assert_no_case_failures
}

@test "bootstrap-claude keeps user content and replaces managed sections in an existing CLAUDE.md" {
  write_text "$WORK/strong/CLAUDE.md" "# My App" "" "Intro line." "" \
    "## Active Context" "" "stale context line" "" "## Build" "" "make build" "" \
    "## Codebase Intelligence" "" "gsd stuff" "" "## Context" "" "soft gsd context" "" \
    "## LBWC Rules" "" "old rule"
  merge_existing "$WORK/strong"
  expect_case_silent "strong-gsd" 0
  expect_exact_line "strong-keeps-title" "$WORK/strong/CLAUDE.md" "# My App"
  expect_exact_line "strong-keeps-intro" "$WORK/strong/CLAUDE.md" "Intro line."
  expect_exact_line "strong-keeps-user-section-body" "$WORK/strong/CLAUDE.md" "make build"
  expect_no_exact_line "strong-ignores-project-name" "$WORK/strong/CLAUDE.md" "# Other"
  expect_headings "strong-user-then-managed" "$WORK/strong/CLAUDE.md" "## Build"$'\n'"$ALL_SECTIONS"
  expect_no_file_line "strong-drops-stale-context" "$WORK/strong/CLAUDE.md" "stale context line"
  expect_no_file_line "strong-drops-gsd-body" "$WORK/strong/CLAUDE.md" "gsd stuff"
  expect_no_file_line "strong-drops-soft-gsd-body" "$WORK/strong/CLAUDE.md" "soft gsd context"
  expect_no_file_line "strong-drops-old-rule" "$WORK/strong/CLAUDE.md" "old rule"

  write_text "$WORK/soft/CLAUDE.md" "# App" "" "## Context" "" "user context"
  merge_existing "$WORK/soft"
  expect_case_silent "soft-only" 0
  expect_headings "soft-only-keeps-context-heading" "$WORK/soft/CLAUDE.md" "## Context"$'\n'"$ALL_SECTIONS"
  expect_exact_line "soft-only-keeps-context-body" "$WORK/soft/CLAUDE.md" "user context"

  write_text "$WORK/variant/CLAUDE.md" "# App" "" "### Active Context" "" "custom context" "" \
    "Prefer LSP over grep for lookups."
  merge_existing "$WORK/variant"
  expect_case_silent "variant-headings" 0
  expect_no_exact_line "variant-prose-replaces-code-intelligence" "$WORK/variant/CLAUDE.md" "## Code Intelligence"
  expect_exact_line "variant-keeps-custom-heading" "$WORK/variant/CLAUDE.md" "### Active Context"
  expect_exact_line "variant-keeps-custom-context" "$WORK/variant/CLAUDE.md" "custom context"

  write_text "$WORK/managed-only/CLAUDE.md" "## Active Context" "" "old"
  merge_existing "$WORK/managed-only"
  expect_case_silent "managed-only" 0
  head -n 1 "$WORK/managed-only/CLAUDE.md" > "$WORK/managed-only-first-line"
  expect_file_equals "managed-only-starts-with-sections" "$WORK/managed-only-first-line" "## Active Context"
  expect_no_exact_line "managed-only-drops-old-body" "$WORK/managed-only/CLAUDE.md" "old"

  assert_no_case_failures
}

@test "bootstrap-claude moves Key Decisions rows into STATE.md and archives leftover notes" {
  write_decisions_claude_md "$WORK/boundary"
  printf '%s\n' "Note kept for later." "" >> "$WORK/boundary/CLAUDE.md"
  write_text "$WORK/boundary/.lbwc-planning/STATE.md" "# State" "" "## Key Decisions" "" \
    "| Decision | Rationale |" "|----------|-----------|" "| Use REST | Simple |" "" "## Todos" "" "- none"
  merge_existing "$WORK/boundary"
  expect_status "boundary" 0
  expect_file_equals "boundary-rows-before-next-section" "$WORK/boundary/.lbwc-planning/STATE.md" \
    "$(printf '%s\n' "# State" "" "## Key Decisions" "" "| Decision | Rationale |" "|----------|-----------|" \
      "| Use REST | Simple |" "| Use Postgres | Mature |" "" "## Todos" "" "- none")"
  expect_no_exact_line "boundary-removes-row" "$WORK/boundary/CLAUDE.md" "| Use Postgres | Mature |"
  expect_no_exact_line "boundary-removes-heading" "$WORK/boundary/CLAUDE.md" "## Key Decisions"
  expect_exact_line "boundary-archives-note" "$WORK/boundary/CLAUDE.md" "Note kept for later."
  expect_exact_line "boundary-keeps-user-notes" "$WORK/boundary/CLAUDE.md" "user notes"

  write_decisions_claude_md "$WORK/at-end"
  write_text "$WORK/at-end/.lbwc-planning/STATE.md" "# State" "" "## Key Decisions" "" \
    "| Decision | Rationale |" "|----------|-----------|"
  merge_existing "$WORK/at-end"
  expect_status "at-end" 0
  expect_file_equals "at-end-rows-appended" "$WORK/at-end/.lbwc-planning/STATE.md" \
    "$(printf '%s\n' "# State" "" "## Key Decisions" "" "| Decision | Rationale |" "|----------|-----------|" \
      "| Use Postgres | Mature |" "| Use REST | Simple |")"

  write_decisions_claude_md "$WORK/duplicates"
  write_text "$WORK/duplicates/.lbwc-planning/STATE.md" "## Key Decisions" "" \
    "| Decision | Rationale |" "|---|---|" "| Use  Postgres |  Mature |" "| Use REST | Simple |"
  local before
  before=$(file_digest "$WORK/duplicates/.lbwc-planning/STATE.md")
  merge_existing "$WORK/duplicates"
  expect_status "duplicates" 0
  expect_same_digest "duplicates-leave-state-alone" "$WORK/duplicates/.lbwc-planning/STATE.md" "$before"
  expect_no_file_line "duplicates-drop-section" "$WORK/duplicates/CLAUDE.md" "Key Decisions"

  write_text "$WORK/template/CLAUDE.md" "# App" "" "## Key Decisions" "" \
    "| Decision | Rationale |" "|---|---|" "" "## Notes" "" "n"
  merge_existing "$WORK/template"
  expect_case_silent "empty-template" 0
  expect_no_file_line "empty-template-dropped" "$WORK/template/CLAUDE.md" "Key Decisions"

  write_text "$WORK/skills/CLAUDE.md" "# App" "" "## Installed Skills" "" "- skill-a" "- skill-b"
  merge_existing "$WORK/skills"
  expect_case_silent "installed-skills" 0
  expect_no_exact_line "installed-skills-heading-retired" "$WORK/skills/CLAUDE.md" "## Installed Skills"
  expect_exact_line "installed-skills-notes-archived" "$WORK/skills/CLAUDE.md" "- skill-b"

  assert_no_case_failures
}

@test "bootstrap-claude keeps the Key Decisions section when STATE.md cannot take its rows" {
  local before
  write_decisions_claude_md "$WORK/no-state"
  merge_existing "$WORK/no-state"
  expect_status "no-state" 0
  expect_output_nonempty "no-state-warns"
  expect_exact_line "no-state-keeps-heading" "$WORK/no-state/CLAUDE.md" "## Key Decisions"
  expect_exact_line "no-state-keeps-row" "$WORK/no-state/CLAUDE.md" "| Use Postgres | Mature |"

  write_decisions_claude_md "$WORK/no-section"
  write_text "$WORK/no-section/.lbwc-planning/STATE.md" "# State" "" "## Todos"
  before=$(file_digest "$WORK/no-section/.lbwc-planning/STATE.md")
  merge_existing "$WORK/no-section"
  expect_status "no-section" 0
  expect_output_nonempty "no-section-warns"
  expect_same_digest "no-section-state-untouched" "$WORK/no-section/.lbwc-planning/STATE.md" "$before"
  expect_exact_line "no-section-keeps-row" "$WORK/no-section/CLAUDE.md" "| Use REST | Simple |"

  write_decisions_claude_md "$WORK/no-table"
  write_text "$WORK/no-table/.lbwc-planning/STATE.md" "# State" "" "## Key Decisions" "" "_(No decisions yet)_"
  before=$(file_digest "$WORK/no-table/.lbwc-planning/STATE.md")
  merge_existing "$WORK/no-table"
  expect_status "no-table" 0
  expect_output_nonempty "no-table-warns"
  expect_same_digest "no-table-state-untouched" "$WORK/no-table/.lbwc-planning/STATE.md" "$before"
  expect_exact_line "no-table-keeps-heading" "$WORK/no-table/CLAUDE.md" "## Key Decisions"

  assert_no_case_failures
}
