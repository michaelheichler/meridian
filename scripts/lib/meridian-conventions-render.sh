compact_json() {
  jq -cS '.' <<< "$1"
}

render_next() {
  printf '\n%s\n' 'Next: continue your current MERIDIAN workflow.'
}

render_table() {
  local value="$1" count
  count=$(jq '.conventions | length' <<< "$value")
  printf 'Project conventions (%s)\n\n' "$count"
  if [ "$count" -eq 0 ]; then
    printf '%s\n' 'No conventions are saved.'
    render_next
    return 0
  fi
  printf '%-10s  %-16s  %-13s  %-10s  %s\n' 'ID' 'Category' 'Source' 'Confidence' 'Rule'
  printf '%-10s  %-16s  %-13s  %-10s  %s\n' '----------' '----------------' '-------------' '----------' '----'
  jq -r '.conventions[] | [.id, .category, .source, (.confidence // "user"), .rule] | @tsv' <<< "$value" |
    while IFS=$'\t' read -r id category source confidence rule; do
      printf '%-10s  %-16s  %-13s  %-10s  %s\n' "$id" "$category" "$source" "$confidence" "$rule"
    done
  render_next
}

render_grouped() {
  local value="$1" category
  while IFS= read -r category; do
    printf '%s\n' "[$category]"
    jq -r --arg category "$category" '.conventions[] | select(.category == $category) | "  \(.id)  \(.rule)  [\(.source)]"' <<< "$value"
    printf '\n'
  done < <(jq -r '[.conventions[].category] | unique[]' <<< "$value")
}

group_json() {
  jq -ceS 'reduce .conventions[] as $item ({}; .[$item.category] = ((.[$item.category] // []) + [$item]))' <<< "$1"
}

render_change_counts() {
  local current="$1" result="$2"
  jq -nr --argjson current "$current" --argjson result "$result" '
    ($current.conventions | map({key: .id, value: .}) | from_entries) as $before
    | ($result.conventions | map({key: .id, value: .}) | from_entries) as $after
    | ([ $after | keys[] | select($before[.] == null) ] | length) as $added
    | ([ $before | keys[] | select($after[.] == null) ] | length) as $removed
    | ([ $after | keys[] | select($before[.] != null and $before[.] != $after[.]) ] | length) as $updated
    | ([ $after | keys[] | select($before[.] == $after[.]) ] | length) as $kept
    | "Added: \($added) | Updated: \($updated) | Removed: \($removed) | Kept: \($kept)"
  '
}
