#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULTS_PATH="$SCRIPT_DIR/../config/settings.json"
ROLE_DEFAULTS_PATH="$SCRIPT_DIR/../templates/agent-roles/defaults.json"
ROUTING_PATH="$SCRIPT_DIR/lbwc-routing.sh"
LOCK_ATTEMPTS=100
LOCK_SLEEP_SECONDS=0.05
LOCK_DIR=""

. "$SCRIPT_DIR/lib/lbwc-config-agent-teams.sh"
. "$SCRIPT_DIR/lib/lbwc-config-defaults.sh"
. "$SCRIPT_DIR/lib/lbwc-config-files.sh"
. "$SCRIPT_DIR/lib/lbwc-config-freeze.sh"
. "$SCRIPT_DIR/lib/lbwc-config-ops.sh"

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

usage() {
  printf '%s\n' 'Usage: lbwc-config.sh <init|migrate|validate|get|set|set-json> <planning-dir> [setting] [json-value]' >&2
  printf '%s\n' '       lbwc-config.sh default-config' >&2
  printf '%s\n' '       lbwc-config.sh validate-config-json (reads JSON on stdin)' >&2
  printf '%s\n' '       lbwc-config.sh validate-tmux-execution-json (reads JSON on stdin)' >&2
  printf '%s\n' '       lbwc-config.sh agent-teams-status --settings PATH [--project-root PATH]' >&2
  printf '%s\n' '       lbwc-config.sh agent-teams-check --settings PATH [--project-root PATH]' >&2
  printf '%s\n' '       lbwc-config.sh agent-teams-enable --settings PATH --approved' >&2
}

require_jq() {
  command -v jq >/dev/null 2>&1 || fail 'jq is required'
}

prepare_transaction_directory() {
  local command="$1" planning_dir="$2"
  assert_no_symbolic_links "$planning_dir"
  case "$command" in
    init|migrate)
      mkdir -p "$planning_dir" || fail "could not create planning directory: $planning_dir"
      ;;
    *)
      [ -d "$planning_dir" ] || fail "planning directory does not exist: $planning_dir"
      ;;
  esac
  assert_no_symbolic_links "$planning_dir"
}

print_default_config() {
  local default_config
  default_config=$(migrate_config_json '{}') || fail 'could not build default configuration'
  validate_or_fail "$default_config"
  jq '.' <<< "$default_config"
}

echo_validated_stdin_config() {
  local stdin_config
  stdin_config=$(cat)
  validate_or_fail "$stdin_config"
  printf '%s\n' "$stdin_config"
}

run_global_command() {
  local command="$1"
  case "$command" in
    agent-teams-status|agent-teams-check|agent-teams-enable)
      shift
      global_command "$command" "$@"
      return
      ;;
    default-config)
      [ "$#" -eq 1 ] || { usage; exit 1; }
      print_default_config
      return
      ;;
    validate-config-json)
      [ "$#" -eq 1 ] || { usage; exit 1; }
      echo_validated_stdin_config
      return
      ;;
    validate-tmux-execution-json)
      [ "$#" -eq 1 ] || { usage; exit 1; }
      validate_tmux_execution_json
      return
      ;;
  esac
}

assert_execution_setting_cli() {
  local planning_dir="$1" setting="$2" value="$3"
  setting_is_writable "$setting" || fail "setting is not writable: $setting"
  jq -e 'type' <<< "$value" >/dev/null 2>&1 || fail 'setting value is not valid JSON'
  assert_execution_setting_is_writable "$planning_dir" "$setting" "$value"
}

run_transaction_command() {
  local command="$1" planning_dir="$2"
  case "$command" in
    init|migrate)
      [ "$#" -eq 2 ] || { usage; exit 1; }
      initialize_config "$planning_dir"
      ;;
    validate)
      [ "$#" -eq 2 ] || { usage; exit 1; }
      validate_config_file "$planning_dir"
      ;;
    get)
      [ "$#" -eq 3 ] || { usage; exit 1; }
      get_setting "$planning_dir" "$3"
      ;;
    assert-execution-setting-writable)
      [ "$#" -eq 4 ] || { usage; exit 1; }
      assert_execution_setting_cli "$planning_dir" "$3" "$4"
      ;;
    set|set-json)
      [ "$#" -eq 4 ] || { usage; exit 1; }
      set_setting "$planning_dir" "$3" "$4"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main() {
  local command="${1:-}" planning_dir="${2:-}"
  require_jq
  case "$command" in
    agent-teams-status|agent-teams-check|agent-teams-enable|default-config|validate-config-json|validate-tmux-execution-json)
      run_global_command "$@"
      return
      ;;
  esac
  [ -n "$command" ] && [ -n "$planning_dir" ] || { usage; exit 1; }
  [ -f "$ROUTING_PATH" ] || fail "routing transaction script is unavailable: $ROUTING_PATH"
  if [ "${LBWC_CONFIG_TRANSACTION_ACTIVE:-0}" != 1 ]; then
    prepare_transaction_directory "$command" "$planning_dir"
    exec bash "$ROUTING_PATH" transaction "$planning_dir" bash "$0" "$@"
  fi
  bash "$ROUTING_PATH" assert-transaction "$planning_dir" >/dev/null
  trap cleanup_lock EXIT
  run_transaction_command "$@"
}

main "$@"
