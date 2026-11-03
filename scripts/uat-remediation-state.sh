#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/lib/uat-utils.sh" ]; then
  source "$SCRIPT_DIR/lib/uat-utils.sh"
fi
CMD="${1:-}"
PHASE_DIR="${2:-}"
SEVERITY_ARG="${3:-}"

if [ -z "$CMD" ] || [ -z "$PHASE_DIR" ]; then
  echo "Usage: uat-remediation-state.sh <get|advance|reset|init|get-or-init|needs-round|current-round> <phase-dir> [severity]" >&2
  exit 1
fi

reject_milestone_phase_dir() {
  local phase_dir="$1"

  case "$phase_dir" in
    */.meridian/milestones/*|.meridian/milestones/*)
      echo "Error: refusing to operate on archived milestone path: $phase_dir" >&2
      echo "Remediation must target active phases in .meridian/phases/" >&2
      echo "Use create-remediation-phase.sh to create active remediation phases from milestone UAT." >&2
      exit 1
      ;;
  esac
}

canonicalize_existing_or_parent() {
  local path="$1" parent base parent_real

  if [ -d "$path" ]; then
    (CDPATH='' cd -- "$path" && pwd -P)
    return 0
  fi

  parent=$(dirname "$path")
  base=$(basename "$path")
  if parent_real=$(CDPATH='' cd -- "$parent" 2>/dev/null && pwd -P); then
    printf '%s/%s\n' "$parent_real" "$base"
  else
    printf '%s\n' "$path"
  fi
}

active_phase_root() {
  local candidate="$1"
  if [[ "$candidate" != *"/.meridian/phases/"* ]]; then
    echo "Error: UAT remediation phase must be under active .meridian/phases/: $candidate" >&2
    exit 1
  fi
  printf '%s\n' "${candidate%%/.meridian/phases/*}"
}

canonicalize_phase_dir() {
  local raw_phase_dir="$1" candidate phase_root
  if [[ "$raw_phase_dir" = /* ]]; then
    candidate="$raw_phase_dir"
  else
    candidate="${MERIDIAN_CONFIG_ROOT:-$(pwd -P)}/$raw_phase_dir"
  fi
  candidate=$(canonicalize_existing_or_parent "$candidate")
  reject_milestone_phase_dir "$candidate"
  phase_root=$(active_phase_root "$candidate")
  [ -n "$phase_root" ] || { echo "Error: unable to determine MERIDIAN root from phase path: $candidate" >&2; exit 1; }
  export MERIDIAN_CONFIG_ROOT="$phase_root"
  export MERIDIAN_PLANNING_DIR="$phase_root/.meridian"
  printf '%s\n' "$candidate"
}

reject_milestone_phase_dir "$PHASE_DIR"
PHASE_DIR=$(canonicalize_phase_dir "$PHASE_DIR")

case "$PHASE_DIR" in
  */.meridian/milestones/*)
    echo "Error: refusing to operate on archived milestone path: $PHASE_DIR" >&2
    echo "Remediation must target active phases in .meridian/phases/" >&2
    echo "Use create-remediation-phase.sh to create active remediation phases from milestone UAT." >&2
    exit 1
    ;;
esac

STATE_FILE="$PHASE_DIR/remediation/uat/.uat-remediation-stage"
LEGACY_STATE_FILE="$PHASE_DIR/.uat-remediation-stage"
LEGACY_REMED_STATE_FILE="$PHASE_DIR/remediation/.uat-remediation-stage"

reconcile_uat_state() {
  local changed_path="${1:-$STATE_FILE}"

  [ -f "$SCRIPT_DIR/reconcile-state-md.sh" ] || return 0
  if [ -e "$changed_path" ]; then
    bash "$SCRIPT_DIR/reconcile-state-md.sh" --changed "$changed_path" >/dev/null 2>&1 || true
  else
    bash "$SCRIPT_DIR/reconcile-state-md.sh" --changed "$PHASE_DIR" >/dev/null 2>&1 || true
  fi
}

read_state_stage_value() {
  local file="$1" _val=""

  if grep -q '^stage=' "$file" 2>/dev/null; then
    _val=$(grep '^stage=' "$file" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]')
  else
    _val=$(tr -d '[:space:]' < "$file")
  fi
  printf '%s\n' "${_val:-none}"
}

read_state_round_value() {
  local file="$1" _val=""

  _val=$(grep '^round=' "$file" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]' || true)
  printf '%s\n' "${_val:-01}"
}

normalize_round_padded_value() {
  local raw="$1" num

  num=$(printf '%s\n' "$raw" | sed 's/^0*//')
  num="${num:-0}"
  case "$num" in
    *[!0-9]*|"")
      echo "Error: invalid UAT remediation round value: $raw" >&2
      return 1
      ;;
  esac
  printf '%02d\n' "$num"
}

