#!/usr/bin/env bash

set -euo pipefail

CMD="${1:-}"
RESULT="${2:-}"
TARGET_PHASE_ARG="${3:-}"
PLANNING_DIR="${LBWC_PLANNING_DIR:-.lbwc-planning}"
PHASES_DIR="$PLANNING_DIR/phases"
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)"
RESOLVE_VERIF_SCRIPT="$SCRIPT_DIR/resolve-verification-path.sh"

. "$SCRIPT_DIR/lib/uat-utils.sh"
read_status_field() { extract_status_value "$@"; }

if [ -f "$SCRIPT_DIR/summary-utils.sh" ]; then
  . "$SCRIPT_DIR/summary-utils.sh"
else
  count_complete_summaries() { echo "0"; }
  extract_summary_status() { :; }
fi
if [ -f "$SCRIPT_DIR/phase-state-utils.sh" ]; then
  . "$SCRIPT_DIR/phase-state-utils.sh"
else
  count_phase_plans() {
    local dir="$1"
    find "$dir" -maxdepth 1 ! -name '.*' \( -name '[0-9]*-PLAN.md' -o -name 'PLAN.md' \) 2>/dev/null | wc -l | tr -d ' '
  }
fi

list_child_dirs_sorted() {
  local parent="$1"
  [ -d "$parent" ] || return 0

  find "$parent" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null |
    (sort -V 2>/dev/null || awk -F/ '{n=$NF; gsub(/[^0-9].*/,"",n); if (n == "") n=0; print (n+0)"\t"$0}' | sort -n -k1,1 -k2,2 | cut -f2-)
}

. "$SCRIPT_DIR/lib/shell-quote-decode.sh"
. "$SCRIPT_DIR/lib/suggest-next-state.sh"
. "$SCRIPT_DIR/lib/suggest-next-verify.sh"
. "$SCRIPT_DIR/lib/suggest-next-helpers.sh"
. "$SCRIPT_DIR/lib/suggest-next-build.sh"
. "$SCRIPT_DIR/lib/suggest-next-review.sh"

load_planning_state

effective_result="${RESULT:-$last_qa_result}"

if [ "$CMD" = "verify" ] && [ "$effective_result" = "issues_found" ] && [ -d "${PHASES_DIR:-}" ]; then
  resolve_verify_target
fi

echo "➜ Next Up"

suggest_for_command
suggest_map_hint
suggest_known_issues_note
