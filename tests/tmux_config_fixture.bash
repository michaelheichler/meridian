config_test_repo() {
  unset LBWC_CONTROL_ROOT LBWC_PLANNING_DIR
  git init -q "$TEST_ROOT"
  await_git_ai
  cd "$TEST_ROOT"
}

run_config_rows() {
  local kind=$1 label row
  reset_case_failures
  while IFS='|' read -r label row; do
    [ -n "$label" ] || continue
    run config_row "$kind" "$row"
    expect_case "$label" 0
  done
  assert_no_case_failures
}

config_row() (
  set -e
  local kind=$1 row=$2
  trap 'clear_failures; tmux_on_test_server kill-server >/dev/null 2>&1 || true' EXIT
  reset_world
  "config_${kind}_row" "$row"
)

config_name_row() {
  local prefix basename expected override name session
  IFS=';' read -r prefix basename expected override <<<"$1"
  PROJECT_ROOT="$TEST_ROOT/$basename"
  CONTROL_ROOT="$PROJECT_ROOT/.lbwc-planning"
  mkdir -p "$CONTROL_ROOT"
  jq -n --arg prefix "$prefix" 'if $prefix == "missing" then {} else {tmux_execution:{session_name_prefix:$prefix}} end' > "$CONTROL_ROOT/config.json"
  if [ "$override" != none ]; then
    name=$(bash "$REPO_ROOT/scripts/tmux-session-name.sh" --project-root "$PROJECT_ROOT" --main-id main-session --prefix "$override")
    [[ "$name" == "$override-"* ]]
  fi
  name=$(bash "$REPO_ROOT/scripts/tmux-session-name.sh" --project-root "$PROJECT_ROOT" --main-id 'main:session')
  [[ "$name" == "$expected-"* ]]
  [[ "$name" != *.* && "$name" != *:* ]]
  provision_main
  session=$(provisioned_session)
  [[ "$session" == "$expected-"* ]]
  tmux_on_test_server has-session -t "=$session"
  run_orchestrator kill-session --project-root "$PROJECT_ROOT" --control-root "$CONTROL_ROOT" --session "$session"
  [ "$status" -eq 0 ]
  run tmux_on_test_server has-session -t "=$session"
  [ "$status" -ne 0 ]
}

config_policy_row() {
  local policy count outcome config before definitions
  IFS=';' read -r policy count outcome <<<"$1"
  config=$(jq -cn --arg policy "$policy" '{tmux_execution:{layout:"even-horizontal"}} | if $policy == "missing" then . else .tmux_execution.attach_policy = $policy end')
  printf '%s\n' "$config" > "$CONTROL_ROOT/config.json"
  if [ "$outcome" = reject ]; then
    provision_attempt
    [ "$status" -ne 0 ]
    run tmux_on_test_server list-panes -a
    [ "$status" -ne 0 ]
    return
  fi
  provision_main
  SESSION=$(provisioned_session)
  definitions=$(prepare_tmux_agents worker-a worker-b worker-c)
  definitions=$(jq --argjson count "$count" '.[:$count]' <<<"$definitions")
  before=$(bus_state_digest)
  if [ "$outcome" = rollback ]; then
    config_layout_rollback
    return
  fi
  export LBWC_TEST_FOCUS_LOG="$TEST_ROOT/focus.log"
  : > "$LBWC_TEST_FOCUS_LOG"
  split_group "$SESSION" "$definitions"
  [ "$status" -eq 0 ]
  config_policy_focus "$policy"
  unset LBWC_TEST_FOCUS_LOG
}

config_layout_rollback() {
  export LBWC_TEST_FAIL_PANE_LAYOUT=1
  split_group "$SESSION" "$definitions"
  unset LBWC_TEST_FAIL_PANE_LAYOUT
  [ "$status" -ne 0 ]
  [ "$(pane_count "$SESSION")" = 1 ]
  [ "$(bus_state_digest)" = "$before" ]
  [ -z "$(find "$CONTROL_ROOT/.runtime/tmux-bus/transactions" -type f -print)" ]
  [ ! -e "$CONTROL_ROOT/.runtime/tmux-bus/inboxes/worker-a" ]
  [ ! -e "$CONTROL_ROOT/.runtime/tmux-bus/credentials/worker-a.json" ]
}

config_policy_focus() {
  local policy=$1 expected active widths
  active=$(tmux_on_test_server display-message -p -t "$SESSION" '#{pane_id}')
  if [ "$policy" = visible_grid ]; then
    expected=$(jq -r '.agents[-1].tmux_pane_id' "$(registry_file)")
    [ "$active" = "$expected" ]
    jq -s -e 'length > 0 and all(.[]; .active == .target and .aligned)' "$LBWC_TEST_FOCUS_LOG"
    widths=$(tmux_on_test_server list-panes -t "$SESSION" -F '#{pane_top} #{pane_width}')
    awk 'NR == 1 {top=$1; width=$2} $1 != top || $2 < width-1 || $2 > width+1 {exit 1}' <<<"$widths"
  else
    expected=$(tmux_on_test_server display-message -p -t "$(jq -r '.tmux.orchestrator_target' "$(registry_file)")" '#{pane_id}')
    [ "$active" = "$expected" ]
    jq -s -e --arg expected "$expected" 'length > 0 and all(.[]; .active == $expected)' "$LBWC_TEST_FOCUS_LOG"
  fi
}

