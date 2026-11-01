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

role_default_turns() {
  local defaults_path="$1" role="$2" out_name="$3" raw
  raw=$(jq -r --arg role "$role" '.[$role].maxTurns | if . == null then "" else tostring end' "$defaults_path" 2>/dev/null) || return 1
  [ -n "$raw" ] || return 1
  normalize_turn_value "$raw" "$out_name"
}
