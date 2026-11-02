workflow_milestone_location() {
  case "$1" in
    custom-planning) mv .lbwc-planning "$planning" ;;
    symlink)
      ln -s "$PWD" "$BATS_TEST_TMPDIR/project-link"
      cd "$BATS_TEST_TMPDIR/project-link" ;;
  esac
}

workflow_milestone_fixture() {
  local row=$1
  git config user.name 'Test Author'
  git config user.email 'test@example.invalid'
  case "$row" in
    missing) ;;
    false|complete-disabled) printf '{"branch_per_milestone":false}\n' > "$planning/config.json" ;;
    *) printf '{"branch_per_milestone":true}\n' > "$planning/config.json" ;;
  esac
  printf 'original\n' > tracked.txt
  printf '# Release roadmap\n' > "$planning/ROADMAP.md"
  printf '**Milestone:** Release Beta\n' > "$planning/STATE.md"
  case "$row" in
    planning|custom-planning) git add tracked.txt ;;
    *) git add . ;;
  esac
  git -c core.hooksPath=/dev/null commit -qm fixture
  git checkout -qb integration-source
}

workflow_milestone_changes() {
  case "$1" in
    tracked) printf 'changed\n' > tracked.txt ;;
    staged) printf 'changed\n' > tracked.txt; git add tracked.txt ;;
    untracked) printf 'new\n' > untracked.txt ;;
    unmanaged) git checkout -qb milestone/release ;;
    repeat|repeat-dirty|complete|finish|restart)
      bash "$SCRIPTS_DIR/milestone-branch.sh" start "$planning" release > /dev/null
      workflow_managed_changes "$1" ;;
  esac
}

workflow_managed_changes() {
  case "$1" in
    repeat-dirty) printf 'changed\n' > tracked.txt ;;
    complete|finish|restart)
      printf 'release work\n' > tracked.txt
      git add tracked.txt
      git -c core.hooksPath=/dev/null commit -qm 'release work'
      case "$1" in
        finish|restart)
          git checkout -q integration-source
          git -c core.hooksPath=/dev/null merge --no-ff -qm 'approved merge' milestone/release ;;
      esac
      [ "$1" != restart ] || bash "$SCRIPTS_DIR/milestone-branch.sh" finish "$planning" release > /dev/null ;;
  esac
}

workflow_milestone() {
  local row=$1 target before refs dirty action=start planning=.lbwc-planning slug=release
  local work_diff index_diff
  [ "$row" != custom-planning ] || planning='planning records'
  workflow_milestone_location "$row"
  workflow_milestone_fixture "$row"
  target=$(git symbolic-ref --short HEAD)
  workflow_milestone_changes "$row"
  before=$(git rev-parse HEAD)
  refs=$(git show-ref)
  dirty=$(git status --porcelain --untracked-files=all)
  work_diff=$(git diff)
  index_diff=$(git diff --cached)
  case "$row" in
    complete|complete-disabled|unmanaged) action=complete ;;
    finish) action=finish ;;
    derived) slug='' ;;
  esac
  run bash "$SCRIPTS_DIR/milestone-branch.sh" "$action" "$planning" "$slug"
  workflow_milestone_result "$row"
  [ "$(git rev-parse HEAD)" = "$before" ]
  [ "$(git status --porcelain --untracked-files=all)" = "$dirty" ]
  [ "$(git diff)" = "$work_diff" ]
  [ "$(git diff --cached)" = "$index_diff" ]
  [ ! -f "$(git rev-parse --git-path MERGE_HEAD)" ]
}

workflow_milestone_result() {
  case "$1" in
    missing|false|complete-disabled)
      [ "$status" -eq 0 ]
      [ "$output" = 'branch_action=disabled' ]
      workflow_git_unchanged ;;
    tracked|staged|untracked)
      [ "$status" -eq 1 ]
      workflow_git_unchanged
      [ ! -f untracked.txt ] || [ "$(cat untracked.txt)" = new ] ;;
    clean|planning|custom-planning|symlink|restart|derived)
      [ "$status" -eq 0 ]
      [[ "$output" == *'branch_action=created'* ]]
      [[ "$output" == *"merge_target=$target"* ]]
      workflow_created_branch "$1" ;;
    repeat|repeat-dirty)
      [ "$status" -eq 0 ]
      [[ "$output" == *'branch_action=already_started'* ]]
      [ "$(git symbolic-ref --short HEAD)" = milestone/release ] ;;
    *) workflow_completed_branch "$1" ;;
  esac
}

workflow_git_unchanged() {
  [ "$(git symbolic-ref --short HEAD)" = "$target" ]
  [ "$(git show-ref)" = "$refs" ]
}

workflow_created_branch() {
  case "$1" in
    derived) [ "$(git symbolic-ref --short HEAD)" = milestone/01-release-beta ] ;;
    *) [ "$(git symbolic-ref --short HEAD)" = milestone/release ] ;;
  esac
  [ "$(git rev-parse "$target")" = "$before" ]
}

workflow_completed_branch() {
  [ "$status" -eq 0 ]
  case "$1" in
    complete)
      [ "$output" = "branch_action=offer_merge
branch=milestone/release
merge_target=$target" ]
      [ "$(git symbolic-ref --short HEAD)" = milestone/release ]
      [ "$(git show-ref)" = "$refs" ] ;;
    unmanaged)
      [ "$output" = branch_action=no_managed_branch ]
      [ "$(git symbolic-ref --short HEAD)" = milestone/release ]
      [ "$(git show-ref)" = "$refs" ] ;;
    finish)
      [[ "$output" == *'branch_action=finished'* ]]
      [ -z "$(git branch --list milestone/release)" ]
      [ ! -f "$(git rev-parse --git-path lbwc-milestone-release.json)" ]
      [ "$(git symbolic-ref --short HEAD)" = "$target" ] ;;
  esac
}
