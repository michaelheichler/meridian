#!/bin/bash
set -eu
CHECK_ROOT=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
exec python3 "$CHECK_ROOT/scripts/dev/check_config_keys.py" "$CHECK_ROOT"
