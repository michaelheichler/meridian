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
. "$SCRIPT_DIR/lib/meridian-control-root.sh"
. "$SCRIPT_DIR/lib/meridian-config-files.sh"
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

sleep_pid=''
cleanup_sender() {
  if [ -n "$sleep_pid" ]; then
    kill "$sleep_pid" 2>/dev/null || true
    wait "$sleep_pid" 2>/dev/null || true
  fi
  tmux_runtime_cleanup_locks
}
trap cleanup_sender EXIT
trap 'exit 0' TERM INT

tmux_runtime_lock_acquire registry 5000 30000
registry=$(tmux_runtime_registry_read)
jq -e --arg agent "$agent_id" --arg session "$session_id" 'any(.agents[]; .agent_id == $agent and .claude_session_id == $session and (.state == "running" or .state == "idle"))' <<<"$registry" >/dev/null || { tmux_runtime_lock_release registry; exit 0; }
sender_started=$(ps -p "$$" -o lstart=)
sender_record=$(jq -cn --argjson pid "$$" --arg started "$sender_started" '{pid:$pid,started:$started}')
tmux_runtime_atomic_json "$TMUX_RUNTIME_BUS_ROOT/inboxes/$agent_id/heartbeat-sender.json" "$sender_record"
tmux_runtime_lock_release registry

failures=0
while :; do
  sleep "$TMUX_HEARTBEAT_INTERVAL" &
  sleep_pid=$!
  wait "$sleep_pid" || break
  sleep_pid=''
  if ! registry=$(tmux_runtime_registry_read); then
    failures=$((failures + 1))
    [ "$failures" -lt 3 ] || exit 1
    continue
  fi
  agent=$(jq -er --arg agent "$agent_id" --arg session "$session_id" '.agents[] | select(.agent_id == $agent and .claude_session_id == $session and (.state == "running" or .state == "idle")) | [.state, .tmux_pane_id] | @tsv' <<<"$registry") || exit 0
  IFS=$'\t' read -r state pane_id <<<"$agent"
  [[ "$pane_id" =~ ^%[0-9]+$ ]] || exit 0
  present=$(tmux display-message -p -t "$pane_id" '#{pane_id}' 2>/dev/null) || exit 0
  [ "$present" = "$pane_id" ] || exit 0
  if printf '%s\n' "$capability" | bash "$SCRIPT_DIR/tmux-bus.sh" --control-root "$control_root" heartbeat --agent-id "$agent_id" --session-id "$session_id" --capability-stdin --state "$state" >/dev/null; then
    failures=0
  else
    failures=$((failures + 1))
    [ "$failures" -lt 3 ] || exit 1
  fi
done
