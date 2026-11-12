#!/bin/bash

printf -v MERIDIAN_MIGRATION_SOURCE '%s' "${BASH_SOURCE[0]}"
case "$MERIDIAN_MIGRATION_SOURCE" in
  *"/"*) printf -v MERIDIAN_MIGRATION_SOURCE '%s' "${MERIDIAN_MIGRATION_SOURCE%"/"*}" ;;
  *) printf -v MERIDIAN_MIGRATION_SOURCE '%s' . ;;
esac
if [ -f "$MERIDIAN_MIGRATION_SOURCE/lib/rename-migration.sh" ]; then
  . "$MERIDIAN_MIGRATION_SOURCE/lib/rename-migration.sh"
  meridian_migrate_environment
fi
unset MERIDIAN_MIGRATION_SOURCE
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
