cleanup() {
  local owner_file
  [ "$LOCK_HELD" -eq 1 ] && [ -n "$LOCK_DIR" ] && [ -n "$LOCK_OWNER_RECORD" ] || return 0
  owner_file="$LOCK_DIR/owner"
  lock_is_owned || return 0
  rm -f -- "$owner_file" 2>/dev/null || return 0
  lock_directory_has_identity || return 0
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

require_tools() {
  local tool
  for tool in awk date jq mkdir mktemp mv ps shasum sleep; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
  done
  configure_platform_tools
}

system_name() {
  if [ -x /usr/bin/uname ]; then
    command /usr/bin/uname -s
  elif [ -x /bin/uname ]; then
    command /bin/uname -s
  else
    return 1
  fi
}

lock_backend_for_system() {
  case "$1" in
    Darwin) printf '%s\n' lockf ;;
    Linux) printf '%s\n' flock ;;
    *) return 1 ;;
  esac
}

first_executable() {
  local candidate
  for candidate in "$@"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

configure_platform_tools() {
  local platform
  platform=$(system_name) || fail 'could not identify the operating system'
  LOCK_BACKEND=$(lock_backend_for_system "$platform") \
    || fail "unsupported operating system for routing locks: $platform"
  ENV_TOOL=$(first_executable /usr/bin/env /bin/env) || fail 'a trusted system env is required'
  OD_TOOL=$(first_executable /usr/bin/od /bin/od) || fail 'a trusted system od is required'
  case "$LOCK_BACKEND" in
    lockf)
      LOCK_TOOL=$(first_executable /usr/bin/lockf) || fail '/usr/bin/lockf is required on macOS'
      STAT_TOOL=$(first_executable /usr/bin/stat) || fail '/usr/bin/stat is required on macOS'
      STAT_STYLE=bsd
      ;;
    flock)
      LOCK_TOOL=$(first_executable /usr/bin/flock /bin/flock) || fail 'flock is required on Linux'
      STAT_TOOL=$(first_executable /usr/bin/stat /bin/stat) || fail 'stat is required on Linux'
      STAT_STYLE=gnu
      ;;
  esac
}

invoke_lock_backend() {
  local backend="$1" tool="$2" fd="$3"
  case "$backend" in
    lockf) command "$tool" -s -t 0 "$fd" ;;
    flock) command "$tool" -n "$fd" ;;
    *) return 1 ;;
  esac
}

directory_identity() {
  local identity
  case "$STAT_STYLE" in
    bsd) identity=$(command "$STAT_TOOL" -f '%d:%i' -- "$1" 2>/dev/null) || return 1 ;;
    gnu) identity=$(command "$STAT_TOOL" -Lc '%d:%i' -- "$1" 2>/dev/null) || return 1 ;;
    *) return 1 ;;
  esac
  [[ "$identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  printf '%s\n' "$identity"
}

file_inode() {
  local inode
  case "$STAT_STYLE" in
    bsd) inode=$(command "$STAT_TOOL" -f '%i' -- "$1" 2>/dev/null) || return 1 ;;
    gnu) inode=$(command "$STAT_TOOL" -Lc '%i' -- "$1" 2>/dev/null) || return 1 ;;
    *) return 1 ;;
  esac
  [[ "$inode" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$inode"
}

descriptor_inode() {
  local inode attempt
  for attempt in 1 2 3 4 5; do
    inode=$(file_inode "/dev/fd/$1") && { printf '%s\n' "$inode"; return 0; }
  done
  return 1
}

lock_directory_has_identity() {
  local current_identity
  [ -n "$LOCK_DIR_IDENTITY" ] && [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ] || return 1
  current_identity=$(directory_identity "$LOCK_DIR") || return 1
  [ "$current_identity" = "$LOCK_DIR_IDENTITY" ]
}

lock_is_owned() {
  local owner_file current
  lock_directory_has_identity || return 1
  owner_file="$LOCK_DIR/owner"
  [ -f "$owner_file" ] && [ ! -L "$owner_file" ] || return 1
  current=$(<"$owner_file")
  [ "$current" = "$LOCK_OWNER_RECORD" ]
}
