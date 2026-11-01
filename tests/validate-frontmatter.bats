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
  VALIDATE="$SCRIPTS_DIR/validate-frontmatter.sh"
  reset_case_failures
}

teardown() {
  await_git_ai
}

check_doc() {
  FILE="$WORK/$1"
  shift
  [ "$#" -eq 0 ] || write_text "$FILE" "$@"
  run bash "$VALIDATE" <<< "{\"tool_input\": {\"file_path\": \"$FILE\"}}"
}

expect_warning() {
  local label=$1 fragment=$2
  expect_status "$label" 0
  expect_jq_output "$label-context" \
    ".hookSpecificOutput.hookEventName == \"PostToolUse\" and (.hookSpecificOutput.additionalContext | contains(\"$FILE\") and contains(\"$fragment\"))"
}

@test "validate-frontmatter warns only about empty or multi-line descriptions" {
  run bash "$VALIDATE" < /dev/null
  expect_case_silent "empty-input" 0

  check_doc notes.txt "---" "description: |" "  multi" "---"
  expect_case_silent "not-markdown" 0
  check_doc absent.md
  expect_case_silent "missing-file" 0
  check_doc plain.md "# Title" "description: |"
  expect_case_silent "no-frontmatter" 0
  check_doc bare.md "---" "---"
  expect_case_silent "empty-frontmatter" 0
  check_doc nodesc.md "---" "name: x" "---"
  expect_case_silent "no-description" 0
  check_doc single.md "---" "description: Does one thing" "name: x" "---"
  expect_case_silent "single-line" 0

  check_doc literal.md "---" "description: |" "  first" "  second" "---"
  expect_warning "literal-block" "single line"
  check_doc folded.md "---" "description: >-" "  first" "---"
  expect_warning "folded-block" "single line"
  check_doc indented.md "---" "description:" "  continued text" "---"
  expect_warning "empty-key-with-continuation" "single line"
  check_doc wrapped.md "---" "description: starts here" "  and wraps" "---"
  expect_warning "value-with-continuation" "single line"
  check_doc empty.md "---" "description:" "name: x" "---"
  expect_warning "empty-description" "empty"

  assert_no_case_failures
}
