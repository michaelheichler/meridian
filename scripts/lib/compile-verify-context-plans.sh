resolve_plan_id() {
  local plan_file="$1" plan_id
  plan_id=$(awk '/^---$/{n++; next} n==1 && /^plan:/{v=$2; gsub(/^["'"'"']|["'"'"']$/, "", v); print v; exit}' "$plan_file" 2>/dev/null) || plan_id=""
  if [ -z "$plan_id" ]; then
    case "$(basename "$plan_file")" in
      R*-PLAN.md) plan_id="$(basename "$plan_file" | sed 's/-PLAN\.md$//')" ;;
      *)
        plan_id=$(awk '/^---$/{n++; next} n==1 && /^round:/{v=$2; gsub(/^["'"'"']|["'"'"']$/, "", v); print "R" v; exit}' "$plan_file" 2>/dev/null) || plan_id=""
        ;;
    esac
  fi
  printf '%s' "$plan_id"
}

extract_must_haves() {
  local plan_file="$1"
  awk '
    BEGIN { in_front=0; in_mh=0; in_sub=0 }
    /^---$/ { if (in_front==0) { in_front=1; next } else { exit } }
    in_front && /^must_haves:/ { in_mh=1; next }
    in_front && in_mh && /^[[:space:]]+truths:/ { in_sub=1; next }
    in_front && in_mh && /^[[:space:]]+artifacts:/ { in_sub=1; next }
    in_front && in_mh && /^[[:space:]]+key_links:/ { in_sub=1; next }
    in_front && in_mh && in_sub && /^[[:space:]]+- / {
      line = $0
      sub(/^[[:space:]]+- /, "", line)
      gsub(/^"/, "", line); gsub(/"$/, "", line)
      items = items (items ? "; " : "") line
      next
    }
    in_front && in_mh && !in_sub && /^[[:space:]]+- / {
      line = $0
      sub(/^[[:space:]]+- /, "", line)
      gsub(/^"/, "", line); gsub(/"$/, "", line)
      items = items (items ? "; " : "") line
      next
    }
    in_front && in_mh && /^[^[:space:]]/ && !/^[[:space:]]+/ { exit }
    END { print items }
  ' "$plan_file" 2>/dev/null
}

resolve_summary_file() {
  local plan_file="$1" plan_base plan_dir
  plan_base=$(basename "$plan_file" | sed 's/-PLAN\.md$//')
  plan_dir=$(dirname "$plan_file")
  if [ "$(basename "$plan_file")" = "PLAN.md" ] && [ -f "$plan_dir/SUMMARY.md" ]; then
    printf '%s' "$plan_dir/SUMMARY.md"
  elif [[ "$plan_dir" == */round-* ]] && [[ "$plan_base" =~ ^R[0-9][0-9](-.*)?$ ]]; then
    local round_summary_base
    round_summary_base=$(printf '%s' "$plan_base" | sed 's/^\(R[0-9][0-9]\).*/\1/')
    printf '%s' "$plan_dir/${round_summary_base}-SUMMARY.md"
  else
    find "$plan_dir" -maxdepth 1 ! -name '.*' -name "${plan_base}-SUMMARY.md" 2>/dev/null | head -1
  fi
}

