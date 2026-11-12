#!/usr/bin/env bats

load test_helper
load gate_case_helper
load rejection_case_helper

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/qa-result-gate.sh"

setup() {
  TEST_DIR="$(mktemp -d)"
  TEST_DIR="$(cd "$TEST_DIR" && pwd -P)"
  PHASE_DIR="$TEST_DIR/.meridian/phases/01-test-phase"
  mkdir -p "$PHASE_DIR" "$TEST_DIR/.meridian"
  printf '{}\n' > "$TEST_DIR/.meridian/config.json"
}

teardown() {
  rm -rf "$TEST_DIR" 2>/dev/null || true
}

create_verif() {
  local writer="${1:-write-verification.sh}"
  local result="${2:-PASS}"
  local body="${3:-}"
  {
    echo "---"
    echo "phase: 01"
    echo "tier: full"
    echo "result: $result"
    echo "passed: 10"
    echo "failed: 0"
    echo "total: 10"
    echo "date: 2026-03-27"
    if [ "$writer" != "OMIT" ]; then
      echo "writer: $writer"
    fi
    echo "---"
    echo ""
    if [ -n "$body" ]; then
      printf '%s\n' "$body"
    fi
  } > "$PHASE_DIR/01-VERIFICATION.md"
}

new_phase() {
  rm -rf "$PHASE_DIR"
  mkdir -p "$PHASE_DIR"
}

tree_digest() {
  (cd "$TEST_DIR" && find . -type f -exec cksum {} + | sort)
}

gate_row() {
  local label="$1" routing="$2" fragment before
  shift 2
  before=$(tree_digest)
  run bash "$SCRIPT" ${GATE_PHASE_ARG-$PHASE_DIR} ${GATE_NAME_ARG:-}
  expect_case "$label" 0 "qa_gate_routing=$routing"
  for fragment in "$@"; do
    expect_fragment "$label" "$fragment"
  done
  expect_digest "$label" "$before" "$(tree_digest)"
}

accept_uat_deviation() {
  local registry="$PHASE_DIR/remediation/uat/accepted-deviations.json" signature
  signature=$(bash "$REPO_ROOT/scripts/track-uat-deviations.sh" signature "$1" "$2" "$3")
  mkdir -p "$(dirname "$registry")"
  [ -f "$registry" ] || printf '{"accepted":[]}\n' > "$registry"
  jq --arg signature "$signature" '.accepted += [{signature: $signature}]' "$registry" > "$registry.next"
  mv "$registry.next" "$registry"
}

write_qa_round_plan() {
  printf -- '---\nround: 01\n%s\n---\n' "$1" > "$PHASE_DIR/remediation/qa/round-01/R01-PLAN.md"
}

create_qa_remediation_fixture() {
  local round_dir="$PHASE_DIR/remediation/qa/round-01"
  mkdir -p "$round_dir"
  create_verif "write-verification.sh" "FAIL" "| ID | Status |
|----|--------|
| F1 | FAIL |"
  : > "$PHASE_DIR/01-01-PLAN.md"
  printf 'stage=verify\nround=01\nsource_verification_path=%s/01-VERIFICATION.md\n' "$PHASE_DIR" \
    > "$PHASE_DIR/remediation/qa/.qa-remediation-stage"
  write_qa_round_plan "$1"
  printf -- '---\nstatus: complete\n---\n\n## Deviations\n\n- Changed approach\n' > "$round_dir/R01-SUMMARY.md"
  printf -- '---\nresult: PASS\nwriter: write-verification.sh\n---\n' > "$round_dir/R01-VERIFICATION.md"
}

