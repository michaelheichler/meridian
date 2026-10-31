declare -g LEGACY_PHASE_DIR=""
declare -g SHAPE_ERROR=""
declare -g MISMATCH_ERROR=""

validate_legacy_shape() {
  local expected_suffix="$1" phase_prefix artifact_basename

  if [ "$ARTIFACT_TYPE" = "summary" ]; then
    emit_failure "summary artifacts must use the round-dir layout"
  fi

  LEGACY_PHASE_DIR=$(artifact_phase_dir "$ARTIFACT_PATH") \
    || emit_failure "artifact path must point at an active .lbwc-planning/phases/ artifact"

  if [ "$(dirname "$ARTIFACT_PATH")" != "$LEGACY_PHASE_DIR" ]; then
    emit_failure "legacy phase-root artifacts must be direct children of the active phase directory"
  fi

  phase_prefix=$(phase_prefix_for_dir "$LEGACY_PHASE_DIR")
  artifact_basename=$(basename "$ARTIFACT_PATH")
  case "$ARTIFACT_TYPE:$artifact_basename" in
    research:"${phase_prefix}-RESEARCH.md"|research:"${phase_prefix}"-*-RESEARCH.md|plan:"${phase_prefix}"-*-PLAN.md) ;;
    *) emit_failure "artifact path must match the expected legacy ${expected_suffix} filename shape" ;;
  esac
}

validate_legacy_selection() {
  local layout selected_path selected_canonical_path

  layout=$(layout_for_phase_dir "$LEGACY_PHASE_DIR")
  if [ "$layout" != "legacy" ]; then
    emit_failure "legacy phase-root artifacts require layout=legacy"
  fi

  selected_path=$(selected_legacy_artifact_path "$LEGACY_PHASE_DIR" "$ARTIFACT_TYPE") \
    || emit_failure "no current legacy ${ARTIFACT_TYPE} artifact is selected by state metadata"
  selected_canonical_path=$(canonicalize_selected_path "$selected_path") \
    || emit_failure "state-selected legacy ${ARTIFACT_TYPE} artifact path is not canonical"

  if [ "$ARTIFACT_PATH" != "$selected_canonical_path" ]; then
    emit_failure "legacy artifact is stale; expected canonical path $selected_canonical_path (state selected $selected_path)"
  fi
}

validate_legacy_phase_root_path() {
  validate_legacy_shape "$1"
  validate_legacy_selection
}

set_round_dir_errors() {
  local remediation_kind="$1" expected_suffix="$2"

  case "$remediation_kind" in
    qa)
      SHAPE_ERROR="artifact path must match the expected QA remediation plan filename shape"
      MISMATCH_ERROR="QA remediation plan round token must match round directory"
      ;;
    *)
      SHAPE_ERROR="artifact path must match the expected round-dir ${expected_suffix} filename shape"
      MISMATCH_ERROR="artifact round token must match round directory"
      ;;
  esac
}

validate_round_dir_token() {
  local round_dir_base round_raw expected_round

  round_dir_base=$(basename "$(dirname "$ARTIFACT_PATH")")
  round_raw="${round_dir_base#round-}"

  case "$round_dir_base" in
    round-[0-9]*) ;;
    *) emit_failure "$SHAPE_ERROR" ;;
  esac

  case "$round_raw" in
    ""|*[!0-9]*) emit_failure "$SHAPE_ERROR" ;;
  esac

  expected_round=$(printf "%02d" "$((10#$round_raw))")
  EXPECTED_ARTIFACT_ROUND="$expected_round"
  if [ "$round_raw" != "$expected_round" ]; then
    emit_failure "$SHAPE_ERROR"
  fi
}

validate_round_dir_artifact_path() {
  local remediation_kind="$1" expected_suffix="$2"
  local artifact_basename file_round

  set_round_dir_errors "$remediation_kind" "$expected_suffix"
  validate_round_dir_token

  artifact_basename=$(basename "$ARTIFACT_PATH")
  file_round=$(printf '%s\n' "$artifact_basename" | sed -n "s/^R\([0-9][0-9]*\)-${expected_suffix}\.md$/\1/p")
  if [ -z "$file_round" ]; then
    emit_failure "$SHAPE_ERROR"
  fi

  if [ "$file_round" != "$EXPECTED_ARTIFACT_ROUND" ]; then
    emit_failure "$MISMATCH_ERROR"
  fi
}

