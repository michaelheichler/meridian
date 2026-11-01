#!/usr/bin/env bats

load script_contract_helper

setup() {
  setup_script_contract_workspace 08-checkout
}

artifact_rows() {
  local label artifact_type plan_number expected
  while IFS='|' read -r label artifact_type plan_number expected; do
    run bash "$SCRIPTS_DIR/resolve-artifact-path.sh" "$artifact_type" "$PHASE/" --plan-number="$plan_number"
    expect_case "$label" 0
    [ "$output" = "$expected" ] || record_case_failure "$label" "got=$output want=$expected"
  done
  assert_no_case_failures
}

@test "artifact paths keep phase and plan identities distinct across artifact types" {
  artifact_rows <<'CASES'
plan|plan|009|08-09-PLAN.md
summary|summary|009|08-09-SUMMARY.md
research|research|009|08-09-RESEARCH.md
phase-research|phase-research||08-RESEARCH.md
context|context||08-CONTEXT.md
uat|uat||08-UAT.md
verification|verification||08-VERIFICATION.md
CASES
}

@test "automatic plan numbering advances past canonical and legacy plans without counting unrelated markdown" {
  touch "$PHASE/08-03-PLAN.md" "$PHASE/09-PLAN.md" "$PHASE/notes-PLAN.md" "$PHASE/08-99-SUMMARY.md"
  mkdir "$PHASE/08-98-PLAN.md"
  run bash "$SCRIPTS_DIR/resolve-artifact-path.sh" plan "$PHASE"
  [ "$status" -eq 0 ]
  [ "$output" = 08-10-PLAN.md ]
}

artifact_rejections() {
  local label expected_status
  while IFS='|' read -r label expected_status; do
    case "$label" in
      missing-type) run bash "$SCRIPTS_DIR/resolve-artifact-path.sh" ;;
      unknown-type) run bash "$SCRIPTS_DIR/resolve-artifact-path.sh" invented "$PHASE" ;;
      missing-phase) run bash "$SCRIPTS_DIR/resolve-artifact-path.sh" plan ;;
      absent-phase) run bash "$SCRIPTS_DIR/resolve-artifact-path.sh" plan "$PHASE/absent" ;;
      unnamed-phase) run bash "$SCRIPTS_DIR/resolve-artifact-path.sh" plan "$TEST_TEMP_DIR" ;;
      unknown-option) run bash "$SCRIPTS_DIR/resolve-artifact-path.sh" plan "$PHASE" --invented ;;
      missing-option-value) run bash "$SCRIPTS_DIR/resolve-artifact-path.sh" plan "$PHASE" --plan-number ;;
      nonnumeric-plan) run bash "$SCRIPTS_DIR/resolve-artifact-path.sh" plan "$PHASE" --plan-number two ;;
      zero-plan) run bash "$SCRIPTS_DIR/resolve-artifact-path.sh" plan "$PHASE" --plan-number 00 ;;
      summary-needs-plan) run bash "$SCRIPTS_DIR/resolve-artifact-path.sh" summary "$PHASE" ;;
      research-needs-plan) run bash "$SCRIPTS_DIR/resolve-artifact-path.sh" research "$PHASE" ;;
    esac
    expect_case "$label" "$expected_status"
  done
  assert_no_case_failures
}

@test "artifact resolution rejects ambiguous identities rather than emitting a usable filename" {
  artifact_rejections <<'CASES'
missing-type|1
unknown-type|1
missing-phase|1
absent-phase|2
unnamed-phase|1
unknown-option|1
missing-option-value|1
nonnumeric-plan|1
zero-plan|1
summary-needs-plan|1
research-needs-plan|1
CASES
}
