isolation_success() {
  [ "$status" -eq 0 ] || { printf 'command failed with %s\n%s\n' "$status" "$output" >&2; return 1; }
}

config_isolation_row() {
  local kind="${1%%,*}" row="${1#*,}"
  local SESSION DEFINITIONS AGENT_PANE AGENT_TARGET WORKER_PATH MAIN_CAPABILITY
  set -E
  trap 'printf "failed command %s\noutput %s\n" "$BASH_COMMAND" "$output" >&2' ERR
  "config_${kind}_row" "$row"
}

isolation_tmux_repo() {
  cd "$PROJECT_ROOT"
  git init -q
  await_git_ai
  git -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m fixture
  await_git_ai
}

isolation_tmux_prepare() {
  local policy="$1" isolation="$2" workers=worker-a
  [ "${3:-}" != distinct ] || workers='worker-a worker-b'
  isolation_tmux_repo
  jq -cn --arg policy "$policy" --arg isolation "$isolation" '
    {} | if $policy == "missing" then . else .tmux_execution.cleanup_policy=$policy end
    | if $isolation == "missing" then . else .worktree_isolation=$isolation end' > "$CONTROL_ROOT/config.json"
  provision_main
  SESSION=$(provisioned_session)
  DEFINITIONS=$(prepare_tmux_agents $workers)
  split_group "$SESSION" "$DEFINITIONS"
  isolation_success
  AGENT_PANE=$(jq -r '.agents[0].tmux_pane_id' "$(registry_file)")
  AGENT_TARGET=$(jq -r '.agents[0].tmux_target' "$(registry_file)")
  WORKER_PATH="$CONTROL_ROOT/.runtime/worker-worktrees/worker-a"
}

isolation_kill_agent() {
  run_orchestrator kill-agent --project-root "$PROJECT_ROOT" --control-root "$CONTROL_ROOT" --target "$AGENT_TARGET"
}

isolation_kill_session() {
  run_orchestrator kill-session --project-root "$PROJECT_ROOT" --control-root "$CONTROL_ROOT" --session "$SESSION"
}

isolation_shutdown_state() {
  jq -e '.agents[] | select(.agent_id == "worker-a") | .state == "shutdown" and .tmux_pane_id == null' "$(registry_file)"
  jq -e '.routes | has("worker-a") | not' "$(routing_file)"
  [ ! -e "$CONTROL_ROOT/.runtime/tmux-bus/inboxes/worker-a" ]
  [ -z "$(find "$CONTROL_ROOT/.runtime/tmux-bus/locks" -name '*.lock' -print)" ]
}

config_cleanup_row() {
  local policy action before
  IFS=',' read -r policy action <<<"$1"
  isolation_tmux_prepare "$policy" off
  before=$(pane_ids "$SESSION")
  case "$action" in
    agent) isolation_kill_agent ;;
    session) isolation_kill_session ;;
  esac
  isolation_success
  isolation_shutdown_state
  if [ "$policy" = keep_panes ]; then
    [ "$(pane_ids "$SESSION")" = "$before" ]
  else
    run tmux_on_test_server list-panes -a -F '#{pane_id}'
    [[ $'\n'"$output"$'\n' != *$'\n'"$AGENT_PANE"$'\n'* ]]
  fi
}

config_kept_row() {
  isolation_tmux_prepare keep_panes on
  "kept_$1"
}

kept_agent_retry() {
  local before
  isolation_kill_agent
  isolation_success
  before=$(bus_state_digest)
  isolation_kill_agent
  isolation_success
  [ "$(bus_state_digest)" = "$before" ]
  [ "$(tmux_on_test_server display-message -p -t "$AGENT_PANE" '#{pane_id}')" = "$AGENT_PANE" ]
  [ -d "$WORKER_PATH" ]
}

kept_session_retry() {
  local before
  isolation_kill_session
  isolation_success
  before=$(bus_state_digest)
  isolation_kill_session
  isolation_success
  [ "$(bus_state_digest)" = "$before" ]
  tmux_on_test_server has-session -t "$SESSION"
}

