#!/usr/bin/env bats

load script_contract_helper

migration_rows() {
  local label config predicate
  while IFS='|' read -r label config predicate; do
    printf '%s\n' "$config" > config.json
    run bash "$SCRIPTS_DIR/migrate-config.sh" config.json
    expect_case "$label" 0
    expect_jq "$label" config.json "$predicate"
  done
  assert_no_case_failures
}

@test "configuration migration preserves explicit choices while translating legacy settings" {
  migration_rows <<'CASES'
legacy-teams-on|{"agent_teams":true}|.prefer_teams == "always" and (has("agent_teams")|not)
legacy-teams-off|{"agent_teams":false}|.prefer_teams == "auto" and (has("agent_teams")|not)
canonical-teams-win|{"agent_teams":true,"prefer_teams":"never"}|.prefer_teams == "never" and (has("agent_teams")|not)
boolean-teams|{"prefer_teams":true}|.prefer_teams == "always"
old-parallel|{"prefer_teams":"when_parallel"}|.prefer_teams == "auto"
null-teams|{"prefer_teams":null}|.prefer_teams == "auto"
empty-teams|{"prefer_teams":""}|.prefer_teams == "auto"
old-feature-choice|{"v3_metrics":false}|.metrics == false and (has("v3_metrics")|not)
new-feature-choice-wins|{"v3_metrics":true,"metrics":false}|.metrics == false and (has("v3_metrics")|not)
legacy-round-cap|{"max_remediation_rounds":12}|.max_uat_remediation_rounds == 12 and (has("max_remediation_rounds")|not)
canonical-round-cap-wins|{"max_remediation_rounds":12,"max_uat_remediation_rounds":false}|.max_uat_remediation_rounds == false and (has("max_remediation_rounds")|not)
invalid-round-cap-disables|{"max_uat_remediation_rounds":"12"}|.max_uat_remediation_rounds == false
nested-values-survive|{"tmux_execution":{"restrictions":{"allow_agent_git":true}},"custom":{"kept":7}}|.custom.kept == 7 and .tmux_execution.restrictions.allow_agent_git == true
CASES
}

migration_rejections() {
  local label config
  while IFS='|' read -r label config; do
    printf '%s\n' "$config" > config.json
    cp config.json before.json
    run bash "$SCRIPTS_DIR/migrate-config.sh" config.json
    expect_case "$label" 1
    cmp -s config.json before.json || record_case_failure "$label" 'failed migration changed source'
    [ "$(find . -name '*.meridian-migrate.*' | wc -l | tr -d ' ')" -eq 0 ] || record_case_failure "$label" 'staging file leaked'
  done
  assert_no_case_failures
}

@test "failed configuration migration leaves the original file intact and removes staged writes" {
  migration_rejections <<'CASES'
malformed|{"broken":
scalar-tmux|{"tmux_execution":false}
scalar-restrictions|{"tmux_execution":{"restrictions":false}}
invalid-heartbeat|{"tmux_execution":{"heartbeat_interval_seconds":-1}}
CASES
}
