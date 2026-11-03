#!/bin/bash
set -u
printf '%s\n' "$$" > "$HB_SLEEP_PID.$$"
mv "$HB_SLEEP_PID.$$" "$HB_SLEEP_PID"
case "$HB_SCENARIO" in
  recovery|exhausted|mixed) exec "$HB_REAL_SLEEP" 0.05 ;;
esac
exec "$HB_REAL_SLEEP" "$@"
