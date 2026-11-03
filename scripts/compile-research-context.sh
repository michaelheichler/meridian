#!/usr/bin/env bash

. "$(CDPATH="" cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/rename-migration.sh"
meridian_migrate_environment

set -euo pipefail

STALE_WARN_THRESHOLD=10   # Past this many commits research is skipped because it no longer matches the code

PLANNING_DIR="${1:-}"
if [ -z "$PLANNING_DIR" ]; then
  echo "Usage: compile-research-context.sh <planning-dir> [description]" >&2
  exit 0
fi
shift

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/compile-research-emit.sh"
. "$SCRIPT_DIR/lib/display-glyphs.sh"
meridian_glyphs_load "$PLANNING_DIR"
meridian_glyph GLYPH_WARNING warning

EXPLICIT_FILE=""
DESCRIPTION=""

while [ $# -gt 0 ]; do
  case "$1" in
    --file)
      EXPLICIT_FILE="${2:-}"
      if [ -z "$EXPLICIT_FILE" ]; then
        echo "[research] --file requires a path argument" >&2
        exit 0
      fi
      shift 2
      ;;
    *)
      if [ -n "$DESCRIPTION" ]; then
        DESCRIPTION="${DESCRIPTION} $1"
      else
        DESCRIPTION="$1"
      fi
      shift
      ;;
  esac
done

if [ -n "$EXPLICIT_FILE" ]; then
  if [ ! -f "$EXPLICIT_FILE" ]; then
    echo "[research] Specified file not found: $EXPLICIT_FILE" >&2
    exit 0
  fi
  echo "[research] Using explicitly specified research: $(basename "$EXPLICIT_FILE")" >&2
  meridian_glyph_file "$EXPLICIT_FILE"
  exit 0
fi

RESEARCH_LIST=$(bash "$SCRIPT_DIR/research-session-state.sh" list "$PLANNING_DIR" --status complete 2>/dev/null || echo "")

if [ -z "$RESEARCH_LIST" ]; then
  exit 0
fi

if [ -z "$DESCRIPTION" ]; then
  exit 0
fi

DESC_WORDS=$(printf '%s' "$DESCRIPTION" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '\n' | awk 'length >= 3' | sort -u)

if [ -z "$DESC_WORDS" ]; then
  exit 0
fi

BEST_FILE=""
BEST_SCORE=0

while IFS= read -r line; do
  file=$(echo "$line" | jq -r '.file')
  title=$(echo "$line" | jq -r '.title')
  title_lower=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]')

  score=0
  while IFS= read -r word; do
    [ -z "$word" ] && continue
    case "$title_lower" in
      *"$word"*) score=$((score + 1)) ;;
    esac
  done <<< "$DESC_WORDS"

  if [ "$score" -gt "$BEST_SCORE" ]; then
    BEST_SCORE=$score
    BEST_FILE=$file
  fi
done <<< "$RESEARCH_LIST"

if [ "$BEST_SCORE" -ge 2 ] && [ -n "$BEST_FILE" ] && [ -f "$BEST_FILE" ]; then
  emit_research "$BEST_FILE"
fi

exit 0