@test "qa-result-gate exits 0 without touching the tree and routes trusted passes to UAT, failures to remediation, and untrusted or incomplete evidence to a QA rerun" {
  reset_case_failures

  new_phase
  create_verif "write-verification.sh" "PASS" "## Must-Have Checks
| Check | Status |
|-------|--------|
| Feature works | PASS |"
  gate_row pass-clean PROCEED_TO_UAT qa_gate_writer=write-verification.sh qa_gate_result=PASS qa_gate_fail_count=0

  new_phase
  cat > "$PHASE_DIR/01-VERIFICATION.md" <<'VERIF'
---
phase: 01
status: PASS
writer: write-verification.sh
---
## Must-Have Checks
| Check | Status |
|-------|--------|
| Feature works | PASS |
VERIF
  gate_row legacy-status-pass PROCEED_TO_UAT qa_gate_result=PASS

  new_phase
  create_verif "write-verification.sh" "pass"
  gate_row lowercase-result-normalized PROCEED_TO_UAT qa_gate_result=PASS

  new_phase
  create_verif "write-verification.sh" "PASS"
  mv "$PHASE_DIR/01-VERIFICATION.md" "$PHASE_DIR/CUSTOM-VERIF.md"
  GATE_NAME_ARG="CUSTOM-VERIF.md" gate_row custom-verif-name PROCEED_TO_UAT

  new_phase
  create_verif "write-verification.sh" "PaRtIaL"
  gate_row mixed-case-partial REMEDIATION_REQUIRED qa_gate_result=PARTIAL

  new_phase
  cat > "$PHASE_DIR/01-VERIFICATION.md" <<'VERIF'
---
phase: 01
result: FAIL
status: PASS
writer: write-verification.sh
---
## Must-Have Checks
| Check | Status |
|-------|--------|
| Feature failed | FAIL |
VERIF
  gate_row result-overrides-legacy-status REMEDIATION_REQUIRED qa_gate_result=FAIL

  new_phase
  create_verif "write-verification.sh" "PASS" "## Must-Have Checks
| Check | Status |
|-------|--------|
| Feature works | PASS |
| Edge case | FAIL |"
  gate_row pass-with-fail-rows REMEDIATION_REQUIRED qa_gate_fail_count=1

  new_phase
  create_verif "write-verification.sh" "PARTIAL"
  gate_row partial-result REMEDIATION_REQUIRED qa_gate_result=PARTIAL

  new_phase
  create_verif "write-verification.sh" "FAIL"
  gate_row fail-result REMEDIATION_REQUIRED qa_gate_result=FAIL

  new_phase
  create_qa_remediation_fixture 'fail_classifications: [{id: F1, type: bogus}]'
  printf -- '---\nresult: FAIL\nwriter: write-verification.sh\n---\n| ID | Status |\n|----|--------|\n| F1 | FAIL |\n' \
    > "$PHASE_DIR/remediation/qa/round-01/R01-VERIFICATION.md"
  gate_row failing-round-with-invalid-classification REMEDIATION_REQUIRED qa_gate_result=FAIL qa_gate_classifications_invalid=true

  new_phase
  local round_dir="$PHASE_DIR/remediation/uat/round-01"
  mkdir -p "$round_dir"
  printf 'stage=verify\nround=01\nlayout=round-dir\n' > "$PHASE_DIR/remediation/uat/.uat-remediation-stage"
  cat > "$round_dir/R01-VERIFICATION.md" <<'VERIF'
---
phase: 01
result: PASS
writer: write-verification.sh
---
VERIF
  gate_row uat-round-without-source-verification REMEDIATION_REQUIRED \
    "qa_gate_scope=uat round=01" qa_gate_result=PASS qa_gate_source_verification_missing=true

  new_phase
  cat > "$PHASE_DIR/01-VERIFICATION.md" <<'VERIF'
---
phase: 01
result:
status: PASS
writer: write-verification.sh
---
VERIF
  gate_row blank-result-ignores-legacy-status QA_RERUN_REQUIRED qa_gate_result=missing

  new_phase
  create_verif "write-verification.sh" "PASS"
  cat > "$PHASE_DIR/01-01-SUMMARY.md" <<'SUMMARY'
---
plan: 01-01
deviations: ["Changed API contract", 'Moved tests to existing file']
---

## Summary
Work completed.
SUMMARY
  gate_row flow-style-deviations QA_RERUN_REQUIRED qa_gate_deviation_count=2 qa_gate_deviation_override=true

  new_phase
  create_verif "write-verification.sh" "PASS"
  printf -- '---\nstatus: complete\ndeviations: ["Changed API contract", "Kept the old cache"]\n---\n' > "$PHASE_DIR/01-01-SUMMARY.md"
  accept_uat_deviation 01-01 01-01-SUMMARY.md "Changed API contract"
  gate_row accepted-uat-deviation-not-counted QA_RERUN_REQUIRED qa_gate_deviation_count=1 qa_gate_deviation_override=true
  accept_uat_deviation 01-01 01-01-SUMMARY.md "Kept the old cache"
  gate_row all-deviations-accepted PROCEED_TO_UAT qa_gate_deviation_count=0

  new_phase
  create_verif "manual-write" "PASS"
  gate_row wrong-writer QA_RERUN_REQUIRED qa_gate_writer=manual-write

  new_phase
  create_verif "OMIT" "PASS"
  gate_row missing-writer QA_RERUN_REQUIRED qa_gate_writer=missing

  new_phase
  gate_row missing-verification QA_RERUN_REQUIRED qa_gate_result=missing

  new_phase
  create_verif "write-verification.sh" "UNKNOWN_VALUE"
  gate_row unknown-result QA_RERUN_REQUIRED

  GATE_PHASE_ARG="" gate_row missing-phase-dir-argument QA_RERUN_REQUIRED

  new_phase
  create_verif "write-verification.sh" "PASS"
  printf 'Plan stub\n' > "$PHASE_DIR/01-01-PLAN.md"
  printf 'Plan stub\n' > "$PHASE_DIR/01-02-PLAN.md"
  gate_row unmet-plan-coverage QA_RERUN_REQUIRED qa_gate_plan_count=2 qa_gate_plans_verified_count=0

  assert_no_case_failures
}

