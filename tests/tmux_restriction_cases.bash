restriction_snapshot() {
  jq -n --argjson value "$1" '{tmux_execution:{restrictions:{allow_agent_git:$value,allow_nested_spawn:$value,allow_agent_ask_user:$value}}}' > "$LBWC_PLANNING_DIR/phases/one/.runtime-snapshot.json"
}

restriction_input() {
  jq -cn --arg tool "$1" --arg command "${2:-}" '{tool_name:$tool,tool_input:{command:$command}}'
}

restriction_policy() {
  python3 -B "$PROJECT_ROOT/hooks/tmux_restrictions.py" <<< "$1"
}

restriction_git_rows() {
  local command expected
  restriction_snapshot false
  reset_case_failures
  while IFS='|' read -r expected command; do
    run restriction_policy "$(restriction_input Bash "$command")"
    expect_case "$command" "$expected"
  done < "$BATS_TEST_DIRNAME/tmux_restriction_git.rows"
  run restriction_policy "$(restriction_input Bash $'true\ngit commit')"
  expect_case newline-command 2
  assert_no_case_failures
}

restriction_guard() {
  bash "$SCRIPTS_DIR/$1.sh" <<< "$2"
}

restriction_bad_snapshot() {
  local kind=$1 path="$LBWC_PLANNING_DIR/phases/one/.runtime-snapshot.json"
  restriction_snapshot true
  case "$kind" in
    missing) rm "$path" ;;
    two) mkdir -p "$LBWC_PLANNING_DIR/phases/two"; cp "$path" "$LBWC_PLANNING_DIR/phases/two/.runtime-snapshot.json" ;;
    symlink) mv "$path" "$LBWC_PLANNING_DIR/saved.json"; ln -s "$LBWC_PLANNING_DIR/saved.json" "$path" ;;
    parent) mv "$LBWC_PLANNING_DIR/phases/one" "$LBWC_PLANNING_DIR/saved"; ln -s "$LBWC_PLANNING_DIR/saved" "$LBWC_PLANNING_DIR/phases/one" ;;
    string) restriction_snapshot '"true"' ;;
    integer) restriction_snapshot 1 ;;
    absent) printf '{}\n' > "$path" ;;
  esac
  restriction_invalid_snapshot_tools "$kind"
  rm -rf "$LBWC_PLANNING_DIR/phases" "$LBWC_PLANNING_DIR/saved" "$LBWC_PLANNING_DIR/saved.json"
  mkdir -p "$LBWC_PLANNING_DIR/phases/one"
}

restriction_invalid_snapshot_tools() {
  local kind=$1 tool key
  for tool in Agent Bash AskUserQuestion; do
    case "$tool" in
      Agent) key=allow_nested_spawn ;;
      Bash) key=allow_agent_git ;;
      AskUserQuestion) key=allow_agent_ask_user ;;
    esac
    run restriction_policy "$(restriction_input "$tool" 'git commit')"
    expect_case "$kind-$tool" 2 "tmux_execution.restrictions.$key"
    expect_case_absent "$kind-$tool-single-diagnostic" $'\n'
  done
}

restriction_wrapper_failure() {
  local guard=$1 code=$2
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/bash\nexit %s\n' "$code" > "$BATS_TEST_TMPDIR/bin/python3"
  chmod +x "$BATS_TEST_TMPDIR/bin/python3"
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash "$SCRIPTS_DIR/$guard.sh" <<< '{"tool_name":"Agent","tool_input":{}}'
  expect_case "$guard-policy-exit-$code" 2
}

restriction_imports() {
  local interpreter=python3
  [ ! -x /usr/bin/python3 ] || interpreter=/usr/bin/python3
  run "$interpreter" -B -c 'from hooks import tmux_restrictions, tmux_git_policy, user_question_guard'
  expect_case_silent python-compatibility 0
}

restriction_wrapper_rows() {
  local guard tool payload code
  for tool in Agent Task TaskCreate Workflow; do
    guard=agent-spawn-guard
    [ "$tool" != Workflow ] || guard=workflow-spawn-guard
    run restriction_guard "$guard" "$(restriction_input "$tool")"
    expect_case "nested-$tool" 2 'allow_nested_spawn=false'
  done
  for guard in bash-guard agent-spawn-guard workflow-spawn-guard; do
    for payload in '{' '[]' '{"tool_name":"Agent","tool_input":"invalid"}'; do
      run restriction_guard "$guard" "$payload"
      expect_case "$guard-$payload" 2
    done
    for code in 1 7 127; do
      restriction_wrapper_failure "$guard" "$code"
    done
  done
}

