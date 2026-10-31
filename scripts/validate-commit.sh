#!/bin/bash
set -u

if ! command -v jq &>/dev/null; then
  exit 0
fi

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

if ! echo "$COMMAND" | grep -q "git commit"; then
  exit 0
fi

VALID_TYPES="feat|fix|test|refactor|perf|docs|style|chore"

first_message_subject() {
  local re='-m[[:space:]]*("([^"]*)"|'"'"'([^'"'"']*)'"'"'|([^[:space:]]+))' subject=""
  if [[ "$1" =~ $re ]]; then
    subject="${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[4]}"
  fi
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
  jq -n --arg msg "$MSG" '{
    "hookSpecificOutput": {
      "hookEventName": "PostToolUse",
      "additionalContext": ("Commit message does not match format {type}({scope}): {desc}. Got: " + $msg)
    }
  }'
fi

exit 0
