authenticate_agent_principal() {
  local agent_id="$1" session_id="$2" capability="$3" registry role=agent
  tmux_runtime_require_bus
  tmux_runtime_lock_acquire registry 5000 30000
  registry=$(tmux_runtime_registry_read)
  [ "$agent_id" != "$(jq -r '.main.agent_id' <<<"$registry")" ] || role=orchestrator
  tmux_runtime_principal_valid "$registry" "$agent_id" "$session_id" "$role" "$capability" || fail "sender capability does not match a registered principal"
  read_routing_table "$registry" >/dev/null
  tmux_runtime_lock_release registry
}

assert_claim_available() {
  local claim="$1" lock_name="$2" agent_id="$3"
  [ -e "$claim" ] || return 0
  tmux_runtime_existing_private_directory "$claim"
  tmux_runtime_private_file "$claim/owner.json"
  if ! tmux_runtime_lock_recoverable "$claim" owner.json; then
    tmux_runtime_lock_release "$lock_name"
    fail "agent inbox is already claimed: $agent_id"
  fi
}

command_claim() {
  local agent_id="$1" session_id="$2" capability="$3" message_type="$4" lease_ms="$5" inbox message claim lock_name now owner value
  for value in "$agent_id" "$session_id"; do tmux_runtime_valid_token "$value" || fail "invalid claim identifier"; done
  valid_message_type "$message_type" || fail "invalid message type"
  [[ "$lease_ms" =~ ^[1-9][0-9]*$ ]] || fail "claim lease must be milliseconds"
  authenticate_agent_principal "$agent_id" "$session_id" "$capability"
  inbox=$(tmux_runtime_inbox "$agent_id")
  message="$inbox/$message_type.json"
  claim="$TMUX_RUNTIME_BUS_ROOT/claims/$agent_id.$message_type.claim"
  lock_name="delivery.$agent_id.$message_type"
  tmux_runtime_lock_acquire "$lock_name" 5000 30000
  [ -e "$message" ] || fail "message is unavailable for claim"
  validate_envelope_file "$message"
  assert_claim_available "$claim" "$lock_name" "$agent_id"
  now=$(tmux_runtime_deadline_now_ms)
  owner=$(jq -n --arg message_id "$(jq -r '.message_id' "$message")" --arg agent "$agent_id" --arg session "$session_id" --argjson pid "$$" --argjson acquired "$now" --argjson lease "$lease_ms" '{message_id: $message_id, agent_id: $agent, session_id: $session, pid: $pid, acquired_at_ms: $acquired, lease_ms: $lease}')
  python3 "$TMUX_RUNTIME_HELPER" publish-directory --root "$TMUX_RUNTIME_BUS_ROOT" --relative "claims/$agent_id.$message_type.claim" --document "$owner" || fail "cannot publish inbox claim"
  cat "$message"
  tmux_runtime_lock_release "$lock_name"
}

complete_recovered_ack() {
  local agent_id="$1" message_id="$2" inbox="$3" type file lock_name
  for type in $MESSAGE_TYPES; do
    file="$inbox/$type.json"
    [ -e "$file" ] || continue
    validate_envelope_file "$file"
    [ "$(jq -r '.message_id' "$file")" = "$message_id" ] || continue
    lock_name="delivery.$agent_id.$type"
    tmux_runtime_lock_acquire "$lock_name" 5000 30000
    python3 "$TMUX_RUNTIME_HELPER" complete-ack --root "$TMUX_RUNTIME_BUS_ROOT" --source "inboxes/$agent_id/$type.json" --destination "inboxes/$agent_id/acked/$message_id.json" || fail "cannot recover acknowledgement message"
    tmux_runtime_lock_release "$lock_name"
    break
  done
}

release_recovered_claims() {
  local agent_id="$1" session_id="$2" message_id="$3" type claim claim_data
  for type in $MESSAGE_TYPES; do
    claim="$TMUX_RUNTIME_BUS_ROOT/claims/$agent_id.$type.claim"
    [ -e "$claim" ] || continue
    tmux_runtime_existing_private_directory "$claim"
    tmux_runtime_private_file "$claim/owner.json"
    claim_data=$(cat "$claim/owner.json")
    jq -e --arg message "$message_id" --arg agent "$agent_id" --arg session "$session_id" '.message_id == $message and .agent_id == $agent and .session_id == $session' <<<"$claim_data" >/dev/null || continue
    rm -f "$claim/owner.json"
    rmdir "$claim" || fail "cannot release recovered claim"
  done
}

