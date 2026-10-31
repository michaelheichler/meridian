normalize_roadmap_phase_num() {
  local num="$1"
  num=$(printf '%s' "$num" | sed 's/^0*//')
  printf '%s\n' "${num:-0}"
}

roadmap_checklist_phase_num_from_line() {
  local line="$1" raw_num
  if [[ "$line" =~ ^-\ \[.\]\ \[?Phase\ ([0-9][0-9]*): ]]; then
    raw_num="${BASH_REMATCH[1]}"
    normalize_roadmap_phase_num "$raw_num"
    return 0
  fi
  return 1
}

roadmap_checklist_duplicate_phase_nums() {
  local roadmap_file="$1"
  local seen="" emitted="" line num

  [ -f "$roadmap_file" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    if num=$(roadmap_checklist_phase_num_from_line "$line"); then
      case " $seen " in
        *" $num "*)
          case " $emitted " in
            *" $num "*) ;;
            *)
              printf '%s\n' "$num"
              emitted="$emitted $num"
              ;;
          esac
          ;;
      esac
      seen="$seen $num"
    fi
  done < "$roadmap_file"
}

roadmap_checklist_has_duplicate_phase_nums() {
  local roadmap_file="$1"
  local seen="" line num

  [ -f "$roadmap_file" ] || return 1

  while IFS= read -r line || [ -n "$line" ]; do
    if num=$(roadmap_checklist_phase_num_from_line "$line"); then
      case " $seen " in
        *" $num "*) return 0 ;;
      esac
      seen="$seen $num"
    fi
  done < "$roadmap_file"

  return 1
}

roadmap_phase_dir_prefix_num() {
  local phase_dir="$1" num
  num=$(basename "$phase_dir" | sed -n 's/^\([0-9][0-9]*\).*/\1/p')
  normalize_roadmap_phase_num "$num"
}

roadmap_dir_names_for_prefix() {
  local phases_dir="$1" num="$2" names="" dup_dir dup_num base
  while IFS= read -r dup_dir; do
    [ -n "$dup_dir" ] || continue
    dup_num=$(roadmap_phase_dir_prefix_num "$dup_dir")
    [ "$dup_num" = "$num" ] || continue
    base=$(basename "$dup_dir")
    names="${names:+$names, }$base"
  done < <(list_canonical_phase_dirs "$phases_dir")
  printf '%s' "$names"
}

roadmap_emit_duplicate_prefix() {
  local names
  names=$(roadmap_dir_names_for_prefix "$1" "$2")
  printf 'duplicate phase directory prefix %s is ambiguous across %s; ROADMAP numbering cannot be safely reconciled\n' "$2" "$names"
}

roadmap_duplicate_phase_dir_prefix_details() {
  local phases_dir="$1"
  local seen="" emitted="" dir num

  [ -d "$phases_dir" ] || return 0

  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    num=$(roadmap_phase_dir_prefix_num "$dir")
    if [[ " $seen " == *" $num "* && " $emitted " != *" $num "* ]]; then
      roadmap_emit_duplicate_prefix "$phases_dir" "$num"
      emitted="$emitted $num"
    fi
    seen="$seen $num"
  done < <(list_canonical_phase_dirs "$phases_dir")
}

roadmap_phase_dir_prefixes_have_duplicates() {
  local detail

  while IFS= read -r detail; do
    [ -n "$detail" ] && return 0
  done < <(roadmap_duplicate_phase_dir_prefix_details "$1")

  return 1
}

_roadmap_index_in_sequence() {
  local wanted="$1" sequence="$2" idx=0 candidate

  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    idx=$((idx + 1))
    if [ "$candidate" = "$wanted" ]; then
      printf '%s\n' "$idx"
      return 0
    fi
  done <<< "$sequence"

  return 1
}

_roadmap_candidate_score() {
  local checklist_seq="$1" expected_seq="$2"
  local seen="" last_idx=0 score=0 num expected_idx

  [ -n "$expected_seq" ] || { printf '%s\n' "0"; return 0; }

  while IFS= read -r num; do
    [ -n "$num" ] || continue
    case " $seen " in *" $num "*) continue ;; esac
    seen="$seen $num"

    if expected_idx=$(_roadmap_index_in_sequence "$num" "$expected_seq"); then
      if [ "$expected_idx" -le "$last_idx" ]; then
        printf '%s\n' "0"
        return 0
      fi
      last_idx="$expected_idx"
      score=$((score + 1))
    fi
  done <<< "$checklist_seq"

  printf '%s\n' "$score"
}

_roadmap_unique_count() {
  local sequence="$1" seen="" count=0 num

  while IFS= read -r num; do
    [ -n "$num" ] || continue
    case " $seen " in *" $num "*) continue ;; esac
    seen="$seen $num"
    count=$((count + 1))
  done <<< "$sequence"

  printf '%s\n' "$count"
}

_roadmap_sequence_contains_all_unique_in_order() {
  local checklist_seq="$1" expected_seq="$2"
  local expected_count score

  expected_count=$(_roadmap_unique_count "$expected_seq")
  [ "$expected_count" -gt 0 ] || return 1
  score=$(_roadmap_candidate_score "$checklist_seq" "$expected_seq")
  [ "$score" -eq "$expected_count" ]
}

