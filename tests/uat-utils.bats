#!/usr/bin/env bats

load script_contract_helper

status_rows() {
  local label content expected
  while IFS='|' read -r label content expected; do
    printf '%b' "$content" > "$PHASE/03-UAT.md"
    run /bin/bash -c 'source "$1/lib/uat-utils.sh"; uat_file_status_class "$2"' bash "$SCRIPTS_DIR" "$PHASE/03-UAT.md"
    expect_case "$label" 0
    [ "$output" = "$expected" ] || record_case_failure "$label" "got=$output want=$expected"
  done
  assert_no_case_failures
}

@test "UAT status parsing respects frontmatter and ignores incidental body status text" {
  status_rows <<'CASES'
quoted-crlf|---\r\nSTATUS: "FAILED"\r\n---\r\n|issues_found
single-quoted|---\n status : 'ALL_PASS'\n---\n|complete
empty-frontmatter-status|---\nstatus: \n---\n|active
unknown-frontmatter-status|---\nstatus: review_needed\n---\n|active
body-legacy-status|# UAT\nstatus: verified\n|complete
body-unknown-status|# UAT\nstatus: unrelated\n|none
indented-example|# UAT\n  status: failed\n|none
frontmatter-wins|---\nstatus: complete\n---\nstatus: failed\n|complete
no-final-newline|status: failed|issues_found
no-status|# Draft UAT\n|none
CASES
}

selection_rows() {
  local label state_location layout round expected
  while IFS='|' read -r label state_location layout round expected; do
    rm -rf "$PHASE/remediation" "$PHASE/.uat-remediation-stage"
    mkdir -p "$PHASE/remediation/uat/round-01" "$PHASE/remediation/uat/round-03" "$PHASE/remediation/round-02" "$PHASE/remediation/round-04"
    touch "$PHASE/03-UAT.md" "$PHASE/99-SOURCE-UAT.md" \
      "$PHASE/remediation/uat/round-01/R01-UAT.md" "$PHASE/remediation/uat/round-03/R03-UAT.md" \
      "$PHASE/remediation/round-02/R02-UAT.md" "$PHASE/remediation/round-04/R04-UAT.md"
    printf 'layout=%s\nround=%s\n' "$layout" "$round" > "$PHASE/$state_location"
    run /bin/bash -c 'source "$1/lib/uat-utils.sh"; current_uat "$2"' bash "$SCRIPTS_DIR" "$PHASE/"
    expect_case "$label" 0
    [ "$output" = "$PHASE/$expected" ] || record_case_failure "$label" "got=$output want=$expected"
  done
  assert_no_case_failures
}

@test "current UAT follows saved remediation layout and falls back to the latest available round" {
  selection_rows <<'CASES'
canonical-exact|remediation/uat/.uat-remediation-stage|round-dir|01|remediation/uat/round-01/R01-UAT.md
canonical-missing|remediation/uat/.uat-remediation-stage|round-dir|04|remediation/uat/round-03/R03-UAT.md
legacy-exact|remediation/.uat-remediation-stage|legacy|02|remediation/round-02/R02-UAT.md
legacy-missing|.uat-remediation-stage|legacy|05|remediation/round-04/R04-UAT.md
legacy-default-layout|.uat-remediation-stage||02|remediation/round-02/R02-UAT.md
unrecognized-layout|remediation/uat/.uat-remediation-stage|unrecognized|02|03-UAT.md
CASES
}
