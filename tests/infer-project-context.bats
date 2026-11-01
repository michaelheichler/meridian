#!/usr/bin/env bats

load test_helper
load gate_case_helper
load gate_case_files

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/infer-project-context.sh"
  TEST_ROOT="$(mktemp -d)"
  MAP_DIR="$TEST_ROOT/codebase"
  TEST_REPO="$TEST_ROOT/repo"
  mkdir -p "$MAP_DIR" "$TEST_REPO"
  reset_case_failures
}

teardown() {
  await_git_ai
  rm -rf "$TEST_ROOT"
}

write_stack() {
  local heading="$1" purpose="$2"
  printf '%s\n' \
    '# Stack' \
    '' \
    "## $heading" \
    '' \
    "$purpose" \
    '' \
    'This second paragraph is outside the inferred purpose.' \
    '' \
    '## Languages' \
    '' \
    '| Language | Evidence |' \
    '| --- | --- |' \
    '| :---: | ---: |' \
    '|---|---|' \
    '| Bash | scripts and hooks |' \
    '' \
    '## Key Technologies' \
    '' \
    '- **jq**: JSON processing' \
    > "$MAP_DIR/STACK.md"
}

write_supporting_map() {
  printf '%s\n' \
    '# Architecture' \
    '' \
    '## Overview' \
    '' \
    'Markdown commands delegate work to Bash scripts.' \
    > "$MAP_DIR/ARCHITECTURE.md"
  printf '%s\n' \
    '# Codebase Map Index' \
    '' \
    '## Cross-Cutting Themes' \
    '' \
    '- **Lifecycle**: Plan, execute, and verify work.' \
    > "$MAP_DIR/INDEX.md"
}

write_concerns() {
  printf '%s\n' \
    '# DO NOT USE THIS AS PURPOSE' \
    '' \
    '## Catastrophic data loss risk' \
    '' \
    '## Credential leakage risk' \
    > "$MAP_DIR/CONCERNS.md"
}

run_infer() {
  run bash "$SCRIPT" "$MAP_DIR" "$TEST_REPO"
}

@test "infer-project-context: infers every field and the project name with source attribution, and rejects missing input" {
  local purpose="A Claude Code plugin for a plan, execute, verify workflow."
  write_stack "Purpose" "$purpose"
  write_supporting_map
  write_concerns

  run_infer
  expect_case canonical-map 0 ""
  expect_jq_output canonical-map ".purpose == {value: \"$purpose\", source: \"STACK.md: Purpose\"}"
  expect_jq_output canonical-map '(.purpose.value | contains("DO NOT USE THIS AS PURPOSE") | not)'
  expect_jq_output canonical-map '(.purpose.value | contains("Catastrophic data loss risk") | not)'
  expect_jq_output canonical-map '.tech_stack.source == "STACK.md" and .tech_stack.value == ["Bash","jq"]'
  expect_jq_output canonical-map '.architecture == {value: "Markdown commands delegate work to Bash scripts.", source: "ARCHITECTURE.md"}'
  expect_jq_output canonical-map '.features == {value: ["Lifecycle"], source: "INDEX.md"}'

  write_stack "What this repo is" "A transitional map purpose."
  run_infer
  expect_case transitional-purpose-heading 0 ""
  expect_jq_output transitional-purpose-heading '.purpose == {value: "A transitional map purpose.", source: "STACK.md: What this repo is"}'

  write_stack "Languages and tools" "No purpose exists in this map."
  run_infer
  expect_case missing-purpose-section 0 ""
  expect_jq_output missing-purpose-section '.purpose == {value: null, source: null}'

  rm -f "$MAP_DIR/STACK.md" "$MAP_DIR/ARCHITECTURE.md" "$MAP_DIR/INDEX.md"
  run_infer
  expect_case empty-map 0 ""
  expect_jq_output empty-map '.tech_stack == {value: null, source: null} and .architecture == {value: null, source: null} and .features == {value: null, source: null} and .purpose == {value: null, source: null}'

  run bash "$SCRIPT" --help
  expect_case help 0 "Usage: infer-project-context.sh CODEBASE_DIR [REPO_ROOT]"

  run_infer
  expect_case directory-fallback 0 ""
  expect_jq_output directory-fallback '.name == {value: "repo", source: "directory"}'

  mkdir -p "$TEST_REPO/.claude-plugin"
  printf '%s\n' '{"name":"manifest-name"}' > "$TEST_REPO/.claude-plugin/plugin.json"
  run_infer
  expect_case plugin-json 0 ""
  expect_jq_output plugin-json '.name == {value: "manifest-name", source: "plugin.json"}'

  git -C "$TEST_REPO" init -q
  git -C "$TEST_REPO" remote add origin https://example.com/acme/widget.git
  run_infer
  expect_case origin-remote 0 ""
  expect_jq_output origin-remote '.name == {value: "widget", source: "repo"}'

  run bash "$SCRIPT"
  expect_case no-arguments 1 "CODEBASE_DIR is required"

  run bash "$SCRIPT" "$TEST_ROOT/absent"
  expect_case missing-codebase-dir 1 "CODEBASE_DIR does not exist"

  assert_no_case_failures
}
