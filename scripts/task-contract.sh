#!/usr/bin/env bash

. "$(CDPATH="" cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/rename-migration.sh"
meridian_migrate_environment
set -euo pipefail

TASK_CONTRACT_SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)"
export TASK_CONTRACT_SCRIPT_DIR
exec python3 -B "$TASK_CONTRACT_SCRIPT_DIR/lib/task_contract/main.py" "$@"
