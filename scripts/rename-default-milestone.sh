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

PLANNING_DIR="${1:-}"
if [[ -z "$PLANNING_DIR" ]]; then
  echo "Usage: rename-default-milestone.sh PLANNING_DIR" >&2
  exit 1
fi
DEFAULT_DIR="$PLANNING_DIR/milestones/default"
if [[ ! -d "$DEFAULT_DIR" ]]; then
  exit 0
fi
normalize_slug() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | \
    sed 's/[^a-z0-9 -]//g' | \
    sed 's/  */ /g' | \
    tr ' ' '-' | \
    sed 's/--*/-/g' | \
    sed 's/^-//;s/-$//'
}
shipped_title_slug() {
  local shipped_content="$1" title_name title_name_lc
  title_name=$(printf '%s\n' "$shipped_content" | awk '
    tolower($0) ~ /^#[[:space:]]*shipped:[[:space:]]*/ {
      sub(/^#[[:space:]]*[Ss][Hh][Ii][Pp][Pp][Ee][Dd]:[[:space:]]*/, "", $0)
      print
      exit
    }
  ')
  title_name_lc=$(printf '%s\n' "$title_name" | tr '[:upper:]' '[:lower:]')
  [[ -n "$title_name" && "$title_name_lc" != "default milestone" ]] || return 0
  normalize_slug "$title_name"
}

shipped_phases_slug() {
  local shipped_content="$1" phases slug
  phases=$(printf '%s\n' "$shipped_content" | awk '
    tolower($0) ~ /^##[[:space:]]+phases[[:space:]]*$/ { found=1; next }
    found && /^## / { exit }
    found && /^[-*] / {
      sub(/^[-*] +(Phase [0-9]+: )?/, "")
      sub(/ - .*/, "")
      if (length > 0) print
    }
    found && /^[0-9]+\. / {
      sub(/^[0-9]+\. +/, "")
      gsub(/\*\*/, "")
      sub(/ - .*/, "")
      if (length > 0) print
    }
  ' | head -2)
  [[ -n "$phases" ]] || return 0
  slug=$(echo "$phases" | tr '\n' ' ' | sed 's/ $//')
  normalize_slug "$slug"
}

shipped_slug() {
  local shipped="$DEFAULT_DIR/SHIPPED.md" shipped_content slug
  [[ -f "$shipped" ]] || return 0
  shipped_content=$(cat "$shipped")
  shipped_content="${shipped_content//$'\xE2\x80\x94'/-}"
  shipped_content="${shipped_content//$'\xE2\x80\x93'/-}"
  slug=$(shipped_title_slug "$shipped_content")
  if [[ -n "$slug" ]]; then
    printf '%s\n' "$slug"
    return 0
  fi
  shipped_phases_slug "$shipped_content"
}

derive_slug() {
  local slug phase_dirs
  slug=$(shipped_slug)
  if [[ -z "$slug" && -d "$DEFAULT_DIR/phases" ]]; then
    phase_dirs=$(ls -1 "$DEFAULT_DIR/phases/" 2>/dev/null | head -2 | sed 's/^[0-9]*-//')
    if [[ -n "$phase_dirs" ]]; then
      slug=$(echo "$phase_dirs" | tr '\n' ' ' | sed 's/ $//')
      slug=$(normalize_slug "$slug")
    fi
  fi
  if [[ -z "$slug" ]]; then
    slug="milestone-$(date +%Y%m%d)"
  fi
  echo "$slug" | head -c 50 | sed 's/-$//'
}
milestone_number() {
  local count=0
  if [[ -d "$PLANNING_DIR/milestones" ]]; then
    local d
    for d in "$PLANNING_DIR/milestones"/*/; do
      [[ -d "$d" ]] || continue
      [[ "$(basename "$d")" == "default" ]] && continue
      count=$((count + 1))
    done
  fi
  printf "%02d" $((count + 1))
}
slug_name=$(derive_slug)
ms_num=$(milestone_number)
if [[ -z "$slug_name" ]]; then
  slug_name="milestone-$(date +%Y%m%d)"
fi
new_slug="${ms_num}-${slug_name}"
new_dir="$PLANNING_DIR/milestones/$new_slug"
if [[ -d "$new_dir" ]]; then
  suffix=1
  while [[ -d "${new_dir}-${suffix}" ]]; do
    suffix=$((suffix + 1))
    if [[ $suffix -gt 10 ]]; then
      echo "Error: cannot find unique name for milestone dir (tried $new_slug through $new_slug-10)" >&2
      exit 1
    fi
  done
  new_dir="${new_dir}-${suffix}"
fi
mv "$DEFAULT_DIR" "$new_dir"
exit 0
