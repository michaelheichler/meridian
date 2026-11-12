#!/usr/bin/env bats

load test_helper

setup() {
  setup_temp_dir
  SCRIPT="$SCRIPTS_DIR/write-verification.sh"
  PHASE_DIR="$TEST_TEMP_DIR/.meridian/phases/01-verification"
  TARGET="$PHASE_DIR/01-VERIFICATION.md"
  mkdir -p "$PHASE_DIR"
}

teardown() {
  teardown_temp_dir
}

run_writer() {
  printf '%s\n' "$1" | bash "$SCRIPT" "$2"
}

passing_payload() {
  cat <<'JSON'
{
  "phase": "01",
  "tier": "standard",
  "result": "PASS",
  "checks": {"passed": 1, "failed": 0, "total": 1},
  "checks_detail": [
    {"id": "must-have", "status": "PASS", "category": "must_have", "description": "The artifact exists", "evidence": "observed"}
  ]
}
JSON
}

fail_case() {
  printf 'case=%s %s\nactual=[%s]\n' "$1" "$2" "$3" >&2
  return 1
}

expect_has() {
  case "$3" in
    *"$2"*) ;;
    *) fail_case "$1" "expected to contain=[$2]" "$3" ;;
  esac
}

reset_phase_dir() {
  find "$PHASE_DIR" -type f -delete
}

plan_fixture() {
  local entry
  [ "$1" != "-" ] || return 0
  for entry in $(printf '%s' "$1" | tr ',' ' '); do
    case "$entry" in
      PLAN.md=*) printf -- '---\nplan: %s\n---\n' "${entry#PLAN.md=}" > "$PHASE_DIR/PLAN.md" ;;
      *) touch "$PHASE_DIR/$entry" ;;
    esac
  done
}

build_payload() {
  case "$1" in
    raw:*) printf '%s' "${1#raw:}" ;;
    *) passing_payload | jq "$1" ;;
  esac
}

leftover_temp_files() {
  find "$PHASE_DIR" -name '*.tmp.*'
}

