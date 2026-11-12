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

CMD="${1:-}"
PLANNING_DIR="${2:-}"
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$CMD" ] || [ -z "$PLANNING_DIR" ]; then
  echo "Usage: debug-session-state.sh <command> <planning-dir> [args...]" >&2
  exit 1
fi

DEBUG_DIR="$PLANNING_DIR/debugging"
ACTIVE_DIR="$DEBUG_DIR/active"
COMPLETED_DIR="$DEBUG_DIR/completed"
ACTIVE_FILE="$DEBUG_DIR/.active-session"
SKIPPED_NO_FIX_REQUIRED="skipped_no_fix_required"
QA_RESULT_VOCABULARY="qa_last_result: pending | skipped_no_fix_required | pass | fail"
UAT_RESULT_VOCABULARY="uat_last_result: pending | skipped_no_fix_required | pass | issues_found"
: "$QA_RESULT_VOCABULARY" "$UAT_RESULT_VOCABULARY"

. "$SCRIPT_DIR/lib/debug-session-fields.sh"
. "$SCRIPT_DIR/lib/debug-session-locate.sh"
. "$SCRIPT_DIR/lib/debug-session-create.sh"
. "$SCRIPT_DIR/lib/debug-session-commands.sh"

case "$CMD" in
  start) cmd_start "${3:-}" ;;
  start-with-source-todo) cmd_start_with_source_todo "${3:-}" ;;
  start-with-selected-todo) cmd_start_with_selected_todo "${3:-}" "${4:-none}" ;;
  get) cmd_get ;;
  get-or-latest) cmd_get_or_latest ;;
  resume) cmd_resume "${3:-}" ;;
  set-status) cmd_set_status "${3:-}" ;;
  increment-qa) bump_round "qa_round" "qa_last_result" ;;
  increment-uat) bump_round "uat_round" "uat_last_result" ;;
  clear-active) cmd_clear_active ;;
  list) cmd_list ;;
  *)
    echo "Error: unknown command '$CMD'" >&2
    echo "Commands: start, start-with-source-todo, start-with-selected-todo, get, get-or-latest, resume, set-status, increment-qa, increment-uat, clear-active, list" >&2
    exit 1
    ;;
esac
