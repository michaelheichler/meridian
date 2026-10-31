teardown_intent_path() {
  printf '%s/transactions/teardown-%s.json\n' "$TMUX_RUNTIME_BUS_ROOT" "$1"
}

write_teardown_intent() {
  local name="$1" target="$2" state="$3" path
  path=$(teardown_intent_path "$name")
  tmux_runtime_atomic_json "$path" "$(jq -n --arg target "$target" --arg state "$state" --argjson updated_at "$(tmux_runtime_now_ms)" '{schema_version: 1, kind: "teardown", target: $target, state: $state, updated_at: $updated_at}')"
}

teardown_process_stopped() {
  local name="$1" target="$2" path
  path=$(teardown_intent_path "$name")
  tmux_runtime_private_file "$path" || return 1
  jq -e --arg target "$target" '.schema_version == 1 and .kind == "teardown" and .target == $target and .state == "process_stopped"' "$path" >/dev/null 2>&1
}

clear_teardown_intent() {
  rm -f "$(teardown_intent_path "$1")"
}

persist_shutdown_agents() {
  local registry="$1" agent_ids="$2" updated agent_id
  updated=$(jq --argjson agent_ids "$agent_ids" '
    .main.agent_id as $main_id
    | .agents |= map(if (.agent_id as $agent_id | $agent_ids | index($agent_id)) then .state = "shutdown" | .tmux_pane_id = null else . end)
    | .routes |= with_entries(.key as $agent_id | select($agent_id == $main_id or ($agent_ids | index($agent_id) | not)))
  ' <<<"$registry") || return 1
  tmux_runtime_write_registry_route_bundle "$updated" || return 1
  while IFS= read -r agent_id; do
    [ -n "$agent_id" ] || continue
    rm -rf "$(tmux_runtime_inbox "$agent_id")" || return 1
  done < <(jq -r '.[]' <<<"$agent_ids")
}

focus_orchestrator() {
  local registry target
  require_main_orchestrator
  registry=$(tmux_runtime_registry_read)
  target=$(jq -r '.tmux.orchestrator_target' <<<"$registry")
  tmux_pane_exists "$target" || fail 'registered orchestrator pane does not exist'
  tmux select-pane -t "$target" || fail 'cannot focus orchestrator pane'
  jq -n --arg target "$target" '{orchestrator_target: $target}'
}

kill_agent() {
  local registry agent_state pane_id remaining_pane_id agent_id
  require_main_orchestrator
  tmux_runtime_lock_acquire registry 5000 30000
  registry=$(tmux_runtime_registry_read)
  agent_state=$(jq -r --arg target "$target" '.agents[] | select(.tmux_target == $target) | .state' <<<"$registry")
  agent_id=$(jq -r --arg target "$target" '.agents[] | select(.tmux_target == $target) | .agent_id' <<<"$registry")
  [ -n "$agent_state" ] || fail 'active agent target is not registered'
  pane_id=$(jq -r --arg target "$target" '.agents[] | select(.tmux_target == $target) | .tmux_pane_id' <<<"$registry")
  if [ "$pane_id" = null ]; then
    [ "$agent_state" = shutdown ] || fail 'registered agent pane identity is invalid'
    tmux_runtime_lock_release registry
    jq -n --arg target "$target" '{tmux_target: $target, state: "shutdown"}'
    return 0
  fi
  [[ "$pane_id" =~ ^%[0-9]+$ ]] || fail 'registered agent pane identity is invalid'
  write_teardown_intent "$agent_id" "$target" prepared || fail 'cannot persist agent teardown intent'
  if tmux_pane_exists "$pane_id"; then
    tmux kill-pane -t "$pane_id" || fail 'cannot kill owned agent pane'
    remaining_pane_id=$(tmux display-message -p -t "$pane_id" '#{pane_id}' 2>/dev/null || true)
    [ "$remaining_pane_id" != "$pane_id" ] || fail 'owned agent pane remains after kill request'
    write_teardown_intent "$agent_id" "$target" process_stopped || fail 'cannot persist stopped agent teardown intent'
  else
    write_teardown_intent "$agent_id" "$target" process_stopped || fail 'cannot persist absent agent shutdown state'
  fi
  persist_shutdown_agents "$registry" "$(jq -n --arg agent_id "$agent_id" '[ $agent_id ]')" || fail 'cannot persist agent shutdown state; retry to finalize teardown'
  clear_teardown_intent "$agent_id"
  tmux_runtime_lock_release registry
  jq -n --arg target "$target" '{tmux_target: $target, state: "shutdown"}'
}

stop_owned_session() {
  local registry="$1" session_name="$2" intent_name="$3" ownership marker
  ownership=$(jq -r '.tmux.ownership_token' <<<"$registry")
  marker=$(tmux show-options -v -t "$session_name" @lbwc_ownership_token 2>/dev/null || true)
  [ "$marker" = "$ownership" ] || fail 'owned tmux session is missing its provisioning ownership marker'
  tmux kill-session -t "$session_name" || fail 'cannot kill owned tmux session'
  tmux_session_exists "$session_name" && fail 'owned tmux session remains after kill request'
  write_teardown_intent "$intent_name" "$session_name" process_stopped || fail 'cannot persist stopped session teardown intent'
}

snapshot_external_agents() {
  local registry="$1" out_agents="$2" agent agent_id agent_target agent_pane_id snapshot_list='[]'
  while IFS= read -r agent; do
    agent_id=$(jq -r '.agent_id' <<<"$agent")
    agent_target=$(jq -r '.tmux_target' <<<"$agent")
    agent_pane_id=$(jq -r '.tmux_pane_id' <<<"$agent")
    [ -n "$agent_target" ] || fail 'registered external agent target is unavailable'
    [[ "$agent_pane_id" =~ ^%[0-9]+$ ]] || fail 'registered external agent pane identity is invalid'
    if tmux_pane_exists "$agent_pane_id"; then
      write_teardown_intent "$agent_id" "$agent_target" prepared || fail 'cannot persist external agent teardown intent'
      snapshot_list=$(jq --arg agent_id "$agent_id" --arg target "$agent_target" --arg pane_id "$agent_pane_id" '. + [{agent_id:$agent_id,tmux_target:$target,pane_id:$pane_id}]' <<<"$snapshot_list") || fail 'cannot snapshot external agent teardown'
    else
      write_teardown_intent "$agent_id" "$agent_target" prepared || fail 'cannot persist absent external agent teardown intent'
      write_teardown_intent "$agent_id" "$agent_target" process_stopped || fail 'cannot persist absent external agent shutdown state'
    fi
  done < <(jq -c '.agents[] | select(.state != "shutdown") | {agent_id, tmux_target, tmux_pane_id}' <<<"$registry")
  printf -v "$out_agents" '%s' "$snapshot_list"
}

stop_external_agents() {
  local active_agents="$1" snapshot_agent agent_id agent_target agent_pane_id
  while IFS= read -r snapshot_agent; do
    agent_id=$(jq -r '.agent_id' <<<"$snapshot_agent")
    agent_target=$(jq -r '.tmux_target' <<<"$snapshot_agent")
    agent_pane_id=$(jq -r '.pane_id' <<<"$snapshot_agent")
    if tmux_pane_exists "$agent_pane_id"; then
      tmux kill-pane -t "$agent_pane_id" || fail 'cannot kill owned agent pane in external session'
      tmux_pane_exists "$agent_pane_id" && fail 'owned agent pane remains in external session'
    fi
    write_teardown_intent "$agent_id" "$agent_target" process_stopped || fail 'cannot persist stopped external agent teardown intent'
  done < <(jq -c '.[]' <<<"$active_agents")
}

stop_external_session() {
  local registry="$1" active_agent_ids="$2" intent_name="$3" active_agents agent_id
  snapshot_external_agents "$registry" active_agents
  stop_external_agents "$active_agents"
  persist_shutdown_agents "$registry" "$active_agent_ids" || fail 'cannot persist session shutdown state; retry to finalize teardown'
  while IFS= read -r agent_id; do
    [ -n "$agent_id" ] && clear_teardown_intent "$agent_id"
  done < <(jq -r '.[]' <<<"$active_agent_ids")
  clear_teardown_intent "$intent_name"
  tmux_runtime_lock_release registry
  jq -n '{state: "agents_shutdown", external_session_preserved: true}'
}

kill_session() {
  local registry registered_session managed active_agent_ids intent_name='session'
  require_main_orchestrator
  tmux_runtime_lock_acquire registry 5000 30000
  registry=$(tmux_runtime_registry_read)
  registered_session=$(jq -r '.tmux.session' <<<"$registry")
  [ "$session" = "$registered_session" ] || fail 'session does not match registry'
  managed=$(jq -r '.tmux.managed_session' <<<"$registry")
  active_agent_ids=$(jq -c '[.agents[] | select(.state != "shutdown") | .agent_id]' <<<"$registry")
  write_teardown_intent "$intent_name" "$session" prepared || fail 'cannot persist session teardown intent'
  if [ "$managed" = true ] && tmux_session_exists "$session"; then
    stop_owned_session "$registry" "$session" "$intent_name"
  elif [ "$managed" = true ]; then
    teardown_process_stopped "$intent_name" "$session" || fail 'owned tmux session is unavailable; refusing false shutdown'
  elif [ "$managed" = false ]; then
    stop_external_session "$registry" "$active_agent_ids" "$intent_name"
    return 0
  fi
  persist_shutdown_agents "$registry" "$(jq -c '[.agents[].agent_id]' <<<"$registry")" || fail 'cannot persist session shutdown state; retry to finalize teardown'
  clear_teardown_intent "$intent_name"
  tmux_runtime_lock_release registry
  jq -n '{state: "shutdown", external_session_preserved: false}'
}

rollback() {
  local registry
  [ -n "$run_id" ] || fail '--run-id is required for rollback'
  tmux_runtime_valid_token "$run_id" || fail 'run id is invalid'
  require_main_orchestrator
  registry=$(tmux_runtime_registry_read)
  session=$(jq -r '.tmux.session // empty' <<<"$registry")
  if [ -z "$session" ]; then
    jq -n --arg run_id "$run_id" '{state: "rolled_back", run_id: $run_id, tmux_session: null}'
    return 0
  fi
  kill_session
}

status() {
  local registry
  require_main_orchestrator
  registry=$(tmux_runtime_registry_read)
  jq '.' <<<"$registry"
}
