#!/usr/bin/env bats

load test_helper
load gate_case_helper
load gate_case_files
load rejection_case_helper

setup() {
  setup_temp_dir
  ROOT="$TEST_TEMP_DIR/project"
  mkdir -p "$ROOT"
  SCRIPT="$SCRIPTS_DIR/team-run-state.sh"
  CLEANUP="$SCRIPTS_DIR/cleanup-temporary-agent-runfiles.sh"
  reset_case_failures
}

teardown() {
  teardown_temp_dir
}

expect_scopes() {
  local label=$1 want=$2
  shift 2
  run bash "$SCRIPT" resolve-scopes --project-root "$ROOT" "$@"
  expect_status "$label" 0
  [ "$(jq -c '.scopes' <<< "$output")" = "$want" ] || record_case_failure "$label" "want=$want output=$output"
}

@test "team run state resolves scope arguments to canonical repository-relative scopes and rejects an escaping scope" {
  mkdir -p "$ROOT/src/web" "$ROOT/tests/web" "$TEST_TEMP_DIR/outside"

  expect_scopes default-is-repository-root '["."]'
  expect_scopes repeatable-relative-scopes '["src/web","tests/web"]' --scope src/web --scope tests/web
  expect_scopes absolute-scope-becomes-relative '["tests/web"]' --scope "$ROOT/tests/web"

  run bash "$SCRIPT" resolve-scopes --project-root "$ROOT" --scope "$TEST_TEMP_DIR/outside"
  expect_rejected scope-outside-project "scope must remain inside the project root"

  assert_no_case_failures
}

@test "team run state creates diagnosis files without planning state, records terminal status and prints a summary" {
  local run_one="$ROOT/.temporary-agent-runfiles/runs/run-one" run_root="$ROOT/.temporary-agent-runfiles/runs/run-summary"

  run bash "$SCRIPT" create --project-root "$ROOT" --run-id run-one
  expect_status create 0
  expect_path create-run-json "$run_one/run.json"
  [ -d "$run_one/contracts" ] || record_case_failure create-contracts-dir "contracts directory missing"
  [ -d "$run_one/generated-agents" ] || record_case_failure create-agents-dir "generated-agents directory missing"
  expect_jq create-planned-root-scope "$run_one/run.json" '.status == "planned" and .scopes == ["."]'
  expect_no_path create-no-planning-config "$ROOT/.lbwc-planning/config.json"

  run bash "$SCRIPT" create --project-root "$ROOT" --run-id run-summary
  expect_status summary-create 0
  run bash "$SCRIPT" record --run-root "$run_root" --kind task --id task-1 --status running
  expect_status record-task 0
  run bash "$SCRIPT" update --run-root "$run_root" --status completed --event "native team completed"
  expect_status update-completed 0
  run bash "$SCRIPT" summary --run-root "$run_root"
  expect_case summary-status 0 "status: completed"
  expect_output_has summary-task "task-1"

  assert_no_case_failures
}

@test "temporary cleanup removes only readable old terminal runs and its scan exposes preserved runs" {
  local runs="$ROOT/.temporary-agent-runfiles/runs"
  mkdir -p "$runs/old-completed" "$runs/old-running" "$runs/old-unreadable"
  printf '%s\n' '{"status":"completed","updated_at":"2000-01-01T00:00:00Z"}' > "$runs/old-completed/run.json"
  printf '%s\n' '{"status":"running","updated_at":"2000-01-01T00:00:00Z"}' > "$runs/old-running/run.json"
  printf '%s\n' '{not-json' > "$runs/old-unreadable/run.json"

  run bash "$CLEANUP" cleanup --project-root "$ROOT"
  expect_case cleanup 0 "old-completed"
  expect_no_path cleanup-removes-old-terminal "$runs/old-completed"
  [ -d "$runs/old-running" ] || record_case_failure cleanup-keeps-running "old-running removed"
  [ -d "$runs/old-unreadable" ] || record_case_failure cleanup-keeps-unreadable "old-unreadable removed"

  rm -rf "$runs"
  mkdir -p "$runs/active" "$runs/unreadable"
  printf '%s\n' '{"status":"awaiting-review"}' > "$runs/active/run.json"
  printf '%s\n' '{not-json' > "$runs/unreadable/run.json"
  run bash "$CLEANUP" scan --project-root "$ROOT"
  expect_case scan-active 0 "temporary_run_active|active"
  expect_output_has scan-unreadable "temporary_run_unreadable|unreadable"

  assert_no_case_failures
}

@test "doctor cleanup scan reports temporary runs through the cleanup helper" {
  local runs="$ROOT/.temporary-agent-runfiles/runs"
  mkdir -p "$runs/active"
  printf '%s\n' '{"status":"awaiting-review"}' > "$runs/active/run.json"
  (cd "$ROOT" && git init -q)

  run bash -c 'cd "$1" && bash "$2" scan' _ "$ROOT" "$SCRIPTS_DIR/doctor-cleanup.sh"

  [ "$status" -eq 0 ]
  [[ "$output" == *"temporary_run_active|active"* ]]
}
