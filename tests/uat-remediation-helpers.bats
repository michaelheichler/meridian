#!/usr/bin/env bats

load gate_case_helper
load gate_case_files

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS="$REPO_ROOT/scripts"
  TEST_ROOT="$(mktemp -d)"
  cd "$TEST_ROOT"
  reset_case_failures
}

teardown() {
  cd "$REPO_ROOT"
  chmod -R u+w "$TEST_ROOT" 2>/dev/null || true
  rm -rf "$TEST_ROOT"
}

fresh_phase() {
  PLANNING_DIR="$TEST_ROOT/$1/.lbwc-planning"
  PHASE_DIR="$PLANNING_DIR/phases/01-checkout"
  UAT_STATE="$PHASE_DIR/remediation/uat/.uat-remediation-stage"
  mkdir -p "$PHASE_DIR"
}

write_stage() {
  mkdir -p "$(dirname "$1")"
  printf 'stage=%s\nround=%s\nlayout=%s\n' "$2" "$3" "$4" > "$1"
}

write_issues_uat() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' '---' 'status: issues_found' 'completed: 2026-01-02' 'passed: 0' 'skipped: 0' 'issues: 1' 'total_tests: 1' '---' '### P1: Checkout' '- **Result:** issue' > "$1"
}

write_checkpoint_uat() {
  printf '%s\n' '---' 'status: in_progress' '---' "$@" > "$UAT_FILE"
}

@test "uat-remediation-state init: writes the authoritative round state" {
  fresh_phase init
  run bash "$SCRIPTS/uat-remediation-state.sh" init "$PHASE_DIR" major
  expect_case init 0 "research"
  expect_output_has init "round=01"
  expect_file_line init "$UAT_STATE" '^stage=research$'
  expect_file_line init "$UAT_STATE" '^layout=round-dir$'

  assert_no_case_failures
}

@test "extract-uat-resume: picks the active UAT file and reports the first open checkpoint" {
  fresh_phase round-dir
  write_stage "$UAT_STATE" verify 01 round-dir
  write_issues_uat "$PHASE_DIR/remediation/uat/round-01/R01-UAT.md"
  run bash "$SCRIPTS/extract-uat-resume.sh" "$PHASE_DIR"
  expect_case round-dir 0 "uat_path=$PHASE_DIR/remediation/uat/round-01/R01-UAT.md"

  fresh_phase round-file-missing
  write_stage "$UAT_STATE" verify 02 round-dir
  write_issues_uat "$PHASE_DIR/remediation/uat/round-01/R01-UAT.md"
  run bash "$SCRIPTS/extract-uat-resume.sh" "$PHASE_DIR"
  expect_case round-file-missing 0 "uat_resume=none"
  expect_output_lacks round-file-missing "uat_path="

  fresh_phase legacy-stage
  write_stage "$PHASE_DIR/remediation/.uat-remediation-stage" verify 01 legacy
  write_issues_uat "$PHASE_DIR/remediation/round-01/R01-UAT.md"
  run bash "$SCRIPTS/extract-uat-resume.sh" "$PHASE_DIR"
  expect_case legacy-stage 0 "uat_path=$PHASE_DIR/remediation/round-01/R01-UAT.md"

  fresh_phase phase-level-stage
  write_stage "$PHASE_DIR/.uat-remediation-stage" verify 01 legacy
  write_issues_uat "$PHASE_DIR/remediation/round-01/R01-UAT.md"
  run bash "$SCRIPTS/extract-uat-resume.sh" "$PHASE_DIR"
  expect_case phase-level-stage 0 "uat_path=$PHASE_DIR/remediation/round-01/R01-UAT.md"

  fresh_phase unknown-layout
  write_stage "$UAT_STATE" verify 01 spiral
  write_issues_uat "$PHASE_DIR/01-UAT.md"
  run bash "$SCRIPTS/extract-uat-resume.sh" "$PHASE_DIR"
  expect_case unknown-layout 0 "uat_path=$PHASE_DIR/01-UAT.md"

  fresh_phase stage-without-layout-or-round
  mkdir -p "$(dirname "$UAT_STATE")"
  printf 'stage=verify\n' > "$UAT_STATE"
  write_issues_uat "$PHASE_DIR/remediation/round-01/R01-UAT.md"
  run bash "$SCRIPTS/extract-uat-resume.sh" "$PHASE_DIR"
  expect_case stage-without-layout-or-round 0 "uat_path=$PHASE_DIR/remediation/round-01/R01-UAT.md"

  fresh_phase no-state-skips-source
  write_issues_uat "$PHASE_DIR/01-UAT.md"
  write_issues_uat "$PHASE_DIR/01-SOURCE-UAT.md"
  run bash "$SCRIPTS/extract-uat-resume.sh" "$PHASE_DIR"
  expect_case no-state-skips-source 0 "uat_path=$PHASE_DIR/01-UAT.md"

  fresh_phase no-uat-file
  run bash "$SCRIPTS/extract-uat-resume.sh" "$PHASE_DIR"
  expect_case no-uat-file 0 "uat_resume=none"

  run bash "$SCRIPTS/extract-uat-resume.sh" "$TEST_ROOT/not-a-dir"
  expect_case missing-phase-dir 0 "uat_resume=none"

  run bash "$SCRIPTS/extract-uat-resume.sh"
  expect_case no-argument 1 "Usage: extract-uat-resume.sh"

  assert_no_case_failures
}

