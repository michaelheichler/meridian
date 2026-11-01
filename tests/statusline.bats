#!/usr/bin/env bats

load gate_case_helper
load gate_case_files

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  STATUSLINE="$REPO_ROOT/scripts/lbwc-statusline.sh"
  INSTALLER="$REPO_ROOT/scripts/statusline-install.sh"
  TEST_ROOT="$(mktemp -d)"
  PROJECT="$TEST_ROOT/project"
  BIN="$TEST_ROOT/bin"
  mkdir -p "$PROJECT/.lbwc-planning/.contracts/tasks" "$BIN"
  cat > "$BIN/git" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'branch --show-current'*) printf 'feature/status\n' ;;
  *'status --porcelain'*) printf ' M scripts/example.sh\n' ;;
  *'rev-parse --is-inside-work-tree'*) printf 'true\n' ;;
  *'rev-parse --path-format=absolute --git-dir'*)
    if [ "${LBWC_TEST_GIT_WORKTREE:-false}" = true ]; then
      printf '%s\n' "$PWD/.git/worktrees/agent"
    else
      printf '%s\n' "$PWD/.git"
    fi
    ;;
  *'rev-parse --path-format=absolute --git-common-dir'*) printf '%s\n' "$PWD/.git" ;;
esac
EOF
  chmod +x "$BIN/git"
  unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
  reset_case_failures
}

teardown() {
  rm -rf "$TEST_ROOT"
}

status_input() {
  jq -cn --arg project "$PROJECT" '{
    model:{display_name:"Claude Opus"}, effort:"high",
    workspace:{project_dir:$project},
    context_window:{used_percentage:42,current_usage:{input_tokens:1200,output_tokens:340,cache_creation_input_tokens:20,cache_read_input_tokens:800}},
    cost:{total_cost_usd:1.25,total_duration_ms:65000,total_lines_added:12,total_lines_removed:3},
    rate_limits:{five_hour:{used_percentage:25,resets_at:"2026-08-09T18:00:00Z"},seven_day:{used_percentage:60,resets_at:"2026-08-15T18:00:00Z"}}
  }'
}

minimal_input() {
  jq -cn --arg project "$PROJECT" '{model:{display_name:"Claude"},workspace:{project_dir:$project}}'
}

run_statusline() {
  local input=$1
  shift
  run env -u TMUX -u TMUX_PANE PATH="$BIN:$PATH" "$@" bash "$STATUSLINE" <<< "$input"
}

write_tmux_config() {
  local hide="$1" collapse="$2"
  jq -n \
    --argjson hide "$hide" \
    --argjson collapse "$collapse" \
    '{agent_execution_mode:"tmux",tmux_execution:{enabled:true,heartbeat_stale_seconds:120},statusline_hide_agent_in_tmux:$hide,statusline_collapse_agent_in_tmux:$collapse}' \
    > "$PROJECT/.lbwc-planning/config.json"
}

write_tmux_registry() {
  local state="$1" heartbeat="$2"
  local runtime="$PROJECT/.lbwc-planning/.runtime/tmux-bus"
  mkdir -p "$runtime"
  jq -n \
    --arg state "$state" \
    --argjson heartbeat "$heartbeat" \
    '{tmux:{session:"none"},agents:[{state:$state,heartbeat_at_ms:$heartbeat}]}' \
    > "$runtime/registry.json"
}

clear_tmux_runtime() {
  rm -rf "$PROJECT/.lbwc-planning/.runtime"
}

