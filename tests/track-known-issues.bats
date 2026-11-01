#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load gate_case_helper
load gate_case_files

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/track-known-issues.sh"
  TEST_ROOT="$(mktemp -d)"
  PLANNING_DIR="$TEST_ROOT/.lbwc-planning"
  PHASE_DIR="$PLANNING_DIR/phases/03-test-phase"
  REGISTRY="$PHASE_DIR/known-issues.json"
  SUPPRESS_VIA="/lbwc:list-todos"
  mkdir -p "$PHASE_DIR"
  reset_case_failures
}

teardown() {
  chmod -R u+w "$TEST_ROOT"
  rm -rf "$TEST_ROOT"
}

write_summary() {
  cat > "$PHASE_DIR/03-01-SUMMARY.md" <<'SUMMARY'
---
phase: 03
pre_existing_issues:
  - '{"test":"TransferTests","file":"tests/transfer.sh","error":"timeout"}'
---
SUMMARY
}

write_second_summary() {
  cat > "$PHASE_DIR/03-02-SUMMARY.md" <<'SUMMARY'
---
phase: 03
pre_existing_issues:
  - '{"test":"BetaTests","file":"tests/beta.sh","error":"crash"}'
---
SUMMARY
}

write_backslash_summary() {
  cat > "$PHASE_DIR/03-03-SUMMARY.md" <<'SUMMARY'
---
phase: 03
pre_existing_issues:
  - '{"test":"GammaTests","file":"tests/gamma.sh","error":"path C:\\temp\\new"}'
---
SUMMARY
}

write_verification() {
  local result=$1
  cat > "$PHASE_DIR/03-VERIFICATION.md" <<VERIFICATION
---
result: $result
pre_existing_issues:
  - '{"test":"TransferTests","file":"tests/transfer.sh","error":"timeout"}'
---
VERIFICATION
}

reset_phase() {
  find "$PHASE_DIR" -type f -delete
  printf '## Todos\nNone.\n' > "$PLANNING_DIR/STATE.md"
}

seed_registry() {
  rm -f "$REGISTRY"
  write_summary
  write_second_summary
  bash "$SCRIPT" sync-summaries "$PHASE_DIR" >/dev/null
  jq '.issues |= map(if .test == "TransferTests" then . + {phase: "07"} else . end)' "$REGISTRY" > "$REGISTRY.seed"
  mv "$REGISTRY.seed" "$REGISTRY"
}

prepare_registry() {
  case "$1" in
    seeded) seed_registry ;;
    missing) rm -f "$REGISTRY" ;;
    malformed) printf '{bad' > "$REGISTRY" ;;
  esac
}

registry_digest() {
  cksum < "$REGISTRY" 2>/dev/null || echo absent
}

registry_entry() {
  jq -c --arg name "$1" "[.issues[] | select(.test == \$name)][0] | $2" "$REGISTRY"
}

payload_named() {
  case "$1" in
    transfer) printf '%s' '{"test":"TransferTests","file":"tests/transfer.sh","error":"timeout"}' ;;
    transfer-via) printf '%s' '{"test":"TransferTests","file":"tests/transfer.sh","error":"timeout","via":"/lbwc:list-todos"}' ;;
    transfer-other-via) printf '%s' '{"test":"TransferTests","file":"tests/transfer.sh","error":"timeout","via":"/lbwc:fix"}' ;;
    unknown) printf '%s' '{"test":"NoSuchTest","file":"tests/none.sh","error":"gone"}' ;;
    unknown-via) printf '%s' '{"test":"NoSuchTest","file":"tests/none.sh","error":"gone","via":"/lbwc:list-todos"}' ;;
    no-test) printf '%s' '{"file":"tests/transfer.sh","error":"timeout"}' ;;
    no-file) printf '%s' '{"test":"TransferTests","error":"timeout"}' ;;
    no-error) printf '%s' '{"test":"TransferTests","file":"tests/transfer.sh"}' ;;
    number-test) printf '%s' '{"test":1,"file":"tests/transfer.sh","error":"timeout"}' ;;
    number-file) printf '%s' '{"test":"TransferTests","file":2,"error":"timeout"}' ;;
    number-error) printf '%s' '{"test":"TransferTests","file":"tests/transfer.sh","error":3}' ;;
    array) printf '%s' '[]' ;;
  esac
}

run_with_stdin() {
  local payload="$1"
  shift
  run bash -c 'printf "%s" "$1" | bash "${@:2}"' -- "$payload" "$@"
}

suppress_transfer() {
  bash "$SCRIPT" suppress "$PHASE_DIR" <<< "$(payload_named transfer-via)" >/dev/null
}

