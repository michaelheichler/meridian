#!/usr/bin/env bats

load test_helper

generate_init_architect_workflow() {
  local project control_root contract task_id agen_out name wgen_out
  project="$TEST_TEMP_DIR/project-init"
  mkdir -p "$project/.lbwc-planning"
  control_root="$project/.temporary-agent-runfiles/runs/init-architect"
  mkdir -p "$control_root"
  jq -n '{workflow_execution:{enabled:true}}' > "$control_root/config.json"
  jq -n '{workflow:{available:true, unavailable_reasons:[]}}' > "$control_root/claude-capabilities.json"
  contract=$(bash "$SCRIPTS_DIR/task-contract.sh" issue "$project" "init-architect" \
    --command init --role architect --team solo --job "draft initial requirements and roadmap" \
    --group fixed \
    --control-root "$control_root" --requested-backend workflow --resolved-backend workflow \
    --read-only-role architect) || return 1
  task_id=$(basename "$contract" .json)
  agen_out=$(bash "$SCRIPTS_DIR/agent-generator.sh" architect \
    --job "draft initial requirements and roadmap" --contract "$contract" --task-id "$task_id" \
    --control-root "$control_root" --execution-backend workflow 2>&1) || { printf '%s\n' "$agen_out" >&2; return 1; }
  name=$(grep '^SPAWN_READY' <<< "$agen_out" | awk '{print $2}')
  [ -n "$name" ] || return 1
  wgen_out=$(bash "$SCRIPTS_DIR/workflow-generator.sh" solo architect \
    --job "draft initial requirements and roadmap" --contract "$contract" --task-id "$task_id" \
    --control-root "$control_root" --name "$name" 2>&1) || { printf '%s\n' "$wgen_out" >&2; return 1; }
  printf '%s\n' "$wgen_out"
}

@test "init command's read-only workflow Architect contract issues, generates, and registers end to end" {
  setup_temp_dir
  run generate_init_architect_workflow
  teardown_temp_dir
  [ "$status" -eq 0 ]
  [[ "$output" == *'WORKFLOW_READY'* ]]
  [[ "$output" == *'path:'* ]]
}
