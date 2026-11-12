#!/usr/bin/env bats

load gate_case_helper
load gate_case_files

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/verify-state-consistency.sh"
  RECONCILE="$REPO_ROOT/scripts/reconcile-state-md.sh"
  UPDATER="$REPO_ROOT/scripts/state-updater.sh"
  TEST_ROOT="$(mktemp -d)"
  cd "$TEST_ROOT"
  reset_case_failures
}

teardown() {
  cd "$REPO_ROOT"
  rm -rf "$TEST_ROOT"
}

fresh_planning() {
  PROJECT="$TEST_ROOT/$1"
  PLANNING_DIR="$PROJECT/.meridian"
  STATE_FILE="$PLANNING_DIR/STATE.md"
  mkdir -p "$PLANNING_DIR/phases"
  cd "$PROJECT"
}

write_state() {
  printf '%s\n' "$@" > "$STATE_FILE"
}

make_minimal_project() {
  mkdir -p "$PLANNING_DIR/phases/01-test"
  write_state 'Phase: 1 of 1 (test)' 'Plans: 0/0'
  printf '# Roadmap\n\n### Phase 1: Test\n' > "$PLANNING_DIR/ROADMAP.md"
}

make_phase() {
  local phase_dir="$PLANNING_DIR/phases/$1" plans=$2 index
  shift 2
  mkdir -p "$phase_dir"
  index=1
  while [ "$index" -le "$plans" ]; do
    printf '# plan\n' > "$phase_dir/$(printf '%02d' "$index")-PLAN.md"
    index=$((index + 1))
  done
  index=1
  for summary_status in "$@"; do
    printf '%s\n' '---' "status: $summary_status" '---' > "$phase_dir/$(printf '%02d' "$index")-SUMMARY.md"
    index=$((index + 1))
  done
}

write_uat() {
  printf '%s\n' '---' "status: $2" '---' '### P1: Check' '- **Result:** pass' > "$PLANNING_DIR/phases/$1/${1%%-*}-UAT.md"
}

skip_qa() {
  printf '{"qa_required": false}\n' > "$PLANNING_DIR/.execution-state.json"
}

run_verify() {
  MERIDIAN_PLANNING_DIR="$PLANNING_DIR" bash "$SCRIPT"
}

