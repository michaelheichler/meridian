split_validation_error() {
  printf -v SPLIT_VALIDATION_ERROR '%s' "$1"
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
  local out_manifest="$1" manifest_path loaded_manifest
  manifest_path=$(agent_manifest_path "$TMUX_RUNTIME_CONTROL_ROOT") || { split_validation_error 'generated agent manifest is unavailable'; return 1; }
  [ -f "$manifest_path" ] && [ ! -L "$manifest_path" ] || { split_validation_error 'generated agent manifest is missing'; return 1; }
  loaded_manifest=$(jq -ce 'select(type == "object" and (.agents | type == "object"))' "$manifest_path" 2>/dev/null) || { split_validation_error 'generated agent manifest is malformed'; return 1; }
  printf -v "$out_manifest" '%s' "$loaded_manifest"
}

check_item_identity() {
  local item="$1" out_agent="$2" out_contract="$3" out_digest="$4" item_agent item_generated item_contract item_digest value
  item_agent=$(jq -r '.agent_id' <<<"$item")
  item_generated=$(jq -r '.generated_name' <<<"$item")
  item_contract=$(jq -r '.contract_id' <<<"$item")
  item_digest=$(jq -r '.contract_digest' <<<"$item")
  for value in "$item_agent" "$item_generated" "$item_contract"; do
    tmux_runtime_valid_token "$value" || { split_validation_error 'agent group contains an invalid identifier'; return 1; }
  done
  [ "$item_agent" = "$item_generated" ] || { split_validation_error 'agent and generated identities must match'; return 1; }
  printf -v "$out_agent" '%s' "$item_agent"
  printf -v "$out_contract" '%s' "$item_contract"
  printf -v "$out_digest" '%s' "$item_digest"
}

check_item_manifest_entry() {
  local manifest="$1" agent_id="$2" contract_id="$3" contract_digest="$4" out_entry="$5" found_entry
  found_entry=$(jq -ce --arg name "$agent_id" '.agents[$name] | select(type == "object")' <<<"$manifest" 2>/dev/null) || { split_validation_error "generated agent is not registered: $agent_id"; return 1; }
  [ "$(jq -r '.name // empty' <<<"$found_entry")" = "$agent_id" ] || { split_validation_error 'generated manifest identity does not match agent id'; return 1; }
  [ "$(jq -r '.contract_id // empty' <<<"$found_entry")" = "$contract_id" ] || { split_validation_error 'contract identity does not match generated manifest'; return 1; }
  [ "$(jq -r '.contract_digest // empty' <<<"$found_entry")" = "$contract_digest" ] || { split_validation_error 'contract digest does not match generated manifest'; return 1; }
  jq -e '
    .schema_version == 3
    and .state == "registered"
    and .contract_enabled == true
    and .definition_authority == "generated-definition"
    and .runtime_kind == "native-team"
    and .communication_policy == "native-team"
  ' <<<"$found_entry" >/dev/null 2>&1 || { split_validation_error 'generated manifest entry is not an unconsumed schema 3 native-team definition'; return 1; }
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
  ' <<<"$found_entry" >/dev/null 2>&1 || { split_validation_error 'generated agent execution identity does not match the manifest'; return 1; }
  printf -v "$out_entry" '%s' "$found_entry"
}

check_item_contract() {
  local entry="$1" agent_id="$2" contract_id="$3" contract_digest="$4" contract_path contract
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
  local entry="$1" agent_id="$2" definition_path definition_digest
  definition_path=$(jq -r '.definition_path // empty' <<<"$entry")
  [ "$definition_path" = "$PROJECT_ROOT/.claude/agents/$agent_id.md" ] || { split_validation_error 'generated definition path is invalid'; return 1; }
  [ -f "$definition_path" ] && [ ! -L "$definition_path" ] || { split_validation_error 'generated definition is missing'; return 1; }
  definition_digest=$(shasum -a 256 "$definition_path" | cut -d ' ' -f 1) || { split_validation_error 'cannot hash generated definition'; return 1; }
  [ "$definition_digest" = "$(jq -r '.definition_sha256 // empty' <<<"$entry")" ] || { split_validation_error 'generated definition digest does not match manifest'; return 1; }
}

validate_split_item() {
  local item="$1" manifest="$2" agent_id contract_id contract_digest entry
  check_item_identity "$item" agent_id contract_id contract_digest || return 1
  check_item_manifest_entry "$manifest" "$agent_id" "$contract_id" "$contract_digest" entry || return 1
  check_item_contract "$entry" "$agent_id" "$contract_id" "$contract_digest" || return 1
  check_item_definition "$entry" "$agent_id" || return 1
}

validate_split_group_definitions() {
  local definitions="$1" manifest item
  SPLIT_VALIDATION_ERROR=''
  validate_definitions_shape "$definitions" || return 1
  load_validation_manifest manifest || return 1
  while IFS= read -r item; do
    validate_split_item "$item" "$manifest" || return 1
  done < <(jq -c '.[]' <<<"$definitions")
}