@test "extract-uat-resume checkpoints: counts results and reports the first open one" {
  fresh_phase checkpoints
  UAT_FILE="$PHASE_DIR/01-UAT.md"

  write_checkpoint_uat '### P1: Cart' '- **Result:** pass' '### P2: Pay' '- **Scenario:** press pay' 'then wait' '- **Expected:** receipt shown' '- **Result:** {pass|skip|issue}' '### P3: Mail' '- **Result:** pass'
  run bash "$SCRIPTS/extract-uat-resume.sh" "$PHASE_DIR"
  expect_case first-open 0 "uat_resume=P2 uat_completed=2 uat_total=3"
  expect_output_has first-open "uat_resume_scenario=press pay then wait"
  expect_output_has first-open "uat_resume_expected=receipt shown"

  write_checkpoint_uat '### P1: Cart' '- **Result:** pass' '### P2: Pay' '- **Result:** SKIP' '### P3: Mail' '- **Result:** Partial'
  run bash "$SCRIPTS/extract-uat-resume.sh" "$PHASE_DIR"
  expect_case all-done 0 "uat_resume=all_done uat_completed=3 uat_total=3"

  write_checkpoint_uat '### P1: Cart' '- **Result:** pass' '### D1: Drift' '- **Deviation:** plan changed' '- **Source Plan:** 01-01' '- **Source Summary:** 01-01-SUMMARY.md' '- **Deviation Signature:** abc123' '- **Scenario:** ignored here' '- **Result:**'
  run bash "$SCRIPTS/extract-uat-resume.sh" "$PHASE_DIR"
  expect_case deviation-open 0 "uat_resume=D1 uat_completed=1 uat_total=2"
  expect_output_has deviation-open "uat_resume_deviation=plan changed"
  expect_output_has deviation-open "uat_resume_source_plan=01-01"
  expect_output_has deviation-open "uat_resume_source_summary=01-01-SUMMARY.md"
  expect_output_has deviation-open "uat_resume_deviation_signature=abc123"
  expect_output_lacks deviation-open "uat_resume_scenario="

  write_checkpoint_uat 'only prose' '## Notes' 'nothing to test'
  run bash "$SCRIPTS/extract-uat-resume.sh" "$PHASE_DIR"
  expect_case no-checkpoints 0 "uat_resume=none"
  expect_output_has no-checkpoints "uat_path=$UAT_FILE"

  assert_no_case_failures
}

