requirements_conflict_detail() {
  local ir="$1" file="$2" existing
  existing=$(jq -c -R -s '
    [split("\n")[] | select(test("^- \\[[xX ]\\] \\*\\*")) | (match("^- \\[(?<mark>[xX ])\\] \\*\\*(?<id>[^*]+)\\*\\*").captures | map({key: .name, value: .string}) | from_entries) | {key: .id, value: {id: .id, status: (if .mark == "x" or .mark == "X" then "complete" else "pending" end)}}] | from_entries | [.[]]' "$file" 2>/dev/null || printf '[]')
  jq -c --argjson existing "${existing:-[]}" '
    [.requirements[] | {id, status: (.status // "pending")}] as $imported
    | {removed_ids: ([$existing[] | .id] - [$imported[] | .id]),
       changed_statuses: [$imported[] | . as $p | ($existing[] | select(.id == $p.id)) as $e | select($e != null and $e.status != $p.status) | {id: $p.id, status: $p.status}]}' "$ir" 2>/dev/null || printf '{}'
}

conflict_detail() {
  local ir="$1" relative="$2" project_root="$3"
  case "$relative" in
    .lbwc-planning/REQUIREMENTS.md)
      requirements_conflict_detail "$ir" "$project_root/$relative"
      ;;
    .lbwc-planning/ROADMAP.md)
      jq -c '{imported_phases: [.phases[] | select(.number != null) | .number]}' "$ir" 2>/dev/null || printf '{}'
      ;;
  esac
}

semantic_conflicts() {
  local ir="$1" tree="$2" project_root="$3" conflicts='[]' path relative source_digest destination_digest status_detail
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    relative="${path#"$tree/"}"
    [ -f "$project_root/$relative" ] || continue
    source_digest=$(import_sha256 "$path") || import_fail "could not digest staged artifact: $relative"
    destination_digest=$(import_sha256 "$project_root/$relative") || import_fail "could not digest canonical artifact: $relative"
    [ "$source_digest" = "$destination_digest" ] && continue
    status_detail=$(conflict_detail "$ir" "$relative" "$project_root")
    [ -n "$status_detail" ] || status_detail='{}'
    conflicts=$(jq -c --arg artifact "$relative" --arg source_digest "$source_digest" --arg destination_digest "$destination_digest" --argjson detail "$status_detail" \
      '. + [{artifact:$artifact, source_digest:$source_digest, destination_digest:$destination_digest, detail:$detail}]' <<< "$conflicts")
  done < <(find "$tree" -type f -print 2>/dev/null | LC_ALL=C sort)
  printf '%s\n' "$conflicts"
}

preview_json() {
  local ir="$1" project_root="$2" import_id="$3" tree="$4" existing='[]' additions='[]' path destination conflicts
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    destination="${path#"$tree/"}"
    if [ -e "$project_root/$destination" ]; then
      existing=$(jq -c --arg path "$destination" '. + [$path]' <<< "$existing")
    else
      additions=$(jq -c --arg path "$destination" '. + [$path]' <<< "$additions")
    fi
  done < <(find "$tree" -type f -print 2>/dev/null | LC_ALL=C sort)
  conflicts=$(semantic_conflicts "$ir" "$tree" "$project_root")
  jq -n --argjson source "$(cat "$ir")" --arg id "$import_id" --arg tree "$tree" \
    --argjson additions "$additions" --argjson overlaps "$existing" --argjson conflicts "$conflicts" \
    '{schema_version:1,import_id:$id,source:$source.source,proposed_destination:".lbwc-planning/",additions:$additions,overlaps:$overlaps,conflicts:$conflicts,unknowns:($source.warnings + [($source.plans[] | select(.status == null) | .source_path)]),skipped:($source.source.skipped_files // []),staged_tree:$tree}'
}

stage_import() {
  local adapter="$1" source="$2" project_root="$3" import_id="$4" run_root ir_file tree preview manifest
  project_root=$(canonical_directory "$project_root")
  valid_import_id "$import_id" || import_fail "invalid import id: $import_id"
  run_root="$project_root/.temporary-agent-runfiles/imports/$import_id"
  [ ! -e "$run_root" ] || import_fail "import staging directory already exists: $run_root"
  mkdir -p "$run_root"
  ir_file="$run_root/ir.json"
  tree="$run_root/tree"
  normalize_source "$adapter" "$source" "$ir_file"
  render_tree "$ir_file" "$tree"
  preview=$(preview_json "$ir_file" "$project_root" "$import_id" "$tree")
  printf '%s\n' "$preview" > "$run_root/preview.json"
  manifest=$(jq -n --arg id "$import_id" --arg digest "$(jq -r '.source.digest' "$ir_file")" --arg adapter "$adapter" \
    --arg source_path "$source" --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema_version:1,import_id:$id,adapter:$adapter,source_digest:$digest,source:{source_path:$source_path},created_at:$created_at,status:"staged"}')
  printf '%s\n' "$manifest" > "$run_root/manifest.json"
  jq -n --arg stage "$run_root" --argjson preview "$preview" '{stage:$stage,preview:$preview}'
}

check_staged_tree() {
  local tree="$1" expected path
  for expected in PROJECT.md REQUIREMENTS.md ROADMAP.md STATE.md config.json; do
    [ -f "$tree/.lbwc-planning/$expected" ] || import_fail "staged canonical artifact is missing: $expected"
  done
  "$SCRIPT_DIR/lbwc-config.sh" validate-config-json < "$tree/.lbwc-planning/config.json" >/dev/null \
    || import_fail 'staged canonical configuration is invalid'
  while IFS= read -r path; do
    [ ! -L "$path" ] || import_fail "staged tree contains a symbolic link: $path"
  done < <(find "$tree" -print 2>/dev/null)
}

validate_stage() {
  local project_root="$1" stage="$2" ir_file tree
  project_root=$(canonical_directory "$project_root")
  stage=$(canonical_directory "$stage")
  tree="$stage/tree"
  ir_file="$stage/ir.json"
  [ "$stage" = "$project_root/.temporary-agent-runfiles/imports/$(basename "$stage")" ] || import_fail 'stage is outside the project import staging directory'
  [ -f "$ir_file" ] || import_fail 'staged IR is missing'
  [ -d "$tree/.lbwc-planning" ] || import_fail 'staged canonical tree is missing'
  validate_ir "$ir_file"
  check_staged_tree "$tree"
  jq -n --arg stage "$stage" --argjson additions "$(jq '.additions' "$stage/preview.json")" \
    --argjson overlaps "$(jq '.overlaps' "$stage/preview.json")" \
    --argjson conflicts "$(jq '.conflicts // []' "$stage/preview.json")" \
    --argjson unknowns "$(jq '.unknowns' "$stage/preview.json")" \
    --argjson skipped "$(jq '.skipped' "$stage/preview.json")" \
    '{status:"valid",stage:$stage,complete:true,additions:$additions,overlaps:$overlaps,conflicts:$conflicts,unknowns:$unknowns,skipped:$skipped}'
}

find_manifest_by_digest() {
  local base="$1" manifest
  [ -d "$base" ] || return 0
  while IFS= read -r manifest; do
    [ -n "$manifest" ] || continue
    if [ "$(jq -r '.source_digest // empty' "$manifest" 2>/dev/null || true)" = "$SOURCE_DIGEST" ]; then
      printf '%s\n' "$manifest"
      return 0
    fi
  done < <(find "$base" -type f -name manifest.json -print 2>/dev/null | LC_ALL=C sort)
  return 0
}

reimport_status() {
  local source="$1" project_root="$2" found=''
  project_root=$(canonical_directory "$project_root")
  source=$(canonical_source "$source")
  import_source_metadata "$source"
  found=$(find_manifest_by_digest "$project_root/.lbwc-planning/imports")
  if [ -z "$found" ]; then
    found=$(find_manifest_by_digest "$project_root/.temporary-agent-runfiles/imports")
  fi
  if [ -n "$found" ]; then
    jq -n --arg digest "$SOURCE_DIGEST" --arg id "$(jq -r '.import_id' "$found")" '{status:"unchanged",source_digest:$digest,previous_import_id:$id}'
  else
    jq -n --arg digest "$SOURCE_DIGEST" '{status:"changed-or-new",source_digest:$digest,previous_import_id:null}'
  fi
}
