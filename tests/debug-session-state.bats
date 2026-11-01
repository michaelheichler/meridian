#!/usr/bin/env bats

load test_helper

SKIPPED="skipped_no_fix_required"

setup() {
  setup_temp_dir
  export LBWC_PLANNING_DIR="$TEST_TEMP_DIR/.lbwc-planning"
  DBG="$LBWC_PLANNING_DIR/debugging"
  mkdir -p "$LBWC_PLANNING_DIR"
}

teardown() {
  teardown_temp_dir
}

dss() {
  bash "$SCRIPTS_DIR/debug-session-state.sh" "$1" "$LBWC_PLANNING_DIR" "${@:2}"
}

run_piped() {
  local payload="$1"
  shift
  run bash -c 'printf %s "$1" | bash "$2" "${@:3}"' -- "$payload" "$SCRIPTS_DIR/debug-session-state.sh" "$@"
}

run_capturing_stderr() {
  STDERR_FILE="$TEST_TEMP_DIR/stderr.tmp"
  run bash -c 'bash "$1" "$2" "$3" 2>"$4"' -- "$SCRIPTS_DIR/debug-session-state.sh" "$1" "$LBWC_PLANNING_DIR" "$STDERR_FILE"
}

reset_planning() {
  rm -rf "$LBWC_PLANNING_DIR"
  mkdir -p "$LBWC_PLANNING_DIR"
}

start_session() {
  eval "$(dss start "$1")"
}

make_session() {
  local loc="$1" id="$2" state="$3" qa_round="${4:-0}" qa_result="${5:-pending}" uat_round="${6:-0}" uat_result="${7:-pending}"
  local dir="$DBG/$loc"
  [ "$loc" != legacy ] || dir="$DBG"
  mkdir -p "$dir"
  printf '%s\n' '---' "session_id: $id" "title: ${id:16}" "status: $state" \
    'created: 2024-01-01 12:00:00' 'updated: 2024-01-01 12:00:00' \
    "qa_round: $qa_round" "qa_last_result: $qa_result" \
    "uat_round: $uat_round" "uat_last_result: $uat_result" \
    '---' '' "# Debug Session: ${id:16}" > "$dir/$id.md"
}

build_specs() {
  local spec loc id state verified
  for spec in $1; do
    IFS=: read -r loc id state verified <<< "$spec"
    case "$loc" in
      emptydir) mkdir -p "$DBG" ;;
      symlink) mkdir -p "$DBG/active" && ln -s /dev/null "$DBG/active/$id.md" ;;
      *)
        if [ "$verified" = v ]; then
          make_session "$loc" "$id" "$state" 1 pass 1 pass
        else
          make_session "$loc" "$id" "$state"
        fi
        ;;
    esac
  done
}

point_to() {
  mkdir -p "$DBG"
  echo "$1" > "$DBG/.active-session"
}

drop_pointer_if() {
  [ "$1" != yes ] || rm -f "$DBG/.active-session"
}

point_if() {
  [ "$1" != yes ] || point_to "$2"
}

point_unless_dash() {
  [ "$1" = - ] || point_to "$1"
}

fail_case() {
  echo "case=$1 $2" >&2
  echo "output=$output" >&2
  return 1
}

expect_status() {
  [ "$status" -eq "$2" ] || fail_case "$1" "expected status $2 got $status"
}

expect_out() {
  [[ "$output" == *"$2"* ]] || fail_case "$1" "expected output to contain: $2"
}

expect_line() {
  printf '%s\n' "$output" | grep -qxF -- "$2" || fail_case "$1" "expected output line: $2"
}

expect_no_line_prefix() {
  [[ $'\n'"$output" != *$'\n'"$2"* ]] || fail_case "$1" "unexpected output line starting with: $2"
}

expect_file() {
  [ -f "$2" ] || fail_case "$1" "expected file: $2"
}

expect_no_file() {
  [ ! -e "$2" ] || fail_case "$1" "unexpected file: $2"
}

