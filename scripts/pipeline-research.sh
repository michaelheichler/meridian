#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/lbwc-settings.sh"

planning_dir="${1:-.lbwc-planning}"
phase_dir="${2:?Usage: pipeline-research.sh <planning-dir> <phase-dir> [effort]}"
effort="${3:-balanced}"
[ -d "$phase_dir" ] || { printf 'Error: phase directory does not exist\n' >&2; exit 1; }
config=$(lbwc_merged_config "$planning_dir/config.json")
enabled=$(jq -er 'if .pipeline_research == null then false else .pipeline_research end | tostring' <<< "$config")
research_name=$(bash "$SCRIPT_DIR/resolve-artifact-path.sh" phase-research "$phase_dir")
research_path="$phase_dir/$research_name"
phase_number="${research_name%%-*}"
if [ ! -f "$research_path" ] && [ -f "$phase_dir/$phase_number-01-RESEARCH.md" ]; then
  other=$(find "$phase_dir" -maxdepth 1 -name "$phase_number-[0-9][0-9]*-RESEARCH.md" ! -name "$phase_number-01-RESEARCH.md" -print -quit)
  [ -n "$other" ] || research_path="$phase_dir/$phase_number-01-RESEARCH.md"
fi
required=false
forced=false
if [ ! -f "$research_path" ]; then
  if [ "$enabled" = true ] || [ "$effort" != turbo ]; then
    required=true
  fi
  [ "$enabled" != true ] || forced=true
fi
printf 'research_required=%s\nresearch_forced=%s\nresearch_path=%s\n' "$required" "$forced" "$research_path"
