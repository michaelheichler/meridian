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

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/lib/display-glyphs.sh"

safe_cell() {
  local _cell_target="$1" _cell_value="$2" _cell_character
  _cell_value=${_cell_value//[[:cntrl:]]/ }
  for _cell_character in '\' '|' '`' '[' ']' '<' '>' '*' '_'; do
    _cell_value=${_cell_value//"$_cell_character"/"\\$_cell_character"}
  done
  printf -v "$_cell_target" '%s' "$_cell_value"
}

row() {
  local label="$1" value="$2"
  safe_cell label "$label"
  safe_cell value "$value"
  printf '| %s | %s |\n' "$label" "$value"
}

failure_card() {
  local reason="$1" failed_glyph
  meridian_glyph failed_glyph failed
  row "$failed_glyph failed" 'Feedback unavailable'
  printf '| --- | --- |\n'
  row Cause "$reason"
  row Fix 'Correct the input and run status-card.sh again'
  row Ask 'No completion claim accepted'
  printf '\n**Next.** Retry this step.\n\n**You approve.** Correct the input before continuing.\n'
  exit 1
}

command -v jq >/dev/null 2>&1 || failure_card 'jq is required to validate result JSON'
meridian_glyphs_load
[ "$#" -eq 2 ] || failure_card 'Usage status-card.sh PHASE_FILE RESULT_JSON_FILE'
[ -r "$1" ] || failure_card 'Cannot read phase-detect output'
[ -r "$2" ] || failure_card 'Cannot read result JSON'
phase=''
phase_complete=false
phase_error=false
while IFS='=' read -r key value || [ -n "$key" ]; do
  case "$key" in
    next_phase) phase="$value" ;;
    phase_detect_complete) phase_complete="$value" ;;
    phase_detect_error) phase_error="$value" ;;
  esac
done < "$1"
[ -n "$phase" ] || failure_card 'Missing next_phase in phase-detect output'
[ "$phase_complete" = true ] && [ "$phase_error" != true ] || failure_card 'Incomplete or failed phase-detect output'

meridian_glyph done_glyph done
meridian_glyph running_glyph running
meridian_glyph needs_you_glyph needs_you
meridian_glyph failed_glyph failed
output=$(jq -rse --rawfile detector "$1" --arg done "$done_glyph" --arg running "$running_glyph" --arg needs_you "$needs_you_glyph" --arg failed "$failed_glyph" '
  def text: type == "string" and test("[^\\s]");
  def count: type == "number" and . >= 0 and floor == .;
  def code: count and . <= 255;
  def record: map(tostring | gsub("[\u0000-\u001f\u007f]"; " ") |
    if length > 300 then .[0:300] + "..." else . end) | join("\t");
  if length != 1 then error("expected one result object") else .[0] end |
  select(type == "object") |
  select(.status == "done" or .status == "running" or .status == "needs_you" or .status == "failed") |
  select(.changed_files | type == "array" and all(.[]; text)) |
  select(.commands | type == "array" and all(.[];
    type == "object" and (.command | text) and (.exit_code | code) and
    ((has("main_session") | not) or (.main_session | type == "boolean")))) |
  select(.open_questions | type == "array" and all(.[]; text)) |
  select(.product | text) | select(.step | text) | select(.plan | text) |
  select(.tests | text) |
  select(.lines_changed | type == "object" and (.added | count) and (.deleted | count)) |
  select(.next | type == "object" and (.command | text) and (.step | text)) |
  select((has("details") | not) or (.details | type == "array" and all(.[]; text))) |
  select((has("cause") | not) or (.cause | text)) |
  select((has("fix") | not) or (.fix | text)) |
  select(.status != "done" or ((.commands | length) > 0 and
    all(.commands[]; .exit_code == 0 and .main_session == true) and
    (.open_questions | length) == 0)) |
  (if any(.commands[]; .exit_code != 0) then "failed" else .status end) as $status |
  ($detector | split("\n") | map(select(startswith("next_phase="))) | last | ltrimstr("next_phase=")) as $phase |
  (["status", $status, "-"],
   ["header", "\(({done: $done, running: $running, needs_you: $needs_you, failed: $failed})[$status]) \(.step)", "phase \($phase), plan \(.plan), \($status)"],
   ["row", "Product", .product], ["row", "Phase", $phase],
   ["row", "Step", .step], ["row", "Plan", .plan],
   ["row", "Done files", (.changed_files | length)],
   ["row", "Done", "\(.lines_changed.added) lines added"],
   ["row", "Done", "\(.lines_changed.deleted) lines deleted"],
   ["row", "Tests", .tests],
   (if (.commands | length) == 0 then ["row", "Proof", "None, not verified"] else
      .commands[] | ["row", "Proof", "exit \(.exit_code), \(if .main_session == true then "main session re-ran" else "worker only, not verified" end), \(.command)"] end),
   (if $status == "failed" then
      ["row", "Cause", (.cause // "Proof command failed or step reported failure")],
      ((.details // [])[] | ["row", "Detail", .]),
      ["row", "Fix", (.fix // .next.command)] else empty end),
   (if (.open_questions | length) == 0 then ["row", "Ask", "None"] else
      .open_questions[] | ["row", "Ask", .] end),
   ["next", .next.command, .next.step],
   ["approve", "You approve", (if $status == "failed" then "Approve this recovery action, \(.fix // .next.command)."
      elif (.open_questions | length) > 0 then "Answer the open questions before continuing."
      elif $status == "needs_you" then "Confirm \(.next.step) before continuing."
      else "Nothing, Meridian continues." end)]) | record
' "$2" 2>/dev/null) || failure_card 'Invalid result JSON or done result without successful main-session proof'

status=failed
while IFS=$'\t' read -r kind label value; do
  case "$kind" in
    status) status="$label" ;;
    header) row "$label" "$value"; printf '| --- | --- |\n' ;;
    row) row "$label" "$value" ;;
    next) safe_cell label "$label"; safe_cell value "$value"; printf '\n**Next.** %s, %s\n' "$label" "$value" ;;
    approve) safe_cell value "$value"; printf '\n**You approve.** %s\n' "$value" ;;
  esac
done <<< "$output"
[ "$status" != failed ]
