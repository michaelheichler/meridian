#!/usr/bin/env bash

. "$(CDPATH="" cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/rename-migration.sh"
meridian_migrate_environment

if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  export CLAUDE_DIR="${CLAUDE_CONFIG_DIR}"
elif [ -d "$HOME/.config/claude-code" ]; then
  export CLAUDE_DIR="$HOME/.config/claude-code"
else
  export CLAUDE_DIR="$HOME/.claude"
fi
