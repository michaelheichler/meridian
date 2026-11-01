#!/usr/bin/env bats

load test_helper
load guard_helper
load worktree_helper

setup() {
  setup_temp_dir
  cd "$TEST_TEMP_DIR"
}

teardown() {
  cd "$PROJECT_ROOT"
  teardown_temp_dir
}

prepare_repo_setup() {
  local base
  case "$1" in
    plain) plain_dir ;;
    plain-with-directory) plain_dir; mkdir -p .lbwc-worktrees/01-01 ;;
    repo) fresh_repo ;;
    repo-with-branch) fresh_repo; git branch lbwc/02-03 ;;
    repo-with-two-commits)
      fresh_repo
      echo "second" > second.txt
      git add second.txt
      git commit -q -m "chore: second"
      ;;
    repo-with-feature-branch|repo-with-conflicting-branch)
      fresh_repo
      base=$(git rev-parse --abbrev-ref HEAD)
      git checkout -q -b lbwc/01-01
      if [ "$1" = "repo-with-feature-branch" ]; then
        echo "feature" > feature.txt
        git add feature.txt
      else
        echo "branch side" > init.txt
        git add init.txt
      fi
      git commit -q -m "feat: branch work"
      git checkout -q "$base"
      if [ "$1" = "repo-with-conflicting-branch" ]; then
        echo "main side" > init.txt
        git add init.txt
        git commit -q -m "feat: main work"
      fi
      ;;
  esac
}

@test "worktree-create prints the worktree path or nothing and never fails" {
  while IFS='|' read -r label setup args expectation; do
    [ -n "$label" ] || continue
    prepare_repo_setup "$setup"

    run bash "$SCRIPTS_DIR/worktree-create.sh" $args

    expect_status "$label" 0
    case "$expectation" in
      empty) expect_output_empty "$label" ;;
      existing-path)
        [[ "$output" == *".lbwc-worktrees/01-01" ]] || fail_case "$label" "expected a path ending in .lbwc-worktrees/01-01"
        ;;
      on-branch)
        [[ "$output" == *".lbwc-worktrees/02-03" ]] || fail_case "$label" "expected a path ending in .lbwc-worktrees/02-03"
        [ "$(git -C .lbwc-worktrees/02-03 rev-parse --abbrev-ref HEAD)" = "lbwc/02-03" ] || fail_case "$label" "worktree is not on lbwc/02-03"
        [ "$(grep -cxF '.lbwc-worktrees/' .gitignore)" -eq 1 ] || fail_case "$label" "gitignore does not list .lbwc-worktrees/ exactly once"
        ;;
      at-base)
        [ "$(git -C .lbwc-worktrees/02-03 rev-parse HEAD)" = "$(git rev-parse HEAD~1)" ] || fail_case "$label" "worktree does not start at the base commit"
        ;;
    esac
  done <<'CASES'
no-arguments|plain||empty
not-a-git-repository|plain|02 03|empty
directory-already-exists|plain-with-directory|01 01|existing-path
new-branch-for-new-worktree|repo|02 03|on-branch
existing-branch-fallback|repo-with-branch|02 03|on-branch
explicit-base-commit|repo-with-two-commits|02 03 HEAD~1|at-base
CASES
}

@test "worktree-merge reports clean or conflict and aborts a failed merge" {
  while IFS='|' read -r label setup args expected; do
    [ -n "$label" ] || continue
    prepare_repo_setup "$setup"

    run bash "$SCRIPTS_DIR/worktree-merge.sh" $args

    expect_status "$label" 0
    case "$expected" in
      none) expect_output_empty "$label" ;;
      *) [ "$(printf '%s\n' "$output" | tail -n 1)" = "$expected" ] || fail_case "$label" "last output line is not $expected" ;;
    esac
    case "$label" in
      clean-merge) expect_exists "$label" feature.txt ;;
      conflicting-merge)
        expect_missing "$label" .git/MERGE_HEAD
        [ -z "$(git status --porcelain)" ] || fail_case "$label" "merge was not aborted"
        ;;
    esac
  done <<'CASES'
no-arguments|plain||none
branch-does-not-exist|repo|01 01|conflict
not-a-git-repository|plain|01 01|conflict
clean-merge|repo-with-feature-branch|01 01|clean
conflicting-merge|repo-with-conflicting-branch|01 01|conflict
CASES
}

@test "worktree-status lists only LBWC worktrees as phase and plan entries" {
  while IFS='|' read -r label setup extra_worktrees expected; do
    [ -n "$label" ] || continue
    prepare_repo_setup "$setup"
    case "$extra_worktrees" in
      lbwc) git worktree add -q .lbwc-worktrees/01-02 -b lbwc/01-02 ;;
      foreign) git worktree add -q foreign-tree -b feature/other ;;
      both)
        git worktree add -q foreign-tree -b feature/other
        git worktree add -q .lbwc-worktrees/01-02 -b lbwc/01-02
        ;;
    esac

    run bash "$SCRIPTS_DIR/worktree-status.sh"

    expect_status "$label" 0
    [ "$(printf '%s' "$output" | jq -c 'map({branch,phase,plan})')" = "$expected" ] || fail_case "$label" "entries differ from $expected"
    printf '%s' "$output" | jq -e 'all(.[]; .path | endswith(".lbwc-worktrees/" + "01-02"))' >/dev/null || fail_case "$label" "entry path is not the worktree directory"
  done <<'CASES'