@test "verify-state-consistency reports ok when disk and state agree and exits 1 naming each kind of drift" {
  fresh_planning no-planning
  rm -rf "$PLANNING_DIR"
  run run_verify
  expect_case no-planning-dir 0 "state_consistency=no_planning_dir"

  fresh_planning minimal
  make_minimal_project
  run run_verify
  expect_case minimal-project 0 "state_consistency=ok"

  fresh_planning counts-match
  make_phase 01-test 2 complete
  write_state 'Phase: 1 of 1 (test)' 'Plans: 1/2'
  printf '# Roadmap\n\n### Phase 1: Test\n' > "$PLANNING_DIR/ROADMAP.md"
  run run_verify
  expect_case counts-match 0 "state_consistency=ok"

  fresh_planning remediation-consistent
  make_minimal_project
  mkdir -p "$PLANNING_DIR/phases/01-test/remediation/qa/round-02"
  printf 'stage=verify\nround=02\n' > "$PLANNING_DIR/phases/01-test/remediation/qa/.qa-remediation-stage"
  printf 'summary\n' > "$PLANNING_DIR/phases/01-test/remediation/qa/round-02/R02-SUMMARY.md"
  run run_verify
  expect_case remediation-consistent 0 "state_consistency=ok"

  fresh_planning empty-manifest
  make_minimal_project
  printf '{"agents":[]}\n' > "$PLANNING_DIR/.agent-manifest.json"
  run run_verify
  expect_case empty-manifest 0 "state_consistency=ok"

  fresh_planning state-plans
  make_minimal_project
  : > "$PLANNING_DIR/phases/01-test/PLAN.md"
  run run_verify
  expect_case state-plans 1 "DRIFT STATE: Plans is 0/0, disk is 0/1"

  fresh_planning state-phase-invalid
  mkdir -p "$PLANNING_DIR/phases/01-test"
  write_state 'Phase: none' 'Plans: 0/0'
  run run_verify
  expect_case state-phase-invalid 1 "DRIFT STATE: Phase field is missing or invalid"

  fresh_planning state-phase-no-dir
  mkdir -p "$PLANNING_DIR/phases/01-test"
  write_state 'Phase: 4 of 4 (gone)' 'Plans: 0/0'
  run run_verify
  expect_case state-phase-no-dir 1 "DRIFT STATE: Phase 4 has no directory"

  fresh_planning state-plans-invalid
  mkdir -p "$PLANNING_DIR/phases/01-test"
  write_state 'Phase: 1 of 1 (test)' 'Plans: many'
  run run_verify
  expect_case state-plans-invalid 1 "DRIFT STATE: Plans is unparsable (value 'many'"
  expect_output_has state-plans-invalid "disk is 0/0"

  fresh_planning state-plans-missing
  mkdir -p "$PLANNING_DIR/phases/01-test"
  write_state 'Phase: 1 of 1 (test)'
  run run_verify
  expect_case state-plans-missing 1 "DRIFT STATE: Plans is unparsable (value 'missing'"

  fresh_planning roadmap-no-dir
  make_minimal_project
  printf '# Roadmap\n\n### Phase 1: Test\n### Phase 2: Ghost\n' > "$PLANNING_DIR/ROADMAP.md"
  run run_verify
  expect_case roadmap-no-dir 1 "DRIFT ROADMAP: Phase 2 has no directory"

  fresh_planning roadmap-unlisted
  make_minimal_project
  mkdir -p "$PLANNING_DIR/phases/02-extra"
  run run_verify
  expect_case roadmap-unlisted 1 "DRIFT ROADMAP: directory 02-extra is not listed"

  fresh_planning manifest-no-timestamp
  make_minimal_project
  printf '{"agents":[{"id":"worker-1","state":"running"}]}\n' > "$PLANNING_DIR/.agent-manifest.json"
  run run_verify
  expect_case manifest-no-timestamp 1 "DRIFT agent_manifest: worker-1 has active state running without timestamp"

  fresh_planning manifest-stale
  make_minimal_project
  printf '{"agents":[{"id":"worker-2","state":"running","timestamp":"2020-01-01T00:00:00Z"}]}\n' > "$PLANNING_DIR/.agent-manifest.json"
  run run_verify
  expect_case manifest-stale 1 "DRIFT agent_manifest: worker-2 is running and older than 24h"

  fresh_planning manifest-bogus-timestamp
  make_minimal_project
  printf '{"agents":[{"id":"worker-3","state":"running","timestamp":"yesterday"}]}\n' > "$PLANNING_DIR/.agent-manifest.json"
  run run_verify
  expect_case manifest-bogus-timestamp 1 "DRIFT agent_manifest: worker-3 has invalid timestamp yesterday"

  fresh_planning deviq-chain
  make_minimal_project
  mkdir -p "$PLANNING_DIR/deviq"
  printf '{"sha256":"bogus","prev_sha256":null}\n' > "$PLANNING_DIR/deviq/blocks.jsonl"
  run run_verify
  expect_case deviq-chain 1 "DRIFT deviq: hash chain verification failed"

  fresh_planning remediation-missing-round
  make_minimal_project
  mkdir -p "$PLANNING_DIR/phases/01-test/remediation/qa"
  printf 'stage=plan\nround=02\n' > "$PLANNING_DIR/phases/01-test/remediation/qa/.qa-remediation-stage"
  run run_verify
  expect_case remediation-missing-round 1 "DRIFT remediation:"
  expect_output_has remediation-missing-round "points at missing round-02"

  fresh_planning remediation-invalid-round
  make_minimal_project
  mkdir -p "$PLANNING_DIR/phases/01-test/remediation/uat"
  printf 'stage=plan\nround=x\n' > "$PLANNING_DIR/phases/01-test/remediation/uat/.uat-remediation-stage"
  run run_verify
  expect_case remediation-invalid-round 1 "has invalid round"

  fresh_planning remediation-verify-no-summary
  make_minimal_project
  mkdir -p "$PLANNING_DIR/phases/01-test/remediation/uat/round-01"
  printf 'stage=verify\nround=01\n' > "$PLANNING_DIR/phases/01-test/remediation/uat/.uat-remediation-stage"
  run run_verify
  expect_case remediation-verify-no-summary 1 "is verify without"

  assert_no_case_failures
}

