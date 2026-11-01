#!/usr/bin/env bats

load test_helper
load gate_case_helper
load gate_case_files

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/map-staleness.sh"
  TEST_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
  WORK="$TEST_ROOT/work"
  PLANNING_DIR="$TEST_ROOT/.lbwc-planning"
  mkdir -p "$WORK" "$PLANNING_DIR/codebase"
  git -C "$WORK" init -q
  git -C "$WORK" config user.email "test@test.com"
  git -C "$WORK" config user.name "Test"
  printf 'seed\n' > "$WORK/seed.txt"
  git -C "$WORK" add seed.txt
  git -C "$WORK" commit -qm "seed"
  BASE_HASH="$(git -C "$WORK" rev-parse HEAD)"
  cd "$WORK"
  reset_case_failures
}

teardown() {
  cd "$REPO_ROOT"
  await_git_ai
  rm -rf "$TEST_ROOT"
}

write_meta() {
  printf 'mapped_at: 2026-08-01T00:00:00Z\ngit_hash: %s\nfile_count: %s\n' "$1" "$2" > "$PLANNING_DIR/codebase/META.md"
}

commit_new_files() {
  local count=$1 index=1
  while [ "$index" -le "$count" ]; do
    printf '%s\n' "$RANDOM$index" > "$WORK/new-$(git -C "$WORK" rev-list --count HEAD)-$index.txt"
    index=$((index + 1))
  done
  git -C "$WORK" add -A
  git -C "$WORK" commit -qm "add $count"
}

run_map_staleness() {
  run env LBWC_PLANNING_DIR="$PLANNING_DIR" bash "$SCRIPT"
}

@test "map-staleness reports no_map, fresh, stale or no_git and stays silent right after a compaction" {
  local plain

  run_map_staleness
  expect_case missing-meta 0 "status: no_map"

  printf '%s\n' '- mapped_at: 2026-08-01T00:00:00Z' "- git_hash: $BASE_HASH" '- file_count: 1' > "$PLANNING_DIR/codebase/META.md"
  run_map_staleness
  expect_case list-item-meta 0 "status: no_map"

  printf 'mapped_at: 2026-08-01T00:00:00Z\nfile_count: 1\n' > "$PLANNING_DIR/codebase/META.md"
  run_map_staleness
  expect_case missing-hash 0 "status: no_map"

  printf 'git_hash: %s\nfile_count: 1\n' "$BASE_HASH" > "$PLANNING_DIR/codebase/META.md"
  run_map_staleness
  expect_case missing-mapped-at 0 "status: no_map"

  write_meta "$BASE_HASH" 0
  run_map_staleness
  expect_case zero-file-count 0 "status: no_map"

  write_meta "$BASE_HASH" many
  run_map_staleness
  expect_case non-numeric-file-count 0 "status: no_map"

  write_meta "$BASE_HASH" 10
  run_map_staleness
  expect_case head-is-mapped 0 "status: fresh"
  expect_output_has head-is-mapped "staleness: 0%"
  expect_output_has head-is-mapped "changed: 0"
  expect_output_has head-is-mapped "total: 10"
  expect_output_has head-is-mapped "since: 2026-08-01T00:00:00Z"
  expect_output_lacks head-is-mapped "hookSpecificOutput"

  commit_new_files 1
  run_map_staleness
  expect_case one-of-ten-changed 0 "status: fresh"
  expect_output_has one-of-ten-changed "staleness: 10%"

  commit_new_files 2
  run_map_staleness
  expect_case thirty-percent-boundary 0 "status: fresh"
  expect_output_has thirty-percent-boundary "staleness: 30%"
  expect_output_lacks thirty-percent-boundary "hookSpecificOutput"

  commit_new_files 1
  run_map_staleness
  expect_case forty-percent 0 "status: stale"
  expect_output_has forty-percent "staleness: 40%"
  expect_output_has forty-percent "changed: 4"
  expect_output_has forty-percent "Codebase map is stale (40% files changed)"

  write_meta 0000000000000000000000000000000000000000 10
  run_map_staleness
  expect_case unknown-hash 0 "status: stale"
  expect_output_has unknown-hash "staleness: 100%"
  expect_output_has unknown-hash "changed: unknown"
  expect_output_has unknown-hash "Codebase map is stale (100% files changed)"

  write_meta "$BASE_HASH" 10
  plain="$TEST_ROOT/plain"
  mkdir -p "$plain"
  cd "$plain"
  run_map_staleness
  expect_case outside-git 0 "status: no_git"

  cd "$WORK"
  write_meta 0000000000000000000000000000000000000000 10
  date +%s > "$PLANNING_DIR/.compaction-marker"
  run_map_staleness
  expect_case_silent recent-compaction 0

  printf '%s\n' "$(($(date +%s) - 600))" > "$PLANNING_DIR/.compaction-marker"
  run_map_staleness
  expect_case old-compaction 0 "status: stale"

  assert_no_case_failures
}
