#!/usr/bin/env bash
# Signature keys entries because a repeated issue must stay one entry.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMD="${1:-}"
PHASE_DIR="${2:-}"
VERIFICATION_FILE="${3:-}"

usage() {
  echo "usage: track-known-issues.sh <status|sync-summaries|sync-verification|promote-todos|resolve|clear> <phase-dir> [verification-file|signature]" >&2
  exit 1
}

case "$CMD" in
  status|clear|sync-summaries|promote-todos) [ -n "$PHASE_DIR" ] || usage ;;
  sync-verification|resolve) [ -n "$PHASE_DIR" ] && [ -n "$VERIFICATION_FILE" ] || usage ;;
  *) usage ;;
esac

PHASE_DIR="$(CDPATH='' cd -- "$PHASE_DIR" 2>/dev/null && pwd -P)" || { echo "known_issues_status=missing_phase_dir" >&2; exit 1; }
case "$PHASE_DIR" in
  */.lbwc-planning/phases/*) ;;
  *) echo "known_issues_status=invalid_phase_dir" >&2; exit 1 ;;
esac
PLANNING_DIR="$(CDPATH='' cd -- "$PHASE_DIR/../.." && pwd -P)"
REGISTRY="${PHASE_DIR%/}/known-issues.json"

. "$SCRIPT_DIR/lib/known-issues-registry.sh"
. "$SCRIPT_DIR/lib/known-issues-sync.sh"
. "$SCRIPT_DIR/lib/known-issues-promote.sh"

case "$CMD" in
  status) cmd_status; exit 0 ;;
  clear) cmd_clear; exit 0 ;;
  resolve) cmd_resolve "$VERIFICATION_FILE"; exit 0 ;;
  sync-summaries) sync_summaries; exit 0 ;;
  promote-todos) promote_todos; exit 0 ;;
  sync-verification) sync_verification "$VERIFICATION_FILE" ;;
esac