check_flow_invalid_terminates() {
  local label="$1"
  create_qa_remediation_fixture 'fail_classifications: [{id: F1, type: bogus}]'
  run timeout 10 bash "$SCRIPT" "$PHASE_DIR"
  expect_case "$label" 0 "qa_gate_classifications_invalid=true"
  expect_fragment "$label" "qa_gate_routing=REMEDIATION_REQUIRED"
  [[ "$output" != *"PROCEED_TO_UAT"* ]] || record_case_failure "$label" "output still proceeds to UAT output=$output"
}

check_flow_block_parity() {
  local label="$1" flow_plan="$2" block_plan="$3" flow_output
  create_qa_remediation_fixture "$flow_plan"
  run timeout 10 bash "$SCRIPT" "$PHASE_DIR"
  flow_output="$output"
  write_qa_round_plan "$block_plan"
  run timeout 10 bash "$SCRIPT" "$PHASE_DIR"
  expect_case "$label" 0
  [ "$output" = "$flow_output" ] \
    || record_case_failure "$label" "flow output differs from block output flow=$flow_output block=$output"
}

@test "qa-result-gate terminates on a flow-style invalid classification with a deviation and gives flow-style and block-style fail_classifications identical output" {
  reset_case_failures

  check_flow_invalid_terminates flow-invalid-with-deviation-terminates
  new_phase
  check_flow_block_parity invalid-type 'fail_classifications: [{id: F1, type: bogus}]' \
    $'fail_classifications:\n  - id: F1\n    type: bogus'
  new_phase
  check_flow_block_parity valid-type 'fail_classifications: [{id: F1, type: code-fix}]' \
    $'fail_classifications:\n  - id: F1\n    type: code-fix'

  assert_no_case_failures
}

