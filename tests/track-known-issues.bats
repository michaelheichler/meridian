#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load todo_helper

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/track-known-issues.sh"
  TEST_ROOT="$(mktemp -d)"
  PLANNING_DIR="$TEST_ROOT/.lbwc-planning"
  PHASE_DIR="$PLANNING_DIR/phases/03-test-phase"
  mkdir -p "$PHASE_DIR"
}

teardown() {
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

@test "sync-summaries creates an idempotent root registry" {
  write_summary

  run bash "$SCRIPT" sync-summaries "$PHASE_DIR"

  [ "$status" -eq 0 ]
  [[ "$output" == *"known_issues_status=present"* ]]
  [[ "$output" == *"known_issues_count=1"* ]]
  [ "$(jq -r '.issues[0].test' "$PHASE_DIR/known-issues.json")" = "TransferTests" ]

  first="$(jq -cS '.issues[0]' "$PHASE_DIR/known-issues.json")"
  bash "$SCRIPT" sync-summaries "$PHASE_DIR" >/dev/null
  [ "$first" = "$(jq -cS '.issues[0]' "$PHASE_DIR/known-issues.json")" ]
}

@test "promote-todos writes each root-canonical issue once" {
  write_summary
  bash "$SCRIPT" sync-summaries "$PHASE_DIR" >/dev/null
  cat > "$PLANNING_DIR/STATE.md" <<'STATE'
## Todos
None.
STATE

  run bash "$SCRIPT" promote-todos "$PHASE_DIR"

  [ "$status" -eq 0 ]
  [[ "$output" == *"promoted_count=1"* ]]
  grep -q '\[KNOWN-ISSUE\] TransferTests (tests/transfer.sh): timeout' "$PLANNING_DIR/STATE.md"

  run bash "$SCRIPT" promote-todos "$PHASE_DIR"

  [ "$status" -eq 0 ]
  [[ "$output" == *"already_tracked_count=1"* ]]
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

@test "promote-todos promotes several issues in one pass and keeps backslashes literal" {
  write_summary
  write_second_summary
  bash "$SCRIPT" sync-summaries "$PHASE_DIR" >/dev/null
  printf '## Todos\nNone.\n' > "$PLANNING_DIR/STATE.md"

  run --separate-stderr bash "$SCRIPT" promote-todos "$PHASE_DIR"

  [ "$status" -eq 0 ]
  [[ "$output" == *"promoted_count=2"* ]]
  [[ "$output" == *"promote_status=promoted"* ]]
  [[ "$stderr" != *"newline in string"* ]]
  [ "$(sed -n '/^## Todos$/,$p' "$PLANNING_DIR/STATE.md" | grep -c '\[KNOWN-ISSUE\]')" -eq 2 ]
  ! grep -q '^None\.$' "$PLANNING_DIR/STATE.md"

  run bash "$SCRIPT" promote-todos "$PHASE_DIR"

  [[ "$output" == *"promoted_count=0"* ]]
  [[ "$output" == *"already_tracked_count=2"* ]]

  write_backslash_summary
  bash "$SCRIPT" sync-summaries "$PHASE_DIR" >/dev/null
  bash "$SCRIPT" promote-todos "$PHASE_DIR" >/dev/null

  grep -qF 'C:\temp\new' "$PLANNING_DIR/STATE.md"
}

@test "promote-todos fails closed without root STATE.md" {
  write_summary
  bash "$SCRIPT" sync-summaries "$PHASE_DIR" >/dev/null

  run bash "$SCRIPT" promote-todos "$PHASE_DIR"

  [ "$status" -ne 0 ]
  [[ "$output" == *"promote_status=no_state_file"* ]]
}

SUPPRESS_VIA="/lbwc:list-todos"

seed_registry() {
  local registry="$PHASE_DIR/known-issues.json"
  rm -f "$registry"
  write_summary
  write_second_summary
  bash "$SCRIPT" sync-summaries "$PHASE_DIR" >/dev/null
  jq '.issues |= map(if .test == "TransferTests" then . + {phase: "07"} else . end)' "$registry" > "$registry.seed"
  mv "$registry.seed" "$registry"
}

prepare_registry() {
  case "$1" in
    seeded) seed_registry ;;
    missing) rm -f "$PHASE_DIR/known-issues.json" ;;
    malformed) printf '{bad' > "$PHASE_DIR/known-issues.json" ;;
  esac
}