_roadmap_sequence_is_exact_ordinal() {
  local checklist_seq="$1" expected_count="$2"
  local idx=0 num

  [ "$expected_count" -gt 0 ] || return 1
  while IFS= read -r num; do
    [ -n "$num" ] || continue
    idx=$((idx + 1))
    [ "$num" = "$idx" ] || return 1
  done <<< "$checklist_seq"

  [ "$idx" -eq "$expected_count" ]
}

roadmap_checklist_phase_nums() {
  local roadmap_file="$1" line num

  [ -f "$roadmap_file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    if num=$(roadmap_checklist_phase_num_from_line "$line"); then
      printf '%s\n' "$num"
    fi
  done < "$roadmap_file"
}

roadmap_checklist_count() {
  local roadmap_file="$1" count=0 num

  while IFS= read -r num; do
    [ -n "$num" ] || continue
    count=$((count + 1))
  done < <(roadmap_checklist_phase_nums "$roadmap_file")

  printf '%s\n' "$count"
}

roadmap_display_numbering_scheme() {
  local raw_scheme="$1" roadmap_total="${2:-0}"

  case "$raw_scheme" in
    unknown)
      printf '%s\n' "unknown"
      ;;
    prefix)
      if [ "${roadmap_total:-0}" -gt 0 ] 2>/dev/null; then
        printf '%s\n' "prefix"
      else
        printf '%s\n' "ordinal"
      fi
      ;;
    *)
      printf '%s\n' "ordinal"
      ;;
  esac
}

roadmap_dir_prefix_sequence() {
  local phases_dir="$1" dir
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    roadmap_phase_dir_prefix_num "$dir"
  done < <(list_canonical_phase_dirs "$phases_dir")
}

roadmap_sequence_length() {
  local count=0 num
  while IFS= read -r num; do
    [ -n "$num" ] || continue
    count=$((count + 1))
  done <<< "$1"
  printf '%s\n' "$count"
}

roadmap_scheme_from_sequences() {
  local checklist_seq="$1" prefix_seq="$2" dir_count
  dir_count=$(roadmap_sequence_length "$prefix_seq")
  if _roadmap_sequence_contains_all_unique_in_order "$checklist_seq" "$prefix_seq"; then
    printf '%s\n' "prefix"
  elif _roadmap_sequence_is_exact_ordinal "$checklist_seq" "$dir_count"; then
    printf '%s\n' "ordinal"
  else
    printf '%s\n' "unknown"
  fi
}

roadmap_numbering_scheme() {
  local roadmap_file="$1" phases_dir="$2" checklist_seq prefix_seq

  [ -f "$roadmap_file" ] || { printf '%s\n' "unknown"; return 0; }
  [ -d "$phases_dir" ] || { printf '%s\n' "unknown"; return 0; }
  if roadmap_checklist_has_duplicate_phase_nums "$roadmap_file"; then
    printf '%s\n' "unknown"
    return 0
  fi

  checklist_seq=$(roadmap_checklist_phase_nums "$roadmap_file")
  prefix_seq=$(roadmap_dir_prefix_sequence "$phases_dir")
  if [ -z "$prefix_seq" ] || roadmap_phase_dir_prefixes_have_duplicates "$phases_dir"; then
    printf '%s\n' "unknown"
    return 0
  fi
  if [ -z "$checklist_seq" ]; then
    printf '%s\n' "prefix"
    return 0
  fi
  roadmap_scheme_from_sequences "$checklist_seq" "$prefix_seq"
}

roadmap_ordinal_mismatch_details() {
  local phases_dir="$1" dir dir_num
  local idx=0 mismatch_count=0 first_position="" first_base="" first_prefix=""
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    idx=$((idx + 1))
    dir_num=$(roadmap_phase_dir_prefix_num "$dir")
    [ "$dir_num" != "$idx" ] || continue
    mismatch_count=$((mismatch_count + 1))
    if [ -z "$first_position" ]; then
      first_position="$idx"
      first_base=$(basename "$dir")
      first_prefix="$dir_num"
    fi
  done < <(list_canonical_phase_dirs "$phases_dir")
  [ "$mismatch_count" -gt 0 ] || return 0
  if [ "$mismatch_count" -gt 1 ]; then
    printf 'legacy ordinal ROADMAP numbering is in use because phase directory prefixes diverge from the Phase 1..N checklist; position %s -> %s (prefix %s), plus %s more divergent phase dir(s)\n' "$first_position" "$first_base" "$first_prefix" "$((mismatch_count - 1))"
  else
    printf 'legacy ordinal ROADMAP numbering is in use because phase directory prefixes diverge from the Phase 1..N checklist; position %s -> %s (prefix %s)\n' "$first_position" "$first_base" "$first_prefix"
  fi
}

