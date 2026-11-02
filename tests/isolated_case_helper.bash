run_isolated_case() (
  set -e
  local scenario=$1
  BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR/$scenario"
  mkdir -p "$BATS_TEST_TMPDIR"
  trap teardown EXIT
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
