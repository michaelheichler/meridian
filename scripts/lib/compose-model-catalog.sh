MERIDIAN_COMPOSE_LIB_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

meridian_extract_model_records() {
  local binary="$1" output="$2" entries metadata entry remainder selector_id group display_name
  entries=$(mktemp "${TMPDIR:-/tmp}/meridian-claude-model-entries.XXXXXX") || return 1
  metadata=$(mktemp "${TMPDIR:-/tmp}/meridian-claude-model-metadata.XXXXXX") || {
    rm -f "$entries"
    return 1
  }
  LC_ALL=C grep -aoE 'id:"claude-[a-zA-Z0-9._-]+",family:"[a-zA-Z0-9_]+",display_name:"[^"[:cntrl:]]+"' "$binary" > "$entries" 2>/dev/null || true
  : > "$metadata" || return 1
  while IFS= read -r entry; do
    remainder="${entry#id:\"}"
    selector_id="${remainder%%\",family:\"*}"
    remainder="${entry#*,family:\"}"
    group="${remainder%%\",display_name:\"*}"
    remainder="${entry#*,display_name:\"}"
    display_name="${remainder%\"}"
    jq -cn --arg selector "$selector_id" --arg label "$display_name" --arg group "$group" \
      '{selector:$selector,label:$label,description:$label,group:$group}' >> "$metadata" || return 1
  done < "$entries"
  jq -s '
    reduce .[] as $record ([];
      if any(.[]; .selector == $record.selector) then . else . + [$record] end
    )
  ' "$metadata" > "$output" || return 1
  rm -f "$entries" "$metadata"
  jq -e 'length > 0' "$output" >/dev/null
}

meridian_extract_host_enum_candidates() {
  local binary="$1" output="$2"
  LC_ALL=C grep -aoE '\["[A-Za-z0-9][A-Za-z0-9._:-]*"(,"[A-Za-z0-9][A-Za-z0-9._:-]*"){1,80}\]' "$binary" > "$output" 2>/dev/null || true
}

meridian_compose_model_catalog() {
  local records_path="$1" candidates_path="$2" output="$3" filter
  filter="$MERIDIAN_COMPOSE_LIB_DIR/compose-model-catalog.jq"
  # Candidates are file input, not argv, so host-sized catalogs stay under ARG_MAX.
  jq -Rs --slurpfile records "$records_path" -f "$filter" "$candidates_path" > "$output"
}

