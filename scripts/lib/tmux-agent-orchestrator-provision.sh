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

provision_load_registry() {
  local main_id="$1" out_registry="$2" out_original="$3" out_capability="$4" out_is_new="$5"
  local loaded_registry loaded_original='' loaded_capability='' is_new=false capability_hash
  if [ -e "$TMUX_RUNTIME_BUS_ROOT/registry.json" ]; then
    loaded_registry=$(tmux_runtime_registry_read)
    loaded_original="$loaded_registry"
    jq -e --arg id "$main_id" '.main.agent_id == $id' <<<"$loaded_registry" >/dev/null || fail 'existing registry belongs to another main id'
    tmux_runtime_principal_valid "$loaded_registry" "$orchestrator_id" "$orchestrator_session_id" orchestrator "$orchestrator_capability" || fail 'main orchestrator session and capability are required for existing provision'
  else
    loaded_capability=$(tmux_runtime_capability)
    capability_hash=$(tmux_runtime_capability_hash "$loaded_capability")
    loaded_registry=$(new_registry "$main_id" "$capability_hash")
    is_new=true
  fi
  printf -v "$out_registry" '%s' "$loaded_registry"
  printf -v "$out_original" '%s' "$loaded_original"
  printf -v "$out_capability" '%s' "$loaded_capability"
  printf -v "$out_is_new" '%s' "$is_new"
}

provision_attach_existing() {
  local out_target="$1" out_pane="$2" attached_pane pane_target pane_index
  attached_pane="${TMUX_PANE:-}"
  [ -n "$attached_pane" ] || fail 'attached orchestration pane is unavailable'
  pane_target=$(tmux display-message -p -t "$attached_pane" '#{session_name}:#{window_index}.#{pane_index}') || fail 'cannot resolve attached orchestrator pane'
  pane_index=$(tmux display-message -p -t "$attached_pane" '#{pane_index}') || fail 'cannot resolve attached orchestrator pane index'
  printf -v "$out_target" '%s' "$pane_target"
  printf -v "$out_pane" '%s' "$pane_index"
}

provision_create_session() {
  local session="$1" new_flag="$2" runtime_flag="$3" original="$4" out_target="$5" out_pane="$6" out_ownership="$7"
  local pane_target pane_index token
  tmux new-session -d -s "$session" -n orchestrator -c "$PROJECT_ROOT" || fail "cannot create detached tmux session: $session"
  pane_target=$(tmux display-message -p -t "$session:0.0" '#{session_name}:#{window_index}.#{pane_index}') || { rollback_provision true "$session" "$new_flag" '' "$runtime_flag" "$original"; fail 'cannot resolve detached orchestrator pane'; }
  pane_index=$(tmux display-message -p -t "$pane_target" '#{pane_index}') || { rollback_provision true "$session" "$new_flag" '' "$runtime_flag" "$original"; fail 'cannot resolve detached orchestrator pane index'; }
  token=$(tmux_runtime_capability)
  tmux set-option -t "$session" @lbwc_ownership_token "$token" || { rollback_provision true "$session" "$new_flag" '' "$runtime_flag" "$original"; fail 'cannot mark owned tmux session'; }
  tmux select-pane -t "$pane_target" -T 'LBWC orchestrator' || { rollback_provision true "$session" "$new_flag" '' "$runtime_flag" "$original"; fail 'cannot label orchestrator pane'; }
  printf -v "$out_target" '%s' "$pane_target"
  printf -v "$out_pane" '%s' "$pane_index"
  printf -v "$out_ownership" '%s' "$token"
}

provision_publish() {
  local new_flag="$1" main_id="$2" managed="$3" session="$4" runtime_flag="$5" original="$6" updated="$7" target="$8" topology="$9" capability="${10}" main_inbox=''
  if [ "$new_flag" = true ] && ! tmux_runtime_initialize_inbox "$main_id"; then
    tmux_runtime_lock_release registry || true
    rollback_provision "$managed" "$session" "$new_flag" "$main_id" "$runtime_flag" "$original"
    fail 'cannot initialize main inbox for provisioned session'
  fi
  [ "$new_flag" = false ] || main_inbox="$main_id"
  if ! tmux_runtime_write_registry_route_bundle "$updated"; then
    tmux_runtime_lock_release registry || true
    rollback_provision "$managed" "$session" "$new_flag" "$main_inbox" "$runtime_flag" "$original"
    fail 'cannot publish provisioned registry and routing table'
  fi
  tmux_runtime_lock_release registry
  jq -n --arg session "$session" --arg target "$target" --arg topology "$topology" --arg capability "$capability" '{tmux_session: $session, orchestrator_target: $target, topology: $topology, main_capability: $capability}'
}

provision() {
  local preflight session topology target pane managed=false ownership='' capability registry original_registry='' updated new_registry=false created_runtime=false
  [ -n "$main_id" ] || fail '--main-id is required for provision'
  tmux_runtime_valid_token "$main_id" || fail 'main id is invalid'
  preflight=$(bash "$SCRIPT_DIR/tmux-preflight.sh" --project-root "$PROJECT_ROOT" --control-root "$TMUX_RUNTIME_CONTROL_ROOT" --main-id "$main_id") || exit $?
  [ -e "$TMUX_RUNTIME_ROOT" ] || created_runtime=true
  ensure_runtime_layout || fail 'cannot initialize private tmux runtime'
  tmux_runtime_lock_acquire registry 5000 30000
  provision_load_registry "$main_id" registry original_registry capability new_registry
  session=$(jq -r '.tmux_session' <<<"$preflight")
  topology=$(jq -r '.topology' <<<"$preflight")
  case "$topology" in
    attached-existing-tmux) provision_attach_existing target pane ;;
    detached-new-session) provision_create_session "$session" "$new_registry" "$created_runtime" "$original_registry" target pane ownership; managed=true ;;
    *) fail "unsupported topology: $topology" ;;
  esac
  updated=$(jq --arg session "$session" --arg target "$target" --arg pane "$pane" --arg topology "$topology" --arg ownership "$ownership" --argjson managed "$managed" '
    .tmux = {session: $session, orchestrator_target: $target, orchestrator_pane: $pane, topology: $topology, managed_session: $managed, ownership_token: (if $managed then $ownership else null end)}
    | .routes[.main.agent_id].tmux_target = $target' <<<"$registry")
  tmux_layout_name >/dev/null
  tmux_max_agents >/dev/null
  configure_pane_borders "$session" || { tmux_runtime_lock_release registry || true; rollback_provision "$managed" "$session" "$new_registry" '' "$created_runtime" "$original_registry"; fail 'cannot configure pane borders'; }
  provision_publish "$new_registry" "$main_id" "$managed" "$session" "$created_runtime" "$original_registry" "$updated" "$target" "$topology" "$capability"
}
