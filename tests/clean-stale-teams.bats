#!/usr/bin/env bats

load test_helper
load gate_case_helper
load gate_case_files

setup() {
  setup_temp_dir
  export CLAUDE_CONFIG_DIR="$TEST_TEMP_DIR/claude"
  export MERIDIAN_PLANNING_DIR="$TEST_TEMP_DIR/.meridian"
  export MERIDIAN_STALE_TEAM_SECONDS=7200
  reset_case_failures
}

teardown() {
  teardown_temp_dir
}

fresh_team_dirs() {
  rm -rf "$CLAUDE_CONFIG_DIR"
  mkdir -p "$CLAUDE_CONFIG_DIR/teams" "$CLAUDE_CONFIG_DIR/tasks" "$MERIDIAN_PLANNING_DIR"
}

configured_team() {
  mkdir -p "$CLAUDE_CONFIG_DIR/teams/meridian-plan-01/inboxes" "$CLAUDE_CONFIG_DIR/tasks/meridian-plan-01"
  printf '{}\n' > "$CLAUDE_CONFIG_DIR/teams/meridian-plan-01/config.json"
  printf '%s\n' "$1" > "$CLAUDE_CONFIG_DIR/teams/meridian-plan-01/inboxes/member"
}

clean_teams() {
  run bash "$SCRIPTS_DIR/clean-stale-teams.sh"
}

@test "clean-stale-teams removes configless or stale MERIDIAN teams with their tasks and keeps recent or foreign teams" {
  fresh_team_dirs
  mkdir -p "$CLAUDE_CONFIG_DIR/teams/meridian-plan-01" "$CLAUDE_CONFIG_DIR/tasks/meridian-plan-01"
  clean_teams
  expect_case configless-meridian-team 0 "teams_cleaned=1"
  expect_no_path configless-meridian-team "$CLAUDE_CONFIG_DIR/teams/meridian-plan-01"
  expect_no_path configless-meridian-team "$CLAUDE_CONFIG_DIR/tasks/meridian-plan-01"

  fresh_team_dirs
  mkdir -p "$CLAUDE_CONFIG_DIR/teams/other-team"
  clean_teams
  expect_status non-meridian-team 0
  expect_path non-meridian-team "$CLAUDE_CONFIG_DIR/teams/other-team"

  fresh_team_dirs
  configured_team recent
  clean_teams
  expect_case recent-configured-team 0 "teams_cleaned=0"
  expect_path recent-configured-team "$CLAUDE_CONFIG_DIR/teams/meridian-plan-01"

  fresh_team_dirs
  configured_team old
  touch -t 200001010000 "$CLAUDE_CONFIG_DIR/teams/meridian-plan-01/inboxes/member"
  clean_teams
  expect_case stale-configured-team 0 "teams_cleaned=1"
  expect_no_path stale-configured-team "$CLAUDE_CONFIG_DIR/teams/meridian-plan-01"
  expect_no_path stale-configured-team "$CLAUDE_CONFIG_DIR/tasks/meridian-plan-01"

  assert_no_case_failures
}
