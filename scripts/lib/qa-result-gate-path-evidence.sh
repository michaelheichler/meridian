QA_RESULT_GATE_PATH_EVIDENCE_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

extract_frontmatter_array_items() {
  local file_path="${1:-}"
  local key_name="${2:-}"
  [ -f "$file_path" ] || return 0
  [ -n "$key_name" ] || return 0
  awk -v key="$key_name" -f "$QA_RESULT_GATE_PATH_EVIDENCE_DIR/extract-frontmatter-array-items.awk" "$file_path" 2>/dev/null
}

normalize_recorded_path() {
  local path="${1:-}"
  local leading_char=""
  local trailing_char=""
  local squote="'"
  local dquote='"'
  local bquote='`'

  path=$(printf '%s' "$path" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/,$//')
  if [ -n "$path" ]; then
    leading_char=${path%"${path#?}"}
    case "$leading_char" in
      "$squote"|"$dquote"|"$bquote") path="${path#?}" ;;
    esac
  fi
  if [ -n "$path" ]; then
    trailing_char=${path#"${path%?}"}
    case "$trailing_char" in
      "$squote"|"$dquote"|"$bquote") path="${path%?}" ;;
    esac
  fi
  while [[ "$path" == ./* ]]; do
    path="${path#./}"
  done
  printf '%s' "$path"
}

path_is_recorded_non_code_artifact() {
  local path="${1:-}"
  local base="${path##*/}"
  case "$base" in
    SOURCE-UAT.md|PLAN.md|SUMMARY.md|VERIFICATION.md|RESEARCH.md|CONTEXT.md|UAT.md|STATE.md|ROADMAP.md|PROJECT.md|REQUIREMENTS.md|RESUME.md|SHIPPED.md|*-PLAN.md|*-SUMMARY.md|*-VERIFICATION.md|*-RESEARCH.md|*-CONTEXT.md|*-UAT.md)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

path_is_implementation_asset_artifact() {
  local path="${1:-}"
  local base="${path##*/}"
  case "$path" in
    docs/*|*/docs/*)
      return 1
      ;;
  esac
  case "$path" in
    assets/*|*/assets/*|asset/*|*/asset/*|resources/*|*/resources/*|resource/*|*/resource/*|public/*|*/public/*|static/*|*/static/*|*/Assets.xcassets/*|Assets.xcassets/*)
      case "$base" in
        *.png|*.jpg|*.jpeg|*.gif|*.svg|*.webp|*.txt|Contents.json)
          return 0
          ;;
      esac
      ;;
  esac
  return 1
}

path_is_documentation_artifact() {
  local path="${1:-}"
  local base="${path##*/}"
  case "$path" in
    docs/*|*/docs/*)
      return 0
      ;;
  esac
  if path_is_implementation_asset_artifact "$path"; then
    return 1
  fi
  case "$base" in
    AGENTS.md|README|README.*|CHANGELOG|CHANGELOG.*|CONTRIBUTING|CONTRIBUTING.*|LICENSE|LICENSE.*|*.md|*.mdx|*.txt|*.rst|*.adoc|*.asciidoc|*.pdf|*.png|*.jpg|*.jpeg|*.gif|*.svg|*.webp)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

path_is_repo_hygiene_artifact() {
  local path="${1:-}"
  local base="${path##*/}"
  case "$base" in
    .gitignore|.gitattributes|.editorconfig|.prettierignore|.eslintignore|.npmignore|.dockerignore|.stylelintignore|.markdownlint.json|.markdownlint.yaml|.markdownlint.yml|VERSION)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

