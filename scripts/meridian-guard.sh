#!/bin/bash
set -eu
unset CDPATH

SOURCE="$0"
while [ -L "$SOURCE" ]; do
  SOURCE_DIR=$(CDPATH='' cd -- "$(dirname "$SOURCE")" && pwd -P)
  SOURCE=$(readlink "$SOURCE")
  if [ "${SOURCE#/}" = "$SOURCE" ]; then
    SOURCE="$SOURCE_DIR/$SOURCE"
  fi
done
ROOT=$(CDPATH='' cd -- "$(dirname "$SOURCE")/.." && pwd -P)
exec python3 "$ROOT/hooks/guard_unlock.py" "$@"
