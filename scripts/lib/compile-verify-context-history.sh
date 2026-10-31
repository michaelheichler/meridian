print_known_issues_section() {
  local known_issues_path="$PHASE_DIR/known-issues.json" known_issue_count
  [ -f "$known_issues_path" ] || return 0

  if jq -e '.issues | type == "array"' "$known_issues_path" >/dev/null 2>&1; then
    known_issue_count=$(jq '.issues | length' "$known_issues_path" 2>/dev/null || echo 0)
    if [ "${known_issue_count:-0}" -gt 0 ] 2>/dev/null; then
      echo "=== KNOWN ISSUES ==="
      echo "known_issues_path=$(basename "$known_issues_path")"
      echo "known_issue_count=${known_issue_count}"
      jq -r '
        .issues[]
        | "KNOWN_ISSUE: test=" + (.test // "-")
          + " | file=" + (.file // "-")
          + " | error=" + (.error // "-")
          + " | first_seen_in=" + (.first_seen_in // "-")
          + " | last_seen_in=" + (.last_seen_in // "-")
          + " | times_seen=" + ((.times_seen // 1) | tostring)
          + " | first_seen_round=" + ((.first_seen_round // 0) | tostring)
          + " | last_seen_round=" + ((.last_seen_round // 0) | tostring)
      ' "$known_issues_path" 2>/dev/null || true
      echo ""
    fi
  else
    echo "=== KNOWN ISSUES ==="
    echo "known_issues_error=malformed"
    echo ""
  fi
}

resolve_source_fail_verif() {
  local _cvc_active_round _cvc_prev_round _cvc_expected_source_verif
  # Callers read these flags after the call, so they must stay global
  declare -g _cvc_source_fail_verif_missing=false
  declare -g _cvc_remediation_state_active=false
  [ -f "$PHASE_DIR/remediation/qa/.qa-remediation-stage" ] || {
    if [ -z "$_cvc_source_fail_verif" ] && [ -n "$_cvc_phase_verif" ]; then
      _cvc_source_fail_verif="$_cvc_phase_verif"
    fi
    return 0
  }
  _cvc_remediation_state_active=true
  _cvc_active_round=$(grep '^round=' "$PHASE_DIR/remediation/qa/.qa-remediation-stage" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]' || true)
  if [[ "${_cvc_active_round:-}" =~ ^[0-9]+$ ]] && [ "$((10#${_cvc_active_round}))" -gt 1 ] 2>/dev/null; then
    _cvc_prev_round=$(printf '%02d' "$((10#${_cvc_active_round} - 1))")
    _cvc_expected_source_verif="$PHASE_DIR/remediation/qa/round-${_cvc_prev_round}/R${_cvc_prev_round}-VERIFICATION.md"
    if [ ! -f "$_cvc_expected_source_verif" ]; then
      _cvc_source_fail_verif_missing=true
      _cvc_source_fail_verif=""
    fi
  fi
  if [[ "${_cvc_active_round:-}" =~ ^[0-9]+$ ]] && [ -z "$_cvc_source_fail_verif" ]; then
    _cvc_source_fail_verif_missing=true
  fi
}

frontmatter_result_field() {
  awk '
    BEGIN { in_fm=0 }
    NR==1 && /^---[[:space:]]*$/ { in_fm=1; next }
    in_fm && /^---[[:space:]]*$/ { exit }
    in_fm && /^result:/ { sub(/^result:[[:space:]]*/, ""); print; exit }
  ' "$1" 2>/dev/null
}

print_fail_rows() {
  awk -F'|' -f "${_CVC_SCRIPT_DIR}/lib/verification-fail-lines.awk" "$1" 2>/dev/null || true
}

print_phase_verification_fails() {
  local vhist_result
  [ -n "$_cvc_phase_verif" ] && [ -f "$_cvc_phase_verif" ] || return 0
  vhist_result=$(frontmatter_result_field "$_cvc_phase_verif") || vhist_result=""
  echo "--- Phase VERIFICATION (${vhist_result:-unknown}) ---"
  print_fail_rows "$_cvc_phase_verif"
}

print_original_fail_resolution_status() {
  if [ "$_cvc_source_fail_verif_missing" = true ]; then
    echo "--- ORIGINAL FAIL RESOLUTION STATUS ---"
    echo "source_verification_missing=true"
    return 0
  fi
  [ -n "$_cvc_source_fail_verif" ] && [ -f "$_cvc_source_fail_verif" ] || return 0
  echo "--- ORIGINAL FAIL RESOLUTION STATUS ---"
  awk -F'|' -f "${_CVC_SCRIPT_DIR}/lib/verification-original-fails.awk" "$_cvc_source_fail_verif" 2>/dev/null || true
}

print_qa_round_verification_fails() {
  local verif_file vhist_rr vhist_rresult
  [ -n "$_cvc_qa_round_verifs" ] || return 0
  while IFS= read -r verif_file; do
    [ -f "$verif_file" ] || continue
    vhist_rr=$(basename "$verif_file" | sed 's/^R\([0-9]*\).*/\1/')
    vhist_rresult=$(frontmatter_result_field "$verif_file") || vhist_rresult=""
    echo "--- Round ${vhist_rr} VERIFICATION (${vhist_rresult:-unknown}) ---"
    print_fail_rows "$verif_file"
  done <<< "$_cvc_qa_round_verifs"
}
