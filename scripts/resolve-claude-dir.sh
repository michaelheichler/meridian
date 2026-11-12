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

if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  export CLAUDE_DIR="${CLAUDE_CONFIG_DIR}"
elif [ -d "$HOME/.config/claude-code" ]; then
  export CLAUDE_DIR="$HOME/.config/claude-code"
else
  export CLAUDE_DIR="$HOME/.claude"
fi
