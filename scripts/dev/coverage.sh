#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)"
IMAGE="lbwc-coverage:4"
LOSS_LIMIT="0.5"

usage() {
  cat <<'USAGE'
Usage: coverage.sh run [--out DIR]
       coverage.sh compare BEFORE_DIR AFTER_DIR
       coverage.sh --help

run      Build the image if missing, run the full bats suite under kcov and the
         hook tests under coverage.py. Default DIR is .coverage-out/.
         Writes bash-files.tsv, python-files.tsv, python-branches.tsv,
         bash-untraced.txt, summary.json, bats-tap.log and unittest.log.
         DIR must sit under a path the Docker VM shares, so avoid /tmp.
compare  Print per-file deltas. Exit 1 if any file loses more than 0.5 points
         or total bash line coverage falls.
USAGE
}

die() {
  echo "coverage: $*" >&2
  exit 1
}

# Checking first is needed because a stopped daemon gives a confusing build error.
require_docker() {
  command -v docker >/dev/null 2>&1 || die "docker is required"
  docker info >/dev/null 2>&1 || die "docker daemon is not reachable"
}

ensure_image() {
  docker image inspect "$IMAGE" >/dev/null 2>&1 && return 0
  docker build -t "$IMAGE" -f "$SCRIPT_DIR/coverage.Dockerfile" "$SCRIPT_DIR"
}

# Because the mount is read-only, tests need a writable copy of /src.
container_script() {
  echo 'cp -a /src/. /w/ && cd /w && bash /w/scripts/dev/coverage-inner.sh'
}

cmd_run() {
  local out=".coverage-out"
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) out="${2:?--out requires a value}"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  mkdir -p "$out"
  out="$(CDPATH='' cd -- "$out" && pwd)"
  require_docker
  ensure_image
  docker run --rm -v "$REPO_ROOT":/src:ro -v "$out":/out "$IMAGE" bash -c "$(container_script)"
  echo "coverage: results in $out"
}

# Because a rename must not hide a loss, new files print "new".
delta_table() {
  local before="$1" after="$2"
  awk -F'\t' 'NR == FNR { b[$1] = $4; next }
    { old = ($1 in b) ? b[$1] : "new"; printf "%s\t%s\t%s\t%.2f\n", $1, old, $4, $4 - (old == "new" ? 0 : old) }' \
    "$before" "$after"
}

files_in_scope() {
  cat "$1/bash-files.tsv" "$1/python-files.tsv" | cut -f1-4
}

losing_files() {
  awk -F'\t' -v limit="$LOSS_LIMIT" '$4 < -limit { print $1 }'
}

total_percent() {
  jq -r '.bash.percent' "$1/summary.json"
}

report_gate() {
  local losers="$1" total_before="$2" total_after="$3" failed=0
  echo "total bash line coverage: $total_before -> $total_after"
  if [ -n "$losers" ]; then
    echo "FAIL: files lost more than $LOSS_LIMIT points:" >&2
    printf '  %s\n' "$losers" >&2
    failed=1
  fi
  if awk -v a="$total_after" -v b="$total_before" 'BEGIN { exit !(a < b) }'; then
    echo "FAIL: total line coverage fell" >&2
    failed=1
  fi
  return "$failed"
}

cmd_compare() {
  [ $# -eq 2 ] || die "compare needs BEFORE_DIR and AFTER_DIR"
  local before="$1" after="$2" dir table losers
  for dir in "$before" "$after"; do
    [ -f "$dir/summary.json" ] || die "no summary.json in $dir"
  done
  table=$(delta_table <(files_in_scope "$before") <(files_in_scope "$after"))
  printf 'file\tbefore\tafter\tdelta\n%s\n' "$table" | column -t -s "$(printf '\t')"
  losers=$(printf '%s\n' "$table" | losing_files)
  report_gate "$losers" "$(total_percent "$before")" "$(total_percent "$after")"
}

main() {
  case "${1:-}" in
    run) shift; cmd_run "$@" ;;
    compare) shift; cmd_compare "$@" ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 1 ;;
  esac
}

main "$@"