expect_frontmatter() {
  grep -qxF -- "$3" "$2" || fail_case "$1" "expected line '$3' in $2, found: $(grep ':' "$2" | head -12 | tr '\n' ' ')"
}

expect_no_frontmatter() {
  local found
  found=$(grep -cxF -- "$3" "$2" || true)
  [ "$found" -eq 0 ] || fail_case "$1" "unexpected line '$3' in $2"
}

expect_file_grep() {
  grep -q -- "$3" "$2" || fail_case "$1" "expected pattern '$3' in $2"
}

expect_presence() {
  case "$2" in
    yes) expect_file "$1" "$3" ;;
    *) expect_no_file "$1" "$3" ;;
  esac
}

expect_files() {
  local label="$1" listed="$2" path
  for path in ${listed//,/ }; do
    expect_file "$label" "$DBG/$path"
  done
}

expect_list_count() {
  local lines
  lines=$(printf '%s\n' "$output" | grep -c '^session=' || true)
  [ "$lines" -eq "$2" ] || fail_case "$1" "expected $2 session lines got $lines"
  case "$3" in
    -) ;;
    *) expect_line "$1" "session_count=$3" ;;
  esac
}

expect_fragments() {
  local label="$1" listed="$2" fragment
  for fragment in ${listed//,/ }; do
    expect_out "$label" "$fragment"
  done
}

expect_warning() {
  local warned=0
  grep -q 'Warning: could not migrate legacy session' "$STDERR_FILE" && warned=1
  case "$2" in
    yes) [ "$warned" -eq 1 ] || fail_case "$1" "expected stderr warning, stderr=$(cat "$STDERR_FILE")" ;;
    *) [ "$warned" -eq 0 ] || fail_case "$1" "unexpected stderr warning: $(cat "$STDERR_FILE")" ;;
  esac
}

expect_selection() {
  case "$2" in
    -)
      expect_no_file "$1" "$DBG/.active-session"
      ;;
    *)
      expect_line "$1" "session_id=$2"
      expect_file "$1" "$DBG/active/$2.md"
      expect_no_file "$1" "$DBG/completed/$2.md"
      [ "$(cat "$DBG/.active-session")" = "$2.md" ] || fail_case "$1" "pointer is '$(cat "$DBG/.active-session")' not $2.md"
      ;;
  esac
}

@test "start creates the session file, pointer and frontmatter, sanitizes the slug, and clear-active keeps the file" {
  local long60 long50 label input expected

  run dss start test-bug
  expect_status start 0
  expect_out start "session_id="
  expect_out start "session_file="
  expect_file start-pointer "$DBG/.active-session"
  eval "$output"
  expect_file start-session-file "$session_file"
  [[ "$session_file" == *"/debugging/active/"* ]] || fail_case start-session-file "not under active: $session_file"
  [ "$(cat "$DBG/.active-session")" = "$(basename "$session_file")" ] || fail_case start-pointer "pointer does not name $session_file"
  expect_file_grep start-frontmatter "$session_file" '^status: investigating$'
  expect_file_grep start-frontmatter "$session_file" '^qa_round: 0$'
  expect_file_grep start-frontmatter "$session_file" '^uat_round: 0$'

  run dss clear-active
  expect_status clear-active 0
  expect_no_file clear-active-pointer "$DBG/.active-session"
  expect_file clear-active-keeps-session "$session_file"

  long60=$(printf 'a%.0s' $(seq 1 60))
  long50=$(printf 'a%.0s' $(seq 1 50))
  while IFS='|' read -r label input expected; do
    [ -n "$label" ] || continue
    reset_planning
    run dss start "$input"
    expect_status "$label" 0
    eval "$output"
    [[ "${session_id:0:16}" =~ ^[0-9]{8}-[0-9]{6}-$ ]] || fail_case "$label" "bad timestamp prefix in $session_id"
    [ "${session_id:16}" = "$expected" ] || fail_case "$label" "expected slug '$expected' got '${session_id:16}'"
  done <<CASES
mixed-case-and-symbols|My Bug Has Spaces & Symbols!|my-bug-has-spaces-symbols
repeated-and-edge-separators|--Foo__Bar--|foo-bar
nothing-left-falls-back|!!!|debug
truncated-to-fifty|$long60|$long50
CASES
}

