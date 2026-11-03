#!/bin/bash

. "$(CDPATH="" cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/rename-migration.sh"
meridian_migrate_environment
set -u
. "$(CDPATH='' cd -- "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd)/lib/debug-logging.sh" 2>/dev/null || true
debug_logging_gate validate-commit.sh PostToolUse 2>/dev/null || true

if ! command -v jq &>/dev/null; then
  exit 0
fi

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

if ! echo "$COMMAND" | grep -q "git commit"; then
  exit 0
fi

VALID_TYPES="feat|fix|test|refactor|perf|docs|style|chore"

DQUOTE='"'
SQUOTE="'"
BSLASH=$'\\'
MESSAGE_VALUE_RE="(${DQUOTE}([^${DQUOTE}]*)${DQUOTE}|${SQUOTE}([^${SQUOTE}]*)${SQUOTE}|([^[:space:]]+))"

message_flag_subject() {
  local short_re="^-[a-ln-zA-Z]*m[[:space:]]*$MESSAGE_VALUE_RE"
  local long_re="^--message(=|[[:space:]]+)$MESSAGE_VALUE_RE"
  if [[ "$1" =~ $short_re ]]; then
    printf '%s%s%s' "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
  elif [[ "$1" =~ $long_re ]]; then
    printf '%s%s%s' "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}"
  fi
}

is_escape_in_double_quotes() {
  [ "$1" = "$BSLASH" ] && [ "$2" = "$DQUOTE" ]
}

# Quoted text is skipped because a "-m" inside it is not a flag.
first_message_subject() {
  local command_text="$1" idx=0 char quote="" at_token_start=1 subject=""
  while [ "$idx" -lt "${#command_text}" ]; do
    char="${command_text:idx:1}"
    if [ -n "$quote" ]; then
      ! is_escape_in_double_quotes "$char" "$quote" || idx=$((idx + 1))
      [ "$char" = "$quote" ] && quote=""
    elif [ "$at_token_start" -eq 1 ] && subject=$(message_flag_subject "${command_text:idx}") && [ -n "$subject" ]; then
      break
    else
      at_token_start=0
      case "$char" in
        "$DQUOTE"|"$SQUOTE") quote="$char" ;;
        [[:space:]]) at_token_start=1 ;;
      esac
    fi
    idx=$((idx + 1))
  done
  printf '%s\n' "${subject%%$'\n'*}"
}

message_file_subject() {
  local re='(-F|--file=?)[[:space:]]*([^[:space:]]+)' file
  [[ "$1" =~ $re ]] || return 0
  file="${BASH_REMATCH[2]}"
  file="${file#[\"\']}"
  file="${file%[\"\']}"
  [ "$file" = "-" ] && return 0
  case "$file" in /*) ;; *) [ -n "$2" ] && file="$2/$file" ;; esac
  [ -f "$file" ] && head -n 1 "$file"
  return 0
}

MSG=""
if echo "$COMMAND" | grep -q 'cat <<'; then
  MSG=$(printf '%s\n' "$COMMAND" | sed -n '/cat <</,$ p' | sed '1d' | grep -m1 -E "^($VALID_TYPES)\(.+\): .+" | sed 's/^[[:space:]]*//')
  if [ -z "$MSG" ]; then
    MSG=$(printf '%s\n' "$COMMAND" | sed -n '/cat <</,$ p' | sed '1d' | sed '/^[[:space:]]*$/d' | head -1 | sed 's/^[[:space:]]*//')
  fi
  if [ -z "$MSG" ]; then
    exit 0  # An unparseable heredoc must not block the commit, so fail open
  fi
fi
if [ -z "$MSG" ]; then
  MSG=$(message_file_subject "$COMMAND" "$(echo "$INPUT" | jq -r '.cwd // ""')")
fi
if [ -z "$MSG" ]; then
  MSG=$(first_message_subject "$COMMAND")
fi

if [ -z "$MSG" ]; then
  exit 0
fi

if ! echo "$MSG" | grep -qE "^($VALID_TYPES)\(.+\): .+"; then
  debug_logging_note warn commit_format 2>/dev/null || true
  jq -n --arg msg "$MSG" '{
    "hookSpecificOutput": {
      "hookEventName": "PostToolUse",
      "additionalContext": ("Commit message does not match format {type}({scope}): {desc}. Got: " + $msg)
    }
  }'
fi

exit 0
