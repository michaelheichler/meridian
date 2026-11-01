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
  if grep -q -- "$pattern" "$file" 2>/dev/null; then
    record_case_failure "$label" "file=$file has pattern=[$pattern]"
  fi
}

expect_path() {
  [ -e "$2" ] || record_case_failure "$1" "missing path=$2"
}

expect_no_path() {
  [ ! -e "$2" ] || record_case_failure "$1" "unexpected path=$2"
}

expect_jq() {
  local label=$1 file=$2 filter=$3
  jq -e "$filter" "$file" >/dev/null 2>&1 \
    || record_case_failure "$label" "jq filter failed=[$filter] file=$file content=$(cat "$file" 2>&1)"
}

expect_jq_output() {
  local label=$1 filter=$2
  printf '%s\n' "$output" | jq -e "$filter" >/dev/null 2>&1 \
    || record_case_failure "$label" "jq filter failed=[$filter] output=$output"
}

expect_same_digest() {
  local label=$1 file=$2 want=$3 got
  got=$(shasum -a 256 "$file" 2>/dev/null | awk '{print $1}')
  [ "$got" = "$want" ] || record_case_failure "$label" "digest of $file is $got want $want"
}

expect_status() {
  local label=$1 want=$2
  [ "$status" -eq "$want" ] \
    || record_case_failure "$label" "status=$status want=$want output=$output"
}
