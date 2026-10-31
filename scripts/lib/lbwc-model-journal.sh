bind_image_into() {
  local identity_var="$1" sha_var="$2" path="$3" message="$4" binding
  binding=$(image_binding "$path") || fail "$message"
  printf -v "$identity_var" '%s' "${binding%%$'\t'*}"
  printf -v "$sha_var" '%s' "${binding#*$'\t'}"
}

bind_rollback_images() {
  bind_image_into ROLLBACK_CONFIG_IDENTITY ROLLBACK_CONFIG_SHA \
    "$ROLLBACK_ROOT/config.before" 'could not bind rollback configuration image'
  if [ "$CATALOG_WAS_PRESENT" -eq 1 ]; then
    bind_image_into ROLLBACK_CATALOG_IDENTITY ROLLBACK_CATALOG_SHA \
      "$ROLLBACK_ROOT/catalog.before" 'could not bind rollback catalog image'
  fi
}

verify_rollback_images() {
  verify_image \
    "$ROLLBACK_ROOT/config.before" \
    "$ROLLBACK_CONFIG_IDENTITY" \
    "$ROLLBACK_CONFIG_SHA" \
    || return 1
  if [ "$CATALOG_WAS_PRESENT" -eq 1 ]; then
    verify_image \
      "$ROLLBACK_ROOT/catalog.before" \
      "$ROLLBACK_CATALOG_IDENTITY" \
      "$ROLLBACK_CATALOG_SHA" \
      || return 1
  fi
}

bind_pending_refresh() {
  local identity_after
  PENDING_REFRESH_IDENTITY=$(path_identity "$PENDING_REFRESH" directory) \
    || fail 'could not bind published model refresh journal'
  bind_image_into PENDING_CONFIG_BEFORE_IDENTITY PENDING_CONFIG_BEFORE_SHA \
    "$PENDING_REFRESH/config.before" 'could not bind model refresh configuration before image'
  if [ "$CATALOG_WAS_PRESENT" -eq 1 ]; then
    bind_image_into PENDING_CATALOG_BEFORE_IDENTITY PENDING_CATALOG_BEFORE_SHA \
      "$PENDING_REFRESH/catalog.before" 'could not bind model refresh catalog before image'
  fi
  bind_image_into PENDING_CONFIG_AFTER_IDENTITY PENDING_CONFIG_AFTER_SHA \
    "$PENDING_REFRESH/config.after" 'could not bind model refresh configuration after image'
  bind_image_into PENDING_CATALOG_AFTER_IDENTITY PENDING_CATALOG_AFTER_SHA \
    "$PENDING_REFRESH/catalog.after" 'could not bind model refresh catalog after image'
  identity_after=$(path_identity "$PENDING_REFRESH" directory) \
    || fail 'published model refresh journal changed while binding images'
  [ "$identity_after" = "$PENDING_REFRESH_IDENTITY" ] \
    || fail 'published model refresh journal changed while binding images'
}

verify_pending_refresh_directory() {
  local identity
  identity=$(path_identity "$PENDING_REFRESH" directory) || return 1
  [ "$identity" = "$PENDING_REFRESH_IDENTITY" ]
}

verify_pending_before_images() {
  verify_pending_refresh_directory || return 1
  verify_image \
    "$PENDING_REFRESH/config.before" \
    "$PENDING_CONFIG_BEFORE_IDENTITY" \
    "$PENDING_CONFIG_BEFORE_SHA" \
    || return 1
  if [ "$CATALOG_WAS_PRESENT" -eq 1 ]; then
    verify_image \
      "$PENDING_REFRESH/catalog.before" \
      "$PENDING_CATALOG_BEFORE_IDENTITY" \
      "$PENDING_CATALOG_BEFORE_SHA" \
      || return 1
  fi
  verify_pending_refresh_directory
}

verify_pending_after_images() {
  verify_pending_refresh_directory || return 1
  verify_image \
    "$PENDING_REFRESH/config.after" \
    "$PENDING_CONFIG_AFTER_IDENTITY" \
    "$PENDING_CONFIG_AFTER_SHA" \
    || return 1
  verify_image \
    "$PENDING_REFRESH/catalog.after" \
    "$PENDING_CATALOG_AFTER_IDENTITY" \
    "$PENDING_CATALOG_AFTER_SHA" \
    || return 1
  verify_pending_refresh_directory
}

remove_refresh_directory() {
  local path="$1" expected_prefix="$2" expected_identity="${3:-}" identity name
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  name=${path##*/}
  [[ "$name" == "$expected_prefix"* ]] || return 1
  if [ -n "$expected_identity" ]; then
    identity=$(path_identity "$path" directory) || return 1
    [ "$identity" = "$expected_identity" ] || return 1
  fi
  rm -rf -- "$path"
}
