debug_logging_init() {
  [ "${DEBUG_LOGGING_LOADED:-0}" = 1 ] && return 0
  local _debug_scripts _debug_planning _debug_config _debug_enabled
  _debug_scripts=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || return 0
  _debug_planning="${MERIDIAN_PLANNING_DIR:-}"
  if [ -z "$_debug_planning" ]; then
    _debug_planning=$(
      . "$_debug_scripts/lib/meridian-config-root.sh"
      find_meridian_root "${1:-$PWD}"
      printf '%s' "$MERIDIAN_PLANNING_DIR"
    ) || return 0
  fi
  . "$_debug_scripts/lib/meridian-settings.sh"
  _debug_config=$(meridian_merged_config "$_debug_planning/config.json") || _debug_config='{}'
  _debug_enabled=false
  if [ "$_debug_config" != '{}' ]; then
    _debug_enabled=$(jq -r '.debug_logging == true' <<< "$_debug_config" 2>/dev/null) || _debug_enabled=false
  fi
  printf -v DEBUG_LOGGING_ENABLED '%s' "$_debug_enabled"
  printf -v DEBUG_LOGGING_DIR '%s' "$_debug_planning"
  printf -v DEBUG_LOGGING_LOADED '%s' 1
}

debug_logging_append() (
  [ "${DEBUG_LOGGING_ENABLED:-false}" = true ] || return 0
  local _debug_component="$1" _debug_event="$2" _debug_check="$3"
  local _debug_decision="$4" _debug_duration="$5" _debug_reason="$6"
  local _debug_line _debug_time _debug_size _debug_attempt=0
  case "$_debug_component$_debug_event$_debug_check$_debug_decision$_debug_duration$_debug_reason" in
    *[!a-zA-Z0-9_.=-]*) return 0 ;;
  esac
  [ -d "$DEBUG_LOGGING_DIR" ] && [ ! -L "$DEBUG_LOGGING_DIR/.debug.log" ] || return 0
  _debug_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 0
  printf -v _debug_line '%s component=%s event=%s check=%s decision=%s duration_ms=%s reason=%s' \
    "$_debug_time" "$_debug_component" "$_debug_event" "$_debug_check" \
    "$_debug_decision" "$_debug_duration" "$_debug_reason"
  while ! mkdir "$DEBUG_LOGGING_DIR/.debug.log.lock" 2>/dev/null; do
    _debug_attempt=$((_debug_attempt + 1))
    [ "$_debug_attempt" -lt 20 ] || return 0
    sleep 0.01
  done
  trap 'rmdir "$DEBUG_LOGGING_DIR/.debug.log.lock" 2>/dev/null || true' EXIT
  [ ! -L "$DEBUG_LOGGING_DIR/.debug.log" ] || return 0
  _debug_size=0
  if [ -f "$DEBUG_LOGGING_DIR/.debug.log" ]; then
    _debug_size=$(wc -c < "$DEBUG_LOGGING_DIR/.debug.log") || return 0
  fi
  if [ "$((_debug_size + ${#_debug_line} + 1))" -gt 1048576 ]; then
    mv -f "$DEBUG_LOGGING_DIR/.debug.log" "$DEBUG_LOGGING_DIR/.debug.log.1" || return 0
  fi
  printf '%s\n' "$_debug_line" >> "$DEBUG_LOGGING_DIR/.debug.log"
) 2>/dev/null

debug_logging_exit() {
  local _debug_status="$1" _debug_decision=allow _debug_reason=completed
  case "$_debug_status" in
    0) ;;
    2) _debug_decision=deny; _debug_reason=blocked ;;
    124) _debug_decision=timeout; _debug_reason=deadline ;;
    *) _debug_decision=error; _debug_reason=nonzero ;;
  esac
  debug_logging_append gate "$DEBUG_LOGGING_EVENT" "$DEBUG_LOGGING_COMPONENT" \
    "${DEBUG_LOGGING_DECISION:-$_debug_decision}" "$(( (SECONDS - DEBUG_LOGGING_STARTED) * 1000 ))" \
    "${DEBUG_LOGGING_REASON:-$_debug_reason}" || true
}

debug_logging_note() {
  printf -v DEBUG_LOGGING_DECISION '%s' "$1"
  printf -v DEBUG_LOGGING_REASON '%s' "$2"
}

debug_logging_gate() {
  [ "${MERIDIAN_DISPATCH_LOGGING:-0}" = 1 ] && return 0
  debug_logging_init 2>/dev/null || true
  [ "${DEBUG_LOGGING_ENABLED:-false}" = true ] || return 0
  printf -v DEBUG_LOGGING_COMPONENT '%s' "$1"
  printf -v DEBUG_LOGGING_EVENT '%s' "$2"
  printf -v DEBUG_LOGGING_STARTED '%s' "$SECONDS"
  trap 'debug_logging_exit "$?"' EXIT
}
