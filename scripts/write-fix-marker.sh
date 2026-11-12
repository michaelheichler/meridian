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

set -u

PLANNING_DIR="${1:-.meridian}"
DESCRIPTION="${2:-}"

if [ ! -d "$PLANNING_DIR" ]; then
  exit 0
fi

if ! command -v git &>/dev/null; then
  exit 0
fi

commit_hash=$(git rev-parse HEAD 2>/dev/null) || exit 0
commit_message=$(git log --format='%s' -1 2>/dev/null) || exit 0
commit_timestamp=$(git log --format='%aI' -1 2>/dev/null) || exit 0
changed_files=$(git diff-tree --root --no-commit-id --name-only -r HEAD 2>/dev/null) || exit 0

if [ -z "$DESCRIPTION" ]; then
  DESCRIPTION="$commit_message"
fi

DESCRIPTION=$(printf '%s' "$DESCRIPTION" | tr '\n\r' '  ')

marker_file="$PLANNING_DIR/.last-fix-commit"
{
  printf 'commit=%s\n' "$commit_hash"
  printf 'message=%s\n' "$commit_message"
  printf 'timestamp=%s\n' "$commit_timestamp"
  printf 'description=%s\n' "$DESCRIPTION"
  printf 'files=%s\n' "$changed_files"
} > "$marker_file" 2>/dev/null || true

exit 0