isolation_reprovision() {
  run_orchestrator provision --project-root "$PROJECT_ROOT" --control-root "$CONTROL_ROOT" --main-id main-session \
    --orchestrator-id main-session --orchestrator-session-id main-session --orchestrator-capability "$MAIN_CAPABILITY"
  isolation_success
}

kept_reuse() {
  local old_session="$SESSION"
  isolation_kill_session
  isolation_success
  isolation_reprovision
  SESSION=$(provisioned_session)
  [ "$SESSION" = "$old_session-next" ]
  jq -e --arg session "$SESSION" '.routes | (keys == ["main-session"]) and (.["main-session"].tmux_target | startswith($session + ":"))' "$(registry_file)"
  isolation_kill_session
  isolation_success
  isolation_reprovision
  [ "$(provisioned_session)" = "$old_session-next-next" ]
}

kept_active() {
  tmux_on_test_server set-option -t "$SESSION" @lbwc_kept_panes true
  provision_attempt
  [ "$status" -ne 0 ]
  [[ "$output" == *'active agents'* ]]
}

config_worktree_row() {
  local kind="$1" branch head
  isolation_tmux_prepare kill_on_complete on "$kind"
  branch=$(git -C "$WORKER_PATH" symbolic-ref --short HEAD)
  head=$(git -C "$PROJECT_ROOT" rev-parse HEAD)
  case "$kind" in
    distinct) worktree_distinct; return ;;
    dirty) printf '%s\n' valuable > "$WORKER_PATH/uncommitted.txt" ;;
    detached) git -C "$WORKER_PATH" checkout -q --detach ;;
    ahead) git -C "$WORKER_PATH" -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m worker ;;
    unreferenced) worktree_unreferenced_setup ;;
    missing) rm -rf "$WORKER_PATH" ;;
  esac
  isolation_kill_agent
  isolation_success
  isolation_shutdown_state
  "worktree_$kind"
}

worktree_distinct() {
  local second_pane
  second_pane=$(jq -r '.agents[] | select(.agent_id == "worker-b") | .tmux_pane_id' "$(registry_file)")
  [ "$(tmux_on_test_server display-message -p -t "$second_pane" '#{pane_current_path}')" = "$(cd "$CONTROL_ROOT/.runtime/worker-worktrees/worker-b" && pwd -P)" ]
  [ "$(git -C "$WORKER_PATH" rev-parse HEAD)" = "$head" ]
  [ "$(git -C "$CONTROL_ROOT/.runtime/worker-worktrees/worker-b" rev-parse HEAD)" = "$head" ]
  [ "$(tmux_on_test_server display-message -p -t "$AGENT_PANE" '#{pane_current_path}')" = "$(cd "$WORKER_PATH" && pwd -P)" ]
  [ "$(git -C "$WORKER_PATH" symbolic-ref HEAD)" != "$(git -C "$CONTROL_ROOT/.runtime/worker-worktrees/worker-b" symbolic-ref HEAD)" ]
}

worktree_dirty() {
  [ "$(cat "$WORKER_PATH/uncommitted.txt")" = valuable ]
}

worktree_detached() {
  [ -d "$WORKER_PATH" ]
}

worktree_ahead() {
  [ ! -d "$WORKER_PATH" ]
  [[ "$output" == *"$branch"* ]]
  [ "$(git -C "$PROJECT_ROOT" rev-list --count "$head..$branch")" = 1 ]
}

worktree_clean() {
  [ ! -d "$WORKER_PATH" ]
  git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/heads/$branch"
  run git -C "$PROJECT_ROOT" worktree list --porcelain
  [[ "$output" != *"$WORKER_PATH"* ]]
}
worktree_missing() { worktree_clean; }

worktree_unreferenced_setup() {
  git -C "$WORKER_PATH" -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m unreferenced
  git -C "$WORKER_PATH" update-ref refs/isolated/worker HEAD
  git -C "$WORKER_PATH" symbolic-ref HEAD refs/isolated/worker
  git -C "$PROJECT_ROOT" update-ref "refs/heads/$branch" "$head"
}