path_is_metadata_artifact() {
  local path="${1:-}"
  case "$path" in
    .lbwc-planning/*|.claude/*)
      return 0
      ;;
  esac
  if path_is_recorded_non_code_artifact "$path"; then
    return 0
  fi
  path_is_documentation_artifact "$path"
}

path_is_code_fix_support_artifact() {
  local path="${1:-}"
  case "$path" in
    .lbwc-planning/*|.claude/*|.claude-plugin/*)
      return 0
      ;;
  esac
  if path_is_recorded_non_code_artifact "$path"; then
    return 0
  fi
  if path_is_documentation_artifact "$path"; then
    return 0
  fi
  path_is_repo_hygiene_artifact "$path"
}

path_is_process_exception_evidence_artifact() {
  local phase_dir="${1:-}"
  local path="${2:-}"
  if resolve_qa_remediation_round_artifact_path "$path" "$phase_dir" >/dev/null 2>&1; then
    return 0
  fi
  path_is_original_plan_artifact "$path" "$phase_dir"
}

path_is_qa_remediation_round_artifact() {
  local path="${1:-}"
  if [[ "$path" =~ (^|/)remediation/qa/round-([0-9]+)/R([0-9]+)-(PLAN|SUMMARY)\.md$ ]]; then
    [ "${BASH_REMATCH[2]}" = "${BASH_REMATCH[3]}" ]
    return
  fi
  return 1
}

intersect_canonical_paths() {
  local candidate_paths="${1:-}"
  local reference_paths="${2:-}"
  local path=""
  [ -n "$candidate_paths" ] || return 0
  [ -n "$reference_paths" ] || return 0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if printf '%s\n' "$reference_paths" | grep -Fx -- "$path" >/dev/null 2>&1; then
      printf '%s\n' "$path"
    fi
  done <<< "$candidate_paths" | (sort -u 2>/dev/null || sort -u)
}

paths_include_original_plan_artifact() {
  local phase_dir="${1:-}"
  while IFS= read -r path; do
    path=$(normalize_recorded_path "$path")
    [ -n "$path" ] || continue
    if path_is_original_plan_artifact "$path" "$phase_dir"; then
      return 0
    fi
  done
  return 1
}

paths_include_non_metadata() {
  local phase_dir="${1:-}"
  while IFS= read -r path; do
    path=$(normalize_recorded_path "$path")
    [ -n "$path" ] || continue
    if [ -n "$phase_dir" ]; then
      path=$(canonicalize_phase_path "$path" "$phase_dir")
    fi
    if ! path_is_metadata_artifact "$path"; then
      return 0
    fi
  done
  return 1
}

paths_include_code_fix_evidence() {
  local phase_dir="${1:-}"
  while IFS= read -r path; do
    path=$(normalize_recorded_path "$path")
    [ -n "$path" ] || continue
    if [ -n "$phase_dir" ]; then
      path=$(canonicalize_phase_path "$path" "$phase_dir")
    fi
    if ! path_is_code_fix_support_artifact "$path"; then
      return 0
    fi
  done
  return 1
}

paths_include_documentation_fix_evidence() {
  local phase_dir="${1:-}"
  local required_paths="${2:-}"
  local changed_paths=""
  local required_path=""
  local changed_path=""
  local canonical_required=""
  local canonical_changed=""
  local found=false

  changed_paths=$(cat)
  while IFS= read -r required_path; do
    required_path=$(normalize_recorded_path "$required_path")
    [ -n "$required_path" ] || return 1
    canonical_required=$(canonicalize_phase_path "$required_path" "$phase_dir")
    path_is_documentation_artifact "$canonical_required" || return 1
    found=false
    while IFS= read -r changed_path; do
      changed_path=$(normalize_recorded_path "$changed_path")
      [ -n "$changed_path" ] || continue
      canonical_changed=$(canonicalize_phase_path "$changed_path" "$phase_dir")
      if [ "$canonical_required" = "$canonical_changed" ]; then
        found=true
        break
      fi
    done <<< "$changed_paths"
    [ "$found" = true ] || return 1
  done <<< "$required_paths"
  [ -n "$required_paths" ]
}

paths_include_process_exception_evidence() {
  local phase_dir="${1:-}"
  while IFS= read -r path; do
    path=$(normalize_recorded_path "$path")
    [ -n "$path" ] || continue
    if path_is_process_exception_evidence_artifact "$phase_dir" "$path"; then
      return 0
    fi
  done
  return 1
}

paths_are_process_exception_evidence_artifacts() {
  local phase_dir="${1:-}"
  local saw_path=false
  while IFS= read -r path; do
    path=$(normalize_recorded_path "$path")
    [ -n "$path" ] || continue
    saw_path=true
    if ! path_is_process_exception_evidence_artifact "$phase_dir" "$path"; then
      return 1
    fi
  done
  [ "$saw_path" = true ]
}

path_is_allowed_worktree_evidence_artifact() {
  local phase_dir="${1:-}"
  local path="${2:-}"
  path=$(normalize_recorded_path "$path")
  [ -n "$path" ] || return 1
  if resolve_qa_remediation_round_artifact_path "$path" "$phase_dir" >/dev/null 2>&1; then
    return 0
  fi
  path_is_original_plan_artifact "$path" "$phase_dir"
}

resolve_corroborated_recorded_paths() {
  local phase_dir="${1:-}"
  local recorded_paths="${2:-}"
  local committed_paths="${3:-}"
  local worktree_paths="${4:-}"
  local ignored_worktree_paths="${5:-}"
  local path=""

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if printf '%s\n' "$committed_paths" | grep -Fx -- "$path" >/dev/null 2>&1; then
      printf '%s\n' "$path"
      continue
    fi
    if path_is_allowed_worktree_evidence_artifact "$phase_dir" "$path" \
      && printf '%s\n' "$worktree_paths" | grep -Fx -- "$path" >/dev/null 2>&1; then
      printf '%s\n' "$path"
      continue
    fi
    if [ -n "$ignored_worktree_paths" ] \
      && path_is_metadata_artifact "$path" \
      && path_is_allowed_worktree_evidence_artifact "$phase_dir" "$path" \
      && printf '%s\n' "$ignored_worktree_paths" | grep -Fx -- "$path" >/dev/null 2>&1; then
      printf '%s\n' "$path"
    fi
  done <<< "$recorded_paths" | (sort -u 2>/dev/null || sort -u)
}

recorded_paths_are_fully_corroborated() {
  local recorded_paths="${1:-}"
  local corroborated_paths="${2:-}"
  local recorded_count corroborated_count
  recorded_count=$(printf '%s\n' "$recorded_paths" | awk 'NF { count++ } END { print count + 0 }')
  corroborated_count=$(printf '%s\n' "$corroborated_paths" | awk 'NF { count++ } END { print count + 0 }')
  [ "$recorded_count" -eq "$corroborated_count" ] 2>/dev/null
}

