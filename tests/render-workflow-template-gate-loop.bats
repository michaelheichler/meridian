#!/usr/bin/env bats

load gate_case_helper
load gate_case_files

setup() {
  command -v node >/dev/null 2>&1 || skip "node is required to execute rendered workflow templates"
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/render-workflow-template.sh"
  HARNESS="$BATS_TEST_DIRNAME/fixtures/workflow-harness.cjs"
  reset_case_failures
}

render_pair() {
  run bash "$SCRIPT" pair NAME=probe-pair DESCRIPTION=desc \
    JOB=job TASK_ID=task-2 "AUTONOMY=$1" \
    ENGINEER_AGENT_TYPE=lbwc-eng-a ENGINEER_MODEL=sonnet ENGINEER_EFFORT=balanced \
    CRITIC_AGENT_TYPE=lbwc-crit-a CRITIC_MODEL=sonnet CRITIC_EFFORT=fast
}

render_trio() {
  run bash "$SCRIPT" trio NAME=probe-trio DESCRIPTION=desc \
    JOB=job TASK_ID=task-3 "AUTONOMY=$1" \
    ENGINEER_AGENT_TYPE=lbwc-eng-a ENGINEER_MODEL=sonnet ENGINEER_EFFORT=balanced \
    CRITIC_AGENT_TYPE=lbwc-crit-a CRITIC_MODEL=sonnet CRITIC_EFFORT=fast \
    TESTDEV_AGENT_TYPE=lbwc-td-a TESTDEV_MODEL=sonnet TESTDEV_EFFORT=fast
}

run_gate_loop() {
  local kind=$1 autonomy=$2 responses=$3 rendered
  rendered="$BATS_TEST_TMPDIR/$kind-exec.mjs"
  "render_$kind" "$autonomy"
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$output" > "$rendered"
  run node "$HARNESS" "$rendered" "$responses"
}

@test "gate loops score verdicts, rerun the blocking owner, and ask the user after three standard blocks" {
  local label kind autonomy responses labels result_status round
  while IFS='|' read -r label kind autonomy responses labels result_status round; do
    [ -n "$label" ] || continue
    run_gate_loop "$kind" "$autonomy" "$responses" || { record_case_failure "$label" "render failed output=$output"; continue; }
    expect_status "$label" 0
    expect_jq_output "$label-calls" ".agentCalls | map(.label) | join(\",\") == \"$labels\""
    expect_jq_output "$label-result" ".result.status == \"$result_status\" and .result.round == $round"
    expect_jq_output "$label-critic-schema" '.agentCalls | map(select(.label == "critic")) | all(.hasSchema == true)'
  done <<'CASES'
pair-pass-on-round-1|pair|standard|[{"n":1},{"verdict":"PASS"}]|engineer,critic|complete|1
pair-pure-vibe-continues-past-round-3|pair|pure-vibe|[{"n":1},{"verdict":"BLOCK"},{"n":2},{"verdict":"BLOCK"},{"n":3},{"verdict":"BLOCK"},{"n":4},{"verdict":"PASS"}]|engineer,critic,engineer,critic,engineer,critic,engineer,critic|complete|4
pair-block-text-containing-pass-stays-block|pair|standard|[{"n":1},{"verdict":"BLOCK","findings":"1. (blocking) The variant does not decrease. Fix: tighten the guard split.\nVERDICT: BLOCK. Flips on: fix 1 so tests/guard.bats can pass.\nGrounding: discipline-of-programming-dijkstra/SKILL.md."},{"n":2},{"verdict":"PASS"}]|engineer,critic,engineer,critic|complete|2
trio-pass-on-round-1|trio|standard|[{"n":1},{"t":1},{"verdict":"PASS"}]|engineer,test-dev,critic|complete|1
trio-owner-source-reruns-engineer|trio|standard|[{"n":1},{"t":1},{"verdict":"BLOCK","owner":"SOURCE"},{"n":2},{"verdict":"PASS"}]|engineer,test-dev,critic,engineer,critic|complete|2
trio-owner-tests-reruns-test-dev|trio|standard|[{"n":1},{"t":1},{"verdict":"BLOCK","owner":"TESTS"},{"t":2},{"verdict":"PASS"}]|engineer,test-dev,critic,test-dev,critic|complete|2
trio-no-owner-reruns-both|trio|standard|[{"n":1},{"t":1},{"verdict":"BLOCK"},{"n":2},{"t":2},{"verdict":"PASS"}]|engineer,test-dev,critic,engineer,test-dev,critic|complete|2
trio-pure-vibe-continues-past-round-3|trio|pure-vibe|[{"n":1},{"t":1},{"verdict":"BLOCK"},{"n":2},{"t":2},{"verdict":"BLOCK"},{"n":3},{"t":3},{"verdict":"BLOCK"},{"n":4},{"t":4},{"verdict":"PASS"}]|engineer,test-dev,critic,engineer,test-dev,critic,engineer,test-dev,critic,engineer,test-dev,critic|complete|4
CASES

  while IFS='|' read -r label kind responses labels; do
    [ -n "$label" ] || continue
    run_gate_loop "$kind" standard "$responses" || { record_case_failure "$label" "render failed output=$output"; continue; }
    expect_status "$label" 0
    expect_jq_output "$label-calls" ".agentCalls | map(.label) | join(\",\") == \"$labels\""
    expect_jq_output "$label-payload-keys" '.result | keys | sort | join(",") == "choices,context,decision,question,status"'
    expect_jq_output "$label-decision" '.result.status == "user_decision_required" and .result.decision == "workflow_gate_unresolved"'
    expect_jq_output "$label-context" '(.result.context | type) == "string" and .result.context == "round 3 findings"'
    expect_jq_output "$label-choices" '(.result.choices | length) >= 2 and (.result.choices | length) <= 4'
    expect_jq_output "$label-question" '.result.question | contains("Round 3")'
  done <<'CASES'
pair-asks-after-three-blocks|pair|[{"n":1},{"verdict":"BLOCK"},{"n":2},{"verdict":"BLOCK"},{"n":3},{"verdict":"BLOCK","findings":"round 3 findings"}]|engineer,critic,engineer,critic,engineer,critic
trio-asks-after-three-blocks|trio|[{"n":1},{"t":1},{"verdict":"BLOCK"},{"n":2},{"t":2},{"verdict":"BLOCK"},{"n":3},{"t":3},{"verdict":"BLOCK","findings":"round 3 findings"}]|engineer,test-dev,critic,engineer,test-dev,critic,engineer,test-dev,critic
CASES

  assert_no_case_failures
}