no-repository|plain||[]
repository-without-worktrees|repo||[]
only-a-foreign-worktree|repo|foreign|[]
lbwc-worktree-listed|repo|lbwc|[{"branch":"lbwc/01-02","phase":"01","plan":"02"}]
foreign-worktree-filtered-out|repo|both|[{"branch":"lbwc/01-02","phase":"01","plan":"02"}]
CASES
}

@test "worktree-agent-map stores, returns, and clears a worktree path per agent" {
  while IFS='|' read -r label setup_args args expected file_state; do
    [ -n "$label" ] || continue
    plain_dir
    [ -z "$setup_args" ] || bash "$SCRIPTS_DIR/worktree-agent-map.sh" $setup_args

    run bash "$SCRIPTS_DIR/worktree-agent-map.sh" $args

    expect_status "$label" 0
    case "$expected" in
      none) expect_output_empty "$label" ;;
      *) expect_output_equals "$label" "$expected" ;;
    esac
    case "$file_state" in
      present) expect_exists "$label" .lbwc-planning/.agent-worktrees/dev-01.json ;;
      absent) expect_missing "$label" .lbwc-planning/.agent-worktrees/dev-01.json ;;
    esac
  done <<'CASES'
set-then-get-returns-the-path|set dev-01 /work/tree|get dev-01|/work/tree|present
get-for-an-unknown-agent||get dev-09|none|-
clear-removes-the-mapping|set dev-01 /work/tree|clear dev-01|none|absent
set-without-a-path-stores-nothing||set dev-01|none|absent
unknown-command-changes-nothing|set dev-01 /work/tree|rename dev-01|none|present
CASES
}

@test "worktree-cleanup validates its arguments and leaves unrelated directories alone" {
  while IFS='|' read -r label args expected_status reason; do
    [ -n "$label" ] || continue
    plain_dir
    mkdir -p outside-01

    run bash "$SCRIPTS_DIR/worktree-cleanup.sh" $args

    expect_status "$label" "$expected_status"
    case "$reason" in
      -) expect_output_empty "$label" ;;
      *) expect_output_has "$label" "$reason" ;;
    esac
    expect_exists "$label" outside-01
  done <<'CASES'
no-arguments||0|-
phase-without-plan|01|0|-
worktree-absent|01 01|0|-
traversal-in-phase|../outside 01|1|invalid cleanup target
non-digit-plan|01 ab|1|invalid cleanup target
three-digit-phase|001 01|1|invalid cleanup target
CASES
}

@test "worktree-cleanup removes the target directory and its empty parent but keeps unrelated files" {
  local entry
  while IFS='|' read -r label siblings parent; do
    [ -n "$label" ] || continue
    plain_dir
    mkdir -p .lbwc-worktrees/01-01/.lbwc-planning
    for entry in $siblings; do
      case "$entry" in
        */) mkdir -p ".lbwc-worktrees/$entry" ;;
        *) touch ".lbwc-worktrees/$entry" ;;
      esac
    done

    run bash "$SCRIPTS_DIR/worktree-cleanup.sh" 01 01

    expect_status "$label" 0
    expect_missing "$label" .lbwc-worktrees/01-01
    for entry in $siblings; do
      expect_exists "$label" ".lbwc-worktrees/$entry"
    done
    case "$parent" in
      removed) expect_missing "$label" .lbwc-worktrees ;;
      kept) expect_exists "$label" .lbwc-worktrees ;;
    esac
  done <<'CASES'
residual-directory-and-empty-parent||removed
sibling-ds-store|.DS_Store|kept
sibling-hidden-files|.DS_Store .localized|kept
sibling-worktree|02-01/|kept
CASES
}

@test "worktree-cleanup deregisters the git worktree, deletes its branch, and clears only its agent maps" {
  local maps=".lbwc-planning/.agent-worktrees" map
  while IFS='|' read -r label lock; do
    [ -n "$label" ] || continue
    fresh_repo
    git worktree add -q -b lbwc/01-01 .lbwc-worktrees/01-01 HEAD
    [ "$lock" != "locked" ] || git worktree lock .lbwc-worktrees/01-01
    mkdir -p "$maps"
    echo "{\"worktree_path\":\"$PWD/.lbwc-worktrees/01-01\"}" > "$maps/lbwc-dev-01-01.json"
    echo '{}' > "$maps/agent-01-01.json"
    echo '{}' > "$maps/dev-01-01-01.json"
    echo '{}' > "$maps/lbwc-dev-02-02.json"

    run bash "$SCRIPTS_DIR/worktree-cleanup.sh" 01 01

    expect_status "$label" 0
    expect_missing "$label" .lbwc-worktrees/01-01
    expect_output_lacks "$label" "scan_only"
    [ -z "$(git worktree list | grep 01-01)" ] || fail_case "$label" "git still lists the worktree"
    [ -z "$(branch_listing)" ] || fail_case "$label" "branch lbwc/01-01 survived"
    expect_no_match_under "$label" .git/worktrees 01-01
    for map in lbwc-dev-01-01 agent-01-01 dev-01-01-01; do
      expect_missing "$label" "$maps/$map.json"
    done
    expect_exists "$label" "$maps/lbwc-dev-02-02.json"
    run git worktree add -b lbwc/01-01 .lbwc-worktrees/01-01 HEAD
    expect_status "$label" 0
  done <<'CASES'
registered-worktree|unlocked
locked-worktree|locked
CASES
}
