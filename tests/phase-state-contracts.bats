#!/usr/bin/env bats

load test_helper
load gate_case_helper

setup() {
  setup_temp_dir
  mkdir -p "$TEST_TEMP_DIR/project/.meridian/phases"
  cd "$TEST_TEMP_DIR/project"
  git init -q
  git config user.email test@example.invalid
  git config user.name Test
  . "$SCRIPTS_DIR/summary-utils.sh"
  . "$SCRIPTS_DIR/phase-state-utils.sh"
  PLANNING="$PWD/.meridian"
  PHASES="$PLANNING/phases"
  ROADMAP="$PLANNING/ROADMAP.md"
  reset_case_failures
}

teardown() {
  await_git_ai
  cd "$PROJECT_ROOT"
  teardown_temp_dir
}

numbering_fixture() {
  local prefixes="$1" checklist="$2" number
  rm -rf "$PHASES"
  mkdir -p "$PHASES"
  for number in $prefixes; do
    mkdir -p "$PHASES/$number-phase"
  done
  : > "$ROADMAP"
  for number in $checklist; do
    printf -- '- [ ] Phase %s: Work\n' "$number" >> "$ROADMAP"
  done
}

@test "roadmap numbering distinguishes prefix identity from ordinal position and rejects ambiguity" {
  local label prefixes checklist expected
  while IFS='|' read -r label prefixes checklist expected; do
    numbering_fixture "$prefixes" "$checklist"
    run roadmap_numbering_scheme "$ROADMAP" "$PHASES"
    expect_case_exact "$label" 0 "$expected"
  done <<'CASES'
matching-prefixes|04 09|4 9|prefix
legacy-ordinal|04 09|1 2|ordinal
missing-phase-slot|04 09|4 7 9|prefix
reversed-identities|04 09|9 4|unknown
partial-checklist|04 09|4|unknown
empty-checklist|04 09||prefix
empty-directories||1|unknown
duplicate-checklist|04 09|4 04 9|unknown
duplicate-prefixes|04 004|4|unknown
CASES
  assert_no_case_failures
}

@test "roadmap references resolve by the selected numbering scheme without choosing an ambiguous phase" {
  local label scheme number expected want_status
  numbering_fixture '04 09' '1 2'
  while IFS='|' read -r label scheme number expected want_status; do
    run roadmap_phase_dir_for_num "$scheme" "$PHASES" "$number"
    expect_case "$label" "$want_status" "${expected:+$PHASES/$expected}"
  done <<'CASES'
prefix-reference|prefix|0009|09-phase|0
ordinal-reference|ordinal|2|09-phase|0
missing-prefix|prefix|2||1
missing-position|ordinal|3||1
zero-not-a-phase|prefix|0||1
unknown-scheme|unknown|4||1
CASES
  mkdir -p "$PHASES/004-copy"
  run roadmap_phase_dir_for_num prefix "$PHASES" 4
  expect_case_silent ambiguous-prefix 1
  assert_no_case_failures
}

@test "duplicate roadmap identities normalize padding and report each repeated phase once" {
  local label checklist expected
  while IFS='|' read -r label checklist expected; do
    numbering_fixture '04 09' "$checklist"
    run roadmap_checklist_duplicate_phase_nums "$ROADMAP"
    expect_case_exact "$label" 0 "$expected"
  done <<'CASES'
normalized-duplicate|4 04 9|4
repeated-three-times|4 04 004 9|4
later-duplicate|4 9 09|9
CASES
  assert_no_case_failures
}

@test "phase directory display references follow prefix or ordinal numbering without conflating them" {
  local label scheme directory expected
  numbering_fixture '04 09' '1 2'
  while IFS='|' read -r label scheme directory expected; do
    run roadmap_phase_num_for_dir "$scheme" "$PHASES/$directory" "$PHASES"
    expect_case_exact "$label" 0 "$expected"
  done <<'CASES'
prefix-reference|prefix|09-phase|9
ordinal-reference|ordinal|09-phase|2
first-position|ordinal|04-phase|1
CASES
  run roadmap_phase_num_for_dir ordinal "$PHASES/missing" "$PHASES"
  expect_case_silent missing-directory 0
  run roadmap_phase_num_for_dir unknown "$PHASES/04-phase" "$PHASES"
  expect_case_silent unresolved-scheme 0
  assert_no_case_failures
}

@test "phase identity falls back from directory prefix to plan and UAT metadata" {
  local label dirname artifact contents expected directory
  while IFS='|' read -r label dirname artifact contents expected; do
    directory="$TEST_TEMP_DIR/$label/$dirname"
    mkdir -p "$directory"
    printf '%b\n' "$contents" > "$directory/$artifact"
    run resolve_phase_number_from_phase_dir "$directory"
    expect_case_exact "$label" 0 "$expected"
  done <<'CASES'
directory-wins|07-build|02-PLAN.md|---\nphase: 2\n---|07
plan-fallback|build|12-PLAN.md|# Plan|12
summary-fallback|build|15-SUMMARY.md|# Summary|15
uat-frontmatter|build|current-UAT.md|---\nphase: 23\n---|23
uat-case-insensitive|build|current-UAT.md|---\nPhase: 24\n---|24
CASES
  mkdir -p "$TEST_TEMP_DIR/no-identity"
  run resolve_phase_number_from_phase_dir "$TEST_TEMP_DIR/no-identity"
  expect_case_silent no-invented-number 0
  assert_no_case_failures
}

@test "phase progress labels distinguish planned work from terminal and complete summaries" {
  local label plans summary_status position expected directory
  while IFS='|' read -r label plans summary_status position expected; do
    directory="$PHASES/$label"
    mkdir -p "$directory"
    [ "$plans" = 0 ] || printf '# Plan\n' > "$directory/01-PLAN.md"
    [ "$summary_status" = absent ] || printf -- '---\nstatus: %s\n---\n' "$summary_status" > "$directory/01-SUMMARY.md"
    run phase_status_label "$directory" "$position"
    expect_case_exact "$label" 0 "$expected"
  done <<'CASES'
first-unplanned|0|absent|1|Pending planning
later-unplanned|0|absent|2|Pending
planned|1|absent|1|Planned
partial|1|partial|1|In progress
failed|1|failed|1|In progress
complete|1|complete|1|Complete
CASES
  assert_no_case_failures
}

@test "numbering warnings identify missing and unlisted phase slots without rewriting the roadmap" {
  numbering_fixture '04 09' '4 7 9'
  local before
  before=$(cksum "$ROADMAP")
  run roadmap_numbering_mismatch_details "$ROADMAP" "$PHASES"
  expect_case missing-slot 0 'phase 7'
  expect_case_absent existing-slot 'phase 4 has no matching'
  [ "$before" = "$(cksum "$ROADMAP")" ]
  numbering_fixture '04 09' '4'
  run roadmap_numbering_mismatch_details "$ROADMAP" "$PHASES" prefix
  expect_case unlisted-directory 0 '09-phase'
  numbering_fixture '04 09' '1 2'
  run roadmap_numbering_mismatch_details "$ROADMAP" "$PHASES"
  expect_case ordinal-diagnostic 0 '04-phase'
  numbering_fixture '01 09' '1 2'
  run roadmap_numbering_mismatch_details "$ROADMAP" "$PHASES"
  expect_case single-mismatch 0 '09-phase'
  numbering_fixture '04 004' '4'
  run roadmap_numbering_mismatch_details "$ROADMAP" "$PHASES"
  expect_case duplicate-diagnostic 0 '004-phase'
  assert_no_case_failures
}
