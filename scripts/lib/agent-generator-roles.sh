PAIR_ROLE=""
TRIO_ROLES=()
TEAM_ROLES=()
RESOLVER_ARGS=()
RESOLVER_OUTPUT=""
TEMPORARY_CONTROL_ROOT=false

is_valid_role() { jq -e --arg role "$1" 'has($role)' "$ROLE_DEFAULTS_PATH" >/dev/null 2>&1; }

role_is_on_team() {
  local candidate="$1" role
  for role in "${TEAM_ROLES[@]}"; do
    [ "$role" = "$candidate" ] && return 0
  done
  return 1
}

role_is_critic() {
  case "$1" in
    *critic) return 0 ;;
    *) return 1 ;;
  esac
}

parse_resolved_settings() {
  local settings="$1" line key raw
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key=${line%%=*}
    case "$key" in
      RESOLVED_AGENT|RESOLVED_AGENT_MODEL|RESOLVED_MODEL|RESOLVED_MAX_TURNS|RESOLVED_EFFORT|RESOLVED_REASONING|RESOLVED_REASONING_JSON) ;;
      *) fail "invalid resolver assignment '$key'" ;;
    esac
    raw=${line#*=}
    [[ "$raw" == \'*\' ]] || fail "invalid resolver value for $key"
    raw=${raw:1:${#raw}-2}
    raw=${raw//"'\\''"/"'"}
    printf -v "$key" '%s' "$raw"
  done <<< "$settings"
}

build_resolver_args() {
  local role="$1" pair token override_value
  RESOLVER_ARGS=("$role")
  if [ "$TEMPORARY_CONTROL_ROOT" = true ]; then
    RESOLVER_ARGS+=(--routing "$CONFIG_PATH")
  else
    RESOLVER_ARGS+=("$CONFIG_PATH")
  fi
  RESOLVER_ARGS+=("$PLUGIN_ROOT")
  for pair in MODEL:--model EFFORT:--effort REASONING:--reasoning MAX_TURNS:--max-turns; do
    token="${pair%%:*}"
    if keyed_has OVERRIDES "$token"; then
      keyed_get_into override_value OVERRIDES "$token"
      RESOLVER_ARGS+=("${pair#*:}" "$override_value")
    fi
  done
}

run_settings_resolver() {
  local role="$1" rc=0 settings_script
  settings_script="${LBWC_AGENT_SETTINGS_SCRIPT:-$SCRIPT_DIR/resolve-agent-settings.sh}"
  [ -f "$settings_script" ] || fail "agent settings resolver not found"
  TEMPORARY_CONTROL_ROOT=false
  if [ "$(basename "$CONTROL_ROOT")" != ".lbwc-planning" ]; then
    TEMPORARY_CONTROL_ROOT=true
  fi
  build_resolver_args "$role"
  RESOLVER_OUTPUT=$(bash "$settings_script" "${RESOLVER_ARGS[@]}" 2>&1) || rc=$?
  if [ "$rc" -eq 3 ]; then
    fail "unknown model while resolving settings for '$role': $RESOLVER_OUTPUT"
  elif [ "$rc" -ne 0 ]; then
    fail "$RESOLVER_OUTPUT"
  fi
}

resolve_role_settings() {
  local role="$1"
  run_settings_resolver "$role"
  RESOLVED_AGENT_MODEL=""
  RESOLVED_REASONING_JSON=""
  parse_resolved_settings "$RESOLVER_OUTPUT"
  [ -n "$RESOLVED_AGENT_MODEL" ] || fail "resolver omitted the Claude Code model selector for '$role'"
  [ -n "$RESOLVED_MAX_TURNS" ] || fail "resolver omitted the max turns value for '$role'"
  jq -e 'type == "string" or . == null' <<< "$RESOLVED_REASONING_JSON" >/dev/null 2>&1 \
    || fail "resolver emitted invalid reasoning JSON for '$role'"
  keyed_set ROLE_MODEL "$role" "$RESOLVED_AGENT_MODEL"
  keyed_set ROLE_EFFORT "$role" "$RESOLVED_EFFORT"
  keyed_set ROLE_REASONING_JSON "$role" "$RESOLVED_REASONING_JSON"
  keyed_set ROLE_MAXTURNS "$role" "$RESOLVED_MAX_TURNS"
}

resolve_pair_role() {
  if [ -n "$PAIR_ROLE_ARG" ]; then
    PAIR_ROLE="$PAIR_ROLE_ARG"
  else
    PAIR_ROLE=$(jq -r --arg r "$ROLE" '.[$r].pairsWith // empty' "$TEMPLATE_DEFAULTS")
  fi
  [ -n "$PAIR_ROLE" ] || fail "--pair requires defaults.json's '$ROLE.pairsWith' or an explicit --pair-role"
  is_valid_role "$PAIR_ROLE" || fail "invalid pair role '$PAIR_ROLE'"
  resolve_role_settings "$PAIR_ROLE"
}

resolve_trio_roles() {
  local trio_role
  TRIO_ROLES=()
  while IFS= read -r trio_role; do
    TRIO_ROLES+=("$trio_role")
  done < <(jq -r --arg r "$ROLE" '.trios[$r] // [] | .[]' "$TEMPLATE_DEFAULTS")
  [ "${#TRIO_ROLES[@]}" -ge 2 ] || fail "--trio requires defaults.json's 'trios.$ROLE' to list at least 2 roles"
  for trio_role in "${TRIO_ROLES[@]}"; do
    is_valid_role "$trio_role" || fail "invalid trio role '$trio_role'"
    [ "$trio_role" = "$ROLE" ] || resolve_role_settings "$trio_role"
  done
}

resolve_team_settings() {
  resolve_role_settings "$ROLE"
  if [ -n "$PAIR_MODE" ]; then
    resolve_pair_role
  fi
  if [ -n "$TRIO_MODE" ]; then
    resolve_trio_roles
  fi
  TEAM_ROLES=("$ROLE")
  if [ -n "$PAIR_MODE" ]; then
    TEAM_ROLES+=("$PAIR_ROLE")
  elif [ -n "$TRIO_MODE" ]; then
    TEAM_ROLES=("${TRIO_ROLES[@]}")
  fi
}
