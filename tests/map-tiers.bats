#!/usr/bin/env bats

load test_helper
load gate_case_helper
load gate_case_files

setup() {
  setup_temp_dir
  reset_case_failures
  LIB="$SCRIPTS_DIR/lib/map-tiers.sh"
}

teardown() {
  teardown_temp_dir
}

run_tier() {
  run bash -c '. "$1"; shift; resolve_map_tier "$@"' _ "$LIB" "$@"
}

run_mode() {
  local repo=$1
  shift
  run bash -c 'cd "$1" && . "$2" && shift 2 && resolve_map_mode "$@"' _ "$repo" "$LIB" "$@"
}

expect_exact_output() {
  local label=$1 want=$2
  [ "$output" = "$want" ] || record_case_failure "$label" "output=[$output] want=[$want]"
}

make_repo() {
  local repo="$TEST_TEMP_DIR/$1" step
  mkdir -p "$repo/.meridian/codebase"
  git -C "$repo" init -q
  git -C "$repo" config user.name "MERIDIAN Test"
  git -C "$repo" config user.email "meridian-tests@example.com"
  for step in 1 2 3; do
    printf 'v%s\n' "$step" > "$repo/file-$step.txt"
    git -C "$repo" add -A
    git -C "$repo" commit -qm "step $step"
  done
  FIRST_HASH=$(git -C "$repo" rev-list --max-parents=0 HEAD)
  HEAD_HASH=$(git -C "$repo" rev-parse HEAD)
}

write_meta() {
  printf '%s\n' 'mapped_at: 2026-08-01T00:00:00Z' "git_hash: $2" "file_count: $3" > "$1/.meridian/codebase/META.md"
}

@test "resolve_map_tier picks a tier from file count, preference and forced tier" {
  local label count prefer forced want
  while IFS='|' read -r label count prefer forced want; do
    [ -n "$label" ] || continue
    run_tier "$count" "$prefer" "$forced"
    expect_case "$label" 0 ""
    expect_exact_output "$label" "tier=$want"
  done <<'CASES'
well-under-200|50|auto||solo
just-under-200|199|auto||solo
exactly-200|200|auto||duo
mid-range|500|auto||duo
exactly-1000|1000|auto||duo
just-over-1000|1001|auto||quad
large|5000|auto||quad
never-forces-solo|5000|never||solo
never-beats-forced-tier|5000|never|quad|solo
forced-tier-beats-count|50|auto|quad|quad
forced-solo-on-large|5000|auto|solo|solo
forced-duo|50|auto|duo|duo
CASES

  assert_no_case_failures
}

@test "resolve_map_tier rejects unknown forced tiers and file counts that are not whole numbers" {
  local label count prefer forced message
  while IFS='|' read -r label count prefer forced message; do
    [ -n "$label" ] || continue
    run_tier "$count" "$prefer" "$forced"
    expect_case "$label" 1 "$message"
  done <<'CASES'
unknown-forced-tier|50|auto|octet|map-tiers: unknown tier: octet
unknown-forced-tier-with-never|5000|never|octet|map-tiers: unknown tier: octet
empty-count||auto||map-tiers: file count is not a whole number:
letter-count|abc|auto||map-tiers: file count is not a whole number: abc
trailing-letter-count|12x|auto||map-tiers: file count is not a whole number: 12x
letter-count-before-never|abc|never||map-tiers: file count is not a whole number: abc
CASES

  assert_no_case_failures
}

@test "resolve_map_mode chooses full or incremental from META and the git delta" {
  local label repo

  make_repo forced
  run_mode "$TEST_TEMP_DIR/forced" "$TEST_TEMP_DIR/forced/.meridian" incremental
  expect_case "forced-incremental-without-meta" 0 ""
  expect_exact_output "forced-incremental-without-meta" $'mode=incremental\nchanged_files=0'

  run_mode "$TEST_TEMP_DIR/forced" "$TEST_TEMP_DIR/forced/.meridian" full
  expect_exact_output "forced-full" $'mode=full\nchanged_files=0'

  make_repo no-meta
  run_mode "$TEST_TEMP_DIR/no-meta" "$TEST_TEMP_DIR/no-meta/.meridian"
  expect_exact_output "missing-meta-is-full" $'mode=full\nchanged_files=0'

  repo="$TEST_TEMP_DIR/no-git"
  mkdir -p "$repo/.meridian/codebase"
  write_meta "$repo" "0123456789abcdef0123456789abcdef01234567" 10
  run_mode "$repo" "$repo/.meridian"
  expect_exact_output "outside-git-is-full" $'mode=full\nchanged_files=0'

  while IFS='|' read -r label hash_kind count want_mode want_changed; do
    [ -n "$label" ] || continue
    make_repo "$label"
    repo="$TEST_TEMP_DIR/$label"
    case "$hash_kind" in
      first) write_meta "$repo" "$FIRST_HASH" "$count" ;;
      head) write_meta "$repo" "$HEAD_HASH" "$count" ;;
      unknown) write_meta "$repo" "0000000000000000000000000000000000000000" "$count" ;;
      no-git) write_meta "$repo" "no-git" "$count" ;;
    esac
    run_mode "$repo" "$repo/.meridian"
    expect_case "$label" 0 ""
    expect_exact_output "$label" "mode=$want_mode"$'\n'"changed_files=$want_changed"
  done <<'CASES'
head-with-huge-file-count|head|1000000|incremental|0
changes-under-twenty-percent|first|11|incremental|2
changes-at-twenty-percent|first|10|full|2
unknown-hash|unknown|10|full|0
no-git-marker|no-git|10|full|0
zero-file-count|first|0|full|0
text-file-count|first|many|full|0
CASES

  assert_no_case_failures
}