@test "finalize-uat-status: rejects unfinished checkpoints" {
  fresh_phase finalize
  UAT_FILE="$PHASE_DIR/01-UAT.md"
  write_checkpoint_uat '### P1: Checkout' '- **Result:** pass' '### P2: Receipt'
  run bash "$SCRIPTS/finalize-uat-status.sh" "$UAT_FILE"
  expect_case finalize-missing-result 1 "missing Result line"

  assert_no_case_failures
}

@test "validate-uat-remediation-artifact: rejects a plan outside the active round" {
  fresh_phase validate
  write_stage "$UAT_STATE" plan 01 round-dir
  mkdir -p "$PHASE_DIR/remediation/uat/round-01"
  printf '%s\n' '---' 'phase: 01' '---' '# Plan' > "$PHASE_DIR/R01-PLAN.md"
  run bash "$SCRIPTS/validate-uat-remediation-artifact.sh" plan "$PHASE_DIR/R01-PLAN.md"
  expect_case validate-outside-round 1 "artifact_valid=false"

  assert_no_case_failures
}

@test "compile-verify-context-for-uat: selects remediation-only scope while a round is active" {
  fresh_phase compile
  write_stage "$UAT_STATE" execute 01 round-dir
  mkdir -p "$PHASE_DIR/remediation/uat/round-01"
  printf '%s\n' '---' 'plan: 01-01' '---' '# Plan' > "$PHASE_DIR/remediation/uat/round-01/R01-PLAN.md"
  run bash "$SCRIPTS/compile-verify-context-for-uat.sh" "$PHASE_DIR"
  expect_case compile-remediation 0 "verify_scope=remediation"

  assert_no_case_failures
}

@test "create-remediation-phase: seeds the roadmap and is idempotent" {
  local planning_dir archived_phase
  fresh_phase create
  planning_dir="$PLANNING_DIR"
  archived_phase="$planning_dir/milestones/v1/phases/02-checkout"
  rm -rf "$PHASE_DIR"
  mkdir -p "$archived_phase"
  printf '%s\n' '# Test Project' > "$planning_dir/PROJECT.md"
  printf '%s\n' '---' 'status: issues_found' '---' '# UAT' > "$archived_phase/02-UAT.md"

  run bash "$SCRIPTS/create-remediation-phase.sh" "$planning_dir" "$archived_phase"
  expect_case create-first 0 "phase=01"
  expect_path create-first "$planning_dir/phases/01-remediate-v1-checkout/01-CONTEXT.md"
  expect_path create-first "$planning_dir/phases/01-remediate-v1-checkout/01-SOURCE-UAT.md"
  expect_file_line create-first "$planning_dir/ROADMAP.md" '^# UAT Remediation Roadmap$'
  expect_file_line create-first "$planning_dir/STATE.md" '^\*\*Milestone:\*\* UAT Remediation$'

  run bash "$SCRIPTS/create-remediation-phase.sh" "$planning_dir" "$archived_phase"
  expect_case create-repeat 0 "phase=01"
  [ "$(find "$planning_dir/phases" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" -eq 1 ] \
    || record_case_failure create-repeat "second run created another phase directory"

  assert_no_case_failures
}

