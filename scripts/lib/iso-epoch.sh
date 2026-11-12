#!/usr/bin/env bash

printf -v MERIDIAN_MIGRATION_SOURCE '%s' "${BASH_SOURCE[0]}"
case "$MERIDIAN_MIGRATION_SOURCE" in
  *"/"*) printf -v MERIDIAN_MIGRATION_SOURCE '%s' "${MERIDIAN_MIGRATION_SOURCE%"/"*}" ;;
  *) printf -v MERIDIAN_MIGRATION_SOURCE '%s' . ;;
esac
if [ -f "$MERIDIAN_MIGRATION_SOURCE/rename-migration.sh" ]; then
  . "$MERIDIAN_MIGRATION_SOURCE/rename-migration.sh"
  meridian_migrate_environment
fi
unset MERIDIAN_MIGRATION_SOURCE

iso_utc_to_epoch() {
  local value="$1" normalized epoch
  if [[ ! "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z?$ ]]; then
    return 1
  fi
  normalized="${value%%.*}"
  normalized="${normalized%Z}"
  epoch=$(date -j -u -f '%Y-%m-%dT%H:%M:%S' "$normalized" '+%s' 2>/dev/null || true)
  [[ -n "$epoch" ]] || epoch=$(date -u -d "${normalized}Z" '+%s' 2>/dev/null || true)
  [[ "$epoch" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$epoch"
}