validate_host_path() {
  local canonical_artifact_path

  case "$ARTIFACT_PATH" in
    /*)
      ;;
    *)
      emit_failure "artifact path must be absolute"
      ;;
  esac

  canonical_artifact_path=$(canonicalize_artifact_path "$ARTIFACT_PATH") \
    || emit_failure "artifact path parent directory does not exist or cannot be canonicalized"

  case "$canonical_artifact_path" in
    */.claude/worktrees/agent-*/*)
      emit_failure "artifact path points at a Claude sidechain; use the host repository path"
      ;;
  esac

  if [ "$ARTIFACT_PATH" != "$canonical_artifact_path" ]; then
    emit_failure "artifact path must be the exact canonical host path"
  fi
}

validate_layout_path() {
  local expected_suffix="$1"

  case "$ARTIFACT_PATH" in
    */.lbwc-planning/phases/*/remediation/uat/round-[0-9]*/*)
      REMEDIATION_KIND="uat"
      validate_round_dir_artifact_path "uat" "$expected_suffix"
      ;;
    */.lbwc-planning/phases/*/remediation/qa/round-[0-9]*/*)
      REMEDIATION_KIND="qa"
      [ "$ARTIFACT_TYPE" = "plan" ] || emit_failure "QA remediation validation currently supports plan artifacts only"
      validate_round_dir_artifact_path "qa" "PLAN"
      ;;
    */.lbwc-planning/phases/*/remediation/qa/*)
      emit_failure "artifact path must match the expected QA remediation plan filename shape"
      ;;
    *) validate_legacy_phase_root_path "$expected_suffix" ;;
  esac
}

validate_common_path() {
  local expected_suffix="$1"

  validate_host_path
  validate_layout_path "$expected_suffix"

  if [ ! -f "$ARTIFACT_PATH" ]; then
    emit_failure "artifact file does not exist"
  fi

  if [ ! -s "$ARTIFACT_PATH" ]; then
    emit_failure "artifact file is empty"
  fi
}

validate_frontmatter() {
  local frontmatter="$1"

  if [ -z "$frontmatter" ]; then
    emit_failure "artifact missing YAML frontmatter"
  fi

  contains_regex "$frontmatter" '^phase:[[:space:]]*[0-9]+([[:space:]]*(#.*)?)?$' \
    || emit_failure "artifact frontmatter missing numeric phase"
  contains_regex "$frontmatter" '^round:[[:space:]]*[0-9]+([[:space:]]*(#.*)?)?$' \
    || emit_failure "artifact frontmatter missing numeric round"
  contains_regex "$frontmatter" '^title:[[:space:]]*.+' \
    || emit_failure "artifact frontmatter missing title"
}

validate_frontmatter_round_matches_path() {
  local frontmatter="$1" frontmatter_round frontmatter_round_norm

  [ -n "$EXPECTED_ARTIFACT_ROUND" ] || return 0
  frontmatter_round=$(printf '%s\n' "$frontmatter" | sed -n 's/^round:[[:space:]]*\([0-9][0-9]*\).*$/\1/p' | head -1)
  [ -n "$frontmatter_round" ] || emit_failure "artifact frontmatter missing numeric round"
  frontmatter_round_norm=$(printf "%02d" "$((10#$frontmatter_round))")
  if [ "$frontmatter_round_norm" != "$EXPECTED_ARTIFACT_ROUND" ]; then
    emit_failure "artifact frontmatter round must match round directory"
  fi
}

validate_research_content() {
  local frontmatter="$1"

  contains_regex "$frontmatter" '^type:[[:space:]]*remediation-research([[:space:]]*(#.*)?)?$' \
    || emit_failure "research artifact type must be remediation-research"
  grep -Eq '^## Findings[[:space:]]*$' "$ARTIFACT_PATH" \
    || emit_failure "research artifact missing Findings section"
  grep -Eq '^## Root Cause Assessment[[:space:]]*$' "$ARTIFACT_PATH" \
    || emit_failure "research artifact missing Root Cause Assessment section"
}

validate_plan_content() {
  local frontmatter="$1"

  contains_regex "$frontmatter" '^type:[[:space:]]*remediation([[:space:]]*(#.*)?)?$' \
    || emit_failure "plan artifact type must be remediation"
  contains_regex "$frontmatter" '^fail_classifications:[[:space:]]*.*$' \
    || emit_failure "plan artifact missing fail_classifications metadata"
  if [ "$REMEDIATION_KIND" = "qa" ]; then
    contains_regex "$frontmatter" '^known_issues_input:[[:space:]]*.*$' \
      || emit_failure "plan artifact missing known_issues_input metadata"
    contains_regex "$frontmatter" '^known_issue_resolutions:[[:space:]]*.*$' \
      || emit_failure "plan artifact missing known_issue_resolutions metadata"
  fi
  grep -Eq '^<tasks>[[:space:]]*$' "$ARTIFACT_PATH" \
    || emit_failure "plan artifact missing tasks block"
  grep -Eq '^<verification>[[:space:]]*$' "$ARTIFACT_PATH" \
    || emit_failure "plan artifact missing verification block"
}

validate_summary_content() {
  local frontmatter="$1"

  contains_regex "$frontmatter" '^type:[[:space:]]*remediation([[:space:]]*(#.*)?)?$' \
    || emit_failure "summary artifact type must be remediation"
  contains_regex "$frontmatter" '^status:[[:space:]]*(complete|partial|failed)([[:space:]]*(#.*)?)?$' \
    || emit_failure "summary artifact status must be complete, partial, or failed before state advance"
  contains_regex "$frontmatter" '^tasks_completed:[[:space:]]*[0-9]+([[:space:]]*(#.*)?)?$' \
    || emit_failure "summary artifact missing tasks_completed metadata"
  contains_regex "$frontmatter" '^tasks_total:[[:space:]]*[0-9]+([[:space:]]*(#.*)?)?$' \
    || emit_failure "summary artifact missing tasks_total metadata"
  contains_regex "$frontmatter" '^known_issue_outcomes:[[:space:]]*.*$' \
    || emit_failure "summary artifact missing known_issue_outcomes metadata"
}
