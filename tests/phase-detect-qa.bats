#!/usr/bin/env bats

load phase-detect-helpers

setup() { pd_setup; }
teardown() { pd_teardown; }

PD_QA_DIR="$PD_PHASES/01-test/remediation/qa"

pd_verification() {
  local file="$1"
  shift
  pd_md "$file" '---' "$@" '---' '# Verification' 'Checked.'
}

pd_original_fail() {
  pd_md "$PD_PHASES/01-test/01-VERIFICATION.md" '---' 'result: FAIL' 'writer: write-verification.sh' '---' \
    '## Must-Have Checks' \
    '| ID | Category | Description | Status | Evidence |' \
    '|----|----------|-------------|--------|----------|' \
    '| FAIL-01 | must_have | Original failure | FAIL | Missing |'
}

pd_round_plan() {
  local round="$1" type="$2" rationale="$3"
  pd_md "$PD_QA_DIR/round-$round/R$round-PLAN.md" '---' "round: $round" 'fail_classifications:' \
    "  - {id: \"FAIL-01\", type: \"$type\", rationale: \"$rationale\"}" '---'
}

pd_round_summary() {
  local round="$1"
  shift
  local -a files=()
  local path
  for path in "$@"; do
    files+=("  - $path")
  done
  pd_md "$PD_QA_DIR/round-$round/R$round-SUMMARY.md" '---' "plan: R$round" 'status: complete' 'files_modified:' "${files[@]}" \
    'deviations: []' '---'
}

pd_stage_done() {
  local round="$1" anchor="$2"
  pd_md "$PD_QA_DIR/.qa-remediation-stage" 'stage=done' "round=$round" "round_started_at_commit=${anchor}"
}

pd_round_pass() {
  local round="$1" commit="$2"
  pd_md "$PD_QA_DIR/round-$round/R$round-VERIFICATION.md" '---' 'result: PASS' 'writer: write-verification.sh' \
    'plans_verified:' "  - R$round" "verified_at_commit: ${commit}" '---' '# Verification' 'Passed after remediation.'
}

sc_qa() {
  local head
  pd_project
  pd_done_flat 01-test
  head="$(git rev-parse HEAD)"
  case "$1" in
    missing_artifact) ;;
    pass) pd_verified_pass "$PD_PHASES/01-test/01-VERIFICATION.md" 01 "$head" ;;
    legacy_pass)
      pd_md "$PD_PHASES/01-test/01-VERIFICATION.md" '---' 'status: PASS' 'writer: write-verification.sh' 'plans_verified:' '  - 01' \
        "verified_at_commit: ${head}" '---' '# Verification' 'Legacy PASS artifact.'
      ;;
    result_overrides_legacy)
      pd_md "$PD_PHASES/01-test/01-VERIFICATION.md" '---' 'result: FAIL' 'status: PASS' 'writer: write-verification.sh' \
        'plans_verified:' '  - 01' "verified_at_commit: ${head}" '---' '# Verification' 'Result wins.'
      ;;
    blank_result | unrecognized_result)
      pd_md "$PD_PHASES/01-test/01-VERIFICATION.md" '---' "result: $([ "$1" = blank_result ] || echo MAYBE)" 'status: PASS' \
        'writer: write-verification.sh' 'plans_verified:' '  - 01' "verified_at_commit: ${head}" '---' '# Verification' 'Invalid.'
      ;;
    pass_with_known_issues)
      pd_verified_pass "$PD_PHASES/01-test/01-VERIFICATION.md" 01 "$head"
      pd_known_issues "$PD_PHASES/01-test/known-issues.json" 01 01-01-SUMMARY.md 01-VERIFICATION.md 0 2
      ;;
    fail_with_preexisting_table)
      pd_md "$PD_PHASES/01-test/01-VERIFICATION.md" '---' 'result: FAIL' 'writer: write-verification.sh' 'plans_verified:' '  - 01' \
        "verified_at_commit: ${head}" '---' '' '## Pre-existing Issues' '' '| Test | File | Error |' '|------|------|-------|' \
        '| FIGIRegistryServiceTests | Tests/FIGIRegistryServiceTests.swift | compositeFigi missing |'
      ;;
    brownfield_plain) pd_verified_pass "$PD_PHASES/01-test/VERIFICATION.md" 01 "$head" ;;
    latest_wave)
      pd_md "$PD_PHASES/01-test/01-VERIFICATION-wave1.md" '---' 'result: FAIL' '---' '# Verification' 'Wave 1 failed.'
      pd_verified_pass "$PD_PHASES/01-test/01-VERIFICATION-wave2.md" 01 "$head"
      ;;
    fail) pd_verification "$PD_PHASES/01-test/01-VERIFICATION.md" 'result: FAIL' ;;
    partial) pd_verification "$PD_PHASES/01-test/01-VERIFICATION.md" 'result: PARTIAL' ;;
    legacy_partial) pd_verification "$PD_PHASES/01-test/01-VERIFICATION.md" 'status: PARTIAL' ;;
    structured_gate_fail | leading_blank_summary)
      if [ "$1" = structured_gate_fail ]; then
        pd_md "$PD_PHASES/01-test/01-SUMMARY.md" '---' 'status: complete' 'deviations:' '  - Changed API approach' '---'
      else
        pd_md "$PD_PHASES/01-test/01-SUMMARY.md" '' '---' 'status: complete' '---'
      fi
      pd_md "$PD_PHASES/01-test/01-VERIFICATION.md" '---' 'result: PASS' 'writer: ' '---' '# Verification' 'Passed.'
      ;;
  esac
}

