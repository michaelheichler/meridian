add_agent_entry() {
  local registry="$1" agent_id="$2" generated_name="$3" contract_id="$4" target="$5" pane_id="$6" capability_hash="$7"
  jq --arg id "$agent_id" --arg generated "$generated_name" --arg contract "$contract_id" --arg target "$target" --arg pane_id "$pane_id" --arg hash "$capability_hash" '
    .agents += [{agent_id: $id, parent_id: .main.agent_id, contract_id: $contract, generated_name: $generated, tmux_target: $target, tmux_pane_id: $pane_id, claude_session_id: null, capability_hash: $hash, state: "registered", heartbeat_at_ms: null}]
    | .routes[$id] = {inbox: $id, tmux_target: $target}' <<<"$registry"
}

prepare_agent_pane() {
  local orchestrator_target="$1" agent_id="$2" contract_id="$3" pane_id target
  pane_id=$(tmux split-window -e LBWC_TMUX_AGENT=1 -e "LBWC_TMUX_CONTROL_ROOT=$TMUX_RUNTIME_CONTROL_ROOT" -e "LBWC_TMUX_AGENT_ID=$agent_id" -e "LBWC_TMUX_CONTRACT_ID=$contract_id" -t "$orchestrator_target" -c "$PROJECT_ROOT" -P -F '#{pane_id}') || return 1
  [[ "$pane_id" =~ ^%[0-9]+$ ]] || return 1
  target=$(tmux display-message -p -t "$pane_id" '#{session_name}:#{window_index}.#{pane_index}') || { tmux kill-pane -t "$pane_id" >/dev/null 2>&1 || true; return 1; }
  if ! tmux select-pane -t "$pane_id" -T "$agent_id"; then
    tmux kill-pane -t "$pane_id" >/dev/null 2>&1 || true
    return 1
  fi
  jq -n --arg pane_id "$pane_id" --arg target "$target" '{pane_id: $pane_id, target: $target}'
}

launch_agent() {
  local orchestrator_target="$1" target="$2" generated_name="$3" command
  printf -v command 'exec claude --agent %q' "$generated_name"
  tmux send-keys -t "$target" "$command" C-m && tmux select-pane -t "$orchestrator_target"
}

rollback_split_group() {
  local original_registry="$1" original_routing="$2" pane_ids="$3" agent_ids="$4" pane_id agent_id
  while IFS= read -r agent_id; do
    [ -n "$agent_id" ] && write_teardown_intent "$agent_id" "$agent_id" prepared || true
  done <<<"$agent_ids"
  while IFS= read -r pane_id; do
    [ -n "$pane_id" ] && tmux kill-pane -t "$pane_id" >/dev/null 2>&1 || true
  done <<<"$pane_ids"
  while IFS= read -r agent_id; do
    [ -n "$agent_id" ] || continue
    rm -rf "$TMUX_RUNTIME_BUS_ROOT/inboxes/$agent_id"
    python3 "$TMUX_RUNTIME_HELPER" delete --root "$TMUX_RUNTIME_BUS_ROOT" --relative "credentials/$agent_id.json" >/dev/null 2>&1 || true
  done <<<"$agent_ids"
  tmux_runtime_atomic_json "$TMUX_RUNTIME_BUS_ROOT/registry.json" "$original_registry" >/dev/null 2>&1 || true
  tmux_runtime_atomic_json "$TMUX_RUNTIME_BUS_ROOT/routing-table.json" "$original_routing" >/dev/null 2>&1 || true
  while IFS= read -r agent_id; do
    [ -n "$agent_id" ] && clear_teardown_intent "$agent_id"
  done <<<"$agent_ids"
}

split_agent_definition() {
  local manifest_path manifest entry
  manifest_path=$(agent_manifest_path "$TMUX_RUNTIME_CONTROL_ROOT") || fail 'generated agent manifest is unavailable'
  [ -f "$manifest_path" ] && [ ! -L "$manifest_path" ] || fail 'generated agent manifest is missing'
  manifest=$(jq -ce 'select(type == "object" and (.agents | type == "object"))' "$manifest_path" 2>/dev/null) || fail 'generated agent manifest is malformed'
  entry=$(jq -ce --arg name "$agent_id" '.agents[$name] | select(type == "object")' <<<"$manifest" 2>/dev/null) || fail "generated agent is not registered: $agent_id"
  jq -cn --arg id "$agent_id" --arg generated "$generated_agent" \
    --arg contract_id "$(jq -r '.contract_id // empty' <<<"$entry")" \
    --arg contract_digest "$(jq -r '.contract_digest // empty' <<<"$entry")" \
    '[{agent_id:$id,generated_name:$generated,contract_id:$contract_id,contract_digest:$contract_digest}]'
}

# Reads split_group locals because the rollback arguments track live arrays.
abort_split_group() {
  rollback_split_group "$original_registry" "$original_routing" "$(printf '%s\n' "${created_pane_ids[@]}")" "$(printf '%s\n' "${created_agent_ids[@]}")"
}

