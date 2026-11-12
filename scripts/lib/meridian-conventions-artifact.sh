empty_artifact() {
  printf '%s\n' '{"conventions":[],"schema_version":1}'
}

normalize_artifact() {
  local value="$1" today
  today=$(date -u +%Y-%m-%d) || fail 'could not determine the current date'
  jq -ceS --arg today "$today" -f "$SCRIPT_DIR/lib/meridian-conventions-normalize.jq" \
    <<< "$value" 2>/dev/null || fail 'invalid conventions artifact'
}

read_artifact() {
  local planning_dir="$1" path value
  path="$planning_dir/conventions.json"
  [ ! -L "$path" ] || fail "symbolic link artifacts are not allowed: $path"
  if [ ! -e "$path" ]; then
    empty_artifact
    return 0
  fi
  [ -f "$path" ] || fail "conventions artifact is not a regular file: $path"
  value=$(<"$path") || fail "could not read conventions artifact: $path"
  normalize_artifact "$value"
}

validate_candidates() {
  local value="$1"
  jq -ceS '
    def category: IN("file-structure", "naming", "testing", "style", "tooling", "patterns", "other");
    def source_file: IN("PATTERNS.md", "ARCHITECTURE.md", "STACK.md", "CONCERNS.md");
    def valid_text: type == "string" and length > 0 and (test("[[:cntrl:]]") | not);
    if type != "object" or .schema_version != 1 or (.conventions | type != "array") or (.conventions | length > 15)
      then error("invalid candidate set") else . end
    | if all(.conventions[];
        (.rule | valid_text)
        and (.category | category)
        and (.confidence | IN("high", "medium", "low"))
        and (.detected_from | source_file)
        and ((.conflicts_with // []) | type == "array" and all(.[]; type == "string" and test("^CONV-[0-9]{3,}$")))
      ) then . else error("invalid candidate") end
  ' <<< "$value" 2>/dev/null || fail 'invalid convention candidates'
}

read_candidates() {
  local source="$1" value
  if [ "$source" = '-' ]; then
    value=$(</dev/stdin) || fail 'could not read convention candidates from stdin'
  else
    [ ! -L "$source" ] || fail "symbolic link candidate files are not allowed: $source"
    [ -f "$source" ] || fail "candidate file is not readable: $source"
    value=$(<"$source") || fail "could not read candidate file: $source"
  fi
  validate_candidates "$value"
}

next_id_number() {
  jq '[.conventions[].id | capture("^CONV-(?<n>[0-9]+)$").n | tonumber] | max // 0 | . + 1' <<< "$1"
}

format_id() {
  printf 'CONV-%03d\n' "$1"
}

normalized_rule() {
  jq -nr --arg rule "$1" '$rule | ascii_downcase | gsub("[[:space:]]+"; " ") | sub("^ "; "") | sub(" $"; "")'
}

validate_rule_text() {
  jq -ne --arg value "$1" '$value | type == "string" and length > 0 and (test("[[:cntrl:]]") | not)' >/dev/null 2>&1
}
