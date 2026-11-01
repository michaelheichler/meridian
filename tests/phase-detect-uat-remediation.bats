#!/usr/bin/env bats

load phase-detect-helpers

setup() { pd_setup; }
teardown() { pd_teardown; }

PD_FEATURE="$PD_PHASES/01-feature"
PD_UAT_STAGE="$PD_FEATURE/remediation/uat/.uat-remediation-stage"

pd_round_one_uat_issue() {
  pd_done 01-feature
  pd_md "$PD_UAT_STAGE" 'stage=done' 'round=01' 'layout=round-dir'
  pd_uat "$PD_FEATURE/remediation/uat/round-01/R01-UAT.md" issues_found major 01
}

pd_cap_shim() {
  case "$1" in
    nonzero) pd_shim cap-helper-fail resolve-uat-remediation-round-limit.sh 'exit 23' ;;
    malformed) pd_shim cap-helper-malformed resolve-uat-remediation-round-limit.sh "printf 'current_round=01\nnext_round=02\n'" ;;
  esac
}

sc_cap() {
  case "$1" in
    finite)
      pd_config '.max_uat_remediation_rounds=1'
      pd_round_one_uat_issue
      ;;
    unlimited)
      pd_config '.max_uat_remediation_rounds=false'
      pd_round_one_uat_issue
      ;;
    zero)
      pd_config '.max_uat_remediation_rounds=0'
      pd_round_one_uat_issue
      ;;
    helper_nonzero | helper_malformed)
      pd_round_one_uat_issue
      pd_cap_shim "${1#helper_}"
      ;;
  esac
}

sc_legacy_state() {
  pd_done 01-legacy
  pd_md "$PD_PHASES/01-legacy/01-UAT.md" '---' 'phase: 01' 'status: issues_found' '---'
  case "$1" in
    root_done) pd_md "$PD_PHASES/01-legacy/.uat-remediation-stage" 'stage=done' 'round=01' 'layout=legacy' ;;
    stale_execute) pd_md "$PD_PHASES/01-legacy/remediation/.uat-remediation-stage" 'stage=execute' 'round=01' 'layout=legacy' ;;
  esac
}

pd_capped_uat_with_unrelated_qa() {
  pd_config '.max_uat_remediation_rounds=1'
  pd_project
  pd_done 01-uat
  pd_md "$PD_PHASES/01-uat/remediation/uat/.uat-remediation-stage" 'stage=verify' 'round=01' 'layout=round-dir'
  pd_uat_issue "$PD_PHASES/01-uat/remediation/uat/round-01/R01-UAT.md" 01 issues_found "Still failing at the cap" major 01
  pd_done 02-qa
  pd_md "$PD_PHASES/02-qa/02-VERIFICATION.md" '---' 'result: FAIL' '---' '# Verification' 'Unrelated pre-UAT QA failure.'
  pd_md "$PD_PHASES/02-qa/remediation/qa/.qa-remediation-stage" 'stage=execute' 'round=01'
}

sc_cap_blocks_qa() {
  pd_capped_uat_with_unrelated_qa
  case "$1" in
    helper_nonzero) pd_cap_shim nonzero ;;
    helper_malformed) pd_cap_shim malformed ;;
  esac
}

