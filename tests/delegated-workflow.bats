#!/usr/bin/env bats

load test_helper
load gate_case_helper
load rejection_case_helper

setup() {
  setup_temp_dir
  REPO="$TEST_TEMP_DIR/repo"
  setup_unrelated_git_repo "$REPO"
  mkdir -p "$REPO/.meridian"
  cd "$REPO" || return 1
  SCRIPT="$SCRIPTS_DIR/delegated-workflow.sh"
  MARKER="$REPO/.meridian/.delegated-workflow.json"
  EXEC_STATE="$REPO/.meridian/.execution-state.json"
  NOJQ_BIN="$TEST_TEMP_DIR/nojq-bin"
  mkdir -p "$NOJQ_BIN"
  local tool
  for tool in bash date uname stat grep rm; do
    ln -s "$(command -v "$tool")" "$NOJQ_BIN/$tool"
  done
}

teardown() {
  cd "$PROJECT_ROOT" || true
  teardown_temp_dir
}

age_file() {
  [ "$2" != old ] || touch -t 202001010000 "$1"
}

place_file() {
  local path="$1" content="$2" age="$3"
  rm -f "$path"
  [ "$content" != "-" ] || return 0
  printf '%s\n' "$content" > "$path"
  age_file "$path" "$age"
}

workflow_world() {
  place_file "$MARKER" "$1" "$2"
  place_file "$EXEC_STATE" "$3" "$4"
}

status_summary() {
  printf '%s' "$output" | jq -r '"\(.reason) live=\(.live) preserve=\(.preserve_on_session_start)"' 2>&1
}

status_row() {
  local label="$1" want="$2" session="${3:-}" got
  run env CLAUDE_SESSION_ID="$session" bash "$SCRIPT" status-json
  expect_case "$label" 0
  got=$(status_summary)
  [ "$got" = "$want" ] || record_case_failure "$label" "got=[$got] want=[$want]"
}

marker_summary() {
  jq -r '"mode=\(.mode) active=\(.active) effort=\(.effort) delegation=\(.delegation_mode) team=\(.team_name) session=\(.session_id) correlation=\(.correlation_id)"' "$MARKER" 2>&1
}

expect_marker() {
  local label="$1" want="$2" got
  got=$(marker_summary)
  [ "$got" = "$want" ] || record_case_failure "$label" "marker got=[$got] want=[$want]"
}

expect_no_marker() {
  [ ! -e "$MARKER" ] || record_case_failure "$1" "marker exists: $(cat "$MARKER")"
}

@test "status-json reports a live marker only for a fresh active marker whose execution state runs under the same correlation and session" {
  local exec_ok='{"status":"running","correlation_id":"c1"}'
  local execute_c1='{"active":true,"mode":"execute","correlation_id":"c1"}'
  reset_case_failures

  workflow_world - now - now
  status_row missing-marker "missing_marker live=false preserve=false"
  workflow_world '{broken' now - now
  status_row invalid-marker-json "invalid_marker_json live=false preserve=false"
  workflow_world '{"active":false,"mode":"debug"}' now - now
  status_row inactive-marker "inactive live=false preserve=false"
  workflow_world '{"active":true,"mode":"debug"}' now - now
  status_row fresh-debug-marker "ok live=true preserve=false"
  workflow_world '{"active":true,"mode":"debug"}' old - now
  status_row old-debug-marker "stale_marker live=false preserve=false"
  workflow_world '{"active":true,"mode":"debug","session_id":"s1"}' now - now
  status_row other-session-marker "session_mismatch live=false preserve=false" s2
  workflow_world '{"active":true,"mode":"debug","session_id":"s1"}' now - now
  status_row same-session-marker "ok live=true preserve=false" s1
  workflow_world "$execute_c1" now - now
  status_row execute-without-state "missing_execution_state live=false preserve=false"
  workflow_world "$execute_c1" old - now
  status_row old-execute-without-state "stale_marker live=false preserve=false"
  workflow_world "$execute_c1" now '{broken' now
  status_row invalid-execution-state "invalid_execution_state live=false preserve=false"
  workflow_world "$execute_c1" now "$exec_ok" old
  status_row old-execution-state "stale_execution_state live=false preserve=false"
  workflow_world "$execute_c1" now '{"status":"done","correlation_id":"c1"}' now
  status_row finished-execution "execution_not_running live=false preserve=false"
  workflow_world "$execute_c1" old '{"status":"done","correlation_id":"c1"}' now
  status_row finished-execution-old-marker "stale_marker live=false preserve=false"
  workflow_world '{"active":true,"mode":"execute"}' now "$exec_ok" now
  status_row marker-without-correlation "missing_marker_correlation_id live=false preserve=false"
  workflow_world "$execute_c1" now '{"status":"running"}' now
  status_row state-without-correlation "missing_execution_correlation_id live=false preserve=false"
  workflow_world '{"active":true,"mode":"execute","correlation_id":"c2"}' now "$exec_ok" now
  status_row correlation-mismatch "correlation_mismatch live=false preserve=false"
  workflow_world '{"active":true,"mode":"execute","correlation_id":"c2"}' old "$exec_ok" now
  status_row correlation-mismatch-old-marker "stale_marker live=false preserve=false"
  workflow_world "$execute_c1" now "$exec_ok" now
  status_row matching-execution "ok live=true preserve=true"

  workflow_world '{"active":true,"mode":"debug"}' now "$exec_ok" now
  run env PATH="$NOJQ_BIN" bash "$SCRIPT" status-json
  expect_case without-jq 0 '"reason":"jq_unavailable"'
  expect_fragment without-jq '"exists":true'
  expect_fragment without-jq '"live":false'

  assert_no_case_failures
}

