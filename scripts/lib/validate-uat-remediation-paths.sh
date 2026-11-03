physicalize_path() {
  local target="$1" parent base parent_physical

  parent=$(dirname "$target")
  base=$(basename "$target")
  [ -d "$parent" ] || return 1
  parent_physical=$(CDPATH='' cd -- "$parent" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s' "$parent_physical" "$base"
}

follow_symlink_once() {
  local current="$1" link_target

  link_target=$(readlink "$current" 2>/dev/null) || return 1
  case "$link_target" in
    /*)
      current="$link_target"
      ;;
    *)
      current="$(dirname "$current")/$link_target"
      ;;
  esac
  physicalize_path "$current"
}

canonicalize_artifact_path() {
  local raw_path="$1" current depth=0

  case "$raw_path" in
    /*)
      ;;
    *)
      return 1
      ;;
  esac

  current=$(physicalize_path "$raw_path") || return 1
  while [ -L "$current" ]; do
    if [ "$depth" -ge 20 ]; then
      return 1
    fi
    current=$(follow_symlink_once "$current") || return 1
    depth=$((depth + 1))
  done

  printf '%s\n' "$current"
}

canonicalize_selected_path() {
  local selected_path="$1" canonical_path

  canonical_path=$(canonicalize_artifact_path "$selected_path") || return 1
  printf '%s\n' "$canonical_path"
}

artifact_phase_dir() {
  local path="$1" root suffix phase_slug

  case "$path" in
    */.meridian/phases/*/*) ;;
    *) return 1 ;;
  esac

  root="${path%%/.meridian/phases/*}"
  suffix="${path#*/.meridian/phases/}"
  phase_slug="${suffix%%/*}"

  [ -n "$root" ] || return 1
  [ -n "$phase_slug" ] || return 1
  printf '%s/.meridian/phases/%s\n' "$root" "$phase_slug"
}

phase_prefix_for_dir() {
  local phase_dir="$1"

  uat_phase_num_for_dir "$phase_dir"
}

active_state_file() {
  local phase_dir="$1"

  if [ -f "$phase_dir/remediation/uat/.uat-remediation-stage" ]; then
    echo "$phase_dir/remediation/uat/.uat-remediation-stage"
  elif [ -f "$phase_dir/.uat-remediation-stage" ]; then
    echo "$phase_dir/.uat-remediation-stage"
  fi
}

state_value() {
  local state_file="$1" key="$2"

  grep "^${key}=" "$state_file" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]' || true
}

layout_for_phase_dir() {
  local phase_dir="$1" state_file layout=""

  state_file=$(active_state_file "$phase_dir")
  if [ -z "$state_file" ]; then
    echo "round-dir"
    return 0
  fi

  layout=$(state_value "$state_file" layout)
  if [ "$state_file" = "$phase_dir/.uat-remediation-stage" ]; then
    echo "${layout:-legacy}"
  else
    echo "${layout:-round-dir}"
  fi
}

round_for_phase_dir() {
  local phase_dir="$1" state_file round="" layout

  state_file=$(active_state_file "$phase_dir")
  if [ -n "$state_file" ]; then
    round=$(state_value "$state_file" round)
  fi

  layout=$(layout_for_phase_dir "$phase_dir")
  if [ "$layout" = "legacy" ]; then
    uat_resolve_legacy_round "$phase_dir" "$round"
  else
    echo "${round:-01}"
  fi
}

first_legacy_artifact() {
  local phase_dir="$1" phase_prefix="$2" round="$3" suffix="$4"
  local round_dir_artifact phase_root_artifact

  round_dir_artifact="$phase_dir/remediation/uat/round-${round}/R${round}-${suffix}.md"
  if [ -f "$round_dir_artifact" ]; then
    echo "$round_dir_artifact"
    return 0
  fi

  phase_root_artifact=$(find "$phase_dir" -maxdepth 1 -name "${phase_prefix}-*-${suffix}.md" ! -name '.*' 2>/dev/null | sort | tail -1)
  if [ -n "$phase_root_artifact" ] && [ -f "$phase_root_artifact" ]; then
    echo "$phase_root_artifact"
    return 0
  fi
  return 1
}

selected_legacy_artifact_path() {
  local phase_dir="$1" artifact_type="$2" phase_prefix round bare_artifact

  phase_prefix=$(phase_prefix_for_dir "$phase_dir")
  round=$(round_for_phase_dir "$phase_dir")
  case "$artifact_type" in
    research)
      if first_legacy_artifact "$phase_dir" "$phase_prefix" "$round" RESEARCH; then
        return 0
      fi
      bare_artifact="$phase_dir/${phase_prefix}-RESEARCH.md"
      if [ -f "$bare_artifact" ]; then
        echo "$bare_artifact"
        return 0
      fi
      ;;
    plan)
      if first_legacy_artifact "$phase_dir" "$phase_prefix" "$round" PLAN; then
        return 0
      fi
      ;;
  esac

  return 1
}
