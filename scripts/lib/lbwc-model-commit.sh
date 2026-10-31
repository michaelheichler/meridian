COMMIT_CONFIG_TMP=""
COMMIT_CONFIG_BINDING=""
COMMIT_CATALOG_TMP=""
COMMIT_CATALOG_BINDING=""

stage_commit_config() {
  local binding
  cp "$PENDING_REFRESH/config.after" "$COMMIT_CONFIG_TMP" || { rm -f "$COMMIT_CONFIG_TMP" "$COMMIT_CATALOG_TMP"; fail 'could not prepare refreshed configuration'; }
  binding=$(image_binding "$COMMIT_CONFIG_TMP") \
    || fail 'could not bind refreshed configuration temporary file'
  printf -v COMMIT_CONFIG_BINDING '%s' "$binding"
  [ "${binding#*$'\t'}" = "$PENDING_CONFIG_AFTER_SHA" ] \
    || fail 'refreshed configuration temporary file changed'
}

stage_commit_catalog() {
  local binding
  cp "$PENDING_REFRESH/catalog.after" "$COMMIT_CATALOG_TMP" || { rm -f "$COMMIT_CONFIG_TMP" "$COMMIT_CATALOG_TMP"; fail 'could not prepare refreshed capability catalog'; }
  binding=$(image_binding "$COMMIT_CATALOG_TMP") \
    || fail 'could not bind refreshed catalog temporary file'
  printf -v COMMIT_CATALOG_BINDING '%s' "$binding"
  [ "${binding#*$'\t'}" = "$PENDING_CATALOG_AFTER_SHA" ] \
    || fail 'refreshed catalog temporary file changed'
}

persist_commit_images() {
  local planning_dir="$1"
  verify_image \
    "$COMMIT_CATALOG_TMP" \
    "${COMMIT_CATALOG_BINDING%%$'\t'*}" \
    "$PENDING_CATALOG_AFTER_SHA" \
    || fail 'refreshed catalog temporary file changed before commit'
  mv -f "$COMMIT_CATALOG_TMP" "$planning_dir/claude-capabilities.json" || { rm -f "$COMMIT_CONFIG_TMP" "$COMMIT_CATALOG_TMP"; fail 'could not persist refreshed capability catalog'; }
  verify_pending_after_images || fail 'published model refresh journal changed during commit'
  verify_image \
    "$COMMIT_CONFIG_TMP" \
    "${COMMIT_CONFIG_BINDING%%$'\t'*}" \
    "$PENDING_CONFIG_AFTER_SHA" \
    || fail 'refreshed configuration temporary file changed before commit'
  mv -f "$COMMIT_CONFIG_TMP" "$planning_dir/config.json" || { rm -f "$COMMIT_CONFIG_TMP"; fail 'could not persist refreshed configuration'; }
}

commit_pending_refresh() {
  local planning_dir="$1"
  [ -n "$PENDING_REFRESH" ] \
    && [ "$PENDING_REFRESH" = "$planning_dir/.lbwc-model-refresh.pending" ] \
    || fail 'model refresh journal is unavailable'
  COMMIT_CONFIG_TMP=$(mktemp "$planning_dir/.config.json.model-refresh.XXXXXX") \
    || fail 'could not create refreshed configuration temporary file'
  COMMIT_CATALOG_TMP=$(mktemp "$planning_dir/.claude-capabilities.json.model-refresh.XXXXXX") || {
    rm -f "$COMMIT_CONFIG_TMP"
    fail 'could not create refreshed catalog temporary file'
  }
  verify_pending_after_images || fail 'published model refresh journal changed before commit'
  stage_commit_config
  verify_pending_after_images || fail 'published model refresh journal changed before commit'
  stage_commit_catalog
  verify_pending_after_images || fail 'published model refresh journal changed before commit'
  persist_commit_images "$planning_dir"
  validate_state "$planning_dir"
  verify_pending_before_images || fail 'published model refresh journal changed after commit'
  verify_pending_after_images || fail 'published model refresh journal changed after commit'
  remove_refresh_directory \
    "$PENDING_REFRESH" \
    '.lbwc-model-refresh.pending' \
    "$PENDING_REFRESH_IDENTITY" \
    || fail 'could not remove completed model refresh journal'
  PENDING_REFRESH=""
  REFRESH_COMMITTED=1
}
