DEBUG_ACTIVE_SESSION=""
DEBUG_SESSION_FILE=""
DEBUG_SESSION_STATUS=""

fmt_phase_name() {
  echo "$1" | tr '-' ' '
}

suggest() {
  echo "  $1"
}

suggest_milestone_recovery() {
  if [ "$milestone_uat_issues" = true ]; then
    if [ "$milestone_uat_slug" != "none" ] && [ "${milestone_uat_count:-0}" -gt 1 ] 2>/dev/null; then
      suggest "/meridian:transit -- Milestone UAT recovery pending (${milestone_uat_slug}, ${milestone_uat_count} phase(s))"
    elif [ "$milestone_uat_slug" != "none" ] && [ "$milestone_uat_phase" != "none" ]; then
      suggest "/meridian:transit -- Milestone UAT recovery pending (${milestone_uat_slug}, Phase ${milestone_uat_phase})"
    else
      suggest "/meridian:transit -- Milestone UAT recovery pending"
    fi
    return 0
  fi
  return 1
}

needs_verify_prompt() {
  [ -z "$current_uat_issues_phase" ] && \
    { { [ "$has_uat" = false ] && [ "$active_phase_plans" -gt 0 ] && { [ "$cfg_auto_uat" = true ] || [ "$cfg_autonomy" = "cautious" ] || [ "$cfg_autonomy" = "standard" ]; }; } \
      || { [ "$cfg_auto_uat" = true ] && [ "$has_unverified_phases" = true ]; }; }
}

suggest_verify_unverified() {
  local fallback="$1" label
  if [ -n "$first_unverified_phase" ]; then
    label="$first_unverified_phase"
    if [ -n "$first_unverified_slug" ]; then
      label="$first_unverified_phase ($(fmt_phase_name "${first_unverified_slug#*-}"))"
    fi
    suggest "/meridian:transit -- Verify $label before continuing"
  else
    suggest "$fallback"
  fi
}

suggest_phase_line() {
  local target="$1" prefix="$2" suffix="$3" dir phase_number phase_name
  for dir in "$PHASES_DIR"/*/; do
    [ -d "$dir" ] || continue
    phase_number=$(basename "$dir" | sed 's/[^0-9].*//')
    if [ "$phase_number" = "$target" ]; then
      phase_name=$(basename "$dir" | sed 's/^[0-9]*-//')
      suggest "/meridian:transit -- ${prefix} $target: $(fmt_phase_name "$phase_name")${suffix}"
      break
    fi
  done
  return 0
}

suggest_fix_plan() {
  local detail="$1" fallback="$2" first_fail
  if [ -n "$failing_plan_ids" ]; then
    first_fail=$(echo "$failing_plan_ids" | awk '{print $1}')
    suggest "/meridian:fix -- Fix plan $first_fail ($detail)"
  else
    suggest "/meridian:fix -- $fallback"
  fi
}

suggest_uat_remediation() {
  if [ "$current_uat_major_or_higher" = true ]; then
    suggest "/meridian:transit -- Remediate UAT issues for $current_uat_issues_label"
  else
    suggest "/meridian:fix -- Fix minor UAT issues in $current_uat_issues_label"
  fi
}

suggest_reverification() {
  suggest "/meridian:transit -- Re-verify Phase ${pd_next_phase:-} after remediation"
}

suggest_resume_verify() {
  suggest "/meridian:transit -- Resume Verify for Phase ${pd_next_phase:-}"
}

continue_target_available() {
  { [ -n "$next_unbuilt" ] || [ -n "$next_unplanned" ]; } && ! { [ "$cfg_auto_uat" = true ] && [ "$has_unverified_phases" = true ]; }
}

suggest_continue_phase() {
  local target="${next_unbuilt:-$next_unplanned}"
  if [ -n "$next_undiscussed" ] && [ "$next_undiscussed" = "$target" ]; then
    suggest "/meridian:discuss $target -- Discuss phase before planning"
  elif [ -n "$next_preseeded" ] && [ "$next_preseeded" = "$target" ]; then
    suggest_phase_line "$target" "Plan Phase" " (discussion pre-seeded from UAT)"
  else
    suggest_phase_line "$target" "Continue Phase" ""
  fi
}

parse_debug_session_output() {
  local line key
  while IFS= read -r line; do
    key="${line%%=*}"
    decode_printf_q "${line#*=}"
    case "$key" in
      active_session) DEBUG_ACTIVE_SESSION="$DECODED_VALUE" ;;
      session_file) DEBUG_SESSION_FILE="$DECODED_VALUE" ;;
      session_status) DEBUG_SESSION_STATUS="$DECODED_VALUE" ;;
    esac
  done <<< "$1"
}

load_debug_session() {
  local session_output
  DEBUG_ACTIVE_SESSION=""
  DEBUG_SESSION_FILE=""
  DEBUG_SESSION_STATUS=""
  session_output=$("$SCRIPT_DIR/debug-session-state.sh" get-or-latest "$PLANNING_DIR" 2>/dev/null) || true
  [ -n "$session_output" ] || return 1
  parse_debug_session_output "$session_output"
  [ "${DEBUG_ACTIVE_SESSION:-none}" != "none" ] && [ -n "$DEBUG_SESSION_FILE" ] && [ -f "$DEBUG_SESSION_FILE" ]
}

debug_fallback_available() {
  [ "${phase_count:-0}" -eq 0 ] && [ -d "$PLANNING_DIR/debugging" ]
}
