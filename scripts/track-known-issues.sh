#!/usr/bin/env bash
# Signature keys entries because a repeated issue must stay one entry.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMD="${1:-}"
PHASE_DIR="${2:-}"
VERIFICATION_FILE="${3:-}"

usage() {
  cat >&2 <<'EOF'
usage: track-known-issues.sh <status|sync-summaries|sync-verification|promote-todos|resolve|clear|lookup-signature|suppress> <phase-dir> [verification-file|signature]

Registry: .meridian/phases/{NN}-{slug}/known-issues.json
Each entry carries a deterministic 12-hex signature (sha256 of normalized
test+file+error) as its unique identifier, so the same issue reported twice
is one entry, and resolution is checked against evidence, not agent claims.

  status <phase-dir>
      Prints known_issues_path= / known_issues_status=missing|present|malformed
      / known_issues_count=N (count of entries whose disposition is unresolved).
  sync-summaries <phase-dir>
      Reads pre_existing_issues from every *-SUMMARY.md in the phase and upserts entries.
  sync-verification <phase-dir> <verification-file>
      Reads `pre_existing_issues` (JSON array of {test,file,error}) from the
      verification file's frontmatter, upserts entries, and marks entries absent
      from a PASSing verification as resolved.
  promote-todos <phase-dir>
      Adds unresolved entries to the STATE.md Todos section as [KNOWN-ISSUE] lines.
  resolve <phase-dir> <signature>
      Mark one entry resolved by its signature.
  clear <phase-dir>
      Remove the registry (round closed clean).
  lookup-signature <phase-dir>
      Reads {test,file,error,disposition,source_path} JSON on stdin and prints
      {status:ok,signature:{...}} for the matching entry, or {status:error,code,message}.
  suppress <phase-dir>
      Reads a signature JSON plus via on stdin and marks the entry suppressed so
      promote-todos skips it. Idempotent. Prints {status:ok,action,signature} or an error object.
EOF
  exit 1
}

case "$CMD" in
  status|clear|sync-summaries|promote-todos|lookup-signature|suppress) [ -n "$PHASE_DIR" ] || usage ;;
  sync-verification|resolve) [ -n "$PHASE_DIR" ] && [ -n "$VERIFICATION_FILE" ] || usage ;;
  *) usage ;;
esac

PHASE_DIR="$(CDPATH='' cd -- "$PHASE_DIR" 2>/dev/null && pwd -P)" || { echo "known_issues_status=missing_phase_dir" >&2; exit 1; }
case "$PHASE_DIR" in
  */.meridian/phases/*) ;;
  *) echo "known_issues_status=invalid_phase_dir" >&2; exit 1 ;;
esac
PLANNING_DIR="$(CDPATH='' cd -- "$PHASE_DIR/../.." && pwd -P)"
REGISTRY="${PHASE_DIR%/}/known-issues.json"

. "$SCRIPT_DIR/lib/known-issues-registry.sh"
. "$SCRIPT_DIR/lib/known-issues-sync.sh"
. "$SCRIPT_DIR/lib/known-issues-promote.sh"
. "$SCRIPT_DIR/lib/track-known-issues-suppress.sh"

case "$CMD" in
  status) cmd_status; exit 0 ;;
  clear) cmd_clear; exit 0 ;;
  resolve) cmd_resolve "$VERIFICATION_FILE"; exit 0 ;;
  sync-summaries) sync_summaries; exit 0 ;;
  promote-todos) promote_todos; exit 0 ;;
  lookup-signature) cmd_lookup_signature; exit 0 ;;
  suppress) cmd_suppress; exit 0 ;;
  sync-verification) sync_verification "$VERIFICATION_FILE" ;;
esac