expect_json_is() {
  local actual
  actual=$(printf '%s' "$output" | jq -r "$2" 2>&1)
  [ "$actual" = "$3" ] || record_case_failure "$1" "json $2 is [$actual] want [$3] output=$output"
}

expect_entry_is() {
  local label=$1 name=$2 filter=$3 want=$4 actual
  actual=$(registry_entry "$name" "$filter")
  [ "$actual" = "$want" ] || record_case_failure "$label" "entry $name $filter is [$actual] want [$want]"
}

expect_digest_is() {
  local actual
  actual=$(registry_digest)
  [ "$actual" = "$2" ] || record_case_failure "$1" "registry bytes changed, before=$2 after=$actual"
}

@test "track-known-issues sync-summaries builds an idempotent registry that keeps a suppression, and sync-verification counts a repeat, resolves on PASS and tolerates a missing file" {
  write_summary
  run bash "$SCRIPT" sync-summaries "$PHASE_DIR"
  expect_case first-sync 0 "known_issues_status=present"
  expect_output_has first-sync "known_issues_count=1"
  expect_jq first-sync "$REGISTRY" '.issues[0].test == "TransferTests"'
  local first
  first="$(jq -cS '.issues[0]' "$REGISTRY")"

  bash "$SCRIPT" sync-summaries "$PHASE_DIR" >/dev/null
  [ "$first" = "$(jq -cS '.issues[0]' "$REGISTRY")" ] || record_case_failure second-sync-idempotent "first entry changed on the second sync"

  write_second_summary
  run bash "$SCRIPT" sync-summaries "$PHASE_DIR"
  expect_case second-summary-merged 0 "known_issues_count=2"

  seed_registry
  suppress_transfer
  run bash "$SCRIPT" sync-summaries "$PHASE_DIR"
  expect_case suppression-survives-resync 0 "known_issues_status=present"
  expect_entry_is suppression-survives-resync TransferTests .suppressed.via "\"$SUPPRESS_VIA\""
  expect_entry_is suppression-survives-resync TransferTests .times_seen 1

  seed_registry
  suppress_transfer
  write_verification FAIL
  run bash "$SCRIPT" sync-verification "$PHASE_DIR" "$PHASE_DIR/03-VERIFICATION.md"
  expect_case fail-verification 0 "known_issues_status=present"
  expect_entry_is fail-verification-keeps-suppression TransferTests .suppressed.via "\"$SUPPRESS_VIA\""
  expect_entry_is fail-verification-counts-again TransferTests .times_seen 2
  expect_entry_is fail-verification-keeps-absent-issue BetaTests .disposition '"unresolved"'

  write_verification PASS
  run bash "$SCRIPT" sync-verification "$PHASE_DIR" "$PHASE_DIR/03-VERIFICATION.md"
  expect_case pass-verification 0 "known_issues_count=0"
  expect_entry_is pass-verification-resolves-reported TransferTests .disposition '"resolved"'
  expect_entry_is pass-verification-resolves-absent BetaTests .disposition '"resolved"'

  run bash "$SCRIPT" sync-verification "$PHASE_DIR" "$PHASE_DIR/absent-VERIFICATION.md"
  expect_case missing-verification-file 0 "known_issues_status=missing"

  assert_no_case_failures
}

@test "track-known-issues promote-todos: writes each root-canonical issue once and skips suppressed ones" {
  reset_phase
  write_summary
  bash "$SCRIPT" sync-summaries "$PHASE_DIR" >/dev/null
  run bash "$SCRIPT" promote-todos "$PHASE_DIR"
  expect_case single-issue 0 "promoted_count=1"
  expect_file_line single-issue "$PLANNING_DIR/STATE.md" '\[KNOWN-ISSUE\] TransferTests (tests/transfer.sh): timeout'
  run bash "$SCRIPT" promote-todos "$PHASE_DIR"
  expect_case single-issue-repeat 0 "already_tracked_count=1"

  reset_phase
  write_summary
  write_second_summary
  bash "$SCRIPT" sync-summaries "$PHASE_DIR" >/dev/null
  run bash "$SCRIPT" promote-todos "$PHASE_DIR"
  expect_case several-issues 0 "promoted_count=2"
  expect_output_has several-issues "promote_status=promoted"
  expect_output_lacks several-issues "newline in string"
  [ "$(sed -n '/^## Todos$/,$p' "$PLANNING_DIR/STATE.md" | grep -c '\[KNOWN-ISSUE\]')" -eq 2 ] \
    || record_case_failure several-issues "Todos section does not hold exactly two known issues"
  expect_no_file_line several-issues "$PLANNING_DIR/STATE.md" '^None\.$'
  run bash "$SCRIPT" promote-todos "$PHASE_DIR"
  expect_case several-issues-repeat 0 "promoted_count=0"
  expect_output_has several-issues-repeat "already_tracked_count=2"

  write_backslash_summary
  bash "$SCRIPT" sync-summaries "$PHASE_DIR" >/dev/null
  bash "$SCRIPT" promote-todos "$PHASE_DIR" >/dev/null
  grep -qF 'C:\temp\new' "$PLANNING_DIR/STATE.md" || record_case_failure backslashes-literal "backslashes were altered in STATE.md"

  reset_phase
  seed_registry
  suppress_transfer
  run bash "$SCRIPT" promote-todos "$PHASE_DIR"
  expect_case suppressed-skipped 0 "promoted_count=1"
  expect_file_line suppressed-skipped "$PLANNING_DIR/STATE.md" '\[KNOWN-ISSUE\] BetaTests (tests/beta.sh): crash'
  expect_no_file_line suppressed-skipped "$PLANNING_DIR/STATE.md" "TransferTests"

  assert_no_case_failures
}

