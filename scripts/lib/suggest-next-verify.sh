verify_target_phase=""
verify_target_phase_dir=""
verify_target_uat=""
uat_major_or_higher=false
SN_VERIFY_DIRS=()

find_verify_target_by_number() {
  local dir phase_number
  for dir in "$PHASES_DIR"/*/; do
    [ -d "$dir" ] || continue
    phase_number=$(basename "$dir" | sed 's/[^0-9].*//' | sed 's/^0*//')
    [ -z "$phase_number" ] && phase_number="0"
    if [ "$phase_number" = "$verify_target_phase" ]; then
      verify_target_phase_dir="$dir"
      break
    fi
  done
  return 0
}

collect_verify_dirs() {
  local verify_dir_entry
  SN_VERIFY_DIRS=()
  while IFS= read -r verify_dir_entry; do
    [ -n "$verify_dir_entry" ] || continue
    SN_VERIFY_DIRS+=("${verify_dir_entry%/}/")
  done < <(list_child_dirs_sorted "$PHASES_DIR")
}

find_verify_target_with_issues() {
  local dir plan_total summary_total uat_path uat_status
  collect_verify_dirs

  for dir in ${SN_VERIFY_DIRS[@]+"${SN_VERIFY_DIRS[@]}"}; do
    [ -d "$dir" ] || continue
    plan_total=$(count_phase_plans "$dir")
    summary_total=$(count_complete_summaries "$dir")
    if [ "$plan_total" -eq 0 ] || [ "$summary_total" -lt "$plan_total" ]; then
      continue
    fi
    uat_path=$(current_uat "$dir")
    if [ -f "$uat_path" ]; then
      uat_status=$(read_status_field "$uat_path")
      if [ "$uat_status" = "issues_found" ]; then
        verify_target_phase_dir="$dir"
        verify_target_phase=$(basename "$dir" | sed 's/[^0-9].*//' | sed 's/^0*//')
        [ -z "$verify_target_phase" ] && verify_target_phase="0"
        break
      fi
    fi
  done
  return 0
}

classify_verify_severity() {
  local uat_critical uat_major uat_minor tagged_severities
  if [ -f "$verify_target_uat" ]; then
    uat_critical=$(grep -Eci 'severity:\**[[:space:]]*\**[[:space:]]*critical' "$verify_target_uat" || true)
    uat_major=$(grep -Eci 'severity:\**[[:space:]]*\**[[:space:]]*major' "$verify_target_uat" || true)
    uat_minor=$(grep -Eci 'severity:\**[[:space:]]*\**[[:space:]]*minor' "$verify_target_uat" || true)
    tagged_severities=$((uat_critical + uat_major + uat_minor))

    if [ "$uat_critical" -gt 0 ] || [ "$uat_major" -gt 0 ] || [ "$tagged_severities" -eq 0 ]; then
      uat_major_or_higher=true
    fi
  elif [ -n "$verify_target_phase_dir" ]; then
    uat_major_or_higher=true
  fi
  return 0
}

resolve_verify_target() {
  verify_target_phase="$TARGET_PHASE_ARG"

  if [ -n "$verify_target_phase" ]; then
    verify_target_phase="${verify_target_phase#"${verify_target_phase%%[!0]*}"}"
    [ -z "$verify_target_phase" ] && verify_target_phase="0"
    find_verify_target_by_number
  else
    find_verify_target_with_issues
  fi

  if [ -n "$verify_target_phase_dir" ]; then
    verify_target_uat=$(current_uat "$verify_target_phase_dir")
  fi

  classify_verify_severity
}