roadmap_missing_dir_details() {
  local roadmap_file="$1" phases_dir="$2" num
  while IFS= read -r num; do
    [ -n "$num" ] || continue
    if ! roadmap_phase_dir_for_num "prefix" "$phases_dir" "$num" >/dev/null 2>&1; then
      printf 'ROADMAP phase %s has no matching %s-* phase directory; using prefix numbering and preserving missing phase slot\n' "$num" "$num"
    fi
  done < <(roadmap_checklist_phase_nums "$roadmap_file")
}

roadmap_unlisted_dir_details() {
  local roadmap_file="$1" phases_dir="$2" checklist_seen="" num dir dir_num base
  while IFS= read -r num; do
    [ -n "$num" ] || continue
    checklist_seen="$checklist_seen $num"
  done < <(roadmap_checklist_phase_nums "$roadmap_file")
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    dir_num=$(roadmap_phase_dir_prefix_num "$dir")
    [[ " $checklist_seen " != *" $dir_num "* ]] || continue
    base=$(basename "$dir")
    printf 'phase directory %s exists on disk but ROADMAP has no matching Phase %s entry; using prefix numbering\n' "$base" "$dir_num"
  done < <(list_canonical_phase_dirs "$phases_dir")
}

roadmap_numbering_mismatch_details() {
  local roadmap_file="$1" phases_dir="$2" scheme="${3:-}"

  [ -f "$roadmap_file" ] || return 0
  [ -d "$phases_dir" ] || return 0
  [ -n "$scheme" ] || scheme=$(roadmap_numbering_scheme "$roadmap_file" "$phases_dir")

  if [ "$scheme" = "unknown" ]; then
    printf '%s\n' "ROADMAP checklist numbering scheme is mixed or unresolvable; skipping numbering-dependent rewrite"
    roadmap_duplicate_phase_dir_prefix_details "$phases_dir"
    return 0
  fi
  if [ "$scheme" = "ordinal" ]; then
    roadmap_ordinal_mismatch_details "$phases_dir"
    return 0
  fi
  [ "$scheme" = "prefix" ] || return 0
  if [ "$(roadmap_checklist_count "$roadmap_file")" -eq 0 ]; then
    printf '%s\n' "ROADMAP has no Phase checklist entries; using ordinal display numbering"
    return 0
  fi
  roadmap_missing_dir_details "$roadmap_file" "$phases_dir"
  roadmap_unlisted_dir_details "$roadmap_file" "$phases_dir"
}

phase_state_log_warning() {
  local planning_root="$1" detail="$2"
  local log timestamp line_count

  [ -n "$planning_root" ] || return 0
  [ -d "$planning_root" ] || return 0
  [ -n "$detail" ] || return 0

  log="$planning_root/.hook-errors.log"
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%s")
  printf '[%s] state-numbering-warning: %s\n' "$timestamp" "$detail" >> "$log" 2>/dev/null || return 0
  if [ -f "$log" ]; then
    line_count=$(wc -l < "$log" 2>/dev/null | tr -d ' ')
    [ "${line_count:-0}" -gt 50 ] && { tail -30 "$log" > "${log}.tmp" && mv "${log}.tmp" "$log"; } 2>/dev/null
  fi
}

phase_state_log_numbering_warnings() {
  local planning_root="$1" roadmap_file="$2" phases_dir="$3" scheme="${4:-}"
  local detail

  while IFS= read -r detail; do
    [ -n "$detail" ] || continue
    phase_state_log_warning "$planning_root" "$detail"
  done < <(roadmap_numbering_mismatch_details "$roadmap_file" "$phases_dir" "$scheme")
}

roadmap_phase_num_for_dir() {
  local scheme="$1" phase_dir="$2" phases_dir
  phases_dir="${3:-$(dirname "$phase_dir")}"

  case "$scheme" in
    prefix)
      roadmap_phase_dir_prefix_num "$phase_dir"
      ;;
    ordinal)
      phase_dir_position "$phase_dir" "$phases_dir"
      ;;
    *)
      printf '\n'
      ;;
  esac
}

roadmap_unique_prefix_dir() {
  local phases_dir="$1" wanted="$2" dir match_dir="" match_count=0
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    [ "$(roadmap_phase_dir_prefix_num "$dir")" = "$wanted" ] || continue
    match_dir="$dir"
    match_count=$((match_count + 1))
  done < <(list_canonical_phase_dirs "$phases_dir")
  [ "$match_count" -eq 1 ] || return 1
  printf '%s\n' "$match_dir"
}

roadmap_ordinal_dir() {
  local phases_dir="$1" wanted="$2" dir idx=0
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    idx=$((idx + 1))
    if [ "$idx" = "$wanted" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
  done < <(list_canonical_phase_dirs "$phases_dir")
  return 1
}

roadmap_phase_dir_for_num() {
  local scheme="$1" phases_dir="$2" wanted

  wanted=$(normalize_roadmap_phase_num "$3")
  [ -n "$wanted" ] || return 1
  [ "$wanted" != "0" ] || return 1

  case "$scheme" in
    prefix) roadmap_unique_prefix_dir "$phases_dir" "$wanted" ;;
    ordinal) roadmap_ordinal_dir "$phases_dir" "$wanted" ;;
    *) return 1 ;;
  esac
}
