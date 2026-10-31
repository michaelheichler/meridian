#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

usage() {
  cat >&2 <<'EOF'
Usage:
  track-uat-deviations.sh signature <source-plan> <source-path> <text>
  track-uat-deviations.sh accepted-signatures <phase-dir>
  track-uat-deviations.sh record-from-uat <phase-dir> <uat-file>
  track-uat-deviations.sh todo-from-uat <phase-dir> <uat-file> <checkpoint-id>
EOF
}

trim_value() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

lower_value() {
  local value="${1:-}"
  local upper="ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  local lower="abcdefghijklmnopqrstuvwxyz"
  local idx letter pos out=""
  for ((idx = 0; idx < ${#value}; idx++)); do
    letter="${value:$idx:1}"
    pos="${upper%%"$letter"*}"
    if [ "${#pos}" -lt "${#upper}" ]; then
      letter="${lower:${#pos}:1}"
    fi
    out="$out$letter"
  done
  printf '%s' "$out"
}

strip_uat_metadata_value() {
  local line="${1:-}"
  local prefix="${2:-}"
  line="${line#"$prefix"}"
  trim_value "$line"
}

sha256_text() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 | awk '{print $NF}'
  else
    echo "track-uat-deviations: no sha256 tool available" >&2
    exit 1
  fi
}

. "$SCRIPT_DIR/lib/uat-deviation-fields.sh"
. "$SCRIPT_DIR/lib/uat-deviation-registry.sh"
. "$SCRIPT_DIR/lib/uat-deviation-insert.sh"
. "$SCRIPT_DIR/lib/uat-deviation-todo.sh"

cmd="${1:-}"
case "$cmd" in
  signature)
    [ $# -eq 4 ] || { usage; exit 1; }
    deviation_signature "$2" "$3" "$4"
    ;;
  accepted-signatures)
    [ $# -eq 2 ] || { usage; exit 1; }
    accepted_signatures "$2"
    ;;
  record-from-uat)
    [ $# -eq 3 ] || { usage; exit 1; }
    record_from_uat "$2" "$3"
    ;;
  todo-from-uat)
    [ $# -eq 4 ] || { usage; exit 1; }
    todo_from_uat "$2" "$3" "$4"
    ;;
  *)
    usage
    exit 1
    ;;
esac
