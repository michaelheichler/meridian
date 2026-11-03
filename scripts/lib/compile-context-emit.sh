emit_codebase_map_file_list() {
  local doc map_files=""
  for doc in ARCHITECTURE CONCERNS PATTERNS DEPENDENCIES STRUCTURE CONVENTIONS TESTING STACK; do
    if [ -f "$PLANNING_DIR/codebase/${doc}.md" ]; then
      map_files="${map_files} ${doc}"
    fi
  done
  printf '%s' "$map_files"
}

emit_codebase_priority_guidance() {
  local priority_files=("$@") pfile guidance_files="" comma_count

  for pfile in "${priority_files[@]}"; do
    if [ -f "$PLANNING_DIR/codebase/${pfile}.md" ]; then
      if [ -z "$guidance_files" ]; then
        guidance_files="${pfile}.md"
      else
        guidance_files="${guidance_files}, ${pfile}.md"
      fi
    fi
  done

  comma_count=$(echo "$guidance_files" | tr -cd ',' | wc -c | tr -d ' ')
  if [ "$comma_count" -eq 1 ]; then
    guidance_files=$(echo "$guidance_files" | sed 's/, / and /')
  elif [ "$comma_count" -gt 1 ]; then
    guidance_files=$(echo "$guidance_files" | sed 's/\(.*\), /\1, and /')
  fi
  if [ -n "$guidance_files" ]; then
    echo "Read ${guidance_files} first to bootstrap codebase understanding."
  fi
}

emit_codebase_mapping_hint() {
  local map_files doc

  [ -f "$PLANNING_DIR/codebase/META.md" ] || return 0
  map_files=$(emit_codebase_map_file_list)
  [ -n "$map_files" ] || return 0

  echo ""
  echo "### Codebase Map Available"
  echo "Codebase mapping exists in \`.meridian/codebase/\`. Key files:"
  for doc in $map_files; do
    echo "- \`${doc}.md\`"
  done
  echo ""

  emit_codebase_priority_guidance "$@"
  return 0
}

emit_caveman_directive() {
  local level="$CAVEMAN_STYLE" extra="${1:-}"

  if [ "$CAVEMAN_STYLE" = "none" ] || [ "$CAVEMAN_STYLE" = "false" ]; then
    return 0
  fi
  if [ "$level" = "auto" ]; then
    . "${SCRIPT_DIR}/lib/resolve-caveman-level.sh"
    resolve_caveman_level "auto" "$PLANNING_DIR"
    level="$RESOLVED_CAVEMAN_LEVEL"
  fi
  [ "$level" = "none" ] && return 0

  echo ""
  echo "### Caveman Language (${level})"
  echo "Respond in ${level} caveman language. Follow rules in \`references/caveman-language.md\`."
  if [ "$extra" = "commit" ] && [ "$CAVEMAN_COMMIT" = "true" ]; then
    echo "Write commit messages per \`references/caveman-commit.md\`."
  fi
  if [ "$extra" = "review" ] && [ "$CAVEMAN_REVIEW" = "true" ]; then
    echo "Format code review output per \`references/caveman-review.md\`."
  fi
  return 0
}

emit_delta_changed_files_section() {
  local delta_files="$1" f

  echo ""
  echo "### Changed Files (Delta)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    echo "- \`$f\`"
  done <<< "$delta_files"
  return 0
}

emit_delta_code_slice() {
  local f="$1" source_path="$2" slice_lines
  slice_lines=$(wc -l < "$source_path" 2>/dev/null | tr -d ' ' || echo "0")
  if [ "$slice_lines" -le 50 ]; then
    echo ""
    echo "#### \`$f\` (${slice_lines} lines)"
    echo '```'
    cat "$source_path" 2>/dev/null || true
    echo '```'
  else
    echo ""
    echo "#### \`$f\` (${slice_lines} lines, first 30 shown)"
    echo '```'
    head -30 "$source_path" 2>/dev/null || true
    echo '```'
  fi
}

emit_delta_code_slices_section() {
  local delta_files="$1" source_root="$2" f source_path

  echo ""
  echo "### Code Slices"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    meridian_is_safe_relative_path "$f" || continue
    source_path=$(meridian_resolve_repo_path "$source_root" "$f") || continue
    [ -f "$source_path" ] && emit_delta_code_slice "$f" "$source_path"
  done <<< "$delta_files"
  return 0
}

