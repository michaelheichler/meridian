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


PHASE="${1:-}"
PLAN="${2:-}"
BASE="${3:-}"

if [ -z "$PHASE" ] || [ -z "$PLAN" ]; then
  exit 0
fi

WORKTREE_DIR=".meridian-worktrees/${PHASE}-${PLAN}"
BRANCH="meridian/${PHASE}-${PLAN}"

if [ -d "$WORKTREE_DIR" ]; then
  ABS_PATH=$(CDPATH='' cd -- "$WORKTREE_DIR" && pwd)
  echo "$ABS_PATH"
  exit 0
fi

mkdir -p .meridian-worktrees

GITIGNORE=".gitignore"
if ! grep -qxF ".meridian-worktrees/" "$GITIGNORE" 2>/dev/null; then
  echo ".meridian-worktrees/" >> "$GITIGNORE"
fi

if [ -n "$BASE" ]; then
  git worktree add "$WORKTREE_DIR" -b "$BRANCH" "$BASE" 2>/dev/null
  GIT_STATUS=$?
  if [ "$GIT_STATUS" -ne 0 ]; then
    git worktree add "$WORKTREE_DIR" "$BRANCH" 2>/dev/null
    GIT_STATUS=$?
  fi
else
  git worktree add "$WORKTREE_DIR" -b "$BRANCH" 2>/dev/null
  GIT_STATUS=$?
  if [ "$GIT_STATUS" -ne 0 ]; then
    git worktree add "$WORKTREE_DIR" "$BRANCH" 2>/dev/null
    GIT_STATUS=$?
  fi
fi

if [ "$GIT_STATUS" -eq 0 ]; then
  ABS_PATH=$(CDPATH='' cd -- "$WORKTREE_DIR" && pwd)
  echo "$ABS_PATH"
fi

exit 0