meridian_lookup_agent_model_id() {
  local composed="$1" selector="$2" mapped
  mapped=$(jq -r --arg selector "$selector" '
    if (.agent_model_ids | type == "object")
       and (.agent_model_ids[$selector] != null)
       and (.agent_model_ids[$selector] != "")
    then .agent_model_ids[$selector]
    elif ((.host_agent_enum | type) != "array" or (.host_agent_enum | length) == 0)
         and any(.models[]; .selector == $selector)
    then $selector
    else empty
    end
  ' "$composed") || return 1
  [ -n "$mapped" ] || return 1
  printf '%s\n' "$mapped"
}

meridian_alloc_catalog_temps() {
  local stem="${TMPDIR:-/tmp}/meridian-claude"
  HELP_TEMP=$(mktemp "$stem-help.XXXXXX") || fail 'could not create help temporary file'
  MODELS_TEMP=$(mktemp "$stem-models.XXXXXX") || fail 'could not create model temporary file'
  REASONING_TEMP=$(mktemp "$stem-reasoning.XXXXXX") || fail 'could not create reasoning temporary file'
  ASSOCIATIONS_TEMP=$(mktemp "$stem-model-associations.XXXXXX") || fail 'could not create model-association temporary file'
  HOST_ENUM_TEMP=$(mktemp "$stem-host-enum.XXXXXX") || fail 'could not create host-enum temporary file'
  COMPOSED_MODELS_TEMP=$(mktemp "$stem-composed-models.XXXXXX") || fail 'could not create composed-model temporary file'
}

meridian_write_catalog_envelope() {
  local binary="$1" version="$2" sha256="$3" output="$4" detected_at
  detected_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
  jq -S -n \
    --arg binary_path "$binary" \
    --arg version "$version" \
    --arg sha256 "$sha256" \
    --arg detected_at "$detected_at" \
    --slurpfile composed "$COMPOSED_MODELS_TEMP" \
    --slurpfile reasoning "$REASONING_TEMP" \
    --slurpfile associations "$ASSOCIATIONS_TEMP" \
    -f "$MERIDIAN_COMPOSE_LIB_DIR/capability-catalog.jq" > "$output"
}

meridian_build_catalog() {
  local binary="$1" output="$2" before after version
  meridian_alloc_catalog_temps
  before=$(sha256_file "$binary") || fail 'could not fingerprint Claude Code executable'
  version=$(extract_version "$binary") || return 1
  extract_help "$binary" "$HELP_TEMP" || return 1
  extract_model_records "$binary" "$MODELS_TEMP" || return 1
  meridian_extract_host_enum_candidates "$binary" "$HOST_ENUM_TEMP"
  meridian_compose_model_catalog "$MODELS_TEMP" "$HOST_ENUM_TEMP" "$COMPOSED_MODELS_TEMP" \
    || fail 'could not compose host Agent model catalog'
  extract_reasoning_values "$HELP_TEMP" "$REASONING_TEMP" || return 1
  extract_model_associations "$binary" "$ASSOCIATIONS_TEMP" || return 1
  after=$(sha256_file "$binary") || fail 'could not recheck Claude Code executable fingerprint'
  [ "$before" = "$after" ] || fail 'Claude Code executable changed during capability extraction'
  meridian_write_catalog_envelope "$binary" "$version" "$after" "$output" || return 1
  rm -f "$HELP_TEMP" "$MODELS_TEMP" "$REASONING_TEMP" "$ASSOCIATIONS_TEMP" "$HOST_ENUM_TEMP" "$COMPOSED_MODELS_TEMP"
}

meridian_map_agent_model_from_binary() {
  local binary="$1" selector="$2" records_path candidates_path composed_path mapped
  records_path=$(mktemp "${TMPDIR:-/tmp}/meridian-map-records.XXXXXX") || return 1
  candidates_path=$(mktemp "${TMPDIR:-/tmp}/meridian-map-enum.XXXXXX") || {
    rm -f "$records_path"
    return 1
  }
  composed_path=$(mktemp "${TMPDIR:-/tmp}/meridian-map-composed.XXXXXX") || {
    rm -f "$records_path" "$candidates_path"
    return 1
  }
  MODELS_TEMP="$records_path"
  HOST_ENUM_TEMP="$candidates_path"
  COMPOSED_MODELS_TEMP="$composed_path"
  meridian_extract_model_records "$binary" "$records_path" || {
    rm -f "$records_path" "$candidates_path" "$composed_path"
    return 1
  }
  meridian_extract_host_enum_candidates "$binary" "$candidates_path"
  meridian_compose_model_catalog "$records_path" "$candidates_path" "$composed_path" || {
    rm -f "$records_path" "$candidates_path" "$composed_path"
    return 1
  }
  mapped=$(meridian_lookup_agent_model_id "$composed_path" "$selector") || {
    rm -f "$records_path" "$candidates_path" "$composed_path"
    return 1
  }
  rm -f "$records_path" "$candidates_path" "$composed_path"
  printf '%s\n' "$mapped"
}

meridian_catalog_fingerprint_matches() {
  local catalog="$1" binary="$2" expected actual
  expected=$(jq -r '.source.sha256' "$catalog") || return 1
  actual=$(sha256_file "$binary") || return 1
  [ "$expected" = "$actual" ]
}

meridian_map_agent_model_via_catalog() {
  local catalog="$1" binary="$2" selector="$3"
  if meridian_catalog_fingerprint_matches "$catalog" "$binary"; then
    meridian_lookup_agent_model_id "$catalog" "$selector"
    return $?
  fi
  meridian_map_agent_model_from_binary "$binary" "$selector"
}

meridian_map_agent_model() {
  local source="$1" selector="$2" catalog_binary live_binary
  [ -n "$selector" ] || return 1
  if [ -f "$source" ] && jq -e '.schema_version == 1 and .source.sha256' "$source" >/dev/null 2>&1; then
    catalog_binary=$(jq -r '.source.binary_path' "$source") || return 1
    live_binary=""
    if [ -n "${CLAUDE_CODE_EXECPATH:-}" ]; then
      live_binary=$(resolve_claude_binary 2>/dev/null || true)
    fi
    if [ -n "$live_binary" ]; then
      meridian_map_agent_model_via_catalog "$source" "$live_binary" "$selector"
      return $?
    fi
    if [ -n "$catalog_binary" ] && [ -f "$catalog_binary" ] && [ -x "$catalog_binary" ]; then
      meridian_map_agent_model_via_catalog "$source" "$catalog_binary" "$selector"
      return $?
    fi
    return 1
  fi
  meridian_map_agent_model_from_binary "$source" "$selector"
}
