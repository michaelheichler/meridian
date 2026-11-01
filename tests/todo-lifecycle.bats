#!/usr/bin/env bats

load test_helper
load todo_helper

snapshot_path_for_session_id() {
  local raw_session_id="${1:-${CLAUDE_SESSION_ID:-default}}"
  local session_key

  session_key=$(printf '%s' "$raw_session_id" | tr -c 'A-Za-z0-9_.-' '_')
  session_key="${session_key:-default}"
  printf '/tmp/.lbwc-last-list-view-%s.json\n' "$session_key"
}

fixed_todo_now_epoch() {
  date -j -f "%Y-%m-%d %H:%M:%S" "2026-04-23 12:00:00" +%s 2>/dev/null || \
    date -d "2026-04-23 12:00:00" +%s 2>/dev/null
}

unique_session_id() {
  printf 'todo-lifecycle-%s-%s-%s-%s' "$1" "${BATS_TEST_NUMBER:-0}" "$$" "$RANDOM"
}

setup() {
  local fixed_now_epoch

  setup_temp_dir
  create_test_config
  if [ "${LBWC_TODO_NOW_EPOCH+x}" = "x" ]; then
    export _ORIG_LBWC_TODO_NOW_EPOCH_WAS_SET=1
    export _ORIG_LBWC_TODO_NOW_EPOCH="$LBWC_TODO_NOW_EPOCH"
  else
    export _ORIG_LBWC_TODO_NOW_EPOCH_WAS_SET=0
    unset _ORIG_LBWC_TODO_NOW_EPOCH 2>/dev/null || true
  fi
  if ! fixed_now_epoch=$(fixed_todo_now_epoch) || [ -z "$fixed_now_epoch" ] || ! [[ "$fixed_now_epoch" =~ ^[0-9]+$ ]]; then
    echo "todo-lifecycle.bats setup: could not derive fixed epoch for deterministic age assertions" >&2
    return 1
  fi
  export LBWC_TODO_NOW_EPOCH="$fixed_now_epoch"
  export CLAUDE_SESSION_ID="$(unique_session_id main)"
  export LBWC_PLANNING_DIR="$TEST_TEMP_DIR/.lbwc-planning"
  SCRIPT="$SCRIPTS_DIR/todo-lifecycle.sh"
  LIST_SCRIPT="$SCRIPTS_DIR/list-todos.sh"
  RESOLVE_SCRIPT="$SCRIPTS_DIR/resolve-todo-item.sh"
  DETAILS_SCRIPT="$SCRIPTS_DIR/todo-details.sh"
  STATE_FILE="$LBWC_PLANNING_DIR/STATE.md"
  export TEST_SNAPSHOT_PATH="$(snapshot_path_for_session_id "$CLAUDE_SESSION_ID")"
  export EXTRA_SNAPSHOT_PATHS=""
  rm -f "$TEST_SNAPSHOT_PATH"
  mkdir -p "$LBWC_PLANNING_DIR/phases/03-test-phase"
}

teardown() {
  rm -f "$TEST_SNAPSHOT_PATH" "$(snapshot_path_for_session_id)" ${EXTRA_SNAPSHOT_PATHS:-} 2>/dev/null || true
  if [ "${_ORIG_LBWC_TODO_NOW_EPOCH_WAS_SET:-0}" = "1" ]; then
    export LBWC_TODO_NOW_EPOCH="${_ORIG_LBWC_TODO_NOW_EPOCH-}"
  else
    unset LBWC_TODO_NOW_EPOCH 2>/dev/null || true
  fi
  unset EXTRA_SNAPSHOT_PATHS TEST_SNAPSHOT_PATH _ORIG_LBWC_TODO_NOW_EPOCH _ORIG_LBWC_TODO_NOW_EPOCH_WAS_SET
  teardown_temp_dir
}

