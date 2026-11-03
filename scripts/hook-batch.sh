#!/bin/bash

. "$(CDPATH="" cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/rename-migration.sh"
meridian_migrate_environment
set -u
unset CDPATH
set -m
BATCH_DIR="$1"
while IFS= read -r -d '' TARGET; do
  bash "$TARGET" < "$BATCH_DIR/input" > "$BATCH_DIR/stdout" 2> "$BATCH_DIR/stderr" &
  GUARD_PID=$!
  printf '%s\n' "$GUARD_PID"
  wait "$GUARD_PID" 2>/dev/null
  printf '%s\n' "$?"
done
