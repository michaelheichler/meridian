#!/usr/bin/env bats

load gate_case_helper
load rejection_case_helper

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/qa-result-gate.sh"

setup() {
  TEST_DIR="$(mktemp -d)"
  TEST_DIR="$(cd "$TEST_DIR" && pwd -P)"
  PHASE_DIR="$TEST_DIR/.lbwc-planning/phases/01-test-phase"
  mkdir -p "$PHASE_DIR" "$TEST_DIR/.lbwc-planning"
  printf '{}\n' > "$TEST_DIR/.lbwc-planning/config.json"
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
