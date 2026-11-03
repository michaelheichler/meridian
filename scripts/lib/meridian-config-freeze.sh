setting_is_writable() {
  case "$1" in
    effort|autonomy|auto_commit|planning_tracking|auto_push|verification_tier|skill_suggestions|auto_install_skills|discovery_questions|discussion_mode|context_compiler|visual_format|max_tasks_per_plan|prefer_teams|agent_execution_mode|tmux_execution|tmux_execution.enabled|tmux_execution.session_name_prefix|tmux_execution.max_agents|tmux_execution.attach_policy|tmux_execution.heartbeat_interval_seconds|tmux_execution.heartbeat_stale_seconds|tmux_execution.comms_latency_tolerance_ms|tmux_execution.comms_fallback|tmux_execution.cleanup_policy|tmux_execution.layout|tmux_execution.restrictions.allow_nested_spawn|tmux_execution.restrictions.allow_agent_git|tmux_execution.restrictions.allow_agent_ask_user|tmux_execution.restrictions.require_orchestrator_attach|workflow_execution|workflow_execution.enabled|pipeline_research|branch_per_milestone|plain_summary|active_profile|custom_profiles|agent_max_turns|qa_skip_agents|auto_uat|require_phase_discussion|rolling_summary|metrics|token_budgets|two_phase_completion|smart_routing|validation_gates|snapshot_resume|lease_locks|event_recovery|worktree_isolation|monorepo_routing|debug_logging|statusline_hide_limits|statusline_hide_limits_for_api_key|statusline_hide_agent_in_tmux|statusline_collapse_agent_in_tmux|caveman_style|caveman_commit|caveman_review|max_uat_remediation_rounds|routing.active_profile)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

plan_execution_is_active() {
  local planning_dir="$1" execution_state="$1/.execution-state.json" state_file="$1/STATE.md" contract_path
  if [ -f "$execution_state" ] && jq -e '.status | IN("running", "executing", "active")' "$execution_state" >/dev/null 2>&1; then
    return 0
  fi
  if [ -f "$state_file" ] && grep -Eq '^[[:space:]]*Status:[[:space:]]*(active|executing)[[:space:]]*$' "$state_file"; then
    return 0
  fi
  for contract_path in "$planning_dir/.contracts/tasks/"*.json; do
    [ -f "$contract_path" ] || continue
    if jq -e '.state | IN("dispatched", "running")' "$contract_path" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

running_tmux_agents_exist() {
  local planning_dir="$1" registry="$1/.runtime/tmux-bus/registry.json"
  [ -f "$registry" ] || return 1
  jq -e '
    type == "object"
    and (.agents | type == "array")
    and all(.agents[];
      type == "object"
      and (.state | type == "string" and IN("registered", "running", "idle", "failed", "shutdown"))
    )
  ' "$registry" >/dev/null 2>&1 || return 2
  jq -e '[.agents[] | select(.state == "running")] | length > 0' "$registry" >/dev/null 2>&1
}

execution_setting_is_frozen() {
  local planning_dir="$1" setting="$2" value="$3" registry_status=0
  plan_execution_is_active "$planning_dir" || return 1
  case "$setting" in
    agent_execution_mode)
      if [ "$value" = '"in_process"' ]; then
        running_tmux_agents_exist "$planning_dir" || registry_status=$?
        case "$registry_status" in
          0) return 0 ;;
          1) return 1 ;;
          *) return 0 ;;
        esac
      fi
      return 0
      ;;
    tmux_execution.cleanup_policy|statusline_hide_agent_in_tmux|statusline_collapse_agent_in_tmux)
      return 1
      ;;
    worktree_isolation|tmux_execution|tmux_execution.*|workflow_execution|workflow_execution.*|effort|routing.active_profile)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

assert_execution_setting_is_writable() {
  local planning_dir="$1" setting="$2" value="$3"
  if execution_setting_is_frozen "$planning_dir" "$setting" "$value"; then
    fail "execution configuration is frozen while a plan is active: $setting"
  fi
}
