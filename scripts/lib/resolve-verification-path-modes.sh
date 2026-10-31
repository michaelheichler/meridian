read_state_field() {
  local key="$1"
  grep "^${key}=" "$STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]' || true
}

read_round() {
  local round
  round=$(read_state_field round)
  round="${round:-01}"
  if ! [[ "$round" =~ ^[0-9]+$ ]]; then
    round="01"
  fi
  printf '%02d' "$((10#$round))"
}

read_stage() {
  local stage
  stage=$(read_state_field stage)
  stage="${stage:-none}"
  case "$stage" in
    plan|execute|verify|done) echo "$stage" ;;
    *) echo "none" ;;
  esac
}

round_verification_path() {
  echo "$PHASE_DIR/remediation/qa/round-$1/R$1-VERIFICATION.md"
}

verification_has_fail_rows() {
  local file_path="${1:-}"
  [ -f "$file_path" ] || return 1
  awk -F'|' -f "$SCRIPT_DIR/lib/verification-fail-rows.awk" "$file_path" 2>/dev/null
}

emit_if_fail_rows() {
  if verification_has_fail_rows "$1"; then
    echo "$1"
  fi
}

mode_current() {
  local phase_path="$1" stage round round_path
  if [ -f "$STATE_FILE" ]; then
    stage=$(read_stage)
    case "$stage" in
      verify|done)
        round=$(read_round)
        round_path=$(round_verification_path "$round")
        if [ -f "$round_path" ] || [ "$stage" = "done" ]; then
          echo "$round_path"
          return 0
        fi
        ;;
    esac
  fi
  echo "$phase_path"
}

mode_authoritative() {
  local phase_path="$1"
  if [ -f "$STATE_FILE" ] && [ "$(read_stage)" = "done" ]; then
    round_verification_path "$(read_round)"
    return 0
  fi
  echo "$phase_path"
}

plan_input_from_rounds() {
  local phase_path="$1" prev_round="$2" search_round candidate_round candidate_path
  [ -f "$(round_verification_path "$prev_round")" ] || return 0

  search_round=$((10#$prev_round))
  while [ "$search_round" -gt 0 ] 2>/dev/null; do
    candidate_round=$(printf '%02d' "$search_round")
    candidate_path=$(round_verification_path "$candidate_round")
    [ -f "$candidate_path" ] || return 0
    if verification_has_fail_rows "$candidate_path"; then
      echo "$candidate_path"
      return 0
    fi
    search_round=$((search_round - 1))
  done
  emit_if_fail_rows "$phase_path"
}

mode_plan_input() {
  local phase_path="$1" round
  if [ -f "$STATE_FILE" ]; then
    round=$(read_round)
    if [ "$((10#$round))" -gt 1 ]; then
      plan_input_from_rounds "$phase_path" "$(printf '%02d' "$((10#$round - 1))")"
      return 0
    fi
  fi
  emit_if_fail_rows "$phase_path"
}
