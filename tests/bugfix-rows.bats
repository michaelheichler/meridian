#!/usr/bin/env bats

load test_helper
load gate_case_helper
load gate_case_files
load text_case_helper

setup() {
  setup_temp_dir
  REPO="$TEST_TEMP_DIR/repo"
  setup_unrelated_git_repo "$REPO"
  cd "$REPO" || return 1
  FIX_SCRIPTS="${BUGFIX_SCRIPTS_DIR:-$SCRIPTS_DIR}"
  reset_case_failures
}

teardown() {
  await_git_ai
  cd "$PROJECT_ROOT" || return 1
  teardown_temp_dir
}

scan_heading() {
  /bin/bash -c '. "$1/lib/claude-md-lbwc-sections.sh"; lbwc_markdown_has_heading_title "$2" "$3"' _ "$FIX_SCRIPTS" "$REPO/input.md" "$1"
}

heading_row() {
  local label="$1" want="$2"
  shift 2
  printf '%s\n' "$@" > "$REPO/input.md"
  run scan_heading "Team Notes"
  expect_case "$label" "$want"
}

@test "markdown recognizes valid heading depths but ignores malformed headings" {
  heading_row level-two 0 '## Team Notes'
  heading_row level-three 0 '### Team Notes'
  heading_row level-four 0 '#### Team Notes'
  heading_row level-five 0 '##### Team Notes'
  heading_row level-six 0 '###### Team Notes'
  heading_row too-deep 1 '####### Team Notes'
  printf '%s\n' '#NoSpace' > "$REPO/input.md"
  run scan_heading NoSpace
  expect_case no-space 1
  assert_no_case_failures
}

@test "markdown keeps short or mismatched fences inside the active code example" {
  heading_row shorter-backticks-stay-fenced 1 '````md' '```' '## Team Notes' '````'
  heading_row tilde-does-not-close-backticks 1 '```md' '~~~' '## Team Notes' '```'
  heading_row backticks-do-not-close-tilde 1 '~~~md' '```' '## Team Notes' '~~~'
  heading_row longer-fence-closes 0 '```md' 'example' '````' '## Team Notes'
  heading_row ordinary-fence-closes 0 '~~~md' 'example' '~~~' '## Team Notes'
  assert_no_case_failures
}

@test "staleness repair clears warnings when user examples contain shorter fences" {
  mkdir -p .lbwc-planning
  printf '%s\n' '# App' '## Examples' '````md' '```' '## LBWC Rules' '````' > CLAUDE.md
  run bash "$FIX_SCRIPTS/check-claude-md-staleness.sh" --fix
  expect_case repaired 0
  run bash "$FIX_SCRIPTS/check-claude-md-staleness.sh" --json
  expect_case repaired-check 0
  expect_jq_output repaired-check '.stale == false'
  assert_no_case_failures
}

@test "bootstrap preserves fenced managed headings and the following user text" {
  local example=$'## Examples\n````md\n## Active Context\n```\nexample body\n````\nafter example'
  printf '# App\n%s\n' "$example" > CLAUDE.md
  run bash "$FIX_SCRIPTS/bootstrap/bootstrap-claude.sh" "$REPO/CLAUDE.md" App Value "$REPO/CLAUDE.md"
  expect_case fenced-example 0
  run cat CLAUDE.md
  expect_case fenced-example-preserved 0 "$example"
  expect_case normal-generated-section 0 '## Plugin Isolation'
  assert_no_case_failures
}

@test "hook installation replaces a plugin symlink without modifying its target" {
  local target before hook="$REPO/.git/hooks/pre-push"
  mkdir -p "$TEST_TEMP_DIR/plugin"
  cp -R "$FIX_SCRIPTS" "$TEST_TEMP_DIR/plugin/scripts"
  target="$TEST_TEMP_DIR/plugin/scripts/pre-push-hook.sh"
  before=$(file_digest "$target")
  ln -s "$target" "$hook"
  run /bin/bash "$TEST_TEMP_DIR/plugin/scripts/install-hooks.sh"
  expect_case upgrade 0
  expect_same_digest plugin-unchanged "$target" "$before"
  [ ! -L "$hook" ] || record_case_failure regular-hook 'hook remains a symlink'
  [ -f "$hook" ] && [ -x "$hook" ] || record_case_failure executable-hook 'hook is not a regular executable'
  assert_no_case_failures
}

