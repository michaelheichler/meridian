#!/usr/bin/env bats

load gate_case_helper

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/render-workflow-template.sh"
  OUT_DIR=$(mktemp -d)
  ADVERSARIAL_JOB=$'evil "job" with \\ backslash\nnewline `backtick` ${evil} and */ close-comment @@JOB@@'
  reset_case_failures
}

teardown() {
  rm -rf "$OUT_DIR"
}

HARNESS="$BATS_TEST_DIRNAME/fixtures/workflow-harness.cjs"

render_pair() {
  local autonomy="$1" job="${2:-job}"
  run bash "$SCRIPT" pair NAME=probe-pair DESCRIPTION=desc \
    "JOB=$job" TASK_ID=task-2 "AUTONOMY=$autonomy" \
    ENGINEER_AGENT_TYPE=meridian-eng-a ENGINEER_MODEL=sonnet ENGINEER_EFFORT=balanced \
    CRITIC_AGENT_TYPE=meridian-crit-a CRITIC_MODEL=sonnet CRITIC_EFFORT=fast
}

render_trio() {
  local autonomy="$1" job="${2:-job}"
  run bash "$SCRIPT" trio NAME=probe-trio DESCRIPTION=desc \
    "JOB=$job" TASK_ID=task-3 "AUTONOMY=$autonomy" \
    ENGINEER_AGENT_TYPE=meridian-eng-a ENGINEER_MODEL=sonnet ENGINEER_EFFORT=balanced \
    CRITIC_AGENT_TYPE=meridian-crit-a CRITIC_MODEL=sonnet CRITIC_EFFORT=fast \
    TESTDEV_AGENT_TYPE=meridian-td-a TESTDEV_MODEL=sonnet TESTDEV_EFFORT=fast
}

run_workflow() {
  local rendered_file="$1" responses_json="$2"
  run node "$HARNESS" "$rendered_file" "$responses_json"
}

make_script_fixture() {
  fixture_dir=$(mktemp -d)
  mkdir -p "$fixture_dir/scripts/lib" "$fixture_dir/templates/workflows"
  cp "$SCRIPT" "$fixture_dir/scripts/render-workflow-template.sh"
}

wrap_body_for_syntax_check() {
  local file="$1" wrapped="${1}.syntax-check.mjs"
  { printf '(async () => {\n'; tail -n +2 "$file"; printf '})\n'; } > "$wrapped"
  printf '%s\n' "$wrapped"
}