@test "prepare-reverification gates: refuses to advance until the UAT and stage allow it" {
  run bash "$SCRIPTS/prepare-reverification.sh"
  expect_case no-argument 1 "Usage: prepare-reverification.sh"

  run bash "$SCRIPTS/prepare-reverification.sh" "$TEST_ROOT/not-a-dir"
  expect_case missing-dir 1 "phase directory does not exist"

  fresh_phase no-uat
  run bash "$SCRIPTS/prepare-reverification.sh" "$PHASE_DIR"
  expect_case no-uat 0 "skipped=already_archived"

  fresh_phase unfinished-uat
  UAT_FILE="$PHASE_DIR/01-UAT.md"
  write_checkpoint_uat '### P1: Checkout' '- **Result:** pass' '### P2: Receipt'
  run bash "$SCRIPTS/prepare-reverification.sh" "$PHASE_DIR"
  expect_case unfinished-uat 1 "current UAT is not finalized as 'issues_found'"
  expect_output_has unfinished-uat "missing Result line"

  fresh_phase finalized-complete
  printf '%s\n' '---' 'status: complete' '---' '### P1: Checkout' '- **Result:** pass' > "$PHASE_DIR/01-UAT.md"
  run bash "$SCRIPTS/prepare-reverification.sh" "$PHASE_DIR"
  expect_case finalized-complete 1 "current UAT is not 'issues_found'"
  expect_output_has finalized-complete "status='complete'"

  fresh_phase finalized-by-script
  UAT_FILE="$PHASE_DIR/01-UAT.md"
  write_checkpoint_uat '### P1: Checkout' '- **Result:** issue'
  run bash "$SCRIPTS/prepare-reverification.sh" "$PHASE_DIR"
  expect_case finalized-by-script 1 "remediation stage is 'none'"
  expect_file_line finalized-by-script "$UAT_FILE" '^status: issues_found$'

  fresh_phase stage-in-progress
  write_issues_uat "$PHASE_DIR/01-UAT.md"
  write_stage "$UAT_STATE" execute 01 round-dir
  run bash "$SCRIPTS/prepare-reverification.sh" "$PHASE_DIR"
  expect_case stage-in-progress 1 "remediation stage is 'execute'"

  assert_no_case_failures
}

@test "prepare-reverification flat UAT: archives it into the next round file" {
  fresh_phase flat-done
  write_issues_uat "$PHASE_DIR/01-UAT.md"
  write_stage "$PHASE_DIR/.uat-remediation-stage" done 01 legacy
  run bash "$SCRIPTS/prepare-reverification.sh" "$PHASE_DIR"
  expect_case flat-done 0 "archived=01-UAT.md"
  expect_output_has flat-done "round_file=01-UAT-round-01.md"
  expect_output_has flat-done "phase=01"
  expect_output_has flat-done "layout=flat"
  expect_path flat-done "$PHASE_DIR/01-UAT-round-01.md"
  expect_no_path flat-done "$PHASE_DIR/01-UAT.md"

  fresh_phase flat-legacy-stage
  write_issues_uat "$PHASE_DIR/01-UAT.md"
  printf 'verify\n' > "$PHASE_DIR/.uat-remediation-stage"
  run bash "$SCRIPTS/prepare-reverification.sh" "$PHASE_DIR"
  expect_case flat-legacy-stage 0 "archived=01-UAT.md"
  expect_output_has flat-legacy-stage "layout=flat"
  expect_file_line flat-legacy-stage "$UAT_STATE" '^layout=round-dir$'
  expect_no_path flat-legacy-stage "$PHASE_DIR/.uat-remediation-stage"

  fresh_phase flat-third-round-warns
  write_issues_uat "$PHASE_DIR/01-UAT.md"
  write_issues_uat "$PHASE_DIR/01-UAT-round-01.md"
  write_issues_uat "$PHASE_DIR/01-UAT-round-02.md"
  write_stage "$PHASE_DIR/.uat-remediation-stage" done 02 legacy
  printf '{"max_uat_remediation_rounds": 9}\n' > "$PLANNING_DIR/config.json"
  run bash "$SCRIPTS/prepare-reverification.sh" "$PHASE_DIR"
  expect_case flat-third-round-warns 0 "round_file=01-UAT-round-03.md"
  expect_output_has flat-third-round-warns "reverification_warning="

  fresh_phase flat-cap-reached
  write_issues_uat "$PHASE_DIR/01-UAT.md"
  write_stage "$PHASE_DIR/.uat-remediation-stage" done 01 legacy
  printf '{"max_uat_remediation_rounds": 1}\n' > "$PLANNING_DIR/config.json"
  run bash "$SCRIPTS/prepare-reverification.sh" "$PHASE_DIR"
  expect_case flat-cap-reached 0 "skipped=cap_reached"
  expect_output_has flat-cap-reached "cap_reached=true"
  expect_path flat-cap-reached "$PHASE_DIR/01-UAT.md"

  assert_no_case_failures
}