sc_qa_stage() {
  pd_project
  pd_done_flat 01-test
  case "$1" in
    execute | plan | verify)
      pd_verification "$PD_PHASES/01-test/01-VERIFICATION.md" 'result: FAIL'
      pd_md "$PD_QA_DIR/.qa-remediation-stage" "stage=$1" "round=$([ "$1" = plan ] && echo 02 || echo 01)"
      ;;
    corrupt_stage)
      pd_md "$PD_QA_DIR/.qa-remediation-stage" 'stage=garbage' 'round=01'
      ;;
    done_round_fails)
      pd_verification "$PD_PHASES/01-test/01-VERIFICATION.md" 'result: FAIL'
      pd_md "$PD_QA_DIR/.qa-remediation-stage" 'stage=done' 'round=01'
      pd_verification "$PD_QA_DIR/round-01/R01-VERIFICATION.md" 'result: FAIL'
      ;;
    done_round_missing)
      pd_md "$PD_QA_DIR/.qa-remediation-stage" 'stage=done' 'round=01'
      ;;
    done_round_missing_phase_pass)
      pd_md "$PD_QA_DIR/.qa-remediation-stage" 'stage=done' 'round=01'
      pd_md "$PD_PHASES/01-test/01-VERIFICATION.md" '---' 'result: PASS' "verified_at_commit: $(git rev-parse HEAD)" '---' \
        '# Verification' 'Passed.'
      ;;
    done_corrupt_round)
      pd_md "$PD_QA_DIR/.qa-remediation-stage" 'stage=done' 'round=abc'
      pd_md "$PD_PHASES/01-test/01-VERIFICATION.md" '---' 'result: PASS' "verified_at_commit: $(git rev-parse HEAD)" '---' \
        '# Verification' 'Passed.'
      ;;
  esac
}

