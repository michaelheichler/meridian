#!/usr/bin/env bats

load test_helper
load gate_case_helper
load rejection_case_helper

lookup() {
  run env CLAUDE_PLUGIN_ROOT="$PROJECT_ROOT" bash "$SCRIPTS_DIR/deviq-lookup.sh" "$@"
}

expect_exact() {
  local label="$1" want="$2"
  [ "$output" = "$want" ] || record_case_failure "$label" "want exact=[$want] output=$output"
}

expect_absent() {
  local label="$1" fragment="$2"
  [[ "$output" != *"$fragment"* ]] || record_case_failure "$label" "unexpected fragment=[$fragment] output=$output"
}

@test "lookup finds articles by index, body, category and id, caps results at 8, and answers misses with exit 0" {
  reset_case_failures

  lookup blob
  expect_case index-search 0 "antipatterns/blob | The Blob |"

  lookup --grep "God Object"
  expect_case body-grep-maps-to-index 0 "antipatterns/blob | The Blob |"

  lookup --category antipatterns blob
  expect_case category-filter-keeps-match 0 "antipatterns/blob"
  expect_absent category-filter-keeps-match "design-patterns/"

  lookup --show antipatterns/blob
  expect_case show-prints-vendored-body 0 "title: The Blob"

  lookup the
  expect_case results-capped 0
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 8 ] \
    || record_case_failure results-capped "expected 8 lines output=$output"

  lookup --category design-patterns blob
  expect_case category-excludes-other-categories 0
  expect_exact category-excludes-other-categories "no match"

  lookup zzzzzznotarealtermxyz
  expect_case query-without-hits 0
  expect_exact query-without-hits "no match"

  lookup --show nope/nope
  expect_case show-missing-id 0 "no article found for id: nope/nope"

  lookup --bogus-flag "; rm -rf /" "$(printf '\xff\xfe')"
  expect_case garbage-arguments 0

  assert_no_case_failures
}

@test "vendored corpus matches MANIFEST.json sha256 hashes" {
  local manifest="$PROJECT_ROOT/references/deviq-corpus/MANIFEST.json"
  local corpus_dir="$PROJECT_ROOT/references/deviq-corpus"

  [ -f "$manifest" ]

  run bash -c "
    jq -r '.files[] | \"\(.[0])\t\(.[1])\"' '$manifest' | while IFS=\$'\t' read -r relpath expected; do
      actual=\$(shasum -a 256 \"$corpus_dir/\$relpath\" | awk '{print \$1}')
      [ \"\$actual\" = \"\$expected\" ] || { echo \"mismatch: \$relpath\"; exit 1; }
    done
  "

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
