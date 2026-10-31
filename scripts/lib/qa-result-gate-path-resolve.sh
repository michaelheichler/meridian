follow_symlink_chain() {
  local path="${1:-}"
  local max_hops=40
  local hop=0
  local path_dir=""
  local path_base=""
  local target=""

  while [ -L "$path" ]; do
    if [ "$hop" -ge "$max_hops" ]; then
      return 1
    fi
    path_dir="${path%/*}"
    path_base="${path##*/}"
    [ -n "$path_dir" ] || path_dir="."
    path_dir="$(CDPATH='' cd -- "$path_dir" 2>/dev/null && pwd -P || return 1)"
    target="$(readlink "$path_dir/$path_base" 2>/dev/null || true)"
    [ -n "$target" ] || return 1
    case "$target" in
      /*)
        path="$target"
        ;;
      *)
        path="$path_dir/$target"
        ;;
    esac
    hop=$((hop + 1))
  done
  printf '%s' "$path"
}

resolve_existing_path_target() {
  local path="${1:-}"
  local path_dir=""
  local path_base=""

  [ -n "$path" ] || return 1
  [ -e "$path" ] || return 1
  path=$(follow_symlink_chain "$path") || return 1

  path_dir="${path%/*}"
  path_base="${path##*/}"
  [ -n "$path_dir" ] || path_dir="."
  path_dir="$(CDPATH='' cd -- "$path_dir" 2>/dev/null && pwd -P || return 1)"
  [ -e "$path_dir/$path_base" ] || return 1
  printf '%s' "$path_dir/$path_base"
}

qa_round_candidate_path() {
  local path="${1:-}"
  local phase_dir_abs="${2:-}"
  local repo_root_abs="${3:-}"
  local phase_dir_rel="${4:-}"
  local phase_parent_abs="${phase_dir_abs%/*}"
  local phase_basename="${phase_dir_abs##*/}"

  if [[ "$path" == /* ]]; then
    printf '%s' "$path"
  elif [ -n "$repo_root_abs" ] && [ -n "$phase_dir_rel" ] && [[ "$path" == "$phase_dir_rel/"* ]]; then
    printf '%s' "$repo_root_abs/$path"
  elif [[ "$path" == remediation/qa/* ]]; then
    printf '%s' "$phase_dir_abs/$path"
  elif [[ "$path" == "$phase_basename/"* ]]; then
    printf '%s' "$phase_parent_abs/$path"
  else
    return 1
  fi
}

qa_round_existing_artifact() {
  local candidate="${1:-}"
  local phase_dir_abs="${2:-}"
  local candidate_rel=""

  candidate="$(resolve_existing_path_target "$candidate" 2>/dev/null || true)"
  [ -n "$candidate" ] || return 1
  [ -f "$candidate" ] || return 1
  [[ "$candidate" == "$phase_dir_abs/"* ]] || return 1

  candidate_rel="${candidate#"$phase_dir_abs"/}"
  if [[ "$candidate_rel" =~ ^remediation/qa/round-([0-9]+)/R([0-9]+)-(PLAN|SUMMARY)\.md$ ]]; then
    [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ] || return 1
    printf '%s' "$candidate"
    return 0
  fi

  return 1
}

resolve_qa_remediation_round_artifact_path() {
  local path="${1:-}"
  local phase_dir="${2:-}"
  local phase_dir_abs=""
  local repo_root_abs=""
  local phase_dir_rel=""
  local candidate=""

  path=$(normalize_recorded_path "$path")
  [ -n "$path" ] || return 1
  [ -n "$phase_dir" ] || return 1

  case "$path" in
    ../*|*/../*|*/./*) return 1 ;;
  esac

  phase_dir_abs="$(CDPATH='' cd -- "$phase_dir" 2>/dev/null && pwd -P || return 1)"
  repo_root_abs="$(git -C "$phase_dir" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$repo_root_abs" ] && [[ "$phase_dir_abs" == "$repo_root_abs/"* ]]; then
    phase_dir_rel="${phase_dir_abs#"$repo_root_abs"/}"
  fi

  candidate=$(qa_round_candidate_path "$path" "$phase_dir_abs" "$repo_root_abs" "$phase_dir_rel") || return 1
  qa_round_existing_artifact "$candidate" "$phase_dir_abs"
}

original_plan_candidate_path() {
  local path="${1:-}"
  local phase_dir_abs="${2:-}"
  local repo_root_abs="${3:-}"
  local phase_dir_rel="${4:-}"

  if [[ "$path" == /* ]]; then
    printf '%s' "$path"
  elif [ -n "$phase_dir_rel" ] && [[ "$path" == "$phase_dir_rel/"* ]]; then
    printf '%s' "$repo_root_abs/$path"
  elif [[ "$path" != */* ]] && { [[ "$path" == *-PLAN.md ]] || [[ "$path" == PLAN.md ]]; }; then
    printf '%s' "$phase_dir_abs/$path"
  else
    return 1
  fi
}

original_plan_base_is_valid() {
  local candidate_base="${1:-}"
  if [[ "$candidate_base" =~ ^R[0-9]+(-.*)?-PLAN\.md$ ]]; then
    return 1
  fi
  case "$candidate_base" in
    *-PLAN.md|PLAN.md) return 0 ;;
    *) return 1 ;;
  esac
}

