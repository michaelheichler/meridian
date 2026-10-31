# awk programs sit in constants because inline they exceed the function limit
QA_GATE_AWK_WRITER='
  BEGIN { in_fm=0 }
  NR==1 && /^---[[:space:]]*$/ { in_fm=1; next }
  in_fm && /^---[[:space:]]*$/ { exit }
  in_fm && /^writer:/ { sub(/^writer:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit }
'

QA_GATE_AWK_RESULT='
  BEGIN { in_fm=0; result_seen=0; status_seen=0; result=""; status="" }
  NR==1 && /^---[[:space:]]*$/ { in_fm=1; next }
  in_fm && /^---[[:space:]]*$/ { exit }
  in_fm && /^result:/ {
    result_seen=1
    result=$0
    sub(/^result:[[:space:]]*/, "", result)
    sub(/[[:space:]]+$/, "", result)
    next
  }
  in_fm && /^status:/ {
    status_seen=1
    status=$0
    sub(/^status:[[:space:]]*/, "", status)
    sub(/[[:space:]]+$/, "", status)
    next
  }
  END {
    if (result_seen) {
      print toupper(result)
    } else if (status_seen && (toupper(status) == "PASS" || toupper(status) == "FAIL" || toupper(status) == "PARTIAL")) {
      print toupper(status)
    }
  }
'

# shared verification facts because routing reads them after the scans finish
WRITER=""
RESULT=""
FAIL_COUNT=0
DEVIATION_COUNT=0

emit_unavailable_gate_report() {
  local result_value="${1:-missing}"
  local with_known_issues="${2:-true}"
  echo "qa_gate_writer=missing"
  echo "qa_gate_result=$result_value"
  echo "qa_gate_fail_count=0"
  echo "qa_gate_deviation_count=0"
  if [ "$with_known_issues" = "true" ]; then
    echo "qa_gate_known_issue_count=0"
  fi
  echo "qa_gate_plan_count=0"
  echo "qa_gate_plans_verified_count=0"
  echo "qa_gate_routing=QA_RERUN_REQUIRED"
}

exit_without_phase_dir() {
  [ -z "$PHASE_DIR" ] || return 0
  emit_unavailable_gate_report missing false
  exit 0
}

exit_without_readable_verification() {
  if [ ! -f "$VERIF_PATH" ]; then
    emit_unavailable_gate_report missing true
    exit 0
  fi
  if [ ! -r "$VERIF_PATH" ]; then
    emit_unavailable_gate_report unreadable true
    exit 0
  fi
}

read_verification_frontmatter() {
  local writer_value=""
  local result_value=""
  writer_value=$(awk "$QA_GATE_AWK_WRITER" "$VERIF_PATH" 2>/dev/null)
  result_value=$(awk "$QA_GATE_AWK_RESULT" "$VERIF_PATH" 2>/dev/null)
  printf -v WRITER '%s' "$writer_value"
  printf -v RESULT '%s' "$result_value"
}

count_gate_findings() {
  local fail_total=""
  local deviation_total=""
  fail_total=$(count_fail_rows_in_verification "$VERIF_PATH")
  printf -v FAIL_COUNT '%s' "$fail_total"
  if gate_in_round_scope; then
    deviation_total=$(count_deviations_in_dir "$PHASE_DIR" "$SUMMARY_SCOPE_DIR" "$PLAN_SCOPE_DIR")
  else
    deviation_total=$(count_deviations_in_dir "$PHASE_DIR" "$SUMMARY_SCOPE_DIR")
  fi
  printf -v DEVIATION_COUNT '%s' "$deviation_total"
}
