find_active_qa_remediation_candidate() {
  local stage
  [ -f "$PHASE_DIR/remediation/qa/.qa-remediation-stage" ] && [ "$REMEDIATION_KIND" != "uat" ] || return 1
  stage=$(grep '^stage=' "$PHASE_DIR/remediation/qa/.qa-remediation-stage" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]')
  case "${stage:-none}" in
    verify|done) ;;
    *) return 1 ;;
  esac
  _cvc_candidates+=("$PHASE_DIR/remediation/qa")
  _cvc_preferred_round=$(grep '^round=' "$PHASE_DIR/remediation/qa/.qa-remediation-stage" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]')
  if ! [[ "${_cvc_preferred_round:-}" =~ ^[0-9]+$ ]]; then
    _cvc_preferred_round=""
  elif [ -n "$_cvc_preferred_round" ]; then
    _cvc_preferred_round=$(printf '%02d' "$((10#$_cvc_preferred_round))")
  fi
  _cvc_preferred_kind="qa"
  _active_remediation=true
}

find_active_uat_remediation_candidate() {
  local stage
  [ -f "$PHASE_DIR/remediation/uat/.uat-remediation-stage" ] && [ "$REMEDIATION_KIND" != "qa" ] || return 1
  [ "$_active_remediation" = false ] || return 1
  stage=$(grep '^stage=' "$PHASE_DIR/remediation/uat/.uat-remediation-stage" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]')
  case "${stage:-none}" in
    research|plan|execute|fix|verify|done) ;;
    *) return 1 ;;
  esac
  _cvc_candidates+=("$PHASE_DIR/remediation/uat")
  _cvc_preferred_round=$(grep '^round=' "$PHASE_DIR/remediation/uat/.uat-remediation-stage" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]')
  if ! [[ "${_cvc_preferred_round:-}" =~ ^[0-9]+$ ]]; then
    _cvc_preferred_round=""
  elif [ -n "$_cvc_preferred_round" ]; then
    _cvc_preferred_round=$(printf '%02d' "$((10#$_cvc_preferred_round))")
  fi
  _cvc_preferred_kind="uat"
  _active_remediation=true
}

fallback_remediation_candidates() {
  if [ "$REMEDIATION_KIND" = "uat" ]; then
    _cvc_candidates+=("$PHASE_DIR/remediation/uat")
  elif [ "$REMEDIATION_KIND" = "qa" ]; then
    _cvc_candidates+=("$PHASE_DIR/remediation/qa")
  else
    _cvc_candidates+=("$PHASE_DIR/remediation/uat" "$PHASE_DIR/remediation/qa")
  fi
}

resolve_remediation_candidates() {
  _cvc_candidates=()
  _active_remediation=false
  find_active_qa_remediation_candidate || true
  find_active_uat_remediation_candidate || true
  if [ "$_active_remediation" = false ]; then
    fallback_remediation_candidates
  fi
  return 0
}

pick_preferred_qa_round() {
  local candidate="$1" preferred_round_dir
  [ "$candidate" = "$PHASE_DIR/remediation/qa" ] && [ "$_cvc_preferred_kind" = "qa" ] && [ -n "$_cvc_preferred_round" ] || return 1
  preferred_round_dir="$candidate/round-$_cvc_preferred_round"
  if [ -d "$preferred_round_dir" ] && \
     ls "$preferred_round_dir"/R"$_cvc_preferred_round"-PLAN.md >/dev/null 2>&1 && \
     ls "$preferred_round_dir"/R"$_cvc_preferred_round"-SUMMARY.md >/dev/null 2>&1 && \
     is_summary_terminal "$preferred_round_dir/R${_cvc_preferred_round}-SUMMARY.md"; then
    LATEST_ROUND="$_cvc_preferred_round"
    REMED_DIR="$candidate"
    REMED_KIND="qa"
    return 0
  fi
  REMEDIATION_ONLY=false
  return 0
}

pick_preferred_uat_round() {
  local candidate="$1"
  [ "$candidate" = "$PHASE_DIR/remediation/uat" ] && [ "$_cvc_preferred_kind" = "uat" ] && [ -n "$_cvc_preferred_round" ] || return 1
  LATEST_ROUND="$_cvc_preferred_round"
  REMED_DIR="$candidate"
  REMED_KIND="uat"
}

pick_latest_terminal_round() {
  local candidate="$1" best_round_num=0 candidate_round="" round_dir round_num round_pad
  for round_dir in "$candidate"/round-*/; do
    [ -d "$round_dir" ] || continue
    round_num=$(basename "$round_dir" | sed 's/^round-0*//')
    round_num=${round_num:-0}
    round_pad=$(printf '%02d' "$round_num")
    if [ "$round_num" -gt "$best_round_num" ] 2>/dev/null && \
       ls "$round_dir"/R"${round_pad}"-PLAN.md >/dev/null 2>&1 && \
       ls "$round_dir"/R"${round_pad}"-SUMMARY.md >/dev/null 2>&1 && \
       is_summary_terminal "$round_dir/R${round_pad}-SUMMARY.md"; then
      best_round_num="$round_num"
      candidate_round="$round_pad"
    fi
  done
  [ -n "$candidate_round" ] || return 1
  LATEST_ROUND="$candidate_round"
  REMED_DIR="$candidate"
  case "$candidate" in
    */remediation/uat) REMED_KIND="uat" ;;
    */remediation/qa) REMED_KIND="qa" ;;
  esac
}

