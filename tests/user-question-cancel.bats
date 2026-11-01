#!/usr/bin/env bats

load test_helper
load gate_case_helper
load gate_case_files

setup() {
  setup_temp_dir
  PLANNING="$TEST_TEMP_DIR/.lbwc-planning"
  QUESTION_TEXT="Which review pace should this project use?"
  reset_case_failures
}

teardown() {
  teardown_temp_dir
}

run_guard() {
  local mode=$1 payload=$2
  run bash -c 'cd "$1" && python3 -m hooks.user_question_guard "$2"' _ "$PROJECT_ROOT" "$mode" <<< "$payload"
}

read_state() {
  run bash -c 'cd "$1" && python3 -m hooks.user_question_guard decision-read state "$2" "$3"' _ "$PROJECT_ROOT" "$PLANNING" "$1"
}

question_json() {
  jq -cn --arg cwd "$TEST_TEMP_DIR" --arg session "$1" '{
    session_id:$session,
    cwd:$cwd,
    tool_name:"AskUserQuestion",
    tool_input:{
      questions:[{
        header:"Review pace",
        question:"Which review pace should this project use?",
        options:[
          {label:"Fast", description:"Finish the review sooner."},
          {label:"Careful", description:"Check each change in detail."}
        ]
      }]
    }
  }'
}

tool_json() {
  jq -cn --arg cwd "$TEST_TEMP_DIR" --arg session "$1" --arg tool "$2" \
    '{session_id:$session, cwd:$cwd, tool_name:$tool, tool_input:{subagent_type:"qa"}}'
}

stop_json() {
  jq -cn --arg cwd "$TEST_TEMP_DIR" --arg session "$1" '{session_id:$session, cwd:$cwd}'
}

open_question() {
  run_guard pretool "$(question_json "$1")"
}

@test "user_question_guard blocks orchestration and mutation while a decision is pending and resumes once it is killed, stopped or answered" {
  open_question pend
  expect_case_silent open-question 0

  run_guard pretool "$(tool_json pend Agent)"
  expect_case pending-blocks-agent 0 "A user decision is pending"
  expect_output_has pending-blocks-agent "orchestration"

  run_guard pretool "$(tool_json pend Bash)"
  expect_case pending-blocks-mutation 0 "A user decision is pending"

  run_guard pretool "$(tool_json pend Read)"
  expect_case_silent pending-allows-inspection 0

  run_guard pretool "$(question_json agent-asker | jq -c '. + {agent_type:"qa"}')"
  expect_case subagent-cannot-ask 0 "reserved for the main session"

  run_guard pretool "$(tool_json 'bad session!' Agent)"
  expect_case invalid-session-id 0 "A valid session id is required"

  open_question killed
  run_guard posttool "$(question_json killed | jq -c '.tool_input = {} | .is_error = true')"
  expect_case_silent killed-question 0
  read_state killed
  expect_case killed-question-state 0 "cancelled"
  run_guard pretool "$(tool_json killed Agent)"
  expect_case_silent killed-question-resumes 0

  open_question stopped
  run_guard stop "$(stop_json stopped)"
  expect_case_silent stop-cancels-pending 0
  run_guard pretool "$(tool_json stopped Agent)"
  expect_case_silent stop-then-agent-allowed 0
  run_guard stop "$(stop_json stopped)"
  expect_case_silent second-stop-allowed 0
  run_guard pretool "$(tool_json stopped Agent)"
  expect_case_silent second-agent-allowed 0

  open_question answered
  run_guard posttool "$(question_json answered | jq -c --arg q "$QUESTION_TEXT" '.tool_response = {answers:{($q):"Fast"}}')"
  expect_case_silent answered-question 0
  read_state answered
  expect_case answered-question-state 0 "resolved"
  run_guard pretool "$(tool_json answered Agent)"
  expect_case_silent answered-question-resumes 0

  assert_no_case_failures
}

@test "question guard hook registration: the PreToolUse matcher covers Agent, Skill and SendMessage" {
  local matcher
  matcher=$(jq -r '.hooks.PreToolUse[0].matcher' "$PROJECT_ROOT/hooks/hooks.json")
  [[ "$matcher" == *Agent* ]] || record_case_failure matcher-agent "matcher=$matcher"
  [[ "$matcher" == *Skill* ]] || record_case_failure matcher-skill "matcher=$matcher"
  [[ "$matcher" == *SendMessage* ]] || record_case_failure matcher-sendmessage "matcher=$matcher"
  assert_no_case_failures
}
