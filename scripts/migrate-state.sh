#!/bin/bash
set -u

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)"
source "$SCRIPT_DIR/lib/rename-migration.sh"

PROJECT_ROOT="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)}"
MERIDIAN_MIGRATION_CONFLICT=0
meridian_migrate_environment
meridian_migrate_planning "$PROJECT_ROOT" || exit 2
[ "${MERIDIAN_MIGRATION_CONFLICT:-0}" = 1 ] && exit 3
exit 0
