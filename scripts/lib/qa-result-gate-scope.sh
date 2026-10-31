# shared scope state because later gate stages read these values
VERIF_PATH=""
IN_REMEDIATION="false"
REMEDIATION_SCOPE="phase"
PLAN_SCOPE_DIR=""
SUMMARY_SCOPE_DIR=""
GATE_STAGE=""
GATE_ROUND=""
GATE_ROUND_DIR=""
GATE_ROUND_VERIF=""
GIT_ROOT=""
KNOWN_ISSUES_STATUS="missing"
KNOWN_ISSUES_COUNT=0

gate_in_round_scope() {
  [ "$IN_REMEDIATION" = "true" ] && [ "$SUMMARY_SCOPE_DIR" != "$PHASE_DIR" ]
}

set_verification_target() {
  local target_path="${1:-}"
  local target_name=""
  target_name=$(basename "$target_path")
  declare -g VERIF_PATH="$target_path"
  declare -g VERIF_NAME="$target_name"
}

resolve_gate_verification() {
  local resolved_path=""
  local phase_num=""
  if [ -n "$VERIF_NAME" ]; then
    declare -g VERIF_PATH="$PHASE_DIR/$VERIF_NAME"
    return 0
  fi
  resolved_path=$(bash "$RESOLVE_VERIF_SCRIPT" phase "$PHASE_DIR" 2>/dev/null || true)
  if [ -n "$resolved_path" ]; then
    set_verification_target "$resolved_path"
    return 0
  fi
  phase_num=$(basename "$PHASE_DIR" | grep -oE '^[0-9]+' 2>/dev/null || true)
  declare -g VERIF_NAME="${phase_num:-01}-VERIFICATION.md"
  declare -g VERIF_PATH="$PHASE_DIR/$VERIF_NAME"
}

stage_file_value() {
  local state_file="${1:-}"
  local key_name="${2:-}"
  grep "^${key_name}=" "$state_file" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]' || true
}

normalize_round_number() {
  local raw_round="${1:-}"
  raw_round="${raw_round:-01}"
  if ! [[ "$raw_round" =~ ^[0-9]+$ ]]; then
    raw_round="01"
  fi
  printf '%02d' "$((10#${raw_round}))"
}

adopt_round_scope() {
  local scope_kind="${1:-}"
  declare -g PLAN_SCOPE_DIR="$GATE_ROUND_DIR"
  declare -g SUMMARY_SCOPE_DIR="$GATE_ROUND_DIR"
  declare -g REMEDIATION_SCOPE="$scope_kind round=$GATE_ROUND"
}

set_round_location() {
  local kind_dir="${1:-}"
  local stage_value="${2:-}"
  local round_value="${3:-}"
  declare -g GATE_STAGE="$stage_value"
  declare -g GATE_ROUND="$round_value"
  declare -g GATE_ROUND_DIR="$PHASE_DIR/remediation/${kind_dir}/round-${round_value}"
  declare -g GATE_ROUND_VERIF="${GATE_ROUND_DIR}/R${round_value}-VERIFICATION.md"
}

select_qa_remediation_verification() {
  local authoritative_path=""
  [ "$EXPLICIT_VERIF_NAME" = false ] || return 0
  case "$GATE_STAGE" in
    verify)
      set_verification_target "$GATE_ROUND_VERIF"
      ;;
    done)
      authoritative_path=$(bash "$RESOLVE_VERIF_SCRIPT" authoritative "$PHASE_DIR" 2>/dev/null || true)
      if [ -n "${authoritative_path:-}" ]; then
        set_verification_target "$authoritative_path"
      fi
      ;;
  esac
}

load_qa_remediation_scope() {
  local state_file="$PHASE_DIR/remediation/qa/.qa-remediation-stage"
  local stage_value=""
  local round_value=""
  [ -f "$state_file" ] || return 0
  stage_value=$(stage_file_value "$state_file" stage)
  stage_value="${stage_value:-none}"
  case "$stage_value" in
    plan|execute|verify|done) declare -g IN_REMEDIATION="true" ;;
    *) stage_value="none" ;;
  esac
  round_value=$(stage_file_value "$state_file" round)
  round_value=$(normalize_round_number "$round_value")
  set_round_location qa "$stage_value" "$round_value"
  select_qa_remediation_verification
  if [ "$VERIF_PATH" = "$GATE_ROUND_VERIF" ]; then
    adopt_round_scope qa
  fi
}

