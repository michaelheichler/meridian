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

# Fails open, so a broken user hook never blocks archiving.

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P 2>/dev/null || dirname "$0")
ROOT_HELPER="$SCRIPT_DIR/lib/meridian-config-root.sh"

if [ -f "$ROOT_HELPER" ]; then
  . "$ROOT_HELPER"
  find_meridian_root "$SCRIPT_DIR" 2>/dev/null || true
fi

warn() {
  echo "[post-archive-hook] WARNING: $*" >&2
}

resolve_from_base() {
  local path="$1"
  local base_dir="$2"

  if [ "${path:0:1}" = "/" ]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$base_dir" "$path"
  fi
}

MILESTONE_SLUG="${1:-}"
ARCHIVE_PATH="${2:-}"
TAG="${3-}"

BASE_ROOT="${MERIDIAN_CONFIG_ROOT:-$(pwd -P 2>/dev/null || pwd)}"
DEFAULT_CONFIG_PATH="${MERIDIAN_PLANNING_DIR:-$BASE_ROOT/.meridian}/config.json"
CONFIG_PATH="${4:-$DEFAULT_CONFIG_PATH}"
CONFIG_PATH=$(resolve_from_base "$CONFIG_PATH" "$BASE_ROOT")

if CONFIG_DIR=$(CDPATH='' cd -- "$(dirname "$CONFIG_PATH")" 2>/dev/null && pwd -P 2>/dev/null); then
  CONFIG_PATH="$CONFIG_DIR/$(basename "$CONFIG_PATH")"
  PLANNING_DIR="$CONFIG_DIR"
else
  PLANNING_DIR=$(dirname "$CONFIG_PATH")
fi

PROJECT_ROOT=$(dirname "$PLANNING_DIR")
export MERIDIAN_CONFIG_ROOT="$PROJECT_ROOT"
export MERIDIAN_PLANNING_DIR="$PLANNING_DIR"

[ -n "$MILESTONE_SLUG" ] || exit 0
[ -n "$ARCHIVE_PATH" ] || exit 0

ARCHIVE_PATH=$(resolve_from_base "$ARCHIVE_PATH" "$PROJECT_ROOT")

if [ ! -f "$CONFIG_PATH" ]; then
  warn "config not found at $CONFIG_PATH; skipping post_archive hook"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  warn "jq unavailable; skipping post_archive hook"
  exit 0
fi

HOOK_PATH=$(jq -r '.hooks.post_archive // ""' "$CONFIG_PATH" 2>/dev/null) || {
  warn "could not read hooks.post_archive from $CONFIG_PATH; skipping post_archive hook"
  exit 0
}

[ -n "$HOOK_PATH" ] || exit 0

HOOK_PATH=$(resolve_from_base "$HOOK_PATH" "$PROJECT_ROOT")

if [ ! -f "$HOOK_PATH" ]; then
  warn "configured post_archive hook not found at $HOOK_PATH; skipping"
  exit 0
fi

if ! (
  CDPATH='' cd -- "$PROJECT_ROOT" 2>/dev/null &&
    bash "$HOOK_PATH" "$MILESTONE_SLUG" "$ARCHIVE_PATH" "$TAG"
); then
  warn "configured post_archive hook failed at $HOOK_PATH; continuing archive"
fi

exit 0