#!/usr/bin/env bash
set -euo pipefail


SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/lib/claude-md-meridian-sections.sh"

if [ ! -f "$LIB" ]; then
  echo "ERROR: helper library not found at $LIB" >&2
  exit 1
fi

source "$SCRIPT_DIR/lib/claude-md-meridian-sections.sh"

if [ "$#" -ne 1 ]; then
  echo "Usage: refresh-claude-md-meridian-sections.sh CLAUDE.md" >&2
  exit 1
fi

CLAUDE_MD="$1"

if [ ! -f "$CLAUDE_MD" ]; then
  echo "ERROR: CLAUDE.md not found at $CLAUDE_MD" >&2
  exit 1
fi

HAS_NONBLANK_CONTENT=false
if awk '/[^[:space:]]/ { found = 1; exit 0 } END { exit found ? 0 : 1 }' "$CLAUDE_MD"; then
  HAS_NONBLANK_CONTENT=true
fi

INCLUDE_ACTIVE_CONTEXT=false
INCLUDE_MERIDIAN_RULES=false
INCLUDE_CODE_INTELLIGENCE=false
INCLUDE_PLUGIN_ISOLATION=false

if meridian_should_emit_managed_section "$CLAUDE_MD" "Active Context" "## Active Context"; then
  INCLUDE_ACTIVE_CONTEXT=true
fi

if meridian_should_emit_managed_section "$CLAUDE_MD" "MERIDIAN Rules" "## MERIDIAN Rules"; then
  INCLUDE_MERIDIAN_RULES=true
fi

if meridian_should_emit_code_intelligence_section "$CLAUDE_MD"; then
  INCLUDE_CODE_INTELLIGENCE=true
fi

if meridian_should_emit_managed_section "$CLAUDE_MD" "Plugin Isolation" "## Plugin Isolation"; then
  INCLUDE_PLUGIN_ISOLATION=true
fi

TMP_STRIPPED="$(mktemp)"
TMP_OUT="$(mktemp)"
trap 'rm -f "$TMP_STRIPPED" "$TMP_OUT"' EXIT

meridian_strip_legacy_refresh_sections "$CLAUDE_MD" "$TMP_STRIPPED"

trim_trailing_blank_lines() {
  awk '
    { lines[NR] = $0 }
    /[^[:space:]]/ { last_nonblank = NR }
    END {
      if (last_nonblank == 0) {
        exit 0
      }
      for (i = 1; i <= last_nonblank; i++) {
        print lines[i]
      }
    }
  ' "$1"
}

CONTENT_WRITTEN=false

{
  if [ "$HAS_NONBLANK_CONTENT" = true ]; then
    trim_trailing_blank_lines "$TMP_STRIPPED"
    CONTENT_WRITTEN=true
  fi

  if [ "$INCLUDE_ACTIVE_CONTEXT" = true ]; then
    if [ "$CONTENT_WRITTEN" = true ]; then echo ""; fi
    meridian_generate_active_context_section
    CONTENT_WRITTEN=true
  fi

  if [ "$INCLUDE_MERIDIAN_RULES" = true ]; then
    if [ "$CONTENT_WRITTEN" = true ]; then echo ""; fi
    meridian_generate_meridian_rules_section
    CONTENT_WRITTEN=true
  fi

  if [ "$INCLUDE_CODE_INTELLIGENCE" = true ]; then
    if [ "$CONTENT_WRITTEN" = true ]; then echo ""; fi
    meridian_generate_code_intelligence_section
    CONTENT_WRITTEN=true
  fi

  if [ "$INCLUDE_PLUGIN_ISOLATION" = true ]; then
    if [ "$CONTENT_WRITTEN" = true ]; then echo ""; fi
    meridian_generate_plugin_isolation_section
    CONTENT_WRITTEN=true
  fi
} > "$TMP_OUT"

cat "$TMP_OUT" > "$CLAUDE_MD"

exit 0