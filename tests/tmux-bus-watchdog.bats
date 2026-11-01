#!/usr/bin/env bats

load tmux_watchdog_fixture
load gate_case_helper
load gate_case_files

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/tmux-bus-watchdog.sh"
  unset TMUX TMUX_PANE
  TEST_ROOT="$(mktemp -d)"
  TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
  reset_case_failures
}

teardown() {
  [ ! -d "${CONTROL_ROOT:-}" ] || chmod 700 "$CONTROL_ROOT"
  rm -rf "$TEST_ROOT"
}

new_row() {
  CONTROL_ROOT="$TEST_ROOT/rows/$1/project/.lbwc-planning"
  mkdir -p "$CONTROL_ROOT"
  printf '%s\n' '{}' > "$CONTROL_ROOT/config.json"
}

run_watchdog() {
  run bash "$SCRIPT" --control-root "$CONTROL_ROOT" check --orchestrator-id main-session --orchestrator-session-id main-session --orchestrator-capability "$MAIN_CAPABILITY" --stale-after-ms "$1" --shutdown-timeout-ms "$2"
}

run_watchdog_with_tmux() {
  local tmux_bin=$1 marker=$2 kill_fail=$3
  run timeout 60 env PATH="$tmux_bin:$PATH" LBWC_TEST_TMUX_MARKER="$marker" LBWC_TEST_TMUX_KILL_FAIL="$kill_fail" bash "$SCRIPT" --control-root "$CONTROL_ROOT" check --orchestrator-id main-session --orchestrator-session-id main-session --orchestrator-capability "$MAIN_CAPABILITY" --stale-after-ms 1 --shutdown-timeout-ms 30
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

write_empty_display_shim() {
  local tmux_bin="$TEST_ROOT/empty-display-bin"
  mkdir -p "$tmux_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'case "$1" in display-message) exit 0 ;; *) exit 1 ;; esac' > "$tmux_bin/tmux"
  chmod +x "$tmux_bin/tmux"
  printf '%s\n' "$tmux_bin"
}

expect_agent() {
  expect_jq "$1" "$CONTROL_ROOT/.runtime/tmux-bus/registry.json" ".agents[] | select(.agent_id == \"agent-a\") | $2"
}

expect_notifications() {
  local label=$1 filter=$2
  jq -s -e "$filter" "$CONTROL_ROOT/.notification-log.jsonl" >/dev/null 2>&1 \
    || record_case_failure "$label" "notification log failed filter=[$filter]"
}

@test "tmux watchdog check fails closed on a malformed registry and reports stale agents exactly once" {
  local result

  new_row malformed-registry
  mkdir -p "$CONTROL_ROOT/.runtime/tmux-bus"
  printf '{not valid json\n' > "$CONTROL_ROOT/.runtime/tmux-bus/registry.json"
  MAIN_CAPABILITY=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
  run_watchdog 120000 5000
  [ "$status" -ne 0 ] || record_case_failure malformed-registry "status=$status"
  [ "$output" = "tmux-watchdog: runtime registry is malformed" ] \
    || record_case_failure malformed-registry "output=$output"

  new_row stale-agent
  fixture_watchdog_bus
  plant_bound_agent missing:0.1 ''
  expect_jq stale-agent-planted "$CONTROL_ROOT/.runtime/tmux-bus/registry.json" '.agents | length == 1'
  run_watchdog 120000 5000
  expect_status stale-agent 1
  expect_agent stale-agent-shutdown '.state == "shutdown"'
  expect_jq stale-agent-error-envelope "$CONTROL_ROOT/.runtime/tmux-bus/inboxes/main-session/error.json" \
    '.type == "error" and .from.role == "orchestrator" and .to.agent_id == "main-session" and (.body.message | contains("agent-a"))'
  expect_notifications stale-agent-notification \
    'length == 1 and .[0].type == "tmux_watchdog_stale_agents_failed" and .[0].title == "TMUX watchdog failed stale agents" and (.[0].message | contains("agent-a"))'
  run_watchdog 120000 5000
  expect_status stale-agent-second-check 0
  expect_notifications stale-agent-second-check 'length == 1'

  new_row concurrent-checks
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
  expect_status concurrent-checks 0
  expect_notifications concurrent-checks-notify-once 'length == 1 and .[0].type == "tmux_watchdog_stale_agents_failed"'
  expect_agent concurrent-checks-shutdown '.state == "shutdown"'

  new_row busy-error-inbox
  fixture_watchdog_bus
  plant_bound_agent missing:0.1 ''
  run bash "$REPO_ROOT/scripts/tmux-bus.sh" --control-root "$CONTROL_ROOT" publish --to main-session --from-agent-id main-session --from-session-id main-session --from-role orchestrator --capability "$MAIN_CAPABILITY" --type error --correlation-id occupied --payload '{"message":"occupied"}'
  expect_status busy-error-inbox-occupied 0
  run_watchdog 1 30
  expect_case busy-error-inbox 1 "cannot publish stale agent error envelope"
  expect_agent busy-error-inbox-teardown '.state == "shutdown" and .watchdog_cleanup_pending == false'
  expect_notifications busy-error-inbox-notification 'length == 1 and .[0].type == "tmux_watchdog_stale_agents_failed"'
  run_watchdog 1 30
  expect_status busy-error-inbox-second-check 0
  expect_notifications busy-error-inbox-no-retry 'length == 1'

  assert_no_case_failures
}

@test "tmux watchdog check shuts stale panes down gracefully, by force, or when tmux reports them gone, and retries pending teardown" {
  local tmux_bin marker output_file

  tmux_bin=$(write_tmux_shim)
  marker="$TEST_ROOT/pane-present"

  new_row graceful-ack
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
  expect_status graceful-ack 0
  expect_no_path graceful-ack-pane-gone "$marker"
  expect_agent graceful-ack-shutdown '.state == "shutdown"'

  new_row forced-kill
  : > "$marker"
  fixture_watchdog_bus
  plant_bound_agent test:0.1 '%1'
  run_watchdog_with_tmux "$tmux_bin" "$marker" 0
  expect_status forced-kill 1
  expect_no_path forced-kill-pane-gone "$marker"
  expect_agent forced-kill-shutdown '.state == "shutdown"'

  new_row empty-display-output
  fixture_watchdog_bus
  plant_bound_agent test:0.1 '%1'
  run_watchdog_with_tmux "$(write_empty_display_shim)" "$marker" 0
  expect_status empty-display-output 1
  expect_agent empty-display-output-shutdown '.state == "shutdown"'

  new_row pending-teardown
  : > "$marker"
  fixture_watchdog_bus
  plant_bound_agent test:0.1 '%1'
  chmod 500 "$CONTROL_ROOT"
  run env PATH="$tmux_bin:$PATH" LBWC_TEST_TMUX_MARKER="$marker" LBWC_TEST_TMUX_KILL_FAIL=1 bash "$SCRIPT" --control-root "$CONTROL_ROOT" check --orchestrator-id main-session --orchestrator-session-id main-session --orchestrator-capability "$MAIN_CAPABILITY" --stale-after-ms 1 --shutdown-timeout-ms 30
  chmod 700 "$CONTROL_ROOT"
  expect_case pending-teardown 1 "cannot append stale agent failure notification"
  expect_agent pending-teardown-failed '.state == "failed" and .watchdog_cleanup_pending == true'
  expect_no_path pending-teardown-no-notification "$CONTROL_ROOT/.notification-log.jsonl"
  run env PATH="$tmux_bin:$PATH" LBWC_TEST_TMUX_MARKER="$marker" bash "$SCRIPT" --control-root "$CONTROL_ROOT" check --orchestrator-id main-session --orchestrator-session-id main-session --orchestrator-capability "$MAIN_CAPABILITY" --stale-after-ms 1 --shutdown-timeout-ms 30
  expect_status pending-teardown-retry 1
  expect_no_path pending-teardown-retry-pane-gone "$marker"
  expect_agent pending-teardown-retry-shutdown '.state == "shutdown" and .watchdog_cleanup_pending == false'
  expect_no_path pending-teardown-retry-no-notification "$CONTROL_ROOT/.notification-log.jsonl"

  assert_no_case_failures
}
