# reported flag is global because the PASS rules read it after the FAIL check
CLASSIFIED_FAIL_EXEMPTION_REPORTED=false

emit_gate_report() {
  echo "qa_gate_writer=${WRITER:-missing}"
  echo "qa_gate_result=${RESULT:-missing}"
  echo "qa_gate_scope=$REMEDIATION_SCOPE"
  echo "qa_gate_fail_count=$FAIL_COUNT"
  echo "qa_gate_deviation_count=$DEVIATION_COUNT"
  echo "qa_gate_known_issue_count=$KNOWN_ISSUES_COUNT"
  echo "qa_gate_plan_count=$PLAN_COUNT"
  echo "qa_gate_plans_verified_count=$PLANS_VERIFIED_COUNT"
  if [ "$ROUND_IGNORED_EVIDENCE_USED" = "true" ]; then
    echo "qa_gate_planning_ignored_evidence=true"
  fi
}

exit_unless_trusted_result() {
  if [ -z "$WRITER" ] || [ "$WRITER" != "write-verification.sh" ]; then
    echo "qa_gate_routing=QA_RERUN_REQUIRED"
    exit 0
  fi
  if [ -z "$RESULT" ]; then
    echo "qa_gate_routing=QA_RERUN_REQUIRED"
    exit 0
  fi
}

emit_remediation_flag() {
  echo "${1:-}=true"
  echo "qa_gate_routing=REMEDIATION_REQUIRED"
}

emit_plan_coverage_if_partial() {
  if [ "$PLAN_COUNT" -gt 0 ] && [ "$PLANS_VERIFIED_COUNT" -lt "$PLAN_COUNT" ]; then
    echo "qa_gate_plan_coverage=${PLANS_VERIFIED_COUNT}/${PLAN_COUNT}"
  fi
}

phase_deviation_count() {
  local phase_total=""
  phase_total=$(count_deviations_in_dir "$PHASE_DIR" "$PHASE_DIR")
  printf '%s' "$phase_total"
}

route_failed_result() {
  case "$RESULT" in
    FAIL|PARTIAL) ;;
    *) return 0 ;;
  esac
  if gate_in_round_scope \
    && [ "$ROUND_CLASSIFICATIONS_VALID" = "true" ] \
    && [ "$FAIL_COUNT" -gt 0 ] 2>/dev/null \
    && [ "$UNRESOLVED_FAIL_COUNT" -eq 0 ] 2>/dev/null; then
    echo "qa_gate_classified_fail_exemption=true"
    echo "qa_gate_exempt_fail_count=$EXEMPT_FAIL_COUNT"
    declare -g CLASSIFIED_FAIL_EXEMPTION_REPORTED=true
    declare -g RESULT=PASS
    return 0
  fi
  if gate_in_round_scope && [ "$ROUND_CLASSIFICATIONS_VALID" != "true" ]; then
    echo "qa_gate_classifications_invalid=true"
  fi
  echo "qa_gate_routing=REMEDIATION_REQUIRED"
  exit 0
}

emit_exemption_notice() {
  if [ "$EXEMPT_FAIL_COUNT" -gt 0 ] 2>/dev/null && [ "$CLASSIFIED_FAIL_EXEMPTION_REPORTED" != "true" ]; then
    echo "qa_gate_classified_fail_exemption=true"
    echo "qa_gate_exempt_fail_count=$EXEMPT_FAIL_COUNT"
  fi
}

pass_rule_basic_flags() {
  if [ "$UNRESOLVED_FAIL_COUNT" -gt 0 ] 2>/dev/null; then
    emit_remediation_flag qa_gate_fail_count_positive
  elif [ "$ROUND_SUMMARY_NONTERMINAL" = "true" ]; then
    emit_remediation_flag qa_gate_round_summary_nonterminal
  elif [ "$ROUND_SOURCE_VERIFICATION_MISSING" = "true" ]; then
    emit_remediation_flag qa_gate_source_verification_missing
  elif [ "$ROUND_SUMMARY_MISSING" = "true" ]; then
    emit_remediation_flag qa_gate_round_summary_missing
  else
    return 1
  fi
}

