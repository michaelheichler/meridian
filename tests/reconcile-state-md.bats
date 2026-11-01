#!/usr/bin/env bats

load script_contract_helper

reconcile_rows() {
  local label plan summary uat qa expected label_text
  while IFS='|' read -r label plan summary uat qa expected label_text; do
    rm -f "$PHASE/03-01-PLAN.md" "$PHASE/03-01-SUMMARY.md" "$PHASE/03-UAT.md"
    printf '# State\n## Current Phase\nPhase: 99 of 99\nPlans: 99/99\nProgress: 99%%\nStatus: stale\n\n## Phase Status\n- **Phase 1:** stale\n\n## Decisions\nKeep the API stable.\n' > "$PLANNING/STATE.md"
    printf '{"qa_required":%s}\n' "$qa" > "$PLANNING/.execution-state.json"
    [ "$plan" = no ] || touch "$PHASE/03-01-PLAN.md"
    [ "$summary" = none ] || printf '%s\n' '---' "status: $summary" '---' > "$PHASE/03-01-SUMMARY.md"
    [ "$uat" = none ] || printf '%s\n' '---' "status: $uat" '---' > "$PHASE/03-UAT.md"
    run bash "$SCRIPTS_DIR/reconcile-state-md.sh" --changed "$PHASE/03-01-PLAN.md" --json
    expect_case "$label" 0
    expect_jq_output "$label" ".status == \"reconciled\" and .phase_status == \"$expected\""
    expect_file_line "$label" "$PLANNING/STATE.md" "^Status: $expected$"
    expect_file_line "$label" "$PLANNING/STATE.md" "$label_text"
    expect_file_line "$label" "$PLANNING/STATE.md" '^Keep the API stable\.$'
  done
  assert_no_case_failures
}

@test "state reconciliation derives readiness from plans, terminal summaries, QA and unresolved UAT" {
  reconcile_rows <<'CASES'
unplanned|no|none|none|false|ready|Pending planning
planned|yes|none|none|false|ready|Planned
partial|yes|partial|none|false|active|In progress
failed|yes|failed|none|false|active|In progress
complete|yes|complete|none|false|complete|Complete
qa-still-required|yes|complete|none|true|needs_verification|Needs verification
uat-active|yes|complete|in_progress|false|needs_verification|Needs verification
uat-failed|yes|complete|issues_found|false|needs_remediation|Needs remediation
uat-passed|yes|complete|passed|false|complete|Complete
CASES
}

@test "state reconciliation updates legacy phase fields without changing neighboring sections" {
  touch "$PHASE/03-01-PLAN.md"
  printf '%s\n' 'Phase: 8 of 8' 'Plans: 8/8' 'Progress: 80%' 'Status: stale' '## Decisions' 'Keep retries bounded.' > "$PLANNING/STATE.md"
  run bash "$SCRIPTS_DIR/reconcile-state-md.sh" "$PLANNING" --json
  [ "$status" -eq 0 ]
  grep -q '^Phase: 1 of 1 (' "$PLANNING/STATE.md"
  grep -q '^Plans: 0/1$' "$PLANNING/STATE.md"
  grep -q '^Progress: 0%$' "$PLANNING/STATE.md"
  grep -q '^Keep retries bounded\.$' "$PLANNING/STATE.md"
}