@test "iso_utc_to_epoch: converts UTC timestamps and rejects malformed ones" {
  source "$REPO_ROOT/scripts/lib/iso-epoch.sh"

  run iso_utc_to_epoch "2020-01-01T00:00:00Z"
  expect_case with-z 0 "1577836800"

  run iso_utc_to_epoch "2020-01-01T00:00:00.789Z"
  expect_case fractional-seconds 0 "1577836800"

  run iso_utc_to_epoch "2020-01-01T00:00:00"
  expect_case without-z 0 "1577836800"

  run iso_utc_to_epoch "not-a-timestamp"
  expect_case_silent garbage 1

  run iso_utc_to_epoch "2020-13-45T99:99:99Z"
  expect_case_silent impossible-date 1

  assert_no_case_failures
}

@test "reconcile-state-md rewrites the phase block, status lines, sections and roadmap checklist, and reports json, skip and changed-file modes" {
  fresh_planning planned
  skip_qa
  make_phase 01-alpha 2
  write_state '# State' 'Phase: 9 of 9 (old)' 'Plans: 9/9' 'Progress: 99%' 'Status: stale'
  run bash "$RECONCILE" "$PLANNING_DIR"
  expect_status planned 0
  expect_file_line planned "$STATE_FILE" '^Phase: 1 of 1 (Alpha)$'
  expect_file_line planned "$STATE_FILE" '^Plans: 0/2$'
  expect_file_line planned "$STATE_FILE" '^Progress: 0%$'
  expect_file_line planned "$STATE_FILE" '^Status: ready$'

  fresh_planning in-progress
  skip_qa
  make_phase 01-alpha 3 complete partial
  make_phase 02-beta 1
  write_state 'Phase: 9 of 9 (old)' 'Plans: 9/9' 'Progress: 99%' 'Status: stale'
  run bash "$RECONCILE" "$PLANNING_DIR"
  expect_status in-progress 0
  expect_file_line in-progress "$STATE_FILE" '^Phase: 1 of 2 (Alpha)$'
  expect_file_line in-progress "$STATE_FILE" '^Plans: 2/3$'
  expect_file_line in-progress "$STATE_FILE" '^Progress: 66%$'
  expect_file_line in-progress "$STATE_FILE" '^Status: active$'

  fresh_planning moves-to-next-phase
  skip_qa
  make_phase 01-alpha 1 complete
  make_phase 02-beta 1
  write_state 'Phase: 1 of 2 (old)' 'Plans: 1/1' 'Progress: 100%' 'Status: stale'
  run bash "$RECONCILE" "$PLANNING_DIR"
  expect_status moves-to-next-phase 0
  expect_file_line moves-to-next-phase "$STATE_FILE" '^Phase: 2 of 2 (Beta)$'
  expect_file_line moves-to-next-phase "$STATE_FILE" '^Plans: 0/1$'

  fresh_planning all-complete
  skip_qa
  make_phase 01-alpha 1 complete
  write_state 'Phase: 1 of 1 (old)' 'Plans: 0/1' 'Progress: 0%' 'Status: stale'
  run bash "$RECONCILE" "$PLANNING_DIR"
  expect_status all-complete 0
  expect_file_line all-complete "$STATE_FILE" '^Status: complete$'
  expect_file_line all-complete "$STATE_FILE" '^Progress: 100%$'

  fresh_planning uat-issues
  skip_qa
  make_phase 01-alpha 1 complete
  write_uat 01-alpha issues_found
  write_state 'Phase: 1 of 1 (old)' 'Plans: 1/1' 'Progress: 100%' 'Status: stale'
  run bash "$RECONCILE" "$PLANNING_DIR"
  expect_status uat-issues 0
  expect_file_line uat-issues "$STATE_FILE" '^Status: needs_remediation$'

  fresh_planning uat-active
  skip_qa
  make_phase 01-alpha 1 complete
  write_uat 01-alpha in_progress
  write_state 'Phase: 1 of 1 (old)' 'Plans: 1/1' 'Progress: 100%' 'Status: stale'
  run bash "$RECONCILE" "$PLANNING_DIR"
  expect_status uat-active 0
  expect_file_line uat-active "$STATE_FILE" '^Status: needs_verification$'

  fresh_planning qa-gate-open
  make_phase 01-alpha 1 complete
  write_state 'Phase: 1 of 1 (old)' 'Plans: 1/1' 'Progress: 100%' 'Status: stale'
  run bash "$RECONCILE" "$PLANNING_DIR"
  expect_status qa-gate-open 0
  expect_file_line qa-gate-open "$STATE_FILE" '^Status: needs_verification$'

  fresh_planning status-lines
  skip_qa
  make_phase 01-alpha 1 complete
  make_phase 02-beta 2 partial
  make_phase 03-gamma 0
  write_state '# State' '## Phase Status' '- **Phase 1 (Old):** stale' '' '## Notes' 'keep me'
  run bash "$RECONCILE" "$PLANNING_DIR"
  expect_status status-lines 0
  expect_file_line status-lines "$STATE_FILE" '^- \*\*Phase 1 (Alpha):\*\* Complete$'
  expect_file_line status-lines "$STATE_FILE" '^- \*\*Phase 2 (Beta):\*\* In progress$'
  expect_file_line status-lines "$STATE_FILE" '^- \*\*Phase 3 (Gamma):\*\* Pending$'
  expect_no_file_line status-lines "$STATE_FILE" 'Old'
  expect_file_line status-lines "$STATE_FILE" '^keep me$'

  fresh_planning current-phase-section
  skip_qa
  make_phase 01-alpha 2 complete
  write_state '# State' '## Current Phase' 'Phase: 9 of 9 (old)' 'Plans: 9/9' '## Notes' 'keep me'
  run bash "$RECONCILE" "$PLANNING_DIR"
  expect_status current-phase-section 0
  expect_file_line current-phase-section "$STATE_FILE" '^Phase: 1 of 1 (Alpha)$'
  expect_file_line current-phase-section "$STATE_FILE" '^Plans: 1/2$'
  expect_file_line current-phase-section "$STATE_FILE" '^Status: active$'
  expect_file_line current-phase-section "$STATE_FILE" '^keep me$'
  expect_no_file_line current-phase-section "$STATE_FILE" 'old'

  fresh_planning roadmap-checklist
  skip_qa
  make_phase 01-alpha 1 complete
  make_phase 02-beta 1
  write_state 'Phase: 1 of 2 (x)' 'Plans: 0/0'
  printf '%s\n' '# Roadmap' '- [ ] Phase 1: Alpha' '- [x] Phase 2: Beta' > "$PLANNING_DIR/ROADMAP.md"
  run bash "$RECONCILE" "$PLANNING_DIR"
  expect_status roadmap-checklist 0
  expect_file_line roadmap-checklist "$PLANNING_DIR/ROADMAP.md" '^- \[x\] Phase 1: Alpha$'
  expect_file_line roadmap-checklist "$PLANNING_DIR/ROADMAP.md" '^- \[ \] Phase 2: Beta$'

  fresh_planning roadmap-missing-dir
  skip_qa
  make_phase 01-alpha 1
  make_phase 03-gamma 1
  write_state '# State' '## Phase Status' '- **Phase 2 (Dropped):** In progress' ''
  printf '%s\n' '# Roadmap' '- [ ] Phase 1: Alpha' '- [ ] Phase 2: Dropped' '- [ ] Phase 3: Gamma' > "$PLANNING_DIR/ROADMAP.md"
  run bash "$RECONCILE" "$PLANNING_DIR"
  expect_status roadmap-missing-dir 0
  expect_file_line roadmap-missing-dir "$STATE_FILE" '^- \*\*Phase 2 (Dropped):\*\* In progress$'
  expect_file_line roadmap-missing-dir "$STATE_FILE" '^- \*\*Phase 3 (Gamma):\*\* Planned$'

  fresh_planning roadmap-unresolvable
  skip_qa
  make_phase 02-beta 1 complete
  make_phase 03-gamma 1 complete
  printf '%s\n' '# Roadmap' '- [ ] Phase 1: Beta' '- [ ] Phase 5: Gamma' > "$PLANNING_DIR/ROADMAP.md"
  write_state 'Phase: 7 of 7 (untouched)'
  run bash "$RECONCILE" --json "$PLANNING_DIR"
  expect_case roadmap-unresolvable 0 "ROADMAP checklist numbering scheme is mixed or unresolvable"
  expect_file_line roadmap-unresolvable "$STATE_FILE" '^Phase: 7 of 7 (untouched)$'

  fresh_planning json-reconciled
  skip_qa
  make_phase 01-alpha 1 complete
  make_phase 02-beta 1
  write_state 'Phase: 1 of 2 (x)' 'Plans: 0/0'
  run bash "$RECONCILE" --json "$PLANNING_DIR"
  expect_case json-reconciled 0 '"status": "reconciled"'
  expect_output_has json-reconciled '"phase": 2'
  expect_output_has json-reconciled '"total": 2'
  expect_output_has json-reconciled '"phase_status": "ready"'

  fresh_planning skip-missing-state
  run bash "$RECONCILE" --json "$PLANNING_DIR"
  expect_case skip-missing-state 0 "missing STATE.md or phases directory"

  fresh_planning skip-no-phases
  write_state 'Phase: 1 of 1 (x)'
  run bash "$RECONCILE" --json "$PLANNING_DIR"
  expect_case skip-no-phases 0 "no canonical phases"

  fresh_planning silent-without-json
  run bash "$RECONCILE" "$PLANNING_DIR"
  expect_case_silent silent-without-json 0

  fresh_planning changed-file
  skip_qa
  make_phase 01-alpha 2 complete
  write_state 'Phase: 9 of 9 (old)' 'Plans: 9/9'
  run bash "$RECONCILE" --changed "$PLANNING_DIR/phases/01-alpha/01-SUMMARY.md"
  expect_status changed-file 0
  expect_file_line changed-file "$STATE_FILE" '^Plans: 1/2$'

  fresh_planning changed-file-outside
  skip_qa
  make_phase 01-alpha 2 complete
  write_state 'Phase: 9 of 9 (old)' 'Plans: 9/9'
  run bash "$RECONCILE" --json --changed "$TEST_ROOT/elsewhere/file.md"
  expect_case changed-file-outside 0 "planning root not found"
  expect_file_line changed-file-outside "$STATE_FILE" '^Plans: 9/9$'

  assert_no_case_failures
}

