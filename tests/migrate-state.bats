#!/usr/bin/env bats

load gate_case_helper

setup() {
  unset CDPATH TMUX TMUX_PANE
  MIGRATE="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd -P)/migrate-state.sh"
  FIXTURE="$BATS_TEST_DIRNAME/rename_fixture.py"
  reset_case_failures
}

new_project() {
  PROJECT="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$PROJECT"
  git -C "$PROJECT" init -q
}

seed_legacy_state() {
  mkdir -p "$PROJECT/.lbwc-planning/phases/01-setup"
  printf 'configuration\n' > "$PROJECT/.lbwc-planning/config.json"
  printf 'plan\n' > "$PROJECT/.lbwc-planning/phases/01-setup/PLAN.md"
}

tree_manifest() {
  python3 -I "$FIXTURE" manifest "$1"
}

migrate_project() {
  (cd "$PROJECT" && bash "$MIGRATE" "$PROJECT")
}

migrate_project_with_failing_mv() {
  local bin="$BATS_TEST_TMPDIR/failing-mv-bin"
  mkdir -p "$bin"
  printf '%s\n' '#!/bin/sh' 'exit 1' > "$bin/mv"
  chmod +x "$bin/mv"
  (cd "$PROJECT" && PATH="$bin:$PATH" bash "$MIGRATE" "$PROJECT")
}

migrate_from_subdirectory_without_argument() {
  mkdir -p "$PROJECT/src/nested"
  (cd "$PROJECT/src/nested" && bash "$MIGRATE")
}

expect_tree_unchanged() {
  local label="$1" root="$2" before="$3"
  tree_manifest "$root" > "$BATS_TEST_TMPDIR/$label.after"
  cmp -s "$before" "$BATS_TEST_TMPDIR/$label.after" \
    || record_case_failure "$label" "tree under $root changed"
}

nothing_to_move_row() {
  new_project nothing
  tree_manifest "$PROJECT" > "$BATS_TEST_TMPDIR/nothing.before"
  run migrate_project
  expect_case nothing-to-move 0
  expect_tree_unchanged nothing-to-move "$PROJECT" "$BATS_TEST_TMPDIR/nothing.before"
}

old_folder_only_row() {
  new_project old-only
  seed_legacy_state
  tree_manifest "$PROJECT/.lbwc-planning" > "$BATS_TEST_TMPDIR/old-only.before"
  run migrate_project
  expect_case old-folder-only 0
  [ ! -e "$PROJECT/.lbwc-planning" ] || record_case_failure old-folder-only "old folder still exists"
  expect_tree_unchanged old-folder-only "$PROJECT/.meridian" "$BATS_TEST_TMPDIR/old-only.before"
}

both_folders_row() {
  new_project both
  seed_legacy_state
  mkdir "$PROJECT/.meridian"
  printf 'current configuration\n' > "$PROJECT/.meridian/config.json"
  tree_manifest "$PROJECT" > "$BATS_TEST_TMPDIR/both.before"
  run migrate_project
  expect_case both-folders-conflict 3
  expect_tree_unchanged both-folders-conflict "$PROJECT" "$BATS_TEST_TMPDIR/both.before"
}

failing_move_row() {
  new_project failing-move
  seed_legacy_state
  tree_manifest "$PROJECT" > "$BATS_TEST_TMPDIR/failing-move.before"
  run migrate_project_with_failing_mv
  expect_case failing-move 2
  expect_tree_unchanged failing-move "$PROJECT" "$BATS_TEST_TMPDIR/failing-move.before"
}

default_root_row() {
  new_project default-root
  seed_legacy_state
  tree_manifest "$PROJECT/.lbwc-planning" > "$BATS_TEST_TMPDIR/default-root.before"
  run migrate_from_subdirectory_without_argument
  expect_case default-root-is-git-toplevel 0
  [ ! -e "$PROJECT/src/nested/.meridian" ] \
    || record_case_failure default-root-is-git-toplevel "migrated into the working directory"
  expect_tree_unchanged default-root-is-git-toplevel "$PROJECT/.meridian" "$BATS_TEST_TMPDIR/default-root.before"
}

@test "migrate-state moves the legacy planning dir and reports conflicts and move failures by exit code" {
  nothing_to_move_row
  old_folder_only_row
  both_folders_row
  failing_move_row
  default_root_row
  assert_no_case_failures
}