extract_what_built() {
  local summary_file="$1" what_built
  what_built=$(awk '
    /^## What Was Built/ { found=1; count=0; next }
    found && /^## / { exit }
    found && /^[[:space:]]*$/ { next }
    found { count++; if (count <= 5) print; if (count >= 5) exit }
  ' "$summary_file" 2>/dev/null) || what_built=""
  if [ -z "$what_built" ]; then
    what_built=$(awk '
      /^### What Was Built/ { found=1; next }
      found && /^### / { found=0; next }
      found && /^## / { found=0; next }
      found && /^[[:space:]]*$/ { next }
      found {
        count++
        if (count <= 5) print
      }
    ' "$summary_file" 2>/dev/null) || what_built=""
  fi
  printf '%s' "$what_built"
}

extract_files_modified() {
  local summary_file="$1" files_modified
  files_modified=$(extract_frontmatter_array_items "$summary_file" files_modified | awk '
    {
      files = files (files ? ", " : "") $0
    }
    END { print files }
  ' 2>/dev/null) || files_modified=""
  if [ -z "$files_modified" ]; then
    files_modified=$(awk '
      /^## Files Modified/ { found=1; next }
      found && /^## / { exit }
      found && /^[[:space:]]*$/ { next }
      found && /^- / {
        line = $0
        sub(/^- /, "", line)
        if (index(line, " -- ") > 0) {
          line = substr(line, 1, index(line, " -- ") - 1)
        }
        gsub(/`/, "", line)
        files = files (files ? ", " : "") line
      }
      END { print files }
    ' "$summary_file" 2>/dev/null) || files_modified=""
  fi
  printf '%s' "$files_modified"
}

emit_pre_existing_line() {
  local item="$1" issue_test issue_file issue_error
  [ -n "$item" ] || return 0
  if ! printf '%s' "$item" | jq -e '
    type == "object"
    and (.test | type == "string")
    and (.file | type == "string")
    and (.error | type == "string")
  ' >/dev/null 2>&1; then
    return 0
  fi
  issue_test=$(printf '%s' "$item" | jq -r '.test')
  issue_file=$(printf '%s' "$item" | jq -r '.file')
  issue_error=$(printf '%s' "$item" | jq -r '.error')
  if [ "$issue_file" = "$issue_test" ]; then
    printf '%s: %s\n' "$issue_test" "$issue_error"
  else
    printf '%s (%s): %s\n' "$issue_test" "$issue_file" "$issue_error"
  fi
}

pre_existing_from_frontmatter() {
  extract_frontmatter_array_items "$1" pre_existing_issues | while IFS= read -r item; do
    emit_pre_existing_line "$item"
  done | awk '
    {
      items = items (items ? "; " : "") $0
    }
    END { print items }
  ' 2>/dev/null
}

pre_existing_from_section() {
  awk '
    /^## Pre-existing Issues/ { found=1; next }
    found && /^## / { exit }
    found && /^[[:space:]]*$/ { next }
    found && /^- / {
      line = $0
      sub(/^- /, "", line)
      items = items (items ? "; " : "") line
    }
    END { print items }
  ' "$1" 2>/dev/null
}

extract_pre_existing_issues() {
  local summary_file="$1" pre_existing
  pre_existing=$(pre_existing_from_frontmatter "$summary_file") || pre_existing=""

  if [ -z "$pre_existing" ] && ! frontmatter_key_present "$summary_file" pre_existing_issues; then
    pre_existing=$(pre_existing_from_section "$summary_file") || pre_existing=""
  fi
  printf '%s' "$pre_existing"
}

deviation_accepted() {
  local deviation="$1" source_plan="$2" summary_rel_path="$3"
  local candidate_source_plans candidate_source_plan candidate_signature

  [ -n "$ACCEPTED_DEVIATION_SIGNATURES" ] || return 1
  candidate_source_plans="$source_plan"
  if type summary_deviation_source_plan_candidates >/dev/null 2>&1; then
    candidate_source_plans=$(summary_deviation_source_plan_candidates "$SUMMARY_FILE" 2>/dev/null || true)
    candidate_source_plans="${candidate_source_plans:-$source_plan}"
  fi
  while IFS= read -r candidate_source_plan; do
    [ -n "$candidate_source_plan" ] || continue
    candidate_signature=$(bash "$TRACK_UAT_DEVIATIONS_SCRIPT" signature "$candidate_source_plan" "$summary_rel_path" "$deviation" 2>/dev/null || true)
    [ -n "$candidate_signature" ] || break
    if printf '%s\n' "$ACCEPTED_DEVIATION_SIGNATURES" | grep -Fx -- "$candidate_signature" >/dev/null 2>&1; then
      return 0
    fi
  done <<< "$candidate_source_plans"
  return 1
}

record_summary_deviation() {
  local deviation="$1" source_plan="$2" summary_rel_path="$3"
  local signature safe_plan safe_path safe_text

  signature=$(bash "$TRACK_UAT_DEVIATIONS_SCRIPT" signature "$source_plan" "$summary_rel_path" "$deviation" 2>/dev/null || true)
  [ -n "$signature" ] || return 0

  if deviation_accepted "$deviation" "$source_plan" "$summary_rel_path"; then
    return 0
  fi

  if [ -n "$EMITTED_SUMMARY_DEVIATION_SIGNATURES" ] && printf '%s\n' "$EMITTED_SUMMARY_DEVIATION_SIGNATURES" | grep -Fx -- "$signature" >/dev/null 2>&1; then
    return 0
  fi
  if [ -n "$EMITTED_SUMMARY_DEVIATION_SIGNATURES" ]; then
    EMITTED_SUMMARY_DEVIATION_SIGNATURES="${EMITTED_SUMMARY_DEVIATION_SIGNATURES}"$'\n'
  fi
  EMITTED_SUMMARY_DEVIATION_SIGNATURES="${EMITTED_SUMMARY_DEVIATION_SIGNATURES}${signature}"

  safe_plan=$(sanitize_summary_deviation_context_field "$source_plan")
  safe_path=$(sanitize_summary_deviation_context_field "$summary_rel_path")
  safe_text=$(sanitize_summary_deviation_context_field "$deviation")
  if [ -n "$SUMMARY_DEVIATION_RECORDS" ]; then
    SUMMARY_DEVIATION_RECORDS="${SUMMARY_DEVIATION_RECORDS}"$'\n'
  fi
  SUMMARY_DEVIATION_RECORDS="${SUMMARY_DEVIATION_RECORDS}SUMMARY_DEVIATION: signature=${signature} | source_plan=${safe_plan} | source_path=${safe_path} | text=${safe_text}"
}

collect_summary_deviations() {
  local plan_id="$1"
  [ -n "$SUMMARY_DEVIATIONS" ] && [ -x "$TRACK_UAT_DEVIATIONS_SCRIPT" ] || return 0
  local summary_rel_path source_plan deviation
  summary_rel_path="${SUMMARY_FILE#"$PHASE_DIR/"}"
  while IFS= read -r deviation; do
    [ -n "$deviation" ] || continue
    source_plan="${plan_id:-unknown}"
    if type summary_deviation_canonical_source_plan >/dev/null 2>&1; then
      source_plan=$(summary_deviation_canonical_source_plan "$SUMMARY_FILE" 2>/dev/null || true)
      source_plan="${source_plan:-unknown}"
    fi
    record_summary_deviation "$deviation" "$source_plan" "$summary_rel_path"
  done <<< "$SUMMARY_DEVIATIONS"
}

read_summary_fields() {
  local summary_file="$1"
  STATUS=$(awk '
    BEGIN { in_fm=0 }
    NR==1 && /^---[[:space:]]*$/ { in_fm=1; next }
    in_fm && /^---[[:space:]]*$/ { exit }
    in_fm && /^status:/ { sub(/^status:[[:space:]]*/, ""); print; exit }
  ' "$summary_file" 2>/dev/null) || STATUS="unknown"

  FILES_MODIFIED=$(extract_files_modified "$summary_file")
  WHAT_BUILT=$(extract_what_built "$summary_file")

  SUMMARY_DEVIATIONS=""
  DEVIATIONS=""
  if type extract_summary_deviations >/dev/null 2>&1; then
    SUMMARY_DEVIATIONS=$(extract_summary_deviations "$summary_file" 2>/dev/null || true)
    DEVIATIONS=$(printf '%s\n' "$SUMMARY_DEVIATIONS" | awk 'NF { items = items (items ? "; " : "") $0 } END { print items }')
  fi

  PRE_EXISTING=$(extract_pre_existing_issues "$summary_file")
}

print_plan_record() {
  local plan_id="$1" title="$2" must_haves="$3"

  echo "=== PLAN ${plan_id}: ${title} ==="
  echo "must_haves: ${must_haves:-none}"
  if [ -n "$WHAT_BUILT" ]; then
    echo "what_was_built:"
    echo "$WHAT_BUILT" | sed 's/^/  /'
  else
    echo "what_was_built: none"
  fi
  echo "files_modified: ${FILES_MODIFIED:-none}"
  echo "status: ${STATUS}"
  echo "deviations: ${DEVIATIONS:-none}"
  if [ -n "$SUMMARY_DEVIATION_RECORDS" ]; then
    printf '%s\n' "$SUMMARY_DEVIATION_RECORDS"
  else
    echo "summary_deviation_reviews: none"
  fi
  echo "pre_existing_issues: ${PRE_EXISTING:-none}"
  echo ""
}

process_plan_file() {
  local plan_file="$1"
  local plan_id title must_haves

  plan_id=$(resolve_plan_id "$plan_file")
  title=$(awk '/^---$/{n++; next} n==1 && /^title:/{sub(/^title: */, ""); gsub(/^["'"'"']|["'"'"']$/, ""); print; exit}' "$plan_file" 2>/dev/null) || title=""
  must_haves=$(extract_must_haves "$plan_file")

  SUMMARY_FILE=$(resolve_summary_file "$plan_file")
  STATUS="no_summary"
  WHAT_BUILT=""
  FILES_MODIFIED=""
  DEVIATIONS=""
  PRE_EXISTING=""
  SUMMARY_DEVIATIONS=""
  SUMMARY_DEVIATION_RECORDS=""

  if [ -n "$SUMMARY_FILE" ] && [ -f "$SUMMARY_FILE" ]; then
    read_summary_fields "$SUMMARY_FILE"
    collect_summary_deviations "$plan_id"
  fi

  print_plan_record "$plan_id" "$title" "$must_haves"
}