@test "commands reject missing arguments, bad session names, a missing active session, unknown commands and invalid statuses" {
  local label command usage name reason argument

  while IFS='|' read -r label command usage; do
    [ -n "$label" ] || continue
    reset_planning
    run dss "$command"
    expect_status "$label" 1
    expect_out "$label" "Usage: debug-session-state.sh $usage"
  done <<'CASES'
start|start|start <planning-dir> <slug>
start-with-source-todo|start-with-source-todo|start-with-source-todo <planning-dir> <slug>
start-with-selected-todo|start-with-selected-todo|start-with-selected-todo <planning-dir> <slug> <detail-status>
resume|resume|resume <planning-dir> <session-id>
set-status|set-status|set-status <planning-dir> <status>
CASES

  while IFS='|' read -r label name reason; do
    [ -n "$label" ] || continue
    reset_planning
    run dss resume "$name"
    expect_status "$label" 1
    expect_out "$label" "$reason"
  done <<'CASES'
path-traversal|../etc/passwd|path traversal
missing-timestamp-prefix|nonexistent|YYYYMMDD-HHMMSS-slug
wrong-extension|20990101-000000-foo.txt|must be .md
unknown-session|20990101-000000-no-such-session.md|not found
CASES

  while IFS='|' read -r label command argument; do
    [ -n "$label" ] || continue
    reset_planning
    run dss "$command" $argument
    expect_status "$label" 1
    expect_out "$label" "no active"
  done <<'CASES'
no-active-set-status|set-status|qa_pending
no-active-increment-qa|increment-qa|
no-active-increment-uat|increment-uat|
CASES

  run dss bogus
  expect_status unknown-command 1
  expect_out unknown-command "unknown command"

  reset_planning
  start_session invalid-test
  run dss set-status bogus
  expect_status invalid-status 1
  expect_out invalid-status "invalid status"
  expect_file_grep invalid-status-unchanged "$session_file" '^status: investigating$'
}

