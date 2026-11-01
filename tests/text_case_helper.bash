#!/bin/bash
set -u

write_text() {
  local path=$1
  shift
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$@" > "$path"
}

file_digest() {
  shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
}

expect_exact_line() {
  local label=$1 file=$2 line=$3
  grep -Fxq -- "$line" "$file" 2>/dev/null \
    || record_case_failure "$label" "file=$file lacks exact line=[$line] content=$(cat "$file" 2>&1)"
}

expect_no_exact_line() {
  local label=$1 file=$2 line=$3
  if grep -Fxq -- "$line" "$file" 2>/dev/null; then
    record_case_failure "$label" "file=$file has exact line=[$line]"
  fi
}

expect_line_count() {
  local label=$1 file=$2 line=$3 want=$4 got
  got=$(grep -Fxc -- "$line" "$file" 2>/dev/null)
  [ "$got" = "$want" ] || record_case_failure "$label" "file=$file has $got copies of [$line] want $want"
}

expect_file_equals() {
  local label=$1 file=$2 want=$3 got
  got=$(cat "$file" 2>&1)
  [ "$got" = "$want" ] || record_case_failure "$label" "file=$file content=[$got] want=[$want]"
}

expect_headings() {
  local label=$1 file=$2 want=$3 got
  got=$(grep '^## ' "$file" 2>&1)
  [ "$got" = "$want" ] || record_case_failure "$label" "file=$file headings=[$got] want=[$want]"
}

expect_output_nonempty() {
  [ -n "$output" ] || record_case_failure "$1" "expected output, got none (status=$status)"
}
