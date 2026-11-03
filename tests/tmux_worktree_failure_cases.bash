config_definition_copy_row() {
  local before
  isolation_tmux_repo
  printf '%s\n' collision > "$PROJECT_ROOT/.claude"
  git -C "$PROJECT_ROOT" add .claude
  git -C "$PROJECT_ROOT" -c user.name=Fixture -c user.email=fixture@example.invalid commit -q -m collision
  await_git_ai
  rm "$PROJECT_ROOT/.claude"
  printf '%s\n' '{"worktree_isolation":"on"}' > "$CONTROL_ROOT/config.json"
  provision_main
  SESSION=$(provisioned_session)
  DEFINITIONS=$(prepare_tmux_agents worker-a)
  before=$(bus_state_digest)
  split_group "$SESSION" "$DEFINITIONS"
  [ "$status" -ne 0 ]
  [ "$(bus_state_digest)" = "$before" ]
  [ "$(pane_count "$SESSION")" = 1 ]
  [ ! -d "$CONTROL_ROOT/.runtime/worker-worktrees/worker-a" ]
  git -C "$PROJECT_ROOT" show-ref --verify --quiet refs/heads/lbwc-worker/worker-a
}

config_worktree_record_row() {
  local before record="$CONTROL_ROOT/.runtime/tmux-bus/worktrees/worker-a.json"
  isolation_tmux_repo
  printf '%s\n' '{"worktree_isolation":"on"}' > "$CONTROL_ROOT/config.json"
  provision_main
  SESSION=$(provisioned_session)
  DEFINITIONS=$(prepare_tmux_agents worker-a)
  mkdir -p "$record"
  chmod 700 "${record%/*}" "$record"
  before=$(bus_state_digest)
  split_group "$SESSION" "$DEFINITIONS"
  [ "$status" -ne 0 ]
  [ "$(bus_state_digest)" = "$before" ]
  [ "$(pane_count "$SESSION")" = 1 ]
  [ ! -d "$CONTROL_ROOT/.runtime/worker-worktrees/worker-a" ]
  git -C "$PROJECT_ROOT" show-ref --verify --quiet refs/heads/lbwc-worker/worker-a
}

config_existing_branch_row() {
  local before branch=lbwc-worker/worker-a
  isolation_tmux_repo
  git -C "$PROJECT_ROOT" branch "$branch"
  before=$(git -C "$PROJECT_ROOT" rev-parse "$branch")
  printf '%s\n' '{"worktree_isolation":"on"}' > "$CONTROL_ROOT/config.json"
  provision_main
  SESSION=$(provisioned_session)
  DEFINITIONS=$(prepare_tmux_agents worker-a)
  split_group "$SESSION" "$DEFINITIONS"
  [ "$status" -ne 0 ]
  [ ! -d "$CONTROL_ROOT/.runtime/worker-worktrees/worker-a" ]
  [ "$(git -C "$PROJECT_ROOT" rev-parse "$branch")" = "$before" ]
  [ "$(pane_count "$SESSION")" = 1 ]
}
