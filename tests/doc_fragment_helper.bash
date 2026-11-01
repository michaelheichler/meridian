#!/bin/bash
set -u

expect_doc_has() {
  local label="$1" file="$2" fragment="$3"
  grep -qF -- "$fragment" "$file" \
    || record_case_failure "$label" "$file does not contain [$fragment]"
}

expect_doc_lacks() {
  local label="$1" file="$2" fragment="$3"
  if grep -qF -- "$fragment" "$file"; then
    record_case_failure "$label" "$file still contains [$fragment]"
  fi
}
