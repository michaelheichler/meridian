#!/usr/bin/env bats

load script_contract_helper

write_issue() {
  printf '%s\n' '---' 'phase: 3' 'status: issues_found' 'issues: 1' '---' \
    '### P7: Checkout' '- **Result:** issue' '- **Issue:** Checkout error' > "$1"
}

@test "issue extraction includes prior failure rounds from flat archives and round directories" {
  mkdir -p "$PHASE/remediation/uat/round-02" "$PHASE/remediation/uat/round-03"
  write_issue "$PHASE/03-UAT-round-01.md"
  write_issue "$PHASE/remediation/uat/round-02/R02-UAT.md"
  write_issue "$PHASE/remediation/uat/round-03/R03-UAT.md"
  run bash "$SCRIPTS_DIR/extract-uat-issues.sh" "$PHASE/remediation/uat/round-03/R03-UAT.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'uat_phase=03 uat_issues_total=1 uat_round=3'* ]]
  [[ "$output" == *'P7|critical|Checkout error|1,2,3'* ]]
}

extract_rows() {
  local label filename content expected
  while IFS='|' read -r label filename content expected; do
    mkdir -p "$(dirname "$filename")"
    printf '%b' "$content" > "$filename"
    run bash "$SCRIPTS_DIR/extract-uat-issues.sh" "$filename"
    expect_case "$label" 0 "$expected"
  done
  assert_no_case_failures
}

@test "issue extraction distinguishes completed reports from inconsistent issue counts and resolves phase metadata" {
  extract_rows <<'CASES'
completed|notes/report.md|---\nstatus: passed\n---\n|uat_extract_status=complete
unknown|notes/unknown.md|# Notes\n|uat_extract_status=unknown
inconsistent|notes/broken.md|---\nstatus: issues_found\nissues: 2\n---\n|uat_extract_error=true
metadata-phase|notes/current.md|---\nphase: 17\nstatus: issues_found\nissues: 0\n---\n|uat_phase=17 uat_issues_total=0 uat_round=1
filename-phase|notes/12-UAT.md|---\nstatus: issues_found\nissues: 0\n---\n|uat_phase=12 uat_issues_total=0 uat_round=1
CASES
}
