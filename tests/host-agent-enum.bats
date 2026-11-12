#!/usr/bin/env bats

load capability_helper
load gate_case_helper
load gate_case_files
load rejection_case_helper

setup() {
  setup_capability_sandbox
  ROUTING="$REPO_ROOT/scripts/meridian-routing.sh"
  BINARY="$TEST_ROOT/claude"
  CUSTOM_ID='leverframe:openai-oauth:codex-auto-review'
}

teardown() {
  teardown_capability_sandbox
}

write_sonnet_opus_fixture() {
  write_claude_fixture \
    "$BINARY" \
    '91.7.3 (Fixture Code)' \
    'careful, brisk, exhaustive' \
    '[{id:"claude-sonnet-5",family:"sonnet",display_name:"Sonnet 5"},{id:"claude-opus-5",family:"opus",display_name:"Opus 5"}]' \
    '' \
    '' \
    '' \
    "$1"
}

seed_routing_catalog() {
  write_sonnet_opus_fixture '["sonnet","opus"]'
  jq '
    {
      schema_version: 1,
      routing: {
        active_profile: "balanced",
        profiles: {
          quality: {roles: {}},
          balanced: {roles: {}},
          turbo: {roles: {}}
        }
      }
    }
  ' "$REPO_ROOT/config/settings.json" > "$PLANNING_DIR/config.json"
  run env CLAUDE_CODE_EXECPATH="$BINARY" bash "$SCRIPT" refresh "$PLANNING_DIR"
  [ "$status" -eq 0 ]
}

@test "catalog stores the extracted host enum with a custom id in any position" {
  while IFS='|' read -r label host_enum; do
    [ -n "$label" ] || continue
    rm -f "$CATALOG"
    write_claude_fixture \
      "$BINARY" \
      '91.7.3 (Fixture Code)' \
      'careful, brisk, exhaustive' \
      '[{id:"claude-amber-route",family:"amber",display_name:"Amber Route"},{id:"claude-violet-route",family:"violet",display_name:"Violet Route"}]' \
      '' \
      '' \
      '' \
      "$host_enum"

    run env CLAUDE_CODE_EXECPATH="$BINARY" bash "$SCRIPT" refresh "$PLANNING_DIR" </dev/null

    [ "$status" -eq 0 ] || { case_fail "$label" "refresh status=$status"; return 1; }
    catalog_matches --argjson enum "$host_enum" --arg custom "$CUSTOM_ID" '
      .host_agent_enum == $enum
      and (($enum - [.models[].selector]) == [])
      and ([.models[].selector] | index("claude-amber-route")) != null
      and .agent_model_ids["claude-amber-route"] == "amber"
      and .agent_model_ids[$custom] == $custom
    ' || { case_fail "$label" "enum=$host_enum"; return 1; }
  done <<'CASES'
custom-first|["leverframe:openai-oauth:codex-auto-review","amber","violet"]
custom-last|["amber","violet","leverframe:openai-oauth:codex-auto-review"]
CASES
}

map_agent_model() {
  run env CLAUDE_CODE_EXECPATH="$BINARY" bash "$SCRIPT" map-agent-model "$BINARY" "$1" </dev/null
}

expect_mapped() {
  map_agent_model "$2"
  expect_case "$1" 0 ""
  [ "$output" = "$3" ] || record_case_failure "$1" "output=[$output] want=[$3]"
}

@test "map-agent-model rewrites a full selector to its alias, keeps a live custom id and fails closed for an unknown model" {
  reset_case_failures

  write_sonnet_opus_fixture '["sonnet","opus","haiku","fable","leverframe:openai-oauth:codex-auto-review"]'
  expect_mapped full-selector-to-alias claude-sonnet-5 sonnet
  expect_mapped live-custom-id-unchanged "$CUSTOM_ID" "$CUSTOM_ID"

  rm -f "$CATALOG"
  make_claude_fixture "$BINARY"
  map_agent_model not-a-model
  expect_rejected unknown-model "not present in the live host Agent enum"

  assert_no_case_failures
}

@test "routing check accepts an extracted host alias and rejects a model missing from the extracted catalog" {
  reset_case_failures
  seed_routing_catalog

  run bash "$ROUTING" check "$PLANNING_DIR" sonnet '"careful"'
  expect_status host-alias-accepted 0
  expect_jq_output host-alias-model '.model == "sonnet"'

  run bash "$ROUTING" check "$PLANNING_DIR" missing-route '"careful"'
  expect_rejected missing-model "not present in the saved capability catalog"

  assert_no_case_failures
}