write_state_body() {
  printf '%s\n\n' '# Project State' > "$STATE_FILE"
  cat >> "$STATE_FILE"
}

write_state_recent_activity() {
  write_state_body <<'EOF'
## Todos
- Fix parser bug (added 2026-04-01)
- [HIGH] Refactor auth module (added 2026-04-02)
- [low] Update docs (added 2026-04-03)

## Recent Activity
- 2026-04-01: Existing note
EOF
}

write_state_without_activity() {
  write_state_body <<'EOF'
## Todos
- Only todo item (added 2026-04-01)

## Blockers
None.
EOF
}

write_state_no_todos() {
  write_state_body <<'EOF'
## Todos
None.

## Blockers
None.
EOF
}

write_state_legacy() {
  write_state_body <<'EOF'
## Todos

### Pending Todos
- [KNOWN-ISSUE] TestCrash (CrashTests.swift): signal trap (phase 03, seen 1x) (added 2026-04-01) (ref:abc12345)
- Follow-up todo (added 2026-04-02)

### Completed Todos
- Already completed item

## Activity Log
- 2026-04-01: Existing note
EOF
}

write_state_ref_item() {
  write_state_body <<'EOF'

## Todos
- Item with detail (added 2026-04-01) (ref:deadbeef)

## Activity Log
- 2026-04-01: Existing note
EOF
}

write_todo_lines() {
  printf '# Project State\n\n## Todos\n%b\n\n## Activity Log\n- 2026-04-01: Existing note\n' "$1" > "$STATE_FILE"
}

save_snapshot() {
  local filter="${1:-}"
  if [ -n "$filter" ]; then
    run bash "$LIST_SCRIPT" "$filter"
  else
    run bash "$LIST_SCRIPT"
  fi
  [ "$status" -eq 0 ]
  printf '%s' "$output" | bash "$SCRIPT" snapshot-save >/dev/null
}

select_snapshot_item() {
  bash "$RESOLVE_SCRIPT" "$1" --session-snapshot
}

item_from() {
  case "$1" in
    snapshot-high)
      save_snapshot high
      select_snapshot_item 1
      ;;
    *)
      bash "$LIST_SCRIPT" | jq -c '.items[0]'
      ;;
  esac
}

run_piped() {
  local payload="$1"
  shift
  run bash -c 'printf "%s" "$1" | bash "$2" "${@:3}"' -- "$payload" "$@"
}

write_raw_snapshot() {
  printf '%s' "$1" > "$(snapshot_path_for_session_id)"
}

seed_sidecar() {
  case "$1" in
    yes) bash "$DETAILS_SCRIPT" add deadbeef '{"summary":"Item with detail","context":"extra detail","files":["a.sh"],"added":"2026-04-01","source":"session"}' "$LBWC_PLANNING_DIR/todo-details.json" >/dev/null ;;
  esac
}

expect_snapshot_invalid_everywhere() {
  local label="$1" selection="${2:-1}"

  run bash "$SCRIPT" snapshot-show
  expect_status "$label" 0
  expect_json "$label" '.code' snapshot_invalid
  expect_json "$label" '.status' error

  run bash "$SCRIPT" snapshot-select "$selection"
  expect_status "$label" 0
  expect_json "$label" '.code' snapshot_invalid
  expect_json "$label" '.status' error

  run bash "$RESOLVE_SCRIPT" "$selection" --session-snapshot --require-unfiltered --validate-live
  expect_status "$label" 0
  expect_json "$label" '.code' snapshot_invalid
  expect_json "$label" '.status' error
}

