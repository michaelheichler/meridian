#!/usr/bin/env bats

load test_helper
load gate_case_helper

setup() {
  setup_temp_dir
  PLUGIN="$TEST_TEMP_DIR/plugin"
  build_plugin
  build_planning active
  cd "$TEST_TEMP_DIR"
  git init -q
  reset_case_failures
}

teardown() {
  cd "$PROJECT_ROOT"
  await_git_ai
  teardown_temp_dir
}

sized_file() {
  local prefix="${3:-}"
  mkdir -p "$(dirname "$1")"
  { printf '%s' "$prefix"; head -c "$(( $2 - ${#prefix} ))" /dev/zero | tr '\0' 'x'; } > "$1"
}

build_plugin() {
  local rel
  for rel in references/execute-protocol.md references/handoff-schemas.md references/meridian-brand-essentials.md \
    references/verification-protocol.md references/discussion-engine.md references/effort-profile-balanced.md \
    templates/agent-roles/dev.md.tpl templates/agent-roles/qa.md.tpl templates/agent-roles/lead.md.tpl \
    templates/SUMMARY.md templates/PLAN.md templates/UAT.md; do
    sized_file "$PLUGIN/$rel" 1000
  done
  sized_file "$PLUGIN/references/effort-profile-thorough.md" 2000
  sized_file "$PLUGIN/references/effort-profile-fast.md" 3000
  sized_file "$PLUGIN/references/effort-profile-turbo.md" 4000
}

build_planning() {
  local dir="$TEST_TEMP_DIR/$1"
  sized_file "$dir/STATE.md" 1000
  sized_file "$dir/ROADMAP.md" 1000
  sized_file "$dir/REQUIREMENTS.md" 1000
  sized_file "$dir/phases/00-done/00-01-PLAN.md" 1000
  sized_file "$dir/phases/00-done/00-01-SUMMARY.md" 1000 $'---\nstatus: complete\n---\n'
  sized_file "$dir/phases/01-active/01-01-PLAN.md" 1000
  sized_file "$dir/phases/01-active/01-CONTEXT.md" 1000
  sized_file "$dir/phases/01-active/01-UAT.md" 1000
  sized_file "$dir/phases/01-active/01-SOURCE-UAT.md" 1000
}

guard() {
  local planning="$TEST_TEMP_DIR/$1" usage=$2 config=$3 sid=$4
  shift 4
  printf '%s\n' "$usage" > "$planning/.context-usage"
  printf '%s\n' "$config" > "$planning/config.json"
  CLAUDE_SESSION_ID="$sid" MERIDIAN_PLANNING_DIR="$planning" CLAUDE_PLUGIN_ROOT="${GUARD_PLUGIN_ROOT-$PLUGIN}" \
    CLAUDE_CONFIG_DIR="$TEST_TEMP_DIR/claude-config" bash "$SCRIPTS_DIR/suggest-compact.sh" "$@"
}

native_guard_row() {
  local label=$1 native=$2 legacy=$3 expected
  expected=$(guard active "$legacy" '{"compaction_threshold":700000}' s1 execute)
  run guard active "$native" '{"compaction_threshold":700000}' s1 execute
  expect_case_exact "$label" 0 "$expected"
  [ -n "$output" ] || record_case_failure "$label" 'compact suggestion missing'
}

@test "context guard stays silent unless this session's usage leaves too little headroom" {
  run env MERIDIAN_PLANNING_DIR="$TEST_TEMP_DIR/active" CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "$SCRIPTS_DIR/suggest-compact.sh" execute
  expect_case_silent no-usage-file 0

  run guard active '80|200000' '{}' s1 execute
  expect_case_silent legacy-two-field-usage 0

  run guard active 'garbage' '{}' s1 execute
  expect_case_silent malformed-usage 0

  run guard active 'other|99|100000' '{}' s1 execute
  expect_case_silent other-session 0

  run guard active 'unknown|99|100000' '{}' unknown execute
  expect_case_silent unknown-session 0

  run guard active 's1|99|100000' '{}' '' execute
  expect_case_silent no-current-session 0

  run guard active 'a/b|99|100000' '{}' 'a/b' execute
  expect_case_silent unsafe-session-id 0

  run guard active 's1|99|0' '{}' s1 execute
  expect_case_silent zero-context-size 0

  run guard active 's1|10|1000000' '{}' s1 execute
  expect_case_silent ample-headroom 0

  run guard active 's1|10|1000000' '{"compaction_threshold":1000000}' s1 execute
  expect_case_silent under-threshold 0

  assert_no_case_failures
}

@test "context guard estimates each workflow's token cost from its fixed and project files" {
  native_guard_row native-fractional-window 's1|72.5|1000000|statusline' 's1|72|1000000'
  native_guard_row native-tight-headroom 's1|99.5|100000|statusline' 's1|99|100000'
  build_planning finished
  rm "$TEST_TEMP_DIR/finished/phases/01-active/01-01-PLAN.md"
  sized_file "$TEST_TEMP_DIR/finished/phases/01-active/01-01-SUMMARY.md" 2000 $'---\nstatus: complete\n---\n'

  run guard active 's1|99|100000' '{}' s1 execute
  expect_case execute 0 "needs ~3700 tokens"

  run guard active 's1|99|100000' '{"effort":"thorough"}' s1 execute
  expect_case execute-thorough 0 "needs ~3900 tokens"

  run guard active 's1|99|100000' '{"effort":"fast"}' s1 execute
  expect_case execute-fast 0 "needs ~4100 tokens"

  run guard active 's1|99|100000' '{"effort":"turbo"}' s1 execute
  expect_case execute-turbo 0 "needs ~4300 tokens"

  run guard active 's1|99|100000' '{}' s1 plan
  expect_case plan 0 "needs ~2700 tokens"

  run guard active 's1|99|100000' '{}' s1 verify
  expect_case verify-excludes-source-uat 0 "needs ~2500 tokens"

  run guard active 's1|99|100000' '{}' s1 qa
  expect_case qa 0 "needs ~3100 tokens"

  run guard finished 's1|99|100000' '{}' s1 qa
  expect_case qa-all-phases-done-uses-last 0 "needs ~3300 tokens"

  run guard active 's1|99|100000' '{}' s1 discuss
  expect_case discuss 0 "needs ~2100 tokens"

  run guard active 's1|99|100000' '{}' s1 archive
  expect_case other-workflow 0 "needs ~2300 tokens"

  mkdir -p "$TEST_TEMP_DIR/claude-config/plugins/cache/meridian-marketplace/meridian/1.0.9"
  cp -R "$PLUGIN" "$TEST_TEMP_DIR/claude-config/plugins/cache/meridian-marketplace/meridian/1.0.10"
  GUARD_PLUGIN_ROOT='' run guard active 's1|99|100000' '{}' s1 execute
  expect_case latest-cached-plugin 0 "needs ~3700 tokens"

  sized_file "$TEST_TEMP_DIR/no-phases/ROADMAP.md" 1000
  run guard no-phases 's1|99|100000' '{}' s1 discuss
  expect_case no-phases-dir 0 "needs ~1900 tokens"

  run guard active 's1|99|100000' '{"autonomy":"confident"}' s1 execute
  expect_case confident-autonomy 0 "autonomy is set to confident"

  run guard active 's1|10|1000000' '{"compaction_threshold":50000}' s1 execute
  expect_case threshold-exceeded 0 "needs ~3700 tokens"

  assert_no_case_failures
}
