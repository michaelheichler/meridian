vibe_finish() {
  if [ "$next_phase_state" = "needs_reverification" ]; then
    suggest_reverification
  elif [ "$next_phase_state" = "needs_verification" ] && [ -n "$current_uat_blocking_phase" ]; then
    suggest_resume_verify
  elif ! suggest_milestone_recovery; then
    if [ "$deviation_count" -eq 0 ]; then
      suggest "/lbwc:vibe --archive -- All phases complete, zero deviations"
    else
      suggest "/lbwc:vibe --archive -- Archive completed work ($deviation_count deviation(s) logged)"
      suggest "/lbwc:vibe -- Review before archiving"
    fi
  elif [ "$deviation_count" -gt 0 ]; then
    suggest "/lbwc:vibe -- Review remediation scope before resuming new work"
  fi
  return 0
}

vibe_continue_target() {
  local target="${next_unbuilt:-$next_unplanned}"
  if [ -n "$next_undiscussed" ] && [ "$next_undiscussed" = "$target" ]; then
    suggest "/lbwc:discuss $target -- Discuss phase before planning"
  elif [ -n "$next_preseeded" ] && [ "$next_preseeded" = "$target" ]; then
    suggest_phase_line "$target" "Plan Phase" " (discussion pre-seeded from UAT)"
  elif [ -n "$active_phase_name" ] && [ "$target" != "$active_phase_num" ]; then
    suggest_phase_line "$target" "Continue to Phase" ""
  else
    suggest "/lbwc:vibe -- Continue to next phase"
  fi
}

vibe_default() {
  if needs_verify_prompt; then
    suggest_verify_unverified "/lbwc:vibe -- Verify completed work before continuing"
  fi
  if [ "$all_done" = true ] || [ "$next_phase_state" = "needs_reverification" ] || { [ "$next_phase_state" = "needs_verification" ] && [ -n "$current_uat_blocking_phase" ]; }; then
    vibe_finish
  elif [ -n "$current_uat_issues_phase" ]; then
    suggest_uat_remediation
  elif continue_target_available; then
    vibe_continue_target
  fi
  if [ "$RESULT" = "skipped" ]; then
    suggest "/lbwc:vibe -- Verify completed work"
  fi
  return 0
}

suggest_vibe() {
  case "$effective_result" in
    fail)
      suggest_fix_plan "failed verification" "Fix the failing checks"
      suggest "/lbwc:vibe -- Re-run verification after fixing"
      ;;
    partial)
      suggest_fix_plan "partial failure" "Address partial failures"
      if [ "$all_done" != true ]; then
        suggest "/lbwc:vibe -- Continue to next phase"
      fi
      ;;
    *)
      vibe_default
      ;;
  esac
}

suggest_plan() {
  if [ "$active_phase_plans" -gt 0 ]; then
    suggest "/lbwc:vibe -- Execute $active_phase_plans plans ($effort effort)"
  else
    suggest "/lbwc:vibe -- Execute the planned phase"
  fi
}

qa_debug_pending() {
  case "$effective_result" in
    fail|partial)
      suggest "/lbwc:debug --resume -- Address QA failures"
      ;;
    *)
      if [ "$DEBUG_SESSION_STATUS" = "uat_pending" ]; then
        suggest "/lbwc:debug --resume -- Continue to UAT verification"
      else
        suggest "/lbwc:debug --resume -- Continue to QA verification"
      fi
      ;;
  esac
}

qa_debug_suggestion() {
  load_debug_session || return 1
  case "$DEBUG_SESSION_STATUS" in
    qa_pending|uat_pending|fix_applied) qa_debug_pending ;;
    qa_failed) suggest "/lbwc:debug --resume -- Address QA failures" ;;
    *) return 1 ;;
  esac
}

