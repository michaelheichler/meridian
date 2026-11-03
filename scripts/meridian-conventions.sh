#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JSON_OUTPUT=0
LOCK_DIR=""
LOCK_HELD=0
TEMP_PATH=""

. "$SCRIPT_DIR/lib/meridian-conventions-files.sh"
. "$SCRIPT_DIR/lib/meridian-conventions-artifact.sh"
. "$SCRIPT_DIR/lib/meridian-conventions-render.sh"
. "$SCRIPT_DIR/lib/meridian-conventions-commands.sh"

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit "${2:-2}"
}

usage() {
  printf '%s\n' 'Usage: meridian-conventions.sh [--json] <list|group|add|remove|reconcile|refresh> <planning-dir> [arguments]' >&2
  exit 2
}

cleanup() {
  [ -z "$TEMP_PATH" ] || rm -f -- "$TEMP_PATH" 2>/dev/null || true
  [ "$LOCK_HELD" -eq 0 ] || rmdir "$LOCK_DIR" 2>/dev/null || true
}

require_tools() {
  local tool
  for tool in chmod date dirname jq mktemp mkdir mv pwd readlink rm rmdir; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
  done
}

main() {
  local operation planning_dir value
  require_tools
  if [ "${1:-}" = '--json' ]; then JSON_OUTPUT=1; shift; fi
  operation="${1:-}"
  [ -n "$operation" ] || usage
  shift
  [ "$#" -ge 1 ] || usage
  planning_dir=$(resolve_planning_dir "$1")
  shift
  case "$operation" in
    list)
      [ "$#" -eq 0 ] || usage
      value=$(read_artifact "$planning_dir")
      if [ "$JSON_OUTPUT" -eq 1 ]; then compact_json "$value"; else render_table "$value"; fi
      ;;
    group)
      [ "$#" -eq 0 ] || usage
      value=$(read_artifact "$planning_dir")
      if [ "$JSON_OUTPUT" -eq 1 ]; then group_json "$value"; else render_grouped "$value"; render_next; fi
      ;;
    add) [ "$#" -ge 2 ] || usage; add_convention "$planning_dir" "$@" ;;
    remove) [ "$#" -ge 1 ] || usage; remove_convention "$planning_dir" "$@" ;;
    reconcile) [ "$#" -eq 1 ] || usage; run_reconcile "$planning_dir" "$1" 0 ;;
    refresh) [ "$#" -eq 1 ] || usage; run_reconcile "$planning_dir" "$1" 1 ;;
    *) usage ;;
  esac
}

trap cleanup EXIT HUP INT TERM
main "$@"
