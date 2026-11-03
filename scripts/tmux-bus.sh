#!/usr/bin/env bash

. "$(CDPATH="" cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/rename-migration.sh"
meridian_migrate_environment
set -euo pipefail
umask 077

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/lib/meridian-control-root.sh"
source "$SCRIPT_DIR/lib/tmux-runtime.sh"

readonly MESSAGE_TYPES='job result heartbeat error shutdown_request shutdown_response'

fail() {
  printf 'tmux-bus: %s\n' "$1" >&2
  exit 1
}

require_tools() {
  local tool
  for tool in jq uuidgen mktemp mv mkdir chmod date sleep perl shasum cut id rm rmdir python3; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is unavailable: $tool"
  done
}

source "$SCRIPT_DIR/lib/tmux-bus-envelope.sh"
source "$SCRIPT_DIR/lib/tmux-bus-publish.sh"
source "$SCRIPT_DIR/lib/tmux-bus-claim.sh"

usage() {
  printf '%s\n' 'Usage: tmux-bus.sh --control-root PATH <init|bind|routing-refresh|publish|poll|claim|ack|await|heartbeat|stale|recover|compact> [options]' >&2
  exit 2
}

main() {
  local control_root command
  require_tools
  [ "$#" -ge 3 ] || usage
  [ "$1" = '--control-root' ] || usage
  control_root="$2"
  command="$3"
  shift 3
  tmux_runtime_configure "$control_root"
  trap tmux_runtime_cleanup_locks EXIT
  case "$command" in
    init) if [ "$#" -eq 4 ] && [ "$1" = '--main-id' ] && [ "$3" = '--main-session-id' ]; then command_init "$2" "$4" ''; elif [ "$#" -eq 6 ] && [ "$1" = '--main-id' ] && [ "$3" = '--main-session-id' ] && [ "$5" = '--orchestrator-capability' ]; then command_init "$2" "$4" "$6"; else usage; fi ;;
    bind) [ "$#" -eq 8 ] && [ "$1" = '--agent-id' ] && [ "$3" = '--session-id' ] && [ "$5" = '--capability' ] && [ "$7" = '--contract-id' ] || usage; command_bind "$2" "$4" "$6" "$8" ;;
    routing-refresh) [ "$#" -eq 6 ] && [ "$1" = '--orchestrator-id' ] && [ "$3" = '--orchestrator-session-id' ] && [ "$5" = '--orchestrator-capability' ] || usage; command_routing_refresh "$2" "$4" "$6" ;;
    publish) if [ "$#" -eq 16 ] && [ "$1" = '--to' ] && [ "$3" = '--from-agent-id' ] && [ "$5" = '--from-session-id' ] && [ "$7" = '--from-role' ] && [ "$9" = '--capability' ] && [ "${11}" = '--type' ] && [ "${13}" = '--correlation-id' ] && [ "${15}" = '--payload' ]; then command_publish "$2" "$4" "$6" "$8" "${10}" "${12}" "${14}" "${16}" 5000; elif [ "$#" -eq 18 ] && [ "${17}" = '--timeout-ms' ]; then command_publish "$2" "$4" "$6" "$8" "${10}" "${12}" "${14}" "${16}" "${18}"; else usage; fi ;;
    poll) [ "$#" -eq 12 ] && [ "$1" = '--from' ] && [ "$3" = '--agent-id' ] && [ "$5" = '--session-id' ] && [ "$7" = '--role' ] && [ "$9" = '--capability' ] && [ "${11}" = '--types' ] || usage; require_principal "$4" "$6" "$8" "${10}" false >/dev/null; poll_messages "$4" "$2" "${12}" ;;
    claim) [ "$#" -eq 10 ] && [ "$1" = '--agent-id' ] && [ "$3" = '--session-id' ] && [ "$5" = '--capability' ] && [ "$7" = '--type' ] && [ "$9" = '--lease-ms' ] || usage; command_claim "$2" "$4" "$6" "$8" "${10}" ;;
    ack) [ "$#" -eq 8 ] && [ "$1" = '--agent-id' ] && [ "$3" = '--session-id' ] && [ "$5" = '--capability' ] && [ "$7" = '--message-id' ] || usage; command_ack "$2" "$4" "$6" "$8" ;;
    await) [ "$#" -eq 14 ] && [ "$1" = '--from' ] && [ "$3" = '--agent-id' ] && [ "$5" = '--session-id' ] && [ "$7" = '--role' ] && [ "$9" = '--capability' ] && [ "${11}" = '--types' ] && [ "${13}" = '--timeout-ms' ] || usage; command_await "$4" "$6" "$8" "${10}" "$2" "${12}" "${14}" ;;
    heartbeat) if [ "$#" -eq 8 ] && [ "$1" = '--agent-id' ] && [ "$3" = '--session-id' ] && [ "$5" = '--capability' ] && [ "$7" = '--state' ]; then command_heartbeat "$2" "$4" "$6" "$8"; elif [ "$#" -eq 7 ] && [ "$1" = '--agent-id' ] && [ "$3" = '--session-id' ] && [ "$5" = '--capability-stdin' ] && [ "$6" = '--state' ]; then IFS= read -r capability || fail 'heartbeat capability input is unavailable'; command_heartbeat "$2" "$4" "$capability" "$7"; else usage; fi ;;
    stale) [ "$#" -eq 12 ] && [ "$1" = '--agent-id' ] && [ "$3" = '--session-id' ] && [ "$5" = '--role' ] && [ "$7" = '--capability' ] && [ "$9" = '--subject-agent-id' ] && [ "${11}" = '--threshold-ms' ] || usage; command_stale "$2" "$4" "$6" "$8" "${10}" "${12}" ;;
    recover) [ "$#" -eq 8 ] && [ "$1" = '--orchestrator-id' ] && [ "$3" = '--orchestrator-session-id' ] && [ "$5" = '--orchestrator-capability' ] && [ "$7" = '--message-id' ] || usage; command_recover "$2" "$4" "$6" "$8" ;;
    compact) [ "$#" -eq 8 ] && [ "$1" = '--orchestrator-id' ] && [ "$3" = '--orchestrator-session-id' ] && [ "$5" = '--orchestrator-capability' ] && [ "$7" = '--retain' ] || usage; command_compact "$2" "$4" "$6" "$8" ;;
    *) usage ;;
  esac
}

main "$@"