sc_qa_git() {
  local verified
  pd_project
  pd_done_flat 01-test
  case "$1" in
    stale_commit)
      pd_commit_file app.py 'print("old")' "old app"
      verified="$(git rev-parse HEAD)"
      pd_verified_pass "$PD_PHASES/01-test/01-VERIFICATION.md" 01 "$verified"
      pd_commit_file app.py 'print("new")' "new app"
      ;;
    brownfield_after_commit)
      pd_commit_file app.py 'print("before")' "before qa"
      pd_md "$PD_PHASES/01-test/01-VERIFICATION.md" '---' 'result: PASS' 'writer: write-verification.sh' 'plans_verified:' '  - 01' \
        '---' '# Verification' 'Passed.'
      pd_commit_file app.py 'print("after")' "after qa"
      ;;
    uncommitted_change)
      pd_commit_file app.py 'print("clean")' "clean app"
      pd_verified_pass "$PD_PHASES/01-test/01-VERIFICATION.md" 01 "$(git rev-parse HEAD)"
      echo 'print("dirty")' > app.py
      ;;
    unrelated_dirt)
      pd_md "$PD_PHASES/01-test/01-PLAN.md" '---' 'files_modified: [app.py]' 'files_touched: [app.py]' '---'
      echo 'print("clean")' > app.py
      echo 'tracked' > unrelated.txt
      git add app.py unrelated.txt
      git commit -m "phase product" --quiet
      pd_verified_pass "$PD_PHASES/01-test/01-VERIFICATION.md" 01 "$(git rev-parse HEAD)"
      echo 'changed elsewhere' > unrelated.txt
      echo 'untracked elsewhere' > elsewhere.sh
      ;;
    remediated_after_commit)
      pd_commit_file app.py 'print("before")' "before remediated qa"
      pd_original_fail
      pd_round_plan 01 process-exception "Fixture documents a structurally valid remediated round"
      pd_round_summary 01 ".lbwc-planning/phases/01-test/remediation/qa/round-01/R01-SUMMARY.md"
      pd_md "$PD_QA_DIR/round-01/R01-VERIFICATION.md" '---' 'result: PASS' 'writer: write-verification.sh' 'plans_verified:' '  - R01' \
        '---' '# Verification' 'Passed.'
      pd_md "$PD_QA_DIR/.qa-remediation-stage" 'stage=done' 'round=01'
      pd_commit_file app.py 'print("after")' "after remediated qa"
      ;;
  esac
}