@test "set records an active marker with the effort, the session and the running execution correlation, and refuses without a mode or planning directory" {
  reset_case_failures

  run bash "$SCRIPT" set
  expect_case set-without-mode 1 "Usage: delegated-workflow.sh set <mode>"
  expect_no_marker set-without-mode

  run env MERIDIAN_PLANNING_DIR="$REPO/absent" bash "$SCRIPT" set debug
  expect_case set-without-planning-dir 1 "No .meridian/ directory"

  run bash "$SCRIPT" set fix
  expect_case_silent set-default-effort 0
  expect_marker set-default-effort "mode=fix active=true effort=balanced delegation= team= session= correlation="

  run bash "$SCRIPT" set debug thorough solo crew
  expect_case_silent set-all-fields 0
  expect_marker set-all-fields "mode=debug active=true effort=thorough delegation=solo team=crew session= correlation="

  workflow_world - now '{"status":"running","correlation_id":"c7"}' now
  run env CLAUDE_SESSION_ID=s9 bash "$SCRIPT" set execute
  expect_case_silent set-with-execution-state 0
  expect_marker set-with-execution-state "mode=execute active=true effort=balanced delegation= team= session=s9 correlation=c7"
  [ "$(jq -r '.session_id' "$EXEC_STATE")" = s9 ] \
    || record_case_failure set-with-execution-state "execution state lacks the session: $(cat "$EXEC_STATE")"
  run env CLAUDE_SESSION_ID=s9 bash "$SCRIPT" status-json
  [ "$(status_summary)" = "ok live=true preserve=true" ] \
    || record_case_failure set-then-status "status after set=[$(status_summary)]"

  workflow_world - now '{broken' now
  run env CLAUDE_SESSION_ID=s9 bash "$SCRIPT" set debug
  expect_case_silent set-with-unreadable-execution-state 0
  expect_marker set-with-unreadable-execution-state "mode=debug active=true effort=balanced delegation= team= session=s9 correlation="
  [ "$(cat "$EXEC_STATE")" = '{broken' ] \
    || record_case_failure set-with-unreadable-execution-state "execution state rewritten: $(cat "$EXEC_STATE")"
  [ -z "$(find "$REPO/.meridian" -name '*.tmp.*')" ] \
    || record_case_failure set-with-unreadable-execution-state "temp file left: $(ls -a "$REPO/.meridian")"

  workflow_world - now - now
  run env PATH="$NOJQ_BIN" bash "$SCRIPT" set debug fast
  expect_case_silent set-without-jq 0
  expect_marker set-without-jq "mode=debug active=true effort=fast delegation= team= session= correlation="

  run bash "$SCRIPT" sett
  expect_case unknown-action 1 "Usage: delegated-workflow.sh {set|clear|check|status-json}"

  assert_no_case_failures
}

@test "check succeeds only while an active marker exists, and clear removes the marker" {
  reset_case_failures

  workflow_world - now - now
  run bash "$SCRIPT" check
  expect_case_silent check-without-marker 1

  workflow_world '{"active":false,"mode":"debug"}' now - now
  run bash "$SCRIPT" check
  expect_case_silent check-inactive-marker 1

  workflow_world '{"active":true,"mode":"debug"}' now - now
  run bash "$SCRIPT" check
  expect_case_silent check-active-marker 0

  run env PATH="$NOJQ_BIN" bash "$SCRIPT" check
  expect_case_silent check-without-jq-trusts-marker 0

  run bash "$SCRIPT" clear
  expect_case_silent clear 0
  expect_no_marker clear
  run bash "$SCRIPT" check
  expect_case_silent check-after-clear 1

  assert_no_case_failures
}
