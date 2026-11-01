#!/usr/bin/env bats

load test_helper

setup() {
  setup_temp_dir
  export LBWC_PLANNING_DIR="$TEST_TEMP_DIR/.lbwc-planning"
  export EVIDENCE_SCRIPT="$SCRIPTS_DIR/agent-routing-evidence.sh"
  cd "$TEST_TEMP_DIR"
}

teardown() {
  teardown_temp_dir
}

run_evidence() {
  local command="$1" input="$2"
  run bash -c 'printf "%s\n" "$1" | LBWC_PLANNING_DIR="$2" bash "$3" "$4"' \
    _ "$input" "$LBWC_PLANNING_DIR" "$EVIDENCE_SCRIPT" "$command"
}

install_route_stub() {
  local route_json="$1" script_dir="$TEST_TEMP_DIR/scripts"
  mkdir -p "$script_dir"
  cp "$SCRIPTS_DIR/agent-routing-evidence.sh" "$script_dir/agent-routing-evidence.sh"
  printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' '$route_json'" > "$script_dir/lbwc-routing.sh"
  chmod +x "$script_dir/lbwc-routing.sh"
  export EVIDENCE_SCRIPT="$script_dir/agent-routing-evidence.sh"
}

write_transcript() {
  TRANSCRIPT="$TEST_TEMP_DIR/subagent.jsonl"
  printf '%s\n' "$1" > "$TRANSCRIPT"
}

stop_event() {
  printf '{"agent_type":"dev","agent_id":"agent-1","agent_transcript_path":"%s"}' "$TRANSCRIPT"
}

@test "routing evidence records a resolved route and transcript match" {
  local record
  install_route_stub '{"model":"claude-sonnet-5","reasoning":"high","role":"dev"}'
  write_transcript '{"type":"assistant","effort":"high","message":{"model":"claude-sonnet-5","content":[]}}'

  run_evidence start '{"agent_type":"dev","agent_id":"agent-1"}'
  [ "$status" -eq 0 ]
  run_evidence stop "$(stop_event)"
  [ "$status" -eq 0 ]

  record=$(jq -s '[.[] | select(.event == "stop")][0]' "$LBWC_PLANNING_DIR/.agent-routing-evidence.jsonl")
  [ "$(jq -r '.verdict.model' <<< "$record")" = "pass" ]
  [ "$(jq -r '.verdict.effort' <<< "$record")" = "pass" ]
}

@test "routing evidence reports a transcript model mismatch" {
  install_route_stub '{"model":"claude-sonnet-5","reasoning":null,"role":"dev"}'
  write_transcript '{"type":"assistant","message":{"model":"claude-opus-5","content":[]}}'

  run_evidence start '{"agent_type":"dev","agent_id":"agent-1"}'
  run_evidence stop "$(stop_event)"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Agent routing evidence mismatch for dev"* ]]
}
