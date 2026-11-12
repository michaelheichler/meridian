#!/usr/bin/env bash

printf -v MERIDIAN_MIGRATION_SOURCE '%s' "${BASH_SOURCE[0]}"
case "$MERIDIAN_MIGRATION_SOURCE" in
  *"/"*) printf -v MERIDIAN_MIGRATION_SOURCE '%s' "${MERIDIAN_MIGRATION_SOURCE%"/"*}" ;;
  *) printf -v MERIDIAN_MIGRATION_SOURCE '%s' . ;;
esac
if [ -f "$MERIDIAN_MIGRATION_SOURCE/../lib/rename-migration.sh" ]; then
  . "$MERIDIAN_MIGRATION_SOURCE/../lib/rename-migration.sh"
  meridian_migrate_environment
fi
unset MERIDIAN_MIGRATION_SOURCE
set -euo pipefail


if [[ $# -lt 3 ]]; then
  echo "Usage: bootstrap-project.sh OUTPUT_PATH NAME DESCRIPTION [CORE_VALUE]" >&2
  exit 1
fi

OUTPUT_PATH="$1"
DESCRIPTION="$3"
CORE_VALUE="${4:-$DESCRIPTION}"

mkdir -p "$(dirname "$OUTPUT_PATH")"

cat > "$OUTPUT_PATH" <<EOF

${DESCRIPTION}

**Core value:** ${CORE_VALUE}





- **Zero dependencies**: No package.json, npm, or build step
- **Bash + Markdown only**: All logic in shell scripts and markdown commands


| Decision | Rationale | Outcome |
|----------|-----------|---------|
EOF

exit 0