qa_round_world() {
  local plan_fields="$1" summary_fields="$2" failed_ids="${3:-}" registry="${4:-}"
  local round_dir="$PHASE_DIR/remediation/qa/round-01" result=PASS failed_id
  new_phase
  mkdir -p "$round_dir"
  printf -- '---\nphase: 01\nresult: FAIL\nwriter: write-verification.sh\n---\n| ID | Status |\n|----|--------|\n| F1 | FAIL |\n' \
    > "$PHASE_DIR/01-VERIFICATION.md"
  printf -- '---\nplan: 01-01\n---\nOriginal plan\n' > "$PHASE_DIR/01-01-PLAN.md"
  printf 'stage=verify\nround=01\nsource_verification_path=%s/01-VERIFICATION.md\nsource_fail_count=1\n' "$PHASE_DIR" \
    > "$PHASE_DIR/remediation/qa/.qa-remediation-stage"
  printf -- '---\nround: 01\n%s\n---\n' "$plan_fields" > "$round_dir/R01-PLAN.md"
  printf -- '---\nstatus: complete\n%s\n---\n' "$summary_fields" > "$round_dir/R01-SUMMARY.md"
  [ -z "$failed_ids" ] || result=FAIL
  {
    printf -- '---\nresult: %s\nwriter: write-verification.sh\nplans_verified:\n  - R01\n---\n' "$result"
    [ -z "$failed_ids" ] || printf '| ID | Status |\n|----|--------|\n'
    for failed_id in $failed_ids; do
      printf '| %s | FAIL |\n' "$failed_id"
    done
  } > "$round_dir/R01-VERIFICATION.md"
  [ -z "$registry" ] || printf '%s\n' "$registry" > "$PHASE_DIR/known-issues.json"
}

