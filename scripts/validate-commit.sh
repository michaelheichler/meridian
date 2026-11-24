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
. "$(CDPATH='' cd -- "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd)/lib/debug-logging.sh" 2>/dev/null || true
debug_logging_gate validate-commit.sh PostToolUse 2>/dev/null || true

if ! command -v jq &>/dev/null || ! command -v python3 &>/dev/null; then
  exit 0
fi

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

HOOKS_DIR="$(CDPATH='' cd -- "${BASH_SOURCE[0]%/*}/../hooks" 2>/dev/null && pwd)" || exit 0
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
MSG=$(printf '%s' "$COMMAND" | python3 "$HOOKS_DIR/commit_command.py" "$CWD" 2>/dev/null)
PARSER_STATUS=$?

if [ "$PARSER_STATUS" -eq 1 ]; then
  exit 0
fi
if [ "$PARSER_STATUS" -ne 0 ]; then
  debug_logging_note error commit_parser_failed 2>/dev/null || true
  exit 0
fi

debug_logging_note warn commit_format 2>/dev/null || true
jq -n --arg msg "$MSG" '{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": ("Commit message does not match format {type}({scope}): {desc}. Got: " + $msg)
  }
}'

exit 0
