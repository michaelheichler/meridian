#!/usr/bin/env bash

. "$(CDPATH="" cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/rename-migration.sh"
meridian_migrate_environment
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)"
. "$SCRIPT_DIR/lib/meridian-settings.sh"

action="${1:?Usage: milestone-branch.sh <start|complete|finish> [planning-dir] [slug]}"
planning_dir="${2:-.meridian}"
case "$action" in start|complete|finish) ;; *) exit 1 ;; esac
config=$(meridian_merged_config "$planning_dir/config.json")
enabled=$(jq -r 'if .branch_per_milestone == null then false else .branch_per_milestone end' <<< "$config")
if [ "$enabled" != true ]; then
  printf 'branch_action=disabled\n'
  exit 0
fi
slug="${3:-}"
[ -n "$slug" ] || slug=$(bash "$SCRIPT_DIR/derive-milestone-slug.sh" "$planning_dir")
case "$slug" in ''|*[!a-z0-9-]*) printf 'Error: invalid milestone slug\n' >&2; exit 1 ;; esac
branch="milestone/$slug"
state=$(git rev-parse --git-path "meridian-milestone-$slug.json")
if [ "$action" = complete ]; then
  if [ -f "$state" ]; then
    jq -r '"branch_action=offer_merge\nbranch=" + .branch + "\nmerge_target=" + .base' "$state"
  else
    printf 'branch_action=no_managed_branch\n'
  fi
  exit 0
fi
current=$(git symbolic-ref --quiet --short HEAD) || { printf 'Error: detached HEAD\n' >&2; exit 1; }
if [ "$action" = finish ]; then
  [ -f "$state" ] || { printf 'branch_action=no_managed_branch\n'; exit 0; }
  base=$(jq -er '.base' "$state")
  [ "$current" = "$base" ] && git merge-base --is-ancestor "$branch" HEAD || {
    printf 'Error: finish requires the merged milestone on its original target\n' >&2
    exit 1
  }
  git branch -d "$branch"
  rm -f "$state"
  printf 'branch_action=finished\n'
  exit 0
fi
if [ "$current" = "$branch" ] && [ -f "$state" ]; then
  printf 'branch_action=already_started\nbranch=%s\n' "$branch"
  exit 0
fi
planning_path=$(CDPATH='' cd -- "$planning_dir" && pwd -P)
repo_root=$(git rev-parse --show-toplevel)
repo_root=$(CDPATH='' cd -- "$repo_root" && pwd -P)
case "$planning_path" in
  "$repo_root"/*) planning_relative="${planning_path#"$repo_root"/}" ;;
  *) printf 'Error: planning directory must be inside the repository\n' >&2; exit 1 ;;
esac
if [ -n "$(git -C "$repo_root" status --porcelain --untracked-files=all -- . ":(top,literal,exclude)$planning_relative")" ]; then
  printf 'Error: milestone branch requires a clean working tree outside planning\n' >&2
  exit 1
fi
if git show-ref --verify --quiet "refs/heads/$branch"; then
  printf 'Error: milestone branch already exists without matching active state\n' >&2
  exit 1
fi
git check-ref-format --branch "$branch" >/dev/null
jq -n --arg branch "$branch" --arg base "$current" '{branch: $branch, base: $base}' > "$state"
if ! git checkout -b "$branch"; then
  rm -f "$state"
  exit 1
fi
printf 'branch_action=created\nbranch=%s\nmerge_target=%s\n' "$branch" "$current"