sc_qa_round() {
  local anchor
  pd_project
  pd_done_flat 01-test
  pd_original_fail
  case "$1" in
    remediated)
      pd_round_plan 01 process-exception "Fixture documents a structurally valid remediated round"
      pd_round_summary 01 README.md ".lbwc-planning/phases/01-test/remediation/qa/round-01/R01-SUMMARY.md"
      anchor="$(git rev-parse HEAD)"
      pd_md "$PD_PHASES/01-test/01-SUMMARY.md" '---' 'status: complete' '---' '# Summary' 'Documented historical process exception.'
      echo "remediation notes" > README.md
      git add README.md "$PD_PHASES/01-test/01-SUMMARY.md"
      git commit -m "document remediation summary" --quiet
      pd_stage_done 01 "$anchor"
      pd_round_pass 01 "$(git rev-parse HEAD)"
      ;;
    second_round)
      pd_md "$PD_QA_DIR/round-01/R01-VERIFICATION.md" '---' 'result: PASS' 'writer: write-verification.sh' 'plans_verified:' '  - R01' '---' \
        '## Checks'
      pd_round_plan 02 process-exception "Fixture documents a structurally valid remediated round"
      pd_round_summary 02 README.md ".lbwc-planning/phases/01-test/remediation/qa/round-02/R02-SUMMARY.md"
      anchor="$(git rev-parse HEAD)"
      pd_md "$PD_PHASES/01-test/01-SUMMARY.md" '---' 'status: complete' '---' '# Summary' 'Round 02 documented the historical process exception.'
      echo "round two docs" > README.md
      git add README.md "$PD_PHASES/01-test/01-SUMMARY.md"
      git commit -m "round two summary evidence" --quiet
      pd_stage_done 02 "$anchor"
      pd_round_pass 02 "$(git rev-parse HEAD)"
      ;;
    known_issues_keep_failed)
      anchor="$(git rev-parse HEAD)"
      pd_round_plan 01 code-fix "Need a fix"
      pd_round_summary 01 README.md
      pd_stage_done 01 "$anchor"
      pd_round_pass 01 "$anchor"
      pd_known_issues "$PD_PHASES/01-test/known-issues.json" 01 01-01-SUMMARY.md remediation/qa/round-01/R01-VERIFICATION.md 1 3
      ;;
    resume_with_stale_phase_issues)
      anchor="$(git rev-parse HEAD)"
      pd_md "$PD_PHASES/01-test/01-VERIFICATION.md" '---' 'result: PASS' 'writer: write-verification.sh' 'plans_verified:' '  - 01' \
        "verified_at_commit: ${anchor}" '---' '' '## Pre-existing Issues' '' '| Test | File | Error |' '|------|------|-------|' \
        '| FIGIRegistryServiceTests | Tests/FIGIRegistryServiceTests.swift | stale phase-level issue |'
      pd_round_plan 01 code-fix "Need a real fix"
      pd_round_summary 01 src/Fix.swift README.md ".lbwc-planning/phases/01-test/01-SUMMARY.md"
      mkdir -p src
      echo "real code fix" > src/Fix.swift
      echo "round pass docs" > README.md
      pd_md "$PD_PHASES/01-test/01-SUMMARY.md" '---' 'status: complete' '---' '# Summary' 'Round 01 documented the remediation outcome.'
      git add src/Fix.swift README.md "$PD_PHASES/01-test/01-SUMMARY.md"
      git commit -m "round pass summary evidence" --quiet
      pd_stage_done 01 "$anchor"
      pd_round_pass 01 "$(git rev-parse HEAD)"
      ;;
  esac
}

pd_remediating_phase() {
  local slug="$1" stage="$2" dir
  dir="$PD_PHASES/$slug/remediation/qa"
  pd_done_flat "$slug"
  pd_md "$PD_PHASES/$slug/$(pd_phase_number "$slug")-VERIFICATION.md" '---' 'result: FAIL' '---' '# Verification' 'Failed.'
  pd_md "$dir/.qa-remediation-stage" "stage=$stage" 'round=01'
}

pd_known_issues_backlog() {
  local head
  head="$(git rev-parse HEAD)"
  mkdir -p "$PD_PHASES/01-unplanned"
  pd_done_flat 02-known-issues
  pd_verified_pass "$PD_PHASES/02-known-issues/02-VERIFICATION.md" 02 "$head"
  pd_known_issues "$PD_PHASES/02-known-issues/known-issues.json" 02 02-01-SUMMARY.md 02-VERIFICATION.md 0 2
}

sc_qa_priority() {
  pd_project
  case "$1" in
    qa_blocks_verification) pd_remediating_phase 01-test plan ;;
    qa_beats_unverified)
      pd_done_flat 01-unverified
      pd_remediating_phase 02-remediating execute
      ;;
    uat_beats_later_qa)
      pd_done_flat 01-uat-issues
      pd_uat "$PD_PHASES/01-uat-issues/01-UAT.md" issues_found major 01
      pd_remediating_phase 02-remediating execute
      ;;
    known_issues_beat_unplanned)
      mkdir -p "$PD_PHASES/01-unplanned"
      pd_remediating_phase 02-remediating execute
      pd_known_issues "$PD_PHASES/02-remediating/known-issues.json" 02 02-01-SUMMARY.md 02-VERIFICATION.md 0 2
      ;;
    qa_beats_mid_execution)
      pd_plan 01-executing 1
      pd_remediating_phase 02-remediating execute
      ;;
    verify_stage_beats_unfinished)
      mkdir -p "$PD_PHASES/01-unplanned"
      pd_remediating_phase 02-remediating verify
      ;;
    backlog) pd_known_issues_backlog ;;
    backlog_probe_fails)
      pd_known_issues_backlog
      pd_shim ki-probe track-known-issues.sh 'case "${1:-}" in
  status) exit 23 ;;
  *) exec "'"$SCRIPTS_DIR"'/track-known-issues.sh" "$@" ;;
