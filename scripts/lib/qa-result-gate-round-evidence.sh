# shared round evidence because the contract and routing stages read these values
ROUND_SOURCE_VERIFICATION_MISSING="false"
SOURCE_VERIFICATION_PATH=""
SOURCE_VERIFIED_AT_COMMIT=""
SOURCE_FAIL_IDS=""
SOURCE_FAIL_ROW_COUNT=0
ROUND_STARTED_AT_COMMIT=""
ROUND_STARTED_AFTER_SOURCE="true"
ROUND_ACTUAL_DIFF_PATHS=""
ROUND_ACTUAL_DIFF_PATHS_AVAILABLE="false"
ROUND_ACTUAL_DIFF_PATHS_CANONICAL=""
ROUND_WORKTREE_PATHS_CANONICAL=""
ROUND_IGNORED_WORKTREE_PATHS_CANONICAL=""
ROUND_INPUT_MODE="none"
ROUND_KNOWN_ISSUE_BACKLOG_PATH=""
METADATA_ONLY_ROUND="false"
ROUND_SUMMARY_MISSING="false"
ROUND_PLAN_MISSING="false"
ROUND_CHANGE_EVIDENCE_UNAVAILABLE="false"
ROUND_CHANGE_EVIDENCE_EMPTY="false"
ROUND_IGNORED_EVIDENCE_USED="false"
ROUND_SUMMARY_NONTERMINAL="false"
PLAN_COUNT=0
PLANS_VERIFIED_COUNT=0
ROUND_ALL_RECORDED_PATHS=""
ROUND_RECORDED_STRUCTURAL_PATHS=""

# scan state is global because per-summary helpers return through it
SCAN_HAS_CODE_CHANGES="false"
SCAN_FOUND_SUMMARY="false"
SCAN_STOP="false"
SCAN_ALL_PATHS=""
SCAN_STRUCTURAL_PATHS=""
SCAN_EFFECTIVE_FILES=""

QA_GATE_AWK_SUMMARY_STATUS='
  BEGIN { in_fm=0 }
  NR==1 && /^---[[:space:]]*$/ { in_fm=1; next }
  in_fm && /^---[[:space:]]*$/ { exit }
  in_fm && /^status:/ { sub(/^status:[[:space:]]*/, ""); print; exit }
'

QA_GATE_AWK_UNIQUE_COUNT='
  {
    if (!seen[$0]++) count++
  }
  END { print count + 0 }
'

round_state_value() {
  printf '%s\n' "${1:-}" | awk -F= -v key="${2:-}" '$0 ~ ("^" key "=") {print $2; exit}'
}

sorted_unique_lines() {
  sed '/^[[:space:]]*$/d' | (sort -u 2>/dev/null || sort -u)
}

check_prior_round_verification() {
  local expected_round=""
  local expected_verification=""
  local phase_verification=""
  gate_in_round_scope || return 0
  if [ -n "${GATE_ROUND:-}" ] && [ "$((10#${GATE_ROUND}))" -gt 1 ] 2>/dev/null; then
    expected_round=$(printf '%02d' "$((10#${GATE_ROUND} - 1))")
    expected_verification="$PHASE_DIR/remediation/qa/round-${expected_round}/R${expected_round}-VERIFICATION.md"
    if [ ! -r "$expected_verification" ]; then
      printf -v ROUND_SOURCE_VERIFICATION_MISSING '%s' "true"
    fi
    return 0
  fi
  phase_verification=$(bash "$SCRIPT_DIR/resolve-verification-path.sh" phase "$PHASE_DIR" 2>/dev/null || true)
  if [ -z "$phase_verification" ] || [ ! -r "$phase_verification" ]; then
    printf -v ROUND_SOURCE_VERIFICATION_MISSING '%s' "true"
  fi
}

settle_source_verification_missing() {
  if [ -z "$SOURCE_VERIFICATION_PATH" ] || [ ! -r "$SOURCE_VERIFICATION_PATH" ]; then
    printf -v ROUND_SOURCE_VERIFICATION_MISSING '%s' "true"
  fi
  if [ "${ROUND_INPUT_MODE:-none}" = "known-issues" ] && [ -z "$SOURCE_VERIFICATION_PATH" ]; then
    printf -v ROUND_SOURCE_VERIFICATION_MISSING '%s' "false"
  fi
  if [ "${GATE_STAGE:-none}" = "done" ] && [ "${ROUND_INPUT_MODE:-none}" = "none" ] && [ -z "$SOURCE_VERIFICATION_PATH" ]; then
    printf -v ROUND_SOURCE_VERIFICATION_MISSING '%s' "false"
  fi
}

