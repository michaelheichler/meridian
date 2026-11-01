#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: compile-context.sh <phase-number> <role> [phases-dir]" >&2
  exit 1
fi

PHASE="$1"
ROLE="$2"
PHASES_DIR_INPUT="${3:-}"
PLAN_PATH="${4:-}"
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

. "${SCRIPT_DIR}/lib/lbwc-target-root.sh"
. "${SCRIPT_DIR}/lib/lbwc-settings.sh"
. "${SCRIPT_DIR}/lib/compile-context-emit.sh"
. "${SCRIPT_DIR}/lib/compile-context-roles.sh"

TARGET_SCOPE_EXPLICIT=0
if [ -n "${LBWC_PLANNING_DIR:-}" ] || [ $# -ge 3 ] || [ $# -ge 4 ]; then
  TARGET_SCOPE_EXPLICIT=1
fi

resolve_preferred_planning_dir() {
  local explicit_planning_dir

  explicit_planning_dir=$(lbwc_resolve_target_planning_dir "1" "$PLAN_PATH" "$PHASES_DIR_INPUT" 2>/dev/null || true)
  if [ -n "$explicit_planning_dir" ]; then
    printf '%s\n' "$explicit_planning_dir"
    return 0
  fi

  if [ -n "${LBWC_PLANNING_DIR:-}" ]; then
    printf '%s\n' "$LBWC_PLANNING_DIR"
    return 0
  fi

  lbwc_resolve_target_planning_dir "$TARGET_SCOPE_EXPLICIT" "$PLAN_PATH" "$PHASES_DIR_INPUT" 2>/dev/null || printf '%s\n' '.lbwc-planning'
}

PLANNING_DIR=$(resolve_preferred_planning_dir)
PLANNING_DIR=$(lbwc_candidate_dir_for_path "$PLANNING_DIR" 2>/dev/null || printf '%s\n' "$PLANNING_DIR")
TARGET_ROOT=$(lbwc_resolve_target_root "$TARGET_SCOPE_EXPLICIT" "$PLAN_PATH" "$PHASES_DIR_INPUT" "$PLANNING_DIR" || true)

if [ -n "$TARGET_ROOT" ] && [ -d "$TARGET_ROOT/.lbwc-planning" ] && [ ! -d "$PLANNING_DIR" ]; then
  PLANNING_DIR="$TARGET_ROOT/.lbwc-planning"
fi

PHASES_DIR="${PHASES_DIR_INPUT:-${PLANNING_DIR}/phases}"

case "$PHASES_DIR" in
  */.lbwc-planning/milestones/*|.lbwc-planning/milestones/*)
    echo "Error: refusing to compile context for archived milestone path: $PHASES_DIR" >&2
    echo "Execution must target active phases in .lbwc-planning/phases/" >&2
    exit 1
    ;;
esac

update_context_index() {
  local cache_key="$1" context_path="$2" role="$3" phase="$4"
  local index_path="${PLANNING_DIR}/.cache/context-index.json"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")

  mkdir -p "$(dirname "$index_path")" 2>/dev/null || return 0

  if [ ! -f "$index_path" ]; then
    echo '{"entries":{}}' > "$index_path" 2>/dev/null || return 0
  fi

  local tmp
  tmp=$(mktemp 2>/dev/null) || return 0
  if jq --arg key "$cache_key" \
       --arg path "$context_path" \
       --arg role "$role" \
       --arg phase "$phase" \
       --arg ts "$timestamp" \
       '.entries[$key] = {path: $path, role: $role, phase: $phase, timestamp: $ts}' \
       "$index_path" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$index_path" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

PHASE_NUM=$(echo "$PHASE" | sed 's/^0*//')
if [ -z "$PHASE_NUM" ]; then PHASE_NUM="0"; fi

PHASE_DIR=$(find "$PHASES_DIR" -maxdepth 1 -type d -name "${PHASE}-*" 2>/dev/null | head -1)

resolve_research_file_per_plan() {
  local phase_dir="$1" plan_path="$2" plan_basename plan_prefix per_plan_research

  [ -n "$plan_path" ] && [ -f "$plan_path" ] || return 0
  plan_basename=$(basename "$plan_path" .md)
  plan_prefix=$(echo "$plan_basename" | sed 's/-PLAN$//')
  per_plan_research="${phase_dir}/${plan_prefix}-RESEARCH.md"
  [ -f "$per_plan_research" ] && echo "$per_plan_research"
}

resolve_research_file_phase_wide() {
  local phase_dir="$1" phase_base phase_num phase_wide_research

  phase_base=$(basename "$phase_dir")
  phase_num=$(echo "$phase_base" | sed 's/^\([0-9]*\).*/\1/')
  [ -n "$phase_num" ] || return 0
  phase_num=$(printf "%02d" "$((10#$phase_num))")
  phase_wide_research="${phase_dir}/${phase_num}-RESEARCH.md"
  [ -f "$phase_wide_research" ] && echo "$phase_wide_research"
}

resolve_research_file() {
  local phase_dir="$1" plan_path="$2" found

  found=$(resolve_research_file_per_plan "$phase_dir" "$plan_path")
  [ -n "$found" ] && { echo "$found"; return; }

  found=$(resolve_research_file_phase_wide "$phase_dir")
  [ -n "$found" ] && { echo "$found"; return; }

  find "$phase_dir" -maxdepth 1 -name "*-RESEARCH.md" -print -quit 2>/dev/null || true
}

if [ -z "$PHASE_DIR" ]; then
  PADDED=$(printf "%02d" "$PHASE" 2>/dev/null || echo "$PHASE")
  PHASE_DIR=$(find "$PHASES_DIR" -maxdepth 1 -type d -name "${PADDED}-*" 2>/dev/null | head -1)
fi
if [ -z "$PHASE_DIR" ]; then
  echo "Phase ${PHASE} directory not found" >&2
  exit 1
fi

ROADMAP="$PLANNING_DIR/ROADMAP.md"

PHASE_SECTION=""
PHASE_GOAL="Not available"
PHASE_REQS="Not available"
PHASE_SUCCESS="Not available"

if [ -f "$ROADMAP" ]; then
  PHASE_SECTION=$(awk -v heading="## Phase ${PHASE_NUM}:" '
    /^## Phase [0-9]/ && inside { exit }
    index($0, heading) == 1 { inside = 1 }
    inside { print }
  ' "$ROADMAP" 2>/dev/null) || true
  if [ -n "$PHASE_SECTION" ]; then
    PHASE_GOAL=$(echo "$PHASE_SECTION" | grep '^\*\*Goal:\*\*' 2>/dev/null | sed 's/\*\*Goal:\*\* *//' ) || PHASE_GOAL="Not available"
    PHASE_REQS=$(echo "$PHASE_SECTION" | grep '^\*\*Reqs:\*\*' 2>/dev/null | sed 's/\*\*Reqs:\*\* *//' ) || PHASE_REQS="Not available"
    PHASE_SUCCESS=$(echo "$PHASE_SECTION" | grep '^\*\*Success:\*\*' 2>/dev/null | sed 's/\*\*Success:\*\* *//' ) || PHASE_SUCCESS="Not available"
  fi
fi

REQ_PATTERN=""
if [ "$PHASE_REQS" != "Not available" ] && [ -n "$PHASE_REQS" ]; then
  REQ_PATTERN=$(echo "$PHASE_REQS" | tr ',' '\n' | sed 's/^ *//' | sed 's/ *$//' | paste -sd '|' -) || true
fi

V3_CACHE_ENABLED=true
CACHE_HASH=""
CONFIG_PATH="${PLANNING_DIR}/config.json"
MERGED_CONFIG=$(lbwc_merged_config "$CONFIG_PATH")

V3_DELTA_ENABLED=true
V3_METRICS_ENABLED=true
START_TIME=""

if command -v jq &>/dev/null; then
  V3_METRICS_ENABLED=$(jq -r 'if .metrics != null then .metrics elif .v3_metrics != null then .v3_metrics else true end' <<< "$MERGED_CONFIG" 2>/dev/null || echo "true")
fi

ROLLING_SUMMARY=false
if command -v jq &>/dev/null; then
  ROLLING_SUMMARY=$(jq -r 'if .rolling_summary != null then .rolling_summary elif .v3_rolling_summary != null then .v3_rolling_summary else false end' <<< "$MERGED_CONFIG" 2>/dev/null || echo "false")
fi

ROLLING_CONTEXT_PATH="${PLANNING_DIR}/ROLLING-CONTEXT.md"
ROLLING_CONTEXT_SECTION=""
if [ "$ROLLING_SUMMARY" = "true" ] && [ "$PHASE_NUM" -gt 1 ] 2>/dev/null && [ -f "$ROLLING_CONTEXT_PATH" ]; then
  ROLLING_CONTEXT_SECTION=$(cat "$ROLLING_CONTEXT_PATH" 2>/dev/null || true)
fi

MILESTONE_CONTEXT_PATH="${PLANNING_DIR}/CONTEXT.md"
MILESTONE_CONTEXT_SECTION=""
if [ -f "$MILESTONE_CONTEXT_PATH" ]; then
  MILESTONE_CONTEXT_SECTION=$(sed '1{/^# /d;}' "$MILESTONE_CONTEXT_PATH" 2>/dev/null || true)
fi

CAVEMAN_STYLE="none"
CAVEMAN_COMMIT="false"
CAVEMAN_REVIEW="false"
if command -v jq &>/dev/null; then
  CAVEMAN_STYLE=$(jq -r '.caveman_style // "none"' <<< "$MERGED_CONFIG" 2>/dev/null || echo "none")
  CAVEMAN_COMMIT=$(jq -r 'if .caveman_commit == null then false else .caveman_commit end' <<< "$MERGED_CONFIG" 2>/dev/null || echo "false")
  CAVEMAN_REVIEW=$(jq -r 'if .caveman_review == null then false else .caveman_review end' <<< "$MERGED_CONFIG" 2>/dev/null || echo "false")
fi

if [ "$V3_METRICS_ENABLED" = "true" ]; then
  START_TIME=$(date +%s 2>/dev/null || echo "0")
fi

try_serve_from_cache() {
  local cache_result cache_status cache_hash cached_path output_path

  cache_result=$(bash "${SCRIPT_DIR}/cache-context.sh" "$PHASE" "$ROLE" "$CONFIG_PATH" "$PLAN_PATH" 2>/dev/null || echo "miss nohash")
  cache_status=$(echo "$cache_result" | cut -d' ' -f1)
  cache_hash=$(echo "$cache_result" | cut -d' ' -f2)
  CACHE_HASH="$cache_hash"

  [ "$cache_status" = "hit" ] || return 1

  cached_path=$(echo "$cache_result" | cut -d' ' -f3)
  output_path="${PHASE_DIR}/.context-${ROLE}.md"
  cp "$cached_path" "$output_path" 2>/dev/null || { echo "V3 fallback: cache copy failed for ${ROLE}, compiling fresh" >&2; return 1; }

  update_context_index "$cache_hash" "$cached_path" "$ROLE" "$PHASE"
  if [ "$V3_METRICS_ENABLED" = "true" ] && [ -f "${SCRIPT_DIR}/lib/session-telemetry.py" ]; then
    python3 "${SCRIPT_DIR}/lib/session-telemetry.py" record \
      --event command --outcome success --phase "$PHASE" --root "$PLANNING_DIR" \
      >/dev/null 2>&1 || true
  fi
  echo "$output_path"
  return 0
}

if [ "$V3_CACHE_ENABLED" = "true" ] && [ -f "${SCRIPT_DIR}/cache-context.sh" ]; then
  try_serve_from_cache && exit 0
elif [ "$V3_CACHE_ENABLED" = "true" ]; then
  echo "V3 fallback: cache-context.sh not found, skipping cache" >&2
fi

case "$ROLE" in
  lead) compile_context_lead ;;
  dev) compile_context_dev ;;
  qa) compile_context_qa ;;
  scout) compile_context_scout ;;
  debugger) compile_context_debugger ;;
  architect) compile_context_architect ;;
  *)
    echo "Unknown role: $ROLE. Valid roles: lead, dev, qa, scout, debugger, architect" >&2
    exit 1
    ;;
