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

@test "gate rejects malformed or unresolved block records with exit 2" {
  local count
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

  assert_no_case_failures
}

@test "gate accepts a resolved block or an absent ledger with exit 0" {
  local id
  reset_case_failures

  fresh_deviq
  id=$(open_block "stale cache")
  record_block p1 roleA --field id="$id" --field trigger="stale cache" --field consequence=c --field fix=f --field status=resolved > /dev/null
  run bash "$GATE" p1 --root "$DEVIQ"
  expect_case_silent resolved-block 0

  fresh_deviq
  run bash "$GATE" p1 --root "$DEVIQ"
  expect_case_silent absent-ledger 0

  assert_no_case_failures
}

@test "gate rejects a call without a phase with exit 1 and a usage line" {
  run bash "$GATE" --root "$DEVIQ"

  [ "$status" -eq 1 ]
  [[ "$output" == *"usage: deviq-build-gate.sh"* ]]
}

@test "a 9th distinct open block is refused by the recorder before it ever reaches the gate" {
  local i count
  for i in 1 2 3 4 5 6 7 8; do
    open_block "issue-$i" > /dev/null
  done

  run open_block "issue-9"
  [ "$status" -eq 1 ]

  run bash "$GATE" p1 --root "$DEVIQ"
  [ "$status" -eq 2 ]
  [[ "$output" != *"issue-9"* ]]
  count=$(grep -oc 'issue-[0-9]' <<< "$output")
  [ "$count" -eq 8 ]
}
