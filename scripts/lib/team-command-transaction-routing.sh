WORKFLOW_EFFORT=""

resolve_active_control_root() {
  ACTIVE_CONTROL_ROOT=""
  CONTROL_ROOT_KIND="temporary-run"
  local candidate
  candidate=$(lbwc_control_root_validate "$PROJECT_ROOT/.lbwc-planning" 1 2>/dev/null) || return 0
  ACTIVE_CONTROL_ROOT="$candidate"
  CONTROL_ROOT_KIND="active-planning"
}

planning_routing_available() {
  [ -f "$ACTIVE_CONTROL_ROOT/config.json" ] || return 1
  jq -e 'type == "object"' "$ACTIVE_CONTROL_ROOT/config.json" >/dev/null 2>&1 || return 1
  jq -e '.routing | type == "object"' "$ACTIVE_CONTROL_ROOT/config.json" >/dev/null 2>&1
}

resolve_routing_saved() {
  local route_json merged_config
  ROUTING_MODE="saved"
  route_json=$(bash "$SCRIPT_DIR/lbwc-routing.sh" resolve "$ACTIVE_CONTROL_ROOT" "$ROSTER_ENGINEER") \
    || fail "route resolution failed for '$ROSTER_ENGINEER': $route_json"
  ROUTING_PROFILE=$(jq -r '.profile' <<< "$route_json")
  ROUTING_MODEL=$(jq -r '.model' <<< "$route_json")
  ROUTING_REASONING_JSON=$(jq -c '.reasoning' <<< "$route_json")
  ROUTING_EFFORT=$(jq -r 'if .reasoning == null then "" else .reasoning end' <<< "$route_json")
  merged_config=$(lbwc_merged_config "$ACTIVE_CONTROL_ROOT/config.json")
  WORKFLOW_EFFORT=$(jq -r '.effort // "balanced"' <<< "$merged_config")
  case "$WORKFLOW_EFFORT" in thorough|balanced|fast|turbo) ;; *) WORKFLOW_EFFORT="balanced" ;; esac
}

resolve_routing_seeded() {
  local binary_path catalog_json
  ROUTING_MODE="seeded"
  ROUTING_PROFILE="balanced"
  binary_path="${CLAUDE_CODE_EXECPATH:-}"
  if [ -z "$binary_path" ]; then
    binary_path=$(command -v claude 2>/dev/null || true)
  fi
  [ -n "$binary_path" ] && [ -f "$binary_path" ] \
    || fail "routing authority requires an initialized .lbwc-planning or the Claude Code executable; run /lbwc:models refresh first or install Claude Code"
  catalog_json=$(bash "$SCRIPT_DIR/claude-capabilities.sh" refresh-from-binary "$binary_path") \
    || fail "could not extract capability catalog from $binary_path"
  require_file "$SCRIPT_DIR/lib/seeded-host-model.jq" 'seeded host model filter not found'
  CATALOG_JSON="$catalog_json"
  ROUTING_MODEL=$(jq -r -f "$SCRIPT_DIR/lib/seeded-host-model.jq" <<< "$catalog_json")
  [ -n "$ROUTING_MODEL" ] && [ "$ROUTING_MODEL" != "null" ] \
    || fail "no native host model in capability catalog"
  ROUTING_REASONING_JSON=$(jq -c '.reasoning.accepted_values[] | select(. == "high")' <<< "$catalog_json" | head -1)
  [ -n "$ROUTING_REASONING_JSON" ] || fail "no high reasoning value in capability catalog"
  ROUTING_EFFORT="high"
  WORKFLOW_EFFORT="balanced"
}

resolve_routing_max_turns() {
  local num den base_turns
  case "$WORKFLOW_EFFORT" in
    thorough) num=3; den=2 ;;
    balanced) num=1; den=1 ;;
    fast) num=4; den=5 ;;
    turbo) num=3; den=5 ;;
  esac
  base_turns=$(jq -r --arg role "$ROSTER_ENGINEER" '.[$role].maxTurns // empty' "$ROLE_DEFAULTS_PATH")
  case "$base_turns" in
    ''|*[!0-9]*) fail "no maxTurns default for role '$ROSTER_ENGINEER' in $ROLE_DEFAULTS_PATH" ;;
  esac
  ROUTING_MAX_TURNS=$(( (base_turns * num + den / 2) / den ))
  [ "$ROUTING_MAX_TURNS" -ge 1 ] || ROUTING_MAX_TURNS=1
}

resolve_routing() {
  ROUTING_MODE=""
  ROUTING_PROFILE=""
  ROUTING_MODEL="unknown"
  ROUTING_EFFORT=""
  ROUTING_REASONING_JSON='null'
  ROUTING_MAX_TURNS=""
  WORKFLOW_EFFORT=""
  if [ "$CONTROL_ROOT_KIND" = "active-planning" ] && planning_routing_available; then
    resolve_routing_saved
  else
    resolve_routing_seeded
  fi
  resolve_routing_max_turns
}
