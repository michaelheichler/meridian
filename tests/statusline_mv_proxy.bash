#!/bin/bash
set -u
arguments=("$@")
while [ "$#" -gt 2 ]; do shift; done
[ -f "$1" ] && [ "$1" != "$2" ] || exit 91
cat "$1" >> "$STATUSLINE_MV_LOG"
exec "$STATUSLINE_REAL_MV" "${arguments[@]}"