@test "prepare-reverification round-dir UAT: keeps, archives or defers by round" {
  fresh_phase round-current-archives
  write_issues_uat "$PHASE_DIR/remediation/uat/round-01/R01-UAT.md"
  write_stage "$UAT_STATE" verify 01 round-dir
  printf '{"max_uat_remediation_rounds": 9}\n' > "$PLANNING_DIR/config.json"
  run bash "$SCRIPTS/prepare-reverification.sh" "$PHASE_DIR"
  expect_case round-current-archives 0 "archived=in-round-dir"
  expect_output_has round-current-archives "round_file=R01-UAT.md"
  expect_output_has round-current-archives "phase=01"

  fresh_phase round-current-cap
  write_issues_uat "$PHASE_DIR/remediation/uat/round-01/R01-UAT.md"
  write_stage "$UAT_STATE" verify 01 round-dir
  printf '{"max_uat_remediation_rounds": 1}\n' > "$PLANNING_DIR/config.json"
  run bash "$SCRIPTS/prepare-reverification.sh" "$PHASE_DIR"
  expect_case round-current-cap 0 "skipped=cap_reached"

  fresh_phase round-older-defers
  write_issues_uat "$PHASE_DIR/remediation/uat/round-01/R01-UAT.md"
  write_stage "$UAT_STATE" done 02 round-dir
  run bash "$SCRIPTS/prepare-reverification.sh" "$PHASE_DIR"
  expect_case round-older-defers 0 "skipped=ready_for_verify"

  fresh_phase flat-round-dir-layout-kept
  write_issues_uat "$PHASE_DIR/01-UAT.md"
  write_stage "$PHASE_DIR/remediation/.uat-remediation-stage" verify 01 round-dir
  run bash "$SCRIPTS/prepare-reverification.sh" "$PHASE_DIR"
  expect_case flat-round-dir-layout-kept 0 "archived=kept"

  assert_no_case_failures
}

write_deviation_uat() {
  UAT_FILE="$PHASE_DIR/01-UAT.md"
  printf '%s\n' '---' 'status: complete' '---' \
    '### D1: Drift' '- **Deviation:** plan changed' '- **Source Plan:** 01-01' \
    '- **Source Summary:** 01-01-SUMMARY.md' '- **Deviation Signature:** sig-one' \
    '- **Result:** pass' '- **Disposition:** accepted-process-exception' \
    '### D2: Rejected' '- **Deviation:** other drift' '- **Source Plan:** 01-02' \
    '- **Source Summary:** 01-02-SUMMARY.md' '- **Deviation Signature:** sig-two' \
    '- **Result:** issue' '- **Disposition:** rejected' \
    '### D3: No signature' '- **Deviation:** unsigned' '- **Result:** pass' \
    '- **Disposition:** accepted-process-exception' \
    '### D5: Failed but accepted' '- **Deviation:** d five' '- **Source Plan:** 01-05' \
    '- **Source Summary:** s5.md' '- **Deviation Signature:** sig-five' \
    '- **Result:** issue' '- **Disposition:** accepted-process-exception' \
    '### D6: Passed but rejected' '- **Deviation:** d six' '- **Source Plan:** 01-06' \
    '- **Source Summary:** s6.md' '- **Deviation Signature:** sig-six' \
    '- **Result:** pass' '- **Disposition:** rejected' > "$UAT_FILE"
}

