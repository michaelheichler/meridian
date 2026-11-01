plain_dir() {
  cd "$TEST_TEMP_DIR" || return 1
  rm -rf case-dir
  mkdir case-dir
  cd case-dir || return 1
  mkdir -p .lbwc-planning
}

fresh_repo() {
  cd "$TEST_TEMP_DIR" || return 1
  rm -rf case-repo
  mkdir case-repo
  cd case-repo || return 1
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  echo "init" > init.txt
  git add init.txt
  git commit -q -m "chore: init"
  mkdir -p .lbwc-planning
}

set_stale_mtime_3h() {
  local stamp=""
  if [ "$(uname)" = "Darwin" ]; then
    stamp=$(date -v-3H '+%Y%m%d%H%M.%S') || return 1
  else
    stamp=$(date -d '3 hours ago' '+%Y%m%d%H%M.%S') || return 1
  fi
  touch -t "$stamp" "$1"
}

build_layout() {
  local name="$1" worktree="$PWD/.lbwc-worktrees/01-01" maps=".lbwc-planning/.agent-worktrees"
  case "$name" in
    none) return 0 ;;
    absent-with-map)
      mkdir -p "$maps"
      echo '{"worktree_path":"/active/worktree"}' > "$maps/lbwc-dev-01-01.json"
      return 0
      ;;
    unowned) mkdir -p .lbwc-worktrees/01-01 ;;
    *) git worktree add -q .lbwc-worktrees/01-01 -b lbwc/01-01 >/dev/null ;;
  esac
  case "$name" in
    mapped)
      mkdir -p "$maps"
      echo "{\"worktree_path\":\"$worktree\"}" > "$maps/lbwc-dev-01.json"
      ;;
    malformed-map)
      mkdir -p "$maps"
      printf '{' > "$maps/lbwc-dev-01.json"
      ;;
    dirty)
      mkdir -p "$maps"
      echo "dirty" > .lbwc-worktrees/01-01/dirty.txt
      ;;
    clean) mkdir -p "$maps" ;;
  esac
}

branch_listing() {
  git for-each-ref --format='%(refname:short)' refs/heads/lbwc
}

run_session_stop() {
  echo '{"cost_usd":0,"duration_ms":0,"tokens_in":0,"tokens_out":0,"model":"test"}' | bash "$SCRIPTS_DIR/session-stop.sh"
}