@test "state-updater hook: syncs STATE.md counts and status from the edited artifact" {
  fresh_planning plan-count
  make_phase 01-alpha 2 complete
  write_state 'Phase: 1 of 1 (Alpha)' 'Plans: 0/0' 'Progress: 0%' 'Status: ready'
  run bash -c 'printf "{\"tool_input\":{\"file_path\":\"%s\"}}" "$1" | bash "$2"' _ "$PLANNING_DIR/phases/01-alpha/01-SUMMARY.md" "$UPDATER"
  expect_status plan-count 0
  expect_file_line plan-count "$STATE_FILE" '^Plans: 1/2$'
  expect_file_line plan-count "$STATE_FILE" '^Progress: 50%$'
  expect_file_line plan-count "$STATE_FILE" '^Status: ready$'

  fresh_planning verification-pass
  make_phase 01-alpha 1 complete
  printf '%s\n' '---' 'result: pass' '---' > "$PLANNING_DIR/phases/01-alpha/01-VERIFICATION.md"
  write_state 'Phase: 1 of 1 (Alpha)' 'Plans: 0/0' 'Progress: 0%' 'Status: ready'
  run bash -c 'printf "{\"tool_input\":{\"file_path\":\"%s\"}}" "$1" | bash "$2"' _ "$PLANNING_DIR/phases/01-alpha/01-VERIFICATION.md" "$UPDATER"
  expect_status verification-pass 0
  expect_file_line verification-pass "$STATE_FILE" '^Status: complete$'
  expect_file_line verification-pass "$STATE_FILE" '^Progress: 100%$'

  fresh_planning verification-fail
  make_phase 01-alpha 1 complete
  printf '%s\n' '---' 'result: FAIL' '---' > "$PLANNING_DIR/phases/01-alpha/01-VERIFICATION.md"
  write_state 'Phase: 1 of 1 (Alpha)' 'Plans: 0/0' 'Progress: 0%' 'Status: ready'
  run bash -c 'printf "{\"tool_input\":{\"file_path\":\"%s\"}}" "$1" | bash "$2"' _ "$PLANNING_DIR/phases/01-alpha/01-VERIFICATION.md" "$UPDATER"
  expect_status verification-fail 0
  expect_file_line verification-fail "$STATE_FILE" '^Status: needs_remediation$'

  fresh_planning verification-partial
  make_phase 01-alpha 1 complete
  printf '%s\n' '---' 'result: Partial' '---' > "$PLANNING_DIR/phases/01-alpha/01-VERIFICATION.md"
  write_state 'Phase: 1 of 1 (Alpha)' 'Plans: 0/0' 'Progress: 0%' 'Status: ready'
  run bash -c 'printf "{\"tool_input\":{\"file_path\":\"%s\"}}" "$1" | bash "$2"' _ "$PLANNING_DIR/phases/01-alpha/01-VERIFICATION.md" "$UPDATER"
  expect_status verification-partial 0
  expect_file_line verification-partial "$STATE_FILE" '^Status: needs_remediation$'

  fresh_planning verification-unknown-result
  make_phase 01-alpha 1 complete
  printf '%s\n' '---' 'result: pending' '---' > "$PLANNING_DIR/phases/01-alpha/01-VERIFICATION.md"
  write_state 'Phase: 1 of 1 (Alpha)' 'Plans: 0/0' 'Progress: 0%' 'Status: ready'
  run bash -c 'printf "{\"tool_input\":{\"file_path\":\"%s\"}}" "$1" | bash "$2"' _ "$PLANNING_DIR/phases/01-alpha/01-VERIFICATION.md" "$UPDATER"
  expect_status verification-unknown-result 0
  expect_file_line verification-unknown-result "$STATE_FILE" '^Status: ready$'

  fresh_planning other-phase-untouched
  make_phase 01-alpha 1 complete
  make_phase 02-beta 2 complete
  write_state 'Phase: 1 of 2 (Alpha)' 'Plans: 0/0' 'Progress: 0%' 'Status: ready'
  run bash -c 'printf "{\"tool_input\":{\"file_path\":\"%s\"}}" "$1" | bash "$2"' _ "$PLANNING_DIR/phases/02-beta/01-SUMMARY.md" "$UPDATER"
  expect_status other-phase-untouched 0
  expect_file_line other-phase-untouched "$STATE_FILE" '^Plans: 0/0$'

  fresh_planning untracked-artifact
  make_phase 01-alpha 1 complete
  write_state 'Phase: 1 of 1 (Alpha)' 'Plans: 0/0' 'Progress: 0%' 'Status: ready'
  printf 'notes\n' > "$PLANNING_DIR/phases/01-alpha/NOTES.md"
  run bash -c 'printf "{\"tool_input\":{\"file_path\":\"%s\"}}" "$1" | bash "$2"' _ "$PLANNING_DIR/phases/01-alpha/NOTES.md" "$UPDATER"
  expect_status untracked-artifact 0
  expect_file_line untracked-artifact "$STATE_FILE" '^Plans: 0/0$'

  fresh_planning empty-input
  write_state 'Phase: 1 of 1 (Alpha)' 'Plans: 0/0'
  run bash -c 'printf "{}" | bash "$1"' _ "$UPDATER"
  expect_case_silent empty-input 0

  assert_no_case_failures
}
