#!/usr/bin/env bats

load test_helper
load gate_case_helper

setup() { setup_temp_dir; cd "$TEST_TEMP_DIR"; LOG=".meridian/telemetry/session.jsonl"; }
teardown() { cd "$PROJECT_ROOT"; teardown_temp_dir; }

writer() { python3 "$PROJECT_ROOT/scripts/lib/session-telemetry.py" "$@"; }

forged_genesis_log() {
  mkdir -p .meridian/telemetry
  python3 - <<'PY'
import hashlib, json
r = {"ts":"2026-01-01T00:00:00+00:00","session_id":None,"actor":"main","event":"session_start","outcome":"success","duration_ms":None,"tokens_in":None,"tokens_out":None,"model":None,"phase":None,"prev_sha256":"forged"}
r["sha256"] = hashlib.sha256(json.dumps(r, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
open('.meridian/telemetry/session.jsonl','w').write(json.dumps(r, sort_keys=True, separators=(",", ":"))+'\n')
PY
}

prior_log() {
  mkdir -p .meridian/telemetry
  case "$1" in
    none) ;;
    schema-garbage) echo '{"not":"a record"}' > "$LOG" ;;
    malformed-json) echo 'not json' > "$LOG" ;;
    forged-genesis) forged_genesis_log ;;
  esac
}

log_size() {
  if [ -f "$LOG" ]; then
    wc -c < "$LOG" | tr -d ' '
  else
    echo 0
  fi
}

hold_lock() {
  mkdir -p .meridian/telemetry
  python3 -c 'import fcntl,sys,time; f=open(sys.argv[1],"a"); fcntl.flock(f,fcntl.LOCK_EX); open(sys.argv[2],"w").close(); time.sleep(5)' "$LOG" "$TEST_TEMP_DIR/locked" &
  LOCKER=$!
  local waited=0
  while [ ! -e "$TEST_TEMP_DIR/locked" ] && [ "$waited" -lt 100 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  [ -e "$TEST_TEMP_DIR/locked" ]
}

release_lock() {
  kill "$LOCKER" 2>/dev/null || true
  wait "$LOCKER" 2>/dev/null || true
}

@test "writer chains main-session events, follows a planning alias, and rejects bad input without appending" {
  local label prior args size_before long_value
  reset_case_failures

  run writer record --event session_start --outcome success --duration-ms 12 --session-id s1
  expect_case chain-start 0
  run writer record --event command --outcome success
  expect_case chain-command 0
  run writer record --event session_stop --outcome success
  expect_case chain-stop 0

  run python3 -c '
import json, sys
first, second, third = [json.loads(line) for line in open(sys.argv[1])]
assert first["actor"] == "main", first
assert first["prev_sha256"] is None, first
assert len(first["sha256"]) == 64, first
assert second["prev_sha256"] == first["sha256"], second
assert third["prev_sha256"] == second["sha256"], third
' "$TEST_TEMP_DIR/$LOG"
  expect_case chain-hashes 0

  mkdir -p canonical
  ln -s canonical alias
  run env MERIDIAN_PLANNING_DIR="$TEST_TEMP_DIR/alias" python3 "$PROJECT_ROOT/scripts/lib/session-telemetry.py" record --event session_start --outcome success
  expect_case planning-alias 0
  [ -f canonical/telemetry/session.jsonl ] || record_case_failure planning-alias "canonical log missing"

  long_value=$(printf 'x%.0s' {1..257})
  while IFS='~' read -r label prior args; do
    [ -n "$label" ] || continue
    rm -rf .meridian
    prior_log "$prior"
    size_before=$(log_size)
    args="${args//@LONG@/$long_value}"

    run writer record $args

    expect_case "$label" 2
    [ "$(log_size)" = "$size_before" ] || record_case_failure "$label" "log size $(log_size) want $size_before"
  done <<'CASES'
agent-actor~none~--event session_start --outcome success --actor agent
arbitrary-field~none~--event session_start --outcome success --field transcript=secret
unknown-event~none~--event bogus --outcome success
unknown-outcome~none~--event command --outcome bogus
oversized-session-id~none~--event command --outcome success --session-id @LONG@
malformed-prior-record~schema-garbage~--event session_start --outcome success
unparsable-prior-line~malformed-json~--event session_start --outcome success
forged-genesis-prev-hash~forged-genesis~--event command --outcome success
CASES

  assert_no_case_failures
}

@test "writer fails closed on lock contention for every timeout setting" {
  local label timeout
  reset_case_failures
  while IFS='~' read -r label timeout; do
    [ -n "$label" ] || continue
    rm -rf .meridian "$TEST_TEMP_DIR/locked"
    hold_lock || record_case_failure "$label" "lock holder did not start"

    run env MERIDIAN_TELEMETRY_LOCK_TIMEOUT="$timeout" python3 "$PROJECT_ROOT/scripts/lib/session-telemetry.py" record --event command --outcome success

    release_lock
    expect_case "$label" 2 "timed out waiting for telemetry lock"
  done <<'CASES'
short-timeout~0.05
nonfinite-timeout-uses-default~nan
unparsable-timeout-uses-default~abc
CASES

  assert_no_case_failures
}
