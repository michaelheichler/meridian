#!/usr/bin/env bats

load test_helper

setup() {
  setup_temp_dir
  export LBWC_PLANNING_DIR="$TEST_TEMP_DIR/.lbwc-planning"
  mkdir -p "$LBWC_PLANNING_DIR"

  eval "$(bash "$SCRIPTS_DIR/debug-session-state.sh" start "$LBWC_PLANNING_DIR" "write-test")"
  export SESSION_FILE="$session_file"
  PRISTINE_FILE="$TEST_TEMP_DIR/pristine-session.md"
  cp "$SESSION_FILE" "$PRISTINE_FILE"
}

teardown() {
  teardown_temp_dir
}

feed() {
  printf '%s\n' "$1" | bash "$SCRIPTS_DIR/write-debug-session.sh" "$2"
}

fail_case() {
  printf 'case=%s %s\nactual=[%s]\n' "$1" "$2" "$3" >&2
  return 1
}

expect_text() {
  case "$3" in
    *"$2"*) ;;
    *) fail_case "$1" "expected to contain=[$2]" "$3" ;;
  esac
}

expect_file_has() {
  grep -Fq -- "$3" "$2" || fail_case "$1" "file contains=[$3]" "$(cat "$2")"
}

expect_file_line() {
  grep -Fxq -- "$3" "$2" || fail_case "$1" "file has line=[$3]" "$(cat "$2")"
}

expect_all() {
  local label="$1" mode="$2" list="$3" source_text="$4" entry expanded
  expanded="${list//;;/$'\n'}"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$mode" in
      output) expect_text "$label stdout" "$entry" "$source_text" ;;
      substring) expect_file_has "$label" "$source_text" "$entry" ;;
      line) expect_file_line "$label" "$source_text" "$entry" ;;
    esac
  done <<EXPECTED
$expanded
EXPECTED
}

assert_write_cases() {
  local label payload stdout_entries substrings file_lines
  while IFS='~' read -r label payload stdout_entries substrings file_lines; do
    [ -n "$label" ] || continue
    cp "$PRISTINE_FILE" "$SESSION_FILE"
    run feed "$payload" "$SESSION_FILE"
    [ "$status" -eq 0 ] || fail_case "$label" "status=0" "status=$status output=$output"
    expect_all "$label" output "$stdout_entries" "$output"
    expect_all "$label" substring "$substrings" "$SESSION_FILE"
    expect_all "$label" line "$file_lines" "$SESSION_FILE"
    [ ! -e "$SESSION_FILE.tmp" ] || fail_case "$label" "no leftover temp file" "$(ls "$TEST_TEMP_DIR")"
  done
}

@test "source-todo mode writes the fixed top-level Source Todo section" {
  run feed '{"mode":"source-todo","text":"Investigate parser crash","raw_line":"- [HIGH] Investigate parser crash (added 2026-04-01) (ref:abcd1234)","ref":"abcd1234","detail_status":"ok","related_files":["src/parser.sh","tests/parser.bats"],"detail_context":"Parser crash context"}' "$SESSION_FILE"

  [ "$status" -eq 0 ]
  expect_text "stdout" "mode=source-todo" "$output"
  expect_file_line "heading" "$SESSION_FILE" "## Source Todo"
  expect_file_has "text" "$SESSION_FILE" "**Text:** Investigate parser crash"
  expect_file_has "raw line" "$SESSION_FILE" "**Raw Line:** - [HIGH] Investigate parser crash"
  expect_file_has "ref" "$SESSION_FILE" "**Ref:** abcd1234"
  expect_file_has "detail status" "$SESSION_FILE" "**Detail Status:** ok"
  expect_file_has "first related file" "$SESSION_FILE" "src/parser.sh"
  expect_file_has "second related file" "$SESSION_FILE" "tests/parser.bats"
  expect_file_has "detail context" "$SESSION_FILE" "Parser crash context"
}

