#!/usr/bin/env bats

load test_helper
load gate_case_helper

ROUTING="${MERIDIAN_ROUTING_UNDER_TEST:-${SCRIPTS_DIR}/meridian-routing.sh}"

setup() {
  setup_temp_dir
  FLAKY_STAT="$TEST_TEMP_DIR/flaky-stat"
  export FLAKY_COUNTER="$TEST_TEMP_DIR/stat-calls"
  printf '%s\n' \
    'case "${@: -1}" in' \
    '  *fd/[0-9])' \
    '    seen=$(cat "$FLAKY_COUNTER" 2>/dev/null || echo 0)' \
    '    printf "%s" $((seen + 1)) > "$FLAKY_COUNTER"' \
    '    [ "$seen" -ge "$FLAKY_FAILS" ] || exit 1 ;;' \
    'esac' \
    'echo 4242' > "$FLAKY_STAT"
  chmod +x "$FLAKY_STAT"
  DRIVER="$TEST_TEMP_DIR/open-guard.sh"
  printf '%s\n' \
    'source "$1"' \
    'STAT_STYLE=gnu STAT_TOOL=$2 LOCK_DIR=$3/lock LOCK_GUARD=$3/guard LOCK_FD=9' \
    'open_lock_guard' > "$DRIVER"
}

teardown() {
  teardown_temp_dir
}

@test "the lock guard descriptor identity survives transient stat failures and fails closed when they persist" {
  local label fail_count want_status fragment
  reset_case_failures
  while IFS='|' read -r label fail_count want_status fragment; do
    rm -f "$FLAKY_COUNTER"
    FLAKY_FAILS=$fail_count run bash "$DRIVER" "$ROUTING" "$FLAKY_STAT" "$TEST_TEMP_DIR"
    expect_case "$label" "$want_status" "$fragment"
  done <<'TABLE'
retry recovers|2|0|
exhaustion fails closed|99|1|could not identify routing lock guard descriptor
TABLE
  assert_no_case_failures
}