split_group_preflight() {
  local definitions="$1"
  agent_manifest_with_lock "$TMUX_RUNTIME_CONTROL_ROOT" validate_split_group_definitions "$definitions" || fail "${SPLIT_VALIDATION_ERROR:-generated agent validation failed}"
  tmux_runtime_lock_acquire registry 5000 30000
  registry=$(tmux_runtime_registry_read)
  original_registry="$registry"
  original_routing=$(cat "$TMUX_RUNTIME_BUS_ROOT/routing-table.json")
  tmux_layout_config
  [ $(( $(jq '[.agents[] | select(.state != "shutdown")] | length' <<<"$registry") + $(jq 'length' <<<"$definitions") )) -le "$max_agents" ] || fail "tmux agent limit exceeded: $max_agents"
  current_session=$(jq -r '.tmux.session' <<<"$registry")
  [ "$session" = "$current_session" ] || fail 'session does not match registry'
  orchestrator_target=$(jq -r '.tmux.orchestrator_target' <<<"$registry")
  tmux_pane_exists "$orchestrator_target" || fail 'registered orchestrator pane does not exist'
}

split_member_identity() {
  local item="$1" value
  agent_id=$(jq -r '.agent_id' <<<"$item")
  generated=$(jq -r '.generated_name' <<<"$item")
  contract_id=$(jq -r '.contract_id' <<<"$item")
  for value in "$agent_id" "$generated" "$contract_id"; do tmux_runtime_valid_token "$value" || fail 'agent group contains an invalid identifier'; done
  jq -e --arg id "$agent_id" 'all(.agents[]; .agent_id != $id) and .main.agent_id != $id' <<<"$registry" >/dev/null || fail "agent is already registered: $agent_id"
}

split_member_credential() {
  capability=$(tmux_runtime_capability)
  hash=$(tmux_runtime_capability_hash "$capability")
  credential=$(jq -n --arg agent_id "$agent_id" --arg contract_id "$contract_id" --arg capability "$capability" '{agent_id:$agent_id,contract_id:$contract_id,capability:$capability}')
  tmux_runtime_atomic_json "$TMUX_RUNTIME_BUS_ROOT/credentials/$agent_id.json" "$credential" || {
    abort_split_group
    fail "cannot publish agent capability: $agent_id"
  }
  created_agent_ids+=("$agent_id")
}

split_member_pane() {
  prepared=$(prepare_agent_pane "$orchestrator_target" "$agent_id" "$contract_id") || {
    abort_split_group
    fail "cannot start generated agent: $agent_id"
  }
  pane_id=$(jq -r '.pane_id' <<<"$prepared") || {
    abort_split_group
    fail "cannot resolve generated agent pane identity: $agent_id"
  }
  target=$(jq -r '.target' <<<"$prepared") || {
    abort_split_group
    fail "cannot resolve generated agent target: $agent_id"
  }
  [[ "$pane_id" =~ ^%[0-9]+$ ]] && tmux_runtime_valid_target "$target" || {
    abort_split_group
    fail "generated agent pane identity is invalid: $agent_id"
  }
  created_pane_ids+=("$pane_id")
  created_generated_names+=("$generated")
  capabilities=$(jq --arg id "$agent_id" --arg capability "$capability" '. + [{agent_id: $id, capability: $capability}]' <<<"$capabilities")
}

split_member_register() {
  if ! tmux_runtime_initialize_inbox "$agent_id" || ! registry=$(add_agent_entry "$registry" "$agent_id" "$generated" "$contract_id" "$target" "$pane_id" "$hash"); then
    abort_split_group
    fail "cannot prepare generated agent runtime state"
  fi
}

split_group_launch() {
  local index
  if ! tmux_runtime_write_registry_route_bundle "$registry"; then
    abort_split_group
    fail 'cannot publish generated agent registry and routing table'
  fi
  for ((index = 0; index < ${#created_pane_ids[@]}; index++)); do
    launch_agent "$orchestrator_target" "${created_pane_ids[$index]}" "${created_generated_names[$index]}" || {
      abort_split_group
      fail "cannot launch generated agent: ${created_agent_ids[$index]}"
    }
  done
  if ! apply_tmux_layout "$current_session"; then
    abort_split_group
    fail 'cannot arrange generated agent panes'
  fi
  tmux_runtime_lock_release registry
  jq -n --argjson agents "$capabilities" '{state: "registered", agents: $agents}'
}

split_group() {
  local definitions="$1" registry original_registry original_routing orchestrator_target current_session item agent_id generated contract_id prepared target pane_id capability hash credential created_pane_ids=() created_agent_ids=() created_generated_names=() capabilities='[]'
  split_group_preflight "$definitions"
  while IFS= read -r item; do
    split_member_identity "$item"
    split_member_credential
    split_member_pane
    split_member_register
  done < <(jq -c '.[]' <<<"$definitions")
  split_group_launch
}

split_agent() {
  local definitions
  [ -n "$agent_id" ] || fail '--name is required for split-agent'
  [ -n "$generated_agent" ] || fail '--agent is required for split-agent'
  [ "$agent_id" = "$generated_agent" ] || fail 'agent and generated identities must match'
  definitions=$(split_agent_definition) || fail 'cannot resolve generated agent manifest identity'
  split_group "$definitions"
}
