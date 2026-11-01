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
