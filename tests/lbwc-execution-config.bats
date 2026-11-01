#!/usr/bin/env bats

load gate_case_helper
load lbwc_config_helper

setup() {
  config_fixture_setup
}

teardown() {
  config_fixture_teardown
}

mark_executing() {
  printf '%s\n' '{"status":"executing"}' > "$1/.execution-state.json"
}

write_registry() {
  mkdir -p "$1/.runtime/tmux-bus"
  printf '%s\n' "$2" > "$1/.runtime/tmux-bus/registry.json"
}

reject_in_process_switch_row() {
  local label="$1" registry="$2"
  write_registry "$PLANNING_DIR" "$registry"
  reject_unchanged_row "$label" "$PLANNING_DIR" frozen set "$PLANNING_DIR" agent_execution_mode '"in_process"'
  expect_config_jq "$label" "$PLANNING_DIR" '.agent_execution_mode == "tmux"'
}

@test "config persists execution defaults, accepts valid settings, and rejects invalid, unwritable and frozen ones unchanged" {
  local tmux_settings workflow_settings state state_dir

  init_config "$PLANNING_DIR"
  expect_config_jq defaults "$PLANNING_DIR" '
    .agent_execution_mode == "ask"
    and .tmux_execution.enabled == false
    and .tmux_execution.session_name_prefix == "lbwc"
    and .tmux_execution.max_agents == 3
    and .tmux_execution.attach_policy == "orchestrator_only"
    and (.tmux_execution | has("session_timeout_seconds") | not)
    and (.tmux_execution | has("pane_base_index") | not)
    and .tmux_execution.heartbeat_interval_seconds == 30
    and .tmux_execution.heartbeat_stale_seconds == 120
    and .tmux_execution.comms_latency_tolerance_ms == 5000
    and .tmux_execution.comms_fallback == "bus_only"
    and .tmux_execution.cleanup_policy == "kill_on_complete"
    and .tmux_execution.layout == "main-vertical"
    and .tmux_execution.restrictions.allow_nested_spawn == false
    and .tmux_execution.restrictions.allow_agent_git == false
    and .tmux_execution.restrictions.allow_agent_ask_user == false
    and .tmux_execution.restrictions.require_orchestrator_attach == true
    and .workflow_execution.enabled == false
  '

  tmux_settings=$(jq -c '.tmux_execution | .enabled = true | .max_agents = 4' "$PLANNING_DIR/config.json")
  run_config set-json "$PLANNING_DIR" tmux_execution "$tmux_settings"
  expect_case tmux-set-json 0
  set_accepted_row tmux-mode "$PLANNING_DIR" agent_execution_mode '"tmux"' '.agent_execution_mode == "tmux"'
  run_config get "$PLANNING_DIR" agent_execution_mode
  expect_case tmux-get 0 '"tmux"'
  expect_config_jq tmux-settings "$PLANNING_DIR" '.tmux_execution.enabled == true and .tmux_execution.max_agents == 4'

  workflow_settings=$(jq -c '.workflow_execution | .enabled = true' "$PLANNING_DIR/config.json")
  run_config set-json "$PLANNING_DIR" workflow_execution "$workflow_settings"
  expect_case workflow-set-json 0
  set_accepted_row workflow-mode "$PLANNING_DIR" agent_execution_mode '"workflow"' '.agent_execution_mode == "workflow"'
  run_config get "$PLANNING_DIR" agent_execution_mode
  expect_case workflow-get 0 '"workflow"'
  expect_config_jq workflow-settings "$PLANNING_DIR" '.workflow_execution.enabled == true'

  mark_executing "$PLANNING_DIR"
  set_accepted_row active-cleanup-policy "$PLANNING_DIR" tmux_execution.cleanup_policy '"keep_panes"' \
    '.tmux_execution.cleanup_policy == "keep_panes"'

  for state in registered idle failed shutdown; do
    state_dir="$TEST_ROOT/$state/.lbwc-planning"
    init_config "$state_dir"
    set_accepted_row "registry-$state-mode" "$state_dir" agent_execution_mode '"tmux"' '.agent_execution_mode == "tmux"'
    mark_executing "$state_dir"
    write_registry "$state_dir" "{\"agents\":[{\"state\":\"$state\"}]}"
    set_accepted_row "registry-$state-switch" "$state_dir" agent_execution_mode '"in_process"' \
      '.agent_execution_mode == "in_process"'
  done

  PLANNING_DIR="$TEST_ROOT/rejections/.lbwc-planning"
  init_config "$PLANNING_DIR"

  reject_unchanged_row invalid-mode "$PLANNING_DIR" "invalid configuration" \
    set "$PLANNING_DIR" agent_execution_mode '"invalid"'
  reject_unchanged_row max-agents-above-limit "$PLANNING_DIR" "invalid configuration" \
    set "$PLANNING_DIR" tmux_execution.max_agents 5
  reject_unchanged_row session-prefix-with-slash "$PLANNING_DIR" "invalid configuration" \
    set "$PLANNING_DIR" tmux_execution.session_name_prefix '"bad/name"'
  reject_unchanged_row unknown-comms-fallback "$PLANNING_DIR" "invalid configuration" \
    set "$PLANNING_DIR" tmux_execution.comms_fallback '"native"'
  reject_unchanged_row unused-session-timeout "$PLANNING_DIR" "setting is not writable" \
    set "$PLANNING_DIR" tmux_execution.session_timeout_seconds 14400
  reject_unchanged_row unused-pane-base-index "$PLANNING_DIR" "setting is not writable" \
    set "$PLANNING_DIR" tmux_execution.pane_base_index 1
  reject_unchanged_row unused-workflow-key "$PLANNING_DIR" "setting is not writable" \
    set "$PLANNING_DIR" workflow_execution.size_guideline '"medium"'

  tmux_settings=$(jq -c '.tmux_execution | .session_timeout_seconds = 14400' "$PLANNING_DIR/config.json")
  reject_unchanged_row extra-tmux-key-in-block "$PLANNING_DIR" invalid set-json "$PLANNING_DIR" tmux_execution "$tmux_settings"
  workflow_settings=$(jq -c '.workflow_execution | .size_guideline = "medium"' "$PLANNING_DIR/config.json")
  reject_unchanged_row extra-workflow-key-in-block "$PLANNING_DIR" invalid \
    set-json "$PLANNING_DIR" workflow_execution "$workflow_settings"

  set_accepted_row prepare-tmux-mode "$PLANNING_DIR" agent_execution_mode '"tmux"' '.agent_execution_mode == "tmux"'
  set_accepted_row workflow-enabled-writable "$PLANNING_DIR" workflow_execution.enabled true \
    '.workflow_execution.enabled == true'
  mark_executing "$PLANNING_DIR"
  reject_unchanged_row mode-frozen-while-executing "$PLANNING_DIR" frozen \
    set "$PLANNING_DIR" agent_execution_mode '"workflow"'
  reject_unchanged_row tmux-layout-frozen-while-executing "$PLANNING_DIR" frozen \
    set "$PLANNING_DIR" tmux_execution.layout '"tiled"'
  reject_unchanged_row workflow-enabled-frozen-while-executing "$PLANNING_DIR" frozen \
    set "$PLANNING_DIR" workflow_execution.enabled false

  write_registry "$PLANNING_DIR" '{"agents":[{"state":"running"}]}'
  reject_unchanged_row running-agent-blocks-switch "$PLANNING_DIR" frozen \
    set "$PLANNING_DIR" agent_execution_mode '"in_process"'
  reject_in_process_switch_row malformed-registry '{not valid json'
  reject_in_process_switch_row registry-null-agent '{"agents":[null]}'
  reject_in_process_switch_row registry-agent-without-state '{"agents":[{}]}'
  reject_in_process_switch_row registry-unknown-state '{"agents":[{"state":"unknown"}]}'
  reject_in_process_switch_row registry-used-state '{"agents":[{"state":"used"}]}'
  reject_in_process_switch_row registry-expired-state '{"agents":[{"state":"expired"}]}'

  assert_no_case_failures
}

