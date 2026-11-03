tmux_worker_directory() {
  local worker_id="$1" worker_manifest worker_role worker_path worker_definition worker_digest base_commit
  if ! worktree_isolation_enabled "$TMUX_RUNTIME_CONTROL_ROOT"; then
    printf '%s\n' "$PROJECT_ROOT"
    return 0
  fi
  worker_manifest=$(agent_manifest_path "$TMUX_RUNTIME_CONTROL_ROOT") || return 1
  worker_role=$(jq -er --arg id "$worker_id" '.agents[$id].role' "$worker_manifest") || return 1
  if ! worker_may_write_code "$worker_role"; then
    printf '%s\n' "$PROJECT_ROOT"
    return 0
  fi
  worker_path="$TMUX_RUNTIME_ROOT/worker-worktrees/$worker_id"
  worker_definition="$PROJECT_ROOT/.claude/agents/$worker_id.md"
  worker_digest=$(shasum -a 256 "$worker_definition" | cut -d ' ' -f 1) || return 1
  mkdir -p "$TMUX_RUNTIME_ROOT/worker-worktrees" || return 1
  base_commit=$(git -C "$PROJECT_ROOT" rev-parse HEAD) || return 1
  git -C "$PROJECT_ROOT" worktree add -b "meridian-worker/$worker_id" "$worker_path" "$base_commit" >&2 || return 1
  if ! tmux_runtime_atomic_json "$TMUX_RUNTIME_BUS_ROOT/worktrees/$worker_id.json" "$(jq -cn --arg path "$worker_path" --arg digest "$worker_digest" --arg base "$base_commit" '{path:$path,definition_digest:$digest,base_commit:$base}')"; then
    git -C "$PROJECT_ROOT" worktree remove "$worker_path" >&2 || true
    return 1
  fi
  mkdir -p "$worker_path/.claude/agents" && cp "$worker_definition" "$worker_path/.claude/agents/$worker_id.md" || return 1
  printf '%s\n' "$worker_path"
}

record_worker_pane() {
  local worker_id="$1" pane_id="$2" record
  [ -e "$TMUX_RUNTIME_BUS_ROOT/worktrees/$worker_id.json" ] || return 0
  record=$(tmux_runtime_helper read-json --root "$TMUX_RUNTIME_BUS_ROOT" --source "worktrees/$worker_id.json") || return 1
  record=$(jq --arg pane_id "$pane_id" '.pane_id = $pane_id' <<<"$record") || return 1
  tmux_runtime_atomic_json "$TMUX_RUNTIME_BUS_ROOT/worktrees/$worker_id.json" "$record"
}

remove_worker_definition() {
  local worker_id="$1" worker_path="$2" expected_digest="$3" actual_digest definition
  definition="$worker_path/.claude/agents/$worker_id.md"
  [ -f "$definition" ] && [ ! -L "$definition" ] || return 0
  actual_digest=$(shasum -a 256 "$definition" | cut -d ' ' -f 1) || return 1
  [ "$actual_digest" = "$expected_digest" ] || return 0
  rm -f "$definition" || return 1
  rmdir "$worker_path/.claude/agents" "$worker_path/.claude" 2>/dev/null || true
}

worker_commits_need_retention() {
  local _wcr_path="$1" _wcr_out="$2" _wcr_status=0 _wcr_branch _wcr_unreachable
  printf -v "$_wcr_out" '%s' false
  _wcr_branch=$(git -C "$_wcr_path" symbolic-ref -q HEAD) || _wcr_status=$?
  case "$_wcr_status" in
    0) ;;
    1)
      printf 'tmux detached HEAD worktree retained: %s\n' "$_wcr_path" >&2
      printf -v "$_wcr_out" '%s' true
      return 0
      ;;
    *) return 1 ;;
  esac
  _wcr_unreachable=$(git -C "$_wcr_path" rev-list HEAD --not --branches) || return 1
  if [ -n "$_wcr_unreachable" ]; then
    printf 'tmux worktree retained with unreferenced commits: %s\n' "$_wcr_path" >&2
    printf -v "$_wcr_out" '%s' true
  fi
}

report_worker_branch() {
  local worker_id="$1" record="$2" base_commit branch_name ahead_count
  branch_name="meridian-worker/$worker_id"
  git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/heads/$branch_name" || return 0
  base_commit=$(jq -r '.base_commit // empty' <<<"$record") || return 1
  if [ -z "$base_commit" ]; then
    printf 'tmux worker branch retained, base unavailable: %s\n' "$branch_name" >&2
    return 0
  fi
  ahead_count=$(git -C "$PROJECT_ROOT" rev-list --count "$base_commit..refs/heads/$branch_name") || return 1
  if [ "$ahead_count" -gt 0 ]; then
    printf 'tmux worker branch retained with %s commits: %s\n' "$ahead_count" "$branch_name" >&2
  fi
}

remove_stopped_worker_worktree() {
  local worker_id="$1" worker_path="$2" record="$3" dirty retain_commits
  worker_commits_need_retention "$worker_path" retain_commits || return 1
  [ "$retain_commits" = false ] || return 0
  remove_worker_definition "$worker_id" "$worker_path" "$(jq -er '.definition_digest' <<<"$record")" || return 1
  dirty=$(git -C "$worker_path" status --porcelain --untracked-files=all) || return 1
  if [ -n "$dirty" ]; then
    printf 'tmux dirty worktree retained: %s\n' "$worker_path" >&2
    return 0
  fi
  git -C "$PROJECT_ROOT" worktree remove "$worker_path" >&2 || return 1
  report_worker_branch "$worker_id" "$record" || return 1
  rm -f "$TMUX_RUNTIME_BUS_ROOT/worktrees/$worker_id.json"
}

cleanup_worker_worktree() {
  local worker_id="$1" preserve="$2" record worker_path expected_path pane_id
  [ -e "$TMUX_RUNTIME_BUS_ROOT/worktrees/$worker_id.json" ] || return 0
  record=$(tmux_runtime_helper read-json --root "$TMUX_RUNTIME_BUS_ROOT" --source "worktrees/$worker_id.json") || return 1
  worker_path=$(jq -er '.path' <<<"$record") || return 1
  expected_path="$TMUX_RUNTIME_ROOT/worker-worktrees/$worker_id"
  [ "$worker_path" = "$expected_path" ] && [ ! -L "$worker_path" ] || return 1
  if [ ! -e "$worker_path" ]; then
    git -C "$PROJECT_ROOT" worktree prune || return 1
    report_worker_branch "$worker_id" "$record" || return 1
    rm -f "$TMUX_RUNTIME_BUS_ROOT/worktrees/$worker_id.json"
    return 0
  fi
  [ -d "$worker_path" ] || return 1
  pane_id=$(jq -r '.pane_id // empty' <<<"$record") || return 1
  if [ -n "$pane_id" ] && tmux_pane_exists "$pane_id"; then preserve=true; fi
  if [ "$preserve" = true ]; then
    printf 'tmux worktree retained for open panes: %s\n' "$worker_path" >&2
    return 0
  fi
  remove_stopped_worker_worktree "$worker_id" "$worker_path" "$record"
}
