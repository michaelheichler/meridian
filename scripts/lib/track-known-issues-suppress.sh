SUPPRESS_ENTRY=''
SUPPRESS_ERROR=''

suppress_fail() {
  local error_json
  printf -v SUPPRESS_ERROR '%s' ''
  error_json=$(jq -cn --arg code "$1" --arg message "$2" '{status:"error", code:$code, message:$message}') || return 1
  printf -v SUPPRESS_ERROR '%s' "$error_json"
}

suppress_payload_signature() {
  local payload="$1" test_name file_path error_message
  jq -e 'type == "object" and (.test | type == "string") and (.file | type == "string") and (.error | type == "string")' \
    <<< "$payload" >/dev/null 2>&1 || return 1
  test_name=$(jq -r '.test' <<< "$payload")
  file_path=$(jq -r '.file' <<< "$payload")
  error_message=$(jq -r '.error' <<< "$payload")
  signature_for "$test_name" "$file_path" "$error_message"
}

suppress_resolve_entry() {
  local payload="$1" signature entry
  registry_valid || { suppress_fail "suppression_registry_unavailable" "Known-issue registry is missing or malformed. The todo was removed, but it may be re-promoted."; return 1; }
  signature=$(suppress_payload_signature "$payload") || { suppress_fail "suppression_missing_signature" "Known-issue suppression metadata is unavailable. The todo was removed, but it may be re-promoted."; return 1; }
  entry=$(jq -c --arg sig "$signature" '[.issues[] | select(.signature == $sig)] | first // empty' "$REGISTRY")
  [ -n "$entry" ] || { suppress_fail "suppression_issue_not_found" "Known issue is not in the phase registry. The todo was removed, but it may be re-promoted."; return 1; }
  printf -v SUPPRESS_ENTRY '%s' "$entry"
}

cmd_lookup_signature() {
  local payload
  payload=$(cat)
  suppress_resolve_entry "$payload" || { [ -n "$SUPPRESS_ERROR" ] || return 1; printf '%s\n' "$SUPPRESS_ERROR"; return 0; }
  jq -cn --arg phase "$(phase_number_label)" --arg phase_dir "$PHASE_DIR" --argjson entry "$SUPPRESS_ENTRY" --argjson query "$payload" '
    {status:"ok", signature:{
      phase: ($entry.phase // $phase),
      phase_dir: $phase_dir,
      test: $entry.test,
      file: $entry.file,
      error: $entry.error,
      source_kind: ($entry.source_kind // null),
      disposition: ($entry.disposition // $query.disposition // null),
      source_path: ($entry.source_path // $query.source_path // null)
    }}'
}

write_suppression() {
  local signature="$1" via="$2" stamp updated
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  updated=$(jq --arg sig "$signature" --arg via "$via" --arg at "$stamp" '
    .issues = [.issues[] | if .signature == $sig then . + {suppressed: {via:$via, at:$at}} else . end]
  ' "$REGISTRY") || return 1
  write_registry "$updated"
}

cmd_suppress() {
  local payload signature via action
  payload=$(cat)
  suppress_resolve_entry "$payload" || { [ -n "$SUPPRESS_ERROR" ] || return 1; printf '%s\n' "$SUPPRESS_ERROR"; return 0; }
  signature=$(jq -r '.signature' <<< "$SUPPRESS_ENTRY")
  via=$(jq -r '.via // "unknown"' <<< "$payload")
  action="already_suppressed"
  if jq -e '(.suppressed // null) == null' <<< "$SUPPRESS_ENTRY" >/dev/null; then
    write_suppression "$signature" "$via" || { suppress_fail "suppression_write_failed" "Known-issue registry could not be updated. The todo was removed, but it may be re-promoted." || return 1; printf '%s\n' "$SUPPRESS_ERROR"; return 0; }
    action="suppressed"
  fi
  jq -cn --arg signature "$signature" --arg action "$action" '{status:"ok", action:$action, signature:$signature}'
}
