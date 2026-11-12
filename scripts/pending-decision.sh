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

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)
GUARD="$SCRIPT_DIR/../hooks/user_question_guard.py"

fail() {
  printf 'pending-decision: %s\n' "$1" >&2
  exit 2
}

case "${1:-}" in
  state|get)
    exec python3 "$GUARD" decision-read "$@"
    ;;
  create|record-bounded|record-freeform)
    fail "direct decision transitions are disabled; Claude Code hooks own decision state"
    ;;
  *)
    fail "only read-only state and get commands are available"
    ;;
esac
