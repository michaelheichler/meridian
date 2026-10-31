list_canonical_phase_dirs() {
  local parent="$1"
  [ -d "$parent" ] || return 0

  local dirs=() d base
  for d in "$parent"/*/; do
    [ -d "$d" ] || continue
    base="${d%/}"
    base="${base##*/}"
    case "$base" in [0-9]*-*) dirs+=("${d%/}") ;; esac
  done
  [ ${#dirs[@]} -gt 0 ] || return 0
  printf '%s\n' "${dirs[@]}" | sort -V 2>/dev/null || \
    printf '%s\n' "${dirs[@]}" | awk -F/ '{n=$NF; gsub(/[^0-9].*/,"",n); if (n == "") n=0; print (n+0)"\t"$0}' | sort -n -k1,1 -k2,2 | cut -f2-
}

count_phase_plans() {
  local dir="$1"
  local count=0
  local f
  for f in "$dir"/[0-9]*-PLAN.md "$dir"/PLAN.md; do
    [ -f "$f" ] && count=$((count + 1))
  done
  echo "$count"
}

phase_dir_display_name() {
  local dir="$1"
  local base

  base=$(basename "$dir")
  base=$(echo "$base" | sed 's/^[0-9]*-//')
  printf '%s' "$base" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)}1'
}

phase_dir_position() {
  local phase_dir="$1"
  local phases_parent="${2:-$(dirname "$phase_dir")}"
  local idx=0 dir

  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    idx=$((idx + 1))
    if [ "${dir%/}" = "${phase_dir%/}" ]; then
      echo "$idx"
      return 0
    fi
  done < <(list_canonical_phase_dirs "$phases_parent")

  echo ""
}

planning_root_from_phase_dir() {
  local phase_dir="$1"
  local phases_dir root

  phases_dir=$(dirname "$phase_dir")
  root=$(dirname "$phases_dir")
  if [ "$(basename "$phases_dir")" = "phases" ] && [ -d "$root" ]; then
    echo "$root"
    return 0
  fi

  echo ".lbwc-planning"
}

find_phase_dir_by_ref() {
  local planning_dir="$1"
  local phase_ref="$2"
  local prefix_match

  [ -d "$planning_dir/phases" ] || return 0
  [ -n "$phase_ref" ] || return 0
  echo "$phase_ref" | grep -qE '^[0-9]+$' || return 0

  prefix_match=$(ls -d "$planning_dir/phases/$(printf '%02d' "$phase_ref")"-*/ 2>/dev/null | head -1)
  if [ -n "$prefix_match" ]; then
    echo "$prefix_match"
    return 0
  fi

  list_canonical_phase_dirs "$planning_dir/phases" | sed -n "${phase_ref}p"
}

phase_status_label() {
  local dir="$1"
  local phase_idx="$2"
  local plans complete terminal

  plans=$(count_phase_plans "$dir")
  complete=$(count_complete_summaries "$dir")
  terminal=$(count_terminal_summaries "$dir")

  if [ "$plans" -gt 0 ] && [ "$complete" -ge "$plans" ]; then
    echo "Complete"
  elif [ "$terminal" -gt 0 ]; then
    echo "In progress"
  elif [ "$plans" -gt 0 ]; then
    echo "Planned"
  elif [ "$phase_idx" -eq 1 ]; then
    echo "Pending planning"
  else
    echo "Pending"
  fi
}

phase_number_from_name() {
  printf '%s' "$1" | sed -n 's/^\([0-9][0-9]*\).*/\1/p'
}

phase_number_emit() {
  if [ -n "$1" ] && echo "$1" | grep -qE '^[0-9]+$'; then
    echo "$1"
    return 0
  fi
  return 1
}

phase_number_from_artifact() {
  local dir="$1" artifact
  artifact=$(find "$dir" -maxdepth 1 ! -name '.*' \( -name '[0-9]*-PLAN.md' -o -name '[0-9]*-SUMMARY.md' -o -name '[0-9]*-UAT.md' \) 2>/dev/null | (sort -V 2>/dev/null || sort) | head -1)
  [ -n "$artifact" ] || return 0
  basename "$artifact" | sed -n 's/^\([0-9][0-9]*\).*/\1/p'
}

phase_number_from_uat_frontmatter() {
  local uat_file="$1"
  [ -n "$uat_file" ] && [ -f "$uat_file" ] || return 0
  awk '
    NR == 1 && /^---[[:space:]]*$/ { in_fm = 1; next }
    in_fm && /^---[[:space:]]*$/ { exit }
    in_fm {
      lower = tolower($0)
      if (lower ~ /^phase:[[:space:]]*[0-9]+[[:space:]]*$/) {
        value = $0
        sub(/^[^:]*:[[:space:]]*/, "", value)
        gsub(/[[:space:]]+$/, "", value)
        print value
        exit
      }
    }
  ' "$uat_file" 2>/dev/null || true
}

phase_number_from_named_uat() {
  local uat_file
  uat_file=$(find "$1" -maxdepth 1 ! -name '.*' -name '*-UAT.md' ! -name '*-SOURCE-UAT.md' 2>/dev/null | (sort -V 2>/dev/null || sort) | head -1)
  phase_number_from_uat_frontmatter "$uat_file"
}

phase_number_from_current_uat() {
  local uat_file=""
  if type current_uat &>/dev/null; then
    uat_file=$(current_uat "$1")
  fi
  phase_number_from_uat_frontmatter "$uat_file"
}

resolve_phase_number_from_phase_dir() {
  local dir="$1" num

  num=$(phase_number_from_name "$(basename "$dir")")
  phase_number_emit "$num" && return 0
  num=$(phase_number_from_artifact "$dir")
  phase_number_emit "$num" && return 0
  num=$(phase_number_from_named_uat "$dir")
  phase_number_emit "$num" && return 0
  num=$(phase_number_from_current_uat "$dir")
  phase_number_emit "$num" && return 0

  echo ""
}