migrate_legacy_remediation_state_if_needed() {
  local _mig_rd _mig_name
  [ ! -f "$STATE_FILE" ] && [ -f "$LEGACY_REMED_STATE_FILE" ] || return 0

  mkdir -p "$PHASE_DIR/remediation/uat"
  cp "$LEGACY_REMED_STATE_FILE" "$STATE_FILE"
  for _mig_rd in "$PHASE_DIR/remediation"/round-*/; do
    [ -d "$_mig_rd" ] || continue
    _mig_name=$(basename "$_mig_rd")
    if [ ! -d "$PHASE_DIR/remediation/uat/$_mig_name" ]; then
      mv "$_mig_rd" "$PHASE_DIR/remediation/uat/$_mig_name"
    fi
  done
  rm -f "$LEGACY_REMED_STATE_FILE"
  reconcile_uat_state "$STATE_FILE"
}

if [ "$CMD" != "needs-round" ]; then
  migrate_legacy_remediation_state_if_needed
fi

MAJOR_STAGES=("research" "plan" "execute" "done")
MINOR_STAGES=("fix" "done")

extract_phase_num() {
  uat_phase_num_for_dir "$PHASE_DIR"
}

infer_legacy_current_round() {
  uat_infer_legacy_current_round "$PHASE_DIR"
}

resolve_legacy_round() {
  local stored_round="$1"
  uat_resolve_legacy_round "$PHASE_DIR" "$stored_round"
}

bare_stage_word() {
  local word
  word=$(tr -d '[:space:]' < "$1")
  case "$word" in
    *=*) echo "none" ;;
    *) echo "$word" ;;
  esac
}