sc_stage_round() {
  case "$1" in
    verify_issues_next_round)
      pd_project
      pd_done 03-order-backed-sync-integration
      pd_md "$PD_PHASES/03-order-backed-sync-integration/remediation/uat/.uat-remediation-stage" 'stage=verify' 'round=05' 'layout=round-dir'
      pd_uat_issue "$PD_PHASES/03-order-backed-sync-integration/remediation/uat/round-05/R05-UAT.md" 03 issues_found "UAT still found a problem" major 05
      pd_md "$PD_PHASES/03-order-backed-sync-integration/remediation/qa/.qa-remediation-stage" 'stage=execute' 'round=01'
      pd_md "$PD_PHASES/03-order-backed-sync-integration/03-VERIFICATION.md" '---' 'result: FAIL' '---' '# Verification' 'Stale QA metadata.'
      ;;
    current_round_not_summarised)
      pd_done 01-feature
      pd_md "$PD_UAT_STAGE" 'stage=execute' 'round=02' 'layout=round-dir'
      pd_md "$PD_FEATURE/remediation/uat/round-01/R01-PLAN.md" '# Plan'
      pd_summary "$PD_FEATURE/remediation/uat/round-01/R01-SUMMARY.md"
      pd_md "$PD_FEATURE/remediation/uat/round-02/R02-PLAN.md" '# Plan'
      pd_uat "$PD_FEATURE/remediation/uat/round-01/R01-UAT.md" issues_found major 01
      ;;
    done_round_issues)
      pd_done 01-feature
      pd_uat_issue "$PD_FEATURE/01-UAT.md" 01 issues_found "root" major
      pd_uat_issue "$PD_FEATURE/remediation/uat/round-01/R01-UAT.md" 01 issues_found "prior round" major 01
      pd_uat_issue "$PD_FEATURE/remediation/uat/round-02/R02-UAT.md" 01 issues_found "fix did not resolve" major 02
      pd_md "$PD_UAT_STAGE" 'stage=done' 'round=02' 'layout=round-dir'
      ;;
    done_no_round_uat)
      pd_done 01-feature
      pd_uat_issue "$PD_FEATURE/01-UAT.md" 01 issues_found "root" major
      pd_md "$PD_FEATURE/remediation/uat/round-02/R02-PLAN.md" '# Plan'
      pd_summary "$PD_FEATURE/remediation/uat/round-02/R02-SUMMARY.md"
      pd_md "$PD_UAT_STAGE" 'stage=done' 'round=02' 'layout=round-dir'
      ;;
    done_round_complete)
      pd_done 01-feature
      pd_uat_issue "$PD_FEATURE/01-UAT.md" 01 issues_found "root" major
      pd_md "$PD_FEATURE/remediation/uat/round-01/R01-UAT.md" '---' 'phase: 01' 'round: 01' 'status: complete' 'issues: 0' '---' \
        '## Tests' '### P01-T1: sample test' '- **Result:** pass'
      pd_md "$PD_UAT_STAGE" 'stage=done' 'round=01' 'layout=round-dir'
      ;;
    done_legacy_layout)
      pd_done 01-feature
      pd_uat_issue "$PD_FEATURE/01-UAT.md" 01 issues_found "root" major
      pd_uat_issue "$PD_FEATURE/remediation/round-01/R01-UAT.md" 01 issues_found "legacy round" major 01
      pd_md "$PD_FEATURE/.uat-remediation-stage" 'stage=done' 'round=01'
      ;;
  esac
}

pd_qa_failure_with_stage() {
  pd_project
  pd_done_flat 01-test
  pd_md "$PD_PHASES/01-test/01-VERIFICATION.md" '---' 'result: FAIL' '---' '# Verification' 'Stale QA failure.'
  pd_md "$PD_PHASES/01-test/remediation/qa/.qa-remediation-stage" 'stage=execute' 'round=01'
}

sc_cutover_layout() {
  local dir="$PD_PHASES/01-test"
  pd_qa_failure_with_stage
  case "$1" in
    phase_root_uat) pd_uat "$dir/01-UAT.md" complete - 01 ;;
    phase_root_archived_uat) pd_md "$dir/01-UAT-round-01.md" '---' 'phase: 01' 'status: issues_found' '---' ;;
    legacy_round_uat) pd_md "$dir/remediation/round-01/R01-UAT.md" '---' 'phase: 01' 'status: issues_found' '---' ;;
    round_dir_uat) pd_md "$dir/remediation/uat/round-01/R01-UAT.md" '---' 'phase: 01' 'status: issues_found' '---' ;;
    phase_root_state) pd_md "$dir/.uat-remediation-stage" 'stage=verify' 'round=01' 'layout=legacy' ;;
    legacy_state) pd_md "$dir/remediation/.uat-remediation-stage" 'stage=verify' 'round=01' 'layout=legacy' ;;
    round_dir_state) pd_md "$dir/remediation/uat/.uat-remediation-stage" 'stage=verify' 'round=01' 'layout=round-dir' ;;
  esac
}

