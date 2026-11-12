resolve_known_system_alias() {
  local current="$1" target
  case "$current" in
    /var|/var/*)
      if [ -L /var ]; then
        target=$(readlink /var) || fail 'could not resolve the macOS /var alias'
        if [ "$target" = 'private/var' ]; then
          printf '/private/var%s\n' "${current#/var}"
          return 0
        fi
      fi
      ;;
  esac
  printf '%s\n' "$current"
}

assert_no_symbolic_links() {
  local current="$1" parent
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

resolve_planning_dir() {
  local input="$1" trimmed parent physical_parent
  case "/$input/" in
    */../*|*/./*) fail "planning directory traversal is not allowed: $input" ;;
  esac
  trimmed="$input"
  while [ "$trimmed" != "/" ] && [ "${trimmed%/}" != "$trimmed" ]; do
    trimmed=${trimmed%/}
  done
  [ ! -L "$trimmed" ] || fail "planning directory boundary must not be a symbolic link: $input"
  [ "${trimmed##*/}" = '.meridian' ] || fail "planning directory must end with .meridian: $input"
  assert_no_symbolic_links "$trimmed"
  [ -d "$trimmed" ] || fail "planning directory does not exist: $input"
  case "$trimmed" in
    */*) parent=${trimmed%/*}; [ -n "$parent" ] || parent=/ ;;
    *) parent=. ;;
  esac
  physical_parent=$(CDPATH='' cd -P -- "$parent" 2>/dev/null && pwd -P) \
    || fail "could not resolve planning directory: $input"
  assert_no_symbolic_links "$physical_parent"
  printf '%s/.meridian\n' "$physical_parent"
}

acquire_lock() {
  local planning_dir="$1"
  LOCK_DIR="$planning_dir/.conventions.lock"
  [ ! -L "$LOCK_DIR" ] || fail "symbolic link locks are not allowed: $LOCK_DIR"
  mkdir "$LOCK_DIR" 2>/dev/null || fail "could not acquire conventions lock: $LOCK_DIR"
  LOCK_HELD=1
  [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ] || fail "invalid conventions lock: $LOCK_DIR"
}

write_artifact() {
  local planning_dir="$1" value="$2" path
  path="$planning_dir/conventions.json"
  [ ! -L "$path" ] || fail "symbolic link artifacts are not allowed: $path"
  TEMP_PATH=$(mktemp "$planning_dir/.conventions.json.tmp.XXXXXXXXXXXX") \
    || fail 'could not create conventions temporary file'
  chmod 600 "$TEMP_PATH" || fail 'could not protect conventions temporary file'
  jq -ceS '.conventions |= sort_by(.id)' <<< "$value" > "$TEMP_PATH" \
    || fail 'could not serialize conventions artifact'
  [ ! -L "$path" ] || fail "symbolic link artifacts are not allowed: $path"
  mv -f -- "$TEMP_PATH" "$path" || fail 'could not replace conventions artifact'
  TEMP_PATH=""
}
