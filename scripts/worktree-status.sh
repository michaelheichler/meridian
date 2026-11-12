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



PORCELAIN=""
PORCELAIN=$(git worktree list --porcelain 2>/dev/null) || true

json_items=""

current_path=""
current_branch=""
in_meridian_worktree=0

process_stanza() {
  local path="$1"
  local branch="$2"
  local is_meridian="$3"

  [ "$is_meridian" -eq 0 ] && return
  [ -z "$path" ] && return
  [ -z "$branch" ] && return

  local short_branch="${branch#refs/heads/}"

  local suffix="${short_branch#meridian/}"
  local phase="${suffix%%-*}"
  local plan="${suffix#*-}"

  local escaped_path
  escaped_path=$(printf '%s' "$path" | sed 's/\\/\\\\/g; s/"/\\"/g')
  local escaped_branch
  escaped_branch=$(printf '%s' "$short_branch" | sed 's/\\/\\\\/g; s/"/\\"/g')

  local entry
  entry="{\"path\":\"${escaped_path}\",\"branch\":\"${escaped_branch}\",\"phase\":\"${phase}\",\"plan\":\"${plan}\"}"

  if [ -z "$json_items" ]; then
    json_items="$entry"
  else
    json_items="${json_items},${entry}"
  fi
}

while IFS= read -r line || [ -n "$line" ]; do
  if [ -z "$line" ]; then
    process_stanza "$current_path" "$current_branch" "$in_meridian_worktree"
    current_path=""
    current_branch=""
    in_meridian_worktree=0
    continue
  fi

  key="${line%% *}"
  value="${line#* }"

  case "$key" in
    worktree)
      current_path="$value"
      case "$value" in
        *".meridian-worktrees/"*) in_meridian_worktree=1 ;;
        *)                    in_meridian_worktree=0 ;;
      esac
      ;;
    branch)
      current_branch="$value"
      ;;
  esac
done <<EOF
$PORCELAIN
EOF

process_stanza "$current_path" "$current_branch" "$in_meridian_worktree"

printf '[%s]\n' "$json_items"

exit 0
