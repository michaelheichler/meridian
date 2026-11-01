#!/usr/bin/env bats

load capability_helper

setup() {
  setup_capability_sandbox
  BINARY="$TEST_ROOT/claude"
  CONFIG_DIR="$TEST_ROOT/claude-config"
  mkdir -p "$CONFIG_DIR"
}

teardown() {
  teardown_capability_sandbox
}

refresh_with_gates() {
  run env -u CLAUDE_CODE_DISABLE_WORKFLOWS -u CLAUDE_CODE_SUBAGENT_MODEL \
    CLAUDE_CODE_EXECPATH="$BINARY" CLAUDE_CONFIG_DIR="$CONFIG_DIR" "$@" \
    bash "$SCRIPT" refresh "$PLANNING_DIR"
}

@test "refresh persists workflow availability when the host clears every gate" {
  make_claude_fixture "$BINARY"

  refresh_with_gates

  [ "$status" -eq 0 ]
  catalog_matches '
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
  [ "$status" -eq 0 ]
}

@test "refresh marks workflow unavailable below the version floor" {
  write_claude_fixture \
    "$BINARY" \
    '2.1.100 (Fixture Code)' \
    'careful, brisk' \
    '[{id:"claude-amber-route",family:"amber",display_name:"Amber Route"}]' \
    ''

  refresh_with_gates

  [ "$status" -eq 0 ]
  catalog_matches '
    .workflow.meets_version_floor == false
    and .workflow.available == false
    and (.workflow.unavailable_reasons | length == 1)
    and (.workflow.unavailable_reasons[0] | contains("2.1.100") and contains("2.1.154"))
  '
}

@test "refresh marks workflow unavailable when disableWorkflows is true in settings" {
  make_claude_fixture "$BINARY"
  printf '%s\n' '{"disableWorkflows":true}' > "$CONFIG_DIR/settings.json"

  refresh_with_gates

  [ "$status" -eq 0 ]
  catalog_matches '
    .workflow.disabled_by_settings == true
    and .workflow.available == false
    and (.workflow.unavailable_reasons | any(. == "disableWorkflows is true in the Claude Code settings file."))
  '
}

@test "refresh marks workflow unavailable for any non-empty CLAUDE_CODE_DISABLE_WORKFLOWS spelling" {
  make_claude_fixture "$BINARY"

  while IFS='|' read -r label spelling; do
    [ -n "$label" ] || continue
    rm -f "$CATALOG"

    refresh_with_gates CLAUDE_CODE_DISABLE_WORKFLOWS="$spelling" </dev/null

    [ "$status" -eq 0 ] || { case_fail "$label" "refresh status=$status"; return 1; }
    catalog_matches '
      .workflow.disabled_by_env == true
      and .workflow.available == false
      and (.workflow.unavailable_reasons | any(. == "CLAUDE_CODE_DISABLE_WORKFLOWS is set."))
    ' || { case_fail "$label" "spelling=$spelling"; return 1; }
  done <<'CASES'
one|1
true|true
yes|yes
CASES
}

@test "refresh marks workflow unavailable and names CLAUDE_CODE_SUBAGENT_MODEL when it is set" {
  make_claude_fixture "$BINARY"

  refresh_with_gates CLAUDE_CODE_SUBAGENT_MODEL=claude-opus

  [ "$status" -eq 0 ]
  catalog_matches '
    .workflow.subagent_model_override_active == true
    and .workflow.available == false
    and (.workflow.unavailable_reasons | any(contains("CLAUDE_CODE_SUBAGENT_MODEL")))
  '
}

@test "refresh treats an exported but empty gate variable as absent" {
  make_claude_fixture "$BINARY"

  refresh_with_gates CLAUDE_CODE_DISABLE_WORKFLOWS='' CLAUDE_CODE_SUBAGENT_MODEL=''

  [ "$status" -eq 0 ]
  catalog_matches '
    .workflow.disabled_by_env == false
    and .workflow.subagent_model_override_active == false
    and .workflow.available == true
    and .workflow.unavailable_reasons == []
  '
}

@test "validate accepts a catalog predating the workflow probe" {
  local legacy="$TEST_ROOT/no-workflow.json"
  make_claude_fixture "$BINARY"
  refresh_with_gates
  [ "$status" -eq 0 ]
  jq 'del(.workflow)' "$CATALOG" > "$legacy"

  run bash "$SCRIPT" validate "$legacy"

  [ "$status" -eq 0 ]
}

@test "validate rejects a catalog whose workflow object is malformed" {
  local malformed="$TEST_ROOT/bad-workflow.json"
  make_claude_fixture "$BINARY"
  refresh_with_gates
  [ "$status" -eq 0 ]
  jq '.workflow.available = "yes"' "$CATALOG" > "$malformed"

  run bash "$SCRIPT" validate "$malformed"

  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid Claude Code capability catalog"* ]]
}