@test "cache cleanup removes owned directories files and dangling links but preserves other users" {
  local root="$TEST_TEMP_DIR/cache" own other
  own=$(id -u)
  other=$((own + 1))
  mkdir -p "$root/lbwc-dir-$own" "$root/lbwc-dir-$other"
  printf payload > "$root/lbwc-dir-$own/entry"
  touch "$root/lbwc-file-$own"
  ln -s "$root/missing" "$root/lbwc-link-$own"
  run env LBWC_TMP_CACHE_ROOT="$root" CLAUDE_CONFIG_DIR="$TEST_TEMP_DIR/config" bash "$FIX_SCRIPTS/cache-nuke.sh"
  expect_case cleanup 0
  expect_jq_output cleanup '.wiped.temp_caches == true'
  expect_no_path owned-directory "$root/lbwc-dir-$own"
  expect_no_path owned-file "$root/lbwc-file-$own"
  [ ! -L "$root/lbwc-link-$own" ] || record_case_failure dangling-link 'link remains'
  expect_path other-user "$root/lbwc-dir-$other"
  run env LBWC_TMP_CACHE_ROOT="$root" CLAUDE_CONFIG_DIR="$TEST_TEMP_DIR/config" bash "$FIX_SCRIPTS/cache-nuke.sh"
  expect_case empty-cleanup 0
  expect_jq_output empty-cleanup '.wiped.temp_caches == false'
  assert_no_case_failures
}

verification_row() {
  local shape="$1"
  mkdir -p .lbwc-planning/phases/01-check
  cp "$BATS_TEST_DIRNAME/fixtures/bugfix-verification-$shape.md" .lbwc-planning/phases/01-check/01-VERIFICATION.md
  run bash "$FIX_SCRIPTS/extract-verified-items.sh" "$REPO/.lbwc-planning/phases/01-check"
  expect_case "$shape" 0 '  PASS MH-01: Login works'
}

@test "verification reads the status header independently of table width and emphasis" {
  verification_row six
  verification_row seven
  verification_row emphasis
  assert_no_case_failures
}

enrichment_row() {
  local label="$1" query="$2"
  run bash "$FIX_SCRIPTS/debug-skill-enrichment.sh" "$query"
  expect_case "$label" 0
  expect_jq_output "$label" '.tokens == ["TodoStore"] and .matched_files == ["TodoStore.swift"]'
}

@test "enrichment resolves concrete symbols despite trailing prose punctuation" {
  printf 'final class TodoStore {}\n' > TodoStore.swift
  git add TodoStore.swift
  git commit -qm fixture
  await_git_ai
  enrichment_row backtick 'TodoStore`'
  enrichment_row double-quote 'TodoStore"'
  enrichment_row single-quote "TodoStore'"
  enrichment_row comma 'TodoStore,'
  enrichment_row period 'TodoStore.'
  enrichment_row bracket 'TodoStore]'
  enrichment_row parenthesis 'TodoStore)'
  enrichment_row normal 'TodoStore'
  assert_no_case_failures
}

@test "fresh debug context omits placeholder QA and UAT history" {
  cp "$PROJECT_ROOT/templates/DEBUG-SESSION.md" session.md
  run bash "$FIX_SCRIPTS/compile-debug-session-context.sh" session.md qa
  expect_case fresh-qa 0
  expect_case_absent fresh-qa '## Prior QA Rounds'
  run bash "$FIX_SCRIPTS/compile-debug-session-context.sh" session.md uat
  expect_case fresh-uat 0
  expect_case_absent fresh-uat '## QA Details'
  expect_case_absent fresh-uat '## Prior UAT Rounds'
  assert_no_case_failures
}

@test "debug context trims section edges while preserving paragraph breaks" {
  printf '## Issue\n\n\nfirst paragraph\n\nsecond paragraph\n\n\n## Source Todo\n' > session.md
  run bash "$FIX_SCRIPTS/compile-debug-session-context.sh" session.md qa
  expect_case paragraphs 0 $'## Issue Summary\n\nfirst paragraph\n\nsecond paragraph\n\n## Source Todo'
  assert_no_case_failures
}

workflow_row() {
  local label="$1" reason="$2"
  run bash "$FIX_SCRIPTS/delegated-workflow.sh" status-json
  expect_case "$label" 0
  expect_jq_output "$label" ".reason == \"$reason\""
}

@test "workflow rejects future timestamps as stale and reports their negative age" {
  mkdir -p .lbwc-planning
  printf '%s\n' '{"active":true,"mode":"debug"}' > .lbwc-planning/.delegated-workflow.json
  touch -t 203501010000 .lbwc-planning/.delegated-workflow.json
  workflow_row future-marker stale_marker
  expect_jq_output negative-marker-age '(.marker_age_seconds | tonumber) < 0'
  printf '%s\n' '{"active":true,"mode":"execute","correlation_id":"c1"}' > .lbwc-planning/.delegated-workflow.json
  touch .lbwc-planning/.delegated-workflow.json
  printf '%s\n' '{"status":"running","correlation_id":"c1"}' > .lbwc-planning/.execution-state.json
  touch -t 203501010000 .lbwc-planning/.execution-state.json
  workflow_row future-execution stale_execution_state
  expect_jq_output negative-execution-age '(.execution_age_seconds | tonumber) < 0'
  touch .lbwc-planning/.execution-state.json
  workflow_row fresh-execution ok
  expect_jq_output fresh-execution '.live == true'
  assert_no_case_failures
}
