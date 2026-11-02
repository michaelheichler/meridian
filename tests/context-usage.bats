#!/usr/bin/env bats

load test_helper
load gate_case_helper

setup() {
  setup_temp_dir
  PROJECT_DIR="$TEST_TEMP_DIR/project"
  mkdir -p "$PROJECT_DIR/.lbwc-planning"
  cd "$PROJECT_DIR"
  HOOK="$PROJECT_ROOT/hooks/context_usage.py"
  USAGE_FILE="$PROJECT_DIR/.lbwc-planning/.context-usage"
  git init -q
  reset_case_failures
}

teardown() {
  cd "$PROJECT_ROOT"
  await_git_ai
  teardown_temp_dir
}

resolve_level() {
  bash -c ". '$PROJECT_ROOT/scripts/lib/resolve-caveman-level.sh' && resolve_caveman_level '$1' '$PROJECT_DIR/.lbwc-planning' && printf '%s' \"\$RESOLVED_CAVEMAN_LEVEL\""
}

run_hook_with_transcript() {
  local transcript="$PROJECT_DIR/transcript.jsonl"
  python3 -c "open('$transcript','w').write('x' * $1)"
  run python3 "$HOOK" <<EOF
{"session_id": "s1", "cwd": "$PROJECT_DIR", "transcript_path": "$transcript", "tool_name": "Write", "tool_input": {}}
EOF
}

record_row() {
  local label="$1" transcript_chars="$2" window_config="$3" expected_record="$4" record
  rm -f "$USAGE_FILE" "$PROJECT_DIR/.lbwc-planning/config.json"
  [ -z "$window_config" ] || printf '{"context_window_tokens": %s}\n' "$window_config" > "$PROJECT_DIR/.lbwc-planning/config.json"
  [ -z "${5:-}" ] || printf '%s\n' "$5" > "$USAGE_FILE"
  run_hook_with_transcript "$transcript_chars"
  expect_case "$label" 0
  record=$(cat "$USAGE_FILE" 2>/dev/null || echo "missing")
  [ "$record" = "$expected_record" ] || record_case_failure "$label" "record=$record expected=$expected_record"
}

fail_open_row() {
  local label="$1" payload="$2"
  rm -f "$USAGE_FILE"
  run python3 "$HOOK" <<< "$payload"
  expect_case "$label" 0
  [ ! -e "$USAGE_FILE" ] || record_case_failure "$label" "usage file written: $(cat "$USAGE_FILE")"
}

level_row() {
  local label="$1" style="$2" record="$3" expected_level="$4" level
  rm -f "$USAGE_FILE"
  [ "$record" = none-file ] || printf '%s\n' "$record" > "$USAGE_FILE"
  level=$(resolve_level "$style")
  [ "$level" = "$expected_level" ] || record_case_failure "$label" "record=$record style=$style level=$level expected=$expected_level"
}

@test "context-usage hook records session, capped percent and window, and fails open without writing on unusable input" {
  record_row default-window 400000 "" "s1|50|200000"
  record_row native-wins 400000 "" 's1|72.5|1000000|statusline' 's1|72.5|1000000|statusline'
  record_row native-zero-wins 400000 "" 's1|0|1000000|statusline' 's1|0|1000000|statusline'
  record_row foreign-native-falls-back 400000 "" 's1|50|200000' 'other|72.5|1000000|statusline'
  record_row configured-window 200000 100000 "s1|50|100000"
  record_row over-full-caps-at-100 2000000 "" "s1|100|200000"

  fail_open_row missing-transcript '{"session_id": "s1", "cwd": "/nonexistent", "tool_name": "Write"}'
  fail_open_row garbage-stdin 'not json at all'

  assert_no_case_failures
}

@test "resolve_caveman_level maps usage records to a level" {
  level_row under-50-is-none auto "s1|30|200000" none
  level_row 49-is-none auto "s1|49|200000" none
  level_row 50-is-lite auto "s1|50|200000" lite
  level_row 55-is-lite auto "s1|55|200000" lite
  level_row 69-is-lite auto "s1|69|200000" lite
  level_row 70-is-full auto "s1|70|200000" full
  level_row 72-is-full auto "s1|72|200000" full
  level_row 84-is-full auto "s1|84|200000" full
  level_row 85-is-ultra auto "s1|85|200000" ultra
  level_row 90-is-ultra auto "s1|90|200000" ultra
  level_row native-fraction-is-full auto 's1|72.5|1000000|statusline' full
  level_row two-field-record auto "60|200000" lite
  level_row missing-file auto none-file none
  level_row non-numeric-percent auto "s1|abc|200000" none
  level_row non-auto-style-passes-through full "s1|90|200000" full

  assert_no_case_failures
}