sc_dormant() {
  local head
  pd_project
  pd_done_flat 01-test
  head="$(git rev-parse HEAD)"
  case "$1" in
    stale_pass)
      pd_commit_file app.py 'print("before")' "before stale qa with uat"
      pd_verified_pass "$PD_PHASES/01-test/01-VERIFICATION.md" 01 "$(git rev-parse HEAD)"
      pd_uat "$PD_PHASES/01-test/01-UAT.md" complete - 01
      pd_commit_file app.py 'print("after")' "after stale qa with uat"
      ;;
    failed_authoritative)
      pd_md "$PD_PHASES/01-test/01-VERIFICATION.md" '---' 'result: FAIL' '---' '# Verification' 'Failed.'
      pd_uat "$PD_PHASES/01-test/01-UAT.md" complete - 01
      ;;
    sort_helper_fails)
      pd_done_flat 02-clean
      pd_md "$PD_PHASES/01-test/01-VERIFICATION.md" '---' 'result: FAIL' '---' '# Verification' 'Failed.'
      pd_verified_pass "$PD_PHASES/02-clean/02-VERIFICATION.md" 02 "$head"
      pd_uat "$PD_PHASES/01-test/01-UAT.md" complete - 01
      pd_uat "$PD_PHASES/02-clean/02-UAT.md" complete - 02
      pd_fake_bin sort 'exit 23'
      ;;
    uat_reread_degraded)
      pd_md "$PD_PHASES/01-test/01-VERIFICATION.md" '---' 'result: FAIL' '---' '# Verification' 'Failed.'
      pd_uat "$PD_PHASES/01-test/01-UAT.md" complete - 01
      export PD_SCRIPTS_DIR="$TEST_TEMP_DIR/scripts-uat-reread-degraded"
      cp -R "$SCRIPTS_DIR" "$PD_SCRIPTS_DIR"
      printf '%s\n' '' 'extract_status_value() {' '  case "${1:-}" in' "    *-UAT.md) printf '%s\n' in_progress ;;" \
        "    *) printf '%s\n' '' ;;" '  esac' '}' >> "$PD_SCRIPTS_DIR/uat-utils.sh"
      ;;
    registry_not_rebuilt)
      pd_md "$PD_PHASES/01-test/01-VERIFICATION.md" '---' 'result: PASS' 'writer: write-verification.sh' 'plans_verified:' '  - 01' \
        "verified_at_commit: ${head}" '---' '' '## Pre-existing Issues' '' '| Test | File | Error |' '|------|------|-------|' \
        '| FIGIRegistryServiceTests | Tests/FIGIRegistryServiceTests.swift | compositeFigi missing |'
      pd_uat "$PD_PHASES/01-test/01-UAT.md" complete - 01
      ;;
    round_scoped_gate_failure)
      pd_md "$PD_PHASES/01-test/01-VERIFICATION.md" '---' 'result: FAIL' 'writer: write-verification.sh' '---' '## Must-Have Checks' \
        '| FAIL-01 | must_have | Original failure still needs remediation | FAIL | Missing |'
      pd_md "$PD_PHASES/01-test/remediation/qa/round-01/R01-PLAN.md" '---' 'round: 01' 'fail_classifications:' \
        '  - {id: "FAIL-01", type: "code-fix", rationale: "Code still needs to change"}' '---'
      pd_md "$PD_PHASES/01-test/remediation/qa/round-01/R01-SUMMARY.md" '---' 'plan: R01' 'status: complete' 'files_modified:' \
        '  - README.md' 'deviations: []' '---'
      pd_md "$PD_PHASES/01-test/remediation/qa/round-01/R01-VERIFICATION.md" '---' 'result: PASS' 'writer: write-verification.sh' \
        'plans_verified:' '  - R01' '---' '## Summary' 'Result: PASS'
      pd_md "$PD_PHASES/01-test/remediation/qa/.qa-remediation-stage" 'stage=done' 'round=01'
      pd_uat "$PD_PHASES/01-test/01-UAT.md" complete - 01
      ;;
    git_probe_fails)
      pd_verified_pass "$PD_PHASES/01-test/01-VERIFICATION.md" 01 "$head"
      pd_uat "$PD_PHASES/01-test/01-UAT.md" complete - 01
      pd_fake_bin git 'case "$1" in
  status | log) exit 77 ;;
