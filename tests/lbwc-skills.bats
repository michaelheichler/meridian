#!/usr/bin/env bats

load test_helper
load gate_case_helper
load rejection_case_helper
load doc_fragment_helper

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  REAL_SCRIPT="$REPO_ROOT/scripts/lbwc-skills.sh"
  TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/lbwc-skills.XXXXXX")
  PLUGIN_ROOT="$TEST_ROOT/plugin"
  PROJECT_ROOT="$TEST_ROOT/project"
  PLANNING_DIR="$PROJECT_ROOT/.lbwc-planning"
  DETECTOR_RESPONSE="$TEST_ROOT/detector.json"
  DETECTOR_TRACE="$TEST_ROOT/detector.trace"
  mkdir -p "$PLUGIN_ROOT/scripts" "$PLANNING_DIR"
  if [ -f "$REAL_SCRIPT" ]; then
    copy_script_with_libs "$REAL_SCRIPT" "$PLUGIN_ROOT/scripts/lbwc-skills.sh"
  fi
  SCRIPT="$PLUGIN_ROOT/scripts/lbwc-skills.sh"
  reset_skills_fixture
  reset_case_failures
}

teardown() {
  rm -rf "$TEST_ROOT"
}

reset_skills_fixture() {
  rm -f "$PLUGIN_ROOT/scripts/detect-stack.sh" "$PLANNING_DIR/config.json"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'printf "%s\n" "$1" >> "$LBWC_DETECTOR_TRACE"' \
    'cat "$LBWC_DETECTOR_RESPONSE"' \
    > "$PLUGIN_ROOT/scripts/detect-stack.sh"
  chmod +x "$PLUGIN_ROOT/scripts/detect-stack.sh"
  write_config true false true
  write_detector '[]' '[]' '[]' '[]' '[]'
}

write_config() {
  local suggestions="$1" auto_install="$2" questions="$3"
  jq -n \
    --argjson suggestions "$suggestions" \
    --argjson auto_install "$auto_install" \
    --argjson questions "$questions" '
      {
        skill_suggestions: $suggestions,
        auto_install_skills: $auto_install,
        discovery_questions: $questions
      }
    ' > "$PLANNING_DIR/config.json"
}

write_detector() {
  local stack="$1" global="$2" project="$3" recommended="$4" suggestions="$5"
  jq -n \
    --argjson stack "$stack" \
    --argjson global "$global" \
    --argjson project "$project" \
    --argjson recommended "$recommended" \
    --argjson suggestions "$suggestions" '
      {
        detected_stack: $stack,
        installed: {global: $global, project: $project},
        recommended_skills: $recommended,
        suggestions: $suggestions,
        global_skills_dir: "/fixture/global/skills"
      }
    ' > "$DETECTOR_RESPONSE"
}

run_skills() {
  rm -f "$DETECTOR_TRACE"
  run env \
    LBWC_DETECTOR_RESPONSE="$DETECTOR_RESPONSE" \
    LBWC_DETECTOR_TRACE="$DETECTOR_TRACE" \
    bash "$SCRIPT" "$@"
}

expect_output_jq() {
  local label="$1" program="$2"
  jq -e "$program" <<< "$output" >/dev/null \
    || record_case_failure "$label" "output did not satisfy: $program output=$output"
}

expect_lacks() {
  local label="$1" fragment="$2"
  [[ "$output" != *"$fragment"* ]] \
    || record_case_failure "$label" "unexpected fragment=[$fragment] output=$output"
}

expect_trace_root() {
  local label="$1" want
  want=$(cd -P "$PROJECT_ROOT" && pwd -P)
  [ "$(cat "$DETECTOR_TRACE")" = "$want" ] \
    || record_case_failure "$label" "detector saw [$(cat "$DETECTOR_TRACE")] want [$want]"
}

discovery_row() {
  local label="$1" program="$2"
  shift 2
  run_skills --json "$@"
  expect_case "$label" 0
  expect_output_jq "$label" "$program"
}

fail_closed_row() {
  local label="$1" fragment="$2"
  run_skills --json list "$PROJECT_ROOT"
  expect_rejected "$label" "$fragment"
  reset_skills_fixture
}

