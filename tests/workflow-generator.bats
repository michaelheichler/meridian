#!/usr/bin/env bats

load test_helper
load gate_case_helper

setup() {
  setup_temp_dir
  create_test_config
  cd "$TEST_TEMP_DIR"
  git init -q
}

teardown() {
  await_git_ai
  cd "$PROJECT_ROOT"
  teardown_temp_dir
}

stage_team() {
  local shape="$1" role="$2" project contract
  project="$TEST_TEMP_DIR/project-$shape"
  CONTROL_ROOT="$project/.temporary-agent-runfiles/runs/wf-$shape"
  mkdir -p "$project/.lbwc-planning" "$CONTROL_ROOT"
  jq -n '{workflow_execution:{enabled:true}}' > "$CONTROL_ROOT/config.json"
  jq -n '{workflow:{available:true, unavailable_reasons:[]}}' > "$CONTROL_ROOT/claude-capabilities.json"
  contract=$(bash "$SCRIPTS_DIR/task-contract.sh" issue "$project" "$shape" \
    --command integration-test --role "$role" --team "$shape" --job "team fixture $shape" \
    --group fixed --control-root "$CONTROL_ROOT" --requested-backend workflow \
    --resolved-backend workflow --write-capability directory:notes) || return 1
  TASK_ID=$(basename "$contract" .json)
  CONTRACT=$contract
  AGENT_OUTPUT=$(LBWC_AGENT_RANDOM_SEED=$RANDOM bash "$SCRIPTS_DIR/agent-generator.sh" "--$shape" "$role" \
    --job "team fixture $shape" --contract "$contract" --task-id "$TASK_ID" \
    --control-root "$CONTROL_ROOT" --write-capability directory:notes \
    --execution-backend workflow 2>&1) || { printf '%s\n' "$AGENT_OUTPUT" >&2; return 1; }
}

spawned_name() {
  grep -i "^$1: SPAWN_READY" <<< "$AGENT_OUTPUT" | awk '{print $3}'
}

run_workflow_generator() {
  local shape="$1" role="$2" engineer_label="$3" critic_label="$4"
  local -a team_args=(--engineer-name "$(spawned_name "$engineer_label")" --critic-name "$(spawned_name "$critic_label")")
  [ "$shape" != trio ] || team_args+=(--testdev-name "$(spawned_name test-dev)")
  run bash "$SCRIPTS_DIR/workflow-generator.sh" "$shape" "$role" \
    --job "team fixture $shape" --contract "$CONTRACT" --task-id "$TASK_ID" --autonomy standard \
    --control-root "$CONTROL_ROOT" "${team_args[@]}"
}

registered_roster() {
  jq -c --arg id "$TASK_ID" '.workflows[$id].roster | sort' "$CONTROL_ROOT/workflow-manifest.json"
}

generated_roster() {
  grep SPAWN_READY <<< "$AGENT_OUTPUT" | awk '{print $3}' | jq -Rn '[inputs] | sort' | jq -c .
}

@test "a pair or trio workflow registers exactly the agents the generator spawned" {
  local label shape role engineer_label critic_label want_roster
  reset_case_failures
  while IFS='|' read -r label shape role engineer_label critic_label; do
    stage_team "$shape" "$role"
    run_workflow_generator "$shape" "$role" "$engineer_label" "$critic_label"
    expect_case "$label" 0
    want_roster=$(generated_roster)
    [ "$(registered_roster)" = "$want_roster" ] \
      || record_case_failure "$label" "roster=$(registered_roster) want=$want_roster"
  done <<'TABLE'
trio|trio|python-engineer|python-engineer|python-critic
pair|pair|python-engineer|ENGINEER|CRITIC
TABLE
  assert_no_case_failures
}

workflow_capability_rows() {
  local label mutation
  reset_case_failures
  while IFS='|' read -r label mutation; do
    stage_team pair python-engineer
    case "$mutation" in
      disabled) printf '%s\n' '{"workflow_execution":{"enabled":false}}' > "$CONTROL_ROOT/config.json" ;;
      missing-config) rm "$CONTROL_ROOT/config.json" ;;
      missing-catalog) rm "$CONTROL_ROOT/claude-capabilities.json" ;;
      malformed-catalog) printf '%s\n' '{}' > "$CONTROL_ROOT/claude-capabilities.json" ;;
      unavailable) printf '%s\n' '{"workflow":{"available":false,"unavailable_reasons":["disabled by host"]}}' > "$CONTROL_ROOT/claude-capabilities.json" ;;
      session-disabled) export CLAUDE_CODE_DISABLE_WORKFLOWS=1 ;;
      model-override) export CLAUDE_CODE_SUBAGENT_MODEL=sample-model ;;
      dispatched) bash "$SCRIPTS_DIR/task-contract.sh" state "$(jq -r '.project_root' "$CONTRACT")" "$TASK_ID" dispatched >/dev/null ;;
    esac
    run_workflow_generator pair python-engineer ENGINEER CRITIC
    expect_case "$label" 1
    [ ! -e "$CONTROL_ROOT/workflow-manifest.json" ] || record_case_failure "$label" 'rejected generation registered a workflow'
    [ ! -e "$CONTROL_ROOT/workflows/$TASK_ID.js" ] || record_case_failure "$label" 'rejected generation published a workflow'
    unset CLAUDE_CODE_DISABLE_WORKFLOWS CLAUDE_CODE_SUBAGENT_MODEL
    rm -rf "$TEST_TEMP_DIR/project-pair"
  done
  assert_no_case_failures
}

@test "workflow generation rechecks live availability before publishing any runnable workflow" {
  workflow_capability_rows <<'CASES'
configuration-disabled|disabled
configuration-missing|missing-config
catalog-missing|missing-catalog
catalog-without-probe|malformed-catalog
host-unavailable|unavailable
session-disabled|session-disabled
session-model-override|model-override
CASES
}

@test "workflow generation refuses a contract that has already left the planned state" {
  workflow_capability_rows <<'CASES'
already-dispatched|dispatched
CASES
}
