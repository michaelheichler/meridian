#!/usr/bin/env bash

. "$(CDPATH="" cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/rename-migration.sh"
meridian_migrate_environment
set -euo pipefail

. "$(dirname "$0")/resolve-claude-dir.sh" 2>/dev/null || true
. "$(dirname "$0")/lib/display-glyphs.sh"
meridian_glyphs_load
meridian_glyph GLYPH_WARNING warning
meridian_glyph GLYPH_NEXT next
meridian_glyph GLYPH_TOP_LEFT top_left
meridian_glyph GLYPH_TOP_RIGHT top_right
meridian_glyph GLYPH_BOTTOM_LEFT bottom_left
meridian_glyph GLYPH_BOTTOM_RIGHT bottom_right
meridian_glyph GLYPH_VERTICAL vertical
meridian_glyph_repeat GLYPH_HORIZONTAL horizontal 74
meridian_glyph_repeat GLYPH_RULE rule 70

PLUGIN_ROOT="${1:-${CLAUDE_PLUGIN_ROOT:-}}"
if [ -z "$PLUGIN_ROOT" ]; then
  PLUGIN_ROOT=$(find "${CLAUDE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}/plugins/cache/meridian-marketplace/meridian" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | (sort -V 2>/dev/null || sort -t. -k1,1n -k2,2n -k3,3n) | tail -1 || true)
fi
if [ -z "$PLUGIN_ROOT" ] || [ ! -d "$PLUGIN_ROOT" ]; then
  PLUGIN_ROOT="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
fi

COMMANDS_DIR="$PLUGIN_ROOT/commands"
PLUGIN_MANIFEST="$PLUGIN_ROOT/.claude-plugin/plugin.json"

if [ ! -d "$COMMANDS_DIR" ]; then
  echo "${GLYPH_WARNING} Commands directory not found: $COMMANDS_DIR"
  exit 1
fi

if [ ! -f "$PLUGIN_MANIFEST" ]; then
  echo "${GLYPH_WARNING} Plugin manifest not found: $PLUGIN_MANIFEST"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "${GLYPH_WARNING} jq is required to read the plugin manifest"
  exit 1
fi
PLUGIN_NAME=$(jq -er '.name | select(type == "string" and length > 0)' "$PLUGIN_MANIFEST") || {
  echo "${GLYPH_WARNING} Plugin manifest has no valid name: $PLUGIN_MANIFEST"
  exit 1
}

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

for cat in lifecycle monitoring supporting advanced other; do
  : > "$TMP_DIR/$cat"
done

for file in "$COMMANDS_DIR"/*.md; do
  [ -f "$file" ] || continue

  slug=${file##*/}
  slug=${slug%.md}
  description=""
  category=""
  hint=""
  hidden=""
  in_frontmatter=0

  while IFS= read -r line; do
    if [ "$in_frontmatter" -eq 0 ] && [ "$line" = "---" ]; then
      in_frontmatter=1
      continue
    fi
    if [ "$in_frontmatter" -eq 1 ] && [ "$line" = "---" ]; then
      break
    fi
    if [ "$in_frontmatter" -eq 1 ]; then
      case "$line" in
        description:*) description="${line#description: }" ; description="${description#description:}" ; description="${description# }" ; description="${description#\"}" ; description="${description%\"}" ;;
        category:*) category="${line#category: }" ; category="${category#category:}" ; category="${category# }" ;;
        argument-hint:*) hint="${line#argument-hint: }" ; hint="${hint#argument-hint:}" ; hint="${hint# }" ; hint="${hint#\"}" ; hint="${hint%\"}" ;;
        hidden:*) hidden="${line#hidden: }" ; hidden="${hidden#hidden:}" ; hidden="${hidden# }" ;;
      esac
    fi
  done < "$file"

  [ "$hidden" = "true" ] && continue

  if [ -n "$hint" ]; then
    entry="  /$PLUGIN_NAME:$slug $hint"
  else
    entry="  /$PLUGIN_NAME:$slug"
  fi
  padded=$(printf "%-42s" "$entry")
  display_line="$padded $description"

  case "$category" in
    lifecycle)   echo "$display_line" >> "$TMP_DIR/lifecycle" ;;
    monitoring)  echo "$display_line" >> "$TMP_DIR/monitoring" ;;
    supporting)  echo "$display_line" >> "$TMP_DIR/supporting" ;;
    advanced)    echo "$display_line" >> "$TMP_DIR/advanced" ;;
    *)           echo "$display_line" >> "$TMP_DIR/other" ;;
  esac
done

VERSION=""
if [ -f "$PLUGIN_ROOT/VERSION" ]; then
  VERSION=$(cat "$PLUGIN_ROOT/VERSION")
fi

printf '%s%s%s\n' "$GLYPH_TOP_LEFT" "$GLYPH_HORIZONTAL" "$GLYPH_TOP_RIGHT"
if [ -n "$VERSION" ]; then
  header="MERIDIAN Help, v$VERSION"
else
  header="MERIDIAN Help"
fi
padding=$((72 - ${#header}))
printf '%s %s%*s%s\n' "$GLYPH_VERTICAL" "$header" "$padding" "" "$GLYPH_VERTICAL"
printf '%s%s%s\n' "$GLYPH_BOTTOM_LEFT" "$GLYPH_HORIZONTAL" "$GLYPH_BOTTOM_RIGHT"
echo ""

print_section() {
  local title="$1"
  local subtitle="$2"
  local file="$3"

  [ -s "$file" ] || return 0

  echo "  $title, $subtitle"
  printf '  %s\n' "$GLYPH_RULE"
  sort < "$file"
  echo ""
}

print_section "Lifecycle"  "The Main Loop"                  "$TMP_DIR/lifecycle"
print_section "Monitoring" "Trust But Verify"               "$TMP_DIR/monitoring"
print_section "Supporting" "The Safety Net"                  "$TMP_DIR/supporting"
print_section "Advanced"   "For When You're Feeling Ambitious" "$TMP_DIR/advanced"
print_section "Other"      "Uncategorized"                  "$TMP_DIR/other"

echo "  Getting Started: /meridian:init ${GLYPH_NEXT} /meridian:transit ${GLYPH_NEXT} /meridian:transit --archive"
