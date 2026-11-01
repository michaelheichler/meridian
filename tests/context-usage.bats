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
  reset_case_failures
}

teardown() {
  cd "$PROJECT_ROOT"
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
  level_row two-field-record auto "60|200000" lite
  level_row missing-file auto none-file none
  level_row non-numeric-percent auto "s1|abc|200000" none
  level_row non-auto-style-passes-through full "s1|90|200000" full

  assert_no_case_failures
}