pass_rule_round_flags() {
  if [ "$ROUND_PLAN_MISSING" = "true" ]; then
    emit_remediation_flag qa_gate_round_plan_missing
  elif [ "$ROUND_CHANGE_EVIDENCE_UNAVAILABLE" = "true" ] && [ "$ROUND_CODE_FIX_COUNT" -gt 0 ] 2>/dev/null; then
    emit_remediation_flag qa_gate_round_change_evidence_unavailable
  elif [ "$ROUND_CHANGE_EVIDENCE_EMPTY" = "true" ] && [ "$ROUND_CODE_FIX_COUNT" -gt 0 ] 2>/dev/null; then
    emit_remediation_flag qa_gate_round_change_evidence_empty
  else
    return 1
  fi
}

pass_rule_known_issue_contract() {
  if gate_in_round_scope \
    && [ "$ROUND_KNOWN_ISSUE_CONTRACT_REQUIRED" = "true" ] \
    && [ "$ROUND_KNOWN_ISSUES_VALID" != "true" ]; then
    emit_remediation_flag qa_gate_known_issue_contract_invalid
  else
    return 1
  fi
}

pass_rule_classifications_invalid() {
  local phase_total=""
  gate_in_round_scope && [ "$ROUND_CLASSIFICATIONS_VALID" != "true" ] || return 1
  if [ "$METADATA_ONLY_ROUND" = "true" ]; then
    phase_total=$(phase_deviation_count)
    echo "qa_gate_metadata_only_override=true"
    echo "qa_gate_phase_deviation_count=$phase_total"
  fi
  emit_remediation_flag qa_gate_classifications_invalid
}

pass_rule_code_fix_evidence() {
  if gate_in_round_scope && [ "$METADATA_ONLY_ROUND" != "true" ] && [ "$ROUND_CODE_FIX_COUNT" -gt 0 ] 2>/dev/null && ! paths_include_code_fix_evidence "$PHASE_DIR" <<< "$ROUND_ALL_RECORDED_PATHS"; then
    emit_remediation_flag qa_gate_code_fix_evidence_missing
  else
    return 1
  fi
}

pass_rule_plan_amendment() {
  if gate_in_round_scope && [ "$ROUND_PLAN_AMENDMENT_COUNT" -gt 0 ] 2>/dev/null && [ "${GATE_STAGE:-none}" != "done" ] && {
    [ "$ROUND_PLAN_AMENDMENT_SOURCE_PLAN_COUNT" -ne "$ROUND_PLAN_AMENDMENT_COUNT" ] 2>/dev/null \
      || ! plan_amendment_source_plans_are_valid "$PHASE_DIR" <<< "$ROUND_PLAN_AMENDMENT_SOURCE_PLANS" \
      || ! paths_cover_required_original_plan_artifacts "$PHASE_DIR" "$ROUND_PLAN_AMENDMENT_SOURCE_PLANS" <<< "$ROUND_ALL_RECORDED_PATHS";
  }; then
    emit_remediation_flag qa_gate_plan_amendment_evidence_missing
  else
    return 1
  fi
}

pass_rule_deviation_override() {
  if [ "$DEVIATION_COUNT" -gt 0 ] && { [ "$IN_REMEDIATION" = "false" ] || [ "$SUMMARY_SCOPE_DIR" != "$PHASE_DIR" ]; }; then
    echo "qa_gate_deviation_override=true"
    emit_plan_coverage_if_partial
    echo "qa_gate_routing=QA_RERUN_REQUIRED"
  else
    return 1
  fi
}

