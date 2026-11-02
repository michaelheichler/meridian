load test_helper
load gate_case_helper

isolated_state_case() (
  set -e
  BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR/state-rows/$1"
  export BATS_TEST_TMPDIR
  mkdir -p "$BATS_TEST_TMPDIR/repo"
  cd "$BATS_TEST_TMPDIR/repo"
  git init -q
  setup
  trap 'teardown' EXIT
  "$1"
)

run_state_case() {
  run isolated_state_case "$1"
  expect_case "$1" 0
}
