#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/lib/display-glyphs.sh"
divider='|'
rule='-'

row() {
  local label="$1" value="$2"
  lbwc_glyph_text value "$value"
  value=${value//\\/\\\\}
  value=${value//|/\\|}
  value=${value//$'\r'/ }
  value=${value//$'\n'/ }
  value=${value//$'\t'/ }
  printf '%s %s %s %s %s\n' "$divider" "$label" "$divider" "$value" "$divider"
}

failure_card() {
  local reason="$1" failed_glyph
  lbwc_glyph failed_glyph failed
  row "$failed_glyph failed" 'Feedback unavailable'
  row "$rule$rule$rule" "$rule$rule$rule"
  row Cause "$reason"
  row Fix 'Correct the input and run status-card.sh again'
  row Ask 'No completion claim accepted'
  row Next 'Retry this step'
  exit 1
}

command -v jq >/dev/null 2>&1 || failure_card 'jq is required to validate result JSON'
lbwc_glyphs_load
[ "$#" -eq 2 ] || failure_card 'Usage status-card.sh PHASE_FILE RESULT_JSON_FILE'
[ -r "$1" ] || failure_card 'Cannot read phase-detect output'
[ -r "$2" ] || failure_card 'Cannot read result JSON'
phase='unknown'
phase_complete=false
phase_error=false
while IFS='=' read -r key value || [ -n "$key" ]; do
  case "$key" in
    next_phase) phase="$value" ;;
    phase_detect_complete) phase_complete="$value" ;;
    phase_detect_error) phase_error="$value" ;;
  esac
done < "$1"
[ "$phase_complete" = true ] && [ "$phase_error" != true ] || failure_card 'Incomplete or failed phase-detect output'

result=$(jq -cse '
  def text: type == "string" and test("[^\\s]");
  def count: type == "number" and . >= 0 and floor == .;
  def code: count and . <= 255;
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
    (.open_questions | length) == 0))
' "$2" 2>/dev/null) || failure_card 'Invalid result JSON or done result without successful main-session proof'

status=$(jq -r '.status' <<< "$result")
if jq -e 'any(.commands[]; .exit_code != 0)' <<< "$result" >/dev/null; then
  status=failed
fi
lbwc_glyph status_glyph "$status"
row "$status_glyph $status" "$(jq -r '.step' <<< "$result")"
row "$rule$rule$rule" "$rule$rule$rule"
row Product "$(jq -r '.product' <<< "$result")"
row Phase "$phase"
row Step "$(jq -r '.step' <<< "$result")"
row Plan "$(jq -r '.plan' <<< "$result")"
row 'Done files' "$(jq -r '.changed_files | length' <<< "$result")"
row Done "$(jq -r '"\(.lines_changed.added) lines added"' <<< "$result")"
row Done "$(jq -r '"\(.lines_changed.deleted) lines deleted"' <<< "$result")"
row Tests "$(jq -r '.tests' <<< "$result")"
while IFS= read -r proof; do
  row Proof "$(jq -r '.' <<< "$proof")"
done < <(jq -c '.commands[] | "\(.command) (exit \(.exit_code), \(if .main_session == true then "main session re-ran" else "worker only, not verified" end))"' <<< "$result")
if jq -e '.commands | length == 0' <<< "$result" >/dev/null; then
  row Proof 'None, not verified'
fi
if [ "$status" = failed ]; then
  row Cause "$(jq -r '.cause // "Proof command failed or step reported failure"' <<< "$result")"
  while IFS= read -r detail; do
    row Detail "$(jq -r '.' <<< "$detail")"
  done < <(jq -c '.details // [] | .[]' <<< "$result")
  row Fix "$(jq -r '.fix // .next.command' <<< "$result")"
fi
while IFS= read -r question; do
  row Ask "$(jq -r '.' <<< "$question")"
done < <(jq -c 'if (.open_questions | length) == 0 then "None" else .open_questions[] end' <<< "$result")
row Next "$(jq -r '.next.command' <<< "$result")"
row Next "$(jq -r '.next.step' <<< "$result")"
if [ "$status" = failed ]; then
  printf '\n**You approve.** Review the failure and fix.\n'
else
  printf '\n**You approve.** %s\n' "$(jq -r 'if (.open_questions | length) == 0 then "Nothing, Meridian continues." else "Answer the open questions." end' <<< "$result")"
fi
[ "$status" != failed ]
