PROMOTE_ENTRIES=''
PROMOTED=0
ALREADY=0

scan_promotable_issues() {
  local state_path="$1" issues="$2" item test_name file_path error_message reference
  PROMOTE_ENTRIES=''
  PROMOTED=0
  ALREADY=0
  while IFS= read -r item; do
    test_name=$(jq -r '.test' <<< "$item")
    file_path=$(jq -r '.file' <<< "$item")
    error_message=$(jq -r '.error' <<< "$item")
    reference=$(printf '%s' "${test_name}|${file_path}|${error_message}" | shasum -a 256 | cut -c1-8)
    if grep -qF "(ref:${reference})" "$state_path"; then
      ALREADY=$((ALREADY + 1))
    else
      PROMOTE_ENTRIES="${PROMOTE_ENTRIES}- [KNOWN-ISSUE] ${test_name} (${file_path}): ${error_message} (ref:${reference})"$'\n'
      PROMOTED=$((PROMOTED + 1))
    fi
  done < <(jq -c '.[]' <<< "$issues")
}

insert_promoted_entries() {
  local state_path="$1" entries="$2" tmp
  tmp=$(mktemp "${state_path}.tmp.XXXXXX") || return 1
  awk -v entries="${entries%$'\n'}" '
    /^## Todos$/ { in_todos=1; print; next }
    in_todos && /^## / { if (!added) print entries; in_todos=0; added=1 }
    in_todos && /^[[:space:]]*None\.?[[:space:]]*$/ { if (!added) print entries; added=1; next }
    { print }
    END { if (in_todos && !added) print entries }
  ' "$state_path" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$state_path" || { rm -f "$tmp"; return 1; }
}

promote_todos() {
  local state_path issues total
  state_path="$PLANNING_DIR/STATE.md"
  [ -f "$state_path" ] || { echo "promoted_count=0"; echo "already_tracked_count=0"; echo "total_known_issues=0"; echo "promote_status=no_state_file"; return 1; }
  registry_valid || { echo "promote_status=malformed_registry"; return 1; }
  grep -q '^## Todos$' "$state_path" || { echo "promote_status=no_todos_section"; return 1; }
  issues=$(jq -c '[.issues[] | select((.disposition // "unresolved") == "unresolved")]' "$REGISTRY")
  total=$(jq 'length' <<< "$issues")
  scan_promotable_issues "$state_path" "$issues"
  if [ "$PROMOTED" -gt 0 ]; then
    insert_promoted_entries "$state_path" "$PROMOTE_ENTRIES" || return 1
  fi
  echo "promoted_count=$PROMOTED"
  echo "already_tracked_count=$ALREADY"
  echo "total_known_issues=$total"
  echo "promote_status=$([ "$PROMOTED" -gt 0 ] && printf promoted || printf all_tracked)"
}