@test "discovery selects the question mode and a stable candidate order and fails closed on invalid inputs or symbolic links" {
  local empty_result linked_project="$TEST_ROOT/project-link"
  empty_result='{"candidate_count":0,"candidates":[],"config":{"auto_install_skills":false,"discovery_questions":true,"skill_suggestions":true},"detected_stack":[],"installed":{"global":[],"project":[]},"operation":"list","question_mode":"none","schema_version":1}'

  run_skills --json list "$PROJECT_ROOT"
  expect_case empty-discovery 0
  [ "$output" = "$empty_result" ] || record_case_failure empty-discovery "unexpected output=$output"
  expect_trace_root empty-discovery

  write_detector '["python"]' '[]' '[]' '["skill-z"]' '["skill-z"]'
  discovery_row single-candidate \
    '.candidate_count == 1 and .question_mode == "single" and .candidates == ["skill-z"]' \
    list "$PROJECT_ROOT"

  write_detector '["typescript"]' '[]' '[]' '["skill-c","skill-a","skill-b"]' '["skill-c","skill-a","skill-b","skill-a"]'
  discovery_row bounded-candidates '
    .operation == "refresh"
    and .candidate_count == 3
    and .question_mode == "bounded"
    and .candidates == ["skill-a","skill-b","skill-c"]
  ' refresh "$PROJECT_ROOT"
  [ "$output" = "$(jq -cS . <<< "$output")" ] \
    || record_case_failure bounded-candidates "output is not compact sorted JSON"

  write_detector '["rust"]' '[]' '[]' '[]' '["skill-5","skill-2","skill-1","skill-4","skill-3"]'
  discovery_row freeform-candidates '
    .candidate_count == 5
    and .question_mode == "freeform"
    and .candidates == ["skill-1","skill-2","skill-3","skill-4","skill-5"]
  ' list "$PROJECT_ROOT"

  write_config false true false
  write_detector '["go"]' '["global-skill"]' '["project-skill"]' '["skill-a"]' '["skill-a"]'
  discovery_row disabled-discovery '
    .config == {auto_install_skills: true, discovery_questions: false, skill_suggestions: false}
    and .detected_stack == ["go"]
    and .installed.global == ["global-skill"]
    and .installed.project == ["project-skill"]
    and .candidates == []
    and .candidate_count == 0
    and .question_mode == "disabled"
  ' list "$PROJECT_ROOT"

  write_config true false true
  write_detector '["python"]' '[]' '[]' '[]' '["lint-python","python-tests","rust-tests"]'
  discovery_row search-filters-candidates '
    .operation == "search"
    and .query == "PYTHON"
    and .candidates == ["lint-python","python-tests"]
    and .candidate_count == 2
    and .question_mode == "bounded"
  ' search "$PROJECT_ROOT" 'PYTHON'

  ln -s "$PROJECT_ROOT" "$linked_project"
  run_skills --json list "$linked_project"
  expect_case symbolic-project-argument 0
  expect_trace_root symbolic-project-argument
  reset_skills_fixture

  printf '%s\n' '{"suggestions":"not-an-array"}' > "$DETECTOR_RESPONSE"
  fail_closed_row malformed-detector-output 'detector output is not a valid LBWC stack result'

  printf '%s\n' '{' > "$PLANNING_DIR/config.json"
  fail_closed_row invalid-json-configuration 'skill discovery configuration is invalid'

  printf '%s\n' '[]' > "$PLANNING_DIR/config.json"
  fail_closed_row non-object-configuration 'skill discovery configuration is invalid'

  printf '%s\n' '{"skill_suggestions":"yes"}' > "$PLANNING_DIR/config.json"
  fail_closed_row non-boolean-setting 'skill discovery configuration is invalid'

  mv "$PLANNING_DIR/config.json" "$TEST_ROOT/external-config.json"
  ln -s "$TEST_ROOT/external-config.json" "$PLANNING_DIR/config.json"
  fail_closed_row symbolic-link-configuration 'configuration must not be a symbolic link'

  rm "$PLANNING_DIR/config.json"
  ln -s "$TEST_ROOT/missing-config.json" "$PLANNING_DIR/config.json"
  fail_closed_row dangling-symbolic-link-configuration 'configuration must not be a symbolic link'

  mv "$PLUGIN_ROOT/scripts/detect-stack.sh" "$TEST_ROOT/external-detector.sh"
  ln -s "$TEST_ROOT/external-detector.sh" "$PLUGIN_ROOT/scripts/detect-stack.sh"
  fail_closed_row symbolic-link-detector 'stack detector must not be a symbolic link'

  assert_no_case_failures
}

