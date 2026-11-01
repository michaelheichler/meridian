#!/usr/bin/env bats

load test_helper
load gate_case_helper
load rejection_case_helper

RECORDER="$SCRIPTS_DIR/lib/deviq-record.py"
GATE="$SCRIPTS_DIR/deviq-build-gate.sh"

setup() {
  setup_temp_dir
  cd "$TEST_TEMP_DIR"
  DEVIQ="$TEST_TEMP_DIR/deviq"
}

teardown() {
  cd "$PROJECT_ROOT"
  teardown_temp_dir
}

record_block() {
  local phase="$1" role="$2"
  shift 2
  python3 "$RECORDER" block --phase "$phase" --role "$role" --root "$DEVIQ" "$@"
}

fresh_deviq() {
  rm -rf "$DEVIQ"
  mkdir -p "$DEVIQ"
}

open_block() {
  record_block p1 roleA --field trigger="$1" --field consequence=c --field fix=f --field status=open
}

@test "gate exits 2 on malformed or open blocks, 0 on resolved or absent ledgers, 1 without a phase, and never sees a 9th block" {
  local count id i
  reset_case_failures

  fresh_deviq
  printf 'not json\n' > "$DEVIQ/blocks.jsonl"
  run bash "$GATE" p1 --root "$DEVIQ"
  expect_case malformed-first-line 2 "malformed at line 1"

  fresh_deviq
  open_block one > /dev/null
  printf 'not json\n' >> "$DEVIQ/blocks.jsonl"
  run bash "$GATE" p1 --root "$DEVIQ"
  expect_case malformed-second-line 2 "malformed at line 2"
  [[ "$output" != *"malformed at line 1"* ]] \
    || record_case_failure malformed-second-line "named line 1 as well output=$output"

  fresh_deviq
  open_block "flaky test" > /dev/null
  open_block "flaky test" > /dev/null
  run bash "$GATE" p1 --root "$DEVIQ"
  expect_case duplicate-open-appends 2 "flaky test"
  count=$(grep -c 'flaky test' <<< "$output")
  [ "$count" -eq 1 ] || record_case_failure duplicate-open-appends "blocking entry count=$count"

  fresh_deviq
  id=$(open_block "stale cache")
  record_block p1 roleA --field id="$id" --field trigger="stale cache" --field consequence=c --field fix=f --field status=resolved > /dev/null
  run bash "$GATE" p1 --root "$DEVIQ"
  expect_case_silent resolved-block 0

  fresh_deviq
  run bash "$GATE" p1 --root "$DEVIQ"
  expect_case_silent absent-ledger 0

  run bash "$GATE" --root "$DEVIQ"
  expect_case missing-phase 1 "usage: deviq-build-gate.sh"

  fresh_deviq
  for i in 1 2 3 4 5 6 7 8; do
    open_block "issue-$i" > /dev/null
  done
  run open_block "issue-9"
  expect_case ninth-open-block-refused 1
  run bash "$GATE" p1 --root "$DEVIQ"
  expect_case eight-open-blocks-gate 2
  [[ "$output" != *"issue-9"* ]] || record_case_failure eight-open-blocks-gate "refused block reached the gate output=$output"
  count=$(grep -oc 'issue-[0-9]' <<< "$output")
  [ "$count" -eq 8 ] || record_case_failure eight-open-blocks-gate "blocking entry count=$count"

  assert_no_case_failures
}
