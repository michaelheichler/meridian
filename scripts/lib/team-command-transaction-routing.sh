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
  local engineer="$1" out_record="$2" route_json merged_config workflow_effort
  route_json=$(bash "$SCRIPT_DIR/lbwc-routing.sh" resolve "$ACTIVE_CONTROL_ROOT" "$engineer") \
    || fail "route resolution failed for '$engineer': $route_json"
  merged_config=$(lbwc_merged_config "$ACTIVE_CONTROL_ROOT/config.json")
  workflow_effort=$(jq -r '.effort // "balanced"' <<< "$merged_config")
  case "$workflow_effort" in thorough|balanced|fast|turbo) ;; *) workflow_effort="balanced" ;; esac
  printf -v "$out_record" '%s' "$(jq -c --arg workflow_effort "$workflow_effort" '{
    mode: "saved", profile: .profile, model: .model, reasoning: .reasoning,
    effort: (if .reasoning == null then "" else .reasoning end),
    workflow_effort: $workflow_effort, catalog: null}' <<< "$route_json")"
}

resolve_routing_seeded() {
  local out_record="$1" binary_path catalog_json model reasoning
  binary_path="${CLAUDE_CODE_EXECPATH:-}"
  if [ -z "$binary_path" ]; then
    binary_path=$(command -v claude 2>/dev/null || true)
  fi
  [ -n "$binary_path" ] && [ -f "$binary_path" ] \
    || fail "routing authority requires an initialized .lbwc-planning or the Claude Code executable; run /lbwc:models refresh first or install Claude Code"
  catalog_json=$(bash "$SCRIPT_DIR/claude-capabilities.sh" refresh-from-binary "$binary_path") \
    || fail "could not extract capability catalog from $binary_path"
  require_file "$SCRIPT_DIR/lib/seeded-host-model.jq" 'seeded host model filter not found'
  model=$(jq -r -f "$SCRIPT_DIR/lib/seeded-host-model.jq" <<< "$catalog_json")
  [ -n "$model" ] && [ "$model" != "null" ] \
    || fail "no native host model in capability catalog"
  reasoning=$(jq -c '.reasoning.accepted_values[] | select(. == "high")' <<< "$catalog_json" | head -1)
  [ -n "$reasoning" ] || fail "no high reasoning value in capability catalog"
  printf -v "$out_record" '%s' "$(jq -cn --arg model "$model" --argjson reasoning "$reasoning" --arg catalog "$catalog_json" '{
    mode: "seeded", profile: "balanced", model: $model, reasoning: $reasoning, effort: "high",
    workflow_effort: "balanced", catalog: $catalog}')"
}

resolve_routing_max_turns() {
  local engineer="$1" workflow_effort="$2" out_turns="$3" num den base_turns turns
  case "$workflow_effort" in
    thorough) num=3; den=2 ;;
    balanced) num=1; den=1 ;;
    fast) num=4; den=5 ;;
    turbo) num=3; den=5 ;;
  esac
  base_turns=$(jq -r --arg role "$engineer" '.[$role].maxTurns // empty' "$ROLE_DEFAULTS_PATH")
  case "$base_turns" in
    ''|*[!0-9]*) fail "no maxTurns default for role '$engineer' in $ROLE_DEFAULTS_PATH" ;;
  esac
  turns=$(( (base_turns * num + den / 2) / den ))
  [ "$turns" -ge 1 ] || turns=1
  printf -v "$out_turns" '%s' "$turns"
}

resolve_routing() {
  local engineer="$1" out_record="$2" record workflow_effort max_turns
  if [ "$CONTROL_ROOT_KIND" = "active-planning" ] && planning_routing_available; then
    resolve_routing_saved "$engineer" record
  else
    resolve_routing_seeded record
  fi
  workflow_effort=$(jq -r '.workflow_effort' <<< "$record")
  resolve_routing_max_turns "$engineer" "$workflow_effort" max_turns
  printf -v "$out_record" '%s' "$(jq -c --argjson turns "$max_turns" '. + {max_turns: $turns} | del(.workflow_effort)' <<< "$record")"
}