esac'
      ;;
    backlog_partial_payload)
      pd_known_issues_backlog
      pd_shim ki-partial track-known-issues.sh 'case "${1:-}" in
  status) printf "known_issues_status=present\n" ;;
  *) exec "'"$SCRIPTS_DIR"'/track-known-issues.sh" "$@" ;;
esac'
      ;;
    all_done_known_issues_failed)
      pd_done_flat 01-test
      pd_verified_pass "$PD_PHASES/01-test/01-VERIFICATION.md" 01 "$(git rev-parse HEAD)"
      pd_known_issues "$PD_PHASES/01-test/known-issues.json" 01 01-01-SUMMARY.md 01-VERIFICATION.md 0 2
      ;;
  esac
}

sc_golden() {
  bash "$PD_FIXTURE_BUILDER" "$1"
}

@test "QA status classifies verification artifacts and remediation stage files" {
  pd_table <<'CASES'
missing-artifact-is-pending#sc_qa missing_artifact#qa_status=pending~qa_reason=missing_verification_artifact
pass-result#sc_qa pass#qa_status=passed~qa_reason=none
legacy-status-pass#sc_qa legacy_pass#qa_status=passed~qa_reason=none
result-field-overrides-legacy-status#sc_qa result_overrides_legacy#qa_status=failed~qa_reason=none
blank-result-does-not-fall-back#sc_qa blank_result#qa_status=pending~qa_reason=verification_result_missing
unrecognized-result-explained#sc_qa unrecognized_result#qa_status=pending~qa_reason=verification_result_unrecognized
pass-with-unresolved-known-issues#sc_qa pass_with_known_issues#qa_status=failed
fail-does-not-restore-missing-registry#sc_qa fail_with_preexisting_table#qa_status=failed~-.lbwc-planning/phases/01-test/known-issues.json
brownfield-plain-verification#sc_qa brownfield_plain#qa_status=passed
latest-wave-verification-wins#sc_qa latest_wave#qa_status=passed
fail-result#sc_qa fail#qa_status=failed
partial-result#sc_qa partial#qa_status=failed~qa_reason=none
legacy-status-partial#sc_qa legacy_partial#qa_status=failed~qa_reason=none
gate-rerun-for-structured-pass#sc_qa structured_gate_fail#qa_status=pending~qa_reason=qa_gate_rerun_required
leading-blank-summary-still-complete#sc_qa leading_blank_summary#qa_status=pending~qa_reason=qa_gate_rerun_required
execute-stage-remediating#sc_qa_stage execute#qa_status=remediating~qa_round=01
plan-stage-remediating#sc_qa_stage plan#qa_status=remediating
verify-stage-remediating#sc_qa_stage verify#qa_status=remediating
corrupt-stage-not-active#sc_qa_stage corrupt_stage#qa_status=pending~!next_phase_state=needs_qa_remediation
done-stage-round-fail#sc_qa_stage done_round_fails#qa_status=failed
done-stage-round-verification-missing#sc_qa_stage done_round_missing#qa_status=pending
done-stage-missing-round-fails-closed#sc_qa_stage done_round_missing_phase_pass#qa_status=pending
done-stage-corrupt-round-degrades#sc_qa_stage done_corrupt_round#phase_detect_complete=true
CASES
}