@test "snapshot-save and snapshot-show keep payloads per sanitized session without masking list errors" {
  local error_json='{"status":"error","message":"STATE.md not found at .lbwc-planning/STATE.md. Run /lbwc:init to set up your project."}'
  local session_a session_b planning_dir_a planning_dir_b
  local snapshot_path_a snapshot_path_b output_a output_b snapshot_a snapshot_b
  while IFS='|' read -r label payload expected_status expected_code; do
    [ -n "$label" ] || continue
    rm -f "$TEST_SNAPSHOT_PATH"
    case "$payload" in
      -) ;;
      *) write_raw_snapshot "$payload" ;;
    esac
    run bash "$SCRIPT" snapshot-show
    expect_status "$label" 0
    expect_json "$label" '.status' "$expected_status"
    expect_json_unless_dash "$label" '.code' "$expected_code"
  done <<'CASES'
missing-snapshot|-|error|snapshot_missing
valid-empty-payload|{"status":"empty","state_path":".lbwc-planning/STATE.md","section":null,"count":0,"filter":null,"display":"No pending todos.","items":[]}|empty|-
valid-no-match-payload|{"status":"no-match","state_path":".lbwc-planning/STATE.md","section":"## Todos","count":0,"filter":"high","display":"No high-priority todos found.","items":[]}|no-match|-
CASES

  rm -f "$TEST_SNAPSHOT_PATH"
  run_piped "$error_json" "$SCRIPT" snapshot-save
  expect_status error-payload-save 0
  expect_json error-payload-save '.status' ok
  run bash "$SCRIPT" snapshot-show
  expect_status error-payload-show 0
  expect_json error-payload-show '.status' error
  expect_json error-payload-show '.message | contains("STATE.md not found")' true

  session_a="$(unique_session_id a)"
  session_b="$(unique_session_id b)"
  planning_dir_a="$TEST_TEMP_DIR/session-a/.lbwc-planning"
  planning_dir_b="$TEST_TEMP_DIR/session-b/.lbwc-planning"

  mkdir -p "$planning_dir_a" "$planning_dir_b"
  STATE_FILE="$planning_dir_a/STATE.md" write_state_recent_activity
  STATE_FILE="$planning_dir_b/STATE.md" write_state_body <<'EOF'

## Todos
- [HIGH] Different task (added 2026-04-10)

## Recent Activity
- 2026-04-10: Alternate note
EOF

  snapshot_path_a=$(snapshot_path_for_session_id "$session_a")
  snapshot_path_b=$(snapshot_path_for_session_id "$session_b")
  EXTRA_SNAPSHOT_PATHS="$snapshot_path_a $snapshot_path_b"
  [ "$snapshot_path_a" != "$snapshot_path_b" ] || fail_case session-isolation "both sessions share $snapshot_path_a"

  output_a=$(CLAUDE_SESSION_ID="$session_a" LBWC_PLANNING_DIR="$planning_dir_a" bash "$SCRIPT" list-with-snapshot high)
  output_b=$(CLAUDE_SESSION_ID="$session_b" LBWC_PLANNING_DIR="$planning_dir_b" bash "$SCRIPT" list-with-snapshot high)
  snapshot_a=$(CLAUDE_SESSION_ID="$session_a" LBWC_PLANNING_DIR="$planning_dir_a" bash "$SCRIPT" snapshot-show)
  snapshot_b=$(CLAUDE_SESSION_ID="$session_b" LBWC_PLANNING_DIR="$planning_dir_b" bash "$SCRIPT" snapshot-show)

  expect_same_json session-a "$snapshot_a" "$output_a"
  expect_same_json session-b "$snapshot_b" "$output_b"
  [ "$(printf '%s' "$snapshot_a" | jq -r '.items[0].command_text')" = "Refactor auth module" ] \
    || fail_case session-a "unexpected first item in $snapshot_a"
  [ "$(printf '%s' "$snapshot_b" | jq -r '.items[0].command_text')" = "Different task" ] \
    || fail_case session-b "unexpected first item in $snapshot_b"

  write_state_recent_activity
  export CLAUDE_SESSION_ID="../unsafe session id $(unique_session_id sanitize)"
  run bash "$LIST_SCRIPT"
  expect_status sanitize-list 0
  run_piped "$output" "$SCRIPT" snapshot-save
  expect_status sanitize-save 0
  expect_json sanitize-save '.status' ok
  expect_json sanitize-save '.path | startswith("/tmp/.lbwc-last-list-view-")' true
  expect_json sanitize-save '.path | contains("../")' false
  run bash "$SCRIPT" snapshot-show
  expect_status sanitize-show 0
  expect_json sanitize-show '.status' ok
}

