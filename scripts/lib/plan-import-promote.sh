# Plain assignments, because bash 3.2 has no declare -g.
PROMOTE_ROOT="" PROMOTE_BACKUP="" PROMOTE_MANIFEST_DIR=""
PROMOTE_IMPORTS_PARENT="" PROMOTE_PLANNING_DIR=""
PROMOTE_IMPORTS_EXISTED=false PROMOTE_PLANNING_EXISTED=false

safe_artifact() {
  local artifact="$1"
  [[ "$artifact" != /* && "$artifact" != ../* && "$artifact" != */../* && "$artifact" != */.. && "$artifact" != *"//"* ]] || return 1
  case "$artifact" in
    .meridian/config.json)
      return 0
      ;;
  esac
  [[ "$artifact" == *.md ]] || return 1
  case "$artifact" in
    .meridian/PROJECT.md|.meridian/REQUIREMENTS.md|.meridian/ROADMAP.md|.meridian/STATE.md|.meridian/phases/*.md|.meridian/imported-markdown/*.md)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

assert_no_symlink_components() {
  local project_root="$1" artifact="$2" current="$project_root" component
  local -a components
  IFS='/' read -r -a components <<< "$artifact"
  for component in "${components[@]}"; do
    current="$current/$component"
    [ ! -e "$current" ] && continue
    [ ! -L "$current" ] || import_fail "canonical destination contains a symbolic link: $artifact"
  done
}

artifact_key() {
  printf '%s' "$1" | tr '/' '__'
}

rollback_promote() {
  local rollback_artifact rollback_destination rollback_key
  for rollback_artifact in "${ARTIFACTS[@]}"; do
    rollback_destination="$PROMOTE_ROOT/$rollback_artifact"
    rollback_key=$(artifact_key "$rollback_artifact")
    rm -f "$(dirname "$rollback_destination")/.$(basename "$rollback_destination").import.$$"
    if [ "$(cat "$PROMOTE_BACKUP/$rollback_key.state")" = present ]; then
      cp -p "$PROMOTE_BACKUP/$rollback_key" "$rollback_destination"
    else
      rm -f "$rollback_destination"
    fi
  done
  rm -rf "$PROMOTE_MANIFEST_DIR"
  if [ "$PROMOTE_IMPORTS_EXISTED" = false ]; then
    rmdir "$PROMOTE_IMPORTS_PARENT" 2>/dev/null || true
  fi
  if [ "$PROMOTE_PLANNING_EXISTED" = false ]; then
    rmdir "$PROMOTE_PLANNING_DIR" 2>/dev/null || true
  fi
}

promote_check_source() {
  local stage="$1" ir_file="$2" staged_source_path staged_digest
  staged_source_path=$(jq -r '.source.source_path // empty' "$stage/manifest.json" 2>/dev/null || true)
  staged_digest=$(jq -r '.source.digest' "$ir_file")
  if [ -n "$staged_source_path" ]; then
    import_source_metadata "$(canonical_source "$staged_source_path")"
    [ "$SOURCE_DIGEST" = "$staged_digest" ] || import_fail "source changed after staging; cancel and re-stage"
  fi
}

promote_backup_artifacts() {
  local tree="$1" artifact destination key
  for artifact in "${ARTIFACTS[@]}"; do
    safe_artifact "$artifact" || import_fail "invalid promotion artifact: $artifact"
    destination="$PROMOTE_ROOT/$artifact"
    [ -f "$tree/$artifact" ] || import_fail "staged artifact is missing: $artifact"
    assert_no_symlink_components "$PROMOTE_ROOT" "$artifact"
    mkdir -p "$(dirname "$destination")"
    key=$(artifact_key "$artifact")
    if [ -e "$destination" ]; then
      [ ! -L "$destination" ] || import_fail "canonical destination is a symbolic link: $artifact"
      cp -p "$destination" "$PROMOTE_BACKUP/$key"
      printf '%s\n' present > "$PROMOTE_BACKUP/$key.state"
    else
      printf '%s\n' absent > "$PROMOTE_BACKUP/$key.state"
    fi
  done
}

promote_copy_artifacts() {
  local tree="$1" artifact destination destination_tmp count=0
  for artifact in "${ARTIFACTS[@]}"; do
    destination="$PROMOTE_ROOT/$artifact"
    destination_tmp="$(dirname "$destination")/.$(basename "$destination").import.$$"
    if ! cp -p "$tree/$artifact" "$destination_tmp" || ! mv -f "$destination_tmp" "$destination"; then
      rm -f "$destination_tmp"
      rollback_promote
      import_fail "promotion failed at artifact $artifact; rollback restored canonical artifacts"
    fi
    count=$((count + 1))
    if [ "$FAIL_AFTER" -gt 0 ] && [ "$count" -ge "$FAIL_AFTER" ]; then
      rollback_promote
      import_fail "promotion failed after artifact $artifact; rollback restored canonical artifacts"
    fi
  done
}

promote_write_provenance() {
  local stage="$1" ir_file="$2" provenance_tmp
  PROMOTE_MANIFEST_DIR="$PROMOTE_IMPORTS_PARENT/$(basename "$stage")"
  provenance_tmp="$stage/.provenance-tmp.$$"
  rm -rf "$provenance_tmp"
  if ! mkdir -p "$provenance_tmp" \
    || ! cp -p "$ir_file" "$provenance_tmp/ir.json" \
    || ! cp -p "$stage/preview.json" "$provenance_tmp/preview.json" \
    || ! jq --arg status promoted '.status = $status' "$stage/manifest.json" > "$provenance_tmp/manifest.json"; then
    rm -rf "$provenance_tmp"
    rollback_promote
    import_fail "promotion provenance preparation failed; rollback restored canonical artifacts"
  fi
  mkdir -p "$PROMOTE_IMPORTS_PARENT"
  rm -rf "$PROMOTE_MANIFEST_DIR"
  if ! mv "$provenance_tmp" "$PROMOTE_MANIFEST_DIR"; then
    rm -rf "$provenance_tmp"
    rollback_promote
    import_fail "promotion provenance persistence failed; rollback restored canonical artifacts"
  fi
}

promote_validation_failure() {
  local validation_output
  if [ "$FAIL_VALIDATION" = 1 ]; then
    printf '%s' "post-promotion validation failed: forced validation failure"
  elif ! printf '%s\n' "${ARTIFACTS[@]}" | grep -qx '.meridian/config.json'; then
    printf '%s' "post-promotion validation failed: canonical artifact .meridian/config.json was not selected for promotion"
  elif ! validation_output=$(MERIDIAN_PLANNING_DIR="$PROMOTE_PLANNING_DIR" "$SCRIPT_DIR/meridian-config.sh" validate-config-json < "$PROMOTE_PLANNING_DIR/config.json" 2>&1); then
    printf '%s' "post-promotion validation failed: meridian-config.sh validate-config-json: $validation_output"
  elif ! validation_output=$(CDPATH='' cd -- "$PROMOTE_ROOT" && MERIDIAN_PLANNING_DIR="$PROMOTE_PLANNING_DIR" bash "$SCRIPT_DIR/verify-state-consistency.sh" 2>&1); then
    printf '%s' "post-promotion validation failed: verify-state-consistency.sh: $validation_output"
  fi
}

promote_finish() {
  local failure
  failure=$(promote_validation_failure)
  if [ -n "$failure" ]; then
    rollback_promote
    import_fail "$failure; rollback restored canonical artifacts and removed provenance"
  fi
  jq -n --arg status promoted --argjson artifacts "$(printf '%s\n' "${ARTIFACTS[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
    '{status:$status,artifacts:$artifacts}'
}

promote_import() {
  local project_root="$1" stage="$2" tree ir_file
  PROMOTE_ROOT=$(canonical_directory "$project_root")
  stage=$(canonical_directory "$stage")
  validate_stage "$PROMOTE_ROOT" "$stage" >/dev/null
  tree="$stage/tree"
  ir_file="$stage/ir.json"
  [ "${#ARTIFACTS[@]}" -gt 0 ] || import_fail 'promotion requires explicit --artifact input'
  promote_check_source "$stage" "$ir_file"
  PROMOTE_PLANNING_DIR="$PROMOTE_ROOT/.meridian"
  PROMOTE_IMPORTS_PARENT="$PROMOTE_PLANNING_DIR/imports"
  PROMOTE_IMPORTS_EXISTED=false
  PROMOTE_PLANNING_EXISTED=false
  [ -d "$PROMOTE_IMPORTS_PARENT" ] && PROMOTE_IMPORTS_EXISTED=true
  [ -d "$PROMOTE_PLANNING_DIR" ] && PROMOTE_PLANNING_EXISTED=true
  PROMOTE_BACKUP="$stage/rollback"
  rm -rf "$PROMOTE_BACKUP"
  mkdir -p "$PROMOTE_BACKUP"
  promote_backup_artifacts "$tree"
  promote_copy_artifacts "$tree"
  promote_write_provenance "$stage" "$ir_file"
  promote_finish
}