@test "valid payloads replace the old artifact atomically, and outside Git they omit the commit stamp" {
  local label filter plans expected_lines line count expanded
  while IFS='~' read -r label filter plans expected_lines; do
    [ -n "$label" ] || continue
    reset_phase_dir
    printf '%s\n' "old artifact" > "$TARGET"
    plan_fixture "$plans"

    run run_writer "$(build_payload "$filter")" "$TARGET"

    [ "$status" -eq 0 ] || fail_case "$label" "status=0" "status=$status output=$output"
    [ -z "$(leftover_temp_files)" ] || fail_case "$label" "no temp files" "$(leftover_temp_files)"
    count=$(grep -Fxc "old artifact" "$TARGET" || true)
    [ "$count" = "0" ] || fail_case "$label" "old artifact gone" "$(cat "$TARGET")"
    expanded="${expected_lines//;;/$'\n'}"
    expanded="${expanded//NUM/#}"
    while IFS= read -r line; do
      count=$(grep -Fxc -- "$line" "$TARGET" || true)
      [ "$count" = "1" ] || fail_case "$label" "line appears once=[$line]" "$(cat "$TARGET")"
    done <<EXPECTED
$expanded
EXPECTED
  done <<'CASES'
canonical-pass~.~-~writer: write-verification.sh;;result: PASS;;## Must-Have Checks
pass-downgraded-by-failed-detail~.result = "PASS" | .checks = {passed: 0, failed: 1, total: 1} | .checks_detail[0].status = "FAIL"~-~result: PARTIAL
rich-failed-artifact-check~.result = "FAIL" | .checks = {passed: 0, failed: 1, total: 1} | .checks_detail[0] = {id: "artifact-docs", status: "FAIL", category: "artifact", description: "docs/api.md", exists: false, contains: "retry guidance", evidence: "docs/api.md is missing, so add the retry guidance."}~-~| NUM | ID | Artifact | Exists | Contains | Evidence | Status |;;| 1 | artifact-docs | docs/api.md | No | retry guidance | docs/api.md is missing, so add the retry guidance. | FAIL |
rich-failed-key-link-check~.result = "FAIL" | .checks = {passed: 0, failed: 1, total: 1} | .checks_detail[0] = {id: "qa-route", status: "FAIL", category: "key_link", description: "QA command invokes the writer", from: "commands/qa.md", to: "scripts/write-verification.sh", via: "subprocess call", evidence: "commands/qa.md bypasses the writer, so route QA through it."}~-~| NUM | ID | From | To | Via | Evidence | Status |;;| 1 | qa-route | commands/qa.md | scripts/write-verification.sh | subprocess call | commands/qa.md bypasses the writer, so route QA through it. | FAIL |
each-canonical-plan-id-once~.checks = {passed: 2, failed: 0, total: 2} | .plans_verified = ["01-01", "01-02"] | .checks_detail[0].plan_ref = "01-01" | .checks_detail += [{"id":"artifact","status":"PASS","plan_ref":"01-02"}]~01-01-PLAN.md,01-02-PLAN.md~  - 01-01;;  - 01-02
envelope-phase~raw:{"phase":"02","payload":{"tier":"quick","result":"PASS","checks":{"passed":1,"failed":0,"total":1},"checks_detail":[{"id":"c1","status":"PASS","category":"must_have"}]}}~-~phase: 02;;tier: quick
phase-omitted~del(.phase)~-~phase: unknown
legacy-plan-without-id~.plans_verified = ["PLAN"] | .checks_detail[0].plan_ref = "PLAN"~PLAN.md=~  - PLAN
rich-requirement-and-convention-checks~.checks = {passed: 2, failed: 0, total: 2} | .checks_detail = [{id: "REQ-1", status: "PASS", category: "requirement", description: "Retry policy", plan_ref: "R9", evidence: "docs"}, {id: "CV-1", status: "PASS", category: "convention", description: "Naming", file: "src/a.sh", detail: "camelCase"}]~-~| NUM | ID | Requirement | Plan Ref | Evidence | Status |;;| 1 | REQ-1 | Retry policy | R9 | docs | PASS |;;| NUM | ID | Convention | File | Status | Detail |;;| 1 | CV-1 | Naming | src/a.sh | PASS | camelCase |
pre-existing-issues~.pre_existing_issues = [{test: "t1", file: "f1.sh", error: "bo|om"}]~-~## Pre-existing Issues;;| t1 | f1.sh | bo&#124;om |
CASES

  reset_phase_dir
  run bash -c 'cd "$1" && printf "%s\\n" "$2" | bash "$3" "$4"' bash "$TEST_TEMP_DIR" "$(passing_payload)" "$SCRIPT" "$TARGET"
  [ "$status" -eq 0 ] || fail_case outside-git "status=0" "status=$status output=$output"
  count=$(grep -Fxc 'result: PASS' "$TARGET" || true)
  [ "$count" = "1" ] || fail_case outside-git "result line written" "$(cat "$TARGET")"
  count=$(grep -Fc 'verified_at_commit:' "$TARGET" || true)
  [ "$count" = "0" ] || fail_case outside-git "no commit stamp" "$(cat "$TARGET")"
}

