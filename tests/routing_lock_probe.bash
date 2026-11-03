#!/usr/bin/env bash
set -euo pipefail

source "$1"
shift

hold_platform_guard() {
  configure_platform_tools
  LOCK_FD=8
  exec 8>> "$1"
  invoke_lock_backend "$LOCK_BACKEND" "$LOCK_TOOL" "$LOCK_FD"
  [ "$#" -gt 1 ] || return 0
  printf '%s\n' "$LOCK_TOOL" > "$2"
  : > "$3"
  local attempt
  for ((attempt = 0; attempt < 3000; attempt++)); do
    [ ! -e "$4" ] || return 0
    sleep 0.01
  done
  return 1
}

"$@"
