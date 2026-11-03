#!/usr/bin/env bash

. "$(CDPATH="" cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/../lib/rename-migration.sh"
meridian_migrate_environment
set -euo pipefail

REPO=/w
OUT=/out
PYDATA=/tmp/pycov

# Tests are omitted because they are not production, except scope_guard.py.
write_pycov_rcfile() {
  local omit="" file
  for file in "$REPO"/hooks/test_*.py; do
    [ "$(basename "$file")" = scope_guard.py ] || omit="$omit,$file"
  done
  mkdir -p "$PYDATA"
  cat >"$PYDATA/rc" <<RC
[run]
branch = True
parallel = True
data_file = $PYDATA/.coverage
source = $REPO/hooks
omit = $REPO/hooks/guard_fixtures.py$omit
RC
}

run_python_unit_tests() {
  (cd "$REPO" && python3 -m coverage run --rcfile="$PYDATA/rc" -m unittest discover -s hooks -t . -p 'test_*.py') \
    >"$OUT/unittest.log" 2>&1 || echo "hook unit tests exited non-zero, see unittest.log" >&2
}

# CDPATH is unset because it hangs. /tmp is traced because tests run copies there.
run_bats_under_kcov() {
  (cd "$REPO" && env -u CDPATH kcov --include-path="$REPO/scripts,/tmp" \
    --exclude-path="$REPO/scripts/tests,$REPO/scripts/dev,/tmp/kc,$PYDATA" \
    /tmp/kc bats --tap tests/) >"$OUT/bats-tap.log" 2>"$OUT/kcov-stderr.log" || true
}

# Output goes to a TSV because compare needs a stable format.
bash_tables() {
  local report_dir
  report_dir=$(find /tmp/kc -maxdepth 1 -type d -name 'bats.*' | head -1)
  python3 "$REPO/scripts/dev/coverage-bash-merge.py" "$report_dir" "$REPO" "$OUT/bash-files.tsv"
}

# Scripts kcov never traced are absent from its totals, so they are listed apart.
untraced_scripts() {
  (cd "$REPO" && find scripts -name '*.sh' -not -path 'scripts/tests/*' -not -path 'scripts/dev/*' | sort) \
    | comm -23 - <(cut -f1 "$OUT/bash-files.tsv" | sort) >"$OUT/bash-untraced.txt"
}

python_tables() {
  cd "$REPO"
  python3 -m coverage combine --rcfile="$PYDATA/rc" "$PYDATA" >/dev/null
  python3 -m coverage json --rcfile="$PYDATA/rc" -o "$PYDATA/report.json" >/dev/null
  python3 "$REPO/scripts/dev/coverage-report.py" "$PYDATA/report.json" "$OUT"
  sed -i "s#$REPO/##" "$OUT/python-files.tsv" "$OUT/python-branches.tsv"
}

write_summary() {
  jq -n --rawfile bash "$OUT/bash-files.tsv" --rawfile py "$OUT/python-files.tsv" '
    def rows(t): t | split("\n") | map(select(length > 0) | split("\t"));
    def total(r; c; t):
      (r | map(.[c] | tonumber) | add // 0) as $c | (r | map(.[t] | tonumber) | add // 0) as $t
      | {covered: $c, total: $t, percent: (if $t == 0 then 100 else ($c * 10000 / $t | round / 100) end)};
    {bash: total(rows($bash); 1; 2), python: {lines: total(rows($py); 1; 2), branches: total(rows($py); 4; 5)}}' \
    >"$OUT/summary.json"
}

# Because a worktree .git file points at a host path, tests need a fresh repo.
fresh_git_repo() {
  cd "$REPO"
  rm -rf .git .coverage-out
  git config --global --add safe.directory "$REPO"
  git config --global user.email coverage@example.invalid
  git config --global user.name coverage
  git init -q
  git add -A
  git commit -qm base
}

main() {
  fresh_git_repo
  write_pycov_rcfile
  export COVERAGE_PROCESS_START="$PYDATA/rc"
  run_python_unit_tests
  run_bats_under_kcov
  bash_tables
  untraced_scripts
  python_tables
  write_summary
}

main "$@"