load_source_verification_facts() {
  local verified_commit=""
  local fail_ids=""
  local fail_rows=""
  if [ -n "$SOURCE_VERIFICATION_PATH" ] && [ -r "$SOURCE_VERIFICATION_PATH" ]; then
    verified_commit=$(extract_verified_at_commit "$SOURCE_VERIFICATION_PATH")
    fail_ids=$(extract_fail_ids_from_verification "$SOURCE_VERIFICATION_PATH")
    fail_rows=$(count_fail_rows_in_verification "$SOURCE_VERIFICATION_PATH")
    printf -v SOURCE_VERIFIED_AT_COMMIT '%s' "$verified_commit"
    printf -v SOURCE_FAIL_IDS '%s' "$fail_ids"
    printf -v SOURCE_FAIL_ROW_COUNT '%s' "$fail_rows"
  fi
  if [ -n "$SOURCE_VERIFIED_AT_COMMIT" ] && [ -n "$ROUND_STARTED_AT_COMMIT" ] && ! commit_is_ancestor_or_same "$GIT_ROOT" "$SOURCE_VERIFIED_AT_COMMIT" "$ROUND_STARTED_AT_COMMIT"; then
    printf -v ROUND_STARTED_AFTER_SOURCE '%s' "false"
  fi
}

load_round_diff_paths() {
  local diff_paths=""
  local canonical_diff=""
  local canonical_worktree=""
  local canonical_ignored=""
  [ -n "$GIT_ROOT" ] && [ -n "$ROUND_STARTED_AT_COMMIT" ] || return 0
  git -C "$GIT_ROOT" cat-file -e "${ROUND_STARTED_AT_COMMIT}^{commit}" 2>/dev/null || return 0
  printf -v ROUND_ACTUAL_DIFF_PATHS_AVAILABLE '%s' "true"
  diff_paths=$(git_diff_paths_since_commit "$GIT_ROOT" "$ROUND_STARTED_AT_COMMIT" | sorted_unique_lines)
  canonical_diff=$(printf '%s\n' "$diff_paths" | canonicalize_recorded_paths "$PHASE_DIR")
  canonical_worktree=$(git_current_worktree_paths "$GIT_ROOT" | sorted_unique_lines | canonicalize_recorded_paths "$PHASE_DIR")
  canonical_ignored=$(git_ignored_metadata_worktree_paths "$GIT_ROOT" | sorted_unique_lines | canonicalize_recorded_paths "$PHASE_DIR")
  printf -v ROUND_ACTUAL_DIFF_PATHS '%s' "$diff_paths"
  printf -v ROUND_ACTUAL_DIFF_PATHS_CANONICAL '%s' "$canonical_diff"
  printf -v ROUND_WORKTREE_PATHS_CANONICAL '%s' "$canonical_worktree"
  printf -v ROUND_IGNORED_WORKTREE_PATHS_CANONICAL '%s' "$canonical_ignored"
}

load_round_source_state() {
  local remediation_state=""
  local state_path=""
  local state_commit=""
  local state_mode=""
  local state_backlog=""
  gate_in_round_scope || return 0
  remediation_state=$(bash "$SCRIPT_DIR/qa-remediation-state.sh" get "$PHASE_DIR" 2>/dev/null || true)
  state_path=$(round_state_value "$remediation_state" source_verification_path)
  state_commit=$(round_state_value "$remediation_state" round_started_at_commit)
  state_mode=$(round_state_value "$remediation_state" input_mode)
  state_backlog=$(round_state_value "$remediation_state" known_issues_path)
  printf -v SOURCE_VERIFICATION_PATH '%s' "$state_path"
  printf -v ROUND_STARTED_AT_COMMIT '%s' "$state_commit"
  printf -v ROUND_INPUT_MODE '%s' "$state_mode"
  printf -v ROUND_KNOWN_ISSUE_BACKLOG_PATH '%s' "$state_backlog"
  settle_source_verification_missing
  load_source_verification_facts
  load_round_diff_paths
}

