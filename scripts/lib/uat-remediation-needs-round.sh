require_issues_found_uat() {
  local uat_file="$1" uat_class
  uat_class=$(uat_file_status_class "$uat_file")
  if [ "$uat_class" != "issues_found" ]; then
    echo "Error: needs-round requires a finalized 'issues_found' UAT; current UAT is '$uat_class': $uat_file" >&2
    exit 1
  fi
}

preflight_legacy_remediation_needs_round() {
  local legacy_stage legacy_round legacy_round_padded legacy_uat

  [ ! -f "$STATE_FILE" ] && [ -f "$LEGACY_REMED_STATE_FILE" ] || return 0

  legacy_stage=$(read_state_stage_value "$LEGACY_REMED_STATE_FILE")
  case "$legacy_stage" in
    verify|done) ;;
    *)
      echo "Error: needs-round requires stage verify or done, got: $legacy_stage" >&2
      exit 1
      ;;
  esac

  legacy_round=$(read_state_round_value "$LEGACY_REMED_STATE_FILE")
  legacy_round_padded=$(normalize_round_padded_value "$legacy_round") || exit 1
  legacy_uat="$PHASE_DIR/remediation/round-${legacy_round_padded}/R${legacy_round_padded}-UAT.md"
  if [ ! -f "$legacy_uat" ]; then
    echo "Error: needs-round current round UAT evidence is missing for round $legacy_round_padded" >&2
    exit 1
  fi

  if type uat_file_status_class >/dev/null 2>&1; then
    require_issues_found_uat "$legacy_uat"
  fi
}

verify_round_dir_uat() {
  local current_round current_round_padded phase_num current_round_uat current_flat_uat current_uat_file
  current_round=$(get_round)
  current_round_padded=$(normalize_round_padded_value "$current_round") || exit 1
  phase_num=$(extract_phase_num)
  current_round_uat="$PHASE_DIR/remediation/uat/round-${current_round_padded}/R${current_round_padded}-UAT.md"
  current_flat_uat="$PHASE_DIR/${phase_num}-UAT-round-${current_round_padded}.md"
  if [ -f "$current_round_uat" ]; then
    current_uat_file="$current_round_uat"
  elif [ -n "$phase_num" ] && [ -f "$current_flat_uat" ]; then
    current_uat_file="$current_flat_uat"
  else
    echo "Error: needs-round current round UAT evidence is missing for round $current_round_padded" >&2
    exit 1
  fi
  require_issues_found_uat "$current_uat_file"
}

verify_legacy_current_uat() {
  local current_uat_file
  current_uat_file=$(current_uat "$PHASE_DIR")
  if [ -n "$current_uat_file" ] && [ -f "$current_uat_file" ]; then
    require_issues_found_uat "$current_uat_file"
  fi
}

verify_current_uat_issues_found() {
  local current_layout
  current_layout=$(get_layout)
  if [ "$current_layout" = "round-dir" ]; then
    verify_round_dir_uat
  elif type current_uat >/dev/null 2>&1; then
    verify_legacy_current_uat
  fi
}

cmd_needs_round() {
  local current_stage
  if [ ! -f "$STATE_FILE" ] && [ -f "$LEGACY_REMED_STATE_FILE" ]; then
    preflight_legacy_remediation_needs_round
    migrate_legacy_remediation_state_if_needed
  fi
  if [ ! -f "$STATE_FILE" ] && [ ! -f "$LEGACY_STATE_FILE" ]; then
    echo "Error: no UAT remediation state exists for $PHASE_DIR, cannot advance to next round without prior init" >&2
    exit 1
  fi
  current_stage=$(get_stage)
  case "$current_stage" in
    verify|done) ;;
    *)
      echo "Error: needs-round requires stage verify or done, got: $current_stage" >&2
      exit 1
      ;;
  esac
  if type uat_file_status_class >/dev/null 2>&1; then
    verify_current_uat_issues_found
  fi
  start_new_round
}
