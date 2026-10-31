split_validation_error() {
  SPLIT_VALIDATION_ERROR="$1"
  return 1
}

validate_definitions_shape() {
  jq -e '
    type == "array" and length > 0
    and all(.[];
      type == "object"
      and ((keys | sort) == ["agent_id", "contract_digest", "contract_id", "generated_name"])
      and (.agent_id | type == "string")
      and (.generated_name | type == "string")
      and (.contract_id | type == "string")
      and (.contract_digest | type == "string" and test("^[0-9a-f]{64}$"))
    )
    and (([.[].agent_id] | length) == ([.[].agent_id] | unique | length))
  ' >/dev/null 2>&1 <<<"$1" || { split_validation_error 'agent group definitions must contain exact agent, generated, contract, and digest identities'; return 1; }
}

load_validation_manifest() {
  local manifest_path
  manifest_path=$(agent_manifest_path "$TMUX_RUNTIME_CONTROL_ROOT") || { split_validation_error 'generated agent manifest is unavailable'; return 1; }
  [ -f "$manifest_path" ] && [ ! -L "$manifest_path" ] || { split_validation_error 'generated agent manifest is missing'; return 1; }
  manifest=$(jq -ce 'select(type == "object" and (.agents | type == "object"))' "$manifest_path" 2>/dev/null) || { split_validation_error 'generated agent manifest is malformed'; return 1; }
}

# Shares validate_split_item locals because each check feeds the next.
check_item_identity() {
  local value
  agent_id=$(jq -r '.agent_id' <<<"$item")
  generated_name=$(jq -r '.generated_name' <<<"$item")
  contract_id=$(jq -r '.contract_id' <<<"$item")
  contract_digest=$(jq -r '.contract_digest' <<<"$item")
  for value in "$agent_id" "$generated_name" "$contract_id"; do
    tmux_runtime_valid_token "$value" || { split_validation_error 'agent group contains an invalid identifier'; return 1; }
  done
  [ "$agent_id" = "$generated_name" ] || { split_validation_error 'agent and generated identities must match'; return 1; }
}

check_item_manifest_entry() {
  entry=$(jq -ce --arg name "$agent_id" '.agents[$name] | select(type == "object")' <<<"$manifest" 2>/dev/null) || { split_validation_error "generated agent is not registered: $agent_id"; return 1; }
  [ "$(jq -r '.name // empty' <<<"$entry")" = "$agent_id" ] || { split_validation_error 'generated manifest identity does not match agent id'; return 1; }
  [ "$(jq -r '.contract_id // empty' <<<"$entry")" = "$contract_id" ] || { split_validation_error 'contract identity does not match generated manifest'; return 1; }
  [ "$(jq -r '.contract_digest // empty' <<<"$entry")" = "$contract_digest" ] || { split_validation_error 'contract digest does not match generated manifest'; return 1; }
  jq -e '
    .schema_version == 3
    and .state == "registered"
    and .contract_enabled == true
    and .definition_authority == "generated-definition"
    and .runtime_kind == "native-team"
    and .communication_policy == "native-team"
  ' <<<"$entry" >/dev/null 2>&1 || { split_validation_error 'generated manifest entry is not an unconsumed schema 3 native-team definition'; return 1; }
  jq -e '
    . as $entry
    | (.execution | type == "object")
    and .execution.role == $entry.role
    and .execution.model == $entry.model
    and .execution.effort == $entry.effort
    and .execution.max_turns == $entry.max_turns
    and .execution.contract_id == $entry.contract_id
    and .execution.contract_digest == $entry.contract_digest
    and .execution.task_identity == $entry.task_identity
  ' <<<"$entry" >/dev/null 2>&1 || { split_validation_error 'generated agent execution identity does not match the manifest'; return 1; }
}

check_item_contract() {
  local contract_path
  contract_path=$(jq -r '.contract_path // empty' <<<"$entry")
  [ -n "$contract_path" ] || { split_validation_error 'generated agent contract path is missing'; return 1; }
  contract=$(bash "$SCRIPT_DIR/task-contract.sh" verify "$contract_path" "$PROJECT_ROOT" 2>/dev/null) || { split_validation_error 'generated agent contract is missing, stale, or tampered'; return 1; }
  jq -e --arg id "$contract_id" --arg digest "$contract_digest" --arg control_root "$TMUX_RUNTIME_CONTROL_ROOT" '
    .schema_version == 3
    and .state == "dispatched"
    and .runtime_kind == "native-team"
    and .communication_policy == "native-team"
    and .control_root == $control_root
    and .contract_id == $id
    and .contract_digest == $digest
    and .task_identity == $id
    and .requested_backend == "tmux"
    and .resolved_backend == "tmux"
  ' <<<"$contract" >/dev/null 2>&1 || { split_validation_error 'generated agent contract does not match the schema 3 native-team pipeline'; return 1; }
  jq -e --arg name "$agent_id" --arg control_root "$TMUX_RUNTIME_CONTROL_ROOT" \
    --arg requested "$(jq -r '.requested_backend' <<<"$contract")" \
    --arg resolved "$(jq -r '.resolved_backend' <<<"$contract")" '
    . as $entry
    | ($entry.execution | type == "object")
    and $entry.execution.requested_backend == $requested
    and $entry.execution.resolved_backend == $resolved
    and ($entry.execution.tmux_bootstrap | type == "object")
    and $entry.execution.tmux_bootstrap.child_identity == $name
    and $entry.execution.tmux_bootstrap.contract_id == $entry.contract_id
    and $entry.execution.tmux_bootstrap.control_root == $control_root
  ' <<<"$entry" >/dev/null 2>&1 || { split_validation_error 'generated agent backend metadata does not match the contract'; return 1; }
}

check_item_definition() {
  local definition_path definition_digest
  definition_path=$(jq -r '.definition_path // empty' <<<"$entry")
  [ "$definition_path" = "$PROJECT_ROOT/.claude/agents/$agent_id.md" ] || { split_validation_error 'generated definition path is invalid'; return 1; }
  [ -f "$definition_path" ] && [ ! -L "$definition_path" ] || { split_validation_error 'generated definition is missing'; return 1; }
  definition_digest=$(shasum -a 256 "$definition_path" | cut -d ' ' -f 1) || { split_validation_error 'cannot hash generated definition'; return 1; }
  [ "$definition_digest" = "$(jq -r '.definition_sha256 // empty' <<<"$entry")" ] || { split_validation_error 'generated definition digest does not match manifest'; return 1; }
}

validate_split_item() {
  local item="$1" agent_id generated_name contract_id contract_digest entry contract
  check_item_identity || return 1
  check_item_manifest_entry || return 1
  check_item_contract || return 1
  check_item_definition || return 1
}

validate_split_group_definitions() {
  local definitions="$1" manifest item
  SPLIT_VALIDATION_ERROR=''
  validate_definitions_shape "$definitions" || return 1
  load_validation_manifest || return 1
  while IFS= read -r item; do
    validate_split_item "$item" || return 1
  done < <(jq -c '.[]' <<<"$definitions")
}
