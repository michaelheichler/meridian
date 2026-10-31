envelope_validation() {
  jq -e '
    def token: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$");
    def body_valid:
      if .type == "job" then (.body | type == "object" and (.brief | type == "string"))
      elif .type == "result" then (.body | type == "object" and (.result | type == "string"))
      elif .type == "error" then (.body | type == "object" and (.message | type == "string"))
      elif .type == "heartbeat" then (.body | type == "object" and (.state | IN("registered", "running", "idle", "failed", "shutdown")))
      elif .type == "shutdown_request" then (.body | type == "object" and (.reason | type == "string"))
      else (.body | type == "object" and (.acknowledged | type == "boolean")) end;
    .schema_version == 1
    and (.message_id | type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))
    and (.correlation_id | token)
    and (.from | type == "object" and (.agent_id | token) and (.session_id | token) and (.role | IN("orchestrator", "agent")))
    and (.to | type == "object" and (.agent_id | token))
    and (.type | IN("job", "result", "heartbeat", "error", "shutdown_request", "shutdown_response"))
    and (.sent_at | type == "string")
    and (.sent_at as $sent_at | ($sent_at | fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == $sent_at)
    and body_valid
  '
}

valid_message_type() {
  case " $MESSAGE_TYPES " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

validate_envelope_file() {
  local path="$1"
  tmux_runtime_private_file "$path"
  envelope_validation < "$path" >/dev/null 2>&1 || fail "malformed message: $path"
}

validate_envelope_document() {
  envelope_validation >/dev/null 2>&1
}

envelope_document() {
  local message_id="$1" recipient="$2" agent_id="$3" session_id="$4" role="$5" message_type="$6" correlation_id="$7" payload="$8"
  jq -n \
    --arg message_id "$message_id" \
    --arg recipient "$recipient" \
    --arg agent_id "$agent_id" \
    --arg session_id "$session_id" \
    --arg role "$role" \
    --arg message_type "$message_type" \
    --arg correlation_id "$correlation_id" \
    --arg sent_at "$(tmux_runtime_iso_now)" \
    --argjson body "$payload" \
    '{schema_version: 1, message_id: $message_id, correlation_id: $correlation_id, from: {agent_id: $agent_id, session_id: $session_id, role: $role}, to: {agent_id: $recipient}, type: $message_type, sent_at: $sent_at, body: $body}'
}

transaction_document() {
  local message_id="$1" envelope="$2"
  jq -n --argjson created_at_ms "$(tmux_runtime_now_ms)" --argjson envelope "$envelope" --arg message_id "$message_id" \
    '{schema_version: 1, kind: "delivery", message_id: $message_id, state: "prepared", created_at_ms: $created_at_ms, envelope: $envelope}'
}

transaction_path() {
  printf '%s/transactions/%s.json\n' "$TMUX_RUNTIME_BUS_ROOT" "$1"
}

write_routing_table() {
  tmux_runtime_write_routing_table "$1" || fail 'cannot write routing table'
}

read_routing_table() {
  local registry="$1" path="$TMUX_RUNTIME_BUS_ROOT/routing-table.json"
  tmux_runtime_private_file "$path" || fail 'routing table is unavailable'
  jq -e --argjson registry "$registry" '
    def token: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$");
    def target: . == null or (type == "string" and test("^[A-Za-z0-9][A-Za-z0-9:._-]*$"));
    . as $table | .schema_version == 1 and (.routes | type == "object")
    and ((.routes | keys | sort) == ($registry.routes | keys | sort))
    and all(.routes | to_entries[]; .key | token)
    and all(.routes | to_entries[]; . as $route | ($route.value | type == "object" and .agent_id == $route.key and (.inbox == $route.key) and ((.session_id == null) or (.session_id | token)) and ((.contract_id == null) or (.contract_id | token)) and (.tmux_target | target)))
    and (.routes[($registry.main.agent_id)].session_id == $registry.main.session_id)
    and (.routes[($registry.main.agent_id)].contract_id == null)
    and all($registry.agents[] | select(.state != "shutdown"); . as $agent | ($table.routes[$agent.agent_id].session_id == $agent.claude_session_id and $table.routes[$agent.agent_id].contract_id == $agent.contract_id))
  ' "$path" >/dev/null 2>&1 || fail 'routing table is malformed or does not match the registry'
  cat "$path"
}

require_principal() {
  local agent_id="$1" session_id="$2" role="$3" capability="$4" main_only="$5" registry
  tmux_runtime_require_bus
  tmux_runtime_lock_acquire registry 5000 30000
  registry=$(tmux_runtime_registry_read)
  tmux_runtime_principal_valid "$registry" "$agent_id" "$session_id" "$role" "$capability" || fail 'principal session, role, or capability is invalid'
  if [ "$main_only" = true ]; then
    [ "$role" = orchestrator ] && [ "$agent_id" = "$(jq -r '.main.agent_id' <<<"$registry")" ] || fail 'operation requires the main orchestrator'
  fi
  read_routing_table "$registry" >/dev/null
  tmux_runtime_lock_release registry
  printf '%s\n' "$registry"
}

delivery_destination() {
  local inbox="$1" sender="$2" message_type="$3"
  if [ "$message_type" = heartbeat ]; then
    printf '%s\n' "$inbox/heartbeat.$sender.json"
  else
    printf '%s\n' "$inbox/$message_type.json"
  fi
}

write_delivery_slot() {
  local existing="$1" destination="$2" message_type="$3" message_id="$4" envelope="$5"
  if [ -e "$existing" ]; then
    validate_envelope_file "$existing"
    if [ "$(jq -r '.message_id' "$existing")" != "$message_id" ]; then
      [ "$existing" = "$destination" ] && [ "$message_type" = heartbeat ] || fail "delivery destination is occupied: $existing"
      tmux_runtime_atomic_json "$existing" "$envelope"
    fi
  else
    tmux_runtime_atomic_json "$existing" "$envelope"
  fi
}

deliver_transaction() {
  local message_id="$1" transaction_path transaction envelope recipient sender message_type inbox destination audit existing registry routes
  transaction_path=$(transaction_path "$message_id")
  tmux_runtime_private_file "$transaction_path"
  jq -e '.schema_version == 1 and .kind == "delivery" and (.state | IN("prepared", "committed")) and .message_id == $id and (.envelope | type == "object")' --arg id "$message_id" "$transaction_path" >/dev/null 2>&1 || fail "delivery transaction is malformed: $message_id"
  transaction=$(cat "$transaction_path")
  envelope=$(jq -c '.envelope' <<<"$transaction")
  validate_envelope_document <<<"$envelope" || fail "delivery transaction envelope is malformed: $message_id"
  recipient=$(jq -r '.to.agent_id' <<<"$envelope")
  sender=$(jq -r '.from.agent_id' <<<"$envelope")
  message_type=$(jq -r '.type' <<<"$envelope")
  registry=$(tmux_runtime_registry_read)
  routes=$(read_routing_table "$registry")
  inbox=$(tmux_runtime_inbox "$(jq -r --arg recipient "$recipient" '.routes[$recipient].inbox' <<<"$routes")")
  tmux_runtime_private_directory "$inbox"
  tmux_runtime_private_directory "$inbox/acked"
  destination=$(delivery_destination "$inbox" "$sender" "$message_type")
  audit="$TMUX_RUNTIME_BUS_ROOT/outbox/main/$message_id.json"
  for existing in "$destination" "$audit"; do
    write_delivery_slot "$existing" "$destination" "$message_type" "$message_id" "$envelope"
  done
  transaction=$(jq '.state = "committed" | .committed_at_ms = $now' --argjson now "$(tmux_runtime_now_ms)" <<<"$transaction")
  tmux_runtime_atomic_json "$transaction_path" "$transaction"
}
