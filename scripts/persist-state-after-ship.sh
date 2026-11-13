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

if [[ $# -lt 3 ]]; then
  echo "Usage: persist-state-after-ship.sh ARCHIVED_STATE_PATH OUTPUT_PATH PROJECT_NAME" >&2
  exit 1
fi
ARCHIVED_PATH="$1"
OUTPUT_PATH="$2"
PROJECT_NAME="$3"
if [[ ! -f "$ARCHIVED_PATH" ]]; then
  echo "ERROR: Archived STATE.md not found: $ARCHIVED_PATH" >&2
  exit 1
fi
mkdir -p "$(dirname "$OUTPUT_PATH")"

extract_section() {
  local file="$1" heading="$2"
  awk -v h="$heading" '
    BEGIN { pat = tolower(h) }
    { low = tolower($0) }
    low ~ ("^##[[:space:]]+" pat "[[:space:]]*$") {
      found=1
      if (!hdr) { print $0; hdr=1 }
      next
    }
    found && /^##[[:space:]]+/ { found=0 }
    found { print }
  ' "$file"
}

extract_todos() {
  awk '
    { low = tolower($0) }
    low ~ /^##[[:space:]]+todos[[:space:]]*$/ {
      found=1; mode="h2"
      if (!hdr) { print "## Todos"; hdr=1 }
      next
    }
    low ~ /^###[[:space:]]+pending[[:space:]]+todos[[:space:]]*$/ {
      found=1; mode="h3"
      if (!hdr) { print "## Todos"; hdr=1 }
      next
    }
    found && mode == "h2" && /^##[[:space:]]+/ { found=0; mode="" }
    found && mode == "h3" && (/^## / || /^### /) { found=0; mode="" }
    found { print }
  ' "$1"
}

extract_decisions() {
  awk '
    { low = tolower($0) }
    low ~ /^##[[:space:]]+(key )?decisions[[:space:]]*$/ {
      found=1
      if (!hdr) { print "## Key Decisions"; hdr=1 }
      next
    }
    found && /^##[[:space:]]/ { found=0 }
    found && low ~ /^###[[:space:]]+pending[[:space:]]+todos[[:space:]]*$/ { found=0; skip_skills=0; next }
    found && low ~ /^###[[:space:]]+skills[[:space:]]*$/ { skip_skills=1; next }
    skip_skills && /^###?#? / { skip_skills=0 }
    found && !skip_skills { print }
  ' "$1"
}

section_has_body() {
  [[ -n "$1" ]] && echo "$1" | tail -n +2 | grep -qv '^[[:space:]]*$'
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

decision_is_content() {
  local low
  low=$(printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]')
  [[ "$low" =~ ^[-*][[:space:]]+none\.?[[:space:]]*$ ]] && return 1
  [[ "$low" =~ ^none\.?[[:space:]]*$ ]] && return 1
  [[ "$low" =~ ^[-*][[:space:]]+_\(no[[:space:]]+decisions[[:space:]]+yet\)_[[:space:]]*$ ]] && return 1
  [[ "$low" =~ ^\|[[:space:]]*_\(no[[:space:]]+decisions[[:space:]]+yet\)_([[:space:]]*\|.*)?$ ]] && return 1
  [[ "$low" =~ ^\|[[:space:]]*decision([[:space:]]*\|.*)?$ ]] && return 1
  [[ "$low" =~ ^\|([[:space:]:-]+\|)+[[:space:]:-]*$ ]] && return 1
  [[ "$1" =~ ^[[:space:]]*$ ]] && return 1
  [[ "$1" =~ ^#+[[:space:]] ]] && return 1
  return 0
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
  if [[ ! "$line" =~ ^\| ]]; then
    line=$(printf '%s\n' "$line" | sed -E 's/^[-*][[:space:]]+//' | sed 's/|/\\|/g')
    line="| $line | | |"
  fi
  if [ "$found" -lt 0 ]; then
    seen_keys+=("$key")
    rows_out+=("$line")
    scores+=("$score")
  elif [ "$score" -gt "${scores[$found]}" ]; then
    rows_out[$found]="$line"
    scores[$found]="$score"
  fi
}

normalize_decisions_section() {
  local section="$1" line
  local -a seen_keys=() rows_out=() scores=()
  echo "## Key Decisions"
  echo "| Decision | Date | Rationale |"
  echo "|----------|------|-----------|"
  while IFS= read -r line; do
    decision_is_content "$line" || continue
    record_decision_row "$line"
  done <<< "$(printf '%s\n' "$section" | tail -n +2)"
  if [ "${#rows_out[@]}" -eq 0 ]; then
    echo "| _(No decisions yet)_ | | |"
  else
    printf '%s\n' "${rows_out[@]}"
  fi
}

normalize_todos_section() {
  local section="$1" rows
  rows=$(printf '%s\n' "$section" | awk '
    NR == 1 { next }
    {
      low = tolower($0)
      if (low ~ /^[-*][[:space:]]+none\.?[[:space:]]*$/) next
      if (low ~ /^none\.?[[:space:]]*$/) next
      if ($0 ~ /^[[:space:]]*$/) next
      print
    }
  ')
  echo "## Todos"
  if [[ -n "$rows" ]]; then
    printf '%s\n' "$rows"
  else
    echo "None."
  fi
}

print_root_blockers() {
  local blockers
  blockers=$(extract_section "$ARCHIVED_PATH" "Blockers")
  if section_has_body "$blockers"; then
    echo "$blockers"
    echo ""
  else
    echo "## Blockers"
    echo "None"
    echo ""
  fi
}

generate_root_state() {
  echo "# State"
  echo ""
  echo "**Project:** ${PROJECT_NAME}"
  echo ""
  local decisions todos codebase
  decisions=$(extract_decisions "$ARCHIVED_PATH")
  normalize_decisions_section "$decisions"
  echo ""
  todos=$(extract_todos "$ARCHIVED_PATH")
  normalize_todos_section "$todos"
  echo ""
  print_root_blockers
  codebase=$(extract_section "$ARCHIVED_PATH" "Codebase Profile")
  if section_has_body "$codebase" && printf '%s\n' "$codebase" | tail -n +2 | grep -Eqv '^[[:space:]]*(None\.?)?[[:space:]]*$'; then
    echo "$codebase"
    echo ""
  fi
}

generate_root_state > "$OUTPUT_PATH"
DETAIL_SCRIPT=""
SESSION_KEY="${CLAUDE_SESSION_ID:-root-$(printf %s "$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)" | shasum -a 256 | cut -c1-64)}"
LINK="/tmp/.meridian-plugin-root-link-${SESSION_KEY}"
TODO_DETAILS_REGISTRY="$(dirname "$OUTPUT_PATH")/todo-details.json"
if [ -f "${LINK}/scripts/todo-details.sh" ]; then
  DETAIL_SCRIPT="${LINK}/scripts/todo-details.sh"
fi
if [ -n "$DETAIL_SCRIPT" ] && [ -f "$DETAIL_SCRIPT" ]; then
  bash "$DETAIL_SCRIPT" gc "$OUTPUT_PATH" "$TODO_DETAILS_REGISTRY" >/dev/null 2>&1 || true
fi
exit 0
