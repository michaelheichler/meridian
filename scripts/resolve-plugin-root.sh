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

required_script="hook-wrapper.sh"
nonfatal=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --require-script)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "Usage: resolve-plugin-root.sh [--require-script <name>] [--nonfatal]" >&2
        exit 2
      fi
      required_script="$2"
      shift 2
      ;;
    --nonfatal)
      nonfatal=true
      shift
      ;;
    *)
      echo "Usage: resolve-plugin-root.sh [--require-script <name>] [--nonfatal]" >&2
      exit 2
      ;;
  esac
done

case "$required_script" in
  */* | . | ..)
    echo "resolve-plugin-root.sh: --require-script expects a script name" >&2
    exit 2
    ;;
esac

valid_root() {
  local candidate="${1:-}"
  [ -n "$candidate" ] &&
    [ -d "$candidate" ] &&
    [ -f "$candidate/scripts/$required_script" ]
}

SESSION_KEY="${CLAUDE_SESSION_ID:-root-$(printf "%s\n%s\n" "${CLAUDE_PLUGIN_ROOT:-}" "$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)" | shasum -a 256 | cut -c1-64)}"
if [ "$SESSION_KEY" = root- ]; then
  [ "$nonfatal" = true ] && exit 0
  echo "MERIDIAN: plugin root hash unavailable" >&2
  exit 1
fi
session_link="/tmp/.meridian-plugin-root-link-${SESSION_KEY}"

fail_resolution() {
  if [ "$nonfatal" = true ]; then
    exit 0
  fi
  echo "MERIDIAN: plugin root unavailable. Restart this session to recreate $session_link." >&2
  exit 1
}

fail_link() {
  if [ "$nonfatal" = true ]; then
    exit 0
  fi
  echo "MERIDIAN: plugin root link unavailable. Restart this session to recreate $session_link." >&2
  exit 1
}

resolved_root=""

if valid_root "${CLAUDE_PLUGIN_ROOT:-}"; then
  resolved_root="$CLAUDE_PLUGIN_ROOT"
fi

if [ -z "$resolved_root" ] && valid_root "$session_link"; then
  resolved_root="$session_link"
fi

[ -n "$resolved_root" ] || fail_resolution
canonical_root=$(CDPATH='' cd -- "$resolved_root" 2>/dev/null && pwd -P) || fail_resolution

if ! bash "$canonical_root/scripts/ensure-plugin-root-link.sh" \
  "$session_link" "$canonical_root" >/dev/null 2>&1; then
  fail_link
fi

printf '%s\n' "$canonical_root"
