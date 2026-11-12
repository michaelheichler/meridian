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

set -euo pipefail

KEEP_LATEST=false
if [[ "${1:-}" == "--keep-latest" ]]; then
  KEEP_LATEST=true
fi

. "$(dirname "$0")/resolve-claude-dir.sh"
PLUGIN_CACHE_DIR="$CLAUDE_DIR/plugins/cache/meridian-marketplace/meridian"
UID_TAG="$(id -u)"
TMP_CACHE_ROOT="${MERIDIAN_TMP_CACHE_ROOT:-/tmp}"

wiped_plugin_cache=false
wiped_temp_caches=false
versions_removed=0

list_real_plugin_versions() {
  local dir
  for dir in "$PLUGIN_CACHE_DIR"/*/; do
    [ -d "$dir" ] || continue
    [ -L "${dir%/}" ] && continue
    printf '%s\n' "$dir"
  done | (sort -V 2>/dev/null || sort -t. -k1,1n -k2,2n -k3,3n)
}

count_plugin_versions() {
  local dir count=0
  for dir in "$PLUGIN_CACHE_DIR"/*/; do
    [ -d "$dir" ] || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

if [[ -d "$PLUGIN_CACHE_DIR" ]]; then
  if [[ "$KEEP_LATEST" == true ]]; then
    VERSIONS=$(list_real_plugin_versions)
    COUNT=$(printf '%s\n' "$VERSIONS" | awk 'NF { c++ } END { print c + 0 }')
    if [[ "$COUNT" -gt 1 ]]; then
      versions_removed=0
      version_index=0
      while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        version_index=$((version_index + 1))
        if [[ "$version_index" -ge "$COUNT" ]]; then
          continue
        fi
        if rm -rf "$dir" 2>/dev/null; then
          versions_removed=$((versions_removed + 1))
        fi
      done <<< "$VERSIONS"
      if [[ "$versions_removed" -gt 0 ]]; then
        wiped_plugin_cache=true
      fi
    fi
  else
    versions_removed=$(count_plugin_versions)
    if rm -rf "$PLUGIN_CACHE_DIR" 2>/dev/null; then
      wiped_plugin_cache=true
    else
      versions_removed=0
      wiped_plugin_cache=false
    fi
  fi
fi

for temp_path in "$TMP_CACHE_ROOT"/meridian-*-"${UID_TAG}"-* "$TMP_CACHE_ROOT"/meridian-*-"${UID_TAG}"; do
  [ -e "$temp_path" ] || [ -L "$temp_path" ] || continue
  rm -rf "$temp_path" 2>/dev/null || true
  wiped_temp_caches=true
done

cat <<EOF
{"wiped":{"plugin_cache":${wiped_plugin_cache},"temp_caches":${wiped_temp_caches},"versions_removed":${versions_removed}}}
EOF
