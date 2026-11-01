#!/usr/bin/env bats

load test_helper
load model_cli_helper

setup() {
  setup_model_sandbox
}

teardown() {
  teardown_model_sandbox
}

@test "catalog emits stable JSON from an arbitrary capability fixture" {
  local expected
  expected=$(jq -cS . "$CATALOG")

  run bash "$SCRIPT" --json catalog "$PLANNING_DIR"

  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "show JSON is stable and includes every role in all three profiles" {
  run bash "$SCRIPT" --json show "$PLANNING_DIR"

  [ "$status" -eq 0 ]
  [ "$output" = "$(jq -cS . <<< "$output")" ]
  run jq -e \
    --slurpfile defaults "$REPO_ROOT/templates/agent-roles/defaults.json" '
      .schema_version == 1
      and .active_profile == "balanced"
      and .structural_default == null
      and (.models | map(.selector)) == ["quartz|route", "ember-path"]
      and .reasoning.accepted_values == ["depth-99", "default"]
      and ([.profiles | to_entries[] | .key] | sort) == ["balanced", "quality", "turbo"]
      and (all(.profiles[];
        (.roles | keys | sort) == ($defaults[0] | keys | map(select(. != "oracles" and . != "trios")) | sort)
        and all(.roles[]; . == null)
      ))
    ' <<< "$output"
  [ "$status" -eq 0 ]
}

@test "human show escapes table cells and distinguishes both defaults" {
  local expected_cells="$TEST_ROOT/expected-cells" found_cells
  jq -r '
    keys[] | select(. != "oracles" and . != "trios") as $role
    | ("quality", "balanced", "turbo") as $profile
    | "| \($profile) | \($role) |"
  ' "$REPO_ROOT/templates/agent-roles/defaults.json" > "$expected_cells"

  run bash "$SCRIPT" show "$PLANNING_DIR"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Detected models"* ]]
  [[ "$output" == *'Quartz \| Route Line?]0;owned?'* ]]
  [[ "$output" != *$'\e'* ]]
  [[ "$output" != *$'\a'* ]]
  [[ "$output" == *"Detected reasoning"* ]]
  [[ "$output" == *"Claude Code default"* ]]
  [[ "$output" == *'| default | Detected value |'* ]]
  [[ "$output" == *"Routing profiles"* ]]
  found_cells=$(grep -oFf "$expected_cells" <<< "$output" | sort -u | wc -l | tr -d ' ')
  [ "$found_cells" -eq "$(wc -l < "$expected_cells" | tr -d ' ')" ]
}

@test "set and refresh reject an unknown saved role without changing either state file" {
  local config_before catalog_before
  jq '
    .routing.profiles.quality.roles.bogus = {
      model: "ember-path",
      reasoning: null,
      status: "resolved"
    }
  ' "$PLANNING_DIR/config.json" > "$PLANNING_DIR/config.next"
  mv "$PLANNING_DIR/config.next" "$PLANNING_DIR/config.json"
  config_before=$(config_sha)
  catalog_before=$(catalog_sha)

  run bash "$SCRIPT" set "$PLANNING_DIR" balanced docs ember-path null
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown routing role: bogus"* ]]
  [ "$config_before" = "$(config_sha)" ]
  [ "$catalog_before" = "$(catalog_sha)" ]

  run env CLAUDE_CODE_EXECPATH="$CLAUDE_FIXTURE" bash "$SCRIPT" refresh "$PLANNING_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown routing role: bogus"* ]]
  [ "$config_before" = "$(config_sha)" ]
  [ "$catalog_before" = "$(catalog_sha)" ]
}

@test "set preserves exact selectors and keeps structural null apart from a detected default value" {
  while IFS=';' read -r label profile role selector reasoning; do
    [ -n "$label" ] || continue

    run bash "$SCRIPT" --json set "$PLANNING_DIR" "$profile" "$role" "$selector" "$reasoning" </dev/null

    [ "$status" -eq 0 ] || { case_fail "$label" "set status=$status"; return 1; }
    [ "$output" = "$(jq -cSn --arg model "$selector" --arg profile "$profile" --arg role "$role" --argjson reasoning "$reasoning" \
      '{model:$model,operation:"set",profile:$profile,reasoning:$reasoning,role:$role,status:"ok"}')" ] \
      || { case_fail "$label" "unexpected mutation JSON"; return 1; }
    jq -e --arg profile "$profile" --arg role "$role" --arg model "$selector" --argjson reasoning "$reasoning" '
      .routing.profiles[$profile].roles[$role] == {model:$model,reasoning:$reasoning,status:"resolved"}
    ' "$PLANNING_DIR/config.json" >/dev/null || { case_fail "$label" "stored route differs"; return 1; }
  done <<'CASES'
pipe-selector-exact-reasoning;quality;architect;quartz|route;"depth-99"
structural-null;balanced;docs;ember-path;null
detected-default-value;turbo;docs;ember-path;"default"
CASES
}

@test "activate and copy use the routing writer and emit stable mutation JSON" {
  bash "$SCRIPT" set "$PLANNING_DIR" quality architect 'quartz|route' '"depth-99"' >/dev/null

  run bash "$SCRIPT" --json copy "$PLANNING_DIR" quality turbo
  [ "$status" -eq 0 ]
  [ "$output" = '{"destination_profile":"turbo","operation":"copy","source_profile":"quality","status":"ok"}' ]
  run bash "$SCRIPT" --json activate "$PLANNING_DIR" turbo
  [ "$status" -eq 0 ]
  [ "$output" = '{"active_profile":"turbo","operation":"activate","status":"ok"}' ]
  jq -e '
    .routing.active_profile == "turbo"
    and .routing.profiles.turbo.roles == .routing.profiles.quality.roles
  ' "$PLANNING_DIR/config.json" >/dev/null
}

@test "validate emits stable JSON only after trusted validation succeeds" {
  run bash "$SCRIPT" --json validate "$PLANNING_DIR"

  [ "$status" -eq 0 ]
  [ "$output" = '{"operation":"validate","status":"ok"}' ]
}

@test "bad options and a missing set route fail without changing configuration" {
  local before
  before=$(config_sha)

  run bash "$SCRIPT" --unknown show "$PLANNING_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
  run bash "$SCRIPT" set "$PLANNING_DIR" quality architect
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
  [ "$before" = "$(config_sha)" ]
}

@test "stale catalogs fail before mutation" {
  local before
  before=$(config_sha)
  printf '%s\n' changed >> "$CLAUDE_FIXTURE"

  run bash "$SCRIPT" activate "$PLANNING_DIR" turbo

  [ "$status" -ne 0 ]
  [[ "$output" == *"fingerprint differs"* ]]
  [ "$before" = "$(config_sha)" ]
}

@test "invalid profiles and malformed reasoning JSON fail atomically" {
  local before
  before=$(config_sha)

  run bash "$SCRIPT" activate "$PLANNING_DIR" impossible
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown routing profile"* ]]
  run bash "$SCRIPT" set "$PLANNING_DIR" quality docs ember-path '"broken'
  [ "$status" -ne 0 ]
  [[ "$output" == *"not valid JSON"* ]]
  [ "$before" = "$(config_sha)" ]
}

@test "unknown selectors fail atomically" {
  local before
  before=$(config_sha)

  run bash "$SCRIPT" set "$PLANNING_DIR" quality docs absent-selector null

  [ "$status" -ne 0 ]
  [[ "$output" == *"not present in the saved capability catalog"* ]]
  [ "$before" = "$(config_sha)" ]
}
