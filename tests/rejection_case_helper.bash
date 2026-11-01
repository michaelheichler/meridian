#!/bin/bash
set -u

expect_rejected() {
  local label="$1" fragment="${2:-}"
  [ "$status" -ne 0 ] \
    || record_case_failure "$label" "expected a failing status, got 0 output=$output"
  [[ "$output" == *"$fragment"* ]] \
    || record_case_failure "$label" "missing fragment=[$fragment] output=$output"
}

expect_fragment() {
  local label="$1" fragment="$2"
  [[ "$output" == *"$fragment"* ]] \
    || record_case_failure "$label" "missing fragment=[$fragment] output=$output"
}

expect_digest() {
  local label="$1" want="$2" got="$3"
  [ "$want" = "$got" ] || record_case_failure "$label" "digest changed from $want to $got"
}