@test "QA status goes pending when product code changed after verification" {
  pd_table <<'CASES'
verified-commit-mismatch#sc_qa_git stale_commit#qa_status=pending~qa_reason=verified_at_commit_mismatch
brownfield-pass-after-later-commit#sc_qa_git brownfield_after_commit#qa_status=pending~qa_reason=product_changed_after_verification
uncommitted-product-change#sc_qa_git uncommitted_change#qa_status=pending~qa_reason=working_tree_changed
unrelated-dirt-ignored#sc_qa_git unrelated_dirt#qa_status=passed~qa_reason=none
brownfield-remediated-after-later-commit#sc_qa_git remediated_after_commit#qa_status=pending~qa_reason=product_changed_after_verification
CASES
}

@test "QA status resolves finished remediation rounds from the round verification" {
  pd_table <<'CASES'
first-round-pass-is-remediated#sc_qa_round remediated#qa_status=remediated
second-round-pass-is-remediated#sc_qa_round second_round#qa_status=remediated
unresolved-known-issues-keep-failed#sc_qa_round known_issues_keep_failed#qa_status=failed
cleared-round-ignores-stale-phase-issues#sc_qa_round resume_with_stale_phase_issues#-.lbwc-planning/phases/01-test/known-issues.json~!next_phase_state=needs_qa_remediation
CASES
}

@test "QA attention and remediation outrank other unfinished work in phase order" {
  pd_table <<'CASES'
qa-remediation-blocks-verification#sc_qa_priority qa_blocks_verification#next_phase_state=needs_qa_remediation
later-qa-beats-unverified#sc_qa_priority qa_beats_unverified#next_phase_state=needs_qa_remediation~next_phase=02~next_phase_slug=02-remediating~qa_status=remediating
earlier-uat-beats-later-qa#sc_qa_priority uat_beats_later_qa#next_phase_state=needs_uat_remediation~next_phase=01
known-issues-qa-beats-unplanned#sc_qa_priority known_issues_beat_unplanned#next_phase_state=needs_qa_remediation~next_phase=02
later-qa-beats-mid-execution#sc_qa_priority qa_beats_mid_execution#next_phase_state=needs_qa_remediation~next_phase=02
verify-stage-beats-unfinished#sc_qa_priority verify_stage_beats_unfinished#next_phase=02~next_phase_state=needs_qa_remediation~first_qa_attention_phase=02~first_qa_attention_slug=02-remediating~qa_attention_status=verify
backlog-attention-while-unfinished#sc_qa_priority backlog#next_phase=01~next_phase_state=needs_plan_and_execute~first_qa_attention_phase=02~first_qa_attention_slug=02-known-issues~qa_attention_status=failed
backlog-attention-when-status-probe-fails#sc_qa_priority backlog_probe_fails#next_phase=01~next_phase_state=needs_plan_and_execute~first_qa_attention_phase=02~first_qa_attention_slug=02-known-issues~qa_attention_status=failed~+.lbwc-planning/phases/02-known-issues/known-issues.json
backlog-attention-with-partial-status-payload#sc_qa_priority backlog_partial_payload#next_phase=01~next_phase_state=needs_plan_and_execute~first_qa_attention_phase=02~first_qa_attention_slug=02-known-issues~qa_attention_status=failed~+.lbwc-planning/phases/02-known-issues/known-issues.json
all-done-routes-to-qa-when-known-issues-failed#sc_qa_priority all_done_known_issues_failed#next_phase=01~next_phase_slug=01-test~next_phase_state=needs_qa_remediation~first_qa_attention_phase=01~qa_attention_status=failed~qa_status=failed
CASES
}

@test "golden fixtures for remediated and masked QA states route to the right phase state" {
  pd_table <<'CASES'
terminal-partial-summary-satisfied-by-current-round-pass#sc_golden phase-05-remediated#^next_phase_state=all_done~^next_phase_summaries=0
terminal-failed-summary-not-masked-by-pass#sc_golden failed-summary-passing-remediation#^next_phase_state=needs_execute~!next_phase_state=all_done
earlier-round-pass-does-not-mask-later-fail#sc_golden stale-pass-later-fail#^next_phase_state=needs_execute~!next_phase_state=all_done
CASES
}
