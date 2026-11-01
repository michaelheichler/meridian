#!/bin/bash
set -u

case_failure_log() {
  printf '%s/case-failures.log\n' "$BATS_TEST_TMPDIR"
}

reset_case_failures() {
  : > "$(case_failure_log)"
}

record_case_failure() {
  printf 'case=%s %s\n' "$1" "$2" >> "$(case_failure_log)"
}

expect_case() {
  local label=$1 want_status=$2 fragment=${3:-}
  [ "$status" -eq "$want_status" ] \
    || record_case_failure "$label" "status=$status want=$want_status output=$output"
  [[ "$output" == *"$fragment"* ]] \
    || record_case_failure "$label" "missing fragment=[$fragment] output=$output"
}

expect_case_exact() {
  local label=$1 want_status=$2 expected=$3
  [ "$status" -eq "$want_status" ] \
    || record_case_failure "$label" "status=$status want=$want_status output=$output"
  [ "$output" = "$expected" ] \
    || record_case_failure "$label" "output=[$output] want=[$expected]"
}

expect_case_silent() {
  local label=$1 want_status=$2
  [ "$status" -eq "$want_status" ] \
    || record_case_failure "$label" "status=$status want=$want_status output=$output"
  [ -z "$output" ] \
    || record_case_failure "$label" "expected empty output, got=$output"
}

expect_case_absent() {
  local label=$1 fragment=$2
  [[ "$output" != *"$fragment"* ]] \
    || record_case_failure "$label" "unexpected fragment=[$fragment] output=$output"
}

assert_no_case_failures() {
  [ ! -s "$(case_failure_log)" ] || { cat "$(case_failure_log)" >&2; return 1; }
}
