# Prefixed locals, so a caller's output name cannot be shadowed.

normalize_turn_value() {
  local _ntv_value="$1" _ntv_out="$2"
  case "$_ntv_value" in
    false|FALSE|False|"") printf -v "$_ntv_out" '%s' ''; return 0 ;;
    null|*[!0-9]*) return 1 ;;
  esac
  _ntv_value=$((10#$_ntv_value))
  [ "$_ntv_value" -gt 0 ] || _ntv_value=''
  printf -v "$_ntv_out" '%s' "$_ntv_value"
}

turn_multiplier() {
  local _tm_effort="$1" _tm_num_out="$2" _tm_den_out="$3"
  case "$_tm_effort" in
    thorough) printf -v "$_tm_num_out" '%s' 3; printf -v "$_tm_den_out" '%s' 2 ;;
    balanced) printf -v "$_tm_num_out" '%s' 1; printf -v "$_tm_den_out" '%s' 1 ;;
    fast) printf -v "$_tm_num_out" '%s' 4; printf -v "$_tm_den_out" '%s' 5 ;;
    turbo) printf -v "$_tm_num_out" '%s' 3; printf -v "$_tm_den_out" '%s' 5 ;;
    *) return 1 ;;
  esac
}

scale_turn_value() {
  local _stv_base="$1" _stv_effort="$2" _stv_out="$3" _stv_num _stv_den _stv_scaled
  turn_multiplier "$_stv_effort" _stv_num _stv_den || return 1
  if [ -z "$_stv_base" ]; then
    printf -v "$_stv_out" '%s' ''
    return 0
  fi
  _stv_scaled=$(( (_stv_base * _stv_num + _stv_den / 2) / _stv_den ))
  [ "$_stv_scaled" -ge 1 ] || _stv_scaled=1
  printf -v "$_stv_out" '%s' "$_stv_scaled"
}

role_is_dev_family() {
  case "$1" in
    coding-dijkstra|python-engineer|web-engineer|test-dev) return 0 ;;
    *) return 1 ;;
  esac
}

agent_max_turns_override() {
  local _amto_config="$1" _amto_role="$2" _amto_effort="$3" _amto_out="$4"
  local _amto_family=false _amto_row _amto_key _amto_raw _amto_value
  ! role_is_dev_family "$_amto_role" || _amto_family=true
  _amto_row=$(jq -r --arg role "$_amto_role" --arg effort "$_amto_effort" --argjson family "$_amto_family" \
    -f "$(dirname "${BASH_SOURCE[0]}")/agent-max-turns.jq" <<< "$_amto_config" 2>/dev/null) || return 1
  [ -n "$_amto_row" ] || return 2
  _amto_key=${_amto_row%%$'\t'*}
  _amto_raw=${_amto_row#*$'\t'}
  if ! normalize_turn_value "$_amto_raw" _amto_value; then
    printf -v "$_amto_out" '%s' "agent_max_turns.$_amto_key value '$_amto_raw'"
    return 1
  fi
  printf -v "$_amto_out" '%s' "$_amto_value"
}

resolve_configured_turns() {
  local _rct_config="$1" _rct_defaults="$2" _rct_role="$3" _rct_effort="$4" _rct_out="$5" _rct_base _rct_raw _rct_rc=0
  agent_max_turns_override "$_rct_config" "$_rct_role" "$_rct_effort" _rct_base || _rct_rc=$?
  case "$_rct_rc" in
    0) printf -v "$_rct_out" '%s' "$_rct_base"; return 0 ;;
    1) printf -v TURN_ERROR '%s' "invalid $_rct_base"; return 1 ;;
  esac
  _rct_raw=$(jq -r --arg role "$_rct_role" '.roles[$role].max_turns | if . == null then "" else tostring end' <<< "$_rct_config" 2>/dev/null) || _rct_raw=""
  if [ -n "$_rct_raw" ]; then
    normalize_turn_value "$_rct_raw" _rct_base || { printf -v TURN_ERROR '%s' "invalid roles.$_rct_role.max_turns value '$_rct_raw'"; return 1; }
  else
    role_default_turns "$_rct_defaults" "$_rct_role" _rct_base \
      || { printf -v TURN_ERROR '%s' "no max_turns resolved for role '$_rct_role': set roles.$_rct_role.max_turns in project config or $_rct_role.maxTurns in $_rct_defaults"; return 1; }
  fi
  scale_turn_value "$_rct_base" "$_rct_effort" "$_rct_out"
}

role_default_turns() {
  local _rdt_defaults="$1" _rdt_role="$2" _rdt_out="$3" _rdt_raw
  _rdt_raw=$(jq -r --arg role "$_rdt_role" '.[$role].maxTurns | if . == null then "" else tostring end' "$_rdt_defaults" 2>/dev/null) || return 1
  [ -n "$_rdt_raw" ] || return 1
  normalize_turn_value "$_rdt_raw" "$_rdt_out"
}