@test "investigation mode writes the issue, hypotheses, and changed files" {
  assert_write_cases <<'CASES'
hypotheses-and-root-cause~{"mode":"investigation","issue":"Button crashes on click","hypotheses":[{"description":"Null ref","status":"confirmed","evidence_for":"Stack trace","evidence_against":"None","conclusion":"Root cause"}],"root_cause":"Null ref in handler","plan":"Add guard","changed_files":["src/button.sh"],"commit":"abc123"}~mode=investigation~Button crashes on click;;Null ref;;Root cause;;Null ref in handler;;Add guard;;src/button.sh;;abc123~
sed-metacharacters-in-issue~{"mode":"investigation","issue":"Fix crash in src/lib/parser.sh & helpers","hypotheses":[],"root_cause":"test","plan":"test","changed_files":[],"commit":"abc"}~mode=investigation~Fix crash in src/lib/parser.sh & helpers~
CASES
}

@test "investigation mode leaves the QA and UAT result fields alone" {
  feed '{"mode":"qa","round":2,"result":"PASS","checks":[{"id":"C1","description":"Existing QA","status":"PASS","evidence":"ok"}]}' "$SESSION_FILE" > /dev/null
  feed '{"mode":"uat","round":1,"result":"issues_found","checkpoints":[{"description":"Existing UAT","result":"issue","user_response":"still broken"}],"issues":[{"description":"Known issue","severity":"major"}]}' "$SESSION_FILE" > /dev/null

  run feed '{"mode":"investigation","issue":"Fresh investigation","hypotheses":[],"root_cause":"New root cause","plan":"New plan","changed_files":["src/new.sh"],"commit":"def456"}' "$SESSION_FILE"

  [ "$status" -eq 0 ]
  expect_file_line "qa_round" "$SESSION_FILE" "qa_round: 2"
  expect_file_line "qa_last_result" "$SESSION_FILE" "qa_last_result: pass"
  expect_file_line "uat_round" "$SESSION_FILE" "uat_round: 1"
  expect_file_line "uat_last_result" "$SESSION_FILE" "uat_last_result: issues_found"
}

@test "investigation mode archives the previous round after a QA round" {
  feed '{"mode":"investigation","issue":"Bug report","hypotheses":[],"root_cause":"Original cause","plan":"Original plan","changed_files":["src/a.sh"],"commit":"abc123"}' "$SESSION_FILE" > /dev/null
  feed '{"mode":"qa","round":1,"result":"FAIL","checks":[{"id":"c1","description":"test","status":"fail","evidence":"broken"}],"summary":"Failed."}' "$SESSION_FILE" > /dev/null

  run feed '{"mode":"investigation","issue":"Bug report v2","hypotheses":[],"root_cause":"New cause","plan":"New plan","changed_files":["src/b.sh"],"commit":"def456"}' "$SESSION_FILE"

  [ "$status" -eq 0 ]
  expect_file_has "new root cause" "$SESSION_FILE" "New cause"
  expect_file_has "new plan" "$SESSION_FILE" "New plan"
  expect_file_has "new changed file" "$SESSION_FILE" "src/b.sh"
  expect_file_line "history heading" "$SESSION_FILE" "## Remediation History"
  expect_file_has "round heading" "$SESSION_FILE" "### Round 1"
  expect_file_has "archived cause" "$SESSION_FILE" "Original cause"
  expect_file_has "archived plan" "$SESSION_FILE" "Original plan"
}

@test "qa mode records the round, the checks, and the frontmatter result" {
  assert_write_cases <<'CASES'
checks-as-array-of-objects~{"mode":"qa","round":1,"result":"PARTIAL","checks":[{"id":"C1","description":"Exit code","status":"PASS","evidence":"exits 0"},{"id":"C2","description":"Output format","status":"FAIL","evidence":"missing header"}]}~mode=qa;;round=1;;result=PARTIAL~1/2 passed;;1 failed;;| C1: Exit code | PASS | exits 0 |;;| C2: Output format | FAIL | missing header |~qa_round: 1;;qa_last_result: fail
checks-as-legacy-summary-object~{"mode":"qa","round":1,"result":"PASS","checks":{"passed":3,"failed":0,"total":3}}~mode=qa~3/3 passed~qa_round: 1;;qa_last_result: pass
empty-checks-array~{"mode":"qa","round":2,"result":"FAIL","checks":[]}~mode=qa~0/0 passed~qa_round: 2;;qa_last_result: fail
no-check-data~{"mode":"qa","round":1,"result":"PASS"}~mode=qa~No check data provided~qa_last_result: pass
CASES
}

