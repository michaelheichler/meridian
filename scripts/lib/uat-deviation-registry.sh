deviation_signature() {
  local source_plan source_path text
  source_plan=$(trim_value "${1:-}")
  source_path=$(trim_value "${2:-}")
  text=$(trim_value "${3:-}")
  [ -n "$source_plan" ] || { echo "track-uat-deviations: source plan is required" >&2; exit 1; }
  [ -n "$source_path" ] || { echo "track-uat-deviations: source path is required" >&2; exit 1; }
  [ -n "$text" ] || { echo "track-uat-deviations: deviation text is required" >&2; exit 1; }
  printf '%s\n%s\n%s\n' "$source_plan" "$source_path" "$text" | sha256_text
}

registry_path() {
  local phase_dir="${1:-}"
  [ -n "$phase_dir" ] || { echo "track-uat-deviations: phase dir is required" >&2; exit 1; }
  printf '%s/remediation/uat/accepted-deviations.json\n' "${phase_dir%/}"
}

require_jq_for_registry() {
  local message="${1:-jq not available; accepted deviation registry operation skipped}"
  if command -v jq >/dev/null 2>&1; then
    return 0
  fi
  echo "track-uat-deviations: jq not available; $message" >&2
  return 1
}

emit_accepted_deviation_record() {
  local signature="$1"
  local source_plan="$2"
  local source_path="$3"
  local text="$4"
  local accepted_in="$5"
  local accepted_at="$6"
  jq -cn \
    --arg signature "$signature" \
    --arg source_plan "$source_plan" \
    --arg source_path "$source_path" \
    --arg text "$text" \
    --arg accepted_in "$accepted_in" \
    --arg accepted_at "$accepted_at" \
    '{signature:$signature,source_plan:$source_plan,source_path:$source_path,text:$text,disposition:"accepted-process-exception",accepted_in:$accepted_in,accepted_at:$accepted_at}'
}

append_accepted_deviation_record_if_complete() {
  local output_file="$1"
  local in_d="$2"
  local signature="$3"
  local source_plan="$4"
  local source_path="$5"
  local text="$6"
  local result="$7"
  local disposition="$8"
  local accepted_in="$9"
  local accepted_at="${10}"

  if [ "$in_d" = true ] && [ -n "$signature" ] && [ "$result" = "pass" ] && [ "$disposition" = "accepted-process-exception" ]; then
    emit_accepted_deviation_record "$signature" "$source_plan" "$source_path" "$text" "$accepted_in" "$accepted_at" >> "$output_file"
  fi
}

accepted_signatures() {
  local phase_dir registry
  phase_dir="${1:-}"
  registry=$(registry_path "$phase_dir")
  [ -f "$registry" ] || return 0
  require_jq_for_registry "cannot read accepted deviation registry; continuing without accepted signatures" || return 0
  jq -r '.accepted[]?.signature // empty' "$registry" 2>/dev/null || true
}

flush_deviation_record() {
  append_accepted_deviation_record_if_complete "$1" "$2" "$TODO_UAT_SIGNATURE" "$TODO_UAT_SOURCE_PLAN" "$TODO_UAT_SOURCE_PATH" "$TODO_UAT_DEVIATION" "$TODO_UAT_RESULT" "$TODO_UAT_DISPOSITION" "$3" "$4"
}

scan_uat_deviations() {
  local uat_file="$1" tmp_records="$2" uat_rel="$3" now="$4"
  local line in_d=false

  reset_uat_deviation_fields
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    if [[ "$line" == "### "* ]]; then
      flush_deviation_record "$tmp_records" "$in_d" "$uat_rel" "$now"
      if [[ "$line" =~ ^###[[:space:]]D[0-9]+(:|[[:space:]]) ]]; then
        in_d=true
      else
        in_d=false
      fi
      reset_uat_deviation_fields
      continue
    fi

    if [ "$in_d" = true ]; then
      capture_uat_deviation_field "$line"
    fi
  done < "$uat_file"
  flush_deviation_record "$tmp_records" "$in_d" "$uat_rel" "$now"
}

merge_deviation_registry() {
  local registry="$1" phase_name="$2" tmp_records="$3" tmp_registry="$4"
  if [ -f "$registry" ] && jq -e 'type == "object"' "$registry" >/dev/null 2>&1; then
    jq -s --arg phase "$phase_name" '
      .[0] as $registry
      | .[1:] as $new
      | {
          schema_version: 1,
          phase: ($registry.phase // $phase),
          accepted: (((($registry.accepted // []) + $new) | unique_by(.signature)) | sort_by(.source_plan, .source_path, .signature))
        }
    ' "$registry" "$tmp_records" > "$tmp_registry"
  else
    jq -s --arg phase "$phase_name" '{schema_version: 1, phase: $phase, accepted: (.|unique_by(.signature)|sort_by(.source_plan, .source_path, .signature))}' "$tmp_records" > "$tmp_registry"
  fi
  mv "$tmp_registry" "$registry"
}

record_from_uat() {
  local phase_dir uat_file registry registry_dir tmp_records tmp_registry now
  phase_dir="${1:-}"
  uat_file="${2:-}"
  [ -d "$phase_dir" ] || { echo "track-uat-deviations: phase dir not found: $phase_dir" >&2; exit 1; }
  [ -f "$uat_file" ] || { echo "track-uat-deviations: UAT file not found: $uat_file" >&2; exit 1; }
  require_jq_for_registry "skipping accepted deviation registry sync; UAT result remains valid" || return 0
  registry=$(registry_path "$phase_dir")
  registry_dir=$(dirname "$registry")
  mkdir -p "$registry_dir"
  tmp_records=$(mktemp "${TMPDIR:-/tmp}/meridian-accepted-deviations.XXXXXX")
  tmp_registry=$(mktemp "${TMPDIR:-/tmp}/meridian-accepted-registry.XXXXXX")
  _TRACK_TMP_RECORDS="$tmp_records"
  _TRACK_TMP_REGISTRY="$tmp_registry"
  trap 'rm -f "${_TRACK_TMP_RECORDS:-}" "${_TRACK_TMP_REGISTRY:-}"' EXIT
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  scan_uat_deviations "$uat_file" "$tmp_records" "${uat_file#"$phase_dir/"}" "$now"

  [ -s "$tmp_records" ] || return 0
  merge_deviation_registry "$registry" "$(basename "$phase_dir")" "$tmp_records" "$tmp_registry"
}