resolve_latest_remediation_round() {
  local candidate
  for candidate in "${_cvc_candidates[@]}"; do
    [ -d "$candidate" ] || continue
    if pick_preferred_qa_round "$candidate"; then
      [ -n "$LATEST_ROUND" ] && return 0
      [ "$REMEDIATION_ONLY" = false ] && return 0
    fi
    if pick_preferred_uat_round "$candidate"; then
      return 0
    fi
    if pick_latest_terminal_round "$candidate"; then
      return 0
    fi
  done
  return 1
}

resolve_legacy_remediation_round() {
  local best_round_num=0 round_dir round_num round_pad
  [ -z "$LATEST_ROUND" ] && [ -d "$PHASE_DIR/remediation" ] && [ "$REMEDIATION_KIND" != "qa" ] || return 0
  REMED_DIR="$PHASE_DIR/remediation"
  REMED_KIND="legacy"
  for round_dir in "$REMED_DIR"/round-*/; do
    [ -d "$round_dir" ] || continue
    round_num=$(basename "$round_dir" | sed 's/^round-0*//')
    round_num=${round_num:-0}
    round_pad=$(printf '%02d' "$round_num")
    if [ "$round_num" -gt "$best_round_num" ] 2>/dev/null && \
       ls "$round_dir"/R"${round_pad}"-PLAN.md >/dev/null 2>&1 && \
       ls "$round_dir"/R"${round_pad}"-SUMMARY.md >/dev/null 2>&1 && \
       is_summary_terminal "$round_dir/R${round_pad}-SUMMARY.md"; then
      best_round_num="$round_num"
      LATEST_ROUND="$round_pad"
    fi
  done
}

resolve_remediation_scope() {
  local round_pad
  LATEST_ROUND=""
  REMED_DIR=""
  REMED_KIND=""
  _cvc_preferred_round=""
  _cvc_preferred_kind=""

  resolve_remediation_candidates
  resolve_latest_remediation_round || true
  resolve_legacy_remediation_round

  if [ -n "$LATEST_ROUND" ]; then
    round_pad=$(printf '%02d' "$((10#$LATEST_ROUND))")
    ALL_PLAN_FILES=$(find "$REMED_DIR/round-$round_pad" -maxdepth 1 \( -name "R${round_pad}-PLAN.md" -o -name "R${round_pad}-*-PLAN.md" \) 2>/dev/null | sort)
    SCOPE_HEADER="verify_scope=remediation round=$round_pad"
    case "$REMED_KIND" in
      qa)
        UAT_PATH=$(bash "${_CVC_SCRIPT_DIR}/resolve-artifact-path.sh" uat "$PHASE_DIR")
        ;;
      *)
        UAT_PATH="${REMED_DIR#"$PHASE_DIR/"}/round-$round_pad/R${round_pad}-UAT.md"
        ;;
    esac
  else
    REMEDIATION_ONLY=false
  fi
}

resolve_full_scope() {
  local plan_files round_plan_files qa_round_plan_files extra_plans
  plan_files=$(find "$PHASE_DIR" -maxdepth 1 ! -name '.*' \( -name '[0-9]*-PLAN.md' -o -name 'PLAN.md' \) 2>/dev/null | sort)
  round_plan_files=$(find "$PHASE_DIR" -path '*/remediation/uat/round-*/R*-PLAN.md' 2>/dev/null | sort)
  if [ -z "$round_plan_files" ]; then
    round_plan_files=$(find "$PHASE_DIR" -path '*/remediation/round-*/R*-PLAN.md' 2>/dev/null | sort)
  fi

  qa_round_plan_files=$(find "$PHASE_DIR" -path '*/remediation/qa/round-*/R*-PLAN.md' 2>/dev/null | sort)

  ALL_PLAN_FILES="$plan_files"
  for extra_plans in "$round_plan_files" "$qa_round_plan_files"; do
    if [ -n "$extra_plans" ]; then
      if [ -n "$ALL_PLAN_FILES" ]; then
        ALL_PLAN_FILES=$(printf '%s\n%s' "$ALL_PLAN_FILES" "$extra_plans")
      else
        ALL_PLAN_FILES="$extra_plans"
      fi
    fi
  done
  SCOPE_HEADER="verify_scope=full"
  UAT_PATH=$(bash "${_CVC_SCRIPT_DIR}/resolve-artifact-path.sh" uat "$PHASE_DIR")
}
