#!/usr/bin/env bats

load tmux_watchdog_fixture

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/tmux-bus-watchdog.sh"
  unset TMUX TMUX_PANE
  TEST_ROOT="$(mktemp -d)"
  TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
  CONTROL_ROOT="$TEST_ROOT/project/.lbwc-planning"
  mkdir -p "$CONTROL_ROOT"
  printf '%s\n' '{}' > "$CONTROL_ROOT/config.json"
}

teardown() {
  rm -rf "$TEST_ROOT"
}

run_watchdog() {
  run bash "$SCRIPT" --control-root "$CONTROL_ROOT" check --orchestrator-id main-session --orchestrator-session-id main-session --orchestrator-capability "$MAIN_CAPABILITY" --stale-after-ms "$1" --shutdown-timeout-ms "$2"
}

write_tmux_shim() {
  local tmux_bin="$TEST_ROOT/bin"
  mkdir -p "$tmux_bin"
  cat > "$tmux_bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  display-message) [ -e "$LBWC_TEST_TMUX_MARKER" ] && printf '%%1\n' ;;
  kill-pane) [ "${LBWC_TEST_TMUX_KILL_FAIL:-0}" = 1 ] && exit 1; rm -f "$LBWC_TEST_TMUX_MARKER" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$tmux_bin/tmux"
  printf '%s\n' "$tmux_bin"
}

@test "tmux watchdog: fails closed on a malformed runtime registry" {
  CONTROL_ROOT="$TEST_ROOT/control"
  mkdir -p "$CONTROL_ROOT/.runtime/tmux-bus"
  printf '{not valid json\n' > "$CONTROL_ROOT/.runtime/tmux-bus/registry.json"

  run bash "$SCRIPT" \
    --control-root "$CONTROL_ROOT" \
    check \
    --orchestrator-id main-session \
    --orchestrator-session-id main-session \
    --orchestrator-capability 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
    --stale-after-ms 120000 \
    --shutdown-timeout-ms 5000

  [ "$status" -ne 0 ]
  [ "$output" = "tmux-watchdog: runtime registry is malformed" ]
}

@test "tmux watchdog: emits an error envelope and records one actionable notification when stale agents shut down" {
  fixture_watchdog_bus
  plant_bound_agent missing:0.1 ''
  run jq -e '.agents | length == 1' "$CONTROL_ROOT/.runtime/tmux-bus/registry.json"
  [ "$status" -eq 0 ]

  run_watchdog 120000 5000
  [ "$status" -eq 1 ]
  run jq -e '.agents[] | select(.agent_id == "agent-a") | .state == "shutdown"' "$CONTROL_ROOT/.runtime/tmux-bus/registry.json"
  [ "$status" -eq 0 ]
  run jq -e '.type == "error" and .from.role == "orchestrator" and .to.agent_id == "main-session" and (.body.message | contains("agent-a"))' "$CONTROL_ROOT/.runtime/tmux-bus/inboxes/main-session/error.json"
  [ "$status" -eq 0 ]
  run jq -s -e 'length == 1 and .[0].type == "tmux_watchdog_stale_agents_failed" and .[0].title == "TMUX watchdog failed stale agents" and (.[0].message | contains("agent-a"))' "$CONTROL_ROOT/.notification-log.jsonl"
  [ "$status" -eq 0 ]

  run_watchdog 120000 5000
  [ "$status" -eq 0 ]
  run jq -s -e 'length == 1' "$CONTROL_ROOT/.notification-log.jsonl"
  [ "$status" -eq 0 ]
}