@test "invalid payloads are rejected with a reason and leave the target untouched" {
  local label existing plans payload fragment leftovers
  while IFS='~' read -r label existing plans payload fragment; do
    [ -n "$label" ] || continue
    reset_phase_dir
    [ "$existing" != "yes" ] || printf '%s\n' "old artifact" > "$TARGET"
    plan_fixture "$plans"

    run run_writer "$(build_payload "$payload")" "$TARGET"

    [ "$status" -ne 0 ] || fail_case "$label" "non-zero status" "status=$status output=$output"
    expect_has "$label" "$fragment" "$output"
    if [ "$existing" = "yes" ]; then
      [ "$(cat "$TARGET")" = "old artifact" ] || fail_case "$label" "old artifact kept" "$(cat "$TARGET")"
    else
      [ ! -e "$TARGET" ] || fail_case "$label" "no artifact created" "$(cat "$TARGET")"
    fi
    leftovers=$(leftover_temp_files)
    [ -z "$leftovers" ] || fail_case "$label" "no temp files" "$leftovers"
  done <<'CASES'
invalid-json~no~-~raw:not json~invalid JSON
unknown-result~no~-~raw:{"tier":"standard","result":"UNKNOWN","checks":{"passed":1,"total":1}}~result must be
non-object-payload~yes~-~raw:{"payload":[]}~must be a JSON object
tier-outside-enum~no~-~.tier = "thorough"~tier
negative-counter~no~-~.checks = {"passed":-1,"failed":0,"total":0} | del(.checks_detail) | .result = "FAIL"~checks
fractional-counter~no~-~.checks = {"passed":0.5,"failed":0,"total":1} | del(.checks_detail) | .result = "FAIL"~checks
passed-plus-failed-above-total~no~-~.checks = {"passed":1,"failed":1,"total":1} | del(.checks_detail) | .result = "FAIL"~checks
counters-differ-from-detail~no~-~.checks = {passed: 2, failed: 0, total: 2}~must match checks_detail
pass-without-detail~no~-~del(.checks_detail)~checks_detail is required
detail-status-outside-enum~no~-~.checks_detail[0].status = "MAYBE"~status must be
fail-without-detail~yes~-~.result = "FAIL" | .checks = {passed: 0, failed: 0, total: 0} | del(.checks_detail)~checks_detail
fail-detail-has-no-failed-check~yes~-~.result = "FAIL"~FAIL check
fail-with-unstable-id~yes~-~.result = "FAIL" | .checks = {passed: 0, failed: 1, total: 1} | .checks_detail[0].status = "FAIL" | .checks_detail[0].id = "test failure"~stable ID
fail-with-blank-description~yes~-~.result = "FAIL" | .checks = {passed: 0, failed: 1, total: 1} | .checks_detail[0].status = "FAIL" | .checks_detail[0].description = " "~actionable
fail-with-blank-evidence~yes~-~.result = "FAIL" | .checks = {passed: 0, failed: 1, total: 1} | .checks_detail[0].status = "FAIL" | .checks_detail[0].evidence = " "~actionable
plans-exist-without-plans-verified~no~01-01-PLAN.md~.~plans_verified is required
check-without-plan-ref~no~01-01-PLAN.md~.plans_verified = ["01-01"]~plan_ref
duplicate-plan-ids~no~01-01-PLAN.md~.plans_verified = ["01-01", "01-01"] | .checks_detail[0].plan_ref = "01-01"~plans_verified
plan-filename-alias~no~01-01-PLAN.md~.plans_verified = ["01-01-PLAN.md"] | .checks_detail[0].plan_ref = "01-01"~plans_verified
empty-plan-id~no~01-01-PLAN.md~.plans_verified = ["", "01-01"] | .checks_detail[0].plan_ref = "01-01"~plans_verified
legacy-plan-alias-beside-canonical-id~no~PLAN.md=01~.plans_verified = ["PLAN"] | .checks_detail[0].plan_ref = "PLAN"~plans_verified
unknown-plan-ref~no~01-01-PLAN.md~.plans_verified = ["01-01"] | .checks_detail[0].plan_ref = "PLAN.md"~plan_ref
unknown-plan-ref-beside-verified-one~no~01-01-PLAN.md~.checks = {passed: 2, failed: 0, total: 2} | .plans_verified = ["01-01"] | .checks_detail[0].plan_ref = "01-01" | .checks_detail += [{"id":"artifact","status":"PASS","plan_ref":"PLAN.md"}]~plan_ref
plans-verified-without-plan-files~no~-~.plans_verified = ["01-01"]~must be empty
plan-file-missing-from-plans-verified~no~01-01-PLAN.md,01-02-PLAN.md~.plans_verified = ["01-01"] | .checks_detail[0].plan_ref = "01-01"~plans_verified has
phase-frontmatter-injection~yes~-~.phase = "01\\nwriter: forged"~phase
top-level-array~no~-~raw:[]~must be a JSON object
tier-not-string~no~-~.tier = 5~tier must be quick, standard, or deep
result-missing~no~-~del(.result)~missing required field (result)
phase-not-string~no~-~.phase = 1~phase must be a string
envelope-phase-not-string~no~-~raw:{"phase":7,"payload":{"tier":"quick","result":"PASS","checks":{"passed":1,"failed":0,"total":1},"checks_detail":[{"id":"c1","status":"PASS"}]}}~phase must be a string
detail-not-array~no~-~.checks_detail = {}~checks_detail must be an array
unsafe-discovered-plan-id~no~PLAN.md=bad/id~.~unsafe canonical plan ID 'bad/id'
duplicate-discovered-plan-id~no~01-01-PLAN.md,PLAN.md=01-01~.~duplicate canonical plan ID '01-01'
non-canonical-verified-plan~no~01-01-PLAN.md~.plans_verified = ["bad id"] | .checks_detail[0].plan_ref = "01-01"~plan 'bad id' in plans_verified is not a canonical plan ID
non-canonical-plan-ref~no~01-01-PLAN.md~.plans_verified = ["01-01"] | .checks_detail[0].plan_ref = "bad ref"~plan_ref 'bad ref' is not a canonical plan ID
verified-plan-without-check~no~01-01-PLAN.md,01-02-PLAN.md~.plans_verified = ["01-01", "01-02"] | .checks_detail[0].plan_ref = "01-01"~no check in checks_detail has plan_ref='01-02'
CASES
}