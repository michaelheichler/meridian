# contract state is global because routing reads the validated round facts
ROUND_CLASSIFICATION_TYPES=""
ROUND_CLASSIFICATION_IDS=""
ROUND_CLASSIFICATION_PATHS=""
ROUND_CLASSIFICATION_TYPE_COUNT=0
ROUND_CLASSIFICATION_ID_COUNT=0
ROUND_CODE_FIX_COUNT=0
ROUND_DOC_FIX_COUNT=0
ROUND_DOC_FIX_PATHS=""
ROUND_DOC_FIX_PATH_COUNT=0
ROUND_PLAN_AMENDMENT_COUNT=0
ROUND_PLAN_AMENDMENT_SOURCE_PLANS=""
ROUND_PLAN_AMENDMENT_SOURCE_PLAN_COUNT=0
ROUND_CLASSIFICATIONS_VALID=true
ROUND_KNOWN_ISSUE_INPUTS_JSON='[]'
ROUND_KNOWN_ISSUE_RESOLUTIONS_JSON='[]'
ROUND_KNOWN_ISSUE_OUTCOMES_JSON='[]'
ROUND_CARRIED_KNOWN_ISSUES_JSON='[]'
ROUND_KNOWN_ISSUE_INPUT_COUNT=0
ROUND_KNOWN_ISSUE_RESOLUTION_COUNT=0
ROUND_KNOWN_ISSUE_OUTCOME_COUNT=0
ROUND_CARRIED_KNOWN_ISSUE_COUNT=0
ROUND_KNOWN_ISSUE_CONTRACT_REQUIRED="false"
ROUND_KNOWN_ISSUES_VALID=true
ROUND_PROCESS_EXCEPTION_EVIDENCE_VALID=false
EXEMPT_FAIL_COUNT=0
UNRESOLVED_FAIL_COUNT=0

count_nonblank_lines() {
  printf '%s\n' "${1:-}" | awk 'NF { count++ } END { print count + 0 }'
}

count_exact_lines() {
  printf '%s\n' "${1:-}" | awk -v needle="${2:-}" '$0 == needle { count++ } END { print count + 0 }'
}

load_classification_lists() {
  local class_types=""
  local class_ids=""
  local class_paths=""
  local class_plans=""
  class_types=$(collect_fail_classification_types_in_dir "$PLAN_SCOPE_DIR")
  class_ids=$(collect_fail_classification_ids_in_dir "$PLAN_SCOPE_DIR" | (sort -u 2>/dev/null || sort -u))
  class_paths=$(collect_fail_classification_paths_in_dir "$PLAN_SCOPE_DIR")
  class_plans=$(collect_fail_classification_source_plans_in_dir "$PLAN_SCOPE_DIR")
  declare -g ROUND_CLASSIFICATION_TYPES="$class_types"
  declare -g ROUND_CLASSIFICATION_IDS="$class_ids"
  declare -g ROUND_CLASSIFICATION_PATHS="$class_paths"
  declare -g ROUND_PLAN_AMENDMENT_SOURCE_PLANS="$class_plans"
}

load_classification_counts() {
  local type_total="" id_total="" code_total="" doc_total="" amend_total="" plan_total=""
  type_total=$(count_nonblank_lines "$ROUND_CLASSIFICATION_TYPES")
  id_total=$(count_nonblank_lines "$ROUND_CLASSIFICATION_IDS")
  code_total=$(count_exact_lines "$ROUND_CLASSIFICATION_TYPES" "code-fix")
  doc_total=$(count_exact_lines "$ROUND_CLASSIFICATION_TYPES" "doc-fix")
  amend_total=$(count_exact_lines "$ROUND_CLASSIFICATION_TYPES" "plan-amendment")
  plan_total=$(count_nonblank_lines "$ROUND_PLAN_AMENDMENT_SOURCE_PLANS")
  declare -g ROUND_CLASSIFICATION_TYPE_COUNT="$type_total"
  declare -g ROUND_CLASSIFICATION_ID_COUNT="$id_total"
  declare -g ROUND_CODE_FIX_COUNT="$code_total"
  declare -g ROUND_DOC_FIX_COUNT="$doc_total"
  declare -g ROUND_PLAN_AMENDMENT_COUNT="$amend_total"
  declare -g ROUND_PLAN_AMENDMENT_SOURCE_PLAN_COUNT="$plan_total"
}

load_doc_fix_paths() {
  local doc_paths=""
  local doc_path_total=""
  if [ "$ROUND_DOC_FIX_COUNT" -gt 0 ] 2>/dev/null; then
    doc_paths=$(printf '%s\n' "$ROUND_CLASSIFICATION_PATHS" | sed '/^[[:space:]]*$/d')
  fi
  doc_path_total=$(count_nonblank_lines "$doc_paths")
  declare -g ROUND_DOC_FIX_PATHS="$doc_paths"
  declare -g ROUND_DOC_FIX_PATH_COUNT="$doc_path_total"
}

