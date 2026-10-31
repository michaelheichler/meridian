compile_context_lead() {
  local total_reqs matched_reqs others
  {
    echo "## Phase ${PHASE} Context (Compiled)"
    emit_prior_context_sections
    emit_goal_and_success
    emit_requirements_section "Requirements (${PHASE_REQS})"
    echo ""
    total_reqs=$(grep -c '^\- \[' "$PLANNING_DIR/REQUIREMENTS.md" 2>/dev/null) || total_reqs=0
    matched_reqs=0
    if [ "$PHASE_REQS" != "Not available" ] && [ -n "$PHASE_REQS" ]; then
      matched_reqs=$(echo "$PHASE_REQS" | tr ',' '\n' | wc -l | tr -d ' ')
    fi
    others=$((total_reqs - matched_reqs))
    if [ "$others" -gt 0 ]; then
      echo "(${others} other requirements exist for other phases -- not shown)"
    fi
    emit_active_decisions_section
    emit_deviq_digest_section
    if ! emit_research_findings_section; then
      emit_codebase_mapping_hint ARCHITECTURE CONCERNS STRUCTURE
    fi
    emit_caveman_directive commit
  } > "${PHASE_DIR}/.context-lead.md"
}

compile_context_dev() {
  {
    echo "## Phase ${PHASE} Context"
    emit_prior_context_sections
    echo ""
    echo "### Goal"
    echo "$PHASE_GOAL"
    emit_conventions_section "Conventions"
    emit_codebase_mapping_hint CONVENTIONS PATTERNS STRUCTURE DEPENDENCIES
    emit_delta_context_for_role true
    if [ "$V3_DELTA_ENABLED" = "true" ] && [ -n "$PLAN_PATH" ] && [ -f "$PLAN_PATH" ]; then
      echo ""
      echo "### Active Plan"
      cat "$PLAN_PATH"
    fi
    emit_research_findings_section || true
    emit_caveman_directive commit
  } > "${PHASE_DIR}/.context-dev.md"
}

compile_context_qa() {
  {
    echo "## Phase ${PHASE} Verification Context"
    emit_prior_context_sections
    emit_goal_and_success
    emit_requirements_section "Requirements to Verify"
    emit_conventions_section "Conventions to Check"
    emit_codebase_mapping_hint TESTING CONCERNS ARCHITECTURE
    emit_caveman_directive review
  } > "${PHASE_DIR}/.context-qa.md"
}

compile_context_scout() {
  {
    echo "## Phase ${PHASE} Research Context"
    emit_prior_context_sections
    emit_goal_and_success
    emit_requirements_section "Requirements (${PHASE_REQS})"
    emit_conventions_section "Conventions"
    emit_research_findings_section || true
    emit_delta_context_for_role false
    emit_caveman_directive
  } > "${PHASE_DIR}/.context-scout.md"
}

compile_context_debugger() {
  local activity
  {
    echo "## Phase ${PHASE} Debug Context"
    emit_prior_context_sections
    emit_goal_and_success
    echo ""
    echo "### Recent Activity"
    if [ -f "$PLANNING_DIR/STATE.md" ]; then
      activity=$(awk '
        /^## (Recent Activity|Activity Log|Activity)$/ { found=1; next }
        found && /^## / { exit }
        found { print }
      ' "$PLANNING_DIR/STATE.md" 2>/dev/null) || true
      echo "${activity:-None}"
    else
      echo "None"
    fi
    emit_conventions_section "Conventions"
    emit_codebase_mapping_hint ARCHITECTURE CONCERNS PATTERNS DEPENDENCIES
    emit_deviq_digest_section
    emit_research_findings_section || true
    emit_delta_context_for_role true
    emit_caveman_directive
  } > "${PHASE_DIR}/.context-debugger.md"
}

compile_context_architect() {
  {
    echo "## Phase ${PHASE} Architecture Context"
    emit_prior_context_sections
    emit_goal_and_success
    echo ""
    echo "### Full Requirements"
    if [ -f "$PLANNING_DIR/REQUIREMENTS.md" ]; then
      cat "$PLANNING_DIR/REQUIREMENTS.md"
    else
      echo "No requirements file found"
    fi
    emit_conventions_section "Conventions"
    emit_codebase_mapping_hint ARCHITECTURE STACK
    emit_deviq_digest_section
    emit_research_findings_section || true
    emit_caveman_directive
  } > "${PHASE_DIR}/.context-architect.md"
}
