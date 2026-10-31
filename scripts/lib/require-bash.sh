# Keep bash 3.2 syntax because this runs before any bash 4 code is parsed.

require_bash_43() {
  if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] ||
    { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -lt 3 ]; }; then
    printf 'meridian requires bash 4.3 or newer, found %s\n' "$BASH_VERSION" >&2
    exit 3
  fi
}