restriction_frozen_rows() {
  local value code tool opposite
  for value in true false; do
    restriction_snapshot "$value"
    opposite=true
    [ "$value" != true ] || opposite=false
    jq -n --argjson value "$opposite" '{tmux_execution:{restrictions:{allow_nested_spawn:$value,allow_agent_git:$value,allow_agent_ask_user:$value}}}' > "$LBWC_PLANNING_DIR/config.json"
    code=2
    [ "$value" != true ] || code=0
    for tool in Agent Bash AskUserQuestion; do
      run restriction_policy "$(restriction_input "$tool" 'git commit')"
      expect_case "frozen-$tool-$value" "$code"
    done
  done
}

restriction_scope_rows() {
  local kind tool guard payload baseline_status baseline_output
  for tool in Bash Agent Task TaskCreate Workflow Write AskUserQuestion; do
    case "$tool" in
      Bash) guard=bash-guard ;;
      Agent|Task|TaskCreate) guard=agent-spawn-guard ;;
      Workflow) guard=workflow-spawn-guard ;;
      Write) guard=file-guard ;;
      AskUserQuestion) guard=question ;;
    esac
    payload=$(restriction_input "$tool" 'echo safe')
    case "$tool" in
      Task) payload=$(jq '.tool_input.subagent_type="lbwc-unregistered"' <<< "$payload") ;;
      Write) payload=$(jq '.tool_input.file_path=".runtime-snapshot.json"' <<< "$payload") ;;
    esac
    run restriction_scope_call ordinary "$guard" "$payload"
    baseline_status=$status baseline_output=$output
    for kind in orchestrator ordinary no-tmux disabled; do
      run restriction_scope_call "$kind" "$guard" "$payload"
      expect_case_exact "scope-$tool-$kind" "$baseline_status" "$baseline_output"
    done
  done
}

restriction_scope_call() {
  local kind=$1 guard=$2 payload=$3
  local scope=() command=()
  case "$kind" in
    orchestrator) scope=(-u LBWC_TMUX_AGENT) ;;
    ordinary) scope=(-u LBWC_TMUX_AGENT -u TMUX -u TMUX_PANE) ;;
    no-tmux) scope=(-u TMUX) ;;
    disabled) scope=(LBWC_TMUX_AGENT=0) ;;
  esac
  case "$guard" in
    question) command=(python3 -B "$PROJECT_ROOT/hooks/user_question_guard.py" pretool) ;;
    *) command=(bash "$SCRIPTS_DIR/$guard.sh") ;;
  esac
  env "${scope[@]}" "${command[@]}" <<< "$payload"
}

restriction_policy_rows() {
  local kind payload
  reset_case_failures
  for kind in missing two symlink parent string integer absent; do
    restriction_bad_snapshot "$kind"
  done
  restriction_snapshot false
  restriction_wrapper_rows
  restriction_frozen_rows
  restriction_snapshot false
  run restriction_policy "$(restriction_input AskUserQuestion)"
  expect_case ask-bus-handoff 2 'orchestrator through the bus'
  restriction_scope_rows
  run restriction_guard bash-guard "$(restriction_input Bash 'echo changed > .runtime-snapshot.json')"
  expect_case snapshot-bash-write 2
  payload=$(jq -cn '{tool_name:"Write",tool_input:{file_path:".runtime-snapshot.json",content:"{}"}}')
  run restriction_guard file-guard "$payload"
  expect_case snapshot-write 2
  restriction_source_rows
  restriction_question_rows
  restriction_existing_guard_rows
  (cd "$PROJECT_ROOT" && restriction_imports)
  assert_no_case_failures
}

