#!/usr/bin/env bats

load capability_helper
load gate_case_helper
load gate_case_files
load rejection_case_helper

setup() {
  setup_capability_sandbox
  BINARY="$TEST_ROOT/claude"
  CONFIG_DIR="$TEST_ROOT/claude-config"
  mkdir -p "$CONFIG_DIR"
  reset_case_failures
}

teardown() {
  teardown_capability_sandbox
}

refresh_with_gates() {
  rm -f "$CATALOG"
  run env -u CLAUDE_CODE_DISABLE_WORKFLOWS -u CLAUDE_CODE_SUBAGENT_MODEL \
    CLAUDE_CODE_EXECPATH="$BINARY" CLAUDE_CONFIG_DIR="$CONFIG_DIR" "$@" \
    bash "$SCRIPT" refresh "$PLANNING_DIR" </dev/null
}

expect_catalog() {
  local label="$1" program="$2"
  catalog_matches "$program" 2>/dev/null \
    || record_case_failure "$label" "catalog did not match: $program content=$(cat "$CATALOG" 2>&1)"
}

@test "refresh records workflow availability and names each gate that disables it" {
  make_claude_fixture "$BINARY"

  refresh_with_gates
  expect_status gates-cleared 0
  expect_catalog gates-cleared '
    .workflow.min_version == "2.1.154"
    and .workflow.host_version == "91.7.3"
    and .workflow.meets_version_floor == true
    and .workflow.disabled_by_settings == false
    and .workflow.disabled_by_env == false
    and .workflow.subagent_model_override_active == false
    and .workflow.available == true
    and .workflow.unavailable_reasons == []
  '
  run bash "$SCRIPT" validate "$CATALOG"
  expect_status gates-cleared-validates 0

  refresh_with_gates CLAUDE_CODE_DISABLE_WORKFLOWS=1
  expect_status env-disable-one 0
  expect_catalog env-disable-one '
    .workflow.disabled_by_env == true
    and .workflow.available == false
    and (.workflow.unavailable_reasons | any(. == "CLAUDE_CODE_DISABLE_WORKFLOWS is set."))
  '

  refresh_with_gates CLAUDE_CODE_DISABLE_WORKFLOWS=true
  expect_status env-disable-true 0
  expect_catalog env-disable-true '
    .workflow.disabled_by_env == true
    and .workflow.available == false
    and (.workflow.unavailable_reasons | any(. == "CLAUDE_CODE_DISABLE_WORKFLOWS is set."))
  '

  refresh_with_gates CLAUDE_CODE_DISABLE_WORKFLOWS=yes
  expect_status env-disable-yes 0
  expect_catalog env-disable-yes '
    .workflow.disabled_by_env == true
    and .workflow.available == false
    and (.workflow.unavailable_reasons | any(. == "CLAUDE_CODE_DISABLE_WORKFLOWS is set."))
  '

  refresh_with_gates CLAUDE_CODE_SUBAGENT_MODEL=claude-opus
  expect_status subagent-model-set 0
  expect_catalog subagent-model-set '
    .workflow.subagent_model_override_active == true
    and .workflow.available == false
    and (.workflow.unavailable_reasons | any(contains("CLAUDE_CODE_SUBAGENT_MODEL")))
  '

  refresh_with_gates CLAUDE_CODE_DISABLE_WORKFLOWS='' CLAUDE_CODE_SUBAGENT_MODEL=''
  expect_status empty-gate-variables 0
  expect_catalog empty-gate-variables '
    .workflow.disabled_by_env == false
    and .workflow.subagent_model_override_active == false
    and .workflow.available == true
    and .workflow.unavailable_reasons == []
  '

  printf '%s\n' '{"disableWorkflows":true}' > "$CONFIG_DIR/settings.json"
  refresh_with_gates
  expect_status settings-disable 0
  expect_catalog settings-disable '
    .workflow.disabled_by_settings == true
    and .workflow.available == false
    and (.workflow.unavailable_reasons | any(. == "disableWorkflows is true in the Claude Code settings file."))
  '
  rm -f "$CONFIG_DIR/settings.json"

  write_claude_fixture \
    "$BINARY" \
    '2.1.100 (Fixture Code)' \
    'careful, brisk' \
    '[{id:"claude-amber-route",family:"amber",display_name:"Amber Route"}]' \
    ''
  refresh_with_gates
  expect_status below-version-floor 0
  expect_catalog below-version-floor '
    .workflow.meets_version_floor == false
    and .workflow.available == false
    and (.workflow.unavailable_reasons | length == 1)
    and (.workflow.unavailable_reasons[0] | contains("2.1.100") and contains("2.1.154"))
  '

  assert_no_case_failures
}

@test "validate accepts a catalog predating the workflow probe and rejects a malformed workflow object" {
  local legacy="$TEST_ROOT/no-workflow.json" malformed="$TEST_ROOT/bad-workflow.json"
  make_claude_fixture "$BINARY"
  refresh_with_gates
  [ "$status" -eq 0 ]
  jq 'del(.workflow)' "$CATALOG" > "$legacy"
  jq '.workflow.available = "yes"' "$CATALOG" > "$malformed"

  run bash "$SCRIPT" validate "$legacy"
  expect_status catalog-without-workflow 0

  run bash "$SCRIPT" validate "$malformed"
  expect_rejected malformed-workflow-object "invalid Claude Code capability catalog"

  assert_no_case_failures
}