@test "list-with-snapshot stores its output, snapshot consumers read it back, and every consumer rejects a malformed snapshot" {
  while IFS='|' read -r label state filter expected_status count section display first_text first_index; do
    [ -n "$label" ] || continue
    rm -f "$TEST_SNAPSHOT_PATH"
    "write_state_$state"
    run bash "$LIST_SCRIPT" $filter
    expect_status "$label" 0
    local expected_json="$output"

    run bash "$SCRIPT" list-with-snapshot $filter
    expect_status "$label" 0
    expect_same_json "$label" "$output" "$expected_json"
    expect_json "$label" '.status' "$expected_status"
    expect_json "$label" '.count' "$count"
    expect_json "$label" '.filter' "$filter"
    expect_json "$label" '.section' "$section"
    expect_json "$label" '.items | length' "$count"
    expect_json_unless_dash "$label" '.display' "$display"
    expect_json_unless_dash "$label" '.items[0].command_text' "$first_text"
    expect_json_unless_dash "$label" '.items[0].section_index' "$first_index"

    run bash "$SCRIPT" snapshot-show
    expect_status "$label" 0
    expect_same_json "$label" "$output" "$expected_json"
  done <<'CASES'
filtered-match|recent_activity|high|ok|1|## Todos|-|Refactor auth module|2
filtered-empty|no_todos|high|empty|0|null|No pending todos.|-|-
CASES

  rm -f "$TEST_SNAPSHOT_PATH"
  write_state_recent_activity
  run bash "$SCRIPT" list-with-snapshot
  expect_status resolve-list 0
  run bash "$RESOLVE_SCRIPT" 1 --session-snapshot --validate-live
  expect_status resolve 0
  expect_json resolve '.status' ok
  expect_json resolve '.selection_source' snapshot

  save_snapshot high
  run bash "$SCRIPT" snapshot-select 1
  expect_status select 0
  expect_json select '.status' ok
  expect_json select '.priority' high
  expect_json select '.num' 1
  expect_json select '.section_index' 2
  expect_json select '.normalized_text' "Refactor auth module"

  while IFS='|' read -r label payload; do
    [ -n "$label" ] || continue
    write_raw_snapshot "$payload"
    expect_snapshot_invalid_everywhere "$label"
  done <<'CASES'
bogus-top-level-status|{"status":"bogus","state_path":".lbwc-planning/STATE.md","section":"## Todos","count":1,"filter":null,"items":[{"num":1,"section_index":1,"line":"- Test todo","normalized_text":"Test todo","state_path":".lbwc-planning/STATE.md","section":"## Todos","line_no":12,"identity_occurrence":1,"identity_total":1,"ref":null,"known_issue_signature":null}]}
ok-snapshot-missing-filter|{"status":"ok","state_path":".lbwc-planning/STATE.md","section":"## Todos","count":1,"items":[{"num":1,"section_index":1,"line":"- Test todo","normalized_text":"Test todo","state_path":".lbwc-planning/STATE.md","section":"## Todos","line_no":12,"identity_occurrence":1,"identity_total":1,"ref":null,"known_issue_signature":null}]}
no-match-snapshot-with-null-filter|{"status":"no-match","state_path":".lbwc-planning/STATE.md","section":"## Todos","count":0,"filter":null,"display":"No matching todos.","items":[]}
invalid-item-ref-metadata|{"status":"ok","state_path":".lbwc-planning/STATE.md","section":"## Todos","count":1,"filter":null,"items":[{"num":1,"section_index":1,"line":"- Test todo","normalized_text":"Test todo","state_path":".lbwc-planning/STATE.md","section":"## Todos","line_no":12,"identity_occurrence":1,"identity_total":1,"ref":"not-a-ref","known_issue_signature":null}]}
CASES
}

