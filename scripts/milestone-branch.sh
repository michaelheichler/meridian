#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/lbwc-settings.sh"

action="${1:?Usage: milestone-branch.sh <start|complete> [planning-dir] [slug]}"
planning_dir="${2:-.lbwc-planning}"
case "$action" in start|complete) ;; *) exit 1 ;; esac
config=$(lbwc_merged_config "$planning_dir/config.json")
enabled=$(jq -r 'if .branch_per_milestone == null then false else .branch_per_milestone end' <<< "$config")
if [ "$enabled" != true ]; then
  printf 'branch_action=disabled\n'
  exit 0
fi
slug="${3:-}"
[ -n "$slug" ] || slug=$(bash "$SCRIPT_DIR/derive-milestone-slug.sh" "$planning_dir")
case "$slug" in ''|*[!a-z0-9-]*) printf 'Error: invalid milestone slug\n' >&2; exit 1 ;; esac
branch="milestone/$slug"
state=$(git rev-parse --git-path "lbwc-milestone-$slug.json")
if [ "$action" = complete ]; then
  if [ -f "$state" ]; then
    jq -r '"branch_action=offer_merge\nbranch=" + .branch + "\nmerge_target=" + .base' "$state"
  else
    printf 'branch_action=no_managed_branch\n'
  fi
  exit 0
fi
if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
  printf 'Error: milestone branch requires a clean working tree\n' >&2
  exit 1
fi
current=$(git symbolic-ref --quiet --short HEAD) || { printf 'Error: detached HEAD\n' >&2; exit 1; }
if [ "$current" = "$branch" ] && [ -f "$state" ]; then
  printf 'branch_action=already_started\nbranch=%s\n' "$branch"
  exit 0
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
