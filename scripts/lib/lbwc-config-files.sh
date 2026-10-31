config_path() {
  printf '%s/config.json\n' "$1"
}

resolve_known_system_alias() {
  local current="$1" target
  case "$current" in
    /var|"/var/"*)
      [ -L /var ] || {
        printf '%s\n' "$current"
        return 0
      }
      target=$(readlink /var) || fail 'could not resolve the macOS /var alias'
      [ "$target" = 'private/var' ] || {
        printf '%s\n' "$current"
        return 0
      }
      printf '/private/var%s\n' "${current#/var}"
      ;;
    *)
      printf '%s\n' "$current"
      ;;
  esac
}

assert_no_symbolic_links() {
  local current="$1" parent
  if [[ "$current" != "/"* ]]; then
    current="$(pwd -P)/$current"
  fi
  current=$(resolve_known_system_alias "$current")
  while [ "$current" != "/" ] && [ "${current%/}" != "$current" ]; do
    current=${current%/}
  done
  while :; do
    [ ! -L "$current" ] || fail "symbolic link paths are not allowed: $current"
    [ "$current" = "/" ] && return 0
    parent=$(dirname "$current")
    [ "$parent" != "$current" ] || return 0
    current="$parent"
  done
}

cleanup_lock() {
  if [ -n "$LOCK_DIR" ] && [ -d "$LOCK_DIR" ]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}

enter_planning_dir() {
  local planning_dir="$1" opened_dir
  CDPATH='' cd -P -- "$planning_dir" || fail "could not enter planning directory: $planning_dir"
  opened_dir=$(pwd -P) || fail "could not resolve planning directory: $planning_dir"
  assert_no_symbolic_links "$opened_dir"
}

acquire_lock() {
  local attempt=0
  LOCK_DIR=".config.lock"
  assert_no_symbolic_links "$LOCK_DIR"
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    assert_no_symbolic_links "$LOCK_DIR"
    attempt=$((attempt + 1))
    [ "$attempt" -lt "$LOCK_ATTEMPTS" ] || fail "could not acquire configuration lock: $LOCK_DIR"
    sleep "$LOCK_SLEEP_SECONDS"
  done
  assert_no_symbolic_links "$LOCK_DIR"
}

read_existing_config() {
  local path="$1"
  assert_no_symbolic_links "$path"
  if [ ! -e "$path" ]; then
    printf '{}\n'
    return 0
  fi
  [ -f "$path" ] || fail "configuration is not a file: $path"
  jq -e 'type == "object"' "$path" >/dev/null 2>&1 || fail "configuration is not valid JSON: $path"
  cat "$path"
}

atomic_write() {
  local path="$1" value="$2" temporary
  [ "$path" = "${path##*/}" ] || fail "configuration path must be relative: $path"
  assert_no_symbolic_links "$path"
  temporary=$(mktemp "./.config.json.tmp.XXXXXX") || fail 'could not create configuration temporary file'
  assert_no_symbolic_links "$temporary"
  if ! printf '%s\n' "$value" > "$temporary"; then
    rm -f "$temporary"
    fail "could not write configuration temporary file: $temporary"
  fi
  assert_no_symbolic_links "$path"
  mv -f "$temporary" "$path" || {
    rm -f "$temporary"
    fail "could not atomically persist configuration: $path"
  }
}
