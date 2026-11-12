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
set -u

command -v jq >/dev/null 2>&1 || {
  printf 'MERIDIAN status unavailable: jq is required\n'
  exit 0
}

STATUS_INPUT=$(cat 2>/dev/null) || STATUS_INPUT=""

CYAN='\033[36m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
MAGENTA='\033[35m'
BLUE='\033[34m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)
. "$SCRIPT_DIR/lib/meridian-statusline-format.sh"
. "$SCRIPT_DIR/lib/meridian-statusline-state.sh"
. "$SCRIPT_DIR/lib/meridian-statusline-tmux.sh"

NATIVE_FIELDS=$(read_native_fields 2>/dev/null) || {
  printf 'MERIDIAN status unavailable: invalid Claude Code input\n'
  exit 0
}
IFS=$'\x1f' read -r MODEL EFFORT PROJECT_ROOT CONTEXT_PERCENT INPUT_TOKENS OUTPUT_TOKENS CACHE_CREATE CACHE_READ COST DURATION_MS LINES_ADDED LINES_REMOVED FIVE_PERCENT FIVE_RESET SEVEN_PERCENT SEVEN_RESET CONTEXT_RECORD <<< "$NATIVE_FIELDS"
PROJECT_ROOT=${PROJECT_ROOT:-$PWD}
[ -d "$PROJECT_ROOT" ] || PROJECT_ROOT="$PWD"
PROJECT_NAME=$(sanitize_label "$(basename "$PROJECT_ROOT")")
MODEL=$(sanitize_label "${MODEL:-Claude}")
EFFORT=$(sanitize_label "${EFFORT:-default}")
BRANCH=$(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null || printf 'no-git')
BRANCH=$(sanitize_label "${BRANCH:-detached}")
if git -C "$PROJECT_ROOT" status --porcelain --untracked-files=normal 2>/dev/null | grep -q .; then
  DIRTY='dirty'
  DIRTY_COLOR="$YELLOW"
else
  DIRTY='clean'
  DIRTY_COLOR="$GREEN"
fi

PLANNING_DIR="$PROJECT_ROOT/.meridian"
if [ -d "$PLANNING_DIR" ] && [ -n "$CONTEXT_RECORD" ]; then
  CURRENT_CONTEXT_RECORD=''
  IFS= read -r CURRENT_CONTEXT_RECORD 2>/dev/null < "$PLANNING_DIR/.context-usage" || true
  if [ "$CURRENT_CONTEXT_RECORD" != "$CONTEXT_RECORD" ]; then
    CONTEXT_TMP="$PLANNING_DIR/.context-usage.statusline.$$"
    if printf '%s\n' "$CONTEXT_RECORD" > "$CONTEXT_TMP" 2>/dev/null; then
      mv -f -- "$CONTEXT_TMP" "$PLANNING_DIR/.context-usage" 2>/dev/null || true
    fi
  fi
fi
read_orchestration_state
IN_TMUX='false'
[ -n "${TMUX:-}" ] && IN_TMUX='true'
[ "$IN_TMUX" = true ] && read_tmux_runtime_state

if [ "$IN_TMUX" = true ] && [ "$TMUX_COLLAPSE_AGENT" = true ] && is_git_worktree; then
  printf '%bMERIDIAN%b %s@%s  %b%s%b  %s  TMUX agents %s running:%s idle:%s failed:%s stale:%s' "$BOLD$CYAN" "$RESET" "$PROJECT_NAME" "$BRANCH" "$DIRTY_COLOR" "$DIRTY" "$RESET" "$(format_duration "$DURATION_MS")" "$TMUX_AGENT_TOTAL" "$TMUX_RUNNING" "$TMUX_IDLE" "$TMUX_FAILED" "$TMUX_STALE"
  [ -z "$TMUX_DIAGNOSTICS" ] || printf '  Diagnostics %s' "$TMUX_DIAGNOSTICS"
  printf '\n'
  exit 0
fi

printf '%bMERIDIAN%b %b%s%b  %b%s%b  %s@%s  %b%s%b  %s\n' "$BOLD$CYAN" "$RESET" "$MAGENTA" "$MODEL" "$RESET" "$BLUE" "$EFFORT" "$RESET" "$PROJECT_NAME" "$BRANCH" "$DIRTY_COLOR" "$DIRTY" "$RESET" "$(format_duration "$DURATION_MS")"
printf '%bContext%b [' "$BOLD" "$RESET"
progress_bar "$CONTEXT_PERCENT"
printf '] %s%%  in %s  out %s  cache %s/%s  cost $%.2f  lines %b+%s%b/%b-%s%b\n' "$CONTEXT_PERCENT" "$(format_tokens "$INPUT_TOKENS")" "$(format_tokens "$OUTPUT_TOKENS")" "$(format_tokens "$CACHE_READ")" "$(format_tokens "$CACHE_CREATE")" "$COST" "$GREEN" "$LINES_ADDED" "$RESET" "$RED" "$LINES_REMOVED" "$RESET"
if { [ -n "$FIVE_PERCENT" ] || [ -n "$SEVEN_PERCENT" ]; } && ! limits_line_hidden; then
  printf '%bQuota%b ' "$BOLD" "$RESET"
  if [ -n "$FIVE_PERCENT" ]; then
    FIVE_PERCENT=${FIVE_PERCENT%.*}
    printf '5h ['; progress_bar "$FIVE_PERCENT"; printf '] %s%% reset %s' "$FIVE_PERCENT" "$(format_reset "$FIVE_RESET")"
  fi
  if [ -n "$SEVEN_PERCENT" ]; then
    SEVEN_PERCENT=${SEVEN_PERCENT%.*}
    [ -n "$FIVE_PERCENT" ] && printf '  '
    printf '7d ['; progress_bar "$SEVEN_PERCENT"; printf '] %s%% reset %s' "$SEVEN_PERCENT" "$(format_reset "$SEVEN_RESET")"
  fi
  printf '\n'
fi
if [ "$IN_TMUX" != true ] || [ "$TMUX_HIDE_AGENT" != true ]; then
  printf '%bFlow%b phase %s  task %s  pair %s  trio %s\n' "$BOLD" "$RESET" "$(sanitize_label "$PHASE")" "$(sanitize_label "$TASK")" "$(sanitize_label "$PAIR")" "$(sanitize_label "$TRIO")"
fi
printf '%bQuality%b QA %s  UAT %s  %bTelemetry%b %s\n' "$BOLD" "$RESET" "$(sanitize_label "$QA_STATE")" "$(sanitize_label "$UAT_STATE")" "$BOLD" "$RESET" "$(sanitize_label "$TELEMETRY_STATE")"
if [ "$IN_TMUX" = true ]; then
  printf 'Backend %s\n' "$(sanitize_label "$TMUX_BACKEND")"
  if [ "$TMUX_BACKEND" = tmux ]; then
    printf 'TMUX session %s %s  panes %s  agents %s running:%s idle:%s failed:%s  stale %s failed %s\n' "$(sanitize_label "$TMUX_SESSION")" "$TMUX_SESSION_STATUS" "$TMUX_PANES" "$TMUX_AGENT_TOTAL" "$TMUX_RUNNING" "$TMUX_IDLE" "$TMUX_FAILED" "$TMUX_STALE" "$TMUX_FAILED"
  fi
  [ -z "$TMUX_DIAGNOSTICS" ] || printf 'Diagnostics %s\n' "$TMUX_DIAGNOSTICS"
fi
