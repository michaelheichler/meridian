#!/usr/bin/env bats

load test_helper
load gate_case_helper
load gate_case_files

setup() {
  setup_temp_dir
  reset_case_failures
  TOTAL_SCRIPT="$SCRIPTS_DIR/update-phase-total.sh"
  TEST_ROOT="$TEST_TEMP_DIR/repo"
  mkdir -p "$TEST_ROOT"
  cd "$TEST_ROOT" || return 1
  git init -q
}

teardown() {
  cd "$BATS_TEST_DIRNAME" || true
  teardown_temp_dir
}

planning() {
  PLANNING="$TEST_ROOT/$1/.meridian"
  STATE="$PLANNING/STATE.md"
  mkdir -p "$PLANNING/phases"
}

write_state() {
  printf '%s\n' '# State' '' "$1" '' '## Phase Status' '- **Phase 1 (Old):** Pending' '' '## Notes' 'keep me' > "$STATE"
}

add_phase() {
  local dir="$PLANNING/phases/$1" prefix="${1%%-*}"
  mkdir -p "$dir"
  [ "$2" = empty ] && return 0
  printf -- '---\nplan: 01\n---\n' > "$dir/$prefix-01-PLAN.md"
  [ "$2" = planned ] && return 0
  printf -- '---\nstatus: %s\n---\n' "$2" > "$dir/$prefix-01-SUMMARY.md"
}

four_phases() {
  add_phase 01-setup complete
  add_phase 02-build-cart partial
  add_phase 03-pay planned
  add_phase 04-ship empty
}

update_total() {
  run bash "$TOTAL_SCRIPT" "$PLANNING" "$@"
}

@test "update-phase-total renumbers the current phase and rebuilds the status block from ordinal phase directories" {
  planning rebuild
  four_phases
  write_state 'Phase: 2 of 3 (Old)'
  update_total
  expect_case_silent rebuild 0
  expect_file_line rebuild "$STATE" '^Phase: 2 of 4 (Build Cart)$'
  expect_file_line rebuild "$STATE" '^- \*\*Phase 1 (Setup):\*\* Complete$'
  expect_file_line rebuild "$STATE" '^- \*\*Phase 2 (Build Cart):\*\* In progress$'
  expect_file_line rebuild "$STATE" '^- \*\*Phase 3 (Pay):\*\* Planned$'
  expect_file_line rebuild "$STATE" '^- \*\*Phase 4 (Ship):\*\* Pending$'
  expect_no_file_line rebuild "$STATE" '(Old)'
  expect_file_line rebuild "$STATE" '^keep me$'

  planning inserted-before-current
  four_phases
  write_state 'Phase: 2 of 3'
  update_total --inserted 2
  expect_file_line inserted-before-current "$STATE" '^Phase: 3 of 4 (Pay)$'

  planning inserted-after-current
  four_phases
  write_state 'Phase: 2 of 3'
  update_total --verbose --inserted 3
  expect_file_line inserted-after-current "$STATE" '^Phase: 2 of 4 (Build Cart)$'

  planning removed-before-current
  four_phases
  write_state 'Phase: 3 of 5'
  update_total --removed 1
  expect_file_line removed-before-current "$STATE" '^Phase: 2 of 4 (Build Cart)$'

  planning bad-position
  four_phases
  write_state 'Phase: 3 of 5'
  update_total --removed first
  expect_file_line bad-position "$STATE" '^Phase: 3 of 5$'

  planning clamps-to-total
  four_phases
  write_state 'Phase: 9 of 9'
  update_total
  expect_file_line clamps-to-total "$STATE" '^Phase: 4 of 4 (Ship)$'

  planning first-phase-unplanned
  add_phase 01-setup empty
  printf '%s\n' 'Phase: 1 of 1' '## Phase Status' '- **Phase 1 (Old):** Pending' '## Notes' > "$STATE"
  update_total
  expect_file_line first-phase-unplanned "$STATE" '^- \*\*Phase 1 (Setup):\*\* Pending planning$'
  expect_file_line first-phase-unplanned "$STATE" '^## Notes$'

  planning no-phase-line
  four_phases
  write_state 'Current: 2'
  update_total
  expect_file_line no-phase-line "$STATE" '^- \*\*Phase 1 (Old):\*\* Pending$'

  planning non-numeric-phase
  four_phases
  write_state 'Phase: two'
  update_total
  expect_file_line non-numeric-phase "$STATE" '^Phase: two$'

  planning no-phases-left
  printf '%s\n' '# State' '## Current Phase' 'Phase: 2 of 2' '' '## Phase Status' '- **Phase 1 (Old):** Pending' '' '## Notes' > "$STATE"
  update_total
  expect_case_silent no-phases-left 0
  expect_no_file_line no-phases-left "$STATE" '^## Current Phase$'
  expect_no_file_line no-phases-left "$STATE" '^- \*\*Phase 1'
  expect_file_line no-phases-left "$STATE" '^## Phase Status$'
  expect_file_line no-phases-left "$STATE" '^## Notes$'

  planning standalone-copy
  four_phases
  write_state 'Phase: 3 of 3'
  mkdir -p "$TEST_ROOT/bin"
  cp "$TOTAL_SCRIPT" "$TEST_ROOT/bin/update-phase-total.sh"
  run bash "$TEST_ROOT/bin/update-phase-total.sh" "$PLANNING"
  expect_case_silent standalone-copy 0
  expect_file_line standalone-copy "$STATE" '^Phase: 3 of 4 (Pay)$'
  expect_file_line standalone-copy "$STATE" '^- \*\*Phase 1 (Setup):\*\* Complete$'
  expect_file_line standalone-copy "$STATE" '^- \*\*Phase 2 (Build Cart):\*\* In progress$'
  expect_file_line standalone-copy "$STATE" '^- \*\*Phase 3 (Pay):\*\* Planned$'
  expect_file_line standalone-copy "$STATE" '^- \*\*Phase 4 (Ship):\*\* Pending$'

  planning no-state
  four_phases
  update_total
  expect_case_silent no-state 0
  expect_no_path no-state "$STATE"

  planning no-phases-dir
  rmdir "$PLANNING/phases"
  write_state 'Phase: 2 of 3'
  update_total
  expect_file_line no-phases-dir "$STATE" '^Phase: 2 of 3$'

  assert_no_case_failures
}