emit_active_decisions_section() {
  local decisions
  echo ""
  echo "### Active Decisions"
  if [ -f "$PLANNING_DIR/STATE.md" ]; then
    decisions=$(awk '
      { low = tolower($0) }
      low ~ /^##[[:space:]]+(key[[:space:]]+)?decisions[[:space:]]*$/ { found=1; next }
      found && /^##[[:space:]]/ { found=0 }
      found && low ~ /^###[[:space:]]+pending[[:space:]]+todos[[:space:]]*$/ { found=0; skip_skills=0; next }
      found && low ~ /^###[[:space:]]+skills[[:space:]]*$/ { skip_skills=1; next }
      skip_skills && /^###?#? / { skip_skills=0 }
      found && !skip_skills { print }
    ' "$PLANNING_DIR/STATE.md" 2>/dev/null) || true
    echo "${decisions:-None}"
  else
    echo "None"
  fi
  return 0
}

emit_requirements_section() {
  local heading="$1"
  echo ""
  echo "### ${heading}"
  if [ -n "$REQ_PATTERN" ] && [ -f "$PLANNING_DIR/REQUIREMENTS.md" ]; then
    grep -E "($REQ_PATTERN)" "$PLANNING_DIR/REQUIREMENTS.md" 2>/dev/null || echo "No matching requirements found"
  else
    echo "No matching requirements found"
  fi
  return 0
}

emit_conventions_section() {
  local heading="$1" conventions
  [ -f "$PLANNING_DIR/conventions.json" ] && command -v jq &>/dev/null || return 0
  conventions=$(jq -r '.conventions[] | "- [\(.tag)] \(.rule)"' "$PLANNING_DIR/conventions.json" 2>/dev/null) || true
  [ -n "$conventions" ] || return 0
  echo ""
  echo "### ${heading}"
  echo "$conventions"
}

emit_research_findings_section() {
  local research_file
  research_file=$(resolve_research_file "$PHASE_DIR" "$PLAN_PATH")
  [ -n "$research_file" ] && [ -f "$research_file" ] || return 1
  echo ""
  echo "### Research Findings"
  cat "$research_file"
}

emit_prior_context_sections() {
  if [ -n "$ROLLING_CONTEXT_SECTION" ]; then
    echo ""
    echo "### Prior Phase Context (Rolling Summary)"
    echo "$ROLLING_CONTEXT_SECTION"
    echo ""
  fi
  if [ -n "$MILESTONE_CONTEXT_SECTION" ]; then
    echo ""
    echo "### Milestone Scope Context"
    echo "$MILESTONE_CONTEXT_SECTION"
    echo ""
  fi
  return 0
}

emit_goal_and_success() {
  echo ""
  echo "### Goal"
  echo "$PHASE_GOAL"
  echo ""
  echo "### Success Criteria"
  echo "$PHASE_SUCCESS"
  return 0
}

emit_deviq_digest_section() {
  local digest
  [ -f "${SCRIPT_DIR}/lib/deviq-digest.sh" ] || return 0
  digest=$(bash "${SCRIPT_DIR}/lib/deviq-digest.sh" --phase "$PHASE" --root "${PLANNING_DIR}/deviq" 2>/dev/null) || return 0
  [ -n "$digest" ] || return 0
  echo ""
  echo "$digest"
  return 0
}

emit_delta_context_for_role() {
  local include_code_slices="$1" delta_files
  [ "$V3_DELTA_ENABLED" = "true" ] && [ -f "${SCRIPT_DIR}/delta-files.sh" ] || return 0
  delta_files=$(bash "${SCRIPT_DIR}/delta-files.sh" "$PHASE_DIR" "$PLAN_PATH" 2>/dev/null || true)
  [ -n "$delta_files" ] || return 0
  emit_delta_changed_files_section "$delta_files"
  if [ "$include_code_slices" = "true" ]; then
    emit_delta_code_slices_section "$delta_files" "$TARGET_ROOT"
  fi
  return 0
}