pass_rule_metadata_only() {
  local phase_total=""
  [ "$METADATA_ONLY_ROUND" = "true" ] || return 1
  if [ "$ROUND_CODE_FIX_COUNT" -gt 0 ] 2>/dev/null; then
    phase_total=$(phase_deviation_count)
    echo "qa_gate_metadata_only_override=true"
    echo "qa_gate_metadata_only_code_fix=true"
    echo "qa_gate_phase_deviation_count=$phase_total"
    echo "qa_gate_routing=REMEDIATION_REQUIRED"
  elif [ "$ROUND_DOC_FIX_COUNT" -gt 0 ] 2>/dev/null \
    && ! paths_include_documentation_fix_evidence "$PHASE_DIR" "$ROUND_DOC_FIX_PATHS" <<< "$ROUND_ALL_RECORDED_PATHS"; then
    emit_remediation_flag qa_gate_doc_fix_evidence_missing
  elif [ "$ROUND_DOC_FIX_COUNT" -gt 0 ] 2>/dev/null; then
    echo "qa_gate_routing=PROCEED_TO_UAT"
  elif [ "$ROUND_PLAN_AMENDMENT_COUNT" -eq 0 ] 2>/dev/null \
    && [ "$ROUND_CLASSIFICATION_TYPE_COUNT" -gt 0 ] 2>/dev/null \
    && [ "$ROUND_PROCESS_EXCEPTION_EVIDENCE_VALID" != "true" ]; then
    emit_remediation_flag qa_gate_process_exception_evidence_missing
  else
    return 1
  fi
}

pass_rule_plan_coverage() {
  if [ "$PLAN_COUNT" -gt 0 ] && [ "$PLANS_VERIFIED_COUNT" -lt "$PLAN_COUNT" ]; then
    emit_plan_coverage_if_partial
    echo "qa_gate_routing=QA_RERUN_REQUIRED"
  else
    return 1
  fi
}

pass_rule_known_issues_flagged() {
  if [ "$KNOWN_ISSUES_STATUS" = "malformed" ] || [ "$KNOWN_ISSUES_STATUS" = "probe_error" ]; then
    emit_remediation_flag qa_gate_known_issues_override
  else
    return 1
  fi
}

pass_rule_known_issues_present() {
  local live_registry_json=""
  [ "$KNOWN_ISSUES_STATUS" = "present" ] && [ "$KNOWN_ISSUES_COUNT" -gt 0 ] 2>/dev/null || return 1
  live_registry_json=$(load_known_issue_registry_json "$PHASE_DIR/known-issues.json")
  if [ "$ROUND_KNOWN_ISSUE_CONTRACT_REQUIRED" = "true" ] \
     && [ "$ROUND_KNOWN_ISSUES_VALID" = "true" ] \
     && [ "$ROUND_KNOWN_ISSUE_OUTCOME_COUNT" -gt 0 ] 2>/dev/null \
     && ! json_object_array_has_disposition "$ROUND_KNOWN_ISSUE_OUTCOMES_JSON" "unresolved" \
     && json_object_array_covers_full_issue_objects "$live_registry_json" "$ROUND_KNOWN_ISSUE_OUTCOMES_JSON"; then
    echo "qa_gate_known_issues_all_addressed=true"
    echo "qa_gate_routing=PROCEED_TO_UAT"
  else
    emit_remediation_flag qa_gate_known_issues_override
  fi
}

route_pass_result() {
  local rule_name=""
  for rule_name in \
    pass_rule_basic_flags pass_rule_round_flags pass_rule_known_issue_contract \
    pass_rule_classifications_invalid pass_rule_code_fix_evidence pass_rule_plan_amendment \
    pass_rule_deviation_override pass_rule_metadata_only pass_rule_plan_coverage \
    pass_rule_known_issues_flagged pass_rule_known_issues_present; do
    if "$rule_name"; then
      return 0
    fi
  done
  echo "qa_gate_routing=PROCEED_TO_UAT"
}

route_gate_result() {
  route_failed_result
  case "$RESULT" in
    PASS)
      emit_exemption_notice
      route_pass_result
      ;;
    FAIL|PARTIAL)
      echo "qa_gate_routing=REMEDIATION_REQUIRED"
      ;;
    *)
      echo "qa_gate_routing=QA_RERUN_REQUIRED"
      ;;
  esac
}
