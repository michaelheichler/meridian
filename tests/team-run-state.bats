#!/usr/bin/env bats

load test_helper

setup() {
  setup_temp_dir
  ROOT="$TEST_TEMP_DIR/project"
  mkdir -p "$ROOT"
  SCRIPT="$SCRIPTS_DIR/team-run-state.sh"
  CLEANUP="$SCRIPTS_DIR/cleanup-temporary-agent-runfiles.sh"
}

teardown() {
  teardown_temp_dir
}

@test "team run state resolves scope arguments to canonical repository-relative scopes" {
  local label scope_args expected
  local -a scope_array
  mkdir -p "$ROOT/src/web" "$ROOT/tests/web"
  while IFS='|' read -r label scope_args expected; do
    [ -n "$label" ] || continue
    scope_array=()
    [ -z "$scope_args" ] || read -r -a scope_array <<< "$scope_args"
    run bash "$SCRIPT" resolve-scopes --project-root "$ROOT" ${scope_array[@]+"${scope_array[@]}"}
    [ "$status" -eq 0 ] || { echo "case=$label status=$status output=$output" >&2; return 1; }
    [ "$(jq -c '.scopes' <<< "$output")" = "$expected" ] \
      || { echo "case=$label expected=$expected output=$output" >&2; return 1; }
  done <<CASES
default-is-repository-root||["."]
repeatable-relative-scopes|--scope src/web --scope tests/web|["src/web","tests/web"]
absolute-scope-becomes-relative|--scope $ROOT/tests/web|["tests/web"]
CASES
}

@test "team run state creates diagnosis files without active planning state" {
  run bash "$SCRIPT" create --project-root "$ROOT" --run-id run-one

  [ "$status" -eq 0 ]
  [ -f "$ROOT/.temporary-agent-runfiles/runs/run-one/run.json" ]
  [ -d "$ROOT/.temporary-agent-runfiles/runs/run-one/contracts" ]
  [ -d "$ROOT/.temporary-agent-runfiles/runs/run-one/generated-agents" ]
  jq -e '.status == "planned" and .scopes == ["."]' \
    "$ROOT/.temporary-agent-runfiles/runs/run-one/run.json" >/dev/null
  [ ! -e "$ROOT/.lbwc-planning/config.json" ]
}

@test "team run state rejects a scope that leaves the repository" {
  outside="$TEST_TEMP_DIR/outside"
  mkdir -p "$outside"

  run bash "$SCRIPT" resolve-scopes --project-root "$ROOT" --scope "$outside"

  [ "$status" -ne 0 ]
  [[ "$output" == *"scope must remain inside the project root"* ]]
}

@test "team run state records terminal status and prints a summary" {
  run_root="$ROOT/.temporary-agent-runfiles/runs/run-summary"
  run bash "$SCRIPT" create --project-root "$ROOT" --run-id run-summary
  [ "$status" -eq 0 ]

  run bash "$SCRIPT" record --run-root "$run_root" --kind task \
    --id task-1 --status running
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" update --run-root "$run_root" --status completed \
    --event "native team completed"
  [ "$status" -eq 0 ]

  run bash "$SCRIPT" summary --run-root "$run_root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status: completed"* ]]
  [[ "$output" == *"task-1"* ]]
}

@test "temporary cleanup removes only readable old terminal runs" {
  runs="$ROOT/.temporary-agent-runfiles/runs"
  mkdir -p "$runs/old-completed" "$runs/old-running" "$runs/old-unreadable"
  printf '%s\n' '{"status":"completed","updated_at":"2000-01-01T00:00:00Z"}' \
    > "$runs/old-completed/run.json"
  printf '%s\n' '{"status":"running","updated_at":"2000-01-01T00:00:00Z"}' \
    > "$runs/old-running/run.json"
  printf '%s\n' '{not-json' > "$runs/old-unreadable/run.json"

  run bash "$CLEANUP" cleanup --project-root "$ROOT"

  [ "$status" -eq 0 ]
  [ ! -e "$runs/old-completed" ]
  [ -d "$runs/old-running" ]
  [ -d "$runs/old-unreadable" ]
  [[ "$output" == *"old-completed"* ]]
}

@test "temporary cleanup scan exposes preserved active and unreadable runs" {
  runs="$ROOT/.temporary-agent-runfiles/runs"
  mkdir -p "$runs/active" "$runs/unreadable"
  printf '%s\n' '{"status":"awaiting-review"}' > "$runs/active/run.json"
  printf '%s\n' '{not-json' > "$runs/unreadable/run.json"

  run bash "$CLEANUP" scan --project-root "$ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"temporary_run_active|active"* ]]
  [[ "$output" == *"temporary_run_unreadable|unreadable"* ]]
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