@test "statusline: renders every line from native input, orchestration state and an absent quota without writes" {
  mkdir -p "$PROJECT/.lbwc-planning/phases/10-status"
  cat > "$PROJECT/.lbwc-planning/.contracts/tasks/task.json" <<EOF
{"phase":"10"}
EOF
  cat > "$PROJECT/.lbwc-planning/.agent-manifest.json" <<EOF
{"agents":{"lbwc-python-engineer-a":{"state":"running","role":"python-engineer","pair_id":"pair-1","task_identity":"task-10","contract_path":"$PROJECT/.lbwc-planning/.contracts/tasks/task.json"},"lbwc-python-critic-b":{"state":"running","role":"python-critic","pair_id":"pair-1","task_identity":"task-10","contract_path":"$PROJECT/.lbwc-planning/.contracts/tasks/task.json"}}}
EOF
  printf '%s\n' '---' 'result: PASS' '---' > "$PROJECT/.lbwc-planning/phases/10-status/10-VERIFICATION.md"
  printf '%s\n' '---' 'status: complete' '---' > "$PROJECT/.lbwc-planning/phases/10-status/10-UAT.md"
  python3 "$REPO_ROOT/scripts/lib/session-telemetry.py" record --root "$PROJECT/.lbwc-planning" --event session_start --outcome success >/dev/null
  local before
  before=$(find "$PROJECT" -type f -exec cksum {} \; | sort)

  run_statusline "$(status_input)"
  expect_case full-native-input 0 "Claude Opus"
  expect_output_has full-native-input "feature/status"
  [[ "$output" == *"5h"*"25%"*"7d"*"60%"* ]] || record_case_failure full-native-input "quota line missing output=$output"
  [[ "$output" == *"phase 10"*"task task-10"*"pair 1 active"* ]] || record_case_failure full-native-input "flow line missing output=$output"
  [[ "$output" == *"QA PASS"*"UAT complete"*"Telemetry"*"1 events"* ]] || record_case_failure full-native-input "quality line missing output=$output"
  [ "$before" = "$(find "$PROJECT" -type f -exec cksum {} \; | sort)" ] \
    || record_case_failure full-native-input "statusline wrote files into the project"

  mkdir -p "$TEST_ROOT/bare/.lbwc-planning"
  run_statusline "$(jq -cn --arg project "$TEST_ROOT/bare" '{model:{display_name:"Claude"},workspace:{project_dir:$project}}')"
  expect_case no-rate-limits 0 "Telemetry"
  expect_output_lacks no-rate-limits "Quota"
  expect_output_has no-rate-limits "off"

  assert_no_case_failures
}

@test "statusline: hides the Quota line for the hide-limits switches and keeps it for unset, false or non-boolean values" {
  local config="$PROJECT/.lbwc-planning/config.json"

  printf '%s' '{"statusline_hide_limits":true}' > "$config"
  run_statusline "$(status_input)"
  expect_output_lacks hide-limits "Quota"

  printf '%s' '{"statusline_hide_limits_for_api_key":true}' > "$config"
  run_statusline "$(status_input)" ANTHROPIC_API_KEY=x
  expect_output_lacks api-key-flag-with-key "Quota"

  run_statusline "$(status_input)" ANTHROPIC_AUTH_TOKEN=x
  expect_output_lacks api-key-flag-with-auth-token "Quota"

  run_statusline "$(status_input)"
  expect_output_has api-key-flag-without-credentials "Quota"

  printf '%s' '{"statusline_hide_limits":true,"statusline_hide_limits_for_api_key":false}' > "$config"
  run_statusline "$(status_input)" ANTHROPIC_API_KEY=x
  expect_output_lacks hide-limits-beats-api-key-false "Quota"

  printf '%s' '{"statusline_hide_limits":"yes"}' > "$config"
  run_statusline "$(status_input)"
  expect_output_has non-boolean-hide-limits "Quota"

  rm -f "$config"
  run_statusline "$(status_input)"
  expect_output_has no-config "Quota"

  assert_no_case_failures
}