@test "track-uat-deviations signature: hashes plan, path and text and rejects blanks" {
  run bash "$SCRIPTS/track-uat-deviations.sh" signature plan-1 summary.md drifted
  expect_case signature-known-digest 0 "1a43e65dee4c5fa74a33a97505f914669d879205b5e45256ce0127ff7df5d968"

  run bash "$SCRIPTS/track-uat-deviations.sh" signature "  plan-1 " summary.md "drifted  "
  expect_case signature-trims-whitespace 0 "1a43e65dee4c5fa74a33a97505f914669d879205b5e45256ce0127ff7df5d968"

  run bash "$SCRIPTS/track-uat-deviations.sh" signature plan-1 summary.md "drifted again"
  expect_status signature-text-changes-digest 0
  expect_output_lacks signature-text-changes-digest "1a43e65dee4c5fa74a33a97505f914669d879205b5e45256ce0127ff7df5d968"

  run bash "$SCRIPTS/track-uat-deviations.sh" signature "" summary.md drifted
  expect_case signature-blank-plan 1 "source plan is required"

  run bash "$SCRIPTS/track-uat-deviations.sh" signature plan-1 "" drifted
  expect_case signature-blank-path 1 "source path is required"

  run bash "$SCRIPTS/track-uat-deviations.sh" signature plan-1 summary.md " "
  expect_case signature-blank-text 1 "deviation text is required"

  run bash "$SCRIPTS/track-uat-deviations.sh" signature plan-1 summary.md
  expect_case signature-wrong-arity 1 "Usage:"

  run bash "$SCRIPTS/track-uat-deviations.sh" bogus
  expect_case unknown-command 1 "Usage:"

  assert_no_case_failures
}

@test "track-uat-deviations record-from-uat and accepted-signatures: sync accepted deviations into the registry" {
  local registry

  fresh_phase registry
  registry="$PHASE_DIR/remediation/uat/accepted-deviations.json"
  write_deviation_uat
  run bash "$SCRIPTS/track-uat-deviations.sh" accepted-signatures "$PHASE_DIR"
  expect_case_silent signatures-before-record 0

  run bash "$SCRIPTS/track-uat-deviations.sh" record-from-uat "$PHASE_DIR" "$UAT_FILE"
  expect_status record-first 0
  expect_path record-first "$registry"
  [ "$(jq -r '.accepted | length' "$registry")" = "1" ] || record_case_failure record-first "registry lacks exactly one accepted record"
  [ "$(jq -r '.accepted[0].signature' "$registry")" = "sig-one" ] || record_case_failure record-first "wrong signature"
  [ "$(jq -r '.accepted[0].source_plan' "$registry")" = "01-01" ] || record_case_failure record-first "wrong source plan"
  [ "$(jq -r '.accepted[0].text' "$registry")" = "plan changed" ] || record_case_failure record-first "wrong text"
  [ "$(jq -r '.accepted[0].accepted_in' "$registry")" = "01-UAT.md" ] || record_case_failure record-first "wrong accepted_in"
  [ "$(jq -r '.phase' "$registry")" = "01-checkout" ] || record_case_failure record-first "wrong phase name"

  run bash "$SCRIPTS/track-uat-deviations.sh" record-from-uat "$PHASE_DIR" "$UAT_FILE"
  expect_status record-repeat 0
  [ "$(jq -r '.accepted | length' "$registry")" = "1" ] || record_case_failure record-repeat "repeat run duplicated the record"

  printf '%s\n' '---' 'status: complete' '---' '### D4: More' '- **Deviation:** later drift' '- **Source Plan:** 01-01' '- **Source Summary:** 01-01-SUMMARY.md' '- **Deviation Signature:** sig-four' '- **Result:** pass' '- **Disposition:** accepted-process-exception' > "$PHASE_DIR/02-UAT.md"
  run bash "$SCRIPTS/track-uat-deviations.sh" record-from-uat "$PHASE_DIR" "$PHASE_DIR/02-UAT.md"
  expect_status record-merge 0
  [ "$(jq -r '.accepted | length' "$registry")" = "2" ] || record_case_failure record-merge "merge lost or duplicated records"

  run bash "$SCRIPTS/track-uat-deviations.sh" accepted-signatures "$PHASE_DIR"
  expect_case signatures-after-record 0 "sig-one"
  expect_output_has signatures-after-record "sig-four"
  expect_output_lacks signatures-after-record "sig-two"

  run bash "$SCRIPTS/track-uat-deviations.sh" record-from-uat "$TEST_ROOT/missing-dir" "$UAT_FILE"
  expect_case record-missing-phase 1 "phase dir not found"

  run bash "$SCRIPTS/track-uat-deviations.sh" record-from-uat "$PHASE_DIR" "$PHASE_DIR/missing-UAT.md"
  expect_case record-missing-uat 1 "UAT file not found"

  run bash "$SCRIPTS/track-uat-deviations.sh" accepted-signatures
  expect_case signatures-wrong-arity 1 "Usage:"

  assert_no_case_failures
}

