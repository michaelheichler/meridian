#!/usr/bin/env bash
set -euo pipefail


SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/../lib/claude-md-lbwc-sections.sh"

if [[ ! -f "$LIB" ]]; then
  echo "Error: helper library not found at $LIB" >&2
  exit 1
fi

source "$SCRIPT_DIR/../lib/claude-md-lbwc-sections.sh"
source "$SCRIPT_DIR/lib/bootstrap-claude-migration.sh"


LBWC_SECTIONS=("${LBWC_CANONICAL_HEADERS[@]}")

LBWC_DEPRECATED_SECTIONS=(
  "## Key Decisions"  # stale because .lbwc-planning/PROJECT.md and STATE.md track decisions
  "## Installed Skills"  # stale because the runtime activation pipeline surfaces skills
)

GSD_STRONG_SECTIONS=(
  "## Codebase Intelligence"
  "## Project Reference"
  "## GSD Rules"
  "## GSD Context"
)

GSD_SOFT_SECTIONS=(
  "## What This Is"
  "## Core Value"
  "## Context"
  "## Constraints"
)

if [[ $# -lt 3 ]]; then
  echo "Usage: bootstrap-claude.sh OUTPUT_PATH PROJECT_NAME CORE_VALUE [EXISTING_PATH]" >&2
  exit 1
fi

OUTPUT_PATH="$1"
PROJECT_NAME="$2"
CORE_VALUE="$3"
EXISTING_PATH="${4:-}"

if [[ -z "$PROJECT_NAME" || -z "$CORE_VALUE" ]]; then
  echo "Error: PROJECT_NAME and CORE_VALUE must not be empty" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"

INCLUDE_ACTIVE_CONTEXT=true
INCLUDE_LBWC_RULES=true
INCLUDE_CODE_INTELLIGENCE=true
INCLUDE_PLUGIN_ISOLATION=true

generate_lbwc_sections() {
  local emitted=false

  if [[ "$INCLUDE_ACTIVE_CONTEXT" == true ]]; then
    lbwc_generate_active_context_section
    emitted=true
  fi

  if [[ "$INCLUDE_LBWC_RULES" == true ]]; then
    if [[ "$emitted" == true ]]; then echo ""; fi
    lbwc_generate_lbwc_rules_section
    emitted=true
  fi

  if [[ "$INCLUDE_CODE_INTELLIGENCE" == true ]]; then
    if [[ "$emitted" == true ]]; then echo ""; fi
    lbwc_generate_code_intelligence_section
    emitted=true
  fi

  if [[ "$INCLUDE_PLUGIN_ISOLATION" == true ]]; then
    if [[ "$emitted" == true ]]; then echo ""; fi
    lbwc_generate_plugin_isolation_section
  fi
}

is_lbwc_section() {
  local line="$1"
  for header in "${LBWC_SECTIONS[@]}"; do
    if [[ "$line" == "$header" ]]; then
      return 0
    fi
  done
  return 1
}

is_gsd_section() {
  local line="$1"
  for header in "${GSD_STRONG_SECTIONS[@]}"; do
    if [[ "$line" == "$header" ]]; then
      return 0
    fi
  done

  if [[ "${ALLOW_SOFT_GSD_STRIP:-false}" == "true" ]]; then
    for header in "${GSD_SOFT_SECTIONS[@]}"; do
      if [[ "$line" == "$header" ]]; then
        return 0
      fi
    done
  fi

  return 1
}

is_deprecated_lbwc_section() {
  local line="$1"
  for header in "${LBWC_DEPRECATED_SECTIONS[@]}"; do
    if [[ "$line" == "$header" ]]; then
      return 0
    fi
  done
  return 1
}

IN_FENCE=false
FENCE_CHAR=""
FENCE_LENGTH=0

update_fence_state() {
  local text="${1#"${1%%[![:space:]]*}"}"
  local mark="${text:0:1}"
  local rest="$text"
  local run=0

  [[ "$mark" == '`' || "$mark" == '~' ]] || return 0
  while [[ "${rest:0:1}" == "$mark" ]]; do
    rest="${rest:1}"
    run=$((run + 1))
  done
  [[ "$run" -ge 3 ]] || return 0

  if [[ "$IN_FENCE" == false ]]; then
    IN_FENCE=true
    FENCE_CHAR="$mark"
    FENCE_LENGTH="$run"
  elif [[ "$mark" == "$FENCE_CHAR" && "$run" -ge "$FENCE_LENGTH" && ! "$rest" =~ [^[:space:]] ]]; then
    IN_FENCE=false
  fi
}

is_managed_section() {
  is_lbwc_section "$1" || is_deprecated_lbwc_section "$1" || is_gsd_section "$1"
}

if [[ -n "$EXISTING_PATH" && -f "$EXISTING_PATH" ]]; then
  ALLOW_SOFT_GSD_STRIP=false
  if grep -Eq '^## (Codebase Intelligence|Project Reference|GSD Rules|GSD Context)$' "$EXISTING_PATH"; then
    ALLOW_SOFT_GSD_STRIP=true
  fi

  NON_LBWC_CONTENT=""
  IN_MANAGED_SECTION=false
  export FOUND_NON_LBWC=false
  IN_DEPRECATED_SECTION=false
  DEPRECATED_SECTION_BUFFER=""
  DEPRECATED_HAS_USER_CONTENT=false
  export DEPRECATED_HAS_USER_CONTENT

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%"${line##*[![:space:]]}"}"

    update_fence_state "$line"

    if [[ "$IN_FENCE" == false ]] && is_managed_section "$line"; then
      flush_deprecated_buffer
      if is_deprecated_lbwc_section "$line"; then
        IN_DEPRECATED_SECTION=true
        DEPRECATED_SECTION_BUFFER="${line}"$'\n'
        DEPRECATED_HAS_USER_CONTENT=false
      fi
      IN_MANAGED_SECTION=true
      continue
    fi

    if [[ "$IN_FENCE" == false && "$line" =~ ^##\  ]] && ! is_managed_section "$line"; then
      flush_deprecated_buffer
      IN_MANAGED_SECTION=false
    fi

    if [[ "$IN_DEPRECATED_SECTION" == true ]]; then
      DEPRECATED_SECTION_BUFFER+="${line}"$'\n'
      if [[ -n "$line" && ! "$line" =~ ^\|[-[:space:]|]+\|$ && ! "$line" =~ ^\|\ *Decision ]]; then
        DEPRECATED_HAS_USER_CONTENT=true
      fi
      continue
    fi

    if [[ "$IN_MANAGED_SECTION" == false ]]; then
      NON_LBWC_CONTENT+="${line}"$'\n'
      FOUND_NON_LBWC=true
    fi
  done < "$EXISTING_PATH"

  flush_deprecated_buffer

  if lbwc_should_emit_managed_section "$EXISTING_PATH" "Active Context" "## Active Context"; then
    INCLUDE_ACTIVE_CONTEXT=true
  else
    INCLUDE_ACTIVE_CONTEXT=false
  fi

  if lbwc_should_emit_managed_section "$EXISTING_PATH" "LBWC Rules" "## LBWC Rules"; then
    INCLUDE_LBWC_RULES=true
  else
    INCLUDE_LBWC_RULES=false
  fi

  if lbwc_should_emit_code_intelligence_section "$EXISTING_PATH"; then
    INCLUDE_CODE_INTELLIGENCE=true
  else
    INCLUDE_CODE_INTELLIGENCE=false
  fi

  if lbwc_should_emit_managed_section "$EXISTING_PATH" "Plugin Isolation" "## Plugin Isolation"; then
    INCLUDE_PLUGIN_ISOLATION=true
  else
    INCLUDE_PLUGIN_ISOLATION=false
  fi

  {
    if [[ "$FOUND_NON_LBWC" == true ]]; then
      echo "$NON_LBWC_CONTENT" | sed '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
      if [[ "$INCLUDE_ACTIVE_CONTEXT" == true || "$INCLUDE_LBWC_RULES" == true || "$INCLUDE_CODE_INTELLIGENCE" == true || "$INCLUDE_PLUGIN_ISOLATION" == true ]]; then
        echo ""
      fi
    fi
    generate_lbwc_sections
  } > "$OUTPUT_PATH"
else
  {
    echo "# ${PROJECT_NAME}"
    echo ""
    echo "**Core value:** ${CORE_VALUE}"
    echo ""
    generate_lbwc_sections
  } > "$OUTPUT_PATH"
fi

exit 0
