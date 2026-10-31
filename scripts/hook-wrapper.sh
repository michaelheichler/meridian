#!/bin/bash
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
  for f in /tmp/.lbwc-plugin-root-link-*/scripts/"$SCRIPT"; do
    [ -f "$f" ] && TARGET="$f" && break
  done
fi

if [ -z "$TARGET" ] || [ ! -f "$TARGET" ]; then
  SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
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