worktree_unreferenced() {
  [ -d "$WORKER_PATH" ]
  [ "$(git -C "$WORKER_PATH" rev-list --count "$head..HEAD")" = 1 ]
}

config_isolation_rollback_row() {
  local failure="$1" before
  isolation_tmux_repo
  printf '%s\n' '{"worktree_isolation":"on"}' > "$CONTROL_ROOT/config.json"
  provision_main
  SESSION=$(provisioned_session)
  DEFINITIONS=$(prepare_tmux_agents worker-a worker-b)
  before=$(bus_state_digest)
  inject_failure "$failure"
  split_group "$SESSION" "$DEFINITIONS"
  [ "$status" -ne 0 ]
  clear_failures
  [ "$(bus_state_digest)" = "$before" ]
  [ "$(pane_count "$SESSION")" = 1 ]
  [ ! -d "$CONTROL_ROOT/.runtime/worker-worktrees/worker-a" ]
  git -C "$PROJECT_ROOT" show-ref --verify --quiet refs/heads/lbwc-worker/worker-a
}

config_poll_row() {
  local kind="$1" started elapsed
  isolation_tmux_prepare kill_on_complete off
  rm -f "$TEST_ROOT/delayed-pane" "$TEST_ROOT/delayed-pane.count"
  export LBWC_TEST_PANE_DELAY="$TEST_ROOT/delayed-pane"
  export LBWC_TEST_PANE_DELAY_PROBES=3
  case "$kind" in
    absent) tmux_on_test_server kill-pane -t "$AGENT_PANE" ;;
    timeout) export LBWC_TEST_PANE_DELAY_PROBES=1000 ;;
  esac
  started=$(date +%s)
  isolation_kill_agent
  elapsed=$(( $(date +%s) - started ))
  if [ "$kind" = timeout ]; then
    poll_timeout
  else
    isolation_success
    isolation_shutdown_state
    [ "$kind" != absent ] || [ ! -e "$LBWC_TEST_PANE_DELAY.count" ]
  fi
  unset LBWC_TEST_PANE_DELAY LBWC_TEST_PANE_DELAY_PROBES
}

poll_timeout() {
  [ "$status" -ne 0 ]
  [ -n "$output" ]
  [ "$elapsed" -ge 3 ] && [ "$elapsed" -lt 12 ]
  jq -e '.state == "prepared"' "$CONTROL_ROOT/.runtime/tmux-bus/transactions/teardown-worker-a.json"
  jq -e '.agents[] | select(.agent_id == "worker-a") | .state != "shutdown"' "$(registry_file)"
  unset LBWC_TEST_PANE_DELAY LBWC_TEST_PANE_DELAY_PROBES
  isolation_kill_agent
  isolation_success
  isolation_shutdown_state
}

config_invalid_cleanup_row() {
  local action="$1"
  if [ "$action" = provision ]; then
    printf '%s\n' '{"tmux_execution":{"cleanup_policy":"invalid"}}' > "$CONTROL_ROOT/config.json"
    provision_attempt
    [ "$status" -ne 0 ]
    [[ "$output" == *cleanup_policy* ]]
    return
  fi
  isolation_tmux_prepare kill_on_complete off
  printf '%s\n' '{"tmux_execution":{"cleanup_policy":"invalid"}}' > "$CONTROL_ROOT/config.json"
  case "$action" in
    agent) isolation_kill_agent ;;
    session) isolation_kill_session ;;
    status) run_orchestrator status --project-root "$PROJECT_ROOT" --control-root "$CONTROL_ROOT" ;;
    rollback) run_orchestrator rollback --project-root "$PROJECT_ROOT" --control-root "$CONTROL_ROOT" --run-id invalid-policy ;;
  esac
  [[ "$output" == *cleanup_policy* ]]
  case "$action" in
    status|rollback) [ "$status" -eq 0 ]; [[ "$output" == *warning* ]] ;;
    *) [ "$status" -ne 0 ] ;;
  esac
}