write_todo_state() {
  STATE_FILE="$PLANNING_DIR/STATE.md"
  printf '%s\n' "$@" > "$STATE_FILE"
}

@test "track-uat-deviations todo-from-uat: files an accepted deviation into STATE.md once" {
  fresh_phase todo-flat
  write_deviation_uat
  write_todo_state '# State' '## Todos' 'None.' '## Notes' 'keep me'
  run bash "$SCRIPTS/track-uat-deviations.sh" todo-from-uat "$PHASE_DIR" "$UAT_FILE" D1
  expect_case todo-flat 0 "todo_status=added"
  expect_output_has todo-flat "todo_ref="
  expect_output_has todo-flat "detail_status=ok"
  expect_file_line todo-flat "$STATE_FILE" '^- \[UAT-DEVIATION\] 01-01: plan changed (phase 01, see 01-01-SUMMARY.md)'
  expect_no_file_line todo-flat "$STATE_FILE" '^None\.$'
  expect_file_line todo-flat "$STATE_FILE" '^keep me$'
  expect_path todo-flat "$PLANNING_DIR/todo-details.json"

  run bash "$SCRIPTS/track-uat-deviations.sh" todo-from-uat "$PHASE_DIR" "$UAT_FILE" D1
  expect_case todo-repeat 0 "todo_status=already_tracked"
  [ "$(grep -c 'UAT-DEVIATION' "$STATE_FILE")" = "1" ] || record_case_failure todo-repeat "todo line was duplicated"

  fresh_phase todo-pending-section
  write_deviation_uat
  write_todo_state '# State' '### Pending Todos' '- existing item' '### Completed Todos' '- done item'
  run bash "$SCRIPTS/track-uat-deviations.sh" todo-from-uat "$PHASE_DIR" "$UAT_FILE" D1
  expect_case todo-pending-section 0 "todo_status=added"
  expect_file_line todo-pending-section "$STATE_FILE" '^- existing item$'
  expect_file_line todo-pending-section "$STATE_FILE" '^- done item$'
  expect_file_line todo-pending-section "$STATE_FILE" 'UAT-DEVIATION'
  [ "$(grep -n 'UAT-DEVIATION' "$STATE_FILE" | cut -d: -f1)" -lt "$(grep -n '^### Completed Todos$' "$STATE_FILE" | cut -d: -f1)" ] \
    || record_case_failure todo-pending-section "todo landed after the Completed Todos header"

  fresh_phase todo-no-section
  write_deviation_uat
  write_todo_state '# State' 'body text'
  run bash "$SCRIPTS/track-uat-deviations.sh" todo-from-uat "$PHASE_DIR" "$UAT_FILE" D1
  expect_case todo-no-section 0 "todo_status=added"
  expect_file_line todo-no-section "$STATE_FILE" '^## Todos$'
  expect_file_line todo-no-section "$STATE_FILE" 'UAT-DEVIATION'

  fresh_phase todo-flat-existing
  write_deviation_uat
  write_todo_state '# State' '## Todos' '- first item' '## Notes' 'tail'
  run bash "$SCRIPTS/track-uat-deviations.sh" todo-from-uat "$PHASE_DIR" "$UAT_FILE" D1
  expect_case todo-flat-existing 0 "todo_status=added"
  expect_file_line todo-flat-existing "$STATE_FILE" '^- first item$'
  expect_file_line todo-flat-existing "$STATE_FILE" '^tail$'

  fresh_phase todo-long-text
  UAT_FILE="$PHASE_DIR/01-UAT.md"
  printf '%s\n' '---' '---' '### D1: Long' "- **Deviation:** $(printf 'word %.0s' $(seq 1 60))" '- **Source Plan:** 01-01' '- **Source Summary:** s.md' '- **Deviation Signature:** sig' '- **Result:** pass' '- **Disposition:** accepted-process-exception' > "$UAT_FILE"
  write_todo_state '# State' '## Todos' 'None.'
  run bash "$SCRIPTS/track-uat-deviations.sh" todo-from-uat "$PHASE_DIR" "$UAT_FILE" D1
  expect_case todo-long-text 0 "todo_status=added"
  expect_output_has todo-long-text "... (phase 01"

  assert_no_case_failures
}

