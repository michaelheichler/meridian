RESTORE_CONFIG_TMP=""
RESTORE_CONFIG_BINDING=""
RESTORE_CATALOG_TMP=""
RESTORE_CATALOG_BINDING=""

stage_config_restore() {
  local scratch binding
  scratch=$(mktemp "$1/.config.json.restore.XXXXXX") || return 1
  printf -v RESTORE_CONFIG_TMP '%s' "$scratch"
  verify_image \
    "$ROLLBACK_ROOT/config.before" \
    "$ROLLBACK_CONFIG_IDENTITY" \
    "$ROLLBACK_CONFIG_SHA" \
    || return 1
  cp "$ROLLBACK_ROOT/config.before" "$scratch" || { rm -f "$scratch"; return 1; }
  binding=$(image_binding "$scratch") || { rm -f "$scratch"; return 1; }
  printf -v RESTORE_CONFIG_BINDING '%s' "$binding"
  [ "${binding#*$'\t'}" = "$ROLLBACK_CONFIG_SHA" ] || { rm -f "$scratch"; return 1; }
}

stage_catalog_restore() {
  local scratch binding
  scratch=$(mktemp "$1/.claude-capabilities.json.restore.XXXXXX") || return 1
  printf -v RESTORE_CATALOG_TMP '%s' "$scratch"
  verify_image \
    "$ROLLBACK_ROOT/catalog.before" \
    "$ROLLBACK_CATALOG_IDENTITY" \
    "$ROLLBACK_CATALOG_SHA" \
    || return 1
  cp "$ROLLBACK_ROOT/catalog.before" "$scratch" || { rm -f "$RESTORE_CONFIG_TMP" "$scratch"; return 1; }
  binding=$(image_binding "$scratch") || { rm -f "$RESTORE_CONFIG_TMP" "$scratch"; return 1; }
  printf -v RESTORE_CATALOG_BINDING '%s' "$binding"
  [ "${binding#*$'\t'}" = "$ROLLBACK_CATALOG_SHA" ] || { rm -f "$RESTORE_CONFIG_TMP" "$scratch"; return 1; }
}

publish_restored_config() {
  verify_image \
    "$RESTORE_CONFIG_TMP" \
    "${RESTORE_CONFIG_BINDING%%$'\t'*}" \
    "$ROLLBACK_CONFIG_SHA" \
    || return 1
  mv -f "$RESTORE_CONFIG_TMP" "$1/config.json" || { rm -f "$RESTORE_CONFIG_TMP" "$RESTORE_CATALOG_TMP"; return 1; }
}

publish_restored_catalog() {
  verify_image \
    "$RESTORE_CATALOG_TMP" \
    "${RESTORE_CATALOG_BINDING%%$'\t'*}" \
    "$ROLLBACK_CATALOG_SHA" \
    || return 1
  mv -f "$RESTORE_CATALOG_TMP" "$1/claude-capabilities.json" || { rm -f "$RESTORE_CATALOG_TMP"; return 1; }
}

finish_restored_journal() {
  local journal_valid="$1"
  if [ "$journal_valid" -eq 0 ]; then
    return 2
  fi
  verify_pending_before_images || return 2
  verify_pending_after_images || return 2
  remove_refresh_directory \
    "$PENDING_REFRESH" \
    '.lbwc-model-refresh.pending' \
    "$PENDING_REFRESH_IDENTITY" \
    || return 2
  PENDING_REFRESH=""
}

restore_pending_refresh() {
  local planning_dir journal_valid=1
  [ -n "$PENDING_REFRESH" ] || return 1
  planning_dir=$(dirname "$PENDING_REFRESH")
  RESTORE_CATALOG_TMP=""
  verify_pending_before_images || journal_valid=0
  verify_rollback_images || return 1
  stage_config_restore "$planning_dir" || return 1
  if [ "$CATALOG_WAS_PRESENT" -eq 1 ]; then
    stage_catalog_restore "$planning_dir" || return 1
  fi
  verify_rollback_images || return 1
  verify_pending_before_images || journal_valid=0
  publish_restored_config "$planning_dir" || return 1
  if [ "$CATALOG_WAS_PRESENT" -eq 1 ]; then
    verify_rollback_images || return 1
    verify_pending_before_images || journal_valid=0
    publish_restored_catalog "$planning_dir" || return 1
  else
    rm -f "$planning_dir/claude-capabilities.json" || return 1
  fi
  finish_restored_journal "$journal_valid"
}
