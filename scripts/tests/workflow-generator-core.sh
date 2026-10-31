#!/usr/bin/env bash
set -uo pipefail

TESTS_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
SCRIPTS_DIR=$(CDPATH='' cd -- "$TESTS_DIR/.." && pwd)
PLUGIN_ROOT=$(CDPATH='' cd -- "$SCRIPTS_DIR/.." && pwd)
WORK_ROOT=$(mktemp -d)
PLUGIN_FIXTURE="$WORK_ROOT/plugin"

cleanup() {
  rm -rf "$WORK_ROOT"
}
trap cleanup EXIT

mkdir -p "$PLUGIN_FIXTURE"
cp -R "$PLUGIN_ROOT/scripts" "$PLUGIN_ROOT/templates" "$PLUGIN_ROOT/config" "$PLUGIN_FIXTURE/"

AGENT_GENERATOR="$PLUGIN_FIXTURE/scripts/agent-generator.sh"
WORKFLOW_GENERATOR="$PLUGIN_FIXTURE/scripts/workflow-generator.sh"
TASK_CONTRACT="$PLUGIN_FIXTURE/scripts/task-contract.sh"

GENERATOR_BASH=""
for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash /opt/local/bin/bash \
  "$(command -v bash 2>/dev/null || true)"; do
  if [ -x "$candidate" ] && "$candidate" -uc 'declare -A test=()' >/dev/null 2>&1; then
    GENERATOR_BASH="$candidate"
    break
  fi
done
[ -n "$GENERATOR_BASH" ] || { printf 'Bash 4+ is required to run workflow-generator.sh\n' >&2; exit 1; }

PASS=0
FAIL=0

. "$TESTS_DIR/lib/workflow-core-helpers.sh"
. "$TESTS_DIR/lib/workflow-pair-scenario.sh"
. "$TESTS_DIR/lib/workflow-trio-effort-scenarios.sh"
. "$TESTS_DIR/lib/workflow-manifest-scenario.sh"
. "$TESTS_DIR/lib/workflow-broken-plugin-scenarios.sh"
. "$TESTS_DIR/lib/workflow-determinism-config-scenarios.sh"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