esac
exec "'"$(command -v git)"'" "$@"'
      ;;
    auto_uat_verification)
      pd_config '. + {effort:"balanced",auto_uat:true,max_uat_remediation_rounds:false}'
      pd_md "$PD_PHASES/01-test/01-VERIFICATION.md" '---' 'result: FAIL' '---' '# Verification' 'This QA failure is pre-UAT metadata.'
      pd_md "$PD_PHASES/01-test/remediation/uat/.uat-remediation-stage" 'stage=verify' 'round=01' 'layout=round-dir'
      ;;
  esac
}

@test "UAT remediation stage state decides routing without rewriting the stage file" {
  local legacy="$PD_PHASES/01-legacy"
  local round_dir="$PD_FEATURE/remediation/uat"
  pd_table <<CASES
legacy-key-value-state-reverifies#sc_legacy_state root_done#next_phase_state=needs_reverification
stale-execute-state-not-rewritten#sc_legacy_state stale_execute#next_phase_state=needs_reverification~@$legacy/remediation/.uat-remediation-stage@stage=execute
finite-cap-stops-auto-advance#sc_cap finite#next_phase_state=needs_reverification~@$PD_UAT_STAGE@stage=done~@$PD_UAT_STAGE@round=01~-$round_dir/round-02
unlimited-cap-routes-next-round#sc_cap unlimited#next_phase_state=needs_uat_remediation~@$PD_UAT_STAGE@stage=done~@$PD_UAT_STAGE@round=01~-$round_dir/round-02
zero-cap-routes-next-round#sc_cap zero#next_phase_state=needs_uat_remediation~@$PD_UAT_STAGE@stage=done~@$PD_UAT_STAGE@round=01~-$round_dir/round-02
cap-helper-exit-stops-auto-advance#sc_cap helper_nonzero#next_phase_state=needs_reverification~@$PD_UAT_STAGE@stage=done~@$PD_UAT_STAGE@round=01~-$round_dir/round-02
cap-helper-malformed-stops-auto-advance#sc_cap helper_malformed#next_phase_state=needs_reverification~@$PD_UAT_STAGE@stage=done~@$PD_UAT_STAGE@round=01~-$round_dir/round-02
verify-stage-issues-route-next-round#sc_stage_round verify_issues_next_round#next_phase=03~next_phase_slug=03-order-backed-sync-integration~next_phase_state=needs_uat_remediation~!next_phase_state=needs_qa_remediation~@$PD_PHASES/03-order-backed-sync-integration/remediation/uat/.uat-remediation-stage@stage=verify~@$PD_PHASES/03-order-backed-sync-integration/remediation/uat/.uat-remediation-stage@round=05~@$PD_PHASES/03-order-backed-sync-integration/remediation/uat/.uat-remediation-stage@layout=round-dir~-$PD_PHASES/03-order-backed-sync-integration/remediation/uat/round-06~@$PD_PHASES/03-order-backed-sync-integration/remediation/qa/.qa-remediation-stage@stage=execute~@$PD_PHASES/03-order-backed-sync-integration/remediation/qa/.qa-remediation-stage@round=01
current-round-without-summary-does-not-advance#sc_stage_round current_round_not_summarised#next_phase_state=needs_uat_remediation~@$PD_UAT_STAGE@stage=execute
done-with-round-issues-routes-remediation#sc_stage_round done_round_issues#next_phase_state=needs_uat_remediation~@$PD_UAT_STAGE@stage=done~@$PD_UAT_STAGE@round=02~-$round_dir/round-03
done-without-round-uat-reverifies#sc_stage_round done_no_round_uat#next_phase_state=needs_reverification~@$PD_UAT_STAGE@stage=done~@$PD_UAT_STAGE@round=02
done-with-passing-round-ends-remediation#sc_stage_round done_round_complete#!next_phase_state=needs_uat_remediation~next_phase_state=all_done~qa_status=none~@$PD_UAT_STAGE@stage=done~@$PD_UAT_STAGE@round=01
done-legacy-layout-keeps-legacy-paths#sc_stage_round done_legacy_layout#next_phase_state=needs_uat_remediation~@$PD_FEATURE/.uat-remediation-stage@stage=done~@$PD_FEATURE/.uat-remediation-stage@round=01~!@$PD_FEATURE/.uat-remediation-stage@layout=~-$PD_FEATURE/remediation/round-02~-$round_dir/round-02
CASES
}