@test "validate-item accepts a live match and fails closed when the displayed item went stale" {
  while IFS='|' read -r label before after selection expected_status expected_code expected_text; do
    [ -n "$label" ] || continue
    rm -f "$TEST_SNAPSHOT_PATH"
    write_todo_lines "$before"
    save_snapshot
    local item_json
    item_json=$(select_snapshot_item "$selection")
    case "$after" in
      =) ;;
      *) write_todo_lines "$after" ;;
    esac

    run_piped "$item_json" "$SCRIPT" validate-item
    expect_status "$label" 0
    expect_json "$label" '.status' "$expected_status"
    expect_json_unless_dash "$label" '.code' "$expected_code"
    expect_json_unless_dash "$label" '.normalized_text' "$expected_text"
  done <<'CASES'
unchanged-state|- Fix parser bug (added 2026-04-01)\n- [HIGH] Refactor auth module (added 2026-04-02)|=|1|ok|-|Fix parser bug
duplicate-occurrence-count-changes|- Duplicate task (added 2026-04-01)\n- Duplicate task (added 2026-04-01)|- Duplicate task (added 2026-04-01)\n- Duplicate task (added 2026-04-01)\n- Duplicate task (added 2026-04-01)|2|error|selection_stale|-
raw-displayed-line-changes|- [HIGH] Change me (added 2026-04-01)|- Change me (added 2026-04-01)|1|error|selection_stale|-
CASES
}

@test "remove and pickup rewrite only the Todos section, log the change, and clean the detail sidecar only when safe" {
  while IFS='|' read -r label state source invocation expected_status present absent; do
    [ -n "$label" ] || continue
    rm -f "$TEST_SNAPSHOT_PATH"
    "write_state_$state"
    local item_json
    item_json=$(item_from "$source")

    run_piped "$item_json" "$SCRIPT" $invocation
    expect_status "$label" 0
    expect_json "$label" '.status' "$expected_status"
    expect_file_matches "$label" "$STATE_FILE" "$present"
    expect_file_lacks_lines "$label" "$STATE_FILE" "$absent"
  done <<'CASES'
remove-from-filtered-snapshot|recent_activity|snapshot-high|remove none safe|ok|=## Recent Activity~Fix parser bug~Removed todo via /lbwc:list-todos: [HIGH] Refactor auth module|- [HIGH] Refactor auth module (added 2026-04-02)
pickup-restores-none-and-creates-activity-log|without_activity|list-first|pickup /lbwc:fix none keep|ok|=## Activity Log~=None.~Picked up todo via /lbwc:fix: Only todo item|- Only todo item (added 2026-04-01)
remove-leaves-legacy-completed-todos|legacy|list-first|remove none keep|partial|=### Completed Todos~Already completed item~Follow-up todo|- [KNOWN-ISSUE] TestCrash (CrashTests.swift): signal trap (phase 03, seen 1x) (added 2026-04-01) (ref:abc12345)
CASES

  while IFS='|' read -r label invocation sidecar expected_status warned sidecar_after; do
    [ -n "$label" ] || continue
    rm -f "$LBWC_PLANNING_DIR/todo-details.json"
    write_state_ref_item
    seed_sidecar "$sidecar"
    local item_json
    item_json=$(item_from list-first)

    run_piped "$item_json" "$SCRIPT" $invocation
    expect_status "$label" 0
    expect_json "$label" '.status' "$expected_status"
    expect_json "$label" '(.warning // "") | contains("sidecar registry was left untouched")' "$warned"
    expect_file_has_line "$label" "$STATE_FILE" "None."

    run bash "$DETAILS_SCRIPT" get deadbeef "$LBWC_PLANNING_DIR/todo-details.json"
    expect_status "$label" 0
    expect_json "$label" '.status' "$sidecar_after"
  done <<'CASES'
remove-detail-not-found|remove not_found safe|no|partial|true|not_found
remove-detail-ok-safe-cleanup|remove ok safe|yes|ok|false|not_found
remove-detail-ok-keep-cleanup|remove ok keep|yes|ok|false|ok
remove-detail-error-safe-cleanup|remove error safe|yes|partial|true|ok
pickup-detail-error-keep-cleanup|pickup /lbwc:fix error keep|yes|partial|true|ok
CASES
}

