run_isolated_case() (
  set -e
  local scenario=$1
  BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR/$scenario"
  export BATS_TEST_TMPDIR
  mkdir -p "$BATS_TEST_TMPDIR/repo"
  trap teardown EXIT
  cd "$BATS_TEST_TMPDIR/repo"
  git init -q
  setup
  "$scenario"
)

run_scenario_cases() {
  local scenario
  reset_case_failures
  for scenario in "$@"; do
    run run_isolated_case "$scenario"
    expect_case "$scenario" 0
  done
  assert_no_case_failures
}
