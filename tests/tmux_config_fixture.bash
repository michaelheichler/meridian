config_test_repo() {
  unset MERIDIAN_CONTROL_ROOT MERIDIAN_PLANNING_DIR
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
  CONTROL_ROOT="$PROJECT_ROOT/.meridian"
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
  if [ "$outcome" = resolution ]; then
    config_client_resolution
    return
  fi
  definitions=$(prepare_tmux_agents worker-a worker-b worker-c)
  definitions=$(jq --argjson count "$count" '.[:$count]' <<<"$definitions")
  before=$(bus_state_digest)
  if [ "$outcome" = rollback ]; then
    config_layout_rollback
    return
  fi
  config_policy_split
}

config_policy_split() {
  export MERIDIAN_TEST_FOCUS_LOG="$TEST_ROOT/focus.log"
  : > "$MERIDIAN_TEST_FOCUS_LOG"
  split_group "$SESSION" "$definitions"
  [ "$status" -eq 0 ]
  config_policy_focus "$policy"
  unset MERIDIAN_TEST_FOCUS_LOG
}

config_client_resolution() {
  local pane command result="$TEST_ROOT/client-resolution"
  pane=$(env TMUX_TMPDIR="$TMUX_TMPDIR" "$BIN_DIR/tmux" split-window -d -t "$SESSION" -P -F '#{pane_id}')
  printf -v command 'command -v claude > %q' "$result"
  tmux_on_test_server send-keys -t "$pane" "$command" C-m
  wait_for_result "$result"
  [ "$(cat "$result")" = "$BIN_DIR/claude" ]
}

config_layout_rollback() {
  export MERIDIAN_TEST_FAIL_PANE_LAYOUT=1
  split_group "$SESSION" "$definitions"
  unset MERIDIAN_TEST_FAIL_PANE_LAYOUT
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
    jq -s -e 'length > 0 and all(.[]; .active == .target and .aligned)' "$MERIDIAN_TEST_FOCUS_LOG"
    widths=$(tmux_on_test_server list-panes -t "$SESSION" -F '#{pane_top} #{pane_width}')
    awk 'NR == 1 {top=$1; width=$2} $1 != top || $2 < width-1 || $2 > width+1 {exit 1}' <<<"$widths"
  else
    expected=$(tmux_on_test_server display-message -p -t "$(jq -r '.tmux.orchestrator_target' "$(registry_file)")" '#{pane_id}')
    [ "$active" = "$expected" ]
    jq -s -e --arg expected "$expected" 'length > 0 and all(.[]; .active == $expected)' "$MERIDIAN_TEST_FOCUS_LOG"
  fi
}

config_bound_agent() {
  local target pane
  provision_main
  SESSION=$(provisioned_session)
  source "$REPO_ROOT/scripts/lib/meridian-control-root.sh"
  source "$REPO_ROOT/scripts/lib/tmux-runtime.sh"
  tmux_runtime_configure "$CONTROL_ROOT"
  pane=$(tmux_on_test_server split-window -d -t "$SESSION" -P -F '#{pane_id}' \
    /usr/bin/env "PATH=$MERIDIAN_TEST_CHILD_PATH" "$MERIDIAN_TEST_CHILD_SHELL" --noprofile --norc -c 'exec tail -f /dev/null')
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
    run bash -c '. "$1/scripts/lib/meridian-config-files.sh"; . "$1/scripts/lib/tmux-heartbeat-settings.sh"; tmux_heartbeat_settings "$2" && printf "%s %s\n" "$TMUX_HEARTBEAT_INTERVAL" "$TMUX_HEARTBEAT_STALE_MS"' _ "$REPO_ROOT" "$CONTROL_ROOT"
    [ "$status" -eq 0 ]
    [ "$output" = '30 90000' ]
    return
  fi
  jq -n --argjson interval "$interval" --arg policy "$threshold" '{agent_execution_mode:"tmux",tmux_execution:{heartbeat_interval_seconds:$interval}} | if $policy == "keep" then .tmux_execution.cleanup_policy="keep_panes" else . end' > "$CONTROL_ROOT/config.json"
  if [ "$threshold" = configured ]; then
    jq '.tmux_execution.heartbeat_stale_seconds = 2' "$CONTROL_ROOT/config.json" > "$TEST_ROOT/config.json"
    mv "$TEST_ROOT/config.json" "$CONTROL_ROOT/config.json"
    threshold=none
  fi
  config_bound_agent
  case "$kind" in
    live) config_live_sender "$state" ;;
    terminal) config_terminal_sender "$state" ;;
    process) config_process_sender "$state" ;;
    stale) config_stale_sender "$threshold" ;;
  esac
}

config_stale_sender() {
  config_agent_update ".agents[0].heartbeat_at_ms = $(($(date +%s) * 1000 - 5000))"
  config_watchdog "$1"
  [ "$status" -eq 1 ]
  jq -e '.stale_agents == ["agent-a"]' <<<"$output"
  jq -e '.agents[0].state == "shutdown" and .agents[0].watchdog_failure_reported_at_ms > 0 and (.routes | has("agent-a") | not)' "$(registry_file)"
  [ "$(pane_count "$SESSION")" = 1 ]
}

config_wait_periodic_heartbeat() {
  local initial deadline=$((SECONDS + 8))
  initial=$(jq -r '.agents[] | select(.agent_id == "worker-a") | .heartbeat_at_ms' "$(registry_file)")
  until jq -e --argjson initial "$initial" '.agents[] | select(.agent_id == "worker-a") | .heartbeat_at_ms > $initial' "$(registry_file)" >/dev/null; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.05
  done
}

config_process_sender() {
  env TMUX_TMPDIR="$TMUX_TMPDIR" python3 "$REPO_ROOT/tests/heartbeat_process_fixture.py" "$1" "$REPO_ROOT" "$CONTROL_ROOT" "$TEST_ROOT" "$BIN_DIR" "$TEST_ROOT/capability" "$MAIN_CAPABILITY"
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
