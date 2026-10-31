#!/usr/bin/env bash
set -euo pipefail


PHASE_DIR="${1:-}"
VERIF_NAME="${2:-}"
EXPLICIT_VERIF_NAME=false
if [ -n "$VERIF_NAME" ]; then
  EXPLICIT_VERIF_NAME=true
fi
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)"
RESOLVE_VERIF_SCRIPT="$SCRIPT_DIR/resolve-verification-path.sh"
if [ -f "$SCRIPT_DIR/summary-utils.sh" ]; then
  . "$SCRIPT_DIR/summary-utils.sh"
fi
TRACK_UAT_DEVIATIONS_SCRIPT="$SCRIPT_DIR/track-uat-deviations.sh"
: "$TRACK_UAT_DEVIATIONS_SCRIPT"

. "$SCRIPT_DIR/lib/qa-result-gate-path-evidence.sh"
. "$SCRIPT_DIR/lib/qa-result-gate-path-resolve.sh"
. "$SCRIPT_DIR/lib/qa-result-gate-git-evidence.sh"
. "$SCRIPT_DIR/lib/qa-result-gate-fail-classifications.sh"
. "$SCRIPT_DIR/lib/qa-result-gate-known-issues.sh"
. "$SCRIPT_DIR/lib/qa-result-gate-summary-deviations.sh"
. "$SCRIPT_DIR/lib/qa-result-gate-scope.sh"
. "$SCRIPT_DIR/lib/qa-result-gate-verification.sh"
. "$SCRIPT_DIR/lib/qa-result-gate-round-evidence.sh"
. "$SCRIPT_DIR/lib/qa-result-gate-round-contract.sh"
. "$SCRIPT_DIR/lib/qa-result-gate-routing.sh"

exit_without_phase_dir
resolve_gate_scope
load_gate_known_issues
exit_without_readable_verification
read_verification_frontmatter
count_gate_findings
gather_round_evidence
evaluate_round_contract
compute_exempt_fail_count
emit_gate_report
exit_unless_trusted_result
route_gate_result

exit 0
