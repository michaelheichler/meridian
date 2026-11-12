#!/usr/bin/env bash

printf -v MERIDIAN_MIGRATION_SOURCE '%s' "${BASH_SOURCE[0]}"
case "$MERIDIAN_MIGRATION_SOURCE" in
  *"/"*) printf -v MERIDIAN_MIGRATION_SOURCE '%s' "${MERIDIAN_MIGRATION_SOURCE%"/"*}" ;;
  *) printf -v MERIDIAN_MIGRATION_SOURCE '%s' . ;;
esac
if [ -f "$MERIDIAN_MIGRATION_SOURCE/../lib/rename-migration.sh" ]; then
  . "$MERIDIAN_MIGRATION_SOURCE/../lib/rename-migration.sh"
  meridian_migrate_environment
fi
unset MERIDIAN_MIGRATION_SOURCE
set -euo pipefail

if [[ $# -lt 4 ]]; then
  echo "Usage: bootstrap-state.sh OUTPUT_PATH PROJECT_NAME MILESTONE_NAME PHASE_COUNT" >&2
  exit 1
fi
OUTPUT_PATH="$1"
PROJECT_NAME="$2"
MILESTONE_NAME="$3"
PHASE_COUNT="$4"
if ! [[ "$PHASE_COUNT" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: PHASE_COUNT must be a positive integer, got: '$PHASE_COUNT'" >&2
  exit 1
fi
STARTED=$(date +%Y-%m-%d)
mkdir -p "$(dirname "$OUTPUT_PATH")"

extract_section() {
  local file="$1" heading="$2"
  awk -v h="$heading" '
    BEGIN { pat = tolower(h) }
    { low = tolower($0) }
    low ~ ("^##[[:space:]]+" pat "[[:space:]]*$") { found=1; next }
    found && /^##[[:space:]]+/ { found=0 }
    found { print }
  ' "$file"
}

extract_todos_section() {
  awk '
    { low = tolower($0) }
    low ~ /^##[[:space:]]+todos[[:space:]]*$/ { found=1; mode="h2"; next }
    low ~ /^###[[:space:]]+pending[[:space:]]+todos[[:space:]]*$/ { found=1; mode="h3"; next }
    found && mode == "h2" && /^##[[:space:]]+/ { found=0; mode="" }
    found && mode == "h3" && (/^## / || /^### /) { found=0; mode="" }
    found { print }
  ' "$1"
}

format_todos_section() {
  local todos="$1" emitted=0 line normalized
  if [[ -z "$todos" ]]; then
    echo "None."
    return 0
  fi
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    normalized=$(printf '%s\n' "$line" | sed -E 's/^[-*][[:space:]]+//' | tr '[:upper:]' '[:lower:]')
    [[ "$normalized" == "none" || "$normalized" == "none." ]] && continue
    echo "$line"
    emitted=1
  done <<< "$todos"
  if [[ "$emitted" -eq 0 ]]; then
    echo "None."
  fi
}

decision_key() {
  local line="$1" escaped_pipe='__MERIDIAN_ESCAPED_PIPE__'
  if [[ "$line" =~ ^\| ]]; then
    line=$(printf '%s\n' "$line" | sed "s/\\\\|/${escaped_pipe}/g" | sed 's/^|//' | sed 's/|$//' | awk -F'|' '{print $1}' | sed "s/${escaped_pipe}/|/g")
  else
    line=$(printf '%s\n' "$line" | sed -E 's/^[-*][[:space:]]+//')
  fi
  printf '%s\n' "$line" | sed -E 's/\*\*//g' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g' | tr '[:upper:]' '[:lower:]'
}

decision_row_score() {
  local line="$1" score=0 escaped_pipe='__MERIDIAN_ESCAPED_PIPE__'
  if [[ "$line" =~ ^\| ]]; then
    local cols col1 col2 col3
    cols=$(printf '%s\n' "$line" | sed "s/\\\\|/${escaped_pipe}/g" | sed 's/^|//' | sed 's/|$//')
    col1=$(printf '%s\n' "$cols" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1); print $1}' | sed "s/${escaped_pipe}/|/g")
    col2=$(printf '%s\n' "$cols" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}' | sed "s/${escaped_pipe}/|/g")
    col3=$(printf '%s\n' "$cols" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3); print $3}' | sed "s/${escaped_pipe}/|/g")
    [ -n "$col1" ] && score=1
    [ -n "$col2" ] && score=$((score + 1))
    [ -n "$col3" ] && score=$((score + 1))
  else
    line=$(printf '%s\n' "$line" | sed -E 's/^[-*][[:space:]]+//')
    [ -n "$line" ] && score=1
  fi
  echo "$score"
}

normalize_decision_row() {
  local line="$1" lower
  if [[ "$line" =~ ^\| ]]; then
    lower=$(printf '%s\n' "$line" | tr '[:upper:]' '[:lower:]')
    [[ "$lower" =~ ^\|([[:space:]:-]+\|)+[[:space:]:-]*$ ]] && return 1
    [[ "$lower" =~ ^\|[[:space:]]*decision([[:space:]]*\|.*)?$ ]] && return 1
    [[ "$lower" =~ ^\|[[:space:]]*_\(no[[:space:]]+decisions[[:space:]]+yet\)_([[:space:]]*\|.*)?$ ]] && return 1
  else
    [[ "$line" =~ ^#+[[:space:]] ]] && return 1
    line=$(printf '%s\n' "$line" | sed -E 's/^[-*][[:space:]]+//')
    lower=$(printf '%s\n' "$line" | tr '[:upper:]' '[:lower:]')
    [[ -z "$line" || "$lower" == "none" || "$lower" == "none." || "$lower" == "_(no decisions yet)_" ]] && return 1
    line=$(printf '%s\n' "$line" | sed 's/|/\\|/g')
    line="| $line | | |"
  fi
  printf '%s\n' "$line"
}

record_decision_row() {
  local line="$1" key score idx found=-1
  key=$(decision_key "$line")
  [ -n "$key" ] || return 0
  score=$(decision_row_score "$line")
  for idx in "${!seen_keys[@]}"; do
    if [[ "${seen_keys[$idx]}" == "$key" ]]; then
      found=$idx
      break
    fi
  done
  if [ "$found" -lt 0 ]; then
    seen_keys+=("$key")
    rows+=("$line")
    scores+=("$score")
  elif [ "$score" -gt "${scores[$found]}" ]; then
    rows[$found]="$line"
    scores[$found]="$score"
  fi
}

format_decisions_table() {
  local decisions="$1" line
  local -a seen_keys=() rows=() scores=()
  echo "| Decision | Date | Rationale |"
  echo "|----------|------|-----------|"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    line=$(normalize_decision_row "$line") || continue
    record_decision_row "$line"
  done <<< "$decisions"
  if [ "${#rows[@]}" -eq 0 ]; then
    echo "| _(No decisions yet)_ | | |"
  else
    printf '%s\n' "${rows[@]}"
  fi
}

EXISTING_TODOS=""
EXISTING_DECISIONS=""
EXISTING_BLOCKERS=""
EXISTING_CODEBASE=""
if [[ -f "$OUTPUT_PATH" ]]; then
  EXISTING_TODOS=$(extract_todos_section "$OUTPUT_PATH")
  EXISTING_DECISIONS=$(awk '
    { low = tolower($0) }
    low ~ /^##[[:space:]]+(key )?decisions[[:space:]]*$/ { found=1; next }
    found && /^##[[:space:]]/ { found=0 }
    found && low ~ /^###[[:space:]]+pending[[:space:]]+todos[[:space:]]*$/ { found=0; skip_skills=0; next }
    found && low ~ /^###[[:space:]]+skills[[:space:]]*$/ { skip_skills=1; next }
    skip_skills && /^###?#? / { skip_skills=0 }
    found && !skip_skills { print }
  ' "$OUTPUT_PATH")
  EXISTING_BLOCKERS=$(extract_section "$OUTPUT_PATH" "Blockers")
  EXISTING_CODEBASE=$(extract_section "$OUTPUT_PATH" "Codebase Profile")
  if [[ -n "$EXISTING_CODEBASE" ]] && ! printf '%s\n' "$EXISTING_CODEBASE" | grep -Eqv '^[[:space:]]*(None\.?)?[[:space:]]*$'; then
    EXISTING_CODEBASE=""
  fi
fi

{
  echo "# State"
  echo ""
  echo "**Project:** ${PROJECT_NAME}"
  echo "**Milestone:** ${MILESTONE_NAME}"
  echo ""
  echo "## Current Phase"
  echo "Phase: 1 of ${PHASE_COUNT}"
  echo "Plans: 0/0"
  echo "Progress: 0%"
  echo "Status: ready"
  echo ""
  echo "## Phase Status"
  for i in $(seq 1 "$PHASE_COUNT"); do
    if [[ "$i" -eq 1 ]]; then
      echo "- **Phase ${i}:** Pending planning"
    else
      echo "- **Phase ${i}:** Pending"
    fi
  done
  echo ""
  echo "## Key Decisions"
  format_decisions_table "$EXISTING_DECISIONS"
  echo ""
  echo "## Todos"
  format_todos_section "$EXISTING_TODOS"
  echo ""
  echo "## Blockers"
  if [[ -n "$EXISTING_BLOCKERS" ]]; then
    echo "$EXISTING_BLOCKERS"
  else
    echo "None"
  fi
  if [[ -n "$EXISTING_CODEBASE" ]]; then
    echo ""
    echo "## Codebase Profile"
    echo "$EXISTING_CODEBASE"
  fi
  echo ""
  echo "## Activity Log"
  echo "- ${STARTED}: Created ${MILESTONE_NAME} milestone (${PHASE_COUNT} phases)"
} > "$OUTPUT_PATH"
DETAILS_PATH="$(dirname "$OUTPUT_PATH")/todo-details.json"
if [ ! -f "$DETAILS_PATH" ]; then
  printf '{"schema_version":1,"items":{}}\n' > "$DETAILS_PATH"
fi
exit 0