validate_round_classifications() {
  if [ "$ROUND_CLASSIFICATION_ID_COUNT" -ne "$ROUND_CLASSIFICATION_TYPE_COUNT" ] 2>/dev/null; then
    declare -g ROUND_CLASSIFICATIONS_VALID=false
  elif [ "$ROUND_CLASSIFICATION_TYPE_COUNT" -gt 0 ] 2>/dev/null && ! fail_classification_types_are_valid <<< "$ROUND_CLASSIFICATION_TYPES"; then
    declare -g ROUND_CLASSIFICATIONS_VALID=false
  elif [ "$ROUND_DOC_FIX_COUNT" -gt 0 ] 2>/dev/null && [ "$ROUND_DOC_FIX_PATH_COUNT" -ne "$ROUND_DOC_FIX_COUNT" ] 2>/dev/null; then
    declare -g ROUND_CLASSIFICATIONS_VALID=false
  elif [ "$METADATA_ONLY_ROUND" = "true" ] && [ "$SOURCE_FAIL_ROW_COUNT" -gt 0 ] 2>/dev/null && [ "$ROUND_CLASSIFICATION_ID_COUNT" -eq 0 ] 2>/dev/null; then
    declare -g ROUND_CLASSIFICATIONS_VALID=false
  elif [ "$SOURCE_FAIL_ROW_COUNT" -gt 0 ] 2>/dev/null && {
    [ "$ROUND_CLASSIFICATION_TYPE_COUNT" -ne "$SOURCE_FAIL_ROW_COUNT" ] 2>/dev/null \
      || ! classification_ids_cover_source_fail_ids "$SOURCE_FAIL_IDS" "$ROUND_CLASSIFICATION_IDS";
  }; then
    declare -g ROUND_CLASSIFICATIONS_VALID=false
  fi
  if [ -z "$GIT_ROOT" ] && [ "$ROUND_CODE_FIX_COUNT" -gt 0 ] 2>/dev/null; then
    declare -g ROUND_CHANGE_EVIDENCE_UNAVAILABLE="true"
  fi
}

load_known_issue_documents() {
  local input_json=""
  local resolution_json=""
  local outcome_json=""
  local carried_json=""
  input_json=$(collect_frontmatter_json_object_array_in_dir "$PLAN_SCOPE_DIR" plan known_issues_input issue)
  resolution_json=$(collect_frontmatter_json_object_array_in_dir "$PLAN_SCOPE_DIR" plan known_issue_resolutions resolution)
  outcome_json=$(collect_frontmatter_json_object_array_in_dir "$SUMMARY_SCOPE_DIR" summary known_issue_outcomes outcome)
  carried_json=$(load_known_issue_registry_json "$ROUND_KNOWN_ISSUE_BACKLOG_PATH")
  declare -g ROUND_KNOWN_ISSUE_INPUTS_JSON="$input_json"
  declare -g ROUND_KNOWN_ISSUE_RESOLUTIONS_JSON="$resolution_json"
  declare -g ROUND_KNOWN_ISSUE_OUTCOMES_JSON="$outcome_json"
  declare -g ROUND_CARRIED_KNOWN_ISSUES_JSON="$carried_json"
}

load_known_issue_counts() {
  local input_total="" resolution_total="" outcome_total="" carried_total=""
  input_total=$(json_object_array_length "$ROUND_KNOWN_ISSUE_INPUTS_JSON")
  resolution_total=$(json_object_array_length "$ROUND_KNOWN_ISSUE_RESOLUTIONS_JSON")
  outcome_total=$(json_object_array_length "$ROUND_KNOWN_ISSUE_OUTCOMES_JSON")
  carried_total=$(json_object_array_length "$ROUND_CARRIED_KNOWN_ISSUES_JSON")
  declare -g ROUND_KNOWN_ISSUE_INPUT_COUNT="$input_total"
  declare -g ROUND_KNOWN_ISSUE_RESOLUTION_COUNT="$resolution_total"
  declare -g ROUND_KNOWN_ISSUE_OUTCOME_COUNT="$outcome_total"
  declare -g ROUND_CARRIED_KNOWN_ISSUE_COUNT="$carried_total"
}

