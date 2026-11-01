#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
PLUGIN_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
. "$SCRIPT_DIR/lib/agent-keyed-vars.sh"
. "$SCRIPT_DIR/lib/agent-manifest.sh"
. "$SCRIPT_DIR/lib/agent-fields.sh"
. "$SCRIPT_DIR/lib/lbwc-control-root.sh"
. "$SCRIPT_DIR/lib/agent-generator-options.sh"
. "$SCRIPT_DIR/lib/agent-generator-contract.sh"
. "$SCRIPT_DIR/lib/agent-generator-roles.sh"
. "$SCRIPT_DIR/lib/agent-generator-render.sh"
. "$SCRIPT_DIR/lib/agent-generator-register.sh"
. "$SCRIPT_DIR/lib/agent-generator-generate.sh"

fail() {
  printf 'agent-generator: %s\n' "$1" >&2
  exit 1
}

usage() {
  printf 'Usage: agent-generator.sh <role> --job <text> --contract <path> --task-id <id> [--exclusive] [--write-allowance <repo-path>] [overrides]\n' >&2
  printf '       agent-generator.sh --native-team <role> --job <text> --contract <path> --task-id <id> [--write-capability <kind:path>]\n' >&2
  printf '       agent-generator.sh --pair <role> --job <text> --contract <path> --task-id <id> [--exclusive] [--pair-role <role>] [--write-allowance <repo-path>] [overrides]\n' >&2
  printf '       agent-generator.sh --trio <role> --job <text> --contract <path> --task-id <id> [--exclusive] [--write-allowance <repo-path>] [--role-write-allowance <role>:<repo-path>] [overrides]\n' >&2
  exit 1
}

ROLE_DEFAULTS_PATH="$PLUGIN_ROOT/templates/agent-roles/defaults.json"
[ -f "$ROLE_DEFAULTS_PATH" ] || fail "role defaults not found: $ROLE_DEFAULTS_PATH"

PAIR_MODE=""
TRIO_MODE=""
NATIVE_TEAM_MODE=""
if [ "${1:-}" = "--native-team" ]; then
  NATIVE_TEAM_MODE=1
  shift
fi
if [ "${1:-}" = "--pair" ]; then
  PAIR_MODE=1
  shift
elif [ "${1:-}" = "--trio" ]; then
  TRIO_MODE=1
  shift
fi
ROLE="${1:-}"
[ -n "$ROLE" ] || usage
ROLE="${ROLE#lbwc-}"
shift
is_valid_role "$ROLE" || fail "invalid role '$ROLE'"

parse_options "$@"
check_required_options
check_native_team_overrides
resolve_contract_context
validate_contract
check_write_allowance_paths

load_words "$WORDLIST_A"
WORDS_A=("${LOADED_WORDS[@]}")
load_words "$WORDLIST_B"
WORDS_B=("${LOADED_WORDS[@]}")

resolve_team_settings
validate_execution_backend_override
validate_team_contract_roles
mkdir -p "$AGENTS_DIR"
check_write_scope

if ! agent_manifest_with_lock "$PLANNING_DIR" generate_agent_locked; then
  fail "${GENERATOR_ERROR:-could not generate agent}"
fi
print_all_spawn_ready
