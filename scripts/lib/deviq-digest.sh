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

newest_matching() {
  local phase="$1" file="$2" select="$3" format="$4"
  [ -s "$file" ] || return 0
  jq -c --arg phase "$phase" "$select" "$file" \
    | tail -n 5 \
    | jq -s -r "$format"
}

deviq_nudges_json() {
  local nudges
  nudges=$(jq -c '.' "$1/config/deviq-nudges.json" 2>/dev/null) || nudges='[]'
  [ -n "$nudges" ] || nudges='[]'
  printf '%s' "$nudges"
}

deviq_open_issues() {
  local root="$1" phase="$2" open_filter="$3" nudges_json="$4"
  [ -s "$root/blocks.jsonl" ] || return 0
  jq -c --arg phase "$phase" 'select($phase == "" or .phase == $phase)' "$root/blocks.jsonl" \
    | jq -s -c -f "$open_filter" \
    | jq -r --argjson nudges "$nudges_json" '
        .[-5:] | reverse[] |
        (.trigger // "") as $t |
        ([$nudges[] | . as $n | select($t != "" and (try ($t | test($n.pattern; "i")) catch false))] | first) as $hit |
        "- [\(.phase)] \($t) (fix: \(.fix // ""))"
          + (if $hit then " (see: \($hit.article))" else "" end)
      '
}

deviq_print_sections() {
  local open_issues="$1" recent_decisions="$2"
  if [ -n "$open_issues" ]; then
    printf '## Recent open issues\n%s\n' "$open_issues"
  fi
  if [ -n "$recent_decisions" ]; then
    [ -n "$open_issues" ] && printf '\n'
    printf '## Recent decisions\n%s\n' "$recent_decisions"
  fi
  return 0
}

deviq_digest_main() {
  local script_dir plugin_root root=".meridian/deviq" phase_filter="" open_issues recent_decisions
  script_dir="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
  plugin_root="${CLAUDE_PLUGIN_ROOT:-$(CDPATH='' cd -- "$script_dir/../.." && pwd)}"

  while [ $# -gt 0 ]; do
    case "$1" in
      --phase) phase_filter="${2:?--phase requires a value}"; shift 2 ;;
      --root) root="${2:?--root requires a value}"; shift 2 ;;
      *) echo "deviq-digest: unknown argument: $1" >&2; return 1 ;;
    esac
  done

  open_issues=$(deviq_open_issues "$root" "$phase_filter" "$script_dir/deviq-open-blocks.jq" \
    "$(deviq_nudges_json "$plugin_root")") || return 1
  recent_decisions=$(newest_matching "$phase_filter" "$root/decisions.jsonl" \
    'select($phase == "" or .phase == $phase)' \
    'reverse[] | "- [\(.phase)] \(.summary // "")"') || return 1
  deviq_print_sections "$open_issues" "$recent_decisions"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  deviq_digest_main "$@"
fi
