#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLE_DEFAULTS_PATH="$SCRIPT_DIR/../templates/agent-roles/defaults.json"
ENV_TOOL=""
LOCK_DIR=""
LOCK_DIR_IDENTITY=""
LOCK_BACKEND=""
LOCK_FD=9
LOCK_GUARD=""
LOCK_HELD=0
LOCK_TOKEN=""
LOCK_TOOL=""
LOCK_OWNER_RECORD=""
LOCK_STALE_AFTER_SECONDS=30
LOCK_WAIT_ATTEMPTS_DEFAULT=500
OD_TOOL=""
STAT_STYLE=""
STAT_TOOL=""
TRANSACTION_ACTIVE="${LBWC_CONFIG_TRANSACTION_ACTIVE:-0}"

. "$SCRIPT_DIR/lib/lbwc-routing-platform.sh"
. "$SCRIPT_DIR/lib/lbwc-routing-lock.sh"
. "$SCRIPT_DIR/lib/lbwc-routing-validate.sh"
. "$SCRIPT_DIR/lib/lbwc-routing-ops.sh"
. "$SCRIPT_DIR/lib/lbwc-routing-migrate.sh"

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

usage() {
  printf '%s\n' 'Usage: lbwc-routing.sh <set|check|activate|copy|resolve|validate|migrate|assert-transaction> <planning-dir> [arguments]' >&2
}

resolve_planning_directory() {
  local input="$1" trimmed parent physical_parent
  case "/$input/" in
    */../*) fail "planning directory traversal is not allowed: $input" ;;
  esac
  trimmed="$input"
  while [ "$trimmed" != "/" ] && [ "${trimmed%/}" != "$trimmed" ]; do
    trimmed=${trimmed%/}
  done
  [ ! -L "$trimmed" ] || fail "planning directory boundary must not be a symbolic link: $input"
  [ "${trimmed##*/}" = '.lbwc-planning' ] || fail "planning directory must end with .lbwc-planning: $input"
  [ -d "$trimmed" ] || fail "planning directory does not exist: $input"
  case "$trimmed" in
    */*)
      parent=${trimmed%/*}
      [ -n "$parent" ] || parent=/
      ;;
    *) parent=. ;;
  esac
  physical_parent=$(CDPATH='' cd -P -- "$parent" 2>/dev/null && pwd -P) || fail "could not resolve planning directory: $input"
  printf '%s/%s\n' "$physical_parent" '.lbwc-planning'
}

assert_command_arity() {
  local command="$1" argument_count="$2"
  case "$command" in
    set) [ "$argument_count" -eq 6 ] || { usage; exit 1; } ;;
    check|copy) [ "$argument_count" -eq 4 ] || { usage; exit 1; } ;;
    activate) [ "$argument_count" -eq 3 ] || { usage; exit 1; } ;;
    resolve) [ "$argument_count" -eq 3 ] || [ "$argument_count" -eq 4 ] || { usage; exit 1; } ;;
    validate|migrate|assert-transaction) [ "$argument_count" -eq 2 ] || { usage; exit 1; } ;;
    *)
      usage
      exit 1
      ;;
  esac
}

dispatch_route_command() {
  local planning_dir="$1"
  shift
  case "$1" in
    set) atomic_set_route "$planning_dir" "$3" "$4" "$5" "$6" ;;
    check) check_route_value "$planning_dir" "$3" "$4" ;;
    activate) activate_profile "$planning_dir" "$3" ;;
    copy) copy_profile "$planning_dir" "$3" "$4" ;;
    resolve) resolve_route "$planning_dir" "$3" "${4:-}" ;;
    validate) validate_routing_config "$planning_dir" ;;
    migrate) migrate_routes "$planning_dir" ;;
    assert-transaction) printf '%s\n' "$planning_dir" ;;
  esac
}

main() {
  local command="${1:-}" planning_dir
  require_tools
  trap cleanup EXIT
  if [ "$command" = transaction ]; then
    [ "$#" -ge 4 ] || { usage; exit 1; }
    planning_dir=$(resolve_planning_directory "$2")
    shift 2
    run_config_transaction "$planning_dir" "$@"
    return
  fi
  assert_command_arity "$command" "$#"
  planning_dir=$(resolve_planning_directory "$2")
  if [ "$TRANSACTION_ACTIVE" = 1 ]; then
    acquire_config_lock "$planning_dir"
  else
    run_config_transaction "$planning_dir" bash "$0" "$@"
    return
  fi
  dispatch_route_command "$planning_dir" "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
