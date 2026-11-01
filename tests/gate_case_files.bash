#!/bin/bash
set -u

expect_output_has() {
  local label=$1 fragment=$2
  [[ "$output" == *"$fragment"* ]] \
    || record_case_failure "$label" "missing fragment=[$fragment] output=$output"
}

expect_output_lacks() {
  local label=$1 fragment=$2
  [[ "$output" != *"$fragment"* ]] \
    || record_case_failure "$label" "unexpected fragment=[$fragment] output=$output"
}

expect_file_line() {
  local label=$1 file=$2 pattern=$3
  grep -q -- "$pattern" "$file" 2>/dev/null \
    || record_case_failure "$label" "file=$file lacks pattern=[$pattern] content=$(cat "$file" 2>&1)"
}

expect_no_file_line() {
  local label=$1 file=$2 pattern=$3
  ! grep -q -- "$pattern" "$file" 2>/dev/null \
    || record_case_failure "$label" "file=$file has pattern=[$pattern]"
}

expect_path() {
  [ -e "$2" ] || record_case_failure "$1" "missing path=$2"
}

expect_no_path() {
  [ ! -e "$2" ] || record_case_failure "$1" "unexpected path=$2"
}

expect_status() {
  local label=$1 want=$2
  [ "$status" -eq "$want" ] \
    || record_case_failure "$label" "status=$status want=$want output=$output"
}
