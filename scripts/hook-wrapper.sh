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
# With CDPATH set, cd prints the path, so $(cd d && pwd) returns two lines.
unset CDPATH
SCRIPT="${1:-}"; shift || true
if [ -z "$SCRIPT" ]; then
  echo "hook target resolution failed: target name is required" >&2
  exit 2
fi

TARGET="${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/scripts/$SCRIPT}"

if [ -z "$TARGET" ] || [ ! -f "$TARGET" ]; then
  SESSION_KEY="${CLAUDE_SESSION_ID:-root-$(printf %s "$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)" | shasum -a 256 | cut -c1-64)}"
  SESSION_TARGET="/tmp/.meridian-plugin-root-link-${SESSION_KEY}/scripts/$SCRIPT"
  [ -f "$SESSION_TARGET" ] && TARGET="$SESSION_TARGET"
fi

if [ -z "$TARGET" ] || [ ! -f "$TARGET" ]; then
  SELF_DIR="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)"
  [ -f "$SELF_DIR/$SCRIPT" ] && TARGET="$SELF_DIR/$SCRIPT"
fi

if [ -z "$TARGET" ] || [ ! -f "$TARGET" ]; then
  echo "hook target resolution failed: unable to locate '$SCRIPT'" >&2
  exit 2
fi

bash "$TARGET" "$@"
RC=$?
[ "$RC" -eq 0 ] && exit 0
[ "$RC" -eq 2 ] && exit 2
echo "meridian hook warning: $SCRIPT exited $RC, call allowed" >&2
exit 1
