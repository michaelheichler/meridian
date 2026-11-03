#!/bin/bash

. "$(CDPATH="" cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/rename-migration.sh"
meridian_migrate_environment
set -u

PHASE_STATE_LIB_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
. "$PHASE_STATE_LIB_DIR/phase-state-dirs.sh"
. "$PHASE_STATE_LIB_DIR/phase-state-qa.sh"
. "$PHASE_STATE_LIB_DIR/phase-state-roadmap.sh"

qa_gate_routing_for_phase() {
  local phase_dir="$1"
  local script_dir="${2:-}" planning_root state_file routing verification_file

  planning_root=$(planning_root_from_phase_dir "$phase_dir")
  state_file="${planning_root}/.execution-state.json"
  if [ "$(qa_required_for_phase "$phase_dir")" != "true" ]; then
    printf '%s\n' "PROCEED_TO_UAT"
    return 0
  fi
  if [ -z "$script_dir" ]; then
    script_dir=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  fi
  if [ ! -f "$state_file" ]; then
    if ! verification_file=$(bash "$script_dir/resolve-verification-path.sh" phase "$phase_dir" 2>/dev/null); then
      printf '%s\n' "QA_RERUN_REQUIRED"
      return 0
    fi
    if [ -z "$verification_file" ] || [ ! -f "$verification_file" ]; then
      printf '%s\n' "QA_RERUN_REQUIRED"
      return 0
    fi
  fi

  routing=$(bash "$script_dir/qa-result-gate.sh" "$phase_dir" 2>/dev/null | awk -F= '$1 == "qa_gate_routing" { routing = $2 } END { print routing }')
  printf '%s\n' "${routing:-QA_RERUN_REQUIRED}"
}

qa_completion_allowed_for_phase() {
  [ "$(qa_gate_routing_for_phase "$1" "${2:-}")" = "PROCEED_TO_UAT" ]
}