original_plan_existing_file() {
  local candidate="${1:-}"
  local phase_dir_abs="${2:-}"
  local candidate_dir=""
  local candidate_base=""

  candidate_dir="${candidate%/*}"
  candidate_base="${candidate##*/}"
  if [ -d "$candidate_dir" ]; then
    candidate_dir="$(CDPATH='' cd -- "$candidate_dir" 2>/dev/null && pwd -P || printf '%s' "$candidate_dir")"
    candidate="$candidate_dir/$candidate_base"
  fi

  candidate="$(resolve_existing_path_target "$candidate" 2>/dev/null || true)"
  [ -n "$candidate" ] || return 1
  candidate_dir="${candidate%/*}"
  candidate_base="${candidate##*/}"

  [ "$candidate_dir" = "$phase_dir_abs" ] || return 1
  original_plan_base_is_valid "$candidate_base" || return 1
  [ -f "$candidate" ] || return 1
  printf '%s' "$candidate"
}

resolve_original_plan_artifact_path() {
  local path="${1:-}"
  local phase_dir="${2:-}"
  local phase_dir_abs=""
  local repo_root_abs=""
  local phase_dir_rel=""
  local candidate=""

  path=$(normalize_recorded_path "$path")
  [ -n "$path" ] || return 1
  [ -n "$phase_dir" ] || return 1

  phase_dir_abs="$(CDPATH='' cd -- "$phase_dir" 2>/dev/null && pwd -P || printf '%s' "$phase_dir")"
  repo_root_abs="$(git -C "$phase_dir" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$repo_root_abs" ] && [[ "$phase_dir_abs" == "$repo_root_abs/"* ]]; then
    phase_dir_rel="${phase_dir_abs#"$repo_root_abs"/}"
  fi

  case "$path" in
    ../*|*/../*|*/./*) return 1 ;;
    */remediation/*) return 1 ;;
  esac

  candidate=$(original_plan_candidate_path "$path" "$phase_dir_abs" "$repo_root_abs" "$phase_dir_rel") || return 1
  original_plan_existing_file "$candidate" "$phase_dir_abs"
}

path_is_original_plan_artifact() {
  local path="${1:-}"
  local phase_dir="${2:-}"
  resolve_original_plan_artifact_path "$path" "$phase_dir" >/dev/null 2>&1
}

physicalize_recorded_path() {
  local path="${1:-}"
  local phase_dir="${2:-}"
  local path_dir=""
  local path_base=""

  if [[ "$path" == /* ]]; then
    path_dir="${path%/*}"
    path_base="${path##*/}"
    if [ -d "$path_dir" ]; then
      path_dir="$(CDPATH='' cd -- "$path_dir" 2>/dev/null && pwd -P || printf '%s' "$path_dir")"
      path="$path_dir/$path_base"
    fi
  elif [[ "$path" == */* ]] && [ -n "$phase_dir" ]; then
    path_dir="${path%/*}"
    path_base="${path##*/}"
    if [ -d "$phase_dir/$path_dir" ]; then
      path_dir="$(CDPATH='' cd -- "$phase_dir/$path_dir" 2>/dev/null && pwd -P || printf '%s' "$phase_dir/$path_dir")"
      path="$path_dir/$path_base"
    fi
  fi
  printf '%s' "$path"
}

relativize_canonical_path() {
  local path="${1:-}"
  local phase_dir="${2:-}"
  local phase_dir_abs="${3:-}"
  local repo_root_abs="${4:-}"
  local phase_dir_rel="${5:-}"

  if [ -n "$repo_root_abs" ] && [[ "$path" == "$repo_root_abs/"* ]]; then
    printf '%s' "${path#"$repo_root_abs"/}"
    return 0
  fi

  if [ -n "$phase_dir_abs" ] && [[ "$path" == "$phase_dir_abs/"* ]]; then
    printf '%s' "$path"
    return 0
  fi

  if [ -n "$phase_dir_rel" ] && [[ "$path" == "$phase_dir_rel/"* ]]; then
    printf '%s' "$path"
    return 0
  fi

  if [ -f "$phase_dir/$path" ]; then
    printf '%s' "${phase_dir_rel:-$phase_dir_abs}/$path"
    return 0
  fi

  printf '%s' "$path"
}

canonicalize_phase_path() {
  local path="${1:-}"
  local phase_dir="${2:-}"
  local phase_dir_abs=""
  local repo_root_abs=""
  local phase_dir_rel=""

  path=$(normalize_recorded_path "$path")
  [ -n "$path" ] || return 1
  path=$(physicalize_recorded_path "$path" "$phase_dir")

  phase_dir_abs="$(CDPATH='' cd -- "$phase_dir" 2>/dev/null && pwd -P || printf '%s' "$phase_dir")"
  repo_root_abs="$(git -C "$phase_dir" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$repo_root_abs" ] && [[ "$phase_dir_abs" == "$repo_root_abs/"* ]]; then
    phase_dir_rel="${phase_dir_abs#"$repo_root_abs"/}"
  fi

  relativize_canonical_path "$path" "$phase_dir" "$phase_dir_abs" "$repo_root_abs" "$phase_dir_rel"
}

canonicalize_recorded_paths() {
  local phase_dir="${1:-}"
  local path=""
  while IFS= read -r path; do
    path=$(normalize_recorded_path "$path")
    [ -n "$path" ] || continue
    if [ -n "$phase_dir" ]; then
      path=$(canonicalize_phase_path "$path" "$phase_dir")
    fi
    [ -n "$path" ] || continue
    printf '%s\n' "$path"
  done | sed '/^[[:space:]]*$/d' | (sort -u 2>/dev/null || sort -u)
}
