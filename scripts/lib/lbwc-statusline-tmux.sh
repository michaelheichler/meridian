reset_tmux_state() {
  TMUX_BACKEND='in_process'
  TMUX_HIDE_AGENT='false'
  TMUX_COLLAPSE_AGENT='false'
  TMUX_SESSION='none'
  TMUX_SESSION_STATUS='unavailable'
  TMUX_PANES='0/0'
  TMUX_AGENT_TOTAL=0
  TMUX_RUNNING=0
  TMUX_IDLE=0
  TMUX_FAILED=0
  TMUX_STALE=0
  TMUX_DIAGNOSTICS=''
}

read_tmux_config() {
  if ! jq -e '
    type == "object"
    and (if has("agent_execution_mode") then (.agent_execution_mode | type == "string" and (. == "in_process" or . == "tmux" or . == "workflow" or . == "ask")) else true end)
    and (if has("statusline_hide_agent_in_tmux") then (.statusline_hide_agent_in_tmux | type == "boolean") else true end)
    and (if has("statusline_collapse_agent_in_tmux") then (.statusline_collapse_agent_in_tmux | type == "boolean") else true end)
  ' "$PLANNING_DIR/config.json" >/dev/null 2>&1; then
    TMUX_BACKEND='invalid'
    TMUX_DIAGNOSTICS='configuration drift'
    return 1
  fi
  TMUX_BACKEND=$(jq -r '.agent_execution_mode // "in_process"' "$PLANNING_DIR/config.json" 2>/dev/null) || {
    TMUX_BACKEND='invalid'
    TMUX_DIAGNOSTICS='configuration drift'
    return 1
  }
  TMUX_HIDE_AGENT=$(jq -r '.statusline_hide_agent_in_tmux // false' "$PLANNING_DIR/config.json")
  TMUX_COLLAPSE_AGENT=$(jq -r '.statusline_collapse_agent_in_tmux // false' "$PLANNING_DIR/config.json")
}

read_tmux_registry_counts() {
  local registry="$1"
  TMUX_SESSION=$(jq -r '.tmux.session // "none"' "$registry")
  TMUX_AGENT_TOTAL=$(jq '[.agents[]] | length' "$registry")
  TMUX_RUNNING=$(jq '[.agents[] | select(.state == "running")] | length' "$registry")
  TMUX_IDLE=$(jq '[.agents[] | select(.state == "idle")] | length' "$registry")
  TMUX_FAILED=$(jq '[.agents[] | select(.state == "failed")] | length' "$registry")
}

read_tmux_stale_count() {
  local registry="$1" now
  now=$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000' 2>/dev/null || printf '0')
  TMUX_STALE=$(jq --argjson now "$now" --argjson threshold "$(jq -r '.tmux_execution.heartbeat_stale_seconds // 120' "$PLANNING_DIR/config.json" 2>/dev/null || printf 120)000" '[.agents[] | select(.heartbeat_at_ms != null and (.heartbeat_at_ms + $threshold) <= $now)] | length' "$registry" 2>/dev/null || printf 0)
}

read_tmux_pane_state() {
  local pane_count expected_panes
  if command -v tmux >/dev/null 2>&1 && [ "$TMUX_SESSION" != none ] && tmux has-session -t "$TMUX_SESSION" >/dev/null 2>&1; then
    TMUX_SESSION_STATUS='up'
    pane_count=$(tmux list-panes -t "$TMUX_SESSION" -F '#{pane_index}' 2>/dev/null | wc -l | tr -d ' ')
    expected_panes=$((TMUX_AGENT_TOTAL + 1))
    TMUX_PANES="${pane_count}/${expected_panes}"
  else
    TMUX_SESSION_STATUS='down'
  fi
}

scan_tmux_locks() {
  local runtime="$1" lock_now lock owner acquired lease
  lock_now=$(perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e 'printf "%.0f\n", clock_gettime(CLOCK_MONOTONIC) * 1000' 2>/dev/null || printf '0')
  while IFS= read -r lock; do
    [ -d "$lock" ] || continue
    owner="$lock/owner.json"
    [ -f "$owner" ] || { TMUX_DIAGNOSTICS='malformed lock'; break; }
    acquired=$(jq -r '.acquired_at_ms // -1' "$owner" 2>/dev/null || printf -- -1)
    lease=$(jq -r '.lease_ms // -1' "$owner" 2>/dev/null || printf -- -1)
    if [[ "$acquired" =~ ^[0-9]+$ ]] && [[ "$lease" =~ ^[1-9][0-9]*$ ]] && [ "$lock_now" -ge $((acquired + lease)) ]; then
      TMUX_DIAGNOSTICS='stale lock'
      break
    fi
  done < <(find "$runtime/locks" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
}

read_tmux_runtime_state() {
  local runtime="$PLANNING_DIR/.runtime/tmux-bus" registry
  reset_tmux_state
  [ -f "$PLANNING_DIR/config.json" ] || return 0
  read_tmux_config || return 0
  [ "$TMUX_BACKEND" = tmux ] || return 0
  registry="$runtime/registry.json"
  [ -f "$registry" ] || {
    TMUX_DIAGNOSTICS='missing registry'
    return 0
  }
  if ! jq -e 'type == "object" and (.tmux | type == "object") and (.agents | type == "array")' "$registry" >/dev/null 2>&1; then
    TMUX_DIAGNOSTICS='malformed registry'
    return 0
  fi
  read_tmux_registry_counts "$registry"
  read_tmux_stale_count "$registry"
  read_tmux_pane_state
  scan_tmux_locks "$runtime"
  [ -n "$TMUX_DIAGNOSTICS" ] || [ "$TMUX_FAILED" -eq 0 ] || TMUX_DIAGNOSTICS='failed agent'
}