@test "tmux watchdog: concurrent checks notify once and preserve one terminal transition" {
  local result
  fixture_watchdog_bus
  plant_bound_agent missing:0.1 ''
  result="$TEST_ROOT/concurrent-result"

  run env SCRIPT="$SCRIPT" CONTROL_ROOT="$CONTROL_ROOT" MAIN_CAPABILITY="$MAIN_CAPABILITY" RESULT="$result" bash -c '
    bash "$SCRIPT" --control-root "$CONTROL_ROOT" check --orchestrator-id main-session --orchestrator-session-id main-session --orchestrator-capability "$MAIN_CAPABILITY" --stale-after-ms 1 --shutdown-timeout-ms 50 > "$RESULT.one" 2>&1 &
    first=$!
    bash "$SCRIPT" --control-root "$CONTROL_ROOT" check --orchestrator-id main-session --orchestrator-session-id main-session --orchestrator-capability "$MAIN_CAPABILITY" --stale-after-ms 1 --shutdown-timeout-ms 50 > "$RESULT.two" 2>&1 &
    second=$!
    wait "$first" || true
    wait "$second" || true
  '

  [ "$status" -eq 0 ]
  run jq -s -e 'length == 1 and .[0].type == "tmux_watchdog_stale_agents_failed"' "$CONTROL_ROOT/.notification-log.jsonl"
  [ "$status" -eq 0 ]
  run jq -e '.agents[] | select(.agent_id == "agent-a") | .state == "shutdown"' "$CONTROL_ROOT/.runtime/tmux-bus/registry.json"
  [ "$status" -eq 0 ]
}

@test "tmux watchdog: honors graceful acknowledgement before forced pane termination" {
  local tmux_bin marker output_file
  tmux_bin=$(write_tmux_shim)
  marker="$TEST_ROOT/pane-present"
  output_file="$TEST_ROOT/watchdog-output"
  : > "$marker"
  fixture_watchdog_bus
  plant_bound_agent test:0.1 '%1'

  run timeout 60 env PATH="$tmux_bin:$PATH" LBWC_TEST_TMUX_MARKER="$marker" SCRIPT="$SCRIPT" BUS="$REPO_ROOT/scripts/tmux-bus.sh" CONTROL_ROOT="$CONTROL_ROOT" MAIN_CAPABILITY="$MAIN_CAPABILITY" AGENT_CAPABILITY="$AGENT_CAPABILITY" OUTPUT_FILE="$output_file" bash -c '
    bash "$SCRIPT" --control-root "$CONTROL_ROOT" check --orchestrator-id main-session --orchestrator-session-id main-session --orchestrator-capability "$MAIN_CAPABILITY" --stale-after-ms 1 --shutdown-timeout-ms 1000 > "$OUTPUT_FILE" 2>&1 &
    watchdog=$!
    for ((attempt = 0; attempt < 800; attempt++)); do
      [ -f "$CONTROL_ROOT/.runtime/tmux-bus/inboxes/agent-a/shutdown_request.json" ] && break
      sleep 0.01
    done
    [ -f "$CONTROL_ROOT/.runtime/tmux-bus/inboxes/agent-a/shutdown_request.json" ] || { cat "$OUTPUT_FILE"; exit 1; }
    bash "$BUS" --control-root "$CONTROL_ROOT" publish --to main-session --from-agent-id agent-a --from-session-id agent-session --from-role agent --capability "$AGENT_CAPABILITY" --type shutdown_response --correlation-id watchdog --payload "{\"acknowledged\":true}" >/dev/null
    rm -f "$LBWC_TEST_TMUX_MARKER"
    wait "$watchdog" || true
  '

  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
  run jq -e '.agents[] | select(.agent_id == "agent-a") | .state == "shutdown"' "$CONTROL_ROOT/.runtime/tmux-bus/registry.json"
  [ "$status" -eq 0 ]
}

@test "tmux watchdog: kills a stale pane after the graceful shutdown timeout" {
  local tmux_bin marker
  tmux_bin=$(write_tmux_shim)
  marker="$TEST_ROOT/pane-present"
  : > "$marker"
  fixture_watchdog_bus
  plant_bound_agent test:0.1 '%1'

  run timeout 60 env PATH="$tmux_bin:$PATH" LBWC_TEST_TMUX_MARKER="$marker" bash "$SCRIPT" --control-root "$CONTROL_ROOT" check --orchestrator-id main-session --orchestrator-session-id main-session --orchestrator-capability "$MAIN_CAPABILITY" --stale-after-ms 1 --shutdown-timeout-ms 30

  [ "$status" -eq 1 ]
  [ ! -e "$marker" ]
  run jq -e '.agents[] | select(.agent_id == "agent-a") | .state == "shutdown"' "$CONTROL_ROOT/.runtime/tmux-bus/registry.json"
  [ "$status" -eq 0 ]
}

