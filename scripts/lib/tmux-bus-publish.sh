POLL_FIRST=true

command_init() {
  local main_id="$1" main_session_id="$2" existing_capability="$3" registry
  tmux_runtime_valid_token "$main_id" || fail "invalid main id"
  tmux_runtime_valid_token "$main_session_id" || fail "invalid main session id"
  [ -e "$TMUX_RUNTIME_BUS_ROOT/registry.json" ] || fail 'bus is not provisioned'
  tmux_runtime_require_bus || fail 'bus is not provisioned'
  tmux_runtime_lock_acquire init 5000 30000
  registry=$(tmux_runtime_registry_read)
  jq -e --arg main "$main_id" '.main.agent_id == $main' <<<"$registry" >/dev/null || fail "existing registry belongs to another main session"
  tmux_runtime_principal_valid "$registry" "$main_id" "$main_session_id" orchestrator "$existing_capability" || fail 'orchestrator session and capability are required for an existing bus'
  read_routing_table "$registry" >/dev/null
  tmux_runtime_initialize_inbox "$main_id"
  tmux_runtime_lock_release init
  jq -n --arg state 'already_initialized' '{state: $state}'
}

command_routing_refresh() {
  local agent_id="$1" session_id="$2" capability="$3" registry
  tmux_runtime_require_bus
  tmux_runtime_lock_acquire registry 5000 30000
  registry=$(tmux_runtime_registry_read)
  tmux_runtime_principal_valid "$registry" "$agent_id" "$session_id" orchestrator "$capability" || fail 'orchestrator session and capability are required to refresh routes'
  [ "$agent_id" = "$(jq -r '.main.agent_id' <<<"$registry")" ] || fail 'routing refresh requires the main orchestrator'
  write_routing_table "$registry"
  tmux_runtime_lock_release registry
}

validate_publish_request() {
  local recipient="$1" agent_id="$2" session_id="$3" role="$4" message_type="$5" correlation_id="$6" payload="$7" publish_timeout_ms="$8" value
  for value in "$recipient" "$agent_id" "$session_id" "$correlation_id"; do
    tmux_runtime_valid_token "$value" || fail "invalid message identifier"
  done
  case "$role" in orchestrator|agent) ;; *) fail "invalid sender role" ;; esac
  valid_message_type "$message_type" || fail "invalid message type"
  if [ "$role" = orchestrator ]; then
    case "$message_type" in job|shutdown_request|error) ;; *) fail "orchestrator cannot publish message type: $message_type" ;; esac
  else
    case "$message_type" in result|error|heartbeat|shutdown_response) ;; *) fail "agent cannot publish message type: $message_type" ;; esac
  fi
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$payload" || fail "payload must be a JSON object"
  [[ "$publish_timeout_ms" =~ ^[1-9][0-9]*$ ]] || fail "publish timeout must be milliseconds"
}

acquire_delivery_slot() {
  local lock_name="$1" inbox="$2" message_type="$3" recipient="$4" publish_timeout_ms="$5" deadline now
  deadline=$(tmux_runtime_deadline_after "$publish_timeout_ms")
  while :; do
    tmux_runtime_deadline_expired "$deadline" && fail "timed out waiting for $message_type inbox slot: $recipient"
    now=$(tmux_runtime_deadline_remaining "$deadline")
    tmux_runtime_lock_acquire "$lock_name" "$now" 30000
    if [ "$message_type" = heartbeat ] || [ ! -e "$inbox/$message_type.json" ]; then
      break
    fi
    tmux_runtime_lock_release "$lock_name"
    sleep 0.01
  done
}