migrate_fills_row() {
  local label="$1" program="$2"
  run bash "$MIGRATE" "$PLANNING_DIR/config.json"
  expect_case "$label" 0
  expect_config_jq "$label" "$PLANNING_DIR" "$program"
}

@test "migration fills missing execution blocks, strips unused tmux keys, and rejects invalid tmux settings unchanged" {
  local default_config setting literal
  mkdir -p "$PLANNING_DIR"
  printf '%s\n' '{"schema_version":1,"agent_execution_mode":"tmux","tmux_execution":{"max_agents":4,"restrictions":{"allow_agent_git":true}}}' \
    > "$PLANNING_DIR/config.json"
  migrate_fills_row partial-tmux-block '
    .agent_execution_mode == "tmux"
    and .tmux_execution.enabled == false
    and .tmux_execution.max_agents == 4
    and (.tmux_execution | has("session_timeout_seconds") | not)
    and (.tmux_execution | has("pane_base_index") | not)
    and .tmux_execution.restrictions.allow_agent_git == true
    and .tmux_execution.restrictions.allow_nested_spawn == false
  '

  run bash "$SCRIPT" default-config
  expect_case default-config 0
  printf '%s\n' "$output" > "$PLANNING_DIR/config.json"
  jq '.tmux_execution.session_timeout_seconds = 14400 | .tmux_execution.pane_base_index = 1' \
    "$PLANNING_DIR/config.json" > "$PLANNING_DIR/config.json.tmp"
  mv "$PLANNING_DIR/config.json.tmp" "$PLANNING_DIR/config.json"
  migrate_fills_row unused-tmux-keys-stripped '
    (.tmux_execution | has("session_timeout_seconds") | not)
    and (.tmux_execution | has("pane_base_index") | not)
    and .tmux_execution.layout == "main-vertical"
    and .tmux_execution.max_agents == 3
    and .tmux_execution.heartbeat_interval_seconds == 30
  '

  printf '%s\n' '{"schema_version":1,"agent_execution_mode":"workflow"}' > "$PLANNING_DIR/config.json"
  migrate_fills_row missing-workflow-block '
    .agent_execution_mode == "workflow"
    and .workflow_execution.enabled == false
  '

  run bash "$SCRIPT" default-config
  [ "$status" -eq 0 ]
  default_config="$output"

  while IFS=$'\t' read -r setting literal; do
    [ -n "$setting" ] || continue
    migrate_rejected_row "$setting=$literal" "$setting" "$literal" "$default_config"
  done <<'VALUES'
tmux_execution.enabled	"true"
tmux_execution.session_name_prefix	"bad/name"
tmux_execution.max_agents	0
tmux_execution.max_agents	5
tmux_execution.attach_policy	"all"
tmux_execution.heartbeat_interval_seconds	0
tmux_execution.heartbeat_stale_seconds	0
tmux_execution.comms_latency_tolerance_ms	0
tmux_execution.comms_fallback	"native"
tmux_execution.cleanup_policy	"retain"
tmux_execution.layout	"stacked"
tmux_execution.restrictions	false
tmux_execution.restrictions.unexpected	true
tmux_execution.restrictions.allow_nested_spawn	"false"
tmux_execution.restrictions.allow_agent_git	"false"
tmux_execution.restrictions.allow_agent_ask_user	"false"
tmux_execution.restrictions.require_orchestrator_attach	"true"
tmux_execution.unexpected	true
VALUES

  assert_no_case_failures
}

migrate_rejected_row() {
  local label="$1" setting="$2" literal="$3" default_config="$4" before
  printf '%s\n' "$default_config" > "$PLANNING_DIR/config.json"
  jq --arg setting "$setting" --argjson value "$literal" 'setpath($setting | split("."); $value)' \
    "$PLANNING_DIR/config.json" > "$PLANNING_DIR/config.json.tmp"
  mv "$PLANNING_DIR/config.json.tmp" "$PLANNING_DIR/config.json"
  before=$(config_digest "$PLANNING_DIR")

  run bash "$MIGRATE" "$PLANNING_DIR/config.json"

  [ "$status" -ne 0 ] || record_case_failure "$label" "expected a failing status output=$output"
  [[ "$output" == *"Config migration failed"* ]] \
    || record_case_failure "$label" "missing failure message output=$output"
  [ "$before" = "$(config_digest "$PLANNING_DIR")" ] || record_case_failure "$label" "configuration changed"
}