@test "human output explains disabled settings and escapes control and table characters" {
  write_config false false true
  write_detector '["go"]' '[]' '[]' '[]' '["skill-a"]'
  run_skills list "$PROJECT_ROOT"
  expect_case suggestions-disabled 0 'Skill suggestions are disabled. No installation decision is requested.'
  expect_lacks suggestions-disabled 'Discovery questions are disabled.'

  write_config true false false
  run_skills list "$PROJECT_ROOT"
  expect_case questions-disabled 0 'Discovery questions are disabled. No installation decision is requested.'
  expect_lacks questions-disabled 'Skill suggestions are disabled.'

  write_config true false true
  write_detector '["letter-u"]' '[]' '[]' '[]' '["safe|name","letter-u","\u001b]0;owned\u0007"]'
  run_skills list "$PROJECT_ROOT"
  expect_case control-and-table-characters 0 '| Detected stack | letter-u |'
  expect_fragment control-and-table-characters '| 2 | letter-u |'
  expect_fragment control-and-table-characters '| 3 | safe\|name |'
  expect_fragment control-and-table-characters '| 1 | ?]0;owned? |'
  expect_lacks control-and-table-characters $'\e'
  expect_lacks control-and-table-characters $'\a'

  write_detector '["line\nbreak","carriage\rreturn"]' '[]' '[]' '[]' '["line\nbreak","carriage\rreturn"]'
  run_skills list "$PROJECT_ROOT"
  expect_case embedded-line-breaks 0 'carriage?return'
  expect_fragment embedded-line-breaks 'line?break'
  expect_lacks embedded-line-breaks $'carriage\rreturn'
  expect_lacks embedded-line-breaks $'line\nbreak'

  assert_no_case_failures
}

@test "install validates the candidate and refuses noninteractive mutation" {
  write_detector '["python"]' '[]' '[]' '["safe-skill"]' '["safe-skill"]'
  run_skills --json install "$PROJECT_ROOT" safe-skill
  expect_rejected blocked-install ""
  [ "$output" = '{"candidate":"safe-skill","operation":"install","reason":"external_installation_not_authorized","status":"blocked"}' ] \
    || record_case_failure blocked-install "unexpected output=$output"
  [ ! -e "$PROJECT_ROOT/.claude/skills" ] || record_case_failure blocked-install "skills directory was created"

  write_detector '["python"]' '[]' '[]' '[]' '["safe-skill"]'
  run_skills --json install "$PROJECT_ROOT" other-skill
  expect_rejected undiscovered-candidate 'skill is not an exact discovered candidate: other-skill'
  [ ! -e "$PROJECT_ROOT/.claude/skills" ] || record_case_failure undiscovered-candidate "skills directory was created"

  assert_no_case_failures
}

@test "the skills command keeps installation consent in the main session and declares no name, network tool, subagent tool or direct installer" {
  local command_file="$REPO_ROOT/commands/skills.md"

  while IFS='|' read -r label fragment; do
    [ -n "$label" ] || continue
    expect_doc_has "$label" "$command_file" "$fragment"
  done <<'FRAGMENTS'
supporting-category|category: supporting
allowed-tools-block|allowed-tools:
read-tool|  - Read
question-tool|  - AskUserQuestion
helper-script-tool|  - Bash("${CLAUDE_PLUGIN_ROOT}/scripts/lbwc-skills.sh" *)
main-session-only|main session only
subagent-prohibition|A generated agent or subagent must not run this flow
category-is-metadata|`category` is LBWC project metadata
options-heading|Options:
skip-all-option|1. Skip all
show-table-option|2. Show the table again
native-other-option|Use native Other to type comma-separated numbers
FRAGMENTS

  run awk 'NR == 1 {next} /^---$/ {exit} /^name:/' "$command_file"
  expect_case frontmatter-has-no-name 0
  [ -z "$output" ] || record_case_failure frontmatter-has-no-name "name entry found: $output"

  run grep -E 'npx skills add|allowed-tools:.*(WebFetch|WebSearch|Agent)|bash "\$\{CLAUDE_PLUGIN_ROOT\}/scripts/lbwc-skills\.sh"|\.vbw-planning' "$command_file"
  [ "$status" -ne 0 ] || record_case_failure forbidden-patterns "forbidden pattern present: $output"

  assert_no_case_failures
}