@test "statusline: summarizes healthy and failed agent runtime with diagnostics" {
  local runtime="$PROJECT/.lbwc-planning/.runtime/tmux-bus"
  mkdir -p "$runtime" "$runtime/locks" "$runtime/claims" "$runtime/transactions"
  printf '%s\n' '{"agent_execution_mode":"tmux","tmux_execution":{"enabled":true,"heartbeat_stale_seconds":120}}' > "$PROJECT/.lbwc-planning/config.json"
  jq -n '{
    schema_version: 2,
    main: {agent_id:"main-session",session_id:"main-session",role:"orchestrator",capability_hash:("0" * 64)},
    tmux: {session:"lbwc-main",orchestrator_target:"lbwc-main:0.0",orchestrator_pane:"0",topology:"detached-new-session",managed_session:true,ownership_token:"owned"},
    agents: [
      {agent_id:"agent-running",parent_id:"main-session",contract_id:"contract-running",generated_name:"running",tmux_target:"lbwc-main:0.1",claude_session_id:"session-running",capability_hash:("1" * 64),state:"running",heartbeat_at_ms:2000000000000},
      {agent_id:"agent-idle",parent_id:"main-session",contract_id:"contract-idle",generated_name:"idle",tmux_target:"lbwc-main:0.2",claude_session_id:"session-idle",capability_hash:("2" * 64),state:"idle",heartbeat_at_ms:2000000000000},
      {agent_id:"agent-failed",parent_id:"main-session",contract_id:"contract-failed",generated_name:"failed",tmux_target:"lbwc-main:0.3",claude_session_id:"session-failed",capability_hash:("3" * 64),state:"failed",heartbeat_at_ms:1}
    ],
    routes: {
      "main-session": {inbox:"main-session",tmux_target:"lbwc-main:0.0"},
      "agent-running": {inbox:"agent-running",tmux_target:"lbwc-main:0.1"},
      "agent-idle": {inbox:"agent-idle",tmux_target:"lbwc-main:0.2"},
      "agent-failed": {inbox:"agent-failed",tmux_target:"lbwc-main:0.3"}
    }
  }' > "$runtime/registry.json"
  chmod 600 "$runtime/registry.json"
  jq -n '{schema_version:1,routes:{
    "main-session":{agent_id:"main-session",session_id:"main-session",contract_id:null,inbox:"main-session",tmux_target:"lbwc-main:0.0"},
    "agent-running":{agent_id:"agent-running",session_id:"session-running",contract_id:"contract-running",inbox:"agent-running",tmux_target:"lbwc-main:0.1"},
    "agent-idle":{agent_id:"agent-idle",session_id:"session-idle",contract_id:"contract-idle",inbox:"agent-idle",tmux_target:"lbwc-main:0.2"},
    "agent-failed":{agent_id:"agent-failed",session_id:"session-failed",contract_id:"contract-failed",inbox:"agent-failed",tmux_target:"lbwc-main:0.3"}
  }}' > "$runtime/routing-table.json"
  chmod 600 "$runtime/routing-table.json"
  jq -n '{pid:999999,acquired_at_ms:1,lease_ms:1}' > "$runtime/locks/stale.lock.owner.json"
  mkdir -p "$runtime/locks/stale.lock"
  mv "$runtime/locks/stale.lock.owner.json" "$runtime/locks/stale.lock/owner.json"
  chmod 600 "$runtime/locks/stale.lock/owner.json"
  cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  has-session) exit 0 ;;
  list-panes) printf '%s\n' '0' '1' '2' '3' ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$BIN/tmux"

  run timeout 10 env PATH="$BIN:$PATH" TMUX=1 bash "$STATUSLINE" <<< "$(minimal_input)"
  expect_case runtime-summary 0 "Backend tmux"
  expect_output_has runtime-summary "session lbwc-main up"
  expect_output_has runtime-summary "panes 4/4"
  [[ "$output" == *"agents 3"*"running:1"*"idle:1"*"failed:1"* ]] || record_case_failure runtime-summary "agent counts missing output=$output"
  [[ "$output" == *"stale 1"*"failed 1"* ]] || record_case_failure runtime-summary "stale and failed totals missing output=$output"
  [[ "$output" == *"Diagnostics"*"stale lock"* ]] || record_case_failure runtime-summary "stale lock diagnostic missing output=$output"

  assert_no_case_failures
}

@test "statusline: applies the hide, collapse and malformed tmux switches and the workflow backend" {
  write_tmux_config true false
  write_tmux_registry running 2000000000000
  run_statusline "$(minimal_input)" TMUX=1
  expect_case hide-agent-in-tmux 0 "Backend tmux"
  expect_output_lacks hide-agent-in-tmux "Flow"
  [[ "$output" == *"Context"*"Quality"* ]] || record_case_failure hide-agent-in-tmux "context and quality lines missing output=$output"
  expect_output_has hide-agent-in-tmux "agents 1 running:1 idle:0 failed:0"

  write_tmux_config false true
  write_tmux_registry failed 1
  run_statusline "$(minimal_input)" LBWC_TEST_GIT_WORKTREE=true TMUX=1
  expect_case collapse-agent-in-worktree 0 "Diagnostics failed agent"
  [[ "$output" == *"LBWC"*"TMUX agents 1 running:0 idle:0 failed:1"* ]] || record_case_failure collapse-agent-in-worktree "collapsed line missing output=$output"
  expect_output_lacks collapse-agent-in-worktree "Context"
  expect_output_lacks collapse-agent-in-worktree "Flow"
  expect_output_lacks collapse-agent-in-worktree "Quality"
  expect_output_lacks collapse-agent-in-worktree "Backend"

  write_tmux_config true true
  write_tmux_registry running 2000000000000
  run_statusline "$(minimal_input)" LBWC_TEST_GIT_WORKTREE=true TMUX=1
  expect_case collapse-beats-hide 0 "TMUX agents 1 running:1 idle:0 failed:0"
  expect_output_lacks collapse-beats-hide "Context"
  expect_output_lacks collapse-beats-hide "Flow"
  expect_output_lacks collapse-beats-hide "Quality"

  write_tmux_config true true
  write_tmux_registry failed 1
  run_statusline "$(minimal_input)" LBWC_TEST_GIT_WORKTREE=true
  [[ "$output" == *"Context"*"Flow"*"Quality"* ]] || record_case_failure outside-tmux "standard lines missing output=$output"
  expect_case outside-tmux 0 ""
  expect_output_lacks outside-tmux "Backend"
  expect_output_lacks outside-tmux "TMUX"
  expect_output_lacks outside-tmux "Diagnostics"

  printf '%s\n' '{"agent_execution_mode":"tmux","statusline_hide_agent_in_tmux":"true","statusline_collapse_agent_in_tmux":false}' > "$PROJECT/.lbwc-planning/config.json"
  write_tmux_registry failed 1
  run_statusline "$(minimal_input)" TMUX=1
  expect_case malformed-settings-fail-closed 0 "Flow"
  expect_output_has malformed-settings-fail-closed "Backend invalid"
  expect_output_has malformed-settings-fail-closed "Diagnostics configuration drift"

  printf '%s\n' '{"agent_execution_mode":"workflow","workflow_execution":{"enabled":true}}' > "$PROJECT/.lbwc-planning/config.json"
  clear_tmux_runtime
  run_statusline "$(minimal_input)" TMUX=1
  expect_case workflow-backend 0 "Backend workflow"
  expect_output_lacks workflow-backend "Backend invalid"
  expect_output_lacks workflow-backend "Diagnostics"

  assert_no_case_failures
}