mark_evidence_unavailable() {
  printf -v ROUND_CHANGE_EVIDENCE_UNAVAILABLE '%s' "true"
  printf -v SCAN_STOP '%s' "true"
}

note_summary_status() {
  local summary_status=""
  summary_status=$(awk "$QA_GATE_AWK_SUMMARY_STATUS" "${1:-}" 2>/dev/null)
  case "${summary_status:-}" in
    complete|completed|partial|failed) ;;
    *) printf -v ROUND_SUMMARY_NONTERMINAL '%s' "true" ;;
  esac
}

note_ignored_evidence() {
  local recorded_files="${1:-}"
  local without_ignored=""
  if [ "$ROUND_IGNORED_EVIDENCE_USED" = "true" ] || [ -z "$ROUND_IGNORED_WORKTREE_PATHS_CANONICAL" ]; then
    return 0
  fi
  without_ignored=$(resolve_corroborated_recorded_paths "$PHASE_DIR" "$recorded_files" "$ROUND_ACTUAL_DIFF_PATHS_CANONICAL" "$ROUND_WORKTREE_PATHS_CANONICAL" "")
  if ! recorded_paths_are_fully_corroborated "$recorded_files" "$without_ignored"; then
    printf -v ROUND_IGNORED_EVIDENCE_USED '%s' "true"
  fi
}

corroborate_recorded_files() {
  local recorded_files="${1:-}"
  local effective_files=""
  if [ "$ROUND_STARTED_AFTER_SOURCE" != "true" ] || [ "$ROUND_ACTUAL_DIFF_PATHS_AVAILABLE" != "true" ]; then
    mark_evidence_unavailable
    return 0
  fi
  effective_files=$(resolve_corroborated_recorded_paths "$PHASE_DIR" "$recorded_files" "$ROUND_ACTUAL_DIFF_PATHS_CANONICAL" "$ROUND_WORKTREE_PATHS_CANONICAL" "$ROUND_IGNORED_WORKTREE_PATHS_CANONICAL")
  printf -v SCAN_EFFECTIVE_FILES '%s' "$effective_files"
  if [ -z "$effective_files" ] || ! recorded_paths_are_fully_corroborated "$recorded_files" "$effective_files"; then
    mark_evidence_unavailable
    return 0
  fi
  note_ignored_evidence "$recorded_files"
}

scan_recorded_files() {
  local recorded_files="${1:-}"
  local joined_paths=""
  joined_paths=$(printf '%s\n%s\n' "${SCAN_STRUCTURAL_PATHS:-}" "$recorded_files")
  printf -v SCAN_STRUCTURAL_PATHS '%s' "$joined_paths"
  if [ -z "$recorded_files" ]; then
    mark_evidence_unavailable
    return 0
  fi
  if [ -n "$GIT_ROOT" ]; then
    corroborate_recorded_files "$recorded_files"
    [ "$SCAN_STOP" != "true" ] || return 0
  else
    printf -v SCAN_EFFECTIVE_FILES '%s' "$recorded_files"
  fi
  joined_paths=$(printf '%s\n%s\n' "${SCAN_ALL_PATHS:-}" "$SCAN_EFFECTIVE_FILES")
  printf -v SCAN_ALL_PATHS '%s' "$joined_paths"
  if paths_include_non_metadata "$PHASE_DIR" <<< "$SCAN_EFFECTIVE_FILES"; then
    printf -v SCAN_HAS_CODE_CHANGES '%s' "true"
  fi
}

scan_recorded_commits() {
  local commit_hashes="${1:-}"
  local commit_files=""
  local joined_paths=""
  if ! commit_hashes_resolve_cleanly "$GIT_ROOT" "$commit_hashes" \
    || [ "$ROUND_STARTED_AFTER_SOURCE" != "true" ] \
    || ! commit_hashes_are_round_local "$GIT_ROOT" "$ROUND_STARTED_AT_COMMIT" "$commit_hashes"; then
    mark_evidence_unavailable
    return 0
  fi
  commit_files="$(commit_hashes_to_changed_files "$GIT_ROOT" "$commit_hashes" | sorted_unique_lines)"
  if [ -z "$commit_files" ]; then
    mark_evidence_unavailable
    return 0
  fi
  joined_paths=$(printf '%s\n%s\n' "${SCAN_ALL_PATHS:-}" "$commit_files")
  printf -v SCAN_ALL_PATHS '%s' "$joined_paths"
  if paths_include_non_metadata "$PHASE_DIR" <<< "$commit_files"; then
    printf -v SCAN_HAS_CODE_CHANGES '%s' "true"
  fi
}

