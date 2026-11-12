#!/usr/bin/env bats

load gate_case_helper
load gate_case_files

setup() {
  ROOT=$(mktemp -d)
  mkdir -p "$ROOT/.meridian"
  printf '%s\n' '{}' > "$ROOT/.meridian/config.json"
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/lib/workflow-manifest.sh"
  PLANNING_DIR="$ROOT/.meridian"
  MANIFEST="$PLANNING_DIR/.workflow-manifest.json"
  SCRIPT_DIGEST=$(printf 'a%.0s' $(seq 1 64))
  ARGS_DIGEST=$(printf 'b%.0s' $(seq 1 64))
  reset_case_failures
}

teardown() {
  rm -rf "$ROOT"
}

manifest_call() {
  run bash -c '. "$1"; shift; "$@"' _ "$SCRIPT" "$@"
}

fresh_manifest() {
  rm -f "$MANIFEST"
  rm -rf "$PLANNING_DIR/.workflow-manifest.lock"
}

register_wf1() {
  manifest_call workflow_manifest_register "$PLANNING_DIR" wf-1 "$ROOT/workflows/${2:-wf-1}.js" "$SCRIPT_DIGEST" "$ARGS_DIGEST" "${3:-[]}"
  expect_status "$1" "${4:-0}"
}

claim_wf1() {
  manifest_call workflow_manifest_claim "$PLANNING_DIR" wf-1 "${2:-$SCRIPT_DIGEST}" "$ARGS_DIGEST"
  expect_status "$1" "${3:-0}"
}

entry_field() {
  jq -r ".workflows[\"wf-1\"].$1" "$MANIFEST"
}

expect_entry() {
  local got
  got=$(entry_field "$2")
  [ "$got" = "$3" ] || record_case_failure "$1" "$2=[$got] want=[$3]"
}

expect_entry_set() {
  local got
  got=$(entry_field "$2")
  [ "$got" != null ] || record_case_failure "$1" "$2 is null"
}

@test "workflow_manifest_register writes a registered entry and rejects a duplicate id or a non-array roster" {
  register_wf1 first-register wf-1 '["meridian-engineer-a","meridian-critic-b"]'
  expect_entry registered-state state registered
  expect_entry registered-script-path script_path "$ROOT/workflows/wf-1.js"
  expect_entry registered-script-digest script_digest "$SCRIPT_DIGEST"
  expect_entry registered-args-digest args_digest "$ARGS_DIGEST"
  [ "$(jq -c '.workflows["wf-1"].roster' "$MANIFEST")" = '["meridian-engineer-a","meridian-critic-b"]' ] \
    || record_case_failure registered-roster "roster=$(jq -c '.workflows["wf-1"].roster' "$MANIFEST")"
  expect_entry_set registered-created-at created_at

  fresh_manifest
  register_wf1 duplicate-first
  register_wf1 duplicate-second other '[]' 3
  expect_entry duplicate-keeps-original-path script_path "$ROOT/workflows/wf-1.js"

  fresh_manifest
  register_wf1 non-array-roster wf-1 '"not-an-array"' 1
  expect_no_path non-array-roster-writes-nothing "$MANIFEST"

  assert_no_case_failures
}

@test "workflow_manifest_claim runs a registered contract once on matching digests and rejects every other claim" {
  local tampered
  tampered=$(printf 'c%.0s' $(seq 1 64))

  register_wf1 claim-register
  claim_wf1 matching-digests
  expect_entry matching-digests-running state running
  expect_entry_set matching-digests-started-at started_at

  run bash -c '. "$1"; workflow_manifest_claim "$2" wf-1 "$3" "$4"; ec=$?; printf "state=%s\n" "$WORKFLOW_MANIFEST_CLAIM_STATE"; exit "$ec"' \
    _ "$SCRIPT" "$PLANNING_DIR" "$SCRIPT_DIGEST" "$ARGS_DIGEST"
  expect_case reclaim-running 3 "state=running"

  fresh_manifest
  register_wf1 tampered-register
  claim_wf1 tampered-script-digest "$tampered" 20
  expect_entry tampered-stays-registered state registered

  fresh_manifest
  manifest_call workflow_manifest_claim "$PLANNING_DIR" wf-missing "$SCRIPT_DIGEST" "$ARGS_DIGEST"
  expect_status absent-contract 10

  assert_no_case_failures
}

@test "workflow_manifest_complete and workflow_manifest_expire move a contract to its terminal state" {
  register_wf1 complete-register
  claim_wf1 complete-claim
  manifest_call workflow_manifest_complete "$PLANNING_DIR" wf-1
  expect_status complete-running 0
  expect_entry complete-used state used
  expect_entry_set complete-completed-at completed_at

  fresh_manifest
  register_wf1 expire-register
  manifest_call workflow_manifest_expire "$PLANNING_DIR" wf-1
  expect_status expire-registered 0
  expect_entry expire-expired state expired

  assert_no_case_failures
}

@test "the manifest lock serializes a live writer until timeout and reclaims a stale lock from a dead writer" {
  local lock_dir="$PLANNING_DIR/.workflow-manifest.lock" writer_pid
  sleep 30 &
  writer_pid=$!
  mkdir -p "$lock_dir"
  printf '%s\n' "$writer_pid" > "$lock_dir/pid"
  touch -t 200001010000 "$lock_dir"
  run env MERIDIAN_WORKFLOW_MANIFEST_LOCK_TIMEOUT=1 MERIDIAN_WORKFLOW_MANIFEST_LOCK_STALE_SECONDS=0 \
    bash -c '. "$1"; workflow_manifest_register "$2" wf-1 "$3" "$4" "$5" "[]"' \
    _ "$SCRIPT" "$PLANNING_DIR" "$ROOT/workflows/wf-1.js" "$SCRIPT_DIGEST" "$ARGS_DIGEST"
  kill "$writer_pid" 2>/dev/null || true
  wait "$writer_pid" 2>/dev/null || true
  expect_status live-writer-times-out 1
  expect_path live-writer-keeps-lock "$lock_dir"
  expect_no_path live-writer-blocks-write "$MANIFEST"

  fresh_manifest
  mkdir -p "$lock_dir"
  printf '%s\n' '999999' > "$lock_dir/pid"
  touch -t 200001010000 "$lock_dir"
  run env MERIDIAN_WORKFLOW_MANIFEST_LOCK_STALE_SECONDS=0 \
    bash -c '. "$1"; workflow_manifest_register "$2" wf-1 "$3" "$4" "$5" "[]"' \
    _ "$SCRIPT" "$PLANNING_DIR" "$ROOT/workflows/wf-1.js" "$SCRIPT_DIGEST" "$ARGS_DIGEST"
  expect_status dead-writer-reclaimed 0
  expect_no_path dead-writer-lock-released "$lock_dir"
  expect_entry dead-writer-registered state registered

  assert_no_case_failures
}