assert_rendered_js_valid() {
  local file="$1" meta_line meta_expr wrapped
  command -v node >/dev/null 2>&1 || skip "node is unavailable"

  meta_line=$(head -n1 "$file")
  meta_expr=${meta_line#"export const meta = "}
  meta_expr=${meta_expr%";"}
  run jq -e . <<< "$meta_expr"
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output"
    return 1
  fi

  wrapped=$(wrap_body_for_syntax_check "$file")
  run node --check --input-type=module - < "$wrapped"
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output"
    return 1
  fi
}

agent_labels() {
  jq -r '.agentCalls | map(.label) | join(",")' <<< "$output"
}

meta_phases() {
  local first_line meta_json
  first_line=$(head -n1 "$1")
  meta_json=${first_line#"export const meta = "}
  meta_json=${meta_json%";"}
  jq -r '.phases | join(",")' <<< "$meta_json"
}

decode_const() {
  local file="$1" name="$2"
  node -e '
    const fs = require("fs");
    const src = fs.readFileSync(process.argv[1], "utf8");
    const re = new RegExp("^const " + process.argv[2] + " = (\".*\");$", "m");
    const match = re.exec(src);
    if (!match) { process.exit(1); }
    process.stdout.write(JSON.parse(match[1]));
  ' "$file" "$name"
}

render_solo() {
  run bash "$SCRIPT" solo NAME=probe DESCRIPTION=desc \
    "JOB=$1" TASK_ID=task-1 ROLE=scout AGENT_TYPE=meridian-scout-a MODEL=sonnet EFFORT=balanced
}

expect_eq() {
  [ "$2" = "$3" ] || record_case_failure "$1" "got=[$2] want=[$3]"
}

expect_fragment_in_output() {
  [[ "$output" == *"$2"* ]] || record_case_failure "$1" "missing fragment=[$2] output=$output"
}

expect_call_field() {
  expect_eq "$1" "$(jq -r "$2" <<< "$output")" "$3"
}

expect_file_fragment() {
  [[ "$(cat "$2")" == *"$3"* ]] || record_case_failure "$1" "file $2 lacks fragment=[$3]"
}

expect_valid_js() {
  assert_rendered_js_valid "$2" >/dev/null || record_case_failure "$1" "rendered file $2 is not valid JavaScript"
}

save_render() {
  expect_case "$1-render" 0 ""
  printf '%s' "$output" > "$OUT_DIR/$1.mjs"
}

render_fixture_template() {
  make_script_fixture
  printf '%b' "$1" > "$fixture_dir/templates/workflows/solo.js.tpl"
  run bash "$fixture_dir/scripts/render-workflow-template.sh" solo NAME=probe DESCRIPTION=desc \
    JOB=job TASK_ID=task-1 ROLE=scout AGENT_TYPE=meridian-scout-a MODEL=sonnet EFFORT=balanced
  rm -rf "$fixture_dir"
}

@test "solo template renders valid JavaScript, attaches the qa schema only for qa, and omits unresolved effort" {
  command -v node >/dev/null 2>&1 || skip "node is unavailable"

  render_solo "$ADVERSARIAL_JOB"
  save_render adversarial
  [[ "$output" != *$'\x1f'* ]] || record_case_failure adversarial-no-unit-separator "output carries a unit separator"
  [[ "$(head -n1 "$OUT_DIR/adversarial.mjs")" == "export const meta = "*";" ]] || record_case_failure adversarial-meta-line "first line is not the meta export"
  expect_eq adversarial-phases "$(meta_phases "$OUT_DIR/adversarial.mjs")" Execute
  expect_valid_js adversarial-valid-js "$OUT_DIR/adversarial.mjs"
  expect_eq adversarial-job-round-trips "$(decode_const "$OUT_DIR/adversarial.mjs" JOB)" "$ADVERSARIAL_JOB"
  run_workflow "$OUT_DIR/adversarial.mjs" '["ok"]'
  expect_case adversarial-runs 0 ""
  expect_eq adversarial-labels "$(agent_labels)" scout
  expect_call_field adversarial-no-schema '.agentCalls[0].hasSchema' false
  expect_call_field adversarial-complete '.result.status' complete

  render_solo "simple job"
  save_render scout
  run_workflow "$OUT_DIR/scout.mjs" '["ok"]'
  expect_case scout-runs 0 ""
  expect_call_field scout-no-schema '.agentCalls[0].hasSchema' false
  expect_call_field scout-passes-effort '.agentCalls[0].hasEffort' true

  run bash "$SCRIPT" solo NAME=probe DESCRIPTION=desc \
    JOB=job TASK_ID=task-1 ROLE=qa AGENT_TYPE=meridian-qa-a MODEL=sonnet EFFORT=balanced
  save_render qa
  run_workflow "$OUT_DIR/qa.mjs" '[{"result":"PASS"}]'
  expect_case qa-runs 0 ""
  expect_call_field qa-has-schema '.agentCalls[0].hasSchema' true

  run bash "$SCRIPT" solo NAME=probe DESCRIPTION=desc \
    JOB=job TASK_ID=task-1 ROLE=scout AGENT_TYPE=meridian-scout-a MODEL=sonnet EFFORT=
  save_render no-effort
  expect_file_fragment no-effort-null-const "$OUT_DIR/no-effort.mjs" "const EFFORT = null;"
  expect_valid_js no-effort-valid-js "$OUT_DIR/no-effort.mjs"
  run_workflow "$OUT_DIR/no-effort.mjs" '["ok"]'
  expect_case no-effort-runs 0 ""
  expect_call_field no-effort-omitted '.agentCalls[0].hasEffort' false

  render_solo "simple job"
  printf '%s\n' "$output" > "$OUT_DIR/corrupt.js"
  printf 'function (((;\n' >> "$OUT_DIR/corrupt.js"
  run assert_rendered_js_valid "$OUT_DIR/corrupt.js"
  [ "$status" -ne 0 ] || record_case_failure corrupt-body-rejected "syntax check accepted a corrupted body"
  expect_fragment_in_output corrupt-body-reports-syntax-error SyntaxError

  assert_no_case_failures
}

@test "pair template renders valid JavaScript with both phases and omits both efforts when unresolved" {
  command -v node >/dev/null 2>&1 || skip "node is unavailable"

  render_pair standard "$ADVERSARIAL_JOB"
  save_render pair
  expect_eq pair-phases "$(meta_phases "$OUT_DIR/pair.mjs")" "Implement,Review"
  expect_valid_js pair-valid-js "$OUT_DIR/pair.mjs"
  run_workflow "$OUT_DIR/pair.mjs" '[{"n":1},{"verdict":"PASS"}]'
  expect_case pair-runs 0 ""
  expect_eq pair-labels "$(agent_labels)" "engineer,critic"
  expect_call_field pair-critic-schema '.agentCalls[1].hasSchema' true
  expect_call_field pair-complete '.result.status' complete
  expect_call_field pair-round '.result.round' 1

  run bash "$SCRIPT" pair NAME=probe-pair DESCRIPTION=desc \
    JOB=job TASK_ID=task-2 AUTONOMY=standard \
    ENGINEER_AGENT_TYPE=meridian-eng-a ENGINEER_MODEL=sonnet ENGINEER_EFFORT= \
    CRITIC_AGENT_TYPE=meridian-crit-a CRITIC_MODEL=sonnet CRITIC_EFFORT=
  save_render pair-no-effort
  expect_file_fragment pair-engineer-null-const "$OUT_DIR/pair-no-effort.mjs" "const ENGINEER_EFFORT = null;"
  expect_file_fragment pair-critic-null-const "$OUT_DIR/pair-no-effort.mjs" "const CRITIC_EFFORT = null;"
  expect_valid_js pair-no-effort-valid-js "$OUT_DIR/pair-no-effort.mjs"
  run_workflow "$OUT_DIR/pair-no-effort.mjs" '[{"n":1},{"verdict":"PASS"}]'
  expect_case pair-no-effort-runs 0 ""
  expect_call_field pair-engineer-effort-omitted '.agentCalls[0].hasEffort' false
  expect_call_field pair-critic-effort-omitted '.agentCalls[1].hasEffort' false

  assert_no_case_failures
}

@test "trio template renders valid JavaScript with all phase titles and runs the adversarial job" {
  command -v node >/dev/null 2>&1 || skip "node is unavailable"

  render_trio pure-vibe "$ADVERSARIAL_JOB"
  save_render trio
  expect_eq trio-phases "$(meta_phases "$OUT_DIR/trio.mjs")" "Implement,Build Tests,Verify"
  expect_valid_js trio-valid-js "$OUT_DIR/trio.mjs"
  expect_eq trio-job-round-trips "$(decode_const "$OUT_DIR/trio.mjs" JOB)" "$ADVERSARIAL_JOB"
  run_workflow "$OUT_DIR/trio.mjs" '[{"n":1},{"t":1},{"verdict":"PASS"}]'
  expect_case trio-runs 0 ""
  expect_eq trio-labels "$(agent_labels)" "engineer,test-dev,critic"
  expect_call_field trio-critic-schema '.agentCalls[2].hasSchema' true
  expect_call_field trio-complete '.result.status' complete

  assert_no_case_failures
}

@test "the renderer rejects bad shapes, fields and templates, and renders literal markers deterministically" {
  local first

  run bash "$SCRIPT" solo NAME=probe DESCRIPTION=desc \
    JOB=job TASK_ID=task-1 ROLE=scout AGENT_TYPE=meridian-scout-a MODEL=sonnet
  expect_case solo-missing-effort 1 "missing required field EFFORT"

  run bash "$SCRIPT" pair NAME=probe-pair DESCRIPTION=desc \
    JOB=job TASK_ID=task-2 AUTONOMY=standard \
    ENGINEER_AGENT_TYPE=meridian-eng-a ENGINEER_MODEL=sonnet ENGINEER_EFFORT=balanced \
    CRITIC_AGENT_TYPE=meridian-crit-a CRITIC_MODEL=sonnet
  expect_case pair-missing-critic-effort 1 "missing required field CRITIC_EFFORT"

  run bash "$SCRIPT" quad NAME=probe DESCRIPTION=desc
  expect_case unknown-shape 1 "unknown shape"

  run bash "$SCRIPT" solo NAME=probe DESCRIPTION=desc \
    JOB=job TASK_ID=task-1 ROLE=scout AGENT_TYPE=meridian-scout-a MODEL=sonnet EFFORT=balanced \
    TASKID=task-1
  expect_case unknown-field 1 "unknown field 'TASKID'"

  render_fixture_template 'const JOB = @@JOB@@;\nconst TASK_ID = @@TASK_ID@@;\nconst ROLE = @@ROLE@@;\nconst AGENT_TYPE = @@AGENT_TYPE@@;\nconst MODEL = @@MODEL@@;\nconst EFFORT = @@EFFORT@@;\n'
  expect_case no-phase-calls 1 ""
  expect_eq no-phase-calls-message "$output" "render-workflow-template: template 'solo' declares no phase(\"...\") calls"

  render_fixture_template 'const JOB = @@JOB@@;\nconst TASK_ID = @@TASK_ID@@;\nconst ROLE = @@ROLE@@;\nconst AGENT_TYPE = @@AGENT_TYPE@@;\nconst MODEL = @@MODEL@@;\nconst EFFORT = @@EFFORT@@;\nconst STRAY = @@UNDECLARED_MARKER@@;\n\nawait phase("Execute");\n\nreturn { status: "complete" };\n'
  expect_case undeclared-marker 1 ""
  expect_eq undeclared-marker-message "$output" "render-workflow-template: unresolved template token"

  render_solo 'plain text containing @@TASK_ID@@ literally'
  expect_case literal-marker-in-job 0 '@@TASK_ID@@ literally'

  render_trio confident
  expect_case first-render 0 ""
  first="$output"
  render_trio confident
  expect_case second-render 0 ""
  expect_eq identical-invocations-identical-bytes "$output" "$first"

  assert_no_case_failures
}

@test "committed workflow templates carry no single-quoted strings" {
  local single_quote template_dir="$BATS_TEST_DIRNAME/../templates/workflows"
  single_quote=$(printf '\047')
  run find "$template_dir" -name '*.js.tpl' -exec grep -lF "$single_quote" {} +
  [ "$status" -eq 1 ] || { printf 'single quotes in %s\n' "$output" >&2; return 1; }
}
