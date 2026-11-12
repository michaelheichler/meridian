#!/usr/bin/env bash

printf -v MERIDIAN_MIGRATION_SOURCE '%s' "${BASH_SOURCE[0]}"
case "$MERIDIAN_MIGRATION_SOURCE" in
  *"/"*) printf -v MERIDIAN_MIGRATION_SOURCE '%s' "${MERIDIAN_MIGRATION_SOURCE%"/"*}" ;;
  *) printf -v MERIDIAN_MIGRATION_SOURCE '%s' . ;;
esac
if [ -f "$MERIDIAN_MIGRATION_SOURCE/lib/rename-migration.sh" ]; then
  . "$MERIDIAN_MIGRATION_SOURCE/lib/rename-migration.sh"
  meridian_migrate_environment
fi
unset MERIDIAN_MIGRATION_SOURCE

set -euo pipefail

extract_frontmatter_array_items() {
  local file_path="${1:-}"
  local key_name="${2:-}"
  [ -f "$file_path" ] || return 0
  [ -n "$key_name" ] || return 0
  awk -v key="$key_name" -f "${_CVC_SCRIPT_DIR}/extract-frontmatter-array-items.awk" "$file_path" 2>/dev/null
}

frontmatter_key_present() {
  local file_path="${1:-}"
  local key_name="${2:-}"
  [ -f "$file_path" ] || return 1
  [ -n "$key_name" ] || return 1
  awk -v key="$key_name" '
    BEGIN { in_fm = 0; found = 0 }
    NR == 1 && /^---[[:space:]]*$/ { in_fm = 1; next }
    in_fm && /^---[[:space:]]*$/ { exit(found ? 0 : 1) }
    in_fm && $0 ~ ("^" key ":[[:space:]]*") { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$file_path" >/dev/null 2>&1
}

_CVC_SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_CVC_SCRIPT_DIR/summary-utils.sh" ]; then
  . "$_CVC_SCRIPT_DIR/summary-utils.sh"
else
  is_summary_terminal() { [ -f "$1" ]; }
fi

sanitize_summary_deviation_context_field() {
  printf '%s' "${1:-}" | tr '\r\n|' '   ' | awk '{ gsub(/[[:space:]]+/, " "); sub(/^ /, ""); sub(/ $/, ""); print }'
}

. "$_CVC_SCRIPT_DIR/lib/compile-verify-context-remediation.sh"
. "$_CVC_SCRIPT_DIR/lib/compile-verify-context-plans.sh"
. "$_CVC_SCRIPT_DIR/lib/compile-verify-context-history.sh"

REMEDIATION_ONLY=false
REMEDIATION_KIND=""
while [ $# -gt 0 ]; do
  case "${1:-}" in
    --remediation-only) REMEDIATION_ONLY=true; shift ;;
    --remediation-kind)
      if [ $# -lt 2 ] || [ -z "${2:-}" ] || [[ "${2:-}" == --* ]]; then
        echo "error: --remediation-kind requires a value (qa or uat)" >&2
        exit 1
      fi
      REMEDIATION_KIND="$2"
      shift 2
      ;;
    --remediation-kind=*)
      REMEDIATION_KIND="${1#--remediation-kind=}"
      if [ -z "$REMEDIATION_KIND" ]; then
        echo "error: --remediation-kind requires a value (qa or uat)" >&2; exit 1
      fi
      shift
      ;;
    *) break ;;
  esac
done

if [ -n "$REMEDIATION_KIND" ]; then
  case "$REMEDIATION_KIND" in
    qa|uat) ;;
    *) echo "error: --remediation-kind must be 'qa' or 'uat', got: $REMEDIATION_KIND" >&2; exit 1 ;;
  esac
fi

PHASE_DIR="${1:?Usage: compile-verify-context.sh [--remediation-only] [--remediation-kind qa|uat] phase-dir}"

if [ ! -d "$PHASE_DIR" ]; then
  echo "verify_context_error=no_phase_dir"
  exit 0
fi

if [ "$REMEDIATION_ONLY" = true ]; then
  resolve_remediation_scope
fi

if [ "$REMEDIATION_ONLY" = false ]; then
  resolve_full_scope
fi

if [ -z "$ALL_PLAN_FILES" ]; then
  echo "verify_context=empty"
  exit 0
fi

echo "$SCOPE_HEADER"
echo "uat_path=$UAT_PATH"

PLAN_COUNT=0
ACCEPTED_DEVIATION_SIGNATURES=""
EMITTED_SUMMARY_DEVIATION_SIGNATURES=""
TRACK_UAT_DEVIATIONS_SCRIPT="$_CVC_SCRIPT_DIR/track-uat-deviations.sh"
if [ -x "$TRACK_UAT_DEVIATIONS_SCRIPT" ]; then
  ACCEPTED_DEVIATION_SIGNATURES=$(bash "$TRACK_UAT_DEVIATIONS_SCRIPT" accepted-signatures "$PHASE_DIR" 2>/dev/null || true)
fi

while IFS= read -r plan_file; do
  [ -f "$plan_file" ] || continue
  PLAN_COUNT=$((PLAN_COUNT + 1))
  process_plan_file "$plan_file"
done <<< "$ALL_PLAN_FILES"

print_known_issues_section

_cvc_phase_verif=$(bash "${_CVC_SCRIPT_DIR}/resolve-verification-path.sh" phase "$PHASE_DIR" 2>/dev/null || true)
if [ -n "$_cvc_phase_verif" ] && [ ! -f "$_cvc_phase_verif" ]; then
  _cvc_phase_verif=""
fi

_cvc_source_fail_verif=$(bash "${_CVC_SCRIPT_DIR}/resolve-verification-path.sh" plan-input "$PHASE_DIR" 2>/dev/null || true)
if [ -n "$_cvc_source_fail_verif" ] && [ ! -f "$_cvc_source_fail_verif" ]; then
  _cvc_source_fail_verif=""
fi
resolve_source_fail_verif

_cvc_qa_round_verifs=$(find "$PHASE_DIR" -path '*/remediation/qa/round-*/R*-VERIFICATION.md' 2>/dev/null | sort)

_cvc_has_verif_history=false
if [ -n "$_cvc_phase_verif" ] && [ -f "$_cvc_phase_verif" ]; then
  _cvc_has_verif_history=true
fi
if [ -n "$_cvc_qa_round_verifs" ]; then
  _cvc_has_verif_history=true
fi
if [ "$_cvc_source_fail_verif_missing" = true ]; then
  _cvc_has_verif_history=true
fi

if [ "$_cvc_has_verif_history" = true ]; then
  echo "=== VERIFICATION HISTORY ==="
  print_phase_verification_fails
  print_original_fail_resolution_status
  print_qa_round_verification_fails
  echo ""
fi

echo "verify_plan_count=${PLAN_COUNT}"
