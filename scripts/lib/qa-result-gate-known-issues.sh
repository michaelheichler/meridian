# jq programs sit in constants because inline they exceed the function limit
QA_GATE_JQ_EXTRACT_ISSUES='
    def trim: gsub("^[[:space:]]+|[[:space:]]+$"; "");
    def valid_issue:
      type == "object"
      and (.test | type == "string")
      and (.file | type == "string")
      and (.error | type == "string");
    def valid_resolution:
      valid_issue
      and (.disposition | type == "string")
      and (.rationale | type == "string")
      and (
        .disposition == "resolved"
        or .disposition == "accepted-process-exception"
        or .disposition == "unresolved"
      );
    split("\n")
    | map(trim | select(length > 0) | (try fromjson catch empty))
    | if $kind == "issue" then
        map(select(valid_issue))
      elif $kind == "resolution" or $kind == "outcome" then
        map(select(valid_resolution))
      else
        []
      end
    | unique_by(.test, .file, .error)
    | sort_by(.test, .file, .error)
'

QA_GATE_JQ_COVERS_ISSUES='
      def valid_issue:
        type == "object"
        and (.test | type == "string")
        and (.file | type == "string")
        and (.error | type == "string");
      ($required[0] // empty) as $required_array |
      ($candidate[0] // empty) as $candidate_array |
      if (($required_array | type) != "array") or (($candidate_array | type) != "array") then
        false
      else
        ([ $required_array[] | select(valid_issue and .test != "") ]
          | group_by([.test, .file])) as $required_pairs |
        all($required_array[];
          if type != "object" then
            false
          elif ((.test | type) == "string" and .test == "") then
            true
          else
            valid_issue
          end
        )
        and all($required_pairs[];
          . as $pair |
          any($candidate_array[];
            . as $candidate |
            valid_issue
            and .test == $pair[0].test
            and .file == $pair[0].file
            and any($pair[]; .error == $candidate.error)
          )
        )
      end
'

QA_GATE_JQ_DISPOSITIONS_MATCH='
      def disposition_key: [.test, .file, .error, .disposition] | @json;
      ($expected[0] // empty) as $expected_array |
      ($actual[0] // empty) as $actual_array |
      if (($expected_array | type) != "array") or (($actual_array | type) != "array") then
        false
      else
        (reduce ($actual_array[] | select(
          type == "object"
          and (.test | type == "string")
          and (.file | type == "string")
          and (.error | type == "string")
          and (.disposition | type == "string")
        )) as $actual_disposition ({}; .[$actual_disposition | disposition_key] = true)) as $actual_disposition_index |
        all($expected_array[];
          if type != "object" then
            true
          elif ((.test // "") == "") then
            true
          elif ((.test | type) != "string") or ((.file | type) != "string") or ((.error | type) != "string") or ((.disposition | type) != "string") then
            false
          else
            ($actual_disposition_index[disposition_key] // false) == true
          end
        )
      end
'

extract_frontmatter_json_object_array() {
  local file_path="${1:-}"
  local key_name="${2:-}"
  local kind="${3:-issue}"
  local tmp_file=""
  [ -f "$file_path" ] || { echo '[]'; return 0; }
  [ -n "$key_name" ] || { echo '[]'; return 0; }

  tmp_file=$(mktemp) || { printf '%s\n' '[{"_extraction_error":true}]'; return 0; }
  if ! extract_frontmatter_array_items "$file_path" "$key_name" > "$tmp_file" 2>/dev/null; then
    rm -f "$tmp_file"
    printf '%s\n' '[{"_extraction_error":true}]'
    return 0
  fi

  if [ ! -s "$tmp_file" ]; then
    rm -f "$tmp_file"
    echo '[]'
    return 0
  fi

  jq -Rsc --arg kind "$kind" "$QA_GATE_JQ_EXTRACT_ISSUES" "$tmp_file"
  rm -f "$tmp_file"
}

list_scope_documents() {
  local scan_dir="${1:-}"
  local file_glob_mode="${2:-plan}"
  local -a name_tests=(-name '*-PLAN.md' -o -name 'PLAN.md')
  if [ "$file_glob_mode" = "summary" ]; then
    name_tests=(-name '*-SUMMARY.md' -o -name 'SUMMARY.md')
  fi
  find "$scan_dir" -maxdepth 1 ! -name '.*' \( "${name_tests[@]}" \) 2>/dev/null | (sort -V 2>/dev/null || sort)
}

collect_frontmatter_json_object_array_in_dir() {
  local scan_dir="${1:-}"
  local file_glob_mode="${2:-plan}"
  local key_name="${3:-}"
  local kind="${4:-issue}"
  local scan_file=""
  local tmp_file=""
  [ -d "$scan_dir" ] || { echo '[]'; return 0; }
  [ -n "$key_name" ] || { echo '[]'; return 0; }

  tmp_file=$(mktemp) || { printf '%s\n' '[{"_extraction_error":true}]'; return 0; }
  while IFS= read -r scan_file; do
    [ -f "$scan_file" ] || continue
    extract_frontmatter_json_object_array "$scan_file" "$key_name" "$kind" | jq -c '.[]' >> "$tmp_file" 2>/dev/null || true
  done < <(list_scope_documents "$scan_dir" "$file_glob_mode")

  if [ ! -s "$tmp_file" ]; then
    rm -f "$tmp_file"
    echo '[]'
    return 0
  fi

  jq -sc 'unique_by(.test, .file, .error) | sort_by(.test, .file, .error)' "$tmp_file"
  rm -f "$tmp_file"
}

json_object_array_length() {
  local json_array="${1:-[]}"
  printf '%s' "$json_array" | jq 'length' 2>/dev/null || echo 0
}

json_arrays_satisfy_program() {
  local program="${1:-}"
  local first_name="${2:-}"
  local first_json="${3:-[]}"
  local second_name="${4:-}"
  local second_json="${5:-[]}"
  local first_file=""
  local second_file=""
  local jq_status=0

  first_file=$(mktemp) || return 1
  second_file=$(mktemp) || {
    rm -f "$first_file"
    return 1
  }
  if ! printf '%s' "$first_json" > "$first_file" || ! printf '%s' "$second_json" > "$second_file"; then
    rm -f "$first_file" "$second_file"
    return 1
  fi

  if jq -e -n \
    --slurpfile "$first_name" "$first_file" \
    --slurpfile "$second_name" "$second_file" "$program" >/dev/null 2>&1; then
    jq_status=0
  else
    jq_status=$?
  fi
  rm -f "$first_file" "$second_file"
  return "$jq_status"
}

json_object_array_covers_full_issue_objects() {
  json_arrays_satisfy_program "$QA_GATE_JQ_COVERS_ISSUES" required "${1:-[]}" candidate "${2:-[]}"
}

load_known_issue_registry_json() {
  local registry_path="${1:-}"
  [ -n "$registry_path" ] || { echo '[]'; return 0; }
  [ -f "$registry_path" ] || { echo '[]'; return 0; }
  jq -c 'select(type == "object" and (.issues | type == "array")) | .issues' "$registry_path" 2>/dev/null || echo '[]'
}

json_object_array_dispositions_match() {
  json_arrays_satisfy_program "$QA_GATE_JQ_DISPOSITIONS_MATCH" expected "${1:-[]}" actual "${2:-[]}"
}

json_object_array_has_disposition() {
  local json_array="${1:-[]}"
  local disposition="${2:-}"
  [ -n "$disposition" ] || return 1
  printf '%s' "$json_array" | jq -e --arg disposition "$disposition" '.[] | select(.disposition == $disposition)' >/dev/null 2>&1
}
