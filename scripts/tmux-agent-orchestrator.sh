#!/usr/bin/env bash

printf -v MERIDIAN_MIGRATION_SOURCE '%s' "${BASH_SOURCE[0]}"
case "$MERIDIAN_MIGRATION_SOURCE" in
  *"/"*) printf -v MERIDIAN_MIGRATION_SOURCE '%s' "${MERIDIAN_MIGRATION_SOURCE%"/"*}" ;;
  *) printf -v MERIDIAN_MIGRATION_SOURCE '%s' . ;;
esac
if [ -f "$MERIDIAN_MIGRATION_SOURCE/lib/rename-migration.sh" ]; then
  . "$MERIDIAN_MIGRATION_SOURCE/lib/rename-migration.sh"
  meridian_migrate_environment
fi
unset MERIDIAN_MIGRATION_SOURCE
set -u
set -eo pipefail
umask 077

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)
source "$SCRIPT_DIR/lib/meridian-control-root.sh"
source "$SCRIPT_DIR/lib/tmux-runtime.sh"
source "$SCRIPT_DIR/lib/agent-manifest.sh"
source "$SCRIPT_DIR/lib/meridian-config-files.sh"
source "$SCRIPT_DIR/lib/worktree-isolation.sh"
source "$SCRIPT_DIR/lib/tmux-worker-worktrees.sh"

fail() {
  printf 'tmux orchestrator error: %s\n' "$1" >&2
  exit 1
}

usage() {
  printf '%s\n' 'Usage: tmux-agent-orchestrator.sh <provision|split-agent|split-group|focus-orchestrator|kill-agent|kill-session|status|rollback> --project-root PATH --control-root PATH [options]' >&2
  exit 2
}

require_tmux() {
  local tool
  for tool in tmux jq claude uuidgen shasum cut id mktemp perl date mkdir chmod mv rm rmdir python3; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command is unavailable: $tool"
  done
}

resolve_context() {
  local requested_root="$1" control_root="$2" out_root="$3" physical_root
  [ -d "$requested_root" ] || fail "project root does not exist: $requested_root"
  physical_root=$(CDPATH='' cd -- "$requested_root" && pwd -P)
  printf -v "$out_root" '%s' "$physical_root"
  tmux_runtime_configure "$control_root"
}

ensure_runtime_layout() {
  tmux_runtime_ensure || return 1
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/inboxes"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/outbox"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/outbox/main"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/transactions"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/claims"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/credentials"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/heartbeats"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/locks"
}

tmux_session_exists() {
  tmux has-session -t "$1" >/dev/null 2>&1
}

tmux_pane_exists() {
  local pane_id
  pane_id=$(tmux display-message -p -t "$1" '#{pane_id}' 2>/dev/null || true)
  [[ "$pane_id" =~ ^%[0-9]+$ ]]
}

require_main_orchestrator() {
  local registry
  tmux_runtime_require_bus
  registry=$(tmux_runtime_registry_read)
  tmux_runtime_principal_valid "$registry" "$orchestrator_id" "$orchestrator_session_id" orchestrator "$orchestrator_capability" || fail 'main orchestrator session and capability are required'
  [ "$orchestrator_id" = "$(jq -r '.main.agent_id' <<<"$registry")" ] || fail 'operation requires the main orchestrator'
}

configure_cleanup_policy() {
  local policy="$1"
  case "$policy" in
    kill_on_complete|keep_panes) ;;
    *)
      case "$subcommand" in
        status|rollback)
          printf 'tmux orchestrator warning: cleanup_policy is invalid, %s uses kill_on_complete\n' "$subcommand" >&2
          policy=kill_on_complete
          ;;
        *) fail 'tmux cleanup_policy is invalid' ;;
      esac
      ;;
  esac
  printf -v TMUX_CLEANUP_POLICY '%s' "$policy"
}

