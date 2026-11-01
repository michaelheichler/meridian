#!/usr/bin/env bats

load capability_helper

setup() {
  setup_capability_sandbox
  ROUTING="$REPO_ROOT/scripts/lbwc-routing.sh"
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

@test "map-agent-model rewrites a full selector to its alias and keeps a live custom id" {
  write_sonnet_opus_fixture '["sonnet","opus","haiku","fable","leverframe:openai-oauth:codex-auto-review"]'

  while IFS='|' read -r label selector expected; do
    [ -n "$label" ] || continue

    run env CLAUDE_CODE_EXECPATH="$BINARY" bash "$SCRIPT" map-agent-model "$BINARY" "$selector" </dev/null

    [ "$status" -eq 0 ] || { case_fail "$label" "status=$status"; return 1; }
    [ "$output" = "$expected" ] || { case_fail "$label" "expected=$expected"; return 1; }
  done <<'CASES'
full-selector-to-alias|claude-sonnet-5|sonnet
live-custom-id-unchanged|leverframe:openai-oauth:codex-auto-review|leverframe:openai-oauth:codex-auto-review
CASES
}

@test "map-agent-model fails closed for an unknown model" {
  make_claude_fixture "$BINARY"

  run env CLAUDE_CODE_EXECPATH="$BINARY" bash "$SCRIPT" map-agent-model "$BINARY" "not-a-model"

  [ "$status" -ne 0 ]
  [[ "$output" == *"not present in the live host Agent enum"* ]]
}

@test "routing check accepts an extracted host alias" {
  seed_routing_catalog

  run bash "$ROUTING" check "$PLANNING_DIR" sonnet '"careful"'

  [ "$status" -eq 0 ]
  jq -e '.model == "sonnet"' <<< "$output" >/dev/null
}

@test "routing check rejects a model missing from the extracted catalog" {
  seed_routing_catalog

  run bash "$ROUTING" check "$PLANNING_DIR" missing-route '"careful"'

  [ "$status" -ne 0 ]
  [[ "$output" == *"not present in the saved capability catalog"* ]]
}
