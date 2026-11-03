#!/bin/bash

. "$(CDPATH="" cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/rename-migration.sh"
meridian_migrate_environment
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/lib/meridian-control-root.sh"
PLANNING_DIR=$(meridian_resolve_control_root "${MERIDIAN_CONTROL_ROOT:-}" "" "$PWD" 2>/dev/null) || PLANNING_DIR=""
[ -n "$PLANNING_DIR" ] || PLANNING_DIR="${MERIDIAN_PLANNING_DIR:-.meridian}"
export MERIDIAN_PLANNING_DIR="$PLANNING_DIR"

commit_delta() {
  local journal_head="$1" resolved_head current_head count
  if ! resolved_head=$(git rev-parse --verify "${journal_head}^{commit}" 2>/dev/null); then
    printf '%s\n' 'Journal HEAD is unknown or unreachable. Cannot compute journal commit delta.'
    return 0
  fi
  current_head=$(git rev-parse --verify HEAD 2>/dev/null) || {
    printf '%s\n' 'Current HEAD is unknown or unreachable. Cannot compute journal commit delta.'
    return 0
  }
  if ! git merge-base --is-ancestor "$resolved_head" "$current_head" 2>/dev/null; then
    printf '%s\n' 'Journal HEAD is unreachable from current HEAD. History may have changed after a rebase.'
    return 0
  fi
  if [ "$resolved_head" != "$current_head" ]; then
    count=$(git rev-list --count "$resolved_head..HEAD") || return 1
    printf 'Journal is stale. HEAD moved by %s commit(s) since the entry.\n' "$count"
    git log --oneline "$resolved_head..HEAD" || return 1
  fi
}

journal_delta() {
  local entry journal_head
  entry=$(bash "$SCRIPT_DIR/explorer-journal.sh" current) || return 1
  if [ -z "$entry" ]; then
    printf '%s\n' 'No explorer journal entry. Restore context from planning state.'
    return 0
  fi
  printf '%s\n' "$entry"
  journal_head=$(printf '%s\n' "$entry" | awk '
    /^### HEAD$/ { in_head = 1; next }
    in_head && /^### / { exit }
    in_head && NF { print $1; exit }
  ')
  commit_delta "$journal_head"
}

active_phase_files() {
  local detected phase slug directory file
  detected=$(bash "$SCRIPT_DIR/phase-detect.sh") || return 1
  if printf '%s\n' "$detected" | grep -q '^phase_detect_error=true$'; then
    printf '%s\n' 'Active phase unavailable. Phase detection failed.'
    return 1
  fi
  phase=$(printf '%s\n' "$detected" | sed -n 's/^next_phase=//p')
  slug=$(printf '%s\n' "$detected" | sed -n 's/^next_phase_slug=//p')
  case "$phase" in
    ''|none) return 0 ;;
    *[!0-9]*) printf '%s\n' 'Active phase unavailable. Invalid phase number.'; return 1 ;;
  esac
  directory="$PLANNING_DIR/phases/$slug"
  [ -d "$directory" ] || return 0
  for file in "$directory"/[0-9]*-PLAN.md "$directory"/PLAN.md "$directory"/[0-9]*-SUMMARY.md "$directory"/SUMMARY.md; do
    [ -f "$file" ] && printf 'active_phase_file=%s\n' "$file"
  done
  return 0
}

consistency_findings() {
  local findings status
  findings=$(bash "$SCRIPT_DIR/verify-state-consistency.sh")
  status=$?
  printf '%s\n' "$findings" | sed '/^state_consistency=ok$/d; /^state_consistency=no_planning_dir$/d; /^$/d'
  [ "$status" -le 1 ] || return "$status"
}

main() {
  local status=0
  journal_delta || status=1
  git diff --stat || status=1
  active_phase_files || status=1
  consistency_findings || status=1
  return "$status"
}

main "$@"
