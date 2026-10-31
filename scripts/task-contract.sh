#!/usr/bin/env bash
set -euo pipefail

TASK_CONTRACT_SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)"
export TASK_CONTRACT_SCRIPT_DIR
exec python3 -B "$TASK_CONTRACT_SCRIPT_DIR/lib/task_contract/main.py" "$@"