@test "start-with-source-todo and start-with-selected-todo write Source Todo and roll back on writer failure" {
  local first_session_name

  run_piped '{"mode":"source-todo","text":"Investigate parser crash","raw_line":"- Investigate parser crash (ref:abcd1234)","ref":"abcd1234","detail_status":"ok","related_files":["src/parser.sh"],"detail_context":"Persisted detail"}' \
    start-with-source-todo "$LBWC_PLANNING_DIR" "source-todo-success"
  expect_status source-todo-success 0
  eval "$output"
  expect_file source-todo-success "$session_file"
  expect_file source-todo-success-pointer "$DBG/.active-session"
  expect_file_grep source-todo-success "$session_file" '^## Source Todo$'
  expect_file_grep source-todo-success "$session_file" 'Investigate parser crash'
  expect_file_grep source-todo-success "$session_file" 'Persisted detail'

  reset_planning
  run_piped 'not-json' start-with-source-todo "$LBWC_PLANNING_DIR" "source-todo-failure"
  expect_status source-todo-rollback 1
  expect_no_file source-todo-rollback-pointer "$DBG/.active-session"
  run find "$DBG/active" -maxdepth 1 -type f -name '*.md'
  expect_status source-todo-rollback-files 0
  [ -z "$output" ] || fail_case source-todo-rollback-files "session files remained"

  reset_planning
  start_session first-bug
  first_session_name=$(basename "$session_file")
  run_piped 'not-json' start-with-source-todo "$LBWC_PLANNING_DIR" "source-todo-failure"
  expect_status source-todo-restores-pointer 1
  expect_file source-todo-restores-pointer "$DBG/.active-session"
  [ "$(cat "$DBG/.active-session")" = "$first_session_name" ] || fail_case source-todo-restores-pointer "pointer is $(cat "$DBG/.active-session")"
  expect_file source-todo-restores-pointer "$DBG/active/$first_session_name"

  reset_planning
  run_piped '{"command_text":"Investigate parser crash","normalized_text":"Investigate parser crash","line":"- [HIGH] Investigate parser crash (added 2026-04-01) (ref:abcd1234)","ref":"abcd1234"}' \
    start-with-selected-todo "$LBWC_PLANNING_DIR" "selected-todo-no-detail" none
  expect_status selected-no-detail 0
  eval "$output"
  expect_file selected-no-detail "$session_file"
  expect_file_grep selected-no-detail "$session_file" '\*\*Text:\*\* Investigate parser crash'
  expect_file_grep selected-no-detail "$session_file" '\*\*Raw Line:\*\* - \[HIGH\] Investigate parser crash'
  expect_file_grep selected-no-detail "$session_file" '\*\*Ref:\*\* abcd1234'
  expect_file_grep selected-no-detail "$session_file" '\*\*Detail Status:\*\* none'
  expect_file_grep selected-no-detail "$session_file" 'None recorded\.'
  expect_file_grep selected-no-detail "$session_file" 'No persisted detail context\.'

  reset_planning
  export TODO_DETAIL_RESULT_JSON='{"status":"ok","detail":{"context":"Persisted detail context","files":["src/parser.sh","tests/parser.bats"]}}'
  run_piped '{"command_text":"Investigate parser crash","line":"- Investigate parser crash (ref:abcd1234)","ref":"abcd1234"}' \
    start-with-selected-todo "$LBWC_PLANNING_DIR" "selected-todo-with-detail" ok
  unset TODO_DETAIL_RESULT_JSON
  expect_status selected-with-detail 0
  eval "$output"
  expect_file selected-with-detail "$session_file"
  expect_file_grep selected-with-detail "$session_file" '\*\*Text:\*\* Investigate parser crash'
  expect_file_grep selected-with-detail "$session_file" '\*\*Detail Status:\*\* ok'
  expect_file_grep selected-with-detail "$session_file" 'src/parser.sh'
  expect_file_grep selected-with-detail "$session_file" 'tests/parser.bats'
  expect_file_grep selected-with-detail "$session_file" 'Persisted detail context'
}

