build_overrides_json() {
  local json='{}' token
  for token in "${!OVERRIDES[@]}"; do
    json=$(jq -c --arg key "$token" --arg value "${OVERRIDES[$token]}" '.[$key] = $value' <<< "$json")
  done
  printf '%s\n' "$json"
}

append_json_path() {
  jq -c --arg path "$2" '. + [$path]' <<< "$1"
}

build_write_allowances_json() {
  local role="$1" json='[]' path i
  if [ "$CONTRACT_SCHEMA_VERSION" = "3" ]; then
    jq -c --arg role "$role" '[.capabilities_by_role[$role][]?.path]' "$CONTRACT_PATH"
    return
  fi
  if role_is_critic "$role"; then
    printf '%s\n' "$json"
    return
  fi
  if [ "$role" = "$ROLE" ]; then
    for path in "${WRITE_ALLOWANCES[@]}"; do
      json=$(append_json_path "$json" "$path")
    done
  fi
  for i in "${!ROLE_WRITE_ALLOWANCE_ROLES[@]}"; do
    [ "${ROLE_WRITE_ALLOWANCE_ROLES[$i]}" = "$role" ] || continue
    json=$(append_json_path "$json" "${ROLE_WRITE_ALLOWANCE_PATHS[$i]}")
  done
  printf '%s\n' "$json"
}

execution_metadata_json() {
  local name="$1" role="$2"
  jq -cn \
    --arg role "$role" --arg model "${ROLE_MODEL[$role]}" --argjson effort "${ROLE_REASONING_JSON[$role]:-null}" \
    --arg max_turns "${ROLE_MAXTURNS[$role]}" --arg contract_id "$CONTRACT_ID" \
    --arg contract_digest "$CONTRACT_DIGEST" --arg task_identity "$TASK_ID" \
    --arg requested_backend "$CONTRACT_REQUESTED_BACKEND" --arg resolved_backend "$CONTRACT_RESOLVED_BACKEND" \
    --arg name "$name" --arg control_root "$CONTROL_ROOT" \
    '{role:$role,model:$model,effort:$effort,max_turns:$max_turns,contract_id:$contract_id,contract_digest:$contract_digest,task_identity:$task_identity,requested_backend:$requested_backend,resolved_backend:$resolved_backend} + (if $resolved_backend == "tmux" then {tmux_bootstrap:{child_identity:$name,contract_id:$contract_id,control_root:$control_root}} else {} end)'
}

definition_header_value() {
  local key="$1" target="$2"
  grep -m1 "^${key}:" "$target" | sed "s/^${key}: \"//; s/\"\$//" || true
}

json_string_or_null() {
  if [ -n "$1" ]; then
    jq -n --arg v "$1" '$v'
  else
    printf 'null'
  fi
}

entry_base_json() {
  local name="$1" role="$2" target="$3" pair_id="$4" pair_role="$5" overrides="$6" allowances="$7"
  local tools disallowed_tools permission_mode initial_prompt definition_sha256 pid_json role_json
  tools=$(definition_header_value tools "$target")
  disallowed_tools=$(definition_header_value disallowedTools "$target")
  permission_mode=$(definition_header_value permissionMode "$target")
  initial_prompt=$(definition_header_value initialPrompt "$target")
  definition_sha256=$(shasum -a 256 "$target" | awk '{print $1}')
  pid_json=$(json_string_or_null "$pair_id")
  role_json=$(json_string_or_null "$pair_role")
  jq -cn \
    --arg name "$name" --arg role "$role" --arg project_root "$PROJECT_ROOT" \
    --arg definition_path "$target" --arg created_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg model "${ROLE_MODEL[$role]}" --argjson effort "${ROLE_REASONING_JSON[$role]:-null}" --arg max_turns "${ROLE_MAXTURNS[$role]}" \
    --argjson overrides "$overrides" --argjson allowances "$allowances" --argjson pair_id "$pid_json" --argjson pair_role "$role_json" \
    --arg control_root "$CONTROL_ROOT" --arg schema_version "$CONTRACT_SCHEMA_VERSION" --argjson capabilities "$(build_capabilities_json "$role")" \
    --arg tools "$tools" --arg disallowed_tools "$disallowed_tools" --arg permission_mode "$permission_mode" \
    --arg initial_prompt "$initial_prompt" --arg definition_sha256 "$definition_sha256" --arg job "$JOB" \
    '{name:$name,role:$role,project_root:$project_root,control_root:$control_root,schema_version:($schema_version|tonumber),definition_path:$definition_path,state:"registered",created_at:$created_at,model:$model,effort:$effort,max_turns:$max_turns,tools:$tools,disallowed_tools:$disallowed_tools,permission_mode:$permission_mode,initial_prompt:$initial_prompt,definition_sha256:$definition_sha256,job:$job,definition_authority:"generated-definition",overrides:$overrides,write_allowances:$allowances,capabilities:$capabilities,pair_id:$pair_id,pair_role:$pair_role}'
}

entry_with_contract_json() {
  local entry="$1" name="$2" role="$3" execution_json
  execution_json=$(execution_metadata_json "$name" "$role")
  jq -c \
    --arg schema_version "$CONTRACT_SCHEMA_VERSION" --argjson execution "$execution_json" \
    --arg runtime_kind "$CONTRACT_RUNTIME_KIND" --arg communication_policy "$CONTRACT_COMMUNICATION_POLICY" \
    --arg contract_path "$CONTRACT_PATH" --arg contract_id "$CONTRACT_ID" --arg contract_digest "$CONTRACT_DIGEST" --arg task_id "$TASK_ID" \
    '. + (if ($schema_version | tonumber) == 3 then {execution:$execution} else {} end) + (if $runtime_kind != "" then {runtime_kind:$runtime_kind,communication_policy:$communication_policy} else {} end) + (if $contract_id != "" then {contract_enabled:true,contract_path:$contract_path,contract_id:$contract_id,contract_digest:$contract_digest,task_identity:$task_id} else {} end)' <<< "$entry"
}

register_entry() {
  local entry
  entry=$(entry_base_json "$@")
  entry=$(entry_with_contract_json "$entry" "$1" "$2")
  MANIFEST=$(jq -c --arg name "$1" --argjson entry "$entry" '.agents[$name] = $entry' <<< "$MANIFEST")
}
