cleanup_preflight() {
  local cleanup_status=0 preserve_preflight=0 restore_status=0
  if [ "$REFRESH_COMMITTED" -eq 0 ] && [ -n "$PENDING_REFRESH" ]; then
    if restore_pending_refresh; then
      :
    else
      restore_status=$?
      cleanup_status=1
      [ "$restore_status" -eq 2 ] || preserve_preflight=1
    fi
  fi
  if [ -n "$PENDING_PREPARE" ] && [ -d "$PENDING_PREPARE" ]; then
    remove_refresh_directory "$PENDING_PREPARE" '.meridian-model-refresh.pending.prepare.' || cleanup_status=1
    PENDING_PREPARE=""
  fi
  if [ "$preserve_preflight" -eq 0 ] && [ -n "$PREFLIGHT_ROOT" ] && [ -d "$PREFLIGHT_ROOT" ]; then
    if [[ "${PREFLIGHT_ROOT##*/}" != meridian-model-preflight.* ]]; then
      return 1
    fi
    rm -rf -- "$PREFLIGHT_ROOT"
    PREFLIGHT_ROOT=""
  fi
  return "$cleanup_status"
}

run_outside_transaction() {
  env \
    -u MERIDIAN_CONFIG_TRANSACTION_ACTIVE \
    -u MERIDIAN_CONFIG_TRANSACTION_PLANNING_DIR \
    -u MERIDIAN_CONFIG_TRANSACTION_LOCK_DIR \
    -u MERIDIAN_CONFIG_TRANSACTION_LOCK_IDENTITY \
    -u MERIDIAN_CONFIG_TRANSACTION_GUARD \
    -u MERIDIAN_CONFIG_TRANSACTION_FD \
    -u MERIDIAN_CONFIG_TRANSACTION_OWNER \
    "$@"
}

validate_state() {
  bash "$ROUTING" validate "$1" >/dev/null
}

preflight_refresh() {
  local planning_dir="$1" staged
  [ -f "$planning_dir/config.json" ] || fail "configuration is not readable: $planning_dir/config.json"
  [ ! -L "$planning_dir/config.json" ] || fail "symbolic link paths are not allowed: $planning_dir/config.json"
  PREFLIGHT_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/meridian-model-preflight.XXXXXX") \
    || fail 'could not create model refresh preflight directory'
  ROLLBACK_ROOT="$PREFLIGHT_ROOT/rollback"
  mkdir "$ROLLBACK_ROOT" || fail 'could not create model refresh rollback state'
  cp "$planning_dir/config.json" "$ROLLBACK_ROOT/config.before" \
    || fail 'could not preserve rollback configuration image'
  if [ -f "$planning_dir/claude-capabilities.json" ] && [ ! -L "$planning_dir/claude-capabilities.json" ]; then
    CATALOG_WAS_PRESENT=1
    cp "$planning_dir/claude-capabilities.json" "$ROLLBACK_ROOT/catalog.before" \
      || fail 'could not preserve rollback catalog image'
  elif [ -e "$planning_dir/claude-capabilities.json" ] || [ -L "$planning_dir/claude-capabilities.json" ]; then
    fail "capability catalog is not a regular file: $planning_dir/claude-capabilities.json"
  fi
  bind_rollback_images
  staged="$PREFLIGHT_ROOT/.meridian"
  mkdir "$staged" || fail 'could not create model refresh preflight state'
  cp "$planning_dir/config.json" "$staged/config.json" \
    || fail 'could not stage configuration for model refresh preflight'
  run_outside_transaction bash "$CAPABILITIES" refresh "$staged" >/dev/null
  run_outside_transaction bash "$ROUTING" migrate "$staged" >/dev/null
  run_outside_transaction bash "$ROUTING" validate "$staged" >/dev/null
}

assert_refresh_ready() {
  local planning_dir="$1" staged="$2" pending="$3" live_binding
  [ ! -e "$pending" ] && [ ! -L "$pending" ] \
    || fail "pending model refresh requires recovery: $pending"
  [ -f "$planning_dir/config.json" ] && [ ! -L "$planning_dir/config.json" ] \
    || fail "configuration is not readable: $planning_dir/config.json"
  verify_rollback_images || fail 'model refresh rollback images changed before journal preparation'
  live_binding=$(image_binding "$planning_dir/config.json") \
    || fail 'configuration changed before model refresh journal preparation'
  [ "${live_binding#*$'\t'}" = "$ROLLBACK_CONFIG_SHA" ] \
    || fail 'configuration changed before model refresh journal preparation'
  [ -f "$staged/config.json" ] && [ ! -L "$staged/config.json" ] \
    || fail 'staged configuration is not readable'
  [ -f "$staged/claude-capabilities.json" ] && [ ! -L "$staged/claude-capabilities.json" ] \
    || fail 'staged capability catalog is not readable'
}

journal_catalog_before() {
  local planning_dir="$1" live_binding
  if [ "$CATALOG_WAS_PRESENT" -eq 1 ]; then
    live_binding=$(image_binding "$planning_dir/claude-capabilities.json") \
      || fail 'capability catalog changed before model refresh journal preparation'
    [ "${live_binding#*$'\t'}" = "$ROLLBACK_CATALOG_SHA" ] \
      || fail 'capability catalog changed before model refresh journal preparation'
    cp "$ROLLBACK_ROOT/catalog.before" "$PENDING_PREPARE/catalog.before" \
      || fail 'could not preserve capability catalog before model refresh'
    : > "$PENDING_PREPARE/catalog.was-present"
  elif [ -e "$planning_dir/claude-capabilities.json" ] || [ -L "$planning_dir/claude-capabilities.json" ]; then
    fail "capability catalog is not a regular file: $planning_dir/claude-capabilities.json"
  fi
}

prepare_pending_refresh() {
  local planning_dir="$1" staged pending
  staged="$PREFLIGHT_ROOT/.meridian"
  pending="$planning_dir/.meridian-model-refresh.pending"
  assert_refresh_ready "$planning_dir" "$staged" "$pending"
  PENDING_PREPARE=$(mktemp -d "$planning_dir/.meridian-model-refresh.pending.prepare.XXXXXX") || fail 'could not create model refresh journal'
  cp "$ROLLBACK_ROOT/config.before" "$PENDING_PREPARE/config.before" \
    || fail 'could not preserve configuration before model refresh'
  journal_catalog_before "$planning_dir"
  cp "$staged/config.json" "$PENDING_PREPARE/config.after" \
    || fail 'could not stage refreshed configuration'
  cp "$staged/claude-capabilities.json" "$PENDING_PREPARE/catalog.after" \
    || fail 'could not stage refreshed capability catalog'
  mv "$PENDING_PREPARE" "$pending" || fail 'could not publish model refresh journal'
  PENDING_PREPARE=""
  PENDING_REFRESH="$pending"
  bind_pending_refresh
}