@test "get, get-or-latest and resume print session_status metadata and get-or-latest selects the latest unresolved session" {
  local label command expected_active drop_pointer sid pointer specs expected_id

  while IFS='|' read -r label command; do
    [ -n "$label" ] || continue
    reset_planning
    run dss "$command"
    expect_status "$label" 0
    expect_line "$label" "active_session=none"
  done <<'CASES'
nothing-active-get|get
nothing-active-get-or-latest|get-or-latest
CASES

  while IFS='|' read -r label command expected_active drop_pointer; do
    [ -n "$label" ] || continue
    reset_planning
    start_session meta-case
    drop_pointer_if "$drop_pointer"
    run dss "$command" "$session_id"
    expect_status "$label" 0
    expect_line "$label" "active_session=$expected_active"
    expect_line "$label" "session_status=investigating"
    expect_no_line_prefix "$label" "status="
    expect_line "$label" "qa_round=0"
  done <<'CASES'
get-active-pointer|get|true|no
get-or-latest-fallback|get-or-latest|fallback|yes
resume|resume|true|yes
CASES

  while IFS='|' read -r label command expected_active; do
    [ -n "$label" ] || continue
    reset_planning
    start_session readonly-case
    sid="$session_id"
    rm -f "$DBG/.active-session"
    run bash -c '
      readonly status=0
      helper_output=$(bash "$1" "$2" "$3" "$4")
      eval "$helper_output"
      printf "active_session=%s\nsession_status=%s\nsession_id=%s\nsession_file=%s\n" \
        "${active_session:-}" "${session_status:-}" "${session_id:-}" "${session_file:-}"
    ' -- "$SCRIPTS_DIR/debug-session-state.sh" "$command" "$LBWC_PLANNING_DIR" "$sid"
    expect_status "$label" 0
    expect_line "$label" "active_session=$expected_active"
    expect_line "$label" "session_status=investigating"
    expect_line "$label" "session_id=$sid"
    expect_out "$label" "session_file=$DBG/active/"
  done <<'CASES'
readonly-status-get-or-latest|get-or-latest|fallback
readonly-status-resume|resume|true
CASES

  while IFS='|' read -r label pointer specs expected_active expected_id; do
    [ -n "$label" ] || continue
    reset_planning
    build_specs "$specs"
    point_unless_dash "$pointer"
    run dss get-or-latest
    expect_status "$label" 0
    expect_line "$label" "active_session=$expected_active"
    expect_selection "$label" "$expected_id"
  done <<'CASES'
single-unresolved|-|active:20240101-120000-solo:investigating|fallback|20240101-120000-solo
latest-of-two-unresolved|-|active:20240101-120000-early:qa_pending active:20240201-120000-late:investigating|fallback|20240201-120000-late
newer-completed-session-skipped|-|active:20240101-120000-open:investigating completed:20240201-120000-done:complete|fallback|20240101-120000-open
newer-complete-stranded-in-active-skipped|-|active:20240101-120000-open:investigating active:20240201-120000-done:complete|fallback|20240101-120000-open
pointer-to-complete-in-active-falls-back|20240101-120000-early.md|active:20240101-120000-early:complete active:20240201-120000-late:investigating|fallback|20240201-120000-late
unresolved-stranded-in-completed|-|completed:20240101-120000-stranded:uat_pending|fallback|20240101-120000-stranded
pointer-to-unresolved-stranded-in-completed|20240101-120000-stranded.md|completed:20240101-120000-stranded:qa_failed|true|20240101-120000-stranded
only-completed-sessions|-|completed:20240101-120000-done:complete|none|-
CASES
}

@test "resume reconciles the session location and only re-activates unresolved sessions" {
  local id="20240101-120000-resumed"
  while IFS='|' read -r label loc state pointer expected_status expected_dir absent_dir expected_get; do
    [ -n "$label" ] || continue
    reset_planning
    make_session "$loc" "$id" "$state"
    point_if "$pointer" "$id.md"
    run dss resume "$id.md"
    expect_status "$label" 0
    expect_line "$label" "active_session=true"
    expect_line "$label" "session_status=$expected_status"
    expect_file "$label" "$DBG/$expected_dir/$id.md"
    expect_no_file "$label" "$DBG/$absent_dir/$id.md"
    expect_no_file "$label" "$DBG/$id.md"
    run dss get
    expect_line "$label" "active_session=$expected_get"
  done <<'CASES'
completed-stays-completed|completed|complete|no|complete|completed|active|none
legacy-complete-migrates-to-completed|legacy|complete|no|complete|completed|active|none
complete-stranded-in-active-moves-to-completed|active|complete|yes|complete|completed|active|none
unresolved-stranded-in-completed-moves-to-active|completed|qa_failed|no|qa_failed|active|completed|true
unresolved-in-active-becomes-active|active|investigating|no|investigating|active|completed|true
CASES
}

