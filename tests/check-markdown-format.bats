#!/usr/bin/env bats

load gate_case_helper
load gate_case_files

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CHECKER="$REPO_ROOT/scripts/check-markdown-format.sh"
  reset_case_failures
}

fresh_root() {
  local root="$BATS_TEST_TMPDIR/root-$1"
  mkdir -p "$root/commands"
  printf '%s\n' "$root"
}

@test "check-markdown-format passes clean trees, counts whitespace violations, and exits 2 on bad invocations" {
  local root label content fragment

  root=$(fresh_root clean)
  printf '%b' '---\ncategory: supporting\n---\n\n# Clean\n' > "$root/commands/clean.md"
  run bash "$CHECKER" --root "$root"
  expect_case "single-clean-file" 0 'Markdown format passed: 1 command files'

  root=$(fresh_root pair)
  printf '%b' '# One\n' > "$root/commands/one.md"
  printf '%b' '# Two\n' > "$root/commands/two.md"
  run bash "$CHECKER" --root "$root"
  expect_case "two-clean-files" 0 'Markdown format passed: 2 command files'

  root=$(fresh_root nested-ignored)
  printf '%b' '# Top\n' > "$root/commands/top.md"
  mkdir -p "$root/commands/sub"
  printf '%b' '# Bad  \n' > "$root/commands/sub/deep.md"
  run bash "$CHECKER" --root "$root"
  expect_case "subdirectory-files-not-scanned" 0 'Markdown format passed: 1 command files'

  run bash "$CHECKER" --root "$REPO_ROOT"
  expect_case "shipped-command-files" 0 'Markdown format passed:'

  while IFS='|' read -r label content fragment; do
    [ -n "$label" ] || continue
    root=$(fresh_root "$label")
    printf '%b' "$content" > "$root/commands/$label.md"
    run bash "$CHECKER" --root "$root"
    expect_case "$label" 1 "$fragment"
    expect_output_has "$label-summary" 'Markdown format failed: 1 violation(s)'
  done <<'CASES'
tabs|# Bad\n\tindented\n|commands/tabs.md:2: literal tab character
trailing|# Bad  \n|commands/trailing.md:1: trailing whitespace
crlf|# Bad\r\n|commands/crlf.md:1: CRLF line ending
no-final-newline|# Bad|commands/no-final-newline.md: missing final newline
CASES

  root=$(fresh_root multi)
  printf '%b' '# A  \n\tb\n' > "$root/commands/a.md"
  printf '%b' '# B' > "$root/commands/b.md"

  run bash "$CHECKER" --root "$root"

  expect_case "multi" 1 'Markdown format failed: 3 violation(s)'
  expect_output_has "multi-a-trailing" 'commands/a.md:1: trailing whitespace'
  expect_output_has "multi-a-tab" 'commands/a.md:2: literal tab character'
  expect_output_has "multi-b-newline" 'commands/b.md: missing final newline'

  run bash "$CHECKER" --bogus
  expect_case "unknown-flag" 2 'Usage: check-markdown-format.sh [--root PATH]'

  run bash "$CHECKER" --root
  expect_case "root-without-value" 2 'Usage: check-markdown-format.sh'

  run bash "$CHECKER" --root /a --extra
  expect_case "too-many-args" 2 'Usage: check-markdown-format.sh'

  run bash "$CHECKER" --root "$BATS_TEST_TMPDIR/absent"
  expect_case "missing-commands-dir" 2 'commands directory is unavailable'

  root=$(fresh_root empty)
  run bash "$CHECKER" --root "$root"
  expect_case "no-markdown-files" 2 'no command Markdown files found'

  assert_no_case_failures
}