qa_finish() {
  if [ "$next_phase_state" = "needs_reverification" ]; then
    suggest_reverification
  elif [ "$next_phase_state" = "needs_verification" ] && [ -n "$current_uat_blocking_phase" ]; then
    suggest_resume_verify
  elif ! suggest_milestone_recovery; then
    if [ "$deviation_count" -eq 0 ]; then
      suggest "/lbwc:vibe --archive -- All phases complete, zero deviations"
    else
      suggest "/lbwc:vibe --archive -- Archive completed work ($deviation_count deviation(s) logged)"
    fi
  fi
  return 0
}

qa_continue_target() {
  local target="${next_unbuilt:-$next_unplanned}"
  if [ -n "$next_undiscussed" ] && [ -n "$target" ] && [ "$next_undiscussed" = "$target" ]; then
    suggest "/lbwc:discuss $target -- Discuss phase before planning"
  elif [ -n "$next_preseeded" ] && [ -n "$target" ] && [ "$next_preseeded" = "$target" ]; then
    suggest_phase_line "$target" "Plan Phase" " (discussion pre-seeded from UAT)"
  elif [ -n "$target" ]; then
    suggest_phase_line "$target" "Continue to Phase" ""
  else
    suggest "/lbwc:vibe -- Continue to next phase"
  fi
}

qa_pass() {
  if needs_verify_prompt; then
    suggest_verify_unverified "/lbwc:vibe -- Verify completed work"
  fi
  if [ "$all_done" = true ] || [ "$next_phase_state" = "needs_reverification" ] || { [ "$next_phase_state" = "needs_verification" ] && [ -n "$current_uat_blocking_phase" ]; }; then
    qa_finish
  elif [ -n "$current_uat_issues_phase" ]; then
    suggest_uat_remediation
  elif continue_target_available; then
    qa_continue_target
  fi
  return 0
}

suggest_qa() {
  if debug_fallback_available && qa_debug_suggestion; then
    return 0
  fi
  case "$effective_result" in
    pass)
      qa_pass
      ;;
    fail)
      suggest_fix_plan "failed QA" "Fix the failing checks"
      ;;
    partial)
      suggest_fix_plan "partial failure" "Address partial failures"
      suggest "/lbwc:vibe -- Continue despite warnings"
      ;;
    *)
      suggest "/lbwc:vibe -- Continue building"
      ;;
  esac
}

fix_debug_suggestion() {
  load_debug_session || return 1
  case "$DEBUG_SESSION_STATUS" in
    qa_pending|fix_applied) suggest "/lbwc:debug --resume -- Address remaining issues" ;;
    qa_failed) suggest "/lbwc:debug --resume -- Address QA failures" ;;
    uat_pending) suggest "/lbwc:debug --resume -- Run UAT on the debug fix" ;;
    uat_failed) suggest "/lbwc:debug --resume -- Address UAT issues" ;;
    investigating) suggest "/lbwc:debug --resume -- Continue investigation" ;;
    *) return 1 ;;
  esac
}

fix_marker_is_fresh() {
  local marker="$PLANNING_DIR/.last-fix-commit" marker_mtime now marker_age marker_stale=true
  marker_mtime=$(stat -c '%Y' "$marker" 2>/dev/null || stat -f '%m' "$marker" 2>/dev/null || echo 0)
  now=$(date +%s 2>/dev/null || echo 0)
  if [ "$marker_mtime" -gt 0 ] && [ "$now" -gt 0 ]; then
    marker_age=$(( now - marker_mtime ))
    [ "$marker_age" -ge 0 ] && [ "$marker_age" -le 86400 ] && marker_stale=false
  fi
  [ "$marker_stale" = false ]
}

suggest_fix() {
  if debug_fallback_available && fix_debug_suggestion; then
    return 0
  fi
  suggest "/lbwc:vibe -- Verify the fix"
  if [ "$cfg_auto_uat" = true ] && [ -f "$PLANNING_DIR/.last-fix-commit" ] && fix_marker_is_fresh; then
    suggest "/lbwc:verify -- Run UAT on the fix"
  fi
  suggest "/lbwc:vibe -- Continue building"
}