@test "track-known-issues: rejects a missing STATE.md, a malformed registry, a bad phase directory and incomplete usage" {
  write_summary
  bash "$SCRIPT" sync-summaries "$PHASE_DIR" >/dev/null
  run bash "$SCRIPT" promote-todos "$PHASE_DIR"
  expect_output_has promote-without-state "promote_status=no_state_file"
  [ "$status" -ne 0 ] || record_case_failure promote-without-state "promote succeeded without a root STATE.md"

  printf '{bad' > "$REGISTRY"
  run bash "$SCRIPT" sync-summaries "$PHASE_DIR"
  expect_case sync-malformed-registry 1 "known_issues_status=malformed"

  run bash "$SCRIPT" status "$TEST_ROOT/missing"
  expect_case missing-phase-dir 1 "known_issues_status=missing_phase_dir"

  mkdir -p "$TEST_ROOT/elsewhere"
  run bash "$SCRIPT" status "$TEST_ROOT/elsewhere"
  expect_case phase-dir-outside-planning 1 "known_issues_status=invalid_phase_dir"

  run bash "$SCRIPT"
  expect_case usage-lists-lookup-signature 1 "lookup-signature <phase-dir>"
  expect_output_has usage-lists-suppress "suppress <phase-dir>"

  run bash "$SCRIPT" lookup-signature
  expect_case lookup-signature-needs-phase-dir 1 "usage:"
  run bash "$SCRIPT" suppress
  expect_case suppress-needs-phase-dir 1 "usage:"
  run bash "$SCRIPT" resolve "$PHASE_DIR"
  expect_case resolve-needs-signature 1 "usage:"
  run bash "$SCRIPT" sync-verification "$PHASE_DIR"
  expect_case sync-verification-needs-file 1 "usage:"
  run bash "$SCRIPT" unknown-command "$PHASE_DIR"
  expect_case unknown-command 1 "usage:"

  assert_no_case_failures
}

@test "track-known-issues status, resolve and clear: report the registry state and update it" {
  run bash "$SCRIPT" status "$PHASE_DIR"
  expect_case status-missing 0 "known_issues_status=missing"
  expect_output_has status-missing "known_issues_count=0"

  seed_registry
  run bash "$SCRIPT" status "$PHASE_DIR"
  expect_case status-present 0 "known_issues_status=present"
  expect_output_has status-present "known_issues_count=2"

  local signature
  signature=$(jq -r '[.issues[] | select(.test == "TransferTests")][0].signature' "$REGISTRY")
  run bash "$SCRIPT" resolve "$PHASE_DIR" "$signature"
  expect_case resolve-one 0 "known_issues_count=1"
  expect_entry_is resolve-one TransferTests .disposition '"resolved"'
  expect_entry_is resolve-one-leaves-other BetaTests .disposition '"unresolved"'

  printf '{bad' > "$REGISTRY"
  run bash "$SCRIPT" status "$PHASE_DIR"
  expect_case status-malformed 0 "known_issues_status=malformed"

  seed_registry
  run bash "$SCRIPT" clear "$PHASE_DIR"
  expect_case clear 0 "known_issues_status=missing"
  expect_no_path clear "$REGISTRY"

  assert_no_case_failures
}

answer_row() {
  local label="$1" command="$2" payload="$3" filter="$4" expected="$5"
  seed_registry
  run_with_stdin "$(payload_named "$payload")" "$SCRIPT" "$command" "$PHASE_DIR"
  expect_status "$label" 0
  expect_json_is "$label" "$filter" "$expected"
}

