#!/bin/bash
set -u
last=''
for argument in "$@"; do last=$argument; done
if [ "$HB_SCENARIO" = mixed ] && [ "$last" = "$HB_REGISTRY" ]; then
  count=0
  [ ! -f "$HB_READS" ] || read -r count < "$HB_READS"
  count=$((count + 1))
  printf '%s\n' "$count" > "$HB_READS"
  [ "$count" -ne 2 ] || exit 1
fi
exec "$HB_REAL_JQ" "$@"