@test "a capped UAT lane blocks unrelated active QA remediation" {
  local uat_stage="$PD_PHASES/01-uat/remediation/uat/.uat-remediation-stage"
  local qa_stage="$PD_PHASES/02-qa/remediation/qa/.qa-remediation-stage"
  local blocked="next_phase=01~next_phase_slug=01-uat~next_phase_state=needs_reverification~uat_issues_phase=01~uat_file=remediation/uat/round-01/R01-UAT.md~!next_phase_state=needs_qa_remediation"
  local untouched="@$uat_stage@stage=verify~@$uat_stage@round=01~@$uat_stage@layout=round-dir~-$PD_PHASES/01-uat/remediation/uat/round-02~@$qa_stage@stage=execute~@$qa_stage@round=01"
  pd_table <<CASES
cap-reached#sc_cap_blocks_qa plain#$blocked~$untouched
cap-helper-failure#sc_cap_blocks_qa helper_nonzero#$blocked~$untouched
cap-helper-malformed#sc_cap_blocks_qa helper_malformed#$blocked~$untouched
CASES
}

@test "terminal or cut-over UAT keeps stale QA remediation dormant" {
  local qa_stage="$PD_PHASES/01-test/remediation/qa/.qa-remediation-stage"
  local dormant="^first_qa_attention_phase=~qa_attention_status=none~next_phase=none~next_phase_slug=none~next_phase_state=all_done"
  local layout_tokens="!next_phase_state=needs_qa_remediation~qa_after_uat_dormant=true~@$qa_stage@stage=execute~@$qa_stage@round=01"
  pd_table <<CASES
stale-pass-after-later-commit#sc_dormant stale_pass#$dormant~qa_attention_reason=none~qa_reason=none
failed-authoritative-qa#sc_dormant failed_authoritative#$dormant~qa_status=none
phase-sorting-helper-fails#sc_dormant sort_helper_fails#$dormant~phase_detect_complete=true~phase_count=2
uat-reread-degraded#sc_dormant uat_reread_degraded#$dormant
registry-not-rebuilt-after-cutover#sc_dormant registry_not_rebuilt#$dormant~qa_status=none~-.lbwc-planning/phases/01-test/known-issues.json
round-scoped-gate-failure#sc_dormant round_scoped_gate_failure#$dormant~qa_status=none
git-freshness-probe-fails#sc_dormant git_probe_fails#$dormant~phase_detect_complete=true~qa_status=none
auto-uat-verification-suppresses-qa-gate#sc_dormant auto_uat_verification#next_phase=01~next_phase_state=needs_verification~qa_status=none~qa_reason=uat_cutover~qa_after_uat_dormant=true~!next_phase_state=needs_qa_remediation
phase-root-uat#sc_cutover_layout phase_root_uat#$layout_tokens
phase-root-archived-uat#sc_cutover_layout phase_root_archived_uat#$layout_tokens
legacy-round-uat#sc_cutover_layout legacy_round_uat#$layout_tokens
round-dir-uat#sc_cutover_layout round_dir_uat#$layout_tokens
phase-root-state#sc_cutover_layout phase_root_state#$layout_tokens
legacy-state#sc_cutover_layout legacy_state#$layout_tokens
round-dir-state#sc_cutover_layout round_dir_state#$layout_tokens
CASES
}
