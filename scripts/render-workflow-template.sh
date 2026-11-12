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

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
TEMPLATE_DIR="$SCRIPT_DIR/../templates/workflows"
SHAPE="${1:-}"
shift || true

fail() {
  printf 'render-workflow-template: %s\n' "$1" >&2
  exit 1
}

case "$SHAPE" in
  solo) BODY_TOKENS=(JOB TASK_ID ROLE AGENT_TYPE MODEL EFFORT) ;;
  pair) BODY_TOKENS=(JOB TASK_ID AUTONOMY ENGINEER_AGENT_TYPE ENGINEER_MODEL ENGINEER_EFFORT CRITIC_AGENT_TYPE CRITIC_MODEL CRITIC_EFFORT) ;;
  trio) BODY_TOKENS=(JOB TASK_ID AUTONOMY ENGINEER_AGENT_TYPE ENGINEER_MODEL ENGINEER_EFFORT CRITIC_AGENT_TYPE CRITIC_MODEL CRITIC_EFFORT TESTDEV_AGENT_TYPE TESTDEV_MODEL TESTDEV_EFFORT) ;;
  *) fail "unknown shape '$SHAPE', expected solo, pair, or trio" ;;
esac

TEMPLATE="$TEMPLATE_DIR/$SHAPE.js.tpl"
[ -f "$TEMPLATE" ] || fail "template not found for shape '$SHAPE'"

is_allowed_field() {
  local candidate="$1" allowed
  for allowed in NAME DESCRIPTION "${BODY_TOKENS[@]}"; do
    [ "$allowed" = "$candidate" ] && return 0
  done
  return 1
}

is_optional_token() {
  case "$1" in
    *EFFORT) return 0 ;;
    *) return 1 ;;
  esac
}

field_is_set() {
  local slot="FIELD_VALUE_$1"
  [ "${!slot+set}" = set ]
}

load_field() {
  local slot="FIELD_VALUE_$1"
  printf -v CURRENT_FIELD '%s' "${!slot}"
}

for assignment in "$@"; do
  key=${assignment%%=*}
  [ "$key" != "$assignment" ] || fail "expected KEY=VALUE, got '$assignment'"
  is_allowed_field "$key" || fail "unknown field '$key'"
  printf -v "FIELD_VALUE_$key" '%s' "${assignment#*=}"
done

for required in NAME DESCRIPTION "${BODY_TOKENS[@]}"; do
  field_is_set "$required" || fail "missing required field $required"
  load_field "$required"
  is_optional_token "$required" || [ -n "$CURRENT_FIELD" ] || fail "missing required field $required"
done

phase_titles=$(grep -oE 'phase\("[^"]*"\)' "$TEMPLATE" | sed -E 's/^phase\("//; s/"\)$//') || true
[ -n "$phase_titles" ] || fail "template '$SHAPE' declares no phase(\"...\") calls"
PHASE_TITLES_JSON=$(jq -R -s 'split("\n") | map(select(length > 0))' <<< "$phase_titles")
META_JSON=$(jq -nc --arg name "$FIELD_VALUE_NAME" --arg description "$FIELD_VALUE_DESCRIPTION" --argjson phases "$PHASE_TITLES_JSON" \
  '{name: $name, description: $description, phases: $phases}')
META_LINE="export const meta = ${META_JSON};"

SEP=$(printf '\x1f')
rendered=$(cat "$TEMPLATE")
check_rendered="$rendered"

for token in "${BODY_TOKENS[@]}"; do
  marker="@@${token}@@"
  sentinel="${SEP}MERIDIAN_WORKFLOW_SLOT_${token}${SEP}"
  rendered=${rendered//"$marker"/"$sentinel"}
  check_rendered=${check_rendered//"$marker"/"$sentinel"}
done

for token in "${BODY_TOKENS[@]}"; do
  sentinel="${SEP}MERIDIAN_WORKFLOW_SLOT_${token}${SEP}"
  load_field "$token"
  if is_optional_token "$token" && [ -z "$CURRENT_FIELD" ]; then
    escaped='null'
  else
    escaped=$(jq -Rn --arg v "$CURRENT_FIELD" '$v')
  fi
  rendered=${rendered//"$sentinel"/"$escaped"}
  check_rendered=${check_rendered//"$sentinel"/__MERIDIAN_WORKFLOW_USER_CONTENT__}
done

case "$rendered" in
  *"$SEP"*) fail "unit separator sentinel survived rendering" ;;
esac

if grep -qE '@@[A-Z_]+@@' <<< "$check_rendered"; then
  fail "unresolved template token"
fi

printf '%s\n' "$META_LINE"
printf '%s' "$rendered"
