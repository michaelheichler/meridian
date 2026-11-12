#!/usr/bin/env bash

printf -v MERIDIAN_MIGRATION_SOURCE '%s' "${BASH_SOURCE[0]}"
case "$MERIDIAN_MIGRATION_SOURCE" in
  *"/"*) printf -v MERIDIAN_MIGRATION_SOURCE '%s' "${MERIDIAN_MIGRATION_SOURCE%"/"*}" ;;
  *) printf -v MERIDIAN_MIGRATION_SOURCE '%s' . ;;
esac
if [ -f "$MERIDIAN_MIGRATION_SOURCE/../lib/rename-migration.sh" ]; then
  . "$MERIDIAN_MIGRATION_SOURCE/../lib/rename-migration.sh"
  meridian_migrate_environment
fi
unset MERIDIAN_MIGRATION_SOURCE
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)"
IMAGE="meridian-coverage:5"

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
compare  Compare uncovered line counts per file (bash and python) and uncovered
         branch counts per python file. Exit 1 if any count rises, or if total
         bash line coverage falls with no file explaining it. Percent drops
         above 0.5 points without a rise, new files and removed files print
         as information only. Exit 0 otherwise.
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

coverage_rows() {
  local dir="$1" side="$2"
  awk -F'\t' -v side="$side" -v OFS='\t' '{ print side, "bash", $1, $2, $3, 0, 0 }' "$dir/bash-files.tsv"
  awk -F'\t' -v side="$side" -v OFS='\t' '{ print side, "python", $1, $2, $3, $5, $6 }' "$dir/python-files.tsv"
}

cmd_compare() {
  [ $# -eq 2 ] || die "compare needs BEFORE_DIR and AFTER_DIR"
  local before="$1" after="$2" dir
  for dir in "$before" "$after"; do
    [ -f "$dir/bash-files.tsv" ] || die "no bash-files.tsv in $dir"
    [ -f "$dir/python-files.tsv" ] || die "no python-files.tsv in $dir"
  done
  awk -f "$SCRIPT_DIR/coverage-compare.awk" <(coverage_rows "$before" B; coverage_rows "$after" A)
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
