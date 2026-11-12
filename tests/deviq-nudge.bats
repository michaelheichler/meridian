#!/usr/bin/env bats

load test_helper
load gate_case_helper
load rejection_case_helper

setup() {
  setup_temp_dir
  cd "$TEST_TEMP_DIR"
}

teardown() {
  cd "$PROJECT_ROOT"
  teardown_temp_dir
}

run_nudge() {
  local content="$1"
  payload "tool_name=Write" "tool_input.content=$content" \
    | env CLAUDE_PLUGIN_ROOT="$PROJECT_ROOT" bash "$SCRIPTS_DIR/deviq-nudge.sh"
}

@test "deviq-nudge stays silent without a usable match and nudges a match once per cooldown" {
  reset_case_failures

  run bash -c "printf 'not json{{{' | env CLAUDE_PLUGIN_ROOT='$PROJECT_ROOT' bash '$SCRIPTS_DIR/deviq-nudge.sh'"
  expect_case_silent garbage-stdin 0

  run bash -c "printf '%s' '{\"tool_input\":{\"content\":\"god object\"}}' | env CLAUDE_PLUGIN_ROOT='$TEST_TEMP_DIR' bash '$SCRIPTS_DIR/deviq-nudge.sh'"
  expect_case_silent missing-nudge-map 0

  run run_nudge "adds a simple helper function to format dates"
  expect_case_silent no-matching-pattern 0

  run run_nudge "this class has become a real god object over time"
  expect_case first-match-nudges 0 "additionalContext"
  expect_fragment first-match-nudges "antipatterns/blob"
  expect_fragment first-match-nudges "scripts/deviq-lookup.sh --show"

  run run_nudge "yet another god object right here"
  expect_case_silent second-match-in-cooldown 0

  printf '0\n' > "$TEST_TEMP_DIR/.meridian/deviq/.nudge-last"
  run run_nudge "a god object again after the cooldown ended"
  expect_case match-after-cooldown-expiry 0 "additionalContext"

  assert_no_case_failures
}