@test "set-status writes statuses and completes sessions, and increment bumps only its own round and result" {
  local id="20240101-120000-status-case" complete_id="20240101-120000-complete-case" bump_id="20240101-120000-bump-case"
  local target label qa_round qa_result uat_round uat_result expected_qa expected_uat kind other

  for target in fix_applied qa_pending qa_failed uat_pending uat_failed; do
    reset_planning
    make_session active "$id" investigating
    point_to "$id.md"
    run dss set-status "$target"
    expect_status "$target" 0
    expect_line "$target" "status=$target"
    expect_frontmatter "$target" "$DBG/active/$id.md" "status: $target"
    expect_no_frontmatter "$target" "$DBG/active/$id.md" 'updated: 2024-01-01 12:00:00'
  done

  while IFS='|' read -r label qa_round qa_result uat_round uat_result expected_qa expected_uat; do
    [ -n "$label" ] || continue
    reset_planning
    make_session active "$complete_id" investigating "$qa_round" "$qa_result" "$uat_round" "$uat_result"
    point_to "$complete_id.md"
    run dss set-status complete
    expect_status "$label" 0
    expect_line "$label" "status=complete"
    expect_no_file "$label" "$DBG/active/$complete_id.md"
    expect_no_file "$label" "$DBG/.active-session"
    expect_frontmatter "$label" "$DBG/completed/$complete_id.md" "status: complete"
    expect_frontmatter "$label" "$DBG/completed/$complete_id.md" "qa_round: $qa_round"
    expect_frontmatter "$label" "$DBG/completed/$complete_id.md" "uat_round: $uat_round"
    expect_frontmatter "$label" "$DBG/completed/$complete_id.md" "qa_last_result: ${expected_qa//SKIPPED/$SKIPPED}"
    expect_frontmatter "$label" "$DBG/completed/$complete_id.md" "uat_last_result: ${expected_uat//SKIPPED/$SKIPPED}"
  done <<'CASES'
no-verification|0|pending|0|pending|SKIPPED|SKIPPED
fully-verified|1|pass|1|pass|pass|pass
qa-only-verified|1|pass|0|pending|pass|pending
CASES

  while IFS='|' read -r kind other; do
    [ -n "$kind" ] || continue
    reset_planning
    make_session active "$bump_id" investigating 0 pass 0 pass
    point_to "$bump_id.md"
    run dss "increment-$kind"
    expect_status "$kind-first" 0
    expect_line "$kind-first" "${kind}_round=1"
    run dss "increment-$kind"
    expect_status "$kind-second" 0
    expect_line "$kind-second" "${kind}_round=2"
    expect_frontmatter "$kind" "$DBG/active/$bump_id.md" "${kind}_round: 2"
    expect_frontmatter "$kind" "$DBG/active/$bump_id.md" "${kind}_last_result: pending"
    expect_frontmatter "$kind" "$DBG/active/$bump_id.md" "${other}_last_result: pass"
    expect_frontmatter "$kind" "$DBG/active/$bump_id.md" "${other}_round: 0"
  done <<'CASES'
qa|uat
uat|qa
CASES
}

