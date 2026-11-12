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

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/meridian-settings.sh"

planning_dir="${1:-.meridian}"
config=$(meridian_merged_config "$planning_dir/config.json")
enabled=$(jq -r 'if .plain_summary == null then true else .plain_summary end' <<< "$config")
text=$(cat)
if [ "$enabled" = true ]; then
  if [ -z "${text//[[:space:]]/}" ]; then
    printf 'Error: plain summary text is empty\n' >&2
    exit 1
  fi
  printf '## In plain words\n\n%s\n' "$text"
fi
