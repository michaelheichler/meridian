#!/usr/bin/env bats

load test_helper
load gate_case_helper

setup() {
  setup_temp_dir
  reset_case_failures
}

teardown() {
  cd "$PROJECT_ROOT"
  teardown_temp_dir
}

fresh_default() {
  local dir="$TEST_TEMP_DIR/$1"
  mkdir -p "$dir/.lbwc-planning/milestones/default"
  cd "$dir" || return 1
}

shipped() {
  printf '%s\n' "$@" > .lbwc-planning/milestones/default/SHIPPED.md
}

milestones_after_rename() {
  bash "$SCRIPTS_DIR/rename-default-milestone.sh" "$@" || return
  ls -1 .lbwc-planning/milestones | sed 's/^/dir=/; s/$/;/'
}

@test "default milestone rename derives a numbered slug from SHIPPED.md, phases, or the date" {
  local today
  today=$(date +%Y%m%d)

  run bash "$SCRIPTS_DIR/rename-default-milestone.sh"
  expect_case missing-planning-arg 1 "Usage"

  mkdir -p "$TEST_TEMP_DIR/no-default/.lbwc-planning/milestones/01-kept"
  cd "$TEST_TEMP_DIR/no-default"
  run milestones_after_rename .lbwc-planning
  expect_case no-default-dir 0 "dir=01-kept;"

  fresh_default shipped-title
  shipped '# Shipped: Auth API Rewrite'
  run milestones_after_rename .lbwc-planning
  expect_case shipped-title 0 "dir=01-auth-api-rewrite;"
  expect_case_absent shipped-title "dir=default;"

  fresh_default title-with-dash-and-punctuation
  shipped $'# SHIPPED: Billing \xE2\x80\x94 Phase Two!'
  run milestones_after_rename .lbwc-planning
  expect_case title-with-dash-and-punctuation 0 "dir=01-billing-phase-two;"

  fresh_default default-title-uses-bullet-phases
  shipped '# Shipped: Default Milestone' '## Phases' '- Phase 1: Setup Core - done' '- Phase 2: Wire API - done' '- Phase 3: Extra'
  run milestones_after_rename .lbwc-planning
  expect_case default-title-uses-bullet-phases 0 "dir=01-setup-core-wire-api;"

  fresh_default numbered-phases
  shipped '# Release notes' '## Phases' '1. **Login Flow** - complete' '2. **Logout**' '## Metrics' '- Phase 9: Ignored'
  run milestones_after_rename .lbwc-planning
  expect_case numbered-phases 0 "dir=01-login-flow-logout;"

  fresh_default phase-dirs
  mkdir -p .lbwc-planning/milestones/default/phases/01-setup .lbwc-planning/milestones/default/phases/02-deploy .lbwc-planning/milestones/default/phases/03-extra
  run milestones_after_rename .lbwc-planning
  expect_case phase-dirs 0 "dir=01-setup-deploy;"

  fresh_default date-fallback
  run milestones_after_rename .lbwc-planning
  expect_case date-fallback 0 "dir=01-milestone-$today;"

  fresh_default long-title
  shipped '# Shipped: alpha beta gamma delta epsilon zeta eta theta iota kappa lambda'
  run milestones_after_rename .lbwc-planning
  expect_case long-title 0 "dir=01-alpha-beta-gamma-delta-epsilon-zeta-eta-theta-iota;"

  fresh_default counts-existing-milestones
  mkdir -p .lbwc-planning/milestones/01-first
  shipped '# Shipped: Second'
  run milestones_after_rename .lbwc-planning
  expect_case counts-existing-milestones 0 "dir=02-second;"

  fresh_default name-collision
  mkdir -p .lbwc-planning/milestones/02-second
  shipped '# Shipped: Second'
  run milestones_after_rename .lbwc-planning
  expect_case name-collision 0 "dir=02-second-1;"

  fresh_default collisions-exhausted
  mkdir -p .lbwc-planning/milestones/12-second
  mkdir -p .lbwc-planning/milestones/12-second-{1,2,3,4,5,6,7,8,9,10}
  shipped '# Shipped: Second'
  run milestones_after_rename .lbwc-planning
  expect_case collisions-exhausted 1 "12-second-10"

  assert_no_case_failures
}
