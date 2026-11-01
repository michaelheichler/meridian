#!/usr/bin/env bats

load test_helper
load gate_case_helper

setup() {
  setup_temp_dir
  mkdir -p "$TEST_TEMP_DIR/map-steps/.lbwc-planning"
  MAP_PROJECT=$(cd -P "$TEST_TEMP_DIR/map-steps" && pwd -P)
  git -C "$MAP_PROJECT" init -q
  reset_case_failures
}

teardown() {
  teardown_temp_dir
}

generate_map_scout_workflow() {
  local domain="$1" project control_root contract task_id agen_out name wgen_out
  project="$TEST_TEMP_DIR/project-$domain"
  mkdir -p "$project/.lbwc-planning"
  control_root="$project/.temporary-agent-runfiles/runs/map-$domain"
  mkdir -p "$control_root"
  jq -n '{workflow_execution:{enabled:true}}' > "$control_root/config.json"
  jq -n '{workflow:{available:true, unavailable_reasons:[]}}' > "$control_root/claude-capabilities.json"
  contract=$(bash "$SCRIPTS_DIR/task-contract.sh" issue "$project" "map-$domain" \
    --command map --role scout --team solo --job "map $domain for the fixture project" \
    --group fixed \
    --control-root "$control_root" --requested-backend workflow --resolved-backend workflow \
    --read-only-role scout) || return 1
  task_id=$(basename "$contract" .json)
  agen_out=$(bash "$SCRIPTS_DIR/agent-generator.sh" scout \
    --job "map $domain for the fixture project" --contract "$contract" --task-id "$task_id" \
    --control-root "$control_root" --execution-backend workflow 2>&1) || { printf '%s\n' "$agen_out" >&2; return 1; }
  name=$(grep '^SPAWN_READY' <<< "$agen_out" | awk '{print $2}')
  [ -n "$name" ] || return 1
  wgen_out=$(bash "$SCRIPTS_DIR/workflow-generator.sh" solo scout \
    --job "map $domain for the fixture project" --contract "$contract" --task-id "$task_id" \
    --control-root "$control_root" --name "$name" 2>&1) || { printf '%s\n' "$wgen_out" >&2; return 1; }
  printf '%s\n' "$wgen_out"
}

map_step_block() {
  local block
  block=$(awk -v heading="$1" 'index($0, heading) == 1 { found = 1; next }
    found && /^```bash$/ { inside = 1; next }
    inside && /^```$/ { exit }
    inside { print }' "$PROJECT_ROOT/commands/map.md")
  printf '%s\n' "${block//\{plugin-root\}/$PROJECT_ROOT}"
}

map_step_row() {
  local label="$1" heading="$2" want_status="$3" fragment="$4" block
  shift 4
  block=$(map_step_block "$heading")
  [ -n "$block" ] || record_case_failure "$label" "commands/map.md has no bash block under [$heading]"
  run env "$@" bash -c "cd \"$MAP_PROJECT\" && $block"
  expect_case "$label" "$want_status" "$fragment"
}

prefer_teams_never() {
  bash "$SCRIPTS_DIR/lbwc-config.sh" init "$MAP_PROJECT/.lbwc-planning" >/dev/null
  bash "$SCRIPTS_DIR/lbwc-config.sh" set "$MAP_PROJECT/.lbwc-planning" prefer_teams '"never"' >/dev/null
}

workflow_scout_row() {
  local label="$1"
  run generate_map_scout_workflow "tech-and-architecture"
  expect_case "$label" 0 "WORKFLOW_READY"
  [[ "$output" == *'scriptPath'* ]] || [[ "$output" == *'path:'* ]] \
    || record_case_failure "$label" "workflow output names no script path output=$output"
}

@test "map command steps run the shared tier helper and its read-only workflow Scout contract issues, generates, and registers end to end" {
  workflow_scout_row read-only-workflow-scout

  map_step_row step-1-forced-incremental '### Step 1. ' 0 "mode=incremental" FORCED_MODE=incremental
  map_step_row step-1-unmapped-project-is-full '### Step 1. ' 0 "mode=full" FORCED_MODE=
  map_step_row step-1-5-large-count-selects-quad '### Step 1.5. ' 0 "tier=quad" SOURCE_FILE_COUNT=1500 FORCED_TIER=
  map_step_row step-1-5-forced-tier-wins '### Step 1.5. ' 0 "tier=duo" SOURCE_FILE_COUNT=50 FORCED_TIER=duo
  map_step_row step-1-5-rejects-a-non-numeric-count '### Step 1.5. ' 1 "file count is not a whole number" SOURCE_FILE_COUNT=many FORCED_TIER=
  prefer_teams_never
  map_step_row step-1-5-prefer-teams-never-forces-solo-over-tier '### Step 1.5. ' 0 "tier=solo" SOURCE_FILE_COUNT=1500 FORCED_TIER=quad

  assert_no_case_failures
}