get_stage() {
  if [ -f "$STATE_FILE" ]; then
    local _val
    _val=$(grep '^stage=' "$STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]' || true)
    if [ -n "$_val" ]; then
      echo "$_val"
    else
      bare_stage_word "$STATE_FILE"
    fi
  elif [ -f "$LEGACY_STATE_FILE" ]; then
    local _val
    _val=$(grep '^stage=' "$LEGACY_STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]' || true)
    if [ -n "$_val" ]; then
      echo "$_val"
    else
      bare_stage_word "$LEGACY_STATE_FILE"
    fi
  else
    echo "none"
  fi
}

get_round() {
  local _val=""

  if [ -f "$STATE_FILE" ]; then
    _val=$(grep '^round=' "$STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]' || true)
    if [ -n "$_val" ]; then
      if [ "$(get_layout)" = "legacy" ]; then
        resolve_legacy_round "$_val"
      else
        echo "$_val"
      fi
    elif [ "$(get_layout)" = "legacy" ]; then
      resolve_legacy_round ""
    else
      echo "01"
    fi
  else
    if [ -f "$LEGACY_STATE_FILE" ]; then
      _val=$(grep '^round=' "$LEGACY_STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]' || true)
      resolve_legacy_round "$_val"
    else
      echo "01"
    fi
  fi
}

get_layout() {
  if [ -f "$STATE_FILE" ]; then
    local _val
    _val=$(grep '^layout=' "$STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]' || true)
    echo "${_val:-round-dir}"
  else
    if [ -f "$LEGACY_STATE_FILE" ]; then
      local _val
      _val=$(grep '^layout=' "$LEGACY_STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]' || true)
      echo "${_val:-legacy}"
    else
      echo "legacy"
    fi
  fi
}

get_round_dir() {
  local round
  round=$(get_round)
  echo "$PHASE_DIR/remediation/uat/round-${round}"
}

start_new_round() {
  local current_round next_round next_round_padded
  current_round=$(get_round)
  next_round=$(( 10#$current_round + 1 ))
  next_round_padded=$(printf '%02d' "$next_round")
  mkdir -p "$PHASE_DIR/remediation/uat/round-${next_round_padded}"
  printf 'stage=research\nround=%s\nlayout=round-dir\n' "$next_round_padded" > "$STATE_FILE"
  [ -f "$LEGACY_STATE_FILE" ] && rm -f "$LEGACY_STATE_FILE"
  reconcile_uat_state "$STATE_FILE"
  echo "research"
  echo "round=${next_round_padded}"
  echo "round_dir=$PHASE_DIR/remediation/uat/round-${next_round_padded}"
  echo "research_path="
  echo "plan_path="
  echo "summary_path=$PHASE_DIR/remediation/uat/round-${next_round_padded}/R${next_round_padded}-SUMMARY.md"
}

next_stage() {
  local current="$1"
  local -a stages

  case "$current" in
    research|plan|execute) stages=("${MAJOR_STAGES[@]}") ;;
    fix)                  stages=("${MINOR_STAGES[@]}") ;;
    done)                 echo "verify"; return 0 ;;
    *)                    echo "done"; return 0 ;;
  esac

  local found=false
  for s in "${stages[@]}"; do
    if [ "$found" = true ]; then
      echo "$s"
      return 0
    fi
    if [ "$s" = "$current" ]; then
      found=true
    fi
  done

  echo "done"
}

. "$SCRIPT_DIR/lib/uat-remediation-init.sh"
. "$SCRIPT_DIR/lib/uat-remediation-needs-round.sh"

cmd_advance() {
  local current new_stage round layout
  current=$(get_stage)
  if [ "$current" = "none" ]; then
    echo "$current"
  elif [ "$current" = "verify" ]; then
    start_new_round
  elif [ "$current" = "verified" ]; then
    echo "$current"
  else
    new_stage=$(next_stage "$current")
    round=$(get_round)
    layout=$(get_layout)
    mkdir -p "$(dirname "$STATE_FILE")"
    printf 'stage=%s\nround=%s\nlayout=%s\n' "$new_stage" "$round" "$layout" > "$STATE_FILE"
    [ -f "$LEGACY_STATE_FILE" ] && rm -f "$LEGACY_STATE_FILE"
    reconcile_uat_state "$STATE_FILE"
    echo "$new_stage"
  fi
}

adopt_legacy_state_file() {
  local resume_round
  resume_round=$(get_round)
  mkdir -p "$PHASE_DIR/remediation/uat/round-${resume_round}"
  printf 'stage=%s\nround=%s\nlayout=legacy\n' "$1" "$resume_round" > "$STATE_FILE"
  rm -f "$LEGACY_STATE_FILE"
  reconcile_uat_state "$STATE_FILE"
}

cmd_get_or_init() {
  local existing
  if [ -z "$SEVERITY_ARG" ]; then
    echo "Usage: uat-remediation-state.sh get-or-init <phase-dir> <major|minor>" >&2
    exit 1
  fi
  existing=$(get_stage)
  if [ "$existing" != "none" ]; then
    if [ ! -f "$STATE_FILE" ] && [ -f "$LEGACY_STATE_FILE" ]; then
      adopt_legacy_state_file "$existing"
    fi
    echo "$existing"
    emit_plan_metadata
  else
    do_init "$SEVERITY_ARG"
    emit_plan_metadata
    emit_init_context
  fi
}

case "$CMD" in
  get)
    get_stage
    ;;

  advance)
    cmd_advance
    ;;

  reset)
    rm -f "$STATE_FILE" "$LEGACY_STATE_FILE"
    reconcile_uat_state "$PHASE_DIR"
    echo "none"
    ;;

  needs-round)
    cmd_needs_round
    ;;

  current-round)
    get_round
    ;;

  init)
    if [ -z "$SEVERITY_ARG" ]; then
      echo "Usage: uat-remediation-state.sh init <phase-dir> <major|minor>" >&2
      exit 1
    fi
    do_init "$SEVERITY_ARG"
    emit_plan_metadata
    emit_init_context
    ;;

  get-or-init)
    cmd_get_or_init
    ;;

  *)
    echo "Unknown command: $CMD" >&2
    exit 1
    ;;
esac
