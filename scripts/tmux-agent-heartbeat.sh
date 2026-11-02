#!/usr/bin/env bash
set -u
set -eo pipefail
umask 077

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)
. "$SCRIPT_DIR/lib/lbwc-control-root.sh"
. "$SCRIPT_DIR/lib/lbwc-config-files.sh"
. "$SCRIPT_DIR/lib/tmux-runtime.sh"
. "$SCRIPT_DIR/lib/tmux-heartbeat-settings.sh"

fail() {
  printf 'tmux heartbeat error: %s\n' "$1" >&2
  exit 1
}

[ "$#" -eq 3 ] || fail 'control root, agent ID and session ID are required'
control_root="$1"
agent_id="$2"
session_id="$3"
IFS= read -r capability || fail 'capability input is unavailable'
[[ "$capability" =~ ^[0-9a-f]{32}$ ]] || fail 'capability is invalid'
tmux_runtime_configure_existing "$control_root"
tmux_heartbeat_settings "$control_root" || fail 'heartbeat settings are invalid'

while sleep "$TMUX_HEARTBEAT_INTERVAL"; do
  registry=$(tmux_runtime_registry_read) || exit 1
  agent=$(jq -er --arg agent "$agent_id" --arg session "$session_id" '.agents[] | select(.agent_id == $agent and .claude_session_id == $session and (.state == "running" or .state == "idle")) | [.state, .tmux_pane_id] | @tsv' <<<"$registry") || exit 0
  IFS=$'\t' read -r state pane_id <<<"$agent"
  [[ "$pane_id" =~ ^%[0-9]+$ ]] || exit 0
  present=$(tmux display-message -p -t "$pane_id" '#{pane_id}' 2>/dev/null) || exit 0
  [ "$present" = "$pane_id" ] || exit 0
  printf '%s\n' "$capability" | bash "$SCRIPT_DIR/tmux-bus.sh" --control-root "$control_root" heartbeat --agent-id "$agent_id" --session-id "$session_id" --capability-stdin --state "$state" >/dev/null || exit 1
done
