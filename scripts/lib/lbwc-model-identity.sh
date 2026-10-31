configure_linux_stat() {
  if [ -x /usr/bin/stat ]; then
    printf -v IDENTITY_STAT_TOOL '%s' /usr/bin/stat
  elif [ -x /bin/stat ]; then
    printf -v IDENTITY_STAT_TOOL '%s' /bin/stat
  else
    fail 'stat is required on Linux'
  fi
  printf -v IDENTITY_STAT_STYLE '%s' gnu
}

configure_identity_tool() {
  local platform
  if [ -x /usr/bin/uname ]; then
    platform=$(/usr/bin/uname -s)
  elif [ -x /bin/uname ]; then
    platform=$(/bin/uname -s)
  else
    fail 'could not identify the operating system'
  fi
  if [ "$platform" = Darwin ]; then
    [ -x /usr/bin/stat ] || fail '/usr/bin/stat is required on macOS'
    IDENTITY_STAT_TOOL=/usr/bin/stat
    IDENTITY_STAT_STYLE=bsd
  elif [ "$platform" = Linux ]; then
    configure_linux_stat
  else
    fail "unsupported operating system for model refresh transactions: $platform"
  fi
}

path_has_type() {
  local path="$1" expected_type="$2"
  [ ! -L "$path" ] || return 1
  if [ "$expected_type" = directory ]; then
    [ -d "$path" ] || return 1
  elif [ "$expected_type" = file ]; then
    [ -f "$path" ] || return 1
  else
    return 1
  fi
}

stat_identity() {
  if [ "$IDENTITY_STAT_STYLE" = bsd ]; then
    "$IDENTITY_STAT_TOOL" -f '%d:%i' -- "$1" 2>/dev/null
  elif [ "$IDENTITY_STAT_STYLE" = gnu ]; then
    "$IDENTITY_STAT_TOOL" -c '%d:%i' -- "$1" 2>/dev/null
  else
    return 1
  fi
}

path_identity() {
  local path="$1" expected_type="$2" identity
  path_has_type "$path" "$expected_type" || return 1
  identity=$(stat_identity "$path") || return 1
  path_has_type "$path" "$expected_type" || return 1
  [[ "$identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  printf '%s\n' "$identity"
}

image_binding() {
  local path="$1" identity_before identity_after sha
  identity_before=$(path_identity "$path" file) || return 1
  sha=$(shasum -a 256 "$path" 2>/dev/null | awk '{print $1}') || return 1
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || return 1
  identity_after=$(path_identity "$path" file) || return 1
  [ "$identity_before" = "$identity_after" ] || return 1
  printf '%s\t%s\n' "$identity_before" "$sha"
}

verify_image() {
  local path="$1" expected_identity="$2" expected_sha="$3" binding
  binding=$(image_binding "$path") || return 1
  [ "$binding" = "$expected_identity"$'\t'"$expected_sha" ]
}