@test "a QA remediation round passes only when its classifications, plan amendments and known-issue outcomes account for every original failure" {
  local exception='fail_classifications: [{id: F1, type: process-exception, rationale: cannot rewrite history}]'
  local round_plan_recorded='files_modified: [remediation/qa/round-01/R01-PLAN.md]'
  local issue='{"test":"t1","file":"f1.sh","error":"boom"}'
  local resolved='{"test":"t1","file":"f1.sh","error":"boom","disposition":"resolved","rationale":"fixed"}'
  local unresolved='{"test":"t1","file":"f1.sh","error":"boom","disposition":"unresolved","rationale":"open"}'
  local registry='{"schema_version":1,"phase":"01","issues":[{"signature":"abcdef123456","test":"t1","file":"f1.sh","error":"boom"}]}'
  local inputs_resolved inputs_unresolved
  inputs_resolved=$(printf "%s\nknown_issues_input:\n  - '%s'\nknown_issue_resolutions:\n  - '%s'" "$exception" "$issue" "$resolved")
  inputs_unresolved=$(printf "%s\nknown_issues_input:\n  - '%s'\nknown_issue_resolutions:\n  - '%s'" "$exception" "$issue" "$unresolved")
  reset_case_failures

  qa_round_world "$exception" "$round_plan_recorded" F1
  gate_row process-exception-exempts-failure PROCEED_TO_UAT \
    qa_gate_classified_fail_exemption=true qa_gate_exempt_fail_count=1
  qa_round_world "$exception" "$round_plan_recorded" "F1 F2"
  gate_row unclassified-round-failure-stays-open REMEDIATION_REQUIRED qa_gate_fail_count=2
  qa_round_world 'fail_classifications: [{id: F1, type: code-fix, rationale: patch it}]' 'files_modified: [src/fix.sh]' F1
  gate_row code-fix-failure-stays-open REMEDIATION_REQUIRED qa_gate_fail_count=1
  qa_round_world 'fail_classifications: [{id: F9, type: process-exception, rationale: wrong failure}]' "$round_plan_recorded"
  gate_row classification-names-another-failure REMEDIATION_REQUIRED qa_gate_classifications_invalid=true
  qa_round_world "$exception" "$round_plan_recorded
deviations: [\"F1 stays a process exception\", \"Unrelated drift\"]"
  gate_row only-unclassified-deviation-counts QA_RERUN_REQUIRED qa_gate_deviation_count=1 qa_gate_deviation_override=true

  qa_round_world 'fail_classifications: [{id: F1, type: plan-amendment, rationale: better approach}]' "$round_plan_recorded"
  gate_row amendment-without-source-plan REMEDIATION_REQUIRED qa_gate_plan_amendment_evidence_missing=true
  qa_round_world 'fail_classifications: [{id: F1, type: plan-amendment, rationale: better approach, source_plan: ../02-other/02-01-PLAN.md}]' "$round_plan_recorded"
  gate_row amendment-of-foreign-plan REMEDIATION_REQUIRED qa_gate_plan_amendment_evidence_missing=true
  qa_round_world 'fail_classifications: [{id: F1, type: plan-amendment, rationale: better approach, source_plan: 01-01-PLAN.md}]' "$round_plan_recorded"
  gate_row amended-plan-not-recorded REMEDIATION_REQUIRED qa_gate_plan_amendment_evidence_missing=true
  qa_round_world 'fail_classifications: [{id: F1, type: plan-amendment, rationale: better approach, source_plan: 01-01-PLAN.md}]' 'files_modified: [01-01-PLAN.md]'
  gate_row amended-plan-recorded PROCEED_TO_UAT qa_gate_plan_count=1 qa_gate_plans_verified_count=1

  qa_round_world "$inputs_resolved" "$(printf "%s\nknown_issue_outcomes:\n  - '%s'" "$round_plan_recorded" "$resolved")" "" "$registry"
  gate_row known-issue-resolved PROCEED_TO_UAT qa_gate_known_issue_count=1 qa_gate_known_issues_all_addressed=true
  qa_round_world "$exception" "$round_plan_recorded" "" "$registry"
  gate_row known-issue-not-carried REMEDIATION_REQUIRED qa_gate_known_issue_contract_invalid=true
  qa_round_world "$inputs_resolved" "$(printf "%s\nknown_issue_outcomes:\n  - '%s'" "$round_plan_recorded" "$unresolved")" "" "$registry"
  gate_row known-issue-outcome-disagrees REMEDIATION_REQUIRED qa_gate_known_issue_contract_invalid=true
  qa_round_world "$inputs_unresolved" "$(printf "%s\nknown_issue_outcomes:\n  - '%s'" "$round_plan_recorded" "$unresolved")"
  gate_row unresolved-outcome-without-registry REMEDIATION_REQUIRED qa_gate_known_issue_contract_invalid=true

  assert_no_case_failures
}

@test "without summary-utils the gate still counts YAML deviations first and falls back to the Deviations section, skipping none markers and comments" {
  copy_script_with_libs "$REPO_ROOT/scripts/qa-result-gate.sh" "$TEST_DIR/bare-gate/qa-result-gate.sh"
  cp "$REPO_ROOT/scripts/extract-frontmatter-array-items.awk" "$TEST_DIR/bare-gate/"
  SCRIPT="$TEST_DIR/bare-gate/qa-result-gate.sh"
  reset_case_failures

  new_phase
  create_verif "write-verification.sh" "PASS"
  printf -- '---\nstatus: complete\ndeviations: ["Changed API contract", "none", "N/A."]\n---\n\n## Deviations\n\n- Body item ignored\n' \
    > "$PHASE_DIR/01-01-SUMMARY.md"
  gate_row yaml-deviations-win QA_RERUN_REQUIRED qa_gate_deviation_count=1 qa_gate_deviation_override=true

  new_phase
  create_verif "write-verification.sh" "PASS"
  printf -- '---\nstatus: complete\ndeviations: []\n---\n\n## Deviations\n\n<!-- list each\ndeviation here -->\n- **Scope:** moved tests\n- N/A\n- **None**\n\n## Next Steps\n\n- Not a deviation\n' \
    > "$PHASE_DIR/01-01-SUMMARY.md"
  gate_row body-deviations-counted QA_RERUN_REQUIRED qa_gate_deviation_count=1

  new_phase
  create_verif "write-verification.sh" "PASS"
  printf -- '---\nstatus: complete\n---\n\n### Deviations\n\n- None. Plan followed.\n<!-- one-line note -->\n' > "$PHASE_DIR/01-01-SUMMARY.md"
  gate_row none-body-deviation PROCEED_TO_UAT qa_gate_deviation_count=0

  assert_no_case_failures
}