@test "legacy sessions migrate with collisions resolved or reported, and completed sessions normalize through every entry command" {
  local id="20250101-120000-legacy-case" norm_id="20240101-120000-norm-case"
  local label entry pointer specs expected_out warn legacy_remains expected_files expected_round expected_qa expected_uat

  while IFS='|' read -r label entry pointer specs expected_out warn legacy_remains expected_files; do
    [ -n "$label" ] || continue
    reset_planning
    build_specs "${specs//@/$id}"
    point_if "$pointer" "$id.md"
    run_capturing_stderr "$entry"
    expect_status "$label" 0
    expected_out="${expected_out//@/$id}"
    expect_out "$label" "${expected_out//PIPE/|}"
    expect_warning "$label" "$warn"
    expect_presence "$label" "$legacy_remains" "$DBG/$id.md"
    expect_files "$label" "${expected_files//@/$id}"
  done <<'CASES'
pointer-to-legacy|get-or-latest|yes|legacy:@:investigating|active_session=true|no|no|active/@.md
fallback-collision-with-complete-file|get-or-latest|no|legacy:@:investigating active:@:complete|session_id=@|no|no|active/@.md,completed/@.md
fallback-collision-with-symlink|get-or-latest|no|legacy:@:investigating symlink:@|session_id=@|yes|yes|
list-collision-with-unresolved-file|list|no|legacy:@:investigating active:@:investigating|session_count=2|yes|yes|
list-legacy-complete|list|no|legacy:@:complete|PIPEcompleted|no|no|completed/@.md
CASES

  while IFS='|' read -r label entry pointer specs expected_out expected_round expected_qa expected_uat; do
    [ -n "$label" ] || continue
    reset_planning
    build_specs "${specs//@/$norm_id}"
    point_if "$pointer" "$norm_id.md"
    run dss "$entry" "$norm_id.md"
    expect_status "$label" 0
    expect_out "$label" "${expected_out//PIPE/|}"
    expect_file "$label" "$DBG/completed/$norm_id.md"
    expect_no_file "$label" "$DBG/active/$norm_id.md"
    expect_no_file "$label" "$DBG/$norm_id.md"
    expect_no_file "$label" "$DBG/.active-session"
    expect_frontmatter "$label" "$DBG/completed/$norm_id.md" "qa_round: $expected_round"
    expect_frontmatter "$label" "$DBG/completed/$norm_id.md" "uat_round: $expected_round"
    expect_frontmatter "$label" "$DBG/completed/$norm_id.md" "qa_last_result: ${expected_qa//SKIPPED/$SKIPPED}"
    expect_frontmatter "$label" "$DBG/completed/$norm_id.md" "uat_last_result: ${expected_uat//SKIPPED/$SKIPPED}"
  done <<'CASES'
canonical-unverified-via-get-or-latest|get-or-latest|no|completed:@:complete|active_session=none|0|SKIPPED|SKIPPED
canonical-verified-via-get-or-latest|get-or-latest|no|completed:@:complete:v|active_session=none|1|pass|pass
stale-pointer-to-completed-via-get|get|yes|completed:@:complete:v|active_session=none|1|pass|pass
legacy-unverified-via-get|get|yes|legacy:@:complete|active_session=none|0|SKIPPED|SKIPPED
legacy-verified-via-list|list|no|legacy:@:complete:v|PIPEcompleted|1|pass|pass
stranded-in-active-via-get|get|yes|active:@:complete|active_session=none|0|SKIPPED|SKIPPED
stranded-in-active-via-list|list|no|active:@:complete|PIPEcompleted|0|SKIPPED|SKIPPED
stranded-in-active-via-resume|resume|yes|active:@:complete|session_status=complete|0|SKIPPED|SKIPPED
CASES
}

@test "list reports each session once with its status and reconciled location" {
  while IFS=';' read -r label specs expected_count fragments expected_files; do
    [ -n "$label" ] || continue
    reset_planning
    build_specs "$specs"
    run dss list
    expect_status "$label" 0
    expect_list_count "$label" "${expected_count%%/*}" "${expected_count##*/}"
    expect_fragments "$label" "$fragments"
    expect_files "$label" "$expected_files"
  done <<'CASES'
no-debugging-directory;;0/-;no_sessions=true;
empty-debugging-directory;emptydir:x:x;0/0;no_sessions=true,session_count=0;
one-active;active:20240101-120000-a:investigating;1/1;session=20240101-120000-a|investigating|a|active;active/20240101-120000-a.md
active-and-completed;active:20240101-120000-a:qa_pending completed:20240201-120000-b:complete;2/2;session=20240101-120000-a|qa_pending|a|active,session=20240201-120000-b|complete|b|completed;active/20240101-120000-a.md,completed/20240201-120000-b.md
unresolved-stranded-in-completed-heals-to-active;completed:20240101-120000-s:investigating;1/1;session=20240101-120000-s|investigating|s|active;active/20240101-120000-s.md
complete-stranded-in-active-is-counted-once;active:20240101-120000-h:complete completed:20240201-120000-d:complete;2/2;session=20240101-120000-h|complete|h|completed,session=20240201-120000-d|complete|d|completed;completed/20240101-120000-h.md,completed/20240201-120000-d.md
CASES
}