registry_digest() {
  cksum < "$PHASE_DIR/known-issues.json" 2>/dev/null || echo absent
}

registry_entry() {
  jq -c --arg name "$1" "[.issues[] | select(.test == \$name)][0] | $2" "$PHASE_DIR/known-issues.json"
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

@test "lookup-signature and suppress answer ok with the registry entry" {
  local label command payload filter expected phys_dir
  phys_dir="$(cd "$PHASE_DIR" && pwd -P)"
  while IFS='~' read -r label command payload filter expected; do
    [ -n "$label" ] || continue
    seed_registry
    run_with_stdin "$(payload_named "$payload")" "$SCRIPT" "$command" "$PHASE_DIR"
    expect_status "$label" 0
    expect_json "$label" "$filter" "${expected//@DIR@/$phys_dir}"
  done <<'CASES'
lookup-status~lookup-signature~transfer~.status~ok
lookup-phase-from-registry-entry~lookup-signature~transfer~.signature.phase~07
lookup-phase-dir-is-absolute~lookup-signature~transfer~.signature.phase_dir~@DIR@
lookup-echoes-issue-identity~lookup-signature~transfer~.signature | [.test, .file, .error] | join(",")~TransferTests,tests/transfer.sh,timeout
lookup-signature-keys~lookup-signature~transfer~.signature | keys | join(",")~disposition,error,file,phase,phase_dir,source_kind,source_path,test
suppress-reports-suppressed~suppress~transfer-via~.action~suppressed
suppress-returns-12-hex-signature~suppress~transfer-via~(.signature | test("^[0-9a-f]{12}$"))~true
CASES
}

@test "lookup-signature and suppress report a coded error and leave the registry untouched" {
  local label command registry payload code before
  while IFS='~' read -r label command registry payload code; do
    [ -n "$label" ] || continue
    prepare_registry "$registry"
    before="$(registry_digest)"
    run_with_stdin "$(payload_named "$payload")" "$SCRIPT" "$command" "$PHASE_DIR"
    expect_status "$label" 0
    expect_json "$label" '.status + ":" + .code' "error:$code"
    expect_json "$label" '(.message | length) > 0' true
    [ "$before" = "$(registry_digest)" ] || fail_case "$label" "registry bytes changed, before=$before after=$(registry_digest)"
  done <<'CASES'
lookup-issue-not-found~lookup-signature~seeded~unknown~suppression_issue_not_found
suppress-issue-not-found~suppress~seeded~unknown-via~suppression_issue_not_found
lookup-registry-missing~lookup-signature~missing~transfer~suppression_registry_unavailable
lookup-registry-malformed~lookup-signature~malformed~transfer~suppression_registry_unavailable
suppress-registry-missing~suppress~missing~transfer-via~suppression_registry_unavailable
suppress-registry-malformed~suppress~malformed~transfer-via~suppression_registry_unavailable
lookup-test-absent~lookup-signature~seeded~no-test~suppression_missing_signature
lookup-file-absent~lookup-signature~seeded~no-file~suppression_missing_signature
lookup-error-absent~lookup-signature~seeded~no-error~suppression_missing_signature
lookup-test-not-a-string~lookup-signature~seeded~number-test~suppression_missing_signature
lookup-file-not-a-string~lookup-signature~seeded~number-file~suppression_missing_signature
lookup-error-not-a-string~lookup-signature~seeded~number-error~suppression_missing_signature
lookup-payload-not-an-object~lookup-signature~seeded~array~suppression_missing_signature
suppress-test-absent~suppress~seeded~no-test~suppression_missing_signature
suppress-error-not-a-string~suppress~seeded~number-error~suppression_missing_signature
CASES
}

@test "suppress marks only the matching entry with via and a UTC timestamp" {
  seed_registry
  local other_before target_before
  other_before="$(registry_entry BetaTests .)"
  target_before="$(registry_entry TransferTests 'del(.suppressed)')"

  run_with_stdin "$(payload_named transfer-via)" "$SCRIPT" suppress "$PHASE_DIR"

  expect_status suppress-run 0
  [ "$(registry_entry TransferTests .suppressed.via)" = "\"$SUPPRESS_VIA\"" ] || fail_case suppress-via "got $(registry_entry TransferTests .suppressed)"
  [ "$(registry_entry TransferTests '.suppressed.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")')" = "true" ] || fail_case suppress-at "got $(registry_entry TransferTests .suppressed)"
  [ "$(registry_entry TransferTests 'del(.suppressed)')" = "$target_before" ] || fail_case suppress-target-fields "target entry fields changed"
  [ "$(registry_entry BetaTests .)" = "$other_before" ] || fail_case suppress-other-entry "other entry changed"
}

@test "a repeated suppress reports already_suppressed and keeps the first via and timestamp" {
  seed_registry
  bash "$SCRIPT" suppress "$PHASE_DIR" <<< "$(payload_named transfer-via)" >/dev/null
  local before
  before="$(registry_digest)"

  run_with_stdin "$(payload_named transfer-other-via)" "$SCRIPT" suppress "$PHASE_DIR"

  expect_status repeat-run 0
  expect_json repeat-action '.action' already_suppressed
  [ "$(registry_entry TransferTests .suppressed.via)" = "\"$SUPPRESS_VIA\"" ] || fail_case repeat-via "got $(registry_entry TransferTests .suppressed)"
  [ "$before" = "$(registry_digest)" ] || fail_case repeat-bytes "registry changed on repeat"
}

@test "promote-todos skips a suppressed issue and still promotes an unsuppressed one" {
  seed_registry
  bash "$SCRIPT" suppress "$PHASE_DIR" <<< "$(payload_named transfer-via)" >/dev/null
  printf '## Todos\nNone.\n' > "$PLANNING_DIR/STATE.md"

  run bash "$SCRIPT" promote-todos "$PHASE_DIR"

  [ "$status" -eq 0 ]
  expect_file_has promoted-unsuppressed "$PLANNING_DIR/STATE.md" "[KNOWN-ISSUE] BetaTests (tests/beta.sh): crash"
  ! grep -qF "TransferTests" "$PLANNING_DIR/STATE.md" || fail_case skipped-suppressed "suppressed issue was promoted"
  [[ "$output" == *"promoted_count=1"* ]] || fail_case promoted-count "expected promoted_count=1"
}

@test "sync commands keep a suppression when the same issue arrives again" {
  local label command times_seen
  while IFS='~' read -r label command times_seen; do
    [ -n "$label" ] || continue
    seed_registry
    bash "$SCRIPT" suppress "$PHASE_DIR" <<< "$(payload_named transfer-via)" >/dev/null
    cat > "$PHASE_DIR/03-VERIFICATION.md" <<'VERIFICATION'
---
result: FAIL
pre_existing_issues:
  - '{"test":"TransferTests","file":"tests/transfer.sh","error":"timeout"}'
---
VERIFICATION

    run bash "$SCRIPT" "$command" "$PHASE_DIR" "$PHASE_DIR/03-VERIFICATION.md"

    expect_status "$label" 0
    [ "$(registry_entry TransferTests .suppressed.via)" = "\"$SUPPRESS_VIA\"" ] || fail_case "$label" "suppression lost, entry=$(registry_entry TransferTests .)"
    [ "$(registry_entry TransferTests .times_seen)" = "$times_seen" ] || fail_case "$label" "expected times_seen $times_seen, entry=$(registry_entry TransferTests .)"
  done <<'CASES'
sync-summaries-keeps-suppressed~sync-summaries~1
sync-verification-fail-keeps-suppressed-and-counts-again~sync-verification~2
CASES
}

@test "usage lists both new subcommands and each one demands a phase directory" {
  local label args expected_status needle
  while IFS='~' read -r label args expected_status needle; do
    [ -n "$label" ] || continue
    run bash "$SCRIPT" $args
    expect_status "$label" "$expected_status"
    [[ "$output" == *"$needle"* ]] || fail_case "$label" "expected '$needle' in output"
  done <<'CASES'
usage-lists-lookup-signature~~1~lookup-signature <phase-dir>
usage-lists-suppress~~1~suppress <phase-dir>
lookup-signature-needs-phase-dir~lookup-signature~1~usage:
suppress-needs-phase-dir~suppress~1~usage:
CASES
}
