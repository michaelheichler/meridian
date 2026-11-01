#!/usr/bin/env bash
set -u

normalize_turn_value() {
  local value="$1" out_name="$2"
  case "$value" in
    false|FALSE|False|null|"") printf -v "$out_name" '%s' ''; return 0 ;;
    *[!0-9]*) return 1 ;;
  esac
  value=$((10#$value))
  [ "$value" -gt 0 ] || value=''
  printf -v "$out_name" '%s' "$value"
}

turn_multiplier() {
  local effort="$1" num_name="$2" den_name="$3"
  case "$effort" in
    thorough) printf -v "$num_name" '%s' 3; printf -v "$den_name" '%s' 2 ;;
    balanced) printf -v "$num_name" '%s' 1; printf -v "$den_name" '%s' 1 ;;
    fast) printf -v "$num_name" '%s' 4; printf -v "$den_name" '%s' 5 ;;
    turbo) printf -v "$num_name" '%s' 3; printf -v "$den_name" '%s' 5 ;;
    *) return 1 ;;
  esac
}

scale_turn_value() {
  local base="$1" effort="$2" out_name="$3" num den scaled
  turn_multiplier "$effort" num den || return 1
  if [ -z "$base" ]; then
    printf -v "$out_name" '%s' ''
    return 0
  fi
  scaled=$(( (base * num + den / 2) / den ))
  [ "$scaled" -ge 1 ] || scaled=1
  printf -v "$out_name" '%s' "$scaled"
}

role_is_dev_family() {
  case "$1" in
    coding-dijkstra|python-engineer|web-engineer|test-dev) return 0 ;;
    *) return 1 ;;
  esac
}

agent_max_turns_override() {
  local config_json="$1" role="$2" effort="$3" out_name="$4" family=false row key raw value
  ! role_is_dev_family "$role" || family=true
  row=$(jq -r --arg role "$role" --arg effort "$effort" --argjson family "$family" \
    -f "$(dirname "${BASH_SOURCE[0]}")/agent-max-turns.jq" <<< "$config_json" 2>/dev/null) || return 1
  [ -n "$row" ] || return 2
  key=${row%%$'\t'*}
  raw=${row#*$'\t'}
  if ! normalize_turn_value "$raw" value; then
    printf -v "$out_name" '%s' "agent_max_turns.$key value '$raw'"
    return 1
  fi
  printf -v "$out_name" '%s' "$value"
}

resolve_configured_turns() {
  local config_json="$1" defaults_path="$2" role="$3" effort="$4" out_name="$5" base rc=0 raw
  agent_max_turns_override "$config_json" "$role" "$effort" base || rc=$?
  case "$rc" in
    0) printf -v "$out_name" '%s' "$base"; return 0 ;;
    1) printf -v TURN_ERROR '%s' "invalid $base"; return 1 ;;
  esac
  raw=$(jq -r --arg role "$role" '.roles[$role].max_turns | if . == null then "" else tostring end' <<< "$config_json" 2>/dev/null) || raw=""
  if [ -n "$raw" ]; then
    normalize_turn_value "$raw" base || { printf -v TURN_ERROR '%s' "invalid roles.$role.max_turns value '$raw'"; return 1; }
  else
    role_default_turns "$defaults_path" "$role" base \
      || { printf -v TURN_ERROR '%s' "no max_turns resolved for role '$role': set roles.$role.max_turns in project config or $role.maxTurns in $defaults_path"; return 1; }
  fi
  scale_turn_value "$base" "$effort" "$out_name"
}

role_default_turns() {
  local defaults_path="$1" role="$2" out_name="$3" raw
  raw=$(jq -r --arg role "$role" '.[$role].maxTurns | if . == null then "" else tostring end' "$defaults_path" 2>/dev/null) || return 1
  [ -n "$raw" ] || return 1
  normalize_turn_value "$raw" "$out_name"
}