compact_fixture() {
  local transcript="$PROJECT_DIR/transcript.jsonl"
  rm -f "$PROJECT_DIR/.lbwc-planning/.context-usage-reset"
  printf '%s\n' 's1|95|200000' > "$USAGE_FILE"
  python3 -c 'import sys; open(sys.argv[1], "w").write("x" * 400000)' "$transcript"
  jq -cn --arg cwd "$PROJECT_DIR" --arg transcript "$transcript" \
    '{source:"compact",session_id:"s1",cwd:$cwd,transcript_path:$transcript}'
}

compact_reset_row() {
  local label=$1 readable=$2 payload baseline
  payload=$(compact_fixture)
  baseline='s1|400000'
  if [ "$readable" = no ]; then
    rm "$PROJECT_DIR/transcript.jsonl"
    baseline='s1|-1'
  fi
  run bash "$SCRIPTS_DIR/post-compact.sh" <<< "$payload"
  expect_case "$label" 0
  [ ! -e "$USAGE_FILE" ] || record_case_failure "$label" 'stale usage survived'
  [ "$(cat "$PROJECT_DIR/.lbwc-planning/.context-usage-reset")" = "$baseline" ] \
    || record_case_failure "$label" 'wrong transcript baseline'
}

compact_estimate_row() {
  local label=$1 growth=$2 readable=$3 expected=$4 payload record
  payload=$(compact_fixture)
  [ "$readable" = yes ] || rm "$PROJECT_DIR/transcript.jsonl"
  bash "$SCRIPTS_DIR/post-compact.sh" <<< "$payload" >/dev/null
  python3 -c 'import sys; open(sys.argv[1], "a").write("x" * int(sys.argv[2]))' "$PROJECT_DIR/transcript.jsonl" "$growth"
  run python3 "$HOOK" <<< "$(jq 'del(.source)' <<< "$payload")"
  expect_case "$label" 0
  record=$(cat "$USAGE_FILE" 2>/dev/null || printf absent)
  [ "$record" = "$expected" ] || record_case_failure "$label" "record=$record expected=$expected"
}

@test "compaction discards stale usage and estimates only transcript growth after the baseline" {
  compact_reset_row compact-baseline yes
  compact_reset_row compact-missing-baseline no
  compact_estimate_row compact-unchanged 0 yes 's1|0|200000'
  compact_estimate_row compact-growth 80000 yes 's1|10|200000'
  compact_estimate_row compact-unreadable-no-stale-estimate 400000 no absent
  assert_no_case_failures
}

compaction_style_row() {
  local style=$1 expected context
  rm -f "$USAGE_FILE" "$PROJECT_DIR/.lbwc-planning/.compaction-count"
  printf '{"caveman_style":"%s"}\n' "$style" > "$PROJECT_DIR/.lbwc-planning/config.json"
  expected=$(bash "$SCRIPTS_DIR/compaction-instructions.sh" <<< '{}')
  rm -f "$PROJECT_DIR/.lbwc-planning/.compaction-count"
  printf '%s\n' 's1|95|200000' > "$USAGE_FILE"
  run bash "$SCRIPTS_DIR/compaction-instructions.sh" <<< '{}'
  expect_case_exact "precompact-$style-independent-of-old-usage" 0 "$expected"
  context=$(jq -r '.hookSpecificOutput.additionalContext' <<< "$output")
  if [ "$style" != auto ]; then
    [[ "$context" =~ $style ]] || record_case_failure "precompact-$style" 'explicit style lost'
  fi
}

@test "compaction instructions retain explicit styles without freezing adaptive style at old usage" {
  compaction_style_row auto
  compaction_style_row lite
  compaction_style_row full
  compaction_style_row ultra
  assert_no_case_failures
}