TRACK_SCRIPT="$BATS_TEST_DIRNAME/../scripts/track-known-issues.sh"
KNOWN_ISSUE_REF_LINE='- [KNOWN-ISSUE] TransferTests (tests/transfer.sh): timeout (phase 03, seen 1x) (added 2026-04-01) (ref:deadbeef)'
KNOWN_ISSUE_LEGACY_LINE='- [KNOWN-ISSUE] TransferTests (tests/transfer.sh): timeout (phase 03, seen 1x) (added 2026-04-01)'

seed_phase_registry() {
  local phase_dir="$LBWC_PLANNING_DIR/phases/03-test-phase"
  cat > "$phase_dir/03-01-SUMMARY.md" <<'SUMMARY'
---
phase: 03
pre_existing_issues:
  - '{"test":"TransferTests","file":"tests/transfer.sh","error":"timeout"}'
---
SUMMARY
  bash "$TRACK_SCRIPT" sync-summaries "$phase_dir" >/dev/null
}

seed_signature_sidecar() {
  jq -n --arg dir "$LBWC_PLANNING_DIR/phases/03-test-phase" '{
    schema_version: 1,
    items: {deadbeef: {summary: "TransferTests", added: "2026-04-01", source: "session",
      known_issue_signature: {phase: "03", phase_dir: $dir, test: "TransferTests", file: "tests/transfer.sh", error: "timeout"}}}
  }' > "$LBWC_PLANNING_DIR/todo-details.json"
}

remove_known_issue_case() {
  local todo_line="$1" sidecar="$2" registry="$3" item_json
  write_todo_lines "$todo_line"
  case "$sidecar" in yes) seed_signature_sidecar ;; esac
  case "$registry" in yes) seed_phase_registry ;; esac
  item_json=$(item_from list-first)
  run_piped "$item_json" "$SCRIPT" remove none keep
}

@test "removing a known-issue todo ends ok and blocks re-promotion with a registry, and ends partial with a warning without one" {
  while IFS='|' read -r label todo_line sidecar; do
    [ -n "$label" ] || continue
    rm -f "$LBWC_PLANNING_DIR/todo-details.json" "$LBWC_PLANNING_DIR/phases/03-test-phase/known-issues.json"

    remove_known_issue_case "$todo_line" "$sidecar" yes

    expect_status "$label" 0
    expect_json "$label" '.status' ok
    expect_json "$label" '.warning' null
    run bash "$TRACK_SCRIPT" promote-todos "$LBWC_PLANNING_DIR/phases/03-test-phase"
    [[ "$output" == *"promoted_count=0"* ]] || fail_case "$label" "known issue was promoted again"
  done <<CASES
remove-with-signature-in-sidecar|$KNOWN_ISSUE_REF_LINE|yes
remove-legacy-line-resolved-through-registry|$KNOWN_ISSUE_LEGACY_LINE|no
CASES

  rm -f "$LBWC_PLANNING_DIR/phases/03-test-phase/03-01-SUMMARY.md"
  while IFS='|' read -r label todo_line sidecar; do
    [ -n "$label" ] || continue
    rm -f "$LBWC_PLANNING_DIR/todo-details.json" "$LBWC_PLANNING_DIR/phases/03-test-phase/known-issues.json"

    remove_known_issue_case "$todo_line" "$sidecar" no

    expect_status "$label" 0
    expect_json "$label" '.status' partial
    expect_json "$label" '.warning | type' string
    expect_json "$label" '.warning | contains("re-promoted")' true
  done <<CASES
remove-without-registry-signature-in-sidecar|$KNOWN_ISSUE_REF_LINE|yes
remove-without-registry-legacy-line|$KNOWN_ISSUE_LEGACY_LINE|no
CASES
}

