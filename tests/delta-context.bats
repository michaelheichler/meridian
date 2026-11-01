#!/usr/bin/env bats

load test_helper
load gate_case_helper
load gate_case_files

setup() {
  setup_temp_dir
  reset_case_failures
}

teardown() {
  teardown_temp_dir
}

build_workspace() {
  local root=$1 plan_title=${2:-Test Plan} planning
  planning="$root/.lbwc-planning"
  mkdir -p "$planning/phases/02-test-phase"
  printf '%s\n' '{}' > "$planning/config.json"
  printf '%s\n' '# Test Roadmap' '## Phase 2: Test Phase' '**Goal:** Test goal' \
    '**Reqs:** REQ-01' '**Success:** Tests pass' > "$planning/ROADMAP.md"
  printf '%s\n' '---' 'phase: 2' 'plan: 1' "title: \"$plan_title\"" 'wave: 1' \
    'depends_on: []' 'must_haves: ["test"]' '---' "# $plan_title" \
    > "$planning/phases/02-test-phase/02-01-PLAN.md"
}

init_repo() {
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" config user.name "LBWC Test"
  git -C "$1" config user.email "lbwc-tests@example.com"
}

commit_all() {
  git -C "$1" add -A
  git -C "$1" commit -qm "$2"
}

write_summary() {
  local phase_dir=$1
  shift
  { printf '%s\n' '# Summary' '## Files Modified'; printf '%s\n' "$@"; printf '%s\n' '## Deviations'; } \
    > "$phase_dir/02-01-SUMMARY.md"
}

expect_exact_output() {
  local label=$1 want=$2
  [ "$output" = "$want" ] || record_case_failure "$label" "output=[$output] want=[$want]"
}

phase_of() { printf '%s\n' "$1/.lbwc-planning/phases/02-test-phase"; }
plan_of() { printf '%s\n' "$1/.lbwc-planning/phases/02-test-phase/02-01-PLAN.md"; }

@test "delta-files picks summaries, worktree changes, last tag or recent commits for the target scope" {
  local root phase unrelated nested step

  root="$TEST_TEMP_DIR/summary-only"
  build_workspace "$root"
  phase=$(phase_of "$root")
  write_summary "$phase" '- scripts/test.sh' '- config/test.json (new)'
  printf '%s\n' '## Files Modified' '- scripts/test.sh' '- docs/extra.md' > "$phase/02-02-SUMMARY.md"
  cd "$root" || return 1
  run bash "$SCRIPTS_DIR/delta-files.sh" ".lbwc-planning/phases/02-test-phase"
  expect_case "union-sorted-deduped-suffix-stripped" 0 ""
  expect_exact_output "union-sorted-deduped-suffix-stripped" $'config/test.json\ndocs/extra.md\nscripts/test.sh'

  rm -f "$phase/02-01-SUMMARY.md" "$phase/02-02-SUMMARY.md"
  run bash "$SCRIPTS_DIR/delta-files.sh" ".lbwc-planning/phases/02-test-phase"
  expect_case_silent "no-summary-files" 0

  run bash "$SCRIPTS_DIR/delta-files.sh" "$root/absent-phase"
  expect_case_silent "missing-phase-directory" 0

  root="$TEST_TEMP_DIR/dirty"
  build_workspace "$root"
  init_repo "$root"
  printf 'v1\n' > "$root/sample.txt"
  commit_all "$root" init
  printf 'v2\n' > "$root/sample.txt"
  printf 'new\n' > "$root/staged.txt"
  git -C "$root" add staged.txt
  cd "$root" || return 1

  run bash "$SCRIPTS_DIR/delta-files.sh" "$(phase_of "$root")" "$(plan_of "$root")"

  expect_case "dirty" 0 ""
  expect_exact_output "dirty" $'sample.txt\nstaged.txt'
  root="$TEST_TEMP_DIR/tagged"
  build_workspace "$root"
  init_repo "$root"
  printf 'v1\n' > "$root/sample.txt"
  commit_all "$root" init
  git -C "$root" tag v1
  printf 'v2\n' > "$root/sample.txt"
  printf 'other\n' > "$root/other.txt"
  commit_all "$root" change
  cd "$root" || return 1

  run bash "$SCRIPTS_DIR/delta-files.sh" "$(phase_of "$root")" "$(plan_of "$root")"

  expect_case "tagged" 0 ""
  expect_exact_output "tagged" $'other.txt\nsample.txt'
  root="$TEST_TEMP_DIR/untagged"
  build_workspace "$root"
  init_repo "$root"
  printf 'old\n' > "$root/old.txt"
  commit_all "$root" first
  for step in 1 2 3 4 5; do
    printf 'v%s\n' "$step" > "$root/sample-$step.txt"
    commit_all "$root" "step $step"
  done
  cd "$root" || return 1

  run bash "$SCRIPTS_DIR/delta-files.sh" "$(phase_of "$root")" "$(plan_of "$root")"

  expect_case "untagged" 0 "sample-5.txt"
  expect_output_has "oldest-of-five-included" "sample-1.txt"
  expect_output_lacks "sixth-commit-excluded" "old.txt"
  unrelated="$TEST_TEMP_DIR/unrelated"
  setup_unrelated_git_repo "$unrelated"
  printf 'modified\n' >> "$unrelated/unrelated.txt"

  root="$TEST_TEMP_DIR/not-git"
  build_workspace "$root"
  write_summary "$(phase_of "$root")" '- scripts/test.sh'
  cd "$unrelated" || return 1
  run bash "$SCRIPTS_DIR/delta-files.sh" "$(phase_of "$root")" "$(plan_of "$root")"
  expect_case "non-git-target-ignores-ambient-repo" 0 ""
  expect_exact_output "non-git-target-ignores-ambient-repo" "scripts/test.sh"

  root="$TEST_TEMP_DIR/young"
  build_workspace "$root"
  init_repo "$root"
  printf 'v1\n' > "$root/sample.txt"
  commit_all "$root" init
  printf 'v2\n' > "$root/sample.txt"
  commit_all "$root" update
  cd "$unrelated" || return 1
  run bash "$SCRIPTS_DIR/delta-files.sh" "$(phase_of "$root")" "$(plan_of "$root")"
  expect_case "git-target-recent-log" 0 "sample.txt"
  expect_output_lacks "git-target-excludes-ambient-file" "unrelated.txt"

  nested="$TEST_TEMP_DIR/mono"
  build_workspace "$nested/apps/proj"
  init_repo "$nested"
  mkdir -p "$nested/apps/other"
  printf 'x\n' > "$nested/apps/other/skip.txt"
  printf 'v1\n' > "$nested/apps/proj/sample.txt"
  commit_all "$nested" init
  printf 'v2\n' > "$nested/apps/proj/sample.txt"
  commit_all "$nested" update
  cd "$unrelated" || return 1
  run bash "$SCRIPTS_DIR/delta-files.sh" "$(phase_of "$nested/apps/proj")" "$(plan_of "$nested/apps/proj")"
  expect_case "nested-workspace-relative-paths" 0 "sample.txt"
  expect_output_lacks "nested-workspace-no-repo-prefix" "apps/proj/sample.txt"
  expect_output_lacks "nested-workspace-excludes-sibling" "skip.txt"

  assert_no_case_failures
}