@test "statusline-install: refuses without confirmation, replacement approval, valid arguments or valid settings" {
  local settings="$TEST_ROOT/settings.json"
  printf '%s\n' '{"statusLine":{"type":"command","command":"other-status"}}' > "$settings"

  run bash "$INSTALLER" --settings "$settings"
  expect_case no-confirmation 2 "statusline_install=confirmation_required"

  run bash "$INSTALLER" --settings "$settings" --yes
  expect_case no-replace-approval 2 "statusline_install=replacement_confirmation_required"
  [ "$(jq -r '.statusLine.command' "$settings")" = "other-status" ] \
    || record_case_failure no-replace-approval "foreign statusline was overwritten"
  [ ! -e "${settings}.lbwc-statusline.bak" ] \
    || record_case_failure no-replace-approval "backup written for a refused install"

  run bash "$INSTALLER" --settings "$settings" --bogus
  expect_case unknown-argument 2 "Usage: statusline-install.sh"

  run bash "$INSTALLER" --settings
  expect_case settings-flag-without-path 2 "Usage: statusline-install.sh"

  printf '%s\n' '[1,2]' > "$settings"
  run bash "$INSTALLER" --settings "$settings" --yes
  expect_case settings-not-an-object 2 "statusline_install=settings_malformed"

  assert_no_case_failures
}

@test "statusline-install: writes the command object with a fifteen second refresh and a backup" {
  local settings="$TEST_ROOT/settings.json" fresh="$TEST_ROOT/nested/fresh.json" own="$TEST_ROOT/own.json"

  printf '{}\n' > "$settings"
  run bash "$INSTALLER" --settings "$settings" --yes
  expect_case empty-settings 0 "statusline_install=installed refresh_interval=15"
  expect_jq empty-settings "$settings" '.statusLine.type == "command" and .statusLine.refreshInterval == 15'
  expect_jq empty-settings "$settings" '.statusLine.command | contains("lbwc-statusline.sh")'
  expect_path empty-settings "${settings}.lbwc-statusline.bak"

  printf '%s\n' '{"statusLine":{"type":"command","command":"other-status"}}' > "$settings"
  run bash "$INSTALLER" --settings "$settings" --yes --replace
  expect_case replace-foreign 0 "statusline_install=installed"
  expect_jq replace-foreign "$settings" '.statusLine.command | contains("lbwc-statusline.sh")'
  expect_jq replace-foreign "$settings" '.statusLine.refreshInterval == 15'
  expect_jq replace-foreign "${settings}.lbwc-statusline.bak" '.statusLine.command == "other-status"'

  run bash "$INSTALLER" --settings "$fresh" --yes
  expect_case missing-settings-file 0 "statusline_install=installed"
  expect_jq missing-settings-file "$fresh" '.statusLine.refreshInterval == 15'

  printf '%s\n' '{"statusLine":{"type":"command","command":"bash /old/lbwc-statusline.sh"}}' > "$own"
  run bash "$INSTALLER" --settings "$own" --yes
  expect_case reinstall-own-statusline 0 "statusline_install=installed"
  expect_jq reinstall-own-statusline "$own" '.statusLine.command | contains("lbwc-statusline.sh") and (contains("/old/") | not)'

  assert_no_case_failures
}
