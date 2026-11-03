#!/bin/bash
set -u
if [ "${4:-}" = heartbeat ] && [ "${1##*/}" = tmux-bus.sh ]; then
  count=0
  [ ! -f "$HB_EVENTS" ] || count=$(wc -l < "$HB_EVENTS")
  count=$((count + 1))
  printf 'bus\n' >> "$HB_EVENTS"
  case "$HB_SCENARIO:$count" in
    recovery:1|recovery:2|recovery:4|recovery:5|exhausted:*|mixed:*) exit 1 ;;
  esac
  "$HB_REAL_BASH" "$@"
  result=$?
  [ "$result" -ne 0 ] || printf 'success\n' >> "$HB_SUCCESSES"
  exit "$result"
fi
exec "$HB_REAL_BASH" "$@"