@test "tmux watchdog: a pane that tmux reports with empty output counts as gone and the stale agent shuts down" {
  local tmux_bin="$TEST_ROOT/bin"
  mkdir -p "$tmux_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'case "$1" in display-message) exit 0 ;; *) exit 1 ;; esac' > "$tmux_bin/tmux"
  chmod +x "$tmux_bin/tmux"
  fixture_watchdog_bus
  plant_bound_agent test:0.1 '%1'

  run timeout 60 env PATH="$tmux_bin:$PATH" bash "$SCRIPT" --control-root "$CONTROL_ROOT" check --orchestrator-id main-session --orchestrator-session-id main-session --orchestrator-capability "$MAIN_CAPABILITY" --stale-after-ms 1 --shutdown-timeout-ms 30
  [ "$status" -eq 1 ]

  run jq -e '.agents[] | select(.agent_id == "agent-a") | .state == "shutdown"' "$CONTROL_ROOT/.runtime/tmux-bus/registry.json"
  [ "$status" -eq 0 ]
}

@test "tmux watchdog: completes teardown after a busy error inbox without retrying terminal reports" {
  fixture_watchdog_bus
  plant_bound_agent missing:0.1 ''
  run bash "$REPO_ROOT/scripts/tmux-bus.sh" --control-root "$CONTROL_ROOT" publish --to main-session --from-agent-id main-session --from-session-id main-session --from-role orchestrator --capability "$MAIN_CAPABILITY" --type error --correlation-id occupied --payload '{"message":"occupied"}'
  [ "$status" -eq 0 ]

  run_watchdog 1 30

  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot publish stale agent error envelope"* ]]
  run jq -e '.agents[] | select(.agent_id == "agent-a") | .state == "shutdown" and .watchdog_cleanup_pending == false' "$CONTROL_ROOT/.runtime/tmux-bus/registry.json"
  [ "$status" -eq 0 ]
  run jq -s -e 'length == 1 and .[0].type == "tmux_watchdog_stale_agents_failed"' "$CONTROL_ROOT/.notification-log.jsonl"
  [ "$status" -eq 0 ]

  run_watchdog 1 30
  [ "$status" -eq 0 ]
  run jq -s -e 'length == 1' "$CONTROL_ROOT/.notification-log.jsonl"
  [ "$status" -eq 0 ]
}

@test "tmux watchdog: retries pending teardown without repeating a failed notification" {
  local tmux_bin marker
  tmux_bin=$(write_tmux_shim)
  marker="$TEST_ROOT/pane-present"
  : > "$marker"
  fixture_watchdog_bus
  plant_bound_agent test:0.1 '%1'
  chmod 500 "$CONTROL_ROOT"

  run env PATH="$tmux_bin:$PATH" LBWC_TEST_TMUX_MARKER="$marker" LBWC_TEST_TMUX_KILL_FAIL=1 bash "$SCRIPT" --control-root "$CONTROL_ROOT" check --orchestrator-id main-session --orchestrator-session-id main-session --orchestrator-capability "$MAIN_CAPABILITY" --stale-after-ms 1 --shutdown-timeout-ms 30
  chmod 700 "$CONTROL_ROOT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot append stale agent failure notification"* ]]
  run jq -e '.agents[] | select(.agent_id == "agent-a") | .state == "failed" and .watchdog_cleanup_pending == true' "$CONTROL_ROOT/.runtime/tmux-bus/registry.json"
  [ "$status" -eq 0 ]
  [ ! -e "$CONTROL_ROOT/.notification-log.jsonl" ]

  run env PATH="$tmux_bin:$PATH" LBWC_TEST_TMUX_MARKER="$marker" bash "$SCRIPT" --control-root "$CONTROL_ROOT" check --orchestrator-id main-session --orchestrator-session-id main-session --orchestrator-capability "$MAIN_CAPABILITY" --stale-after-ms 1 --shutdown-timeout-ms 30

  [ "$status" -eq 1 ]
  [ ! -e "$marker" ]
  run jq -e '.agents[] | select(.agent_id == "agent-a") | .state == "shutdown" and .watchdog_cleanup_pending == false' "$CONTROL_ROOT/.runtime/tmux-bus/registry.json"
  [ "$status" -eq 0 ]
  [ ! -e "$CONTROL_ROOT/.notification-log.jsonl" ]
}