@test "track-uat-deviations todo-from-uat gates: skips what is not an accepted, complete, persistable deviation" {
  fresh_phase gate-not-accepted
  write_deviation_uat
  write_todo_state '# State' '## Todos' 'None.'
  run bash "$SCRIPTS/track-uat-deviations.sh" todo-from-uat "$PHASE_DIR" "$UAT_FILE" D2
  expect_case gate-not-accepted 0 "todo_status=not_accepted"
  expect_no_file_line gate-not-accepted "$STATE_FILE" 'UAT-DEVIATION'

  run bash "$SCRIPTS/track-uat-deviations.sh" todo-from-uat "$PHASE_DIR" "$UAT_FILE" D5
  expect_case gate-failed-result 0 "todo_status=not_accepted"

  run bash "$SCRIPTS/track-uat-deviations.sh" todo-from-uat "$PHASE_DIR" "$UAT_FILE" D6
  expect_case gate-rejected-disposition 0 "todo_status=not_accepted"

  run bash "$SCRIPTS/track-uat-deviations.sh" todo-from-uat "$PHASE_DIR" "$UAT_FILE" D3
  expect_case gate-missing-metadata 0 "todo_status=missing_metadata"

  run bash "$SCRIPTS/track-uat-deviations.sh" todo-from-uat "$PHASE_DIR" "$UAT_FILE" D9
  expect_case gate-unknown-checkpoint 0 "todo_status=missing_metadata"

  run bash "$SCRIPTS/track-uat-deviations.sh" todo-from-uat "$PHASE_DIR" "$UAT_FILE" P1
  expect_case gate-bad-checkpoint-id 1 "checkpoint id must look like DNN"

  run bash "$SCRIPTS/track-uat-deviations.sh" todo-from-uat "$TEST_ROOT/missing-dir" "$UAT_FILE" D1
  expect_case gate-missing-phase 1 "phase dir not found"

  run bash "$SCRIPTS/track-uat-deviations.sh" todo-from-uat "$PHASE_DIR" "$PHASE_DIR/missing-UAT.md" D1
  expect_case gate-missing-uat 1 "UAT file not found"

  fresh_phase gate-no-state-file
  write_deviation_uat
  run bash "$SCRIPTS/track-uat-deviations.sh" todo-from-uat "$PHASE_DIR" "$UAT_FILE" D1
  expect_case gate-no-state-file 0 "todo_status=no_state_file"

  fresh_phase gate-state-not-writable
  write_deviation_uat
  write_todo_state '# State' '## Todos' 'None.'
  chmod 555 "$PLANNING_DIR"
  run bash "$SCRIPTS/track-uat-deviations.sh" todo-from-uat "$PHASE_DIR" "$UAT_FILE" D1
  chmod 755 "$PLANNING_DIR"
  expect_case gate-state-not-writable 0 "todo_status=state_update_failed"
  expect_output_has gate-state-not-writable "todo_warning=STATE.md todo update failed"
  expect_no_file_line gate-state-not-writable "$STATE_FILE" 'UAT-DEVIATION'

  assert_no_case_failures
}