command_publish() {
  local recipient="$1" agent_id="$2" session_id="$3" role="$4" capability="$5" message_type="$6" correlation_id="$7" payload="$8" publish_timeout_ms="$9" registry inbox message_id envelope transaction lock_name
  validate_publish_request "$recipient" "$agent_id" "$session_id" "$role" "$message_type" "$correlation_id" "$payload" "$publish_timeout_ms"
  registry=$(require_principal "$agent_id" "$session_id" "$role" "$capability" false)
  jq -e --arg recipient "$recipient" '.routes[$recipient].inbox == $recipient' <<<"$registry" >/dev/null || fail "no route for recipient: $recipient"
  inbox=$(tmux_runtime_inbox "$recipient")
  tmux_runtime_private_directory "$inbox"
  tmux_runtime_private_directory "$inbox/acked"
  message_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
  [[ "$message_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || fail "cannot generate message identifier"
  envelope=$(envelope_document "$message_id" "$recipient" "$agent_id" "$session_id" "$role" "$message_type" "$correlation_id" "$payload")
  transaction=$(transaction_document "$message_id" "$envelope")
  lock_name="delivery.$recipient.$message_type"
  acquire_delivery_slot "$lock_name" "$inbox" "$message_type" "$recipient" "$publish_timeout_ms"
  tmux_runtime_atomic_json "$(transaction_path "$message_id")" "$transaction"
  printf '%s\n' "$message_id"
  deliver_transaction "$message_id"
  tmux_runtime_lock_release "$lock_name"
}

emit_poll_message() {
  local file="$1" inbox="$2" sender_filter="$3"
  validate_envelope_file "$file"
  [ "$(jq -r '.to.agent_id' "$file")" = "$(basename "$inbox")" ] || fail "message recipient does not match inbox"
  [ -z "$sender_filter" ] || [ "$(jq -r '.from.agent_id' "$file")" = "$sender_filter" ] || return 0
  [ "$POLL_FIRST" = true ] || printf '\n'
  cat "$file"
  POLL_FIRST=false
}

poll_inbox_type() {
  local type="$1" inbox="$2" sender_filter="$3" file
  if [ "$type" = heartbeat ]; then
    for file in "$inbox"/heartbeat.*.json; do
      [ -e "$file" ] || continue
      emit_poll_message "$file" "$inbox" "$sender_filter"
    done
    return 0
  fi
  file="$inbox/$type.json"
  [ -e "$file" ] || return 0
  emit_poll_message "$file" "$inbox" "$sender_filter"
}

poll_messages() {
  local requester_id="$1" requested_sender="$2" types_csv="$3" registry inbox main_id type sender_filter
  local -a type_list
  tmux_runtime_valid_token "$requested_sender" || fail "invalid requested sender id"
  registry=$(tmux_runtime_registry_read)
  jq -e --arg id "$requester_id" '.routes[$id].inbox == $id' <<<"$registry" >/dev/null || fail "no route for authenticated principal: $requester_id"
  main_id=$(jq -r '.main.agent_id' <<<"$registry")
  sender_filter=''
  if [ "$requester_id" = "$main_id" ] && [ "$requested_sender" != "$main_id" ] && [[ ",$types_csv," == *,result,* || ",$types_csv," == *,error,* || ",$types_csv," == *,heartbeat,* || ",$types_csv," == *,shutdown_response,* ]]; then
    inbox=$(tmux_runtime_inbox "$main_id")
    sender_filter="$requested_sender"
  else
    [ "$requester_id" = "$requested_sender" ] || fail 'principal cannot read another agent inbox'
    inbox=$(tmux_runtime_inbox "$requester_id")
  fi
  tmux_runtime_private_directory "$inbox"
  POLL_FIRST=true
  IFS=',' read -r -a type_list <<<"$types_csv"
  for type in "${type_list[@]}"; do
    valid_message_type "$type" || fail "invalid message type"
    poll_inbox_type "$type" "$inbox" "$sender_filter"
  done
}

command_await() {
  local requester_id="$1" session_id="$2" role="$3" capability="$4" requested_sender="$5" types="$6" timeout_ms="$7" deadline output registry
  [[ "$timeout_ms" =~ ^[1-9][0-9]*$ ]] || fail "timeout must be a positive number of milliseconds"
  registry=$(require_principal "$requester_id" "$session_id" "$role" "$capability" false)
  deadline=$(tmux_runtime_deadline_after "$timeout_ms")
  while :; do
    output=$(poll_messages "$requester_id" "$requested_sender" "$types")
    [ -z "$output" ] || { printf '%s\n' "$output"; return 0; }
    tmux_runtime_deadline_expired "$deadline" && fail "timed out awaiting message from $requested_sender"
    sleep 0.005
  done
}

command_stale() {
  local requester_id="$1" session_id="$2" role="$3" capability="$4" agent_id="$5" threshold_ms="$6" registry heartbeat now
  tmux_runtime_valid_token "$agent_id" || fail "invalid agent id"
  [[ "$threshold_ms" =~ ^[1-9][0-9]*$ ]] || fail "stale threshold must be milliseconds"
  registry=$(require_principal "$requester_id" "$session_id" "$role" "$capability" true)
  tmux_runtime_lock_acquire registry 5000 30000
  registry=$(tmux_runtime_registry_read)
  read_routing_table "$registry" >/dev/null
  heartbeat=$(jq -r --arg id "$agent_id" '.agents[] | select(.agent_id == $id) | .heartbeat_at_ms' <<<"$registry")
  tmux_runtime_lock_release registry
  [[ "$heartbeat" =~ ^[0-9]+$ ]] || fail "agent has no heartbeat: $agent_id"
  now=$(tmux_runtime_now_ms)
  if [ "$now" -ge $((heartbeat + threshold_ms)) ]; then
    printf 'stale: %s\n' "$agent_id"
    return 1
  fi
  printf 'fresh: %s\n' "$agent_id"
}

command_recover() {
  local agent_id="$1" session_id="$2" capability="$3" message_id="$4" lock_name registry
  [[ "$message_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || fail "invalid message id"
  registry=$(require_principal "$agent_id" "$session_id" orchestrator "$capability" true)
  lock_name="recovery.$message_id"
  tmux_runtime_lock_acquire "$lock_name" 5000 30000
  deliver_transaction "$message_id"
  tmux_runtime_lock_release "$lock_name"
  printf '%s\n' "$message_id"
}

compact_directory() {
  local directory="$1" retain="$2" name count=0
  [ -d "$directory" ] || return 0
  tmux_runtime_private_directory "$directory"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    tmux_runtime_private_file "$directory/$name"
    count=$((count + 1))
    [ "$count" -le "$retain" ] || rm -f "$directory/$name" || fail "cannot compact retained message: $directory/$name"
  done < <(python3 "$TMUX_RUNTIME_HELPER" list-json --path "$directory")
}

command_compact() {
  local requester_id="$1" session_id="$2" capability="$3" retain="$4" registry agent_id
  [[ "$retain" =~ ^[0-9]+$ ]] || fail "retain must be a non-negative integer"
  registry=$(require_principal "$requester_id" "$session_id" orchestrator "$capability" true)
  tmux_runtime_lock_acquire retention 5000 30000
  registry=$(tmux_runtime_registry_read)
  read_routing_table "$registry" >/dev/null
  compact_directory "$TMUX_RUNTIME_BUS_ROOT/outbox/main" "$retain"
  while IFS= read -r agent_id; do
    [ -n "$agent_id" ] || continue
    compact_directory "$(tmux_runtime_inbox "$agent_id")/acked" "$retain"
  done < <(jq -r '.routes | keys[]' <<<"$registry")
  tmux_runtime_lock_release retention
}

command_bind() {
  local agent_id="$1" session_id="$2" capability="$3" contract_id="$4" registry updated value
  for value in "$agent_id" "$session_id" "$contract_id"; do
    tmux_runtime_valid_token "$value" || fail 'invalid bind identifier'
  done
  tmux_runtime_require_bus
  tmux_runtime_lock_acquire registry 5000 30000
  registry=$(tmux_runtime_registry_read)
  read_routing_table "$registry" >/dev/null
  jq -e --arg agent "$agent_id" --arg contract "$contract_id" --arg capability "$(tmux_runtime_capability_hash "$capability")" 'any(.agents[]; .agent_id == $agent and .contract_id == $contract and .claude_session_id == null and .capability_hash == $capability and .state != "shutdown")' <<<"$registry" >/dev/null || fail 'bind is invalid or already consumed'
  updated=$(jq --arg agent "$agent_id" --arg session "$session_id" '.agents |= map(if .agent_id == $agent then .claude_session_id = $session else . end)' <<<"$registry")
  tmux_runtime_write_registry_route_bundle "$updated" || fail 'cannot publish bound agent routing'
  tmux_runtime_lock_release registry
}
