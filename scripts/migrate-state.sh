#!/bin/bash
set -u

readonly MOVE_FAILED=2
readonly BOTH_FOLDERS_EXIST=3

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)"
source "$SCRIPT_DIR/lib/rename-migration.sh"

PROJECT_ROOT="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)}"
MERIDIAN_MIGRATION_CONFLICT=0
meridian_migrate_planning "$PROJECT_ROOT" || exit "$MOVE_FAILED"
[ "$MERIDIAN_MIGRATION_CONFLICT" = 1 ] && exit "$BOTH_FOLDERS_EXIST"
exit 0
