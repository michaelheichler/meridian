#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)}"
NUDGES_FILE="$PLUGIN_ROOT/config/deviq-nudges.json"
INDEX_FILE="$PLUGIN_ROOT/references/deviq-corpus/index.json"
PLANNING_DIR="${MERIDIAN_PLANNING_DIR:-.meridian}"
STATE_FILE="$PLANNING_DIR/deviq/.nudge-last"
COOLDOWN_SECONDS=120

command -v jq >/dev/null 2>&1 || exit 0
[ -f "$NUDGES_FILE" ] || exit 0
[ -f "$INDEX_FILE" ] || exit 0
[ -d "$PLANNING_DIR" ] || exit 0

INPUT=$(cat 2>/dev/null) || exit 0
[ -n "$INPUT" ] || exit 0

if [ -f "$STATE_FILE" ]; then
  LAST=$(cat "$STATE_FILE" 2>/dev/null)
  case "$LAST" in
    ''|*[!0-9]*) LAST=0 ;;
  esac
  NOW=$(date +%s)
  [ $((NOW - LAST)) -ge "$COOLDOWN_SECONDS" ] || exit 0
fi

emit_nudge() {
  local content='' pattern='' article='' title='' output=''
  IFS= read -r -d '' content || return 0
  while [[ "$content" = *$'\n' ]]; do content=${content%$'\n'}; done
  [ -n "$content" ] || return 0
  while IFS= read -r -d '' pattern; do
    IFS= read -r -d '' article || return 0
    IFS= read -r -d '' title || return 0
    IFS= read -r -d '' output || return 0
    [ -n "$pattern" ] && [ -n "$article" ] || continue
    printf '%s' "$content" | grep -Eiq -- "$pattern" 2>/dev/null || continue
    [ -n "$title" ] || return 0
    mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || return 0
    date +%s > "$STATE_FILE" 2>/dev/null
    printf '%s\n' "$output"
    return 0
  done
}

emit_nudge < <(printf '%s' "$INPUT" | jq -j \
  --slurpfile nudges "$NUDGES_FILE" --slurpfile index "$INDEX_FILE" '
  def text: (if type == "string" then . else tojson end) | gsub("\u0000"; "") | sub("\n+$"; "");
  def field: ., "\u0000";
  (.tool_input.content // .tool_input.new_string // "") |
  select(type == "string") | gsub("\u0000"; "") | field,
  ($nudges[0][] | select(type == "object") |
   (.pattern // "" | text) as $pattern |
   (.article // "" | text) as $article |
   ([$index[0][] | select(.id == $article) | .title | text] | join("\n")) as $title |
   ("DevIQ: this resembles " + $title + " (" + $article + "). Run scripts/deviq-lookup.sh --show " + $article + " for the practice.") as $context |
   ($pattern | field), ($article | field), ($title | field),
   ({hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $context}} | tojson | field))
' 2>/dev/null)

exit 0
