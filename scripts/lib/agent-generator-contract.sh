CONTRACT_ID=""
CONTRACT_DIGEST=""
CONTRACT_ALLOWANCES_JSON='[]'
CONTRACT_CAPABILITIES_JSON='[]'
CONTRACT_SCHEMA_VERSION=2
CONTRACT_RUNTIME_KIND=""
CONTRACT_COMMUNICATION_POLICY=""
CONTRACT_REQUESTED_BACKEND=""
CONTRACT_RESOLVED_BACKEND=""
CONTRACT_CAPABILITY_ARGS_JSON='[]'
declare -A CONTRACT_ROLE_CAPABILITIES=()
CONTRACT_JSON=""
PROJECT_ROOT=""
CONTROL_ROOT=""
CONFIG_PATH=""
PLANNING_DIR=""
TEMPLATE_DEFAULTS=""
AGENTS_DIR=""

resolve_contract_file() {
  local path root
  path="$CONTRACT_PATH"
  [[ "$path" = /* ]] || path="$PWD/$path"
  path=$(CDPATH='' cd -- "$(dirname "$path")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename "$path")") || fail "contract path is unavailable"
  declare -g CONTRACT_PATH="$path"
  [ -f "$path" ] || fail "contract not found: $path"
  root=$(jq -r '.project_root // empty' "$path" 2>/dev/null) || fail "invalid contract"
  [ -n "$root" ] || fail "contract project root is required"
  root=$(CDPATH='' cd -- "$root" 2>/dev/null && pwd -P) || fail "contract project root is unavailable"
  declare -g PROJECT_ROOT="$root"
}

resolve_schema3_control_root() {
  local contract_control_root control_root
  contract_control_root=$(jq -r '.control_root // empty' "$CONTRACT_PATH" 2>/dev/null) || fail "invalid contract"
  [ -n "$CONTROL_ROOT_ARG" ] || declare -g CONTROL_ROOT_ARG="$contract_control_root"
  control_root=$(lbwc_control_root_validate "$CONTROL_ROOT_ARG" 0) || fail "control root is unavailable or invalid"
  declare -g CONTROL_ROOT="$control_root"
  contract_control_root=$(lbwc_control_root_validate "$contract_control_root" 0) || fail "contract control root is unavailable"
  [ "$control_root" = "$contract_control_root" ] || fail "contract control root mismatch"
}

resolve_control_root() {
  local schema_preview control_root
  schema_preview=$(jq -r '.schema_version // empty' "$CONTRACT_PATH" 2>/dev/null) || fail "invalid contract"
  if [ "$schema_preview" = "3" ]; then
    resolve_schema3_control_root
  else
    [ "$schema_preview" = "2" ] || fail "unsupported contract schema"
    [ -z "$CONTROL_ROOT_ARG" ] || fail "schema 2 contract does not accept --control-root"
    control_root=$(lbwc_control_root_validate "$PROJECT_ROOT/.lbwc-planning" 1) || fail "active planning control root is unavailable"
    declare -g CONTROL_ROOT="$control_root"
  fi
}

write_temporary_routing() {
  local temporary="${CONFIG_PATH}.tmp.${BASHPID:-$$}"
  jq -cn '{schema_version:1,routing_source:"temporary-control-root",routing:{active_profile:"balanced",profiles:{balanced:{roles:{}}}}}' > "$temporary" \
    || fail "could not write temporary routing configuration: $CONFIG_PATH"
  mv -f "$temporary" "$CONFIG_PATH" || { rm -f "$temporary"; fail "could not persist temporary routing configuration: $CONFIG_PATH"; }
}

resolve_config_path() {
  declare -g PLANNING_DIR="$CONTROL_ROOT"
  if [ "$(basename "$CONTROL_ROOT")" = ".lbwc-planning" ]; then
    declare -g CONFIG_PATH="$CONTROL_ROOT/config.json"
    return
  fi
  declare -g CONFIG_PATH="$CONTROL_ROOT/routing.json"
  if [ ! -f "$CONFIG_PATH" ]; then
    write_temporary_routing
  fi
}

resolve_contract_context() {
  resolve_contract_file
  resolve_control_root
  resolve_config_path
  declare -g TEMPLATE_DEFAULTS="$PLUGIN_ROOT/templates/agent-roles/defaults.json"
  [ -f "$TEMPLATE_DEFAULTS" ] || fail "role defaults not found: $TEMPLATE_DEFAULTS"
  declare -g AGENTS_DIR="$PROJECT_ROOT/.claude/agents"
  if [ -n "$NATIVE_TEAM_MODE" ]; then
    mkdir -p "$CONTROL_ROOT/generated-agents"
  fi
}

load_contract_json() {
  local raw
  raw=$(bash "$SCRIPT_DIR/task-contract.sh" verify "$CONTRACT_PATH" "$PROJECT_ROOT" --job "$JOB" 2>&1) || fail "$raw"
  CONTRACT_JSON=$(jq -ce 'select(type == "object")' <<< "$raw" 2>/dev/null) || fail "invalid contract"
}

check_contract_header() {
  local root
  CONTRACT_DIGEST=$(jq -r '.contract_digest // empty' <<< "$CONTRACT_JSON")
  [ -n "$CONTRACT_DIGEST" ] || fail "contract digest is required"
  root=$(jq -r '.project_root // .canonical_project_root // empty' <<< "$CONTRACT_JSON")
  [ -n "$root" ] || fail "contract project root is required"
  root=$(CDPATH='' cd -- "$root" 2>/dev/null && pwd -P) || fail "contract project root is unavailable"
  [ "$root" = "$PROJECT_ROOT" ] || fail "contract project root mismatch"
  jq -e '(.schema_version == 2 or .schema_version == 3) and .created_by == "main" and .state == "planned"' <<< "$CONTRACT_JSON" >/dev/null || fail "contract must be a planned main-session contract"
  CONTRACT_SCHEMA_VERSION=$(jq -r '.schema_version' <<< "$CONTRACT_JSON")
}

check_contract_backends() {
  local requested resolved
  requested=$(jq -r '.requested_backend // empty' <<< "$CONTRACT_JSON")
  resolved=$(jq -r '.resolved_backend // empty' <<< "$CONTRACT_JSON")
  case "$requested" in in_process|tmux|workflow) ;; *) fail "contract requested backend is invalid" ;; esac
  case "$resolved" in in_process|tmux|workflow) ;; *) fail "contract resolved backend is invalid" ;; esac
  [ "$requested" = "$resolved" ] || fail "contract backend resolution is invalid"
  CONTRACT_REQUESTED_BACKEND="$requested"
  CONTRACT_RESOLVED_BACKEND="$resolved"
}

check_contract_capabilities() {
  local contract_role
  CONTRACT_CAPABILITY_ARGS_JSON=$(printf '%s\n' "${WRITE_CAPABILITIES[@]}" | jq -Rsc 'split("\n") | map(select(length > 0) | (split(":")) | select(length == 2) | {access:"write",kind:.[0],path:.[1]})')
  jq -ne --argjson requested "$CONTRACT_CAPABILITY_ARGS_JSON" --argjson allowed "$CONTRACT_CAPABILITIES_JSON" '$requested == $allowed' >/dev/null || fail "write capabilities do not match contract"
  for contract_role in $(jq -r '.roles[]' <<< "$CONTRACT_JSON"); do
    CONTRACT_ROLE_CAPABILITIES["$contract_role"]=$(jq -ce --arg role "$contract_role" '.capabilities_by_role[$role] // []' <<< "$CONTRACT_JSON") || fail "contract capabilities are invalid"
  done
}

check_contract_v3_fields() {
  local contract_control_root
  contract_control_root=$(jq -r '.control_root // empty' <<< "$CONTRACT_JSON")
  [ -n "$contract_control_root" ] || fail "contract control root is required"
  contract_control_root=$(lbwc_control_root_validate "$contract_control_root" 0) || fail "contract control root is unavailable"
  [ "$contract_control_root" = "$CONTROL_ROOT" ] || fail "contract control root mismatch"
  CONTRACT_CAPABILITIES_JSON=$(jq -ce --arg role "$ROLE" '.capabilities_by_role[$role] | select(type == "array")' <<< "$CONTRACT_JSON") || fail "contract capabilities are invalid"
  CONTRACT_RUNTIME_KIND=$(jq -r '.runtime_kind // empty' <<< "$CONTRACT_JSON")
  CONTRACT_COMMUNICATION_POLICY=$(jq -r '.communication_policy // empty' <<< "$CONTRACT_JSON")
  check_contract_backends
  check_contract_capabilities
}

check_contract_identity() {
  local task
  task=$(jq -r '.task_identity // .task_id // .contract_id // empty' <<< "$CONTRACT_JSON")
  [ -n "$task" ] || fail "contract task identity is required"
  [ -n "$TASK_ID" ] || TASK_ID="$task"
  [ "$TASK_ID" = "$task" ] || fail "contract task identity mismatch"
  CONTRACT_ID=$(jq -r '.contract_id // .id // empty' <<< "$CONTRACT_JSON")
  [ -n "$CONTRACT_ID" ] || fail "contract id is required"
  jq -e --arg role "$ROLE" '(.roles | type == "array" and index($role) != null)' <<< "$CONTRACT_JSON" >/dev/null || fail "contract role mismatch"
}

check_contract_allowances() {
  local requested
  CONTRACT_ALLOWANCES_JSON=$(jq -ce --arg role "$ROLE" '.allowances_by_role[$role] | select(type == "array" and all(.[]; type == "string"))' <<< "$CONTRACT_JSON") || fail "contract write allowances are invalid"
  if [ "$CONTRACT_SCHEMA_VERSION" = "2" ]; then
    requested=$(printf '%s\n' "${WRITE_ALLOWANCES[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')
    jq -ne --argjson requested "$requested" --argjson allowed "$CONTRACT_ALLOWANCES_JSON" '$requested == $allowed' >/dev/null || fail "write allowances do not match contract"
  fi
  case "$ROLE" in
    *critic) [ "$CONTRACT_ALLOWANCES_JSON" = '[]' ] || fail "contract grants allowances to critic" ;;
  esac
}

validate_contract() {
  load_contract_json
  check_contract_header
  [ "$CONTRACT_SCHEMA_VERSION" != "3" ] || check_contract_v3_fields
  check_contract_identity
  check_contract_allowances
}

validate_execution_backend_override() {
  [ -n "$EXECUTION_BACKEND_OVERRIDE" ] || return 0
  case "$EXECUTION_BACKEND_OVERRIDE" in
    in_process|tmux|workflow) ;;
    *) fail "invalid execution backend override '$EXECUTION_BACKEND_OVERRIDE'" ;;
  esac
  [ "$CONTRACT_SCHEMA_VERSION" = "3" ] || fail "execution backend overrides require a schema 3 contract"
  [ "$EXECUTION_BACKEND_OVERRIDE" = "$CONTRACT_REQUESTED_BACKEND" ] \
    && [ "$EXECUTION_BACKEND_OVERRIDE" = "$CONTRACT_RESOLVED_BACKEND" ] \
    || fail "execution backend override conflicts with contract"
}

build_capabilities_json() {
  local role="$1" raw kind path role_capability_index
  if [ "$CONTRACT_SCHEMA_VERSION" != "3" ]; then
    printf '%s\n' '[]'
    return
  fi
  if [ "$role" = "$ROLE" ]; then
    printf '%s\n' "$CONTRACT_CAPABILITY_ARGS_JSON"
    return
  fi
  for role_capability_index in "${!ROLE_WRITE_CAPABILITY_ROLES[@]}"; do
    if [ "${ROLE_WRITE_CAPABILITY_ROLES[$role_capability_index]}" = "$role" ]; then
      raw="${ROLE_WRITE_CAPABILITY_VALUES[$role_capability_index]}"
      kind="${raw%%:*}"
      path="${raw#*:}"
      jq -cn --arg kind "$kind" --arg path "$path" '[{access:"write",kind:$kind,path:$path}]'
      return
    fi
  done
  printf '%s\n' '[]'
}

expected_role_allowances() {
  local team_role="$1" index expected='[]'
  if [ "$team_role" = "$ROLE" ]; then
    printf '%s\n' "${WRITE_ALLOWANCES[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))'
    return
  fi
  for index in "${!ROLE_WRITE_ALLOWANCE_ROLES[@]}"; do
    [ "${ROLE_WRITE_ALLOWANCE_ROLES[$index]}" = "$team_role" ] || continue
    expected=$(jq -c --arg path "${ROLE_WRITE_ALLOWANCE_PATHS[$index]}" '. + [$path]' <<< "$expected")
  done
  printf '%s\n' "$expected"
}

check_team_role_contract() {
  local team_role="$1" role_allowances expected capability_json
  role_allowances=$(jq -c --arg role "$team_role" '.allowances_by_role[$role]' "$CONTRACT_PATH")
  if [ "$CONTRACT_SCHEMA_VERSION" = "3" ]; then
    capability_json=$(build_capabilities_json "$team_role")
    [ "$capability_json" = "${CONTRACT_ROLE_CAPABILITIES[$team_role]}" ] || fail "contract capabilities mismatch for '$team_role'"
    return
  fi
  expected=$(expected_role_allowances "$team_role")
  [ "$role_allowances" = "$expected" ] || fail "contract allowances mismatch for '$team_role'"
}

validate_team_contract_roles() {
  local team_role requested_roles mode
  if [ -n "$PAIR_MODE" ]; then mode="pair"; elif [ -n "$TRIO_MODE" ]; then mode="trio"; else mode="solo"; fi
  requested_roles=$(printf '%s\n' "${TEAM_ROLES[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')
  jq -e --arg mode "$mode" --argjson roles "$requested_roles" '.team_mode == $mode and .roles == $roles' "$CONTRACT_PATH" >/dev/null 2>&1 || fail "contract team mismatch"
  for team_role in "${TEAM_ROLES[@]}"; do
    check_team_role_contract "$team_role"
  done
}