coded_error_row() {
  local label="$1" command="$2" registry="$3" payload="$4" code="$5" before
  prepare_registry "$registry"
  before="$(registry_digest)"
  run_with_stdin "$(payload_named "$payload")" "$SCRIPT" "$command" "$PHASE_DIR"
  expect_status "$label" 0
  expect_json_is "$label" '.status + ":" + .code' "error:$code"
  expect_json_is "$label" '(.message | length) > 0' true
  expect_digest_is "$label" "$before"
}

@test "track-known-issues lookup-signature and suppress answer ok with the registry entry and mark only the match, or report a coded error and leave the registry untouched" {
  local phys_dir
  phys_dir="$(cd "$PHASE_DIR" && pwd -P)"

  answer_row lookup-status lookup-signature transfer .status ok
  answer_row lookup-phase-from-registry-entry lookup-signature transfer .signature.phase 07
  answer_row lookup-phase-dir-is-absolute lookup-signature transfer .signature.phase_dir "$phys_dir"
  answer_row lookup-echoes-issue-identity lookup-signature transfer '.signature | [.test, .file, .error] | join(",")' TransferTests,tests/transfer.sh,timeout
  answer_row lookup-signature-keys lookup-signature transfer '.signature | keys | join(",")' disposition,error,file,phase,phase_dir,source_kind,source_path,test
  answer_row suppress-reports-suppressed suppress transfer-via .action suppressed
  answer_row suppress-returns-12-hex-signature suppress transfer-via '(.signature | test("^[0-9a-f]{12}$"))' true

  coded_error_row lookup-issue-not-found lookup-signature seeded unknown suppression_issue_not_found
  coded_error_row suppress-issue-not-found suppress seeded unknown-via suppression_issue_not_found
  coded_error_row lookup-registry-missing lookup-signature missing transfer suppression_registry_unavailable
  coded_error_row lookup-registry-malformed lookup-signature malformed transfer suppression_registry_unavailable
  coded_error_row suppress-registry-missing suppress missing transfer-via suppression_registry_unavailable
  coded_error_row suppress-registry-malformed suppress malformed transfer-via suppression_registry_unavailable
  coded_error_row lookup-test-absent lookup-signature seeded no-test suppression_missing_signature
  coded_error_row lookup-file-absent lookup-signature seeded no-file suppression_missing_signature
  coded_error_row lookup-error-absent lookup-signature seeded no-error suppression_missing_signature
  coded_error_row lookup-test-not-a-string lookup-signature seeded number-test suppression_missing_signature
  coded_error_row lookup-file-not-a-string lookup-signature seeded number-file suppression_missing_signature
  coded_error_row lookup-error-not-a-string lookup-signature seeded number-error suppression_missing_signature
  coded_error_row lookup-payload-not-an-object lookup-signature seeded array suppression_missing_signature
  coded_error_row suppress-test-absent suppress seeded no-test suppression_missing_signature
  coded_error_row suppress-error-not-a-string suppress seeded number-error suppression_missing_signature

  seed_registry
  local other_before target_before
  other_before="$(registry_entry BetaTests .)"
  target_before="$(registry_entry TransferTests 'del(.suppressed)')"
  run_with_stdin "$(payload_named transfer-via)" "$SCRIPT" suppress "$PHASE_DIR"
  expect_status suppress-run 0
  expect_entry_is suppress-via TransferTests .suppressed.via "\"$SUPPRESS_VIA\""
  expect_entry_is suppress-at TransferTests '.suppressed.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' true
  expect_entry_is suppress-target-fields TransferTests 'del(.suppressed)' "$target_before"
  expect_entry_is suppress-other-entry BetaTests . "$other_before"

  local digest_after_first
  digest_after_first="$(registry_digest)"
  run_with_stdin "$(payload_named transfer-other-via)" "$SCRIPT" suppress "$PHASE_DIR"
  expect_status repeat-run 0
  expect_json_is repeat-action .action already_suppressed
  expect_entry_is repeat-keeps-first-via TransferTests .suppressed.via "\"$SUPPRESS_VIA\""
  expect_digest_is repeat-bytes "$digest_after_first"

  assert_no_case_failures
}

@test "track-known-issues suppress: reports suppression_write_failed and keeps the registry when the phase dir is read-only" {
  [ "$(id -u)" -ne 0 ] || skip "root bypasses chmod, so the registry cannot be made unwritable"
  seed_registry
  local before
  before="$(registry_digest)"
  chmod a-w "$PHASE_DIR"

  run --separate-stderr bash -c 'printf "%s" "$1" | bash "${@:2}"' -- "$(payload_named transfer-via)" "$SCRIPT" suppress "$PHASE_DIR"

  expect_status write-failed 0
  expect_json_is write-failed '.status + ":" + .code' "error:suppression_write_failed"
  expect_json_is write-failed '(.message | length) > 0' true
  expect_digest_is write-failed "$before"
  assert_no_case_failures
}