esac

if [ "$V3_CACHE_ENABLED" = "true" ] && [ -n "$CACHE_HASH" ] && [ "$CACHE_HASH" != "nohash" ]; then
  CACHE_DIR="${PLANNING_DIR}/.cache/context"
  if mkdir -p "$CACHE_DIR" 2>/dev/null; then
    cp "${PHASE_DIR}/.context-${ROLE}.md" "${CACHE_DIR}/${CACHE_HASH}.md" 2>/dev/null || echo "V3 fallback: cache write failed for ${ROLE}" >&2
    update_context_index "$CACHE_HASH" "${CACHE_DIR}/${CACHE_HASH}.md" "$ROLE" "$PHASE"
  else
    echo "V3 fallback: could not create cache dir" >&2
  fi
fi

if [ "$V3_METRICS_ENABLED" = "true" ] && [ -f "${SCRIPT_DIR}/lib/session-telemetry.py" ]; then
  END_TIME=$(date +%s 2>/dev/null || echo "0")
  DURATION_MS=$(( (END_TIME - ${START_TIME:-0}) * 1000 ))
  python3 "${SCRIPT_DIR}/lib/session-telemetry.py" record \
    --event command --outcome success --duration-ms "$DURATION_MS" \
    --phase "$PHASE" --root "$PLANNING_DIR" >/dev/null 2>&1 || true
fi

echo "${PHASE_DIR}/.context-${ROLE}.md"