load_uat_remediation_scope() {
  local state_file="$PHASE_DIR/remediation/uat/.uat-remediation-stage"
  local stage_value=""
  local round_value=""
  [ "$IN_REMEDIATION" = "false" ] || return 0
  [ -f "$state_file" ] || return 0
  stage_value=$(stage_file_value "$state_file" stage)
  case "${stage_value:-none}" in
    verify|done) declare -g IN_REMEDIATION="true" ;;
    *) stage_value="none" ;;
  esac
  round_value=$(stage_file_value "$state_file" round)
  round_value=$(normalize_round_number "$round_value")
  set_round_location uat "$stage_value" "$round_value"
  if [ "$EXPLICIT_VERIF_NAME" = false ] && [ "$IN_REMEDIATION" = true ]; then
    set_verification_target "$GATE_ROUND_VERIF"
    adopt_round_scope uat
  fi
}

resolve_gate_scope() {
  declare -g IN_REMEDIATION="false"
  declare -g REMEDIATION_SCOPE="phase"
  declare -g PLAN_SCOPE_DIR="$PHASE_DIR"
  declare -g SUMMARY_SCOPE_DIR="$PHASE_DIR"
  resolve_gate_verification
  load_qa_remediation_scope
  load_uat_remediation_scope
}

set_known_issues() {
  declare -g KNOWN_ISSUES_STATUS="${1:-}"
  declare -g KNOWN_ISSUES_COUNT="${2:-0}"
}

apply_known_issues_probe() {
  local probe_status="${1:-}"
  local count_raw="${2:-}"
  case "$probe_status" in
    present|missing|malformed) ;;
    *) set_known_issues probe_error 0; return 0 ;;
  esac
  case "$count_raw" in
    '')
      if [ "$probe_status" = "present" ]; then
        set_known_issues probe_error 0
      else
        set_known_issues "$probe_status" 0
      fi
      ;;
    *[!0-9]*) set_known_issues probe_error 0 ;;
    *)
      if [ "$probe_status" != "present" ] && [ "$count_raw" -gt 0 ] 2>/dev/null; then
        set_known_issues probe_error 0
      else
        set_known_issues "$probe_status" "$count_raw"
      fi
      ;;
  esac
}

probe_known_issues() {
  local probe_meta=""
  local probe_status=""
  local count_raw=""
  [ -f "$SCRIPT_DIR/track-known-issues.sh" ] || return 0
  probe_meta=$(bash "$SCRIPT_DIR/track-known-issues.sh" status "$PHASE_DIR" 2>/dev/null || true)
  probe_status=$(printf '%s\n' "${probe_meta:-}" | awk -F= '/^known_issues_status=/{print $2; exit}')
  count_raw=$(printf '%s\n' "${probe_meta:-}" | awk -F= '/^known_issues_count=/{print $2; exit}')
  apply_known_issues_probe "$probe_status" "$count_raw"
}

recount_known_issues_from_registry() {
  local registry_json=""
  local registry_count=""
  [ "$KNOWN_ISSUES_STATUS" = "probe_error" ] || return 0
  registry_json=$(load_known_issue_registry_json "$PHASE_DIR/known-issues.json")
  registry_count=$(json_object_array_length "${registry_json:-[]}")
  case "${registry_count:-}" in
    ''|*[!0-9]*) declare -g KNOWN_ISSUES_COUNT=0 ;;
    *) declare -g KNOWN_ISSUES_COUNT="$registry_count" ;;
  esac
}

load_gate_known_issues() {
  local git_root=""
  git_root=$(git -C "$PHASE_DIR" rev-parse --show-toplevel 2>/dev/null || true)
  declare -g GIT_ROOT="$git_root"
  declare -g KNOWN_ISSUES_STATUS="missing"
  declare -g KNOWN_ISSUES_COUNT=0
  probe_known_issues
  recount_known_issues_from_registry
}
