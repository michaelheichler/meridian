#!/usr/bin/env bats

load test_helper
load gate_case_helper
load gate_case_files

setup() {
  setup_temp_dir
  export MERIDIAN_PLANNING_DIR="$TEST_TEMP_DIR/.meridian"
  export EVIDENCE_SCRIPT="$SCRIPTS_DIR/agent-routing-evidence.sh"
  cd "$TEST_TEMP_DIR"
}

teardown() {
  teardown_temp_dir
}

run_evidence() {
  local command="$1" input="$2"
  run bash -c 'printf "%s\n" "$1" | MERIDIAN_PLANNING_DIR="$2" bash "$3" "$4"' \
    _ "$input" "$MERIDIAN_PLANNING_DIR" "$EVIDENCE_SCRIPT" "$command"
}

install_route_stub() {
  local route_json="$1" script_dir="$TEST_TEMP_DIR/scripts"
  mkdir -p "$script_dir"
  cp "$SCRIPTS_DIR/agent-routing-evidence.sh" "$script_dir/agent-routing-evidence.sh"
  printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' '$route_json'" > "$script_dir/meridian-routing.sh"
  chmod +x "$script_dir/meridian-routing.sh"
  export EVIDENCE_SCRIPT="$script_dir/agent-routing-evidence.sh"
}

write_transcript() {
  TRANSCRIPT="$TEST_TEMP_DIR/subagent.jsonl"
  printf '%s\n' "$1" > "$TRANSCRIPT"
}

stop_event() {
  printf '{"agent_type":"dev","agent_id":"agent-1","agent_transcript_path":"%s"}' "$TRANSCRIPT"
}

evidence_round() {
  rm -f "$MERIDIAN_PLANNING_DIR/.agent-routing-evidence.jsonl"
  install_route_stub "$2"
  write_transcript "$3"
  run_evidence start '{"agent_type":"dev","agent_id":"agent-1"}'
  expect_status "$1-start" 0
  run_evidence stop "$(stop_event)"
}

@test "routing evidence records a transcript match and reports a transcript model mismatch" {
  local record
  reset_case_failures

  evidence_round match '{"model":"claude-sonnet-5","reasoning":"high","role":"dev"}' \
    '{"type":"assistant","effort":"high","message":{"model":"claude-sonnet-5","content":[]}}'
  expect_status match-stop 0
  record=$(jq -s '[.[] | select(.event == "stop")][0]' "$MERIDIAN_PLANNING_DIR/.agent-routing-evidence.jsonl")
  [ "$(jq -r '.verdict.model' <<< "$record")" = "pass" ] || record_case_failure match-model "record=$record"
  [ "$(jq -r '.verdict.effort' <<< "$record")" = "pass" ] || record_case_failure match-effort "record=$record"

  evidence_round mismatch '{"model":"claude-sonnet-5","reasoning":null,"role":"dev"}' \
    '{"type":"assistant","message":{"model":"claude-opus-5","content":[]}}'
  expect_case mismatch-stop 0 "Agent routing evidence mismatch for dev"

  assert_no_case_failures
}