config_bound_agent() {
  local target pane
  provision_main
  SESSION=$(provisioned_session)
  source "$REPO_ROOT/scripts/lib/lbwc-control-root.sh"
  source "$REPO_ROOT/scripts/lib/tmux-runtime.sh"
  tmux_runtime_configure "$CONTROL_ROOT"
  pane=$(tmux_on_test_server split-window -d -t "$SESSION" -P -F '#{pane_id}' 'tail -f /dev/null')
  target=$(tmux_on_test_server display-message -p -t "$pane" '#{session_name}:#{window_index}.#{pane_index}')
  plant_bound_agent "$target" "$pane"
  printf '%s\n' "$AGENT_CAPABILITY" > "$TEST_ROOT/capability"
}

config_agent_update() {
  local updated
  updated=$(jq "$1" "$(registry_file)")
  tmux_runtime_write_registry_route_bundle "$updated"
}

config_sender() {
  exec timeout 12 env PATH="$BIN_DIR:$PATH" TMUX_TMPDIR="$TMUX_TMPDIR" bash "$REPO_ROOT/scripts/tmux-agent-heartbeat.sh" "$CONTROL_ROOT" agent-a agent-session < "$TEST_ROOT/capability"
}

config_wait_heartbeat() {
  local deadline=$((SECONDS + 10))
  until jq -e '.agents[0].heartbeat_at_ms > 1' "$(registry_file)" >/dev/null &&
    [ -f "$CONTROL_ROOT/.runtime/tmux-bus/inboxes/main-session/heartbeat.agent-a.json" ]; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.1
  done
}

config_heartbeat_row() {
  local kind interval threshold state
  IFS=';' read -r kind interval threshold state <<<"$1"
  if [ "$kind" = defaults ]; then
    run bash -c '. "$1/scripts/lib/lbwc-config-files.sh"; . "$1/scripts/lib/tmux-heartbeat-settings.sh"; tmux_heartbeat_settings "$2" && printf "%s %s\n" "$TMUX_HEARTBEAT_INTERVAL" "$TMUX_HEARTBEAT_STALE_MS"' _ "$REPO_ROOT" "$CONTROL_ROOT"
    [ "$status" -eq 0 ]
    [ "$output" = '30 90000' ]
    return
  fi
  jq -n --argjson interval "$interval" '{agent_execution_mode:"tmux",tmux_execution:{heartbeat_interval_seconds:$interval}}' > "$CONTROL_ROOT/config.json"
  if [ "$threshold" = configured ]; then
    jq '.tmux_execution.heartbeat_stale_seconds = 2' "$CONTROL_ROOT/config.json" > "$TEST_ROOT/config.json"
    mv "$TEST_ROOT/config.json" "$CONTROL_ROOT/config.json"
    threshold=none
  fi
  config_bound_agent
  case "$kind" in
    live) config_live_sender "$state" ;;
    terminal) config_terminal_sender "$state" ;;
    stale)
      config_agent_update ".agents[0].heartbeat_at_ms = $(($(date +%s) * 1000 - 5000))"
      config_watchdog "$threshold"
      [ "$status" -eq 1 ]
      jq -e '.stale_agents == ["agent-a"]' <<<"$output"
      jq -e '.agents[0].state == "shutdown" and .agents[0].watchdog_failure_reported_at_ms > 0 and (.routes | has("agent-a") | not)' "$(registry_file)"
      [ "$(pane_count "$SESSION")" = 1 ]
      ;;
  esac
}

config_live_sender() {
  local state=$1
  config_agent_update ".agents[0].state = \"$state\""
  config_sender > "$TEST_ROOT/sender.log" 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &
  printf -v CONFIG_SENDER_PID '%s' "$!"
  trap 'kill "$CONFIG_SENDER_PID" 2>/dev/null || true; wait "$CONFIG_SENDER_PID" 2>/dev/null || true; clear_failures; tmux_on_test_server kill-server >/dev/null 2>&1 || true' EXIT
  config_wait_heartbeat
  jq -e --arg state "$state" '.agents[0].state == $state and .agents[0].heartbeat_at_ms > 1' "$(registry_file)"
  jq -e --arg state "$state" '.type == "heartbeat" and .from.agent_id == "agent-a" and .body.state == $state' "$CONTROL_ROOT/.runtime/tmux-bus/inboxes/main-session/heartbeat.agent-a.json"
}

config_terminal_sender() {
  local state=$1 before pane
  case "$state" in
    rebound) config_agent_update '.agents[0].claude_session_id = "replacement-session"' ;;
    shutdown) config_agent_update '.agents[0].state = "shutdown" | del(.routes["agent-a"])' ;;
    absent) pane=$(jq -r '.agents[0].tmux_pane_id' "$(registry_file)"); tmux_on_test_server kill-pane -t "$pane" ;;
    *) config_agent_update ".agents[0].state = \"$state\"" ;;
  esac
  before=$(bus_state_digest)
  run config_sender
  [ "$status" -eq 0 ]
  [ "$(bus_state_digest)" = "$before" ]
  [ ! -e "$CONTROL_ROOT/.runtime/tmux-bus/inboxes/main-session/heartbeat.agent-a.json" ]
}

config_watchdog() {
  local threshold=$1 args=()
  [ "$threshold" = none ] || args=(--stale-after-ms "$threshold")
  run env PATH="$BIN_DIR:$PATH" TMUX_TMPDIR="$TMUX_TMPDIR" bash "$REPO_ROOT/scripts/tmux-bus-watchdog.sh" --control-root "$CONTROL_ROOT" check --orchestrator-id main-session --orchestrator-session-id main-session --orchestrator-capability "$MAIN_CAPABILITY" --shutdown-timeout-ms 1000 ${args[@]+"${args[@]}"}
}