mark_known_issue_contract_required() {
  if [ "$ROUND_KNOWN_ISSUE_INPUT_COUNT" -gt 0 ] 2>/dev/null \
    || [ "$ROUND_KNOWN_ISSUE_RESOLUTION_COUNT" -gt 0 ] 2>/dev/null \
    || [ "$ROUND_KNOWN_ISSUE_OUTCOME_COUNT" -gt 0 ] 2>/dev/null \
    || [ "$ROUND_CARRIED_KNOWN_ISSUE_COUNT" -gt 0 ] 2>/dev/null \
    || [ "${ROUND_INPUT_MODE:-none}" = "known-issues" ] \
    || [ "${ROUND_INPUT_MODE:-none}" = "both" ]; then
    declare -g ROUND_KNOWN_ISSUE_CONTRACT_REQUIRED="true"
  fi
}

validate_known_issue_contract() {
  [ "$ROUND_KNOWN_ISSUE_CONTRACT_REQUIRED" = "true" ] || return 0
  if [ "$ROUND_KNOWN_ISSUE_INPUT_COUNT" -eq 0 ] 2>/dev/null; then
    declare -g ROUND_KNOWN_ISSUES_VALID=false
  elif [ "$ROUND_CARRIED_KNOWN_ISSUE_COUNT" -gt 0 ] 2>/dev/null && ! json_object_array_covers_full_issue_objects "$ROUND_CARRIED_KNOWN_ISSUES_JSON" "$ROUND_KNOWN_ISSUE_INPUTS_JSON"; then
    declare -g ROUND_KNOWN_ISSUES_VALID=false
  elif ! json_object_array_covers_full_issue_objects "$ROUND_KNOWN_ISSUE_INPUTS_JSON" "$ROUND_KNOWN_ISSUE_RESOLUTIONS_JSON"; then
    declare -g ROUND_KNOWN_ISSUES_VALID=false
  elif ! json_object_array_covers_full_issue_objects "$ROUND_KNOWN_ISSUE_INPUTS_JSON" "$ROUND_KNOWN_ISSUE_OUTCOMES_JSON"; then
    declare -g ROUND_KNOWN_ISSUES_VALID=false
  elif ! json_object_array_dispositions_match "$ROUND_KNOWN_ISSUE_RESOLUTIONS_JSON" "$ROUND_KNOWN_ISSUE_OUTCOMES_JSON"; then
    declare -g ROUND_KNOWN_ISSUES_VALID=false
  elif json_object_array_has_disposition "$ROUND_KNOWN_ISSUE_OUTCOMES_JSON" "unresolved" && [ "$KNOWN_ISSUES_COUNT" -eq 0 ] 2>/dev/null; then
    declare -g ROUND_KNOWN_ISSUES_VALID=false
  fi
}

validate_process_exception_evidence() {
  if paths_include_process_exception_evidence "$PHASE_DIR" <<< "$ROUND_ALL_RECORDED_PATHS"; then
    declare -g ROUND_PROCESS_EXCEPTION_EVIDENCE_VALID=true
  elif [ "$METADATA_ONLY_ROUND" = "true" ] \
    && [ "$ROUND_CHANGE_EVIDENCE_UNAVAILABLE" = "true" ] \
    && paths_are_process_exception_evidence_artifacts "$PHASE_DIR" <<< "$ROUND_RECORDED_STRUCTURAL_PATHS"; then
    declare -g ROUND_PROCESS_EXCEPTION_EVIDENCE_VALID=true
  fi
}

evaluate_round_contract() {
  gate_in_round_scope || return 0
  load_classification_lists
  load_classification_counts
  load_doc_fix_paths
  validate_round_classifications
  load_known_issue_documents
  load_known_issue_counts
  mark_known_issue_contract_required
  validate_known_issue_contract
  if [ "$ROUND_KNOWN_ISSUE_INPUT_COUNT" -gt 0 ] 2>/dev/null && [ "$SOURCE_FAIL_ROW_COUNT" -eq 0 ] 2>/dev/null && [ -z "$SOURCE_VERIFICATION_PATH" ]; then
    declare -g ROUND_SOURCE_VERIFICATION_MISSING="false"
  fi
  validate_process_exception_evidence
}

compute_exempt_fail_count() {
  local exempt_total=""
  declare -g EXEMPT_FAIL_COUNT=0
  declare -g UNRESOLVED_FAIL_COUNT="$FAIL_COUNT"
  gate_in_round_scope && [ "$ROUND_CLASSIFICATIONS_VALID" = "true" ] || return 0
  exempt_total=$(count_fail_ids_with_round_classifications "$VERIF_PATH" "$PLAN_SCOPE_DIR" 2>/dev/null || printf '0')
  case "${exempt_total:-}" in
    ''|*[!0-9]*) exempt_total=0 ;;
  esac
  if [ "$exempt_total" -le "$FAIL_COUNT" ] 2>/dev/null; then
    declare -g EXEMPT_FAIL_COUNT="$exempt_total"
    declare -g UNRESOLVED_FAIL_COUNT=$((FAIL_COUNT - exempt_total))
  fi
}
