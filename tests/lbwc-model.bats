#!/usr/bin/env bats

load test_helper
load model_cli_helper
load gate_case_helper
load gate_case_files

setup() {
  setup_model_sandbox
  reset_case_failures
}

teardown() {
  teardown_model_sandbox
}

expect_config_unchanged() {
  [ "$(config_sha)" = "$2" ] || record_case_failure "$1" "config.json changed"
}

expect_refused() {
  local label=$1 fragment=$2
  [ "$status" -ne 0 ] || record_case_failure "$label" "command succeeded output=$output"
  expect_output_has "$label" "$fragment"
}

@test "catalog, show and validate emit stable JSON and an escaped human table" {
  local expected expected_cells="$TEST_ROOT/expected-cells" found_cells

  expected=$(jq -cS . "$CATALOG")
  run bash "$SCRIPT" --json catalog "$PLANNING_DIR"
  expect_case catalog-json 0
  [ "$output" = "$expected" ] || record_case_failure catalog-json "output=$output"

  run bash "$SCRIPT" --json show "$PLANNING_DIR"
  expect_case show-json 0
  [ "$output" = "$(jq -cS . <<< "$output")" ] || record_case_failure show-json "output is not stable sorted JSON"
  jq -e --slurpfile defaults "$REPO_ROOT/templates/agent-roles/defaults.json" '
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
    ' <<< "$output" >/dev/null || record_case_failure show-json-roles "profiles or catalog fields differ"

  jq -r '
    keys[] | select(. != "oracles" and . != "trios") as $role
    | ("quality", "balanced", "turbo") as $profile
    | "| \($profile) | \($role) |"
  ' "$REPO_ROOT/templates/agent-roles/defaults.json" > "$expected_cells"
  run bash "$SCRIPT" show "$PLANNING_DIR"
  expect_case show-human 0 "Detected models"
  expect_output_has show-human-escapes-cells 'Quartz \| Route Line?]0;owned?'
  expect_output_lacks show-human-no-escape-byte $'\e'
  expect_output_lacks show-human-no-bell-byte $'\a'
  expect_output_has show-human-reasoning "Detected reasoning"
  expect_output_has show-human-structural-default "Claude Code default"
  expect_output_has show-human-detected-default '| default | Detected value |'
  expect_output_has show-human-profiles "Routing profiles"
  found_cells=$(grep -oFf "$expected_cells" <<< "$output" | sort -u | wc -l | tr -d ' ')
  [ "$found_cells" -eq "$(wc -l < "$expected_cells" | tr -d ' ')" ] \
    || record_case_failure show-human-every-cell "found $found_cells profile and role cells"

  run bash "$SCRIPT" --json validate "$PLANNING_DIR"
  expect_case validate-json 0
  [ "$output" = '{"operation":"validate","status":"ok"}' ] || record_case_failure validate-json "output=$output"

  assert_no_case_failures
}

@test "set, copy and activate store exact routes and emit stable mutation JSON" {
  local label profile role selector reasoning

  while IFS=';' read -r label profile role selector reasoning; do
    [ -n "$label" ] || continue
    run bash "$SCRIPT" --json set "$PLANNING_DIR" "$profile" "$role" "$selector" "$reasoning" </dev/null
    expect_case "$label" 0
    [ "$output" = "$(jq -cSn --arg model "$selector" --arg profile "$profile" --arg role "$role" --argjson reasoning "$reasoning" \
      '{model:$model,operation:"set",profile:$profile,reasoning:$reasoning,role:$role,status:"ok"}')" ] \
      || record_case_failure "$label" "unexpected mutation JSON"
    jq -e --arg profile "$profile" --arg role "$role" --arg model "$selector" --argjson reasoning "$reasoning" '
      .routing.profiles[$profile].roles[$role] == {model:$model,reasoning:$reasoning,status:"resolved"}
    ' "$PLANNING_DIR/config.json" >/dev/null || record_case_failure "$label" "stored route differs"
  done <<'CASES'
pipe-selector-exact-reasoning;quality;architect;quartz|route;"depth-99"
structural-null;balanced;docs;ember-path;null
detected-default-value;turbo;docs;ember-path;"default"
CASES

  run bash "$SCRIPT" --json copy "$PLANNING_DIR" quality turbo
  expect_case copy 0
  [ "$output" = '{"destination_profile":"turbo","operation":"copy","source_profile":"quality","status":"ok"}' ] \
    || record_case_failure copy "output=$output"
  run bash "$SCRIPT" --json activate "$PLANNING_DIR" turbo
  expect_case activate 0
  [ "$output" = '{"active_profile":"turbo","operation":"activate","status":"ok"}' ] \
    || record_case_failure activate "output=$output"
  expect_jq activate-copied-roles "$PLANNING_DIR/config.json" '
    .routing.active_profile == "turbo"
    and .routing.profiles.turbo.roles == .routing.profiles.quality.roles
  '

  assert_no_case_failures
}

@test "bad options, unknown profiles, selectors and roles, malformed reasoning, and stale catalogs fail without mutation" {
  local before catalog_before

  before=$(config_sha)
  run bash "$SCRIPT" --unknown show "$PLANNING_DIR"
  expect_refused unknown-option "Usage:"
  run bash "$SCRIPT" set "$PLANNING_DIR" quality architect
  expect_refused set-without-route "Usage:"
  run bash "$SCRIPT" activate "$PLANNING_DIR" impossible
  expect_refused unknown-profile "unknown routing profile"
  run bash "$SCRIPT" set "$PLANNING_DIR" quality docs ember-path '"broken'
  expect_refused malformed-reasoning "not valid JSON"
  run bash "$SCRIPT" set "$PLANNING_DIR" quality docs absent-selector null
  expect_refused unknown-selector "not present in the saved capability catalog"
  expect_config_unchanged rejected-arguments "$before"

  cp "$PLANNING_DIR/config.json" "$TEST_ROOT/config.saved"
  jq '
    .routing.profiles.quality.roles.bogus = {
      model: "ember-path",
      reasoning: null,
      status: "resolved"
    }
  ' "$PLANNING_DIR/config.json" > "$PLANNING_DIR/config.next"
  mv "$PLANNING_DIR/config.next" "$PLANNING_DIR/config.json"
  before=$(config_sha)
  catalog_before=$(catalog_sha)
  run bash "$SCRIPT" set "$PLANNING_DIR" balanced docs ember-path null
  expect_refused unknown-saved-role-set "unknown routing role: bogus"
  expect_config_unchanged unknown-saved-role-set "$before"
  [ "$catalog_before" = "$(catalog_sha)" ] || record_case_failure unknown-saved-role-set "catalog changed"
  run env CLAUDE_CODE_EXECPATH="$CLAUDE_FIXTURE" bash "$SCRIPT" refresh "$PLANNING_DIR"
  expect_refused unknown-saved-role-refresh "unknown routing role: bogus"
  expect_config_unchanged unknown-saved-role-refresh "$before"
  [ "$catalog_before" = "$(catalog_sha)" ] || record_case_failure unknown-saved-role-refresh "catalog changed"
  cp "$TEST_ROOT/config.saved" "$PLANNING_DIR/config.json"

  before=$(config_sha)
  printf '%s\n' changed >> "$CLAUDE_FIXTURE"
  run bash "$SCRIPT" activate "$PLANNING_DIR" turbo
  expect_refused stale-catalog "fingerprint differs"
  expect_config_unchanged stale-catalog "$before"

  assert_no_case_failures
}