read_tmux_settings() {
  local config settings layout_name agent_limit attach_policy cleanup_policy
  config=$(read_existing_config "$TMUX_RUNTIME_CONTROL_ROOT/config.json")
  settings=$(jq -er '[.tmux_execution.layout // .tmux.layout // "tiled", .tmux_execution.max_agents // .tmux.max_agents // 3, .tmux_execution.attach_policy // "orchestrator_only"] | @tsv' <<<"$config") || fail 'cannot read tmux settings'
  IFS=$'\t' read -r layout_name agent_limit attach_policy <<<"$settings"
  cleanup_policy=$(jq -er '.tmux_execution.cleanup_policy as $policy | if (.tmux_execution // {} | has("cleanup_policy")) then $policy else "kill_on_complete" end | if type == "string" then . else "__invalid__" end' <<<"$config") || fail 'cannot read tmux cleanup_policy'
  case "$layout_name" in tiled|even-horizontal|even-vertical|main-horizontal|main-vertical) ;; *) fail 'tmux layout is invalid' ;; esac
  [[ "$agent_limit" =~ ^[1-4]$ ]] || fail 'tmux max_agents must be between 1 and 4'
  case "$attach_policy" in orchestrator_only|visible_grid) ;; *) fail 'tmux attach_policy is invalid' ;; esac
  printf -v TMUX_LAYOUT '%s' "$layout_name"
  printf -v TMUX_AGENT_LIMIT '%s' "$agent_limit"
  printf -v TMUX_ATTACH_POLICY '%s' "$attach_policy"
  configure_cleanup_policy "$cleanup_policy"
}

tmux_layout_name() {
  printf '%s\n' "$TMUX_LAYOUT"
}

tmux_max_agents() {
  printf '%s\n' "$TMUX_AGENT_LIMIT"
}

apply_tmux_layout() {
  tmux select-layout -t "$1" "$2"
}

configure_pane_borders() {
  tmux set-option -t "$1" pane-border-status top && tmux set-option -t "$1" pane-border-format '#{pane_title}'
}

source "$SCRIPT_DIR/lib/tmux-agent-orchestrator-teardown.sh"
source "$SCRIPT_DIR/lib/tmux-agent-orchestrator-provision.sh"
source "$SCRIPT_DIR/lib/tmux-agent-orchestrator-validate.sh"
source "$SCRIPT_DIR/lib/tmux-agent-orchestrator-split.sh"

[ "$#" -gt 0 ] || usage
subcommand="$1"
shift
project_root=''
requested_control_root=''
main_id=''
session=''
agent_id=''
generated_agent=''
target=''
definitions=''
orchestrator_id=''
orchestrator_session_id=''
orchestrator_capability=''
run_id=''

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project-root) [ "$#" -ge 2 ] || usage; project_root="$2"; shift 2 ;;
    --control-root) [ "$#" -ge 2 ] || usage; requested_control_root="$2"; shift 2 ;;
    --main-id) [ "$#" -ge 2 ] || usage; main_id="$2"; shift 2 ;;
    --session) [ "$#" -ge 2 ] || usage; session="$2"; shift 2 ;;
    --name) [ "$#" -ge 2 ] || usage; agent_id="$2"; shift 2 ;;
    --agent) [ "$#" -ge 2 ] || usage; generated_agent="$2"; shift 2 ;;
    --agents) [ "$#" -ge 2 ] || usage; definitions="$2"; shift 2 ;;
    --target) [ "$#" -ge 2 ] || usage; target="$2"; shift 2 ;;
    --orchestrator-id) [ "$#" -ge 2 ] || usage; orchestrator_id="$2"; shift 2 ;;
    --orchestrator-session-id) [ "$#" -ge 2 ] || usage; orchestrator_session_id="$2"; shift 2 ;;
    --orchestrator-capability) [ "$#" -ge 2 ] || usage; orchestrator_capability="$2"; shift 2 ;;
    --run-id) [ "$#" -ge 2 ] || usage; run_id="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[ -n "$project_root" ] || fail '--project-root is required'
[ -n "$requested_control_root" ] || fail '--control-root is required'
case "$subcommand" in provision|split-agent|split-group|focus-orchestrator|kill-agent|kill-session|status|rollback) ;; *) usage ;; esac
require_tmux
resolve_context "$project_root" "$requested_control_root" PROJECT_ROOT
read_tmux_settings
trap tmux_runtime_cleanup_locks EXIT

case "$subcommand" in
  provision) provision ;;
  split-agent) [ -n "$session" ] || fail '--session is required'; require_main_orchestrator; split_agent ;;
  split-group) [ -n "$session" ] || fail '--session is required'; [ -n "$definitions" ] || fail '--agents is required'; require_main_orchestrator; split_group "$definitions" ;;
  focus-orchestrator) focus_orchestrator ;;
  kill-agent) [ -n "$target" ] || fail '--target is required'; kill_agent ;;
  kill-session) [ -n "$session" ] || fail '--session is required'; kill_session ;;
  status) status ;;
  rollback) rollback ;;
esac
