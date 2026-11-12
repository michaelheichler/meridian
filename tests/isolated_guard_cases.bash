isolated_guard_fixture() {
  local layout="$1" root="$TEST_TEMP_DIR" branch="guard-$RANDOM"
  create_test_config
  build_contract_worker ok
  git init -q "$root"
  await_git_ai
  git -C "$root" -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m fixture
  GUARD_CONTROL_ROOT="$root/.meridian"
  [ "$layout" != policy ] || build_root_capability_worker
  case "$layout" in
    primary) WORKER_ROOT="$root"; return 0 ;;
    temporary)
      GUARD_CONTROL_ROOT="$root/.temporary-agent-runfiles/runs/isolated"
      mkdir -p "$GUARD_CONTROL_ROOT"
      cp -R "$root/.meridian/." "$GUARD_CONTROL_ROOT/"
      WORKER_ROOT="$GUARD_CONTROL_ROOT/.runtime/worker-worktrees/dev-1"
      ;;
    native) WORKER_ROOT="$root/.claude/worktrees/native" ;;
    other) WORKER_ROOT="$GUARD_CONTROL_ROOT/.runtime/worker-worktrees/other" ;;
    project-runtime) WORKER_ROOT="$root/.runtime/worker-worktrees/dev-1" ;;
    nested) WORKER_ROOT="$root/.claude/worktrees/native/nested" ;;
    evil) WORKER_ROOT="$root/.claude/worktrees-evil/native" ;;
    *) WORKER_ROOT="$GUARD_CONTROL_ROOT/.runtime/worker-worktrees/dev-1" ;;
  esac
  git -C "$root" worktree add -q -b "$branch" "$WORKER_ROOT" HEAD
  await_git_ai
  mkdir -p "$WORKER_ROOT/src"
  WORKER_ROOT=$(cd "$WORKER_ROOT" && pwd -P)
}

isolated_guard_call() {
  local path="$1"
  payload tool_name=Write "tool_input.file_path=$path" agent_id=dev-1 "cwd=$WORKER_ROOT" \
    | MERIDIAN_CONTROL_ROOT="$GUARD_CONTROL_ROOT" bash "$SCRIPTS_DIR/file-guard.sh"
}

isolated_guard_allow() {
  isolated_guard_fixture "$1"
  local path=src/allowed.py
  [ "${2:-relative}" != absolute ] || path="$WORKER_ROOT/$path"
  run isolated_guard_call "$path"
  expect_status "$1" 0
  expect_output_empty "$1"
}

guard_primary() { isolated_guard_allow primary; }
guard_planning_relative() { isolated_guard_allow planning; }
guard_planning_absolute() { isolated_guard_allow planning absolute; }
guard_temporary_relative() { isolated_guard_allow temporary; }
guard_temporary_absolute() { isolated_guard_allow temporary absolute; }
guard_native_relative() { isolated_guard_allow native; }
guard_native_absolute() { isolated_guard_allow native absolute; }

isolated_guard_deny_root() {
  isolated_guard_fixture "$1"
  run isolated_guard_call src/allowed.py
  expect_status "$1" 2
  expect_output_has "$1" 'primary workspace'
}
guard_other_worker() { isolated_guard_deny_root other; }
guard_project_runtime() { isolated_guard_deny_root project-runtime; }
guard_nested_root() { isolated_guard_deny_root nested; }
guard_prefix_root() { isolated_guard_deny_root evil; }

isolated_guard_unlisted() {
  isolated_guard_fixture planning
  local original="$WORKER_ROOT"
  WORKER_ROOT="$TEST_TEMP_DIR/.claude/worktrees/copied"
  mkdir -p "$WORKER_ROOT/src"
  cp "$original/.git" "$WORKER_ROOT/.git"
  run isolated_guard_call src/allowed.py
  expect_status copied-git 2
  expect_output_has copied-git 'primary workspace'
}
guard_copied_git() { isolated_guard_unlisted; }

guard_pruned() {
  isolated_guard_fixture native
  local saved="$TEST_TEMP_DIR/saved-git"
  cp "$WORKER_ROOT/.git" "$saved"
  rm -rf "$WORKER_ROOT"
  git -C "$TEST_TEMP_DIR" worktree prune
  mkdir -p "$WORKER_ROOT/src"
  cp "$saved" "$WORKER_ROOT/.git"
  run isolated_guard_call src/allowed.py
  expect_status pruned 2
  expect_output_has pruned 'primary workspace'
}

guard_foreign_git() {
  isolated_guard_fixture planning
  local foreign="$TEST_TEMP_DIR/foreign"
  git init -q "$foreign"
  await_git_ai
  git -C "$foreign" -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m fixture
  git -C "$foreign" worktree add -q -b foreign-worker "$TEST_TEMP_DIR/foreign-worker"
  cp "$TEST_TEMP_DIR/foreign-worker/.git" "$WORKER_ROOT/.git"
  run isolated_guard_call src/allowed.py
  expect_status foreign-git 2
  expect_output_has foreign-git 'primary workspace'
}

isolated_guard_link() {
  isolated_guard_fixture planning
  local target="$WORKER_ROOT" replacement="$TEST_TEMP_DIR/relocated"
  [ "$1" != runtime ] || target="$GUARD_CONTROL_ROOT/.runtime"
  mv "$target" "$replacement"
  ln -s "$replacement" "$target"
  run isolated_guard_call src/allowed.py
  expect_status "$1" 2
  expect_output_has "$1" 'primary workspace'
}
guard_symlink_runtime() { isolated_guard_link runtime; }
guard_symlink_worktree() { isolated_guard_link worktree; }

isolated_guard_path_denied() {
  isolated_guard_fixture "${3:-planning}"
  local path="$1" fragment="$2"
  [ "$path" != primary ] || path="$TEST_TEMP_DIR/src/allowed.py"
  run isolated_guard_call "$path"
  expect_status "$1" 2
  expect_output_has "$1" "$fragment"
}
guard_primary_absolute() { isolated_guard_path_denied primary 'canonical primary root'; }
guard_planning_policy() { isolated_guard_path_denied .meridian/x 'cannot write MERIDIAN policy' policy; }
guard_git_policy() { isolated_guard_path_denied .git/x 'cannot write MERIDIAN policy' policy; }
guard_script_policy() { isolated_guard_path_denied scripts/file-guard.sh 'cannot write MERIDIAN policy'; }
guard_outside_allowance() { isolated_guard_path_denied src/other.py 'assigned write allowance'; }

guard_foreign_control() {
  isolated_guard_fixture planning
  local foreign="$BATS_TEST_TMPDIR/foreign/.meridian"
  mkdir -p "$foreign"
  cp -R "$GUARD_CONTROL_ROOT/." "$foreign/"
  GUARD_CONTROL_ROOT="$foreign"
  run isolated_guard_call src/allowed.py
  expect_status foreign-control 2
}

guard_local_manifest() {
  isolated_guard_fixture planning
  mkdir -p "$WORKER_ROOT/.meridian"
  printf '%s\n' '{}' > "$WORKER_ROOT/.meridian/config.json"
  jq --arg root "$WORKER_ROOT" '.agents["dev-1"].project_root=$root | .agents["dev-1"].write_allowances=["src/other.py"]' \
    "$TEST_TEMP_DIR/.meridian/.agent-manifest.json" > "$WORKER_ROOT/.meridian/.agent-manifest.json"
  run isolated_guard_call src/other.py
  expect_status local-manifest 2
}
