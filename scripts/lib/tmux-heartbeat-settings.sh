tmux_heartbeat_settings() {
  local control_root="$1" config settings interval stale_seconds backend
  config=$(read_existing_config "$control_root/config.json") || return 1
  settings=$(jq -er '[.tmux_execution.heartbeat_interval_seconds // 30, .tmux_execution.heartbeat_stale_seconds // 0, .agent_execution_mode // "in_process"] | @tsv' <<<"$config") || return 1
  IFS=$'\t' read -r interval stale_seconds backend <<<"$settings"
  [[ "$interval" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "$stale_seconds" =~ ^[0-9]+$ ]] || return 1
  printf -v TMUX_HEARTBEAT_INTERVAL '%s' "$interval"
  printf -v TMUX_HEARTBEAT_STALE_MS '%s' "$((interval * 3000))"
  if [ "$stale_seconds" -gt 0 ] && [ "$((stale_seconds * 1000))" -lt "$TMUX_HEARTBEAT_STALE_MS" ]; then
    printf -v TMUX_HEARTBEAT_STALE_MS '%s' "$((stale_seconds * 1000))"
  fi
  printf -v TMUX_HEARTBEAT_BACKEND '%s' "$backend"
}
