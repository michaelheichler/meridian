#!/bin/bash
set -u
. "$(CDPATH='' cd -- "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd)/lib/debug-logging.sh" 2>/dev/null || true
debug_logging_gate security-filter.sh PreToolUse 2>/dev/null || true

if ! command -v jq >/dev/null 2>&1; then
  echo "meridian hook warning: security-filter jq not available, call allowed" >&2
  exit 0
fi

INPUT=$(cat 2>/dev/null) || exit 2
[ -z "$INPUT" ] && exit 2

HAS_PATH=$(echo "$INPUT" | jq -r '(.tool_input.file_path != null) or (.tool_input.path != null)' 2>/dev/null) || exit 2

if [ "$HAS_PATH" != "true" ]; then
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // ""' 2>/dev/null) || exit 2

if [ -z "$FILE_PATH" ]; then
  exit 2
fi

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null) || exit 2
BUILD_DIRS='|(^|/)dist/|(^|/)build/'
# Reading build output is harmless, so only writes stay blocked there.
case "$TOOL_NAME" in Read|Grep) BUILD_DIRS='' ;; esac

if echo "$FILE_PATH" | grep -qE '\.env$|\.env\.|(^|/)[^/]+\.(pem|key|cert|p12|pfx)(\.[A-Za-z0-9]+)?($|/)|credentials\.json$|secrets\.json$|service-account.*\.json$|(^|/)node_modules/|(^|/)\.git/|(^|/)\.temporary-agent-runfiles/'"$BUILD_DIRS"; then
  echo "Blocked: sensitive file ($FILE_PATH)" >&2
  exit 2
fi

exit 0
