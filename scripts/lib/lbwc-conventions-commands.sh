# Plain globals, because bash 3.2 has no declare -g.
CONV_CONFLICT_ID="" CONV_REPLACE_ID="" CONV_KEEP_BOTH=0

parse_add_options() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --conflicts-with) [ "$#" -ge 2 ] || usage; CONV_CONFLICT_ID="$2"; shift 2 ;;
      --replace) [ "$#" -ge 2 ] || usage; CONV_REPLACE_ID="$2"; shift 2 ;;
      --keep-both) CONV_KEEP_BOTH=1; shift ;;
      *) usage ;;
    esac
  done
  [ -z "$CONV_REPLACE_ID" ] || [ "$CONV_KEEP_BOTH" -eq 0 ] || fail 'choose either --replace or --keep-both'
}

check_conflict_declaration() {
  local current="$1"
  if [ -n "$CONV_CONFLICT_ID" ]; then
    jq -e --arg id "$CONV_CONFLICT_ID" '.conventions | any(.id == $id)' <<< "$current" >/dev/null \
      || fail "conflicting convention not found: $CONV_CONFLICT_ID"
    if [ -z "$CONV_REPLACE_ID" ] && [ "$CONV_KEEP_BOTH" -eq 0 ]; then
      fail "conflict with $CONV_CONFLICT_ID requires --replace or --keep-both" 4
    fi
    [ -z "$CONV_REPLACE_ID" ] || [ "$CONV_REPLACE_ID" = "$CONV_CONFLICT_ID" ] \
      || fail 'replacement id must match the declared conflict'
  fi
  if [ -n "$CONV_REPLACE_ID" ]; then
    jq -e --arg id "$CONV_REPLACE_ID" '.conventions | any(.id == $id)' <<< "$current" >/dev/null \
      || fail "replacement convention not found: $CONV_REPLACE_ID"
  fi
}

find_duplicate_rule() {
  local current="$1" normalized="$2"
  jq -r --arg normalized "$normalized" --arg replace "$CONV_REPLACE_ID" '
    def norm: ascii_downcase | gsub("[[:space:]]+"; " ") | sub("^ "; "") | sub(" $"; "");
    [.conventions[] | select(.id != $replace and (.rule | norm) == $normalized) | .id][0] // empty
  ' <<< "$current"
}

add_convention() {
  local planning_dir="$1" category="$2" rule="$3"
  local current normalized duplicate next new_id tag today result
  shift 3
  case "$category" in
    file-structure|naming|testing|style|tooling|patterns|other) ;;
    *) fail "unknown convention category: $category" ;;
  esac
  validate_rule_text "$rule" || fail 'convention rule must be one non-empty line'
  parse_add_options "$@"
  acquire_lock "$planning_dir"
  current=$(read_artifact "$planning_dir")
  check_conflict_declaration "$current"
  normalized=$(normalized_rule "$rule")
  duplicate=$(find_duplicate_rule "$current" "$normalized")
  [ -z "$duplicate" ] || fail "convention is redundant with $duplicate" 3
  next=$(next_id_number "$current")
  new_id=$(format_id "$next")
  tag=$(jq -nr --arg category "$category" '$category | ascii_upcase')
  today=$(date -u +%Y-%m-%d)
  result=$(jq -ceS --arg id "$new_id" --arg rule "$rule" --arg category "$category" \
    --arg tag "$tag" --arg today "$today" --arg replace "$CONV_REPLACE_ID" \
    -f "$SCRIPT_DIR/lib/lbwc-conventions-add.jq" <<< "$current") || fail 'could not add convention'
  write_artifact "$planning_dir" "$result"
  if [ "$JSON_OUTPUT" -eq 1 ]; then compact_json "$result"; else printf 'Added %s: %s [%s]\n' "$new_id" "$rule" "$category"; render_next; fi
}

remove_convention() {
  local planning_dir="$1" convention_id="$2" confirmation="${3:-}" current rule result
  [ "$confirmation" = '--yes' ] || fail "removing $convention_id requires --yes" 4
  acquire_lock "$planning_dir"
  current=$(read_artifact "$planning_dir")
  rule=$(jq -r --arg id "$convention_id" '.conventions[] | select(.id == $id) | .rule' <<< "$current")
  [ -n "$rule" ] || fail "convention not found: $convention_id"
  result=$(jq -ceS --arg id "$convention_id" '.conventions |= map(select(.id != $id))' <<< "$current")
  write_artifact "$planning_dir" "$result"
  if [ "$JSON_OUTPUT" -eq 1 ]; then compact_json "$result"; else printf 'Removed %s: %s\n' "$convention_id" "$rule"; render_next; fi
}

reconciled_artifact() {
  local current="$1" candidates="$2" today
  today=$(date -u +%Y-%m-%d)
  jq -nceS --argjson current "$current" --argjson candidates "$candidates" --arg today "$today" \
    -f "$SCRIPT_DIR/lib/lbwc-conventions-reconcile.jq" 2>/dev/null || fail 'could not reconcile convention candidates'
}

unknown_conflict_reference() {
  local current="$1" candidates="$2"
  jq -nr --argjson current "$current" --argjson candidates "$candidates" '
    ([ $current.conventions[].id ] | unique) as $known
    | [ $candidates.conventions[].conflicts_with[]? | select(($known | index(.)) == null) ]
    | unique
    | .[0] // empty
  '
}

run_reconcile() {
  local planning_dir="$1" source="$2" persist="$3" current candidates unknown result counts
  if [ "$persist" -eq 1 ]; then acquire_lock "$planning_dir"; fi
  current=$(read_artifact "$planning_dir")
  candidates=$(read_candidates "$source")
  unknown=$(unknown_conflict_reference "$current" "$candidates")
  [ -z "$unknown" ] || fail "unknown conflict reference: $unknown"
  result=$(reconciled_artifact "$current" "$candidates")
  normalize_artifact "$result" >/dev/null
  counts=$(render_change_counts "$current" "$result")
  if [ "$persist" -eq 1 ]; then write_artifact "$planning_dir" "$result"; fi
  if [ "$JSON_OUTPUT" -eq 1 ]; then
    compact_json "$result"
  elif [ "$persist" -eq 1 ]; then
    printf 'Refreshed conventions.\n%s\n\n' "$counts"
    render_table "$result"
  else
    printf 'Convention reconciliation preview. No files changed.\n%s\n\n' "$counts"
    render_table "$result"
  fi
}