restriction_question_rows() {
  local payload
  payload=$(jq -cn --arg cwd "$PWD" '{cwd:$cwd,session_id:"question-worker",agent_id:"worker",tool_name:"AskUserQuestion",tool_input:{questions:[{header:"Review pace",question:"Which review pace should this project use?",options:[{label:"Fast",description:"Finish the review sooner."},{label:"Careful",description:"Check each change in detail."}]}]}}')
  restriction_snapshot false
  run python3 -B "$PROJECT_ROOT/hooks/user_question_guard.py" pretool <<< "$payload"
  expect_case question-denied 0 'orchestrator through the bus'
  restriction_snapshot true
  run python3 -B "$PROJECT_ROOT/hooks/user_question_guard.py" pretool <<< "$payload"
  expect_case_silent question-allowed 0
  payload=$(jq '.session_id="question-invalid" | .tool_input.questions=[]' <<< "$payload")
  run python3 -B "$PROJECT_ROOT/hooks/user_question_guard.py" pretool <<< "$payload"
  expect_case question-validation 0 'permissionDecision'
  run env -u LBWC_TMUX_AGENT python3 -B "$PROJECT_ROOT/hooks/user_question_guard.py" pretool <<< "$payload"
  expect_case ordinary-subagent-question 0 'reserved for the main session'
}

restriction_existing_guard_rows() {
  local tool guard
  restriction_snapshot true
  for tool in Agent Task TaskCreate Workflow; do
    guard=agent-spawn-guard
    [ "$tool" != Workflow ] || guard=workflow-spawn-guard
    run restriction_guard "$guard" "$(restriction_input "$tool")"
    expect_case_absent "existing-$tool" 'tmux_execution.restrictions'
    case "$tool" in
      Workflow) expect_case "existing-$tool" 2 'scriptPath' ;;
      *) expect_case "existing-$tool" 0 ;;
    esac
  done
  run restriction_guard bash-guard "$(restriction_input Bash 'git commit')"
  expect_case git-write-allowed 0
  jq '.agents.worker.role="scout"' "$LBWC_PLANNING_DIR/.agent-manifest.json" > "$BATS_TEST_TMPDIR/manifest-next"
  cp "$BATS_TEST_TMPDIR/manifest-next" "$LBWC_PLANNING_DIR/.agent-manifest.json"
  run restriction_guard bash-guard "$(restriction_input Bash 'git commit > result' | jq '.agent_id="worker"')"
  expect_case git-existing-role-guard 2 'read-only'
  expect_case_absent git-existing-role-guard 'tmux_execution.restrictions'
}

restriction_contract_wrappers() {
  local guard tool
  for guard in bash-guard agent-spawn-guard workflow-spawn-guard; do
    case "$guard" in
      bash-guard) tool=Bash ;;
      agent-spawn-guard) tool=Agent ;;
      workflow-spawn-guard) tool=Workflow ;;
    esac
    run restriction_guard "$guard" "$(restriction_input "$tool" 'git commit')"
    expect_case "contract-array-$guard" 2
  done
}

restriction_source_rows() {
  local source="$LBWC_PLANNING_DIR/phases/source/plan.md"
  mkdir -p "${source%/*}"
  restriction_snapshot true
  cp "$LBWC_PLANNING_DIR/phases/one/.runtime-snapshot.json" "${source%/*}/.runtime-snapshot.json"
  jq -n --arg source "$source" '{source_path:$source}' > "$LBWC_PLANNING_DIR/contract.json"
  jq -n --arg path "$LBWC_PLANNING_DIR/contract.json" '{agents:{worker:{contract_path:$path}}}' > "$LBWC_PLANNING_DIR/.agent-manifest.json"
  export LBWC_TMUX_AGENT_ID=worker
  run restriction_policy "$(restriction_input Task)"
  expect_case source-snapshot 0
  rm "${source%/*}/.runtime-snapshot.json"
  run restriction_policy "$(restriction_input Task)"
  expect_case source-no-fallback 2
  printf '[]\n' > "$LBWC_PLANNING_DIR/contract.json"
  run restriction_policy "$(restriction_input Task)"
  expect_case invalid-contract 2
  restriction_contract_wrappers
  printf '{}\n' > "$LBWC_PLANNING_DIR/contract.json"
  run restriction_policy "$(restriction_input Task)"
  expect_case command-single-phase 0
  cp "$LBWC_PLANNING_DIR/phases/one/.runtime-snapshot.json" "${source%/*}/.runtime-snapshot.json"
  run restriction_policy "$(restriction_input Task)"
  expect_case command-ambiguous-phase 2
  rm "${source%/*}/.runtime-snapshot.json"
  unset LBWC_TMUX_AGENT_ID
}