@test "update-phase-total follows ROADMAP prefix numbering, keeps missing phase slots and skips ambiguous roadmaps" {
  planning prefix
  add_phase 01-setup complete
  add_phase 03-ship planned
  printf '%s\n' '# Roadmap' '- [x] Phase 1: Setup' '- [ ] Phase 2: Pay' '- [ ] Phase 3: Ship' > "$PLANNING/ROADMAP.md"
  printf '%s\n' 'Phase: 3 of 2' '' '## Phase Status' '- **Phase 2 (Pay):** Planned' '' '## Notes' > "$STATE"
  update_total
  expect_file_line prefix "$STATE" '^Phase: 3 of 3 (Ship)$'
  expect_file_line prefix "$STATE" '^- \*\*Phase 1 (Setup):\*\* Complete$'
  expect_file_line prefix "$STATE" '^- \*\*Phase 2 (Pay):\*\* Planned$'
  expect_file_line prefix "$STATE" '^- \*\*Phase 3 (Ship):\*\* Planned$'

  planning prefix-missing-slot
  add_phase 01-setup complete
  add_phase 03-ship planned
  printf '%s\n' '# Roadmap' '- [x] Phase 1: Setup' '- [ ] Phase 2: Pay' '- [ ] Phase 3: Ship' > "$PLANNING/ROADMAP.md"
  write_state 'Phase: 2 of 2'
  update_total
  expect_file_line prefix-missing-slot "$STATE" '^Phase: 2 of 3$'
  expect_file_line prefix-missing-slot "$STATE" '^- \*\*Phase 2 (Missing phase directory):\*\* Unknown (missing phase directory)$'

  planning duplicate-roadmap
  add_phase 01-setup complete
  add_phase 02-ship planned
  printf '%s\n' '# Roadmap' '- [x] Phase 1: Setup' '- [ ] Phase 1: Again' > "$PLANNING/ROADMAP.md"
  write_state 'Phase: 2 of 9'
  update_total
  expect_case_silent duplicate-roadmap 0
  expect_file_line duplicate-roadmap "$STATE" '^Phase: 2 of 9$'

  assert_no_case_failures
}
