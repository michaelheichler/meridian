#!/usr/bin/env bats

load test_helper

setup() {
  setup_temp_dir
  PROJECT_DIR="$TEST_TEMP_DIR/project"
  mkdir -p "$PROJECT_DIR/.lbwc-planning"
  cd "$PROJECT_DIR"
  HOOK="$PROJECT_ROOT/hooks/context_usage.py"
  USAGE_FILE="$PROJECT_DIR/.lbwc-planning/.context-usage"
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

case_fail() {
  echo "case=$1 $2" >&2
  echo "output=$output" >&2
}

@test "context-usage hook records session, capped percent, and window" {
  while IFS='|' read -r label transcript_chars window_config expected_record; do
    [ -n "$label" ] || continue
    rm -f "$USAGE_FILE" "$PROJECT_DIR/.lbwc-planning/config.json"
    [ -z "$window_config" ] || printf '{"context_window_tokens": %s}\n' "$window_config" > "$PROJECT_DIR/.lbwc-planning/config.json"

    run_hook_with_transcript "$transcript_chars"

    [ "$status" -eq 0 ] || { case_fail "$label" "hook status=$status"; return 1; }
    record=$(cat "$USAGE_FILE" 2>/dev/null || echo "missing")
    [ "$record" = "$expected_record" ] || { case_fail "$label" "record=$record expected=$expected_record"; return 1; }
  done <<'CASES'
default-window|400000||s1|50|200000
configured-window|200000|100000|s1|50|100000
over-full-caps-at-100|2000000||s1|100|200000
CASES
}

@test "context-usage hook fails open and writes nothing on unusable input" {
  while IFS='|' read -r label payload; do
    [ -n "$label" ] || continue
    rm -f "$USAGE_FILE"

    run python3 "$HOOK" <<< "$payload"

    [ "$status" -eq 0 ] || { case_fail "$label" "hook status=$status"; return 1; }
    [ ! -e "$USAGE_FILE" ] || { case_fail "$label" "usage file written: $(cat "$USAGE_FILE")"; return 1; }
  done <<'CASES'
missing-transcript|{"session_id": "s1", "cwd": "/nonexistent", "tool_name": "Write"}
garbage-stdin|not json at all
CASES
}

@test "resolve_caveman_level maps usage records to a level" {
  while IFS='|' read -r label style record expected_level; do
    [ -n "$label" ] || continue
    rm -f "$USAGE_FILE"
    [ "$record" = none-file ] || printf '%s\n' "${record//;/|}" > "$USAGE_FILE"

    level=$(resolve_level "$style")

    [ "$level" = "$expected_level" ] || { echo "case=$label record=$record style=$style level=$level expected=$expected_level" >&2; return 1; }
  done <<'CASES'
under-50-is-none|auto|s1;30;200000|none
49-is-none|auto|s1;49;200000|none
50-is-lite|auto|s1;50;200000|lite
55-is-lite|auto|s1;55;200000|lite
69-is-lite|auto|s1;69;200000|lite
70-is-full|auto|s1;70;200000|full
72-is-full|auto|s1;72;200000|full
84-is-full|auto|s1;84;200000|full
85-is-ultra|auto|s1;85;200000|ultra
90-is-ultra|auto|s1;90;200000|ultra
two-field-record|auto|60;200000|lite
missing-file|auto|none-file|none
non-numeric-percent|auto|s1;abc;200000|none
non-auto-style-passes-through|full|s1;90;200000|full
CASES
}
