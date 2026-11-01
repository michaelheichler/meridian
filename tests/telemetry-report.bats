#!/usr/bin/env bats

load test_helper
load gate_case_helper
load gate_case_files

setup() {
  setup_temp_dir
  cd "$TEST_TEMP_DIR"
  TELEMETRY="$PROJECT_ROOT/scripts/lib/session-telemetry.py"
  JOURNAL=".lbwc-planning/telemetry/session.jsonl"
  reset_case_failures
}

teardown() {
  cd "$PROJECT_ROOT"
  teardown_temp_dir
}

record_event() {
  python3 "$TELEMETRY" record --event "$1" --outcome "$2" --duration-ms "$3" >/dev/null
}

@test "telemetry-report: reports counts and percentiles, and detects a rewritten value, a deleted record and a malformed line" {
  run bash "$PROJECT_ROOT/scripts/telemetry-report.sh"
  expect_case empty-journal 0 '"total":0'
  expect_output_has empty-journal '"p50_ms":null'
  expect_output_has empty-journal '"p95_ms":null'

  record_event command success 10
  record_event command success 20
  record_event tool_call failure 30
  run bash "$PROJECT_ROOT/scripts/telemetry-report.sh"
  expect_case counts-and-percentiles 0 '"total":3'
  expect_output_has counts-and-percentiles '"p50_ms":20'
  expect_output_has counts-and-percentiles '"p95_ms":30'
  expect_output_has counts-and-percentiles '"events":{"command":2,"tool_call":1}'
  expect_output_has counts-and-percentiles '"outcomes":{"failure":1,"success":2}'

  rm -f "$JOURNAL"
  record_event command success 10
  record_event command success 20
  record_event command failure 30
  cp "$JOURNAL" "$TEST_TEMP_DIR/journal.original"

  sed 's/"duration_ms":10.0/"duration_ms":99.0/' "$TEST_TEMP_DIR/journal.original" > "$JOURNAL"
  run bash "$PROJECT_ROOT/scripts/telemetry-report.sh"
  expect_case rewritten-value 2 "tamper detected"
  expect_output_has rewritten-value "sha256 mismatch"

  sed '2d' "$TEST_TEMP_DIR/journal.original" > "$JOURNAL"
  run bash "$PROJECT_ROOT/scripts/telemetry-report.sh"
  expect_case deleted-record 2 "tamper detected"
  expect_output_has deleted-record "hash chain mismatch"

  printf '%s\n' '{not json' >> "$TEST_TEMP_DIR/journal.original"
  cp "$TEST_TEMP_DIR/journal.original" "$JOURNAL"
  run bash "$PROJECT_ROOT/scripts/telemetry-report.sh"
  expect_case malformed-line 2 "malformed prior record"

  assert_no_case_failures
}
