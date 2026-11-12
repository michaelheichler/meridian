#!/bin/bash

printf -v MERIDIAN_MIGRATION_SOURCE '%s' "${BASH_SOURCE[0]}"
case "$MERIDIAN_MIGRATION_SOURCE" in
  *"/"*) printf -v MERIDIAN_MIGRATION_SOURCE '%s' "${MERIDIAN_MIGRATION_SOURCE%"/"*}" ;;
  *) printf -v MERIDIAN_MIGRATION_SOURCE '%s' . ;;
esac
if [ -f "$MERIDIAN_MIGRATION_SOURCE/../lib/rename-migration.sh" ]; then
  . "$MERIDIAN_MIGRATION_SOURCE/../lib/rename-migration.sh"
  meridian_migrate_environment
fi
unset MERIDIAN_MIGRATION_SOURCE
set -eu
CHECK_ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
exec python3 "$CHECK_ROOT/scripts/dev/check_config_keys.py" "$CHECK_ROOT"
