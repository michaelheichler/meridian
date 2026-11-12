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
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || ROOT=""

if [ -z "$ROOT" ] || [ ! -d "$ROOT/.git" ]; then
  exit 0
fi

mkdir -p "$ROOT/.git/hooks"

HOOK_PATH="$ROOT/.git/hooks/pre-push"

HOOK_CONTENT='#!/usr/bin/env bash
set -euo pipefail
SCRIPT="/tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/pre-push-hook.sh"
if [ -f "$SCRIPT" ]; then
  exec bash "$SCRIPT" "$@"
fi
exit 0'

if [ -f "$HOOK_PATH" ]; then
  if [ -L "$HOOK_PATH" ]; then
    CURRENT_TARGET=$(readlink "$HOOK_PATH")
    if echo "$CURRENT_TARGET" | grep -q "pre-push-hook.sh"; then
      rm -f "$HOOK_PATH"
      echo "$HOOK_CONTENT" > "$HOOK_PATH"
      chmod +x "$HOOK_PATH"
      echo "Upgraded pre-push hook to standalone script" >&2
    else
      echo "pre-push hook exists but is not managed by MERIDIAN -- skipping" >&2
    fi
  elif [ -x "$HOOK_PATH" ] && [ "$(cat "$HOOK_PATH")" = "$HOOK_CONTENT" ]; then
    echo "pre-push hook already installed" >&2
  elif grep -qE '(_meridian_find_script|SCRIPT="/tmp/.meridian-plugin-root-link-)' "$HOOK_PATH" 2>/dev/null; then
    echo "$HOOK_CONTENT" > "$HOOK_PATH"
    chmod +x "$HOOK_PATH"
    echo "Updated pre-push hook" >&2
  else
    echo "pre-push hook exists but is not managed by MERIDIAN -- skipping" >&2
  fi
else
  echo "$HOOK_CONTENT" > "$HOOK_PATH"
  chmod +x "$HOOK_PATH"
  echo "Installed pre-push hook" >&2
fi
