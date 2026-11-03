#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)"
PROJECT_ROOT=""
SOURCE=""
OUTPUT=""
ADAPTER=""
IMPORT_ID=""
STAGE=""
FAIL_AFTER="${MERIDIAN_IMPORT_FAIL_AFTER:-0}"
FAIL_VALIDATION="${MERIDIAN_IMPORT_FAIL_VALIDATION:-0}"
ARTIFACTS=()

die() {
  printf 'plan-import: %s\n' "$1" >&2
  exit 1
}

import_fail() {
  die "$1"
}

usage() {
  printf '%s\n' \
    'Usage: plan-import.sh <normalize|digest|stage|validate-stage|reimport|promote> [options]' \
    '  normalize --adapter gsd|markdown --source PATH --output PATH' \
    '  digest --source PATH --output PATH' \
    '  stage --adapter gsd|markdown --source PATH --project-root PATH --import-id ID' \
    '  validate-stage --project-root PATH --stage PATH' \
    '  reimport --source PATH --project-root PATH' \
    '  promote --project-root PATH --stage PATH --artifact PATH [--artifact PATH ...]'
}

. "$SCRIPT_DIR/lib/plan-import-source.sh"
. "$SCRIPT_DIR/lib/plan-import-render.sh"
. "$SCRIPT_DIR/lib/plan-import-stage.sh"
. "$SCRIPT_DIR/lib/plan-import-promote.sh"

COMMAND="${1:-}"
[ -n "$COMMAND" ] || { usage >&2; exit 2; }
shift

while [ "$#" -gt 0 ]; do
  case "$1" in
    --adapter) [ "$#" -ge 2 ] || die '--adapter requires a value'; ADAPTER="$2"; shift 2 ;;
    --source) [ "$#" -ge 2 ] || die '--source requires a path'; SOURCE="$2"; shift 2 ;;
    --output) [ "$#" -ge 2 ] || die '--output requires a path'; OUTPUT="$2"; shift 2 ;;
    --project-root) [ "$#" -ge 2 ] || die '--project-root requires a path'; PROJECT_ROOT="$2"; shift 2 ;;
    --import-id) [ "$#" -ge 2 ] || die '--import-id requires a value'; IMPORT_ID="$2"; shift 2 ;;
    --stage) [ "$#" -ge 2 ] || die '--stage requires a path'; STAGE="$2"; shift 2 ;;
    --artifact) [ "$#" -ge 2 ] || die '--artifact requires a path'; ARTIFACTS+=("$2"); shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

case "$COMMAND" in
  normalize)
    [ -n "$ADAPTER" ] && [ -n "$SOURCE" ] && [ -n "$OUTPUT" ] || die 'normalize requires --adapter, --source, and --output'
    normalize_source "$ADAPTER" "$SOURCE" "$OUTPUT"
    ;;
  digest)
    [ -n "$SOURCE" ] && [ -n "$OUTPUT" ] || die 'digest requires --source and --output'
    SOURCE=$(canonical_source "$SOURCE")
    import_source_metadata "$SOURCE"
    mkdir -p "$(dirname "$OUTPUT")"
    jq -n --arg digest "$SOURCE_DIGEST" --argjson file_count "$SOURCE_FILE_COUNT" --argjson total_bytes "$SOURCE_TOTAL_BYTES" \
      '{schema_version:1,digest:$digest,file_count:$file_count,total_bytes:$total_bytes}' > "$OUTPUT"
    ;;
  stage)
    [ -n "$ADAPTER" ] && [ -n "$SOURCE" ] && [ -n "$PROJECT_ROOT" ] && [ -n "$IMPORT_ID" ] || die 'stage requires --adapter, --source, --project-root, and --import-id'
    stage_import "$ADAPTER" "$SOURCE" "$PROJECT_ROOT" "$IMPORT_ID"
    ;;
  validate-stage)
    [ -n "$PROJECT_ROOT" ] && [ -n "$STAGE" ] || die 'validate-stage requires --project-root and --stage'
    validate_stage "$PROJECT_ROOT" "$STAGE"
    ;;
  reimport)
    [ -n "$SOURCE" ] && [ -n "$PROJECT_ROOT" ] || die 'reimport requires --source and --project-root'
    reimport_status "$SOURCE" "$PROJECT_ROOT"
    ;;
  promote)
    [ -n "$PROJECT_ROOT" ] && [ -n "$STAGE" ] || die 'promote requires --project-root and --stage'
    promote_import "$PROJECT_ROOT" "$STAGE"
    ;;
  *) usage >&2; exit 2;;
esac
