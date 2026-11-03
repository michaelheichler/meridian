add_agent_entry() {
  local registry="$1" agent_id="$2" generated_name="$3" contract_id="$4" target="$5" pane_id="$6" capability_hash="$7"
  jq --arg id "$agent_id" --arg generated "$generated_name" --arg contract "$contract_id" --arg target "$target" --arg pane_id "$pane_id" --arg hash "$capability_hash" '
    .agents += [{agent_id: $id, parent_id: .main.agent_id, contract_id: $contract, generated_name: $generated, tmux_target: $target, tmux_pane_id: $pane_id, claude_session_id: null, capability_hash: $hash, state: "registered", heartbeat_at_ms: null}]
    | .routes[$id] = {inbox: $id, tmux_target: $target}' <<<"$registry"
}

prepare_agent_pane() {
  local orchestrator_target="$1" agent_id="$2" contract_id="$3" pane_id target worker_directory
  worker_directory=$(tmux_worker_directory "$agent_id") || return 1
  pane_id=$(tmux split-window -e LBWC_TMUX_AGENT=1 -e "LBWC_TMUX_CONTROL_ROOT=$TMUX_RUNTIME_CONTROL_ROOT" -e "LBWC_TMUX_AGENT_ID=$agent_id" -e "LBWC_TMUX_CONTRACT_ID=$contract_id" -t "$orchestrator_target" -c "$worker_directory" -P -F '#{pane_id}') || return 1
  [[ "$pane_id" =~ ^%[0-9]+$ ]] || return 1
  if ! record_worker_pane "$agent_id" "$pane_id"; then
    tmux kill-pane -t "$pane_id" >/dev/null 2>&1 || true
    return 1
  fi
  target=$(tmux display-message -p -t "$pane_id" '#{session_name}:#{window_index}.#{pane_index}') || { tmux kill-pane -t "$pane_id" >/dev/null 2>&1 || true; return 1; }
  if ! tmux select-pane -t "$pane_id" -T "$agent_id"; then
    tmux kill-pane -t "$pane_id" >/dev/null 2>&1 || true
    return 1
  fi
  if ! focus_split_pane "$orchestrator_target" "$pane_id"; then
    tmux kill-pane -t "$pane_id" >/dev/null 2>&1 || true
    return 1
  fi
  jq -n --arg pane_id "$pane_id" --arg target "$target" '{pane_id: $pane_id, target: $target}'
}

focus_split_pane() {
  local orchestrator_target="$1" agent_target="$2"
  if [ "$TMUX_ATTACH_POLICY" = visible_grid ]; then
    apply_tmux_layout "$agent_target" "$TMUX_LAYOUT" && tmux select-pane -t "$agent_target"
  else
    tmux select-pane -t "$orchestrator_target"
  fi
}