@test "snapshot-save and snapshot-select reject unreadable payloads and out-of-view selections with a coded error" {
  run_piped 'not json' "$SCRIPT" snapshot-save
  expect_status save-invalid-json 0
  expect_json save-invalid-json '.code' snapshot_invalid
  expect_json save-invalid-json '.message | contains("invalid")' true

  run_piped '{"status":"ok"}' "$SCRIPT" snapshot-save
  expect_status save-malformed 0
  expect_json save-malformed '.code' snapshot_invalid
  expect_json save-malformed '.message | contains("malformed")' true

  write_state_recent_activity
  save_snapshot
  run bash "$SCRIPT" snapshot-select 4
  expect_status select-past-end 0
  expect_json select-past-end '.code' invalid_selection
  expect_json select-past-end '.message | contains("1-3")' true

  run bash "$SCRIPT" snapshot-select 0
  expect_status select-zero 0
  expect_json select-zero '.code' invalid_selection

  run bash "$SCRIPT" snapshot-select first
  expect_status select-not-a-number 0
  expect_json select-not-a-number '.code' invalid_selection

  run bash "$SCRIPT" snapshot-select 03
  expect_status select-padded 0
  expect_json select-padded '.num' 3
  expect_json select-padded '.snapshot_filter' null

  save_snapshot high
  run bash "$SCRIPT" snapshot-select 1 --require-unfiltered
  expect_status select-filtered 0
  expect_json select-filtered '.code' snapshot_filtered

  run_piped '{"status":"error","message":"STATE.md not found"}' "$SCRIPT" snapshot-save
  run bash "$SCRIPT" snapshot-select 1
  expect_status select-error-snapshot 0
  expect_json select-error-snapshot '.status' error
  expect_json select-error-snapshot '.message' "STATE.md not found"

  CLAUDE_SESSION_ID="$(printf 'n%.0s' $(seq 1 300))" run_piped '{"status":"error","message":"x"}' "$SCRIPT" snapshot-save
  expect_status save-uncreatable 0
  expect_json save-uncreatable '.code' snapshot_write_failed
}

@test "validate-item fails closed on payloads without identity metadata or outside the root backlog" {
  local item_json other_state="$TEST_TEMP_DIR/other/.lbwc-planning/STATE.md"
  write_state_recent_activity
  save_snapshot
  item_json=$(select_snapshot_item 1)

  run_piped "$(printf '%s' "$item_json" | jq -c 'del(.identity_occurrence)')" "$SCRIPT" validate-item
  expect_status missing-occurrence 0
  expect_json missing-occurrence '.code' invalid_item

  mkdir -p "$(dirname "$other_state")"
  cp "$STATE_FILE" "$other_state"
  run_piped "$(printf '%s' "$item_json" | jq -c --arg path "$other_state" '.state_path = $path')" "$SCRIPT" validate-item
  expect_status foreign-state 0
  expect_json foreign-state '.code' state_missing

  run_piped "$(printf '%s' "$item_json" | jq -c --arg path "$LBWC_PLANNING_DIR/NOTES.md" '.state_path = $path')" "$SCRIPT" validate-item
  expect_status not-state-file 0
  expect_json not-state-file '.code' state_missing

  run_piped 'not json' "$SCRIPT" validate-item
  expect_status invalid-json 0
  expect_json invalid-json '.code' invalid_item
}
