#!/usr/bin/env bash
set -euo pipefail


MODE="${1:-}"
PHASE_DIR="${2:-}"
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)"
STATE_FILE="${PHASE_DIR%/}/remediation/qa/.qa-remediation-stage"

if [ -z "$MODE" ] || [ -z "$PHASE_DIR" ]; then
  echo "usage: resolve-verification-path.sh <phase|current|authoritative|plan-input> <phase-dir>" >&2
  exit 1
fi

case "$MODE" in
  phase|current|authoritative|plan-input) ;;
  *)
    echo "error: unknown mode: $MODE" >&2
    exit 1
    ;;
esac

if [ ! -d "$PHASE_DIR" ]; then
  echo "error: phase-dir does not exist: $PHASE_DIR" >&2
  exit 1
fi

source "$SCRIPT_DIR/lib/resolve-verification-path-phase.sh"
source "$SCRIPT_DIR/lib/resolve-verification-path-modes.sh"

phase_path=$(phase_level_path)

case "$MODE" in
  phase) echo "$phase_path" ;;
  current) mode_current "$phase_path" ;;
  authoritative) mode_authoritative "$phase_path" ;;
  plan-input) mode_plan_input "$phase_path" ;;
esac
