#!/usr/bin/env bash

. "$(CDPATH="" cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/../lib/rename-migration.sh"
meridian_migrate_environment
# Bats needs modern bash, so only repo scripts are shimmed down to 3.2.
set -euo pipefail

OLD_BASH=/bin/bash

usage() {
  printf '%s\n' 'Usage: scripts/dev/bats32.sh [bats arguments]' >&2
  printf '%s\n' 'Runs bats on the modern bash. A temporary bash shim sends scripts under scripts/ and hooks/ to /bin/bash 3.2.' >&2
  printf '%s\n' 'Example: scripts/dev/bats32.sh tests/bash32-compat.bats' >&2
}

for argument in "$@"; do
  case "$argument" in
    --help | -h)
      usage
      exit 0
      ;;
  esac
done

REPO_ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MODERN_BASH="$(command -v bash)"

old_major="$("$OLD_BASH" -c 'printf %s "${BASH_VERSINFO[0]}"' 2>/dev/null || true)"
if [ "$old_major" != 3 ]; then
  printf 'bats32: %s is not bash 3.x (found major version "%s"), so it cannot prove bash 3.2 compatibility\n' "$OLD_BASH" "$old_major" >&2
  exit 2
fi
command -v bats >/dev/null 2>&1 || {
  printf 'bats32: bats is not on PATH\n' >&2
  exit 2
}

shim_dir="$(mktemp -d "${TMPDIR:-/tmp}/bats32.XXXXXX")"
trap 'rm -rf -- "$shim_dir"' EXIT

cat >"$shim_dir/bash" <<SHIM
#!$MODERN_BASH
target=''
for argument in "\$@"; do
  case "\$argument" in
    -c) break ;;
    -*) continue ;;
  esac
  target="\$argument"
  break
done
case "\$target" in
  "$REPO_ROOT"/scripts/* | "$REPO_ROOT"/hooks/*) exec "$OLD_BASH" "\$@" ;;
esac
exec "$MODERN_BASH" "\$@"
SHIM
chmod +x "$shim_dir/bash"

PATH="$shim_dir:$PATH" bats "$@"