launch_agent() {
  local orchestrator_target="$1" target="$2" generated_name="$3" command
  printf -v command 'exec claude --agent %q' "$generated_name"
  tmux send-keys -t "$target" "$command" C-m && focus_split_pane "$orchestrator_target" "$target"
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
    cleanup_worker_worktree "$agent_id" false || printf 'tmux worktree cleanup failed for %s\n' "$agent_id" >&2
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

split_ledger_new() {
  local original_registry="$1" original_routing="$2" out_ledger="$3" built
  built=$(jq -cn --arg registry "$original_registry" --arg routing "$original_routing" '{registry:$registry,routing:$routing,panes:[],agents:[],names:[]}') || return 1
  printf -v "$out_ledger" '%s' "$built"
}

split_ledger_add() {
  local ledger="$1" field="$2" value="$3" out_ledger="$4" extended
  extended=$(jq -c --arg field "$field" --arg value "$value" '.[$field] += [$value]' <<<"$ledger") || return 1
  printf -v "$out_ledger" '%s' "$extended"
}

split_abort() {
  local ledger="$1" message="$2" saved_registry saved_routing pane_ids agent_ids
  saved_registry=$(jq -r '.registry' <<<"$ledger") \
    && saved_routing=$(jq -r '.routing' <<<"$ledger") \
    && pane_ids=$(jq -r '.panes | join("\n")' <<<"$ledger") \
    && agent_ids=$(jq -r '.agents | join("\n")' <<<"$ledger") \
    || fail "$message (rollback ledger is unreadable, nothing was restored)"
  rollback_split_group "$saved_registry" "$saved_routing" "$pane_ids" "$agent_ids"
  fail "$message"
}

split_group_open() {
  local definitions="$1" session="$2" out_registry="$3" out_target="$4" out_ledger="$5" out_layout="$6"
  local current_registry routing_table agent_limit orchestrator_pane opened_ledger opened_layout
  agent_manifest_with_lock "$TMUX_RUNTIME_CONTROL_ROOT" validate_split_group_definitions "$definitions" || fail "${SPLIT_VALIDATION_ERROR:-generated agent validation failed}"
  tmux_runtime_lock_acquire registry 5000 30000
  current_registry=$(tmux_runtime_registry_read)
  routing_table=$(cat "$TMUX_RUNTIME_BUS_ROOT/routing-table.json")
  opened_layout=$(tmux_layout_name)
  agent_limit=$(tmux_max_agents)
  [ $(( $(jq '[.agents[] | select(.state != "shutdown")] | length' <<<"$current_registry") + $(jq 'length' <<<"$definitions") )) -le "$agent_limit" ] || fail "tmux agent limit exceeded: $agent_limit"
  [ "$session" = "$(jq -r '.tmux.session' <<<"$current_registry")" ] || fail 'session does not match registry'
  orchestrator_pane=$(jq -r '.tmux.orchestrator_target' <<<"$current_registry")
  tmux_pane_exists "$orchestrator_pane" || fail 'registered orchestrator pane does not exist'
  split_ledger_new "$current_registry" "$routing_table" opened_ledger || fail 'cannot build the rollback ledger'
  printf -v "$out_layout" '%s' "$opened_layout"
  printf -v "$out_registry" '%s' "$current_registry"
  printf -v "$out_target" '%s' "$orchestrator_pane"
  printf -v "$out_ledger" '%s' "$opened_ledger"
}

split_member_identity() {
  local item="$1" registry="$2" out_agent="$3" out_generated="$4" out_contract="$5" item_agent item_generated item_contract value
  item_agent=$(jq -r '.agent_id' <<<"$item")
  item_generated=$(jq -r '.generated_name' <<<"$item")
  item_contract=$(jq -r '.contract_id' <<<"$item")
  for value in "$item_agent" "$item_generated" "$item_contract"; do tmux_runtime_valid_token "$value" || fail 'agent group contains an invalid identifier'; done
  jq -e --arg id "$item_agent" 'all(.agents[]; .agent_id != $id) and .main.agent_id != $id' <<<"$registry" >/dev/null || fail "agent is already registered: $item_agent"
  printf -v "$out_agent" '%s' "$item_agent"
  printf -v "$out_generated" '%s' "$item_generated"
  printf -v "$out_contract" '%s' "$item_contract"
}

split_member_credential() {
  local in_ledger="$1" agent_id="$2" contract_id="$3" out_capability="$4" out_hash="$5" out_ledger="$6"
  local new_capability new_hash credential next_ledger
  new_capability=$(tmux_runtime_capability)
  new_hash=$(tmux_runtime_capability_hash "$new_capability")
  credential=$(jq -n --arg agent_id "$agent_id" --arg contract_id "$contract_id" --arg capability "$new_capability" '{agent_id:$agent_id,contract_id:$contract_id,capability:$capability}')
  split_ledger_add "$in_ledger" agents "$agent_id" next_ledger || split_abort "$in_ledger" "cannot record agent capability: $agent_id"
  tmux_runtime_atomic_json "$TMUX_RUNTIME_BUS_ROOT/credentials/$agent_id.json" "$credential" || split_abort "$in_ledger" "cannot publish agent capability: $agent_id"
  printf -v "$out_capability" '%s' "$new_capability"
  printf -v "$out_hash" '%s' "$new_hash"
  printf -v "$out_ledger" '%s' "$next_ledger"
}

split_member_pane() {
  local in_ledger="$1" orchestrator_target="$2" agent_id="$3" contract_id="$4" generated_name="$5" out_pane="$6" out_target="$7" out_ledger="$8"
  local prepared new_pane new_target next_ledger
  prepared=$(prepare_agent_pane "$orchestrator_target" "$agent_id" "$contract_id") || split_abort "$in_ledger" "cannot start generated agent: $agent_id"
  new_pane=$(jq -r '.pane_id' <<<"$prepared") || split_abort "$in_ledger" "cannot resolve generated agent pane identity: $agent_id"
  new_target=$(jq -r '.target' <<<"$prepared") || split_abort "$in_ledger" "cannot resolve generated agent target: $agent_id"
  [[ "$new_pane" =~ ^%[0-9]+$ ]] && tmux_runtime_valid_target "$new_target" || split_abort "$in_ledger" "generated agent pane identity is invalid: $agent_id"
  split_ledger_add "$in_ledger" panes "$new_pane" next_ledger \
    && split_ledger_add "$next_ledger" names "$generated_name" next_ledger \
    || { tmux kill-pane -t "$new_pane" >/dev/null 2>&1 || true; split_abort "$in_ledger" "cannot record generated agent pane: $agent_id"; }
  printf -v "$out_pane" '%s' "$new_pane"
  printf -v "$out_target" '%s' "$new_target"
  printf -v "$out_ledger" '%s' "$next_ledger"
}

split_member_register() {
  local in_ledger="$1" in_registry="$2" agent_id="$3" generated_name="$4" contract_id="$5" pane_target="$6" in_pane="$7" capability_hash="$8" out_registry="$9" updated
  if ! tmux_runtime_initialize_inbox "$agent_id" || ! updated=$(add_agent_entry "$in_registry" "$agent_id" "$generated_name" "$contract_id" "$pane_target" "$in_pane" "$capability_hash"); then
    split_abort "$in_ledger" "cannot prepare generated agent runtime state"
  fi
  printf -v "$out_registry" '%s' "$updated"
}

split_group_launch() {
  local ledger="$1" registry="$2" orchestrator_target="$3" capabilities="$4" session="$5" layout_name="$6" pane_id generated_name agent_id launch_rows
  launch_rows=$(jq -r '[.panes, .names, .agents] | transpose[] | @tsv' <<<"$ledger") || split_abort "$ledger" 'cannot read the generated agent ledger'
  if ! tmux_runtime_write_registry_route_bundle "$registry"; then
    split_abort "$ledger" 'cannot publish generated agent registry and routing table'
  fi
  while IFS=$'\t' read -r pane_id generated_name agent_id; do
    [ -n "$pane_id" ] || continue
    launch_agent "$orchestrator_target" "$pane_id" "$generated_name" || split_abort "$ledger" "cannot launch generated agent: $agent_id"
  done <<<"$launch_rows"
  if ! apply_tmux_layout "$session" "$layout_name"; then
    split_abort "$ledger" 'cannot arrange generated agent panes'
  fi
  tmux_runtime_lock_release registry
  jq -n --argjson agents "$capabilities" '{state: "registered", agents: $agents}'
}

split_group() {
  local definitions="$1" registry orchestrator_target ledger item agent_id generated contract_id target pane_id capability hash layout capabilities='[]'
  split_group_open "$definitions" "$session" registry orchestrator_target ledger layout
  while IFS= read -r item; do
    split_member_identity "$item" "$registry" agent_id generated contract_id
    split_member_credential "$ledger" "$agent_id" "$contract_id" capability hash ledger
    split_member_pane "$ledger" "$orchestrator_target" "$agent_id" "$contract_id" "$generated" pane_id target ledger
    capabilities=$(jq --arg id "$agent_id" --arg capability "$capability" '. + [{agent_id: $id, capability: $capability}]' <<<"$capabilities") || split_abort "$ledger" "cannot record agent capability: $agent_id"
    split_member_register "$ledger" "$registry" "$agent_id" "$generated" "$contract_id" "$target" "$pane_id" "$hash" registry
  done < <(jq -c '.[]' <<<"$definitions")
  split_group_launch "$ledger" "$registry" "$orchestrator_target" "$capabilities" "$session" "$layout"
}

split_agent() {
  local definitions
  [ -n "$agent_id" ] || fail '--name is required for split-agent'
  [ -n "$generated_agent" ] || fail '--agent is required for split-agent'
  [ "$agent_id" = "$generated_agent" ] || fail 'agent and generated identities must match'
  definitions=$(split_agent_definition) || fail 'cannot resolve generated agent manifest identity'
  split_group "$definitions"
}
