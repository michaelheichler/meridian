isolation_external_prepare() {
  local policy="$1" pane
  isolation_tmux_repo
  jq -cn --arg policy "$policy" '{} | if $policy == "missing" then . else .tmux_execution.cleanup_policy=$policy end' > "$CONTROL_ROOT/config.json"
  SESSION="external-$RANDOM"
  tmux_on_test_server new-session -d -s "$SESSION" -c "$PROJECT_ROOT" \
    /usr/bin/env "PATH=$LBWC_TEST_CHILD_PATH" "$LBWC_TEST_CHILD_SHELL" --noprofile --norc -c 'exec sleep 600'
  pane=$(tmux_on_test_server display-message -p -t "$SESSION" '#{pane_id}')
  run env TMUX=private-test-server TMUX_PANE="$pane" PATH="$BIN_DIR:$PATH" TMUX_TMPDIR="$TMUX_TMPDIR" \
    bash "$ORCHESTRATOR" provision --project-root "$PROJECT_ROOT" --control-root "$CONTROL_ROOT" --main-id main-session
  isolation_success
  MAIN_CAPABILITY=$(jq -r '.main_capability' <<<"$output")
  DEFINITIONS=$(prepare_tmux_agents worker-a)
  split_group "$SESSION" "$DEFINITIONS"
  isolation_success
  AGENT_PANE=$(jq -r '.agents[0].tmux_pane_id' "$(registry_file)")
  AGENT_TARGET=$(jq -r '.agents[0].tmux_target' "$(registry_file)")
}

config_external_cleanup_row() {
  local policy="$1" before
  isolation_external_prepare "$policy"
  before=$(pane_ids "$SESSION")
  isolation_kill_session
  isolation_success
  isolation_shutdown_state
  tmux_on_test_server has-session -t "$SESSION"
  if [ "$policy" = keep_panes ]; then
    [ "$(pane_ids "$SESSION")" = "$before" ]
  else
    [ "$(pane_count "$SESSION")" = 1 ]
  fi
}

config_spawn_cwd_row() {
  local isolation="$1"
  isolation_tmux_prepare kill_on_complete "$isolation"
  [ ! -d "$WORKER_PATH" ]
  [ "$(tmux_on_test_server display-message -p -t "$AGENT_PANE" '#{pane_current_path}')" = "$(cd "$PROJECT_ROOT" && pwd -P)" ]
}

config_readonly_cwd_row() {
  local TMUX_FIXTURE_ROLE="$1"
  isolation_tmux_prepare kill_on_complete on
  [ ! -d "$WORKER_PATH" ]
  [ "$(tmux_on_test_server display-message -p -t "$AGENT_PANE" '#{pane_current_path}')" = "$(cd "$PROJECT_ROOT" && pwd -P)" ]
}

config_rollback_poll_row() {
  local mode="$1" before started elapsed
  isolation_tmux_repo
  provision_main
  SESSION=$(provisioned_session)
  DEFINITIONS=$(prepare_tmux_agents worker-a worker-b)
  before=$(bus_state_digest)
  export LBWC_TEST_PANE_DELAY="$TEST_ROOT/rollback-pane"
  export LBWC_TEST_PANE_DELAY_PROBES=3
  [ "$mode" != timeout ] || export LBWC_TEST_PANE_DELAY_PROBES=1000
  inject_failure send-keys
  started=$(date +%s)
  split_group "$SESSION" "$DEFINITIONS"
  elapsed=$(( $(date +%s) - started ))
  [ "$status" -ne 0 ]
  if [ "$mode" = timeout ]; then
    [ -n "$output" ]
    [ "$elapsed" -ge 3 ] && [ "$elapsed" -lt 25 ]
    [ "$(pane_count "$SESSION")" -gt 1 ]
  else
    [ "$(pane_count "$SESSION")" = 1 ]
  fi
  [ "$(bus_state_digest)" = "$before" ]
  clear_failures
  unset LBWC_TEST_PANE_DELAY LBWC_TEST_PANE_DELAY_PROBES
}
