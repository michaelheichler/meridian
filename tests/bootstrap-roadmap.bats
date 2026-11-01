#!/usr/bin/env bats

load test_helper
load gate_case_helper
load gate_case_files
load text_case_helper

setup() {
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK" "$BATS_TEST_TMPDIR/home"
  export HOME="$BATS_TEST_TMPDIR/home"
  git init -q "$WORK"
  cd "$WORK"
  ROADMAP="$SCRIPTS_DIR/bootstrap/bootstrap-roadmap.sh"
  reset_case_failures
}

teardown() {
  await_git_ai
}

@test "bootstrap-roadmap rejects missing, malformed and empty phase input" {
  write_text "$WORK/bad.json" "{not json"
  write_text "$WORK/empty.json" "[]"

  run bash "$ROADMAP" "$WORK/out/ROADMAP.md" "App"
  expect_case "too-few-arguments" 1 "Usage: bootstrap-roadmap.sh"
  run bash "$ROADMAP" "$WORK/out/ROADMAP.md" "App" "$WORK/absent.json"
  expect_case "missing-phases-file" 1 "$WORK/absent.json"
  run bash "$ROADMAP" "$WORK/out/ROADMAP.md" "App" "$WORK/bad.json"
  expect_case "invalid-json" 1 "$WORK/bad.json"
  run bash "$ROADMAP" "$WORK/out/ROADMAP.md" "App" "$WORK/empty.json"
  expect_case "no-phases" 1 "$WORK/empty.json"
  expect_no_path "rejections-write-nothing" "$WORK/out"

  assert_no_case_failures
}

@test "bootstrap-roadmap writes one linked section and one directory per phase" {
  local out="$WORK/.lbwc-planning/ROADMAP.md"
  write_text "$WORK/phases.json" '[
    {"name": "Core API", "goal": "Serve data", "requirements": ["REQ-01", "REQ-02"],
     "success_criteria": ["Returns 200", "Logs requests"]},
    {"name": "UI & Polish!", "goal": "Look good", "success_criteria": []}
  ]'

  run bash "$ROADMAP" "$out" "Shop" "$WORK/phases.json"
  expect_case_silent "two-phases" 0
  expect_exact_line "scope-counts-phases" "$out" "**Scope:** 2 phases"
  expect_exact_line "progress-row-per-phase" "$out" "| 2 | Pending | 0 | 0 | 0 |"
  expect_exact_line "list-links-slug-anchor" "$out" "- [ ] [Phase 2: UI & Polish!](#phase-2-ui-polish)"
  expect_exact_line "phase-goal" "$out" "**Goal:** Look good"
  expect_line_count "requirements-only-when-given" "$out" "**Requirements:** REQ-01, REQ-02" 1
  expect_exact_line "criteria-bullets" "$out" "- Logs requests"
  expect_exact_line "first-phase-has-no-dependency" "$out" "**Dependencies:** None"
  expect_exact_line "later-phase-depends-on-previous" "$out" "**Dependencies:** Phase 1"
  expect_path "first-phase-directory" "$WORK/.lbwc-planning/phases/01-core-api"
  expect_path "second-phase-directory" "$WORK/.lbwc-planning/phases/02-ui-polish"

  assert_no_case_failures
}