ack_pending_message() {
  local agent_id="$1" session_id="$2" message_id="$3" inbox="$4" type file claim claim_data lock_name
  for type in $MESSAGE_TYPES; do
    file="$inbox/$type.json"
    [ -e "$file" ] || continue
    lock_name="delivery.$agent_id.$type"
    tmux_runtime_lock_acquire "$lock_name" 5000 30000
    validate_envelope_file "$file"
    [ "$(jq -r '.message_id' "$file")" = "$message_id" ] || { tmux_runtime_lock_release "$lock_name"; continue; }
    claim="$TMUX_RUNTIME_BUS_ROOT/claims/$agent_id.$type.claim"
    tmux_runtime_existing_private_directory "$claim"
    tmux_runtime_private_file "$claim/owner.json"
    claim_data=$(cat "$claim/owner.json")
    jq -e --arg message "$message_id" --arg agent "$agent_id" --arg session "$session_id" '.message_id == $message and .agent_id == $agent and .session_id == $session and (.pid | type == "number") and (.acquired_at_ms | type == "number") and (.lease_ms | type == "number" and . > 0)' <<<"$claim_data" >/dev/null || fail "agent claim is malformed: $agent_id"
    tmux_runtime_private_directory "$inbox/acked"
    [ ! -L "$inbox/acked" ] || fail "symbolic link is not permitted at acknowledgement"
    python3 "$TMUX_RUNTIME_HELPER" complete-ack --root "$TMUX_RUNTIME_BUS_ROOT" --source "inboxes/$agent_id/$type.json" --destination "inboxes/$agent_id/acked/$message_id.json" || fail "cannot acknowledge message"
    tmux_runtime_private_file "$inbox/acked/$message_id.json"
    rm -f "$claim/owner.json"
    rmdir "$claim" || fail "cannot release claim"
    tmux_runtime_lock_release "$lock_name"
    printf '%s\n' "$message_id"
    return 0
  done
  fail "message is not available for acknowledgement: $message_id"
}

command_ack() {
  local agent_id="$1" session_id="$2" capability="$3" message_id="$4" inbox
  tmux_runtime_valid_token "$agent_id" || fail "invalid agent id"
  tmux_runtime_valid_token "$session_id" || fail "invalid session id"
  [[ "$message_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || fail "invalid message id"
  authenticate_agent_principal "$agent_id" "$session_id" "$capability"
  inbox=$(tmux_runtime_inbox "$agent_id")
  if [ -e "$inbox/acked/$message_id.json" ]; then
    tmux_runtime_private_file "$inbox/acked/$message_id.json"
    complete_recovered_ack "$agent_id" "$message_id" "$inbox"
    release_recovered_claims "$agent_id" "$session_id" "$message_id"
    printf '%s\n' "$message_id"
    return 0
  fi
  ack_pending_message "$agent_id" "$session_id" "$message_id" "$inbox"
}

assert_heartbeat_state() {
  local registry="$1" agent_id="$2" current_state
  current_state=$(jq -r --arg id "$agent_id" '.agents[] | select(.agent_id == $id) | .state' <<<"$registry")
  case "$current_state" in
    registered|running|idle) ;;
    failed|shutdown) fail "agent is in a terminal lifecycle state: $agent_id" ;;
    *) fail "agent lifecycle state is malformed: $agent_id" ;;
  esac
}

heartbeat_shutdown() {
  local agent_id="$1" session_id="$2" capability="$3" main_id="$4" state="$5" registry updated
  tmux_runtime_lock_release registry
  command_publish "$main_id" "$agent_id" "$session_id" agent "$capability" heartbeat heartbeat "$(jq -n --arg state "$state" '{state: $state}')" 5000 >/dev/null
  tmux_runtime_lock_acquire registry 5000 30000
  registry=$(tmux_runtime_registry_read) || fail 'runtime registry is malformed'
  assert_heartbeat_state "$registry" "$agent_id"
  updated=$(jq --arg id "$agent_id" --argjson now "$(tmux_runtime_now_ms)" '
    .main.agent_id as $main_id
    | .agents |= map(if .agent_id == $id then .state = "shutdown" | .heartbeat_at_ms = $now else . end)
    | .routes |= with_entries(.key as $route_id | select($route_id == $main_id or $route_id != $id))
  ' <<<"$registry")
  tmux_runtime_write_registry_route_bundle "$updated"
  tmux_runtime_lock_release registry
}

heartbeat_update() {
  local agent_id="$1" session_id="$2" capability="$3" main_id="$4" state="$5" registry="$6" updated
  updated=$(jq --arg id "$agent_id" --arg state "$state" --argjson now "$(tmux_runtime_now_ms)" '.agents |= map(if .agent_id == $id then .state = $state | .heartbeat_at_ms = $now else . end)' <<<"$registry")
  tmux_runtime_registry_write "$updated"
  tmux_runtime_lock_release registry
  command_publish "$main_id" "$agent_id" "$session_id" agent "$capability" heartbeat heartbeat "$(jq -n --arg state "$state" '{state: $state}')" 5000 >/dev/null
}

command_heartbeat() {
  local agent_id="$1" session_id="$2" capability="$3" state="$4" registry main_id heartbeat_lock
  case "$state" in registered|running|idle|failed|shutdown) ;; *) fail "invalid agent state" ;; esac
  tmux_runtime_require_bus
  heartbeat_lock="heartbeat.$agent_id"
  tmux_runtime_lock_acquire "$heartbeat_lock" 5000 30000
  tmux_runtime_lock_acquire registry 5000 30000
  registry=$(tmux_runtime_registry_read)
  tmux_runtime_principal_valid "$registry" "$agent_id" "$session_id" agent "$capability" || fail "sender capability does not match a registered principal"
  read_routing_table "$registry" >/dev/null
  assert_heartbeat_state "$registry" "$agent_id"
  main_id=$(jq -r '.main.agent_id' <<<"$registry")
  if [ "$state" = shutdown ]; then
    heartbeat_shutdown "$agent_id" "$session_id" "$capability" "$main_id" "$state"
  else
    heartbeat_update "$agent_id" "$session_id" "$capability" "$main_id" "$state" "$registry"
  fi
  tmux_runtime_lock_release "$heartbeat_lock"
}
