new_registry() {
  local main_id="$1" capability_hash="$2"
  jq -n --arg main "$main_id" --arg hash "$capability_hash" '
    {schema_version: 2, main: {agent_id: $main, session_id: $main, role: "orchestrator", capability_hash: $hash}, tmux: {session: null, orchestrator_target: null, orchestrator_pane: null, topology: "pending", managed_session: false, ownership_token: null}, agents: [], routes: {($main): {inbox: $main, tmux_target: null}}}'
}

rollback_provision() {
  local managed="$1" session="$2" created_registry="$3" main_inbox="$4" created_runtime="$5" original_registry="$6"
  if [ "$managed" = true ] && [ -n "$session" ]; then
    tmux kill-session -t "$session" >/dev/null 2>&1 || true
  fi
  if [ "$created_registry" = true ]; then
    rm -f "$TMUX_RUNTIME_BUS_ROOT/registry.json" "$TMUX_RUNTIME_BUS_ROOT/routing-table.json"
  fi
  [ -z "$main_inbox" ] || rm -rf "$TMUX_RUNTIME_BUS_ROOT/inboxes/$main_inbox"
  if [ -n "$original_registry" ]; then
    tmux_runtime_atomic_json "$TMUX_RUNTIME_BUS_ROOT/registry.json" "$original_registry" >/dev/null 2>&1 || true
    tmux_runtime_write_routing_table "$original_registry" >/dev/null 2>&1 || true
  fi
  if [ "$created_runtime" = true ]; then
    rmdir "$TMUX_RUNTIME_BUS_ROOT/inboxes" "$TMUX_RUNTIME_BUS_ROOT/outbox/main" "$TMUX_RUNTIME_BUS_ROOT/outbox" "$TMUX_RUNTIME_BUS_ROOT/transactions" "$TMUX_RUNTIME_BUS_ROOT/claims" "$TMUX_RUNTIME_BUS_ROOT/credentials" "$TMUX_RUNTIME_BUS_ROOT/heartbeats" "$TMUX_RUNTIME_BUS_ROOT/locks" "$TMUX_RUNTIME_BUS_ROOT" "$TMUX_RUNTIME_ROOT" 2>/dev/null || true
  fi
}

# Reads provision locals because one rollback path needs every step's state.
provision_load_registry() {
  if [ -e "$TMUX_RUNTIME_BUS_ROOT/registry.json" ]; then
    registry=$(tmux_runtime_registry_read)
    original_registry="$registry"
    jq -e --arg id "$main_id" '.main.agent_id == $id' <<<"$registry" >/dev/null || fail 'existing registry belongs to another main id'
    tmux_runtime_principal_valid "$registry" "$orchestrator_id" "$orchestrator_session_id" orchestrator "$orchestrator_capability" || fail 'main orchestrator session and capability are required for existing provision'
    capability=''
  else
    capability=$(tmux_runtime_capability)
    hash=$(tmux_runtime_capability_hash "$capability")
    registry=$(new_registry "$main_id" "$hash")
    new_registry=true
  fi
}

provision_open_topology() {
  session=$(jq -r '.tmux_session' <<<"$preflight")
  topology=$(jq -r '.topology' <<<"$preflight")
  case "$topology" in
    attached-existing-tmux)
      attached_pane="${TMUX_PANE:-}"
      [ -n "$attached_pane" ] || fail 'attached orchestration pane is unavailable'
      target=$(tmux display-message -p -t "$attached_pane" '#{session_name}:#{window_index}.#{pane_index}') || fail 'cannot resolve attached orchestrator pane'
      pane=$(tmux display-message -p -t "$attached_pane" '#{pane_index}') || fail 'cannot resolve attached orchestrator pane index'
      managed=false
      ownership=''
      ;;
    detached-new-session)
      tmux new-session -d -s "$session" -n orchestrator -c "$PROJECT_ROOT" || fail "cannot create detached tmux session: $session"
      target=$(tmux display-message -p -t "$session:0.0" '#{session_name}:#{window_index}.#{pane_index}') || { rollback_provision true "$session" "$new_registry" '' "$created_runtime" "$original_registry"; fail 'cannot resolve detached orchestrator pane'; }
      pane=$(tmux display-message -p -t "$target" '#{pane_index}') || { rollback_provision true "$session" "$new_registry" '' "$created_runtime" "$original_registry"; fail 'cannot resolve detached orchestrator pane index'; }
      ownership=$(tmux_runtime_capability)
      tmux set-option -t "$session" @lbwc_ownership_token "$ownership" || { rollback_provision true "$session" "$new_registry" '' "$created_runtime" "$original_registry"; fail 'cannot mark owned tmux session'; }
      tmux select-pane -t "$target" -T 'LBWC orchestrator' || { rollback_provision true "$session" "$new_registry" '' "$created_runtime" "$original_registry"; fail 'cannot label orchestrator pane'; }
      managed=true
      ;;
    *) fail "unsupported topology: $topology" ;;
  esac
}

provision_publish() {
  if [ "$new_registry" = true ] && ! tmux_runtime_initialize_inbox "$main_id"; then
    tmux_runtime_lock_release registry || true
    rollback_provision "$managed" "$session" "$new_registry" "$main_id" "$created_runtime" "$original_registry"
    fail 'cannot initialize main inbox for provisioned session'
  fi
  [ "$new_registry" = false ] || main_inbox="$main_id"
  if ! tmux_runtime_write_registry_route_bundle "$updated"; then
    tmux_runtime_lock_release registry || true
    rollback_provision "$managed" "$session" "$new_registry" "$main_inbox" "$created_runtime" "$original_registry"
    fail 'cannot publish provisioned registry and routing table'
  fi
  tmux_runtime_lock_release registry
  jq -n --arg session "$session" --arg target "$target" --arg topology "$topology" --arg capability "$capability" '{tmux_session: $session, orchestrator_target: $target, topology: $topology, main_capability: $capability}'
}

provision() {
  local preflight session topology target pane managed=false ownership='' capability hash registry original_registry='' updated attached_pane new_registry=false created_runtime=false main_inbox=''
  [ -n "$main_id" ] || fail '--main-id is required for provision'
  tmux_runtime_valid_token "$main_id" || fail 'main id is invalid'
  preflight=$(bash "$SCRIPT_DIR/tmux-preflight.sh" --project-root "$PROJECT_ROOT" --control-root "$TMUX_RUNTIME_CONTROL_ROOT" --main-id "$main_id") || exit $?
  [ -e "$TMUX_RUNTIME_ROOT" ] || created_runtime=true
  ensure_runtime_layout || fail 'cannot initialize private tmux runtime'
  tmux_runtime_lock_acquire registry 5000 30000
  provision_load_registry
  provision_open_topology
  updated=$(jq --arg session "$session" --arg target "$target" --arg pane "$pane" --arg topology "$topology" --arg ownership "$ownership" --argjson managed "$managed" '
    .tmux = {session: $session, orchestrator_target: $target, orchestrator_pane: $pane, topology: $topology, managed_session: $managed, ownership_token: (if $managed then $ownership else null end)}
    | .routes[.main.agent_id].tmux_target = $target' <<<"$registry")
  tmux_layout_config
  configure_pane_borders "$session" || { tmux_runtime_lock_release registry || true; rollback_provision "$managed" "$session" "$new_registry" '' "$created_runtime" "$original_registry"; fail 'cannot configure pane borders'; }
  provision_publish
}
