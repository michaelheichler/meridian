#!/bin/bash

printf -v MERIDIAN_MIGRATION_SOURCE '%s' "${BASH_SOURCE[0]}"
case "$MERIDIAN_MIGRATION_SOURCE" in
  *"/"*) printf -v MERIDIAN_MIGRATION_SOURCE '%s' "${MERIDIAN_MIGRATION_SOURCE%"/"*}" ;;
  *) printf -v MERIDIAN_MIGRATION_SOURCE '%s' . ;;
esac
if [ -f "$MERIDIAN_MIGRATION_SOURCE/rename-migration.sh" ]; then
  . "$MERIDIAN_MIGRATION_SOURCE/rename-migration.sh"
  meridian_migrate_environment
fi
unset MERIDIAN_MIGRATION_SOURCE

should_emit_hook_output() {
  local event_name="${1:-}"

  case "$event_name" in
    SessionStart|PreToolUse|PostToolUse|UserPromptSubmit|PreCompact)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  should_emit_hook_output "${1:-}"
  exit $?
fi