scan_round_summary() {
  local summary_file="${1:-}"
  local recorded_files=""
  local canonical_files=""
  local commit_hashes=""
  local commit_total=""
  printf -v SCAN_FOUND_SUMMARY '%s' "true"
  note_summary_status "$summary_file"
  recorded_files=$(extract_frontmatter_array_items "$summary_file" files_modified)
  canonical_files=$(printf '%s\n' "$recorded_files" | canonicalize_recorded_paths "$PHASE_DIR")
  commit_hashes=$(extract_frontmatter_array_items "$summary_file" commit_hashes)
  commit_total=$(printf '%s\n' "$commit_hashes" | awk 'NF { count++ } END { print count + 0 }')
  commit_total="${commit_total:-0}"
  if [ -z "$recorded_files" ] && [ "$commit_total" -eq 0 ] 2>/dev/null; then
    printf -v ROUND_CHANGE_EVIDENCE_EMPTY '%s' "true"
  fi
  if [ -n "$recorded_files" ]; then
    scan_recorded_files "$canonical_files"
  elif [ "$commit_total" -gt 0 ] 2>/dev/null; then
    scan_recorded_commits "$commit_hashes"
  fi
  if [ "$SCAN_HAS_CODE_CHANGES" = "true" ]; then
    printf -v SCAN_STOP '%s' "true"
  fi
}

scan_round_summaries() {
  local summary_file=""
  gate_in_round_scope || return 0
  while IFS= read -r summary_file; do
    [ -f "$summary_file" ] || continue
    scan_round_summary "$summary_file"
    if [ "$SCAN_STOP" = "true" ]; then
      break
    fi
  done < <(list_scope_documents "$SUMMARY_SCOPE_DIR" summary)
  if [ "$SCAN_FOUND_SUMMARY" = "false" ]; then
    printf -v ROUND_SUMMARY_MISSING '%s' "true"
  elif [ "$SCAN_HAS_CODE_CHANGES" = "false" ]; then
    printf -v METADATA_ONLY_ROUND '%s' "true"
  fi
}

count_scope_plans() {
  local plan_file=""
  local plan_total=0
  local verified_total=""
  while IFS= read -r plan_file; do
    [ -f "$plan_file" ] || continue
    plan_total=$((plan_total + 1))
  done < <(list_scope_documents "$PLAN_SCOPE_DIR" plan)
  printf -v PLAN_COUNT '%s' "$plan_total"
  verified_total=$(extract_frontmatter_array_items "$VERIF_PATH" plans_verified | awk "$QA_GATE_AWK_UNIQUE_COUNT" 2>/dev/null)
  printf -v PLANS_VERIFIED_COUNT '%s' "${verified_total:-0}"
  if [ "$IN_REMEDIATION" = "true" ] && [ "$PLAN_SCOPE_DIR" != "$PHASE_DIR" ] && [ "$PLAN_COUNT" -eq 0 ] 2>/dev/null; then
    printf -v ROUND_PLAN_MISSING '%s' "true"
  fi
}

collect_recorded_paths() {
  local all_paths=""
  local structural_paths=""
  all_paths=$(printf '%s\n' "${SCAN_ALL_PATHS:-}" | sorted_unique_lines)
  structural_paths=$(printf '%s\n' "${SCAN_STRUCTURAL_PATHS:-}" | sorted_unique_lines)
  printf -v ROUND_ALL_RECORDED_PATHS '%s' "$all_paths"
  printf -v ROUND_RECORDED_STRUCTURAL_PATHS '%s' "$structural_paths"
}

gather_round_evidence() {
  check_prior_round_verification
  load_round_source_state
  scan_round_summaries
  count_scope_plans
  collect_recorded_paths
}
