verify_debug_suggestion() {
  load_debug_session || return 1
  [ "$DEBUG_SESSION_STATUS" = "uat_failed" ] || return 1
  suggest "/meridian:debug --resume -- Address UAT issues"
}

verify_pass() {
  if [ "$next_phase_state" = "needs_reverification" ]; then
    suggest_reverification
  elif [ "$next_phase_state" = "needs_verification" ] && [ -n "$current_uat_blocking_phase" ]; then
    suggest_resume_verify
  elif [ "$all_done" = true ]; then
    if ! suggest_milestone_recovery; then
      suggest "/meridian:transit --archive -- All verified, ready to ship"
    fi
  else
    suggest "/meridian:transit -- Continue to next phase"
  fi
  return 0
}

verify_issues_found() {
  if [ "$uat_major_or_higher" = true ]; then
    if [ -n "$verify_target_phase" ]; then
      suggest "/meridian:transit -- Remediate UAT issues for Phase $verify_target_phase"
    else
      suggest "/meridian:transit -- Remediate UAT issues from the latest report"
    fi
  else
    suggest "/meridian:fix -- Fix minor issues found during UAT"
  fi
}

suggest_verify() {
  if debug_fallback_available && verify_debug_suggestion; then
    return 0
  fi
  case "$effective_result" in
    pass) verify_pass ;;
    issues_found) verify_issues_found ;;
    *) suggest "/meridian:transit -- Continue building" ;;
  esac
}

suggest_debug() {
  local session_status=""
  if [ -d "$PLANNING_DIR/debugging" ] && load_debug_session; then
    session_status="$DEBUG_SESSION_STATUS"
  fi
  case "$session_status" in
    qa_pending|fix_applied) suggest "/meridian:debug --resume -- Continue to QA verification" ;;
    qa_failed) suggest "/meridian:debug --resume -- Address QA failures" ;;
    uat_pending) suggest "/meridian:debug --resume -- Continue to UAT verification" ;;
    uat_failed) suggest "/meridian:debug --resume -- Address UAT issues" ;;
    complete) suggest "/meridian:status -- View project status" ;;
    investigating)
      suggest "/meridian:debug --resume -- Continue investigation"
      suggest "/meridian:fix -- Apply the fix"
      ;;
    *)
      suggest "/meridian:fix -- Apply the fix"
      suggest "/meridian:transit -- Continue building"
      ;;
  esac
}

suggest_config() {
  if [ "$has_project" = true ]; then
    suggest "/meridian:status -- View project state"
  else
    suggest "/meridian:transit -- Define your project and start building"
  fi
}

suggest_status() {
  if [ "$next_phase_state" = "needs_reverification" ]; then
    suggest_reverification
  elif [ "$next_phase_state" = "needs_verification" ]; then
    suggest_verify_unverified "/meridian:transit -- Verify completed phases before continuing"
  elif [ "$all_done" = true ]; then
    if ! suggest_milestone_recovery; then
      if [ "$deviation_count" -eq 0 ]; then
        suggest "/meridian:transit --archive -- All phases complete, zero deviations"
      else
        suggest "/meridian:transit --archive -- Archive completed work"
      fi
    fi
  elif [ -n "$current_uat_issues_phase" ]; then
    suggest_uat_remediation
  elif [ "$cfg_auto_uat" = true ] && [ "$has_unverified_phases" = true ]; then
    suggest_verify_unverified "/meridian:transit -- Verify completed phases before continuing"
  elif [ -n "$next_unbuilt" ] || [ -n "$next_unplanned" ]; then
    suggest_continue_phase
  else
    suggest "/meridian:transit -- Start building"
  fi
  return 0
}

suggest_resume() {
  if [ "$next_phase_state" = "needs_reverification" ]; then
    suggest_reverification
  elif [ "$next_phase_state" = "needs_verification" ]; then
    suggest_verify_unverified "/meridian:transit -- Verify completed phases before continuing"
  elif [ -n "$current_uat_issues_phase" ]; then
    suggest_uat_remediation
  elif [ "$all_done" = true ]; then
    if ! suggest_milestone_recovery; then
      if [ "$deviation_count" -eq 0 ]; then
        suggest "/meridian:transit --archive -- All phases complete, zero deviations"
      else
        suggest "/meridian:transit --archive -- Archive completed work ($deviation_count deviation(s) logged)"
      fi
    fi
  elif [ "$cfg_auto_uat" = true ] && [ "$has_unverified_phases" = true ]; then
    suggest_verify_unverified "/meridian:transit -- Verify completed phases before continuing"
  elif [ -n "$next_unbuilt" ] || [ -n "$next_unplanned" ]; then
    suggest_continue_phase
  else
    suggest "/meridian:transit -- Continue building"
  fi
  suggest "/meridian:status -- View current progress"
}

suggest_default() {
  if [ "$has_project" = true ]; then
    suggest "/meridian:transit -- Continue building"
    suggest "/meridian:status -- View project progress"
  else
    suggest "/meridian:transit -- Start a new project"
  fi
}

suggest_for_command() {
  case "$CMD" in
    init) suggest "/meridian:transit -- Define your project and start building" ;;
    transit|implement|execute) suggest_transit ;;
    plan) suggest_plan ;;
    qa) suggest_qa ;;
    fix) suggest_fix ;;
    verify) suggest_verify ;;
    debug) suggest_debug ;;
    config) suggest_config ;;
    archive) suggest "/meridian:transit -- Start new work" ;;
    status) suggest_status ;;
    map)
      suggest "/meridian:transit -- Start building"
      suggest "/meridian:status -- View project state"
      ;;
    discuss|assumptions)
      suggest "/meridian:transit --plan -- Plan this phase"
      suggest "/meridian:transit -- Plan and execute in one flow"
      ;;
    resume) suggest_resume ;;
    *) suggest_default ;;
  esac
}

suggest_map_hint() {
  case "$CMD" in
    map|init|help|update|whats-new|uninstall) ;;
    *)
      if [ "$has_project" = true ] && [ "$phase_count" -gt 0 ]; then
        if [ "$map_exists" = false ]; then
          suggest "/meridian:map -- Map your codebase for better planning"
        elif [ "$map_staleness" -gt 30 ]; then
          suggest "/meridian:map --incremental -- Codebase map is ${map_staleness}% stale"
        fi
      fi
      ;;
  esac
}

count_known_issues() {
  local issues_dir issues_file issues_count
  KNOWN_ISSUES_TOTAL=0
  while IFS= read -r issues_dir; do
    [ -d "$issues_dir" ] || continue
    issues_file="$issues_dir/known-issues.json"
    if [ -f "$issues_file" ]; then
      issues_count=$(jq -r '.issues | length' "$issues_file" 2>/dev/null || echo "0")
      KNOWN_ISSUES_TOTAL=$(( KNOWN_ISSUES_TOTAL + issues_count ))
    fi
  done < <(find "$PHASES_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
}

suggest_known_issues_note() {
  case "$CMD" in
    init|help|update|whats-new|uninstall) ;;
    *)
      if [ "$has_project" = true ] && [ -d "$PHASES_DIR" ]; then
        count_known_issues
        if [ "$KNOWN_ISSUES_TOTAL" -gt 0 ]; then
          echo ""
          echo "Note: $KNOWN_ISSUES_TOTAL known issue(s) deferred across phases, visible in /meridian:list-todos"
        fi
      fi
      ;;
  esac
}