@test "compile-context renders delta slices, lead metadata and the active plan for the target workspace" {
  local root unrelated nested context

  unrelated="$TEST_TEMP_DIR/unrelated"
  setup_unrelated_git_repo "$unrelated"

  root="$TEST_TEMP_DIR/summary-target"
  build_workspace "$root"
  write_summary "$(phase_of "$root")" '- sample.txt'
  printf 'sample body\n' > "$root/sample.txt"
  cd "$unrelated" || return 1
  run env LBWC_PLANNING_DIR="$root/.lbwc-planning" bash "$SCRIPTS_DIR/compile-context.sh" 02 dev \
    "$root/.lbwc-planning/phases" "$(plan_of "$root")"
  context="$(phase_of "$root")/.context-dev.md"
  expect_status "summary-target" 0
  expect_file_line "summary-target-heading" "$context" '#### `sample.txt`'
  expect_file_line "summary-target-body" "$context" 'sample body'

  root="$TEST_TEMP_DIR/git-target"
  build_workspace "$root"
  init_repo "$root"
  printf 'v1 body\n' > "$root/sample.txt"
  commit_all "$root" init
  printf 'v2 body\n' > "$root/sample.txt"
  commit_all "$root" update
  cd "$unrelated" || return 1
  run env LBWC_PLANNING_DIR="$root/.lbwc-planning" bash "$SCRIPTS_DIR/compile-context.sh" 02 dev \
    "$root/.lbwc-planning/phases" "$(plan_of "$root")"
  context="$(phase_of "$root")/.context-dev.md"
  expect_status "git-target" 0
  expect_file_line "git-target-list" "$context" '- `sample.txt`'
  expect_file_line "git-target-heading" "$context" '#### `sample.txt`'
  expect_file_line "git-target-latest-body" "$context" 'v2 body'
  expect_no_file_line "git-target-no-stale-body" "$context" 'v1 body'

  nested="$TEST_TEMP_DIR/mono"
  build_workspace "$nested/apps/proj"
  init_repo "$nested"
  printf 'v1 body\n' > "$nested/apps/proj/sample.txt"
  commit_all "$nested" init
  printf 'v2 body\n' > "$nested/apps/proj/sample.txt"
  commit_all "$nested" update
  cd "$unrelated" || return 1
  run bash "$SCRIPTS_DIR/compile-context.sh" 02 dev "$nested/apps/proj/.lbwc-planning/phases" \
    "$(plan_of "$nested/apps/proj")"
  context="$(phase_of "$nested/apps/proj")/.context-dev.md"
  expect_status "nested-target" 0
  expect_file_line "nested-list" "$context" '- `sample.txt`'
  expect_no_file_line "nested-no-repo-prefix" "$context" 'apps/proj/sample.txt'
  expect_file_line "nested-body" "$context" 'v2 body'

  root="$TEST_TEMP_DIR/lead-target"
  build_workspace "$root"
  printf '%s\n' '## Requirements' '- [REQ-01] Test requirement' > "$root/.lbwc-planning/REQUIREMENTS.md"
  cd "$unrelated" || return 1

  run bash "$SCRIPTS_DIR/compile-context.sh" 02 lead "$root/.lbwc-planning/phases" "$(plan_of "$root")"

  context="$(phase_of "$root")/.context-lead.md"
  expect_status "lead" 0
  expect_file_line "lead-goal" "$context" 'Test goal'
  expect_file_line "lead-requirement" "$context" 'Test requirement'
  root="$TEST_TEMP_DIR/active-plan"
  build_workspace "$root"
  write_summary "$(phase_of "$root")" '- scripts/delta-test.sh'
  cd "$root" || return 1

  run bash "$SCRIPTS_DIR/compile-context.sh" 02 dev ".lbwc-planning/phases" ".lbwc-planning/phases/02-test-phase/02-01-PLAN.md"

  context="$(phase_of "$root")/.context-dev.md"
  expect_status "active-plan" 0
  expect_file_line "active-plan-heading" "$context" "Active Plan"
  expect_file_line "delta-file-listed" "$context" 'scripts/delta-test.sh'
  assert_no_case_failures
}
