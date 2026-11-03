#!/usr/bin/env bash

. "$(CDPATH="" cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/rename-migration.sh"
meridian_migrate_environment
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
