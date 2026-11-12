#!/usr/bin/env bash

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
set -euo pipefail


PLANNING_DIR="${1:-.meridian}"
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)"

if [[ ! -d "$PLANNING_DIR" ]]; then
  exit 0
fi

if [[ -f "$PLANNING_DIR/STATE.md" ]]; then
  exit 0
fi

latest_state=""
latest_mtime=-1
for f in "$PLANNING_DIR"/milestones/*/STATE.md; do
  [ -f "$f" ] || continue
  mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
  if [[ "$mtime" -gt "$latest_mtime" ]]; then
    latest_mtime="$mtime"
    latest_state="$f"
  fi
done

if [[ -z "$latest_state" ]]; then
  exit 0
fi

project_name=$(grep -m1 '^\*\*Project:\*\*' "$latest_state" 2>/dev/null | sed 's/\*\*Project:\*\* *//' || echo "Unknown")

bash "$SCRIPT_DIR/persist-state-after-ship.sh" \
  "$latest_state" "$PLANNING_DIR/STATE.md" "$project_name" 2>/dev/null || true

exit 0
