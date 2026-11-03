#!/bin/bash

. "$(CDPATH="" cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/rename-migration.sh"
meridian_migrate_environment
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/lib/manifest-lock.sh"
. "$SCRIPT_DIR/lib/meridian-control-root.sh"

usage() {
  printf '%s\n' 'Usage: explorer-journal.sh append --trigger precompact|pause|phase-end [--command TEXT] [--request TEXT] [--questions TEXT] [--next TEXT]' '       explorer-journal.sh current' >&2
  exit 2
}

parse_append() {
  local flag value
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || usage
    flag="$1"
    value="$2"
    case "$flag" in
      --trigger) printf -v TRIGGER '%s' "$value" ;;
      --command) printf -v ACTIVE_COMMAND '%s' "$value" ;;
      --request) printf -v ORIGINAL_REQUEST '%s' "$value" ;;
      --questions) printf -v OPEN_QUESTIONS '%s' "$value" ;;
      --next) printf -v NEXT_STEP '%s' "$value" ;;
      *) usage ;;
    esac
    shift 2
  done
  case "$TRIGGER" in
    precompact|pause|phase-end) ;;
    *) usage ;;
  esac
}

journal_field() {
  printf '\n### %s\n\n' "$1"
  printf '%s\n' "$2" | sed 's/^/    /'
}

journal_git_field() {
  local label="$1" result
  shift
  result=$(git "$@" 2>/dev/null) || result=unavailable
  journal_field "$label" "$result"
}

build_entry() {
  local timestamp
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
  printf '## %s %s\n' "$timestamp" "$TRIGGER" || return 1
  journal_git_field Branch symbolic-ref --quiet --short HEAD || return 1
  journal_git_field HEAD rev-parse --verify HEAD || return 1
  journal_git_field Worktrees worktree list || return 1
  journal_git_field 'Diff stat' diff --stat || return 1
  journal_git_field Stashes stash list || return 1
  journal_field 'Active command' "$ACTIVE_COMMAND" || return 1
  journal_field 'Original request' "$ORIGINAL_REQUEST" || return 1
  journal_field 'Open questions' "$OPEN_QUESTIONS" || return 1
  journal_field 'Next step' "$NEXT_STEP"
}

rotation_boundary() {
  local journal="$1"
  LC_ALL=C awk '
    /^## / { starts[++count] = NR; sizes[count] = 0 }
    { sizes[count] += length($0) + 1; total += length($0) + 1 }
    END {
      oldest = 1
      while (total >= 8192 && oldest < count) {
        total -= sizes[oldest++]
      }
      print starts[oldest] + 0
    }
  ' "$journal"
}

publish_entry() {
  local scratch="$1" journal="$PLANNING_DIR/EXPLORER-JOURNAL.md"
  local boundary first_date archive
  if [ -f "$journal" ]; then
    cat "$journal" > "$scratch/combined" || return 1
  else
    : > "$scratch/combined" || return 1
  fi
  cat "$scratch/entry" >> "$scratch/combined" || return 1
  boundary=$(rotation_boundary "$scratch/combined") || return 1
  if [ "$boundary" -gt 1 ]; then
    first_date=$(awk 'NR == 1 { print substr($2, 1, 10); exit }' "$scratch/combined") || return 1
    archive="$PLANNING_DIR/journal-archive/EXPLORER-JOURNAL-$first_date.md"
    mkdir -p "$PLANNING_DIR/journal-archive" || return 1
    awk -v boundary="$boundary" 'NR < boundary' "$scratch/combined" > "$scratch/older" || return 1
    awk -v boundary="$boundary" 'NR >= boundary' "$scratch/combined" > "$scratch/live" || return 1
    cat "$scratch/older" >> "$archive" || return 1
    mv -f "$scratch/live" "$journal" || return 1
  else
    mv -f "$scratch/combined" "$journal" || return 1
  fi
}

append_locked() (
  local scratch
  scratch=$(mktemp -d "$PLANNING_DIR/.explorer-journal.XXXXXX") || return 1
  trap 'rm -rf "$scratch"' EXIT
  trap 'exit 1' HUP INT TERM
  build_entry > "$scratch/entry" || return 1
  publish_entry "$scratch"
)

current_entry() {
  local journal="$PLANNING_DIR/EXPLORER-JOURNAL.md"
  [ -f "$journal" ] || return 0
  awk '
    /^## / { entry = "" }
    { entry = entry $0 "\n" }
    END { printf "%s", entry }
  ' "$journal"
}

main() {
  local action="${1:-}"
  [ "$#" -gt 0 ] || usage
  shift
  case "$action" in
    append) parse_append "$@" ;;
    current) [ "$#" -eq 0 ] || usage ;;
    *) usage ;;
  esac
  local resolved
  resolved=$(meridian_resolve_control_root "${MERIDIAN_CONTROL_ROOT:-}" "" "$PWD" 2>/dev/null || true)
  [ -n "$resolved" ] || resolved="${MERIDIAN_PLANNING_DIR:-.meridian}"
  printf -v PLANNING_DIR '%s' "$resolved"
  case "$action" in
    append)
      manifest_lock_with_lock "$PLANNING_DIR/.explorer-journal.lock" EXPLORER_JOURNAL append_locked || {
        printf '%s\n' 'explorer-journal.sh could not append journal entry' >&2
        return 1
      }
      ;;
    current) current_entry ;;
  esac
}

TRIGGER=''
ACTIVE_COMMAND=''
ORIGINAL_REQUEST=''
OPEN_QUESTIONS=''
NEXT_STEP=''
PLANNING_DIR=''
main "$@"