@test "uat mode records checkpoints, responses, and issues" {
  assert_write_cases <<'CASES'
issues-as-objects-with-severity~{"mode":"uat","round":1,"result":"issues_found","checkpoints":[{"description":"Basic flow","result":"pass"}],"issues":[{"description":"Button misaligned","severity":"minor"},{"description":"Crash on empty input","severity":"major"}]}~mode=uat;;round=1;;result=issues_found~[x] Basic flow;;[minor] Button misaligned;;[major] Crash on empty input~uat_round: 1;;uat_last_result: issues_found
issues-as-plain-strings~{"mode":"uat","round":1,"result":"issues_found","issues":["Simple string issue"]}~mode=uat~- Simple string issue~uat_last_result: issues_found
skipped-and-passed-checkpoints-with-responses~{"mode":"uat","round":1,"result":"pass","checkpoints":[{"description":"Skipped check","result":"skip","user_response":"Not applicable to this flow"},{"description":"Passed check","result":"pass","user_response":"Looks good"}]}~mode=uat~[-] Skipped check (**SKIPPED**);;[x] Passed check;;> Not applicable to this flow;;> Looks good~uat_last_result: pass
issue-checkpoint~{"mode":"uat","round":1,"result":"issues_found","checkpoints":[{"description":"Broken flow","result":"issue","user_response":"Crashes on click"}]}~mode=uat~Broken flow (**ISSUE**);;> Crashes on click~
CASES
}

@test "status mode updates the frontmatter status" {
  run feed '{"mode":"status","status":"qa_pending"}' "$SESSION_FILE"

  [ "$status" -eq 0 ]
  expect_text "stdout" "status=qa_pending" "$output"
  expect_file_line "status" "$SESSION_FILE" "status: qa_pending"
}

@test "invalid requests are rejected with a reason and leave the session file untouched" {
  local label target payload fragments before request_target
  ln -s "$SESSION_FILE" "$TEST_TEMP_DIR/link.md"
  while IFS='~' read -r label target payload fragments; do
    [ -n "$label" ] || continue
    cp "$PRISTINE_FILE" "$SESSION_FILE"
    case "$target" in
      MISSING) request_target="/nonexistent/file.md" ;;
      SYMLINK) request_target="$TEST_TEMP_DIR/link.md" ;;
      *) request_target="$SESSION_FILE" ;;
    esac
    before=$(cksum < "$SESSION_FILE")

    run feed "$payload" "$request_target"

    [ "$status" -eq 1 ] || fail_case "$label" "status=1" "status=$status output=$output"
    expect_all "$label" output "$fragments" "$output"
    [ "$(cksum < "$SESSION_FILE")" = "$before" ] || fail_case "$label" "session file unchanged" "$(cat "$SESSION_FILE")"
  done <<'CASES'
invalid-json~SESSION~not json~invalid JSON
missing-mode~SESSION~{"status":"qa_pending"}~missing required field 'mode'
source-todo-underscore-alias~SESSION~{"mode":"source_todo","text":"Investigate parser crash"}~unknown mode 'source_todo';;Valid: source-todo, investigation, qa, uat, status
missing-session-file~MISSING~{"mode":"status","status":"investigating"}~not found
symlinked-session-file~SYMLINK~{"mode":"status","status":"investigating"}~symlink
investigation-without-issue~SESSION~{"mode":"investigation"}~requires 'issue'
qa-invalid-result~SESSION~{"mode":"qa","round":1,"result":"INVALID"}~must be PASS, FAIL, or PARTIAL
qa-without-round~SESSION~{"mode":"qa","result":"PASS"}~requires 'round' and 'result'
uat-invalid-result~SESSION~{"mode":"uat","round":1,"result":"bad"}~must be pass or issues_found
uat-without-result~SESSION~{"mode":"uat","round":1}~requires 'round' and 'result'
status-invalid-value~SESSION~{"mode":"status","status":"invalid_status"}~invalid status
status-without-value~SESSION~{"mode":"status"}~requires 'status'
CASES
}
