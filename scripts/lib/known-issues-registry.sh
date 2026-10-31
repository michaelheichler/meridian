status_output() {
  echo "known_issues_path=$REGISTRY"
  echo "known_issues_status=$1"
  echo "known_issues_count=$2"
}

registry_valid() {
  [ -f "$REGISTRY" ] || return 1
  jq -e '
    type == "object"
    and (.schema_version | type == "number")
    and (.phase | type == "string")
    and (.issues | type == "array")
    and all(.issues[]; (.signature | type == "string") and (.signature | test("^[0-9a-f]{12}$")))
  ' "$REGISTRY" >/dev/null 2>&1
}

signature_for() {
  jq -rn --arg t "$1" --arg f "$2" --arg e "$3" \
    '[$t, $f, $e] | map(ascii_downcase | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ")) | join("\n")' \
    | shasum -a 256 2>/dev/null | cut -c1-12
}

phase_number_label() {
  basename "${PHASE_DIR%/}" | sed 's/^\([0-9]*\).*/\1/'
}

empty_registry() {
  jq -n --arg phase "$(phase_number_label)" \
    '{schema_version: 1, phase: $phase, issues: []}'
}

write_registry() {
  local tmp
  tmp=$(mktemp "${REGISTRY}.tmp.XXXXXX") || return 1
  printf '%s\n' "$1" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$REGISTRY" || { rm -f "$tmp"; return 1; }
}

unresolved_count() {
  jq '[.issues[] | select((.disposition // "unresolved") == "unresolved")] | length' "$REGISTRY"
}

cmd_status() {
  local count
  if [ ! -f "$REGISTRY" ]; then
    status_output missing 0
    return 0
  fi
  if ! registry_valid; then
    status_output malformed 0
    return 0
  fi
  count=$(unresolved_count)
  status_output present "$count"
}

cmd_clear() {
  rm -f "$REGISTRY"
  status_output missing 0
}

cmd_resolve() {
  local signature="$1" updated
  registry_valid || { status_output missing 0; return 0; }
  updated=$(jq --arg sig "$signature" '
    .issues = [.issues[] | if .signature == $sig then . + {disposition: "resolved"} else . end]
  ' "$REGISTRY")
  write_registry "$updated"
  status_output present "$(jq '[.issues[] | select((.disposition // "unresolved") == "unresolved")] | length' <<< "$updated")"
}
