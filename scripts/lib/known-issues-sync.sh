NEW_ISSUES="[]"

summary_issues() {
  python3 -I "$SCRIPT_DIR/lib/known-issues-extract.py" --glob "$PHASE_DIR"
}

load_current_registry() {
  if registry_valid; then
    cat "$REGISTRY"
  else
    empty_registry
  fi
}

merge_summary_issues() {
  jq -cn --argjson current "$1" --argjson incoming "$2" '
    ($current.issues // []) as $old
    | [ $incoming[] as $new | ($old[] | select(.signature == $new.signature)) // $new ] as $seen
    | $seen + [ $old[] | select(.signature as $signature | [$seen[].signature] | index($signature) | not) ]
    | unique_by(.signature)
  '
}

sign_summary_issues() {
  local raw="$1" item test_name file_path error_message signature signed='[]'
  while IFS= read -r item; do
    test_name=$(jq -r '.test' <<< "$item")
    file_path=$(jq -r '.file' <<< "$item")
    error_message=$(jq -r '.error' <<< "$item")
    signature=$(signature_for "$test_name" "$file_path" "$error_message")
    signed=$(jq -cn --argjson items "$signed" --argjson item "$item" --arg signature "$signature" '$items + [$item + {signature:$signature, times_seen:1, disposition:"unresolved"}]')
  done < <(jq -c '.[]' <<< "$raw")
  printf '%s' "$signed"
}

write_merged_registry() {
  local final
  final=$(jq -n --arg phase "$(phase_number_label)" --argjson issues "$1" '{schema_version:1, phase:$phase, issues:$issues}')
  write_registry "$final"
}

sync_summaries() {
  local raw current signed merged
  registry_valid || [ ! -f "$REGISTRY" ] || { status_output malformed 0; return 1; }
  raw=$(summary_issues) || return 1
  current=$(load_current_registry)
  signed=$(sign_summary_issues "$raw")
  merged=$(merge_summary_issues "$current" "$signed")
  write_merged_registry "$merged"
  status_output present "$(unresolved_count)"
}

verification_result() {
  awk '
    BEGIN { in_fm=0 }
    NR==1 && /^---[[:space:]]*$/ { in_fm=1; next }
    in_fm && /^---[[:space:]]*$/ { exit }
    in_fm && /^result:[[:space:]]*/ { sub(/^result:[[:space:]]*/, ""); gsub(/[[:space:]]/, ""); print toupper($0); exit }
  ' "$1"
}

sign_verification_issues() {
  local issues_json="$1" item test_name file_path error_message signature
  NEW_ISSUES="[]"
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    test_name=$(jq -r '.test' <<< "$item")
    file_path=$(jq -r '.file' <<< "$item")
    error_message=$(jq -r '.error' <<< "$item")
    signature=$(signature_for "$test_name" "$file_path" "$error_message")
    NEW_ISSUES=$(jq -cn --argjson arr "$NEW_ISSUES" --arg t "$test_name" --arg f "$file_path" --arg e "$error_message" --arg sig "$signature" \
      '$arr + [{test: $t, file: $f, error: $e, signature: $sig}]')
  done < <(jq -c '.[]' <<< "$issues_json" 2>/dev/null)
}

merge_verification_issues() {
  local current="$1" new_issues="$2"
  jq -cn --argjson current "$current" --argjson new "$new_issues" '
    ($current.issues // []) as $existing
    | ($existing | map(.signature)) as $existing_sigs
    | [ $new[] | . as $n
        | if ($existing_sigs | index($n.signature)) then
            ($existing[] | select(.signature == $n.signature))
            | . + {times_seen: ((.times_seen // 1) + 1)}
          else
            $n + {times_seen: 1, disposition: "unresolved"}
          end
      ] as $synced
    | $synced + [ $existing[]
        | select((.disposition // "unresolved") == "unresolved")
        | select(.signature as $s | [$synced[].signature] | index($s) | not) ]
    | unique_by(.signature)
  ' 2>/dev/null || printf '%s' "$current" | jq -c '.issues // []'
}

sync_verification() {
  local verification_file="$1" result issues_json current merged
  [ -f "$verification_file" ] || { status_output missing 0; return 0; }

  result=$(verification_result "$verification_file")
  issues_json=$(python3 -I "$SCRIPT_DIR/lib/known-issues-extract.py" "$verification_file")
  current=$(load_current_registry)
  sign_verification_issues "$issues_json"
  merged=$(merge_verification_issues "$current" "$NEW_ISSUES")

  if [ "$result" = "PASS" ]; then
    merged=$(jq '[.[] | . + {disposition: "resolved"}]' <<< "$merged")
  fi

  write_merged_registry "$merged"
  status_output present "$(unresolved_count)"
}
