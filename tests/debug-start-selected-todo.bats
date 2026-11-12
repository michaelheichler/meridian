#!/usr/bin/env bats

load test_helper
load gate_case_helper
load gate_case_files

snapshot_path_for_session_id() {
  local raw_session_id="${1:-${CLAUDE_SESSION_ID:-default}}"
  local session_key

  session_key=$(printf '%s' "$raw_session_id" | tr -c 'A-Za-z0-9_.-' '_')
  session_key="${session_key:-default}"
  printf '/tmp/.meridian-last-list-view-%s.json\n' "$session_key"
}

setup() {
  setup_temp_dir
  create_test_config
  reset_case_failures
  export MERIDIAN_PLANNING_DIR="$TEST_TEMP_DIR/.meridian"
  export CLAUDE_SESSION_ID="debug-start-selected-${BATS_TEST_NUMBER:-0}-$$-$RANDOM"
  SCRIPT="$SCRIPTS_DIR/debug-start-selected-todo.sh"
  LIFECYCLE_SCRIPT="$SCRIPTS_DIR/todo-lifecycle.sh"
  DETAILS_SCRIPT="$SCRIPTS_DIR/todo-details.sh"
  STATE_SCRIPT="$SCRIPTS_DIR/debug-session-state.sh"
  export TEST_SNAPSHOT_PATH="$(snapshot_path_for_session_id "$CLAUDE_SESSION_ID")"
  rm -f "$TEST_SNAPSHOT_PATH"
}

teardown() {
  chmod u+w "$MERIDIAN_PLANNING_DIR" 2>/dev/null || true
  rm -f "$TEST_SNAPSHOT_PATH" 2>/dev/null || true
  teardown_temp_dir
}

reset_world() {
  rm -rf "$MERIDIAN_PLANNING_DIR/debugging" "$MERIDIAN_PLANNING_DIR/milestones" \
    "$MERIDIAN_PLANNING_DIR/todo-details.json" "$MERIDIAN_PLANNING_DIR/STATE.md"
  rm -f "$TEST_SNAPSHOT_PATH"
}

write_state() {
  printf '%s\n' '# Project State' '' '## Todos' \
    '- Fix parser bug (added 2026-04-01)' \
    '- Investigate detail-backed crash (added 2026-04-02) (ref:deadbeef)' \
    '- Empty detail item (added 2026-04-03) (ref:feedcafe)' \
    '- Missing detail item (added 2026-04-04) (ref:f78562c0)' \
    '' '## Recent Activity' '- 2026-04-01: Existing note' > "$MERIDIAN_PLANNING_DIR/STATE.md"
}

write_todos_state() {
  { printf '%s\n' '# Project State' '' '## Todos'; printf '%s\n' "$@"; printf '%s\n' '' '## Activity Log' '- 2026-04-01: Existing note'; } \
    > "$MERIDIAN_PLANNING_DIR/STATE.md"
}

add_detail() {
  bash "$DETAILS_SCRIPT" add "$1" "$2" "$MERIDIAN_PLANNING_DIR/todo-details.json" >/dev/null
}

save_snapshot() {
  (cd "$TEST_TEMP_DIR" && MERIDIAN_PLANNING_DIR="$MERIDIAN_PLANNING_DIR" bash "$LIFECYCLE_SCRIPT" list-with-snapshot) >/dev/null
}

seed_complete_session() {
  local text=$1 raw_line=$2 ref=$3 detail_status=$4 slug=$5 source_json
  source_json=$(jq -cn --arg mode source-todo --arg text "$text" --arg raw_line "$raw_line" --arg ref "$ref" \
    --arg detail_status "$detail_status" \
    '{mode:$mode,text:$text,raw_line:$raw_line,ref:$ref,detail_status:$detail_status,related_files:[],detail_context:""}')
  eval "$(printf '%s' "$source_json" | bash "$STATE_SCRIPT" start-with-source-todo "$MERIDIAN_PLANNING_DIR" "$slug")"
  bash "$STATE_SCRIPT" set-status "$MERIDIAN_PLANNING_DIR" complete >/dev/null
}

session_file_from_output() {
  printf '%s' "$1" | jq -r '.session.file'
}

count_sessions() {
  find "$MERIDIAN_PLANNING_DIR/debugging/$1" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' '
}

expect_count() {
  local label=$1 got=$2 want=$3
  [ "$got" = "$want" ] || record_case_failure "$label" "count=$got want=$want"
}

pending_todos_contain() {
  awk '/^## Todos$/{found=1; next} found && /^## /{exit} found {print}' "${2:-$MERIDIAN_PLANNING_DIR/STATE.md}" | grep -qF "$1"
}

expect_pending() {
  pending_todos_contain "$2" "${3:-}" || record_case_failure "$1" "pending todos lack [$2]"
}

expect_not_pending() {
  pending_todos_contain "$2" "${3:-}" && record_case_failure "$1" "pending todos still hold [$2]"
  return 0
}

instrument_list_todos() {
  local instrumented=$1 count_file=$2 script_path
  mkdir -p "$instrumented"
  while IFS= read -r script_path; do
    ln -sf "$script_path" "$instrumented/$(basename "$script_path")"
  done < <(find "$SCRIPTS_DIR" -maxdepth 1 -type f -name '*.sh')
  ln -sfn "$SCRIPTS_DIR/lib" "$instrumented/lib"
  rm -f "$instrumented/list-todos.sh"
  printf '%s\n' '#!/usr/bin/env bash' "printf '1\\n' >> \"$count_file\"" "exec \"$SCRIPTS_DIR/list-todos.sh\" \"\$@\"" > "$instrumented/list-todos.sh"
  chmod +x "$instrumented/list-todos.sh"
}

@test "debug-start-selected-todo starts a session for the selected todo, cleans the pending list, and repairs todos a completed session already solved" {
  local session_file other_root target_planning other_planning count_file

  reset_world
  write_state
  save_snapshot
  run bash "$SCRIPT" "$MERIDIAN_PLANNING_DIR" 1
  session_file=$(session_file_from_output "$output")
  expect_status "no-ref" 0
  expect_jq_output "no-ref-fields" '.status == "ok" and .bug_desc == "Fix parser bug" and .detail_status == "none" and .pickup.status == "ok" and .pickup.auto_note == "Selected todo was already picked up automatically."'
  [[ "$output" != status=* ]] || record_case_failure "no-ref-json-only" "output starts with a shell assignment"
  expect_path "no-ref-session-file" "$session_file"
  expect_file_line "no-ref-source-heading" "$session_file" '^## Source Todo$'
  expect_file_line "no-ref-source-text" "$session_file" '\*\*Text:\*\* Fix parser bug'
  expect_no_file_line "no-ref-root-todo-removed" "$MERIDIAN_PLANNING_DIR/STATE.md" '^- Fix parser bug'
  expect_file_line "no-ref-activity-note" "$MERIDIAN_PLANNING_DIR/STATE.md" 'Picked up todo via /meridian:debug: Fix parser bug'
  run bash "$LIFECYCLE_SCRIPT" list-with-snapshot
  expect_jq_output "no-ref-gone-from-list" '[.items[]?.command_text | select(. == "Fix parser bug")] | length == 0'

  reset_world
  write_state
  add_detail deadbeef '{"summary":"Investigate detail-backed crash","context":"Crash detail context","files":["src/parser.sh","tests/parser.bats"],"added":"2026-04-02","source":"session"}'
  save_snapshot
  run bash "$SCRIPT" "$MERIDIAN_PLANNING_DIR" 2
  session_file=$(session_file_from_output "$output")
  expect_status "detail-ok" 0
  expect_jq_output "detail-ok-fields" '.status == "ok" and .detail_status == "ok" and .detail_has_signal == true and .detail.files[0] == "src/parser.sh"'
  expect_file_line "detail-ok-session-context" "$session_file" 'Crash detail context'
  expect_file_line "detail-ok-session-files" "$session_file" 'src/parser.sh'
  expect_not_pending "detail-ok-root-todo-removed" 'Investigate detail-backed crash'
  run bash "$DETAILS_SCRIPT" get deadbeef "$MERIDIAN_PLANNING_DIR/todo-details.json"
  expect_jq_output "detail-ok-sidecar-removed" '.status == "not_found"'

  reset_world
  write_state
  add_detail feedcafe '{"summary":"Empty detail item","context":"","files":[],"added":"2026-04-03","source":"session"}'
  save_snapshot
  run bash "$SCRIPT" "$MERIDIAN_PLANNING_DIR" 3
  expect_status "detail-sparse" 0
  expect_jq_output "detail-sparse-fields" '.status == "ok" and .detail_status == "ok" and .detail_has_signal == false'
  expect_not_pending "detail-sparse-root-todo-removed" 'Empty detail item'

  reset_world
  write_state
  save_snapshot
  run bash "$SCRIPT" "$MERIDIAN_PLANNING_DIR" 4
  expect_status "detail-missing" 0
  expect_jq_output "detail-missing-fields" '.status == "ok" and .detail_status == "not_found" and .pickup.status == "partial"'
  expect_jq_output "detail-missing-warning" '.pickup.warning | contains("sidecar registry was left untouched")'
  expect_not_pending "detail-missing-root-todo-removed" 'Missing detail item'
  expect_file_line "detail-missing-warning-recorded" "$MERIDIAN_PLANNING_DIR/STATE.md" 'Detail for ref f78562c0 could not be loaded'

  reset_world
  write_state
  save_snapshot
  run bash "$SCRIPT" "$MERIDIAN_PLANNING_DIR" 1 --parallel --serial
  expect_status "routing-flags" 0
  expect_jq_output "routing-flags-preserved" '.routing_flags == ["--parallel","--serial"]'

  reset_world
  write_todos_state '- [KNOWN-ISSUE] Marker bug (added 2026-04-01) (ref:decafbad)'
  add_detail decafbad '{"summary":"Marker bug","context":"Accepted UAT summary deviation","files":[],"added":"2026-04-01","source":"uat-deviation","uat_deviation":{"id":"D1"},"known_issue_signature":{"disposition":"accepted-process-exception"}}'
  save_snapshot
  run bash "$SCRIPT" "$MERIDIAN_PLANNING_DIR" 1
  expect_status "markers" 0
  expect_jq_output "markers-known-issue" '.accepted_exception_markers | index("[KNOWN-ISSUE]") != null'
  expect_jq_output "markers-disposition" '.accepted_exception_markers | index("known_issue_signature.disposition") != null'
  expect_jq_output "markers-uat-source" '.accepted_exception_markers | index("source: \"uat-deviation\"") != null'
  expect_jq_output "markers-uat-key" '.accepted_exception_markers | index("uat_deviation") != null'
  expect_jq_output "markers-summary-deviation" '.accepted_exception_markers | index("Accepted UAT summary deviation") != null'

  reset_world
  other_root="$BATS_TEST_TMPDIR/other"
  target_planning="$BATS_TEST_TMPDIR/target/.meridian"
  other_planning="$other_root/.meridian"
  mkdir -p "$target_planning" "$other_planning"
  printf '%s\n' '# Project State' '' '## Todos' '- Target-only bug (added 2026-04-01) (ref:deadbeef)' '' '## Activity Log' '- 2026-04-01: Target note' > "$target_planning/STATE.md"
  printf '%s\n' '# Project State' '' '## Todos' '- Other repo bug (added 2026-04-01) (ref:deadbeef)' '' '## Activity Log' '- 2026-04-01: Other note' > "$other_planning/STATE.md"
  bash "$DETAILS_SCRIPT" add deadbeef '{"summary":"Target-only bug","context":"target context","files":["target.sh"],"added":"2026-04-01","source":"session"}' "$target_planning/todo-details.json" >/dev/null
  (cd "$BATS_TEST_TMPDIR/target" && MERIDIAN_PLANNING_DIR="$target_planning" bash "$LIFECYCLE_SCRIPT" list-with-snapshot) >/dev/null
  run bash -c 'cd "$1" && bash "$2" "$3" 1' -- "$other_root" "$SCRIPT" "$target_planning"
  expect_status "other-cwd" 0
  expect_jq_output "other-cwd-detail-from-target" '.status == "ok" and .detail.context == "target context"'
  expect_not_pending "other-cwd-target-todo-removed" 'Target-only bug' "$target_planning/STATE.md"
  expect_pending "other-cwd-other-todo-kept" 'Other repo bug' "$other_planning/STATE.md"
  expect_file_line "other-cwd-other-repo-untouched" "$other_planning/STATE.md" 'Other repo bug'

  reset_world
  write_todos_state '- Already completed bug (added 2026-04-04) (ref:f78562c0)'
  seed_complete_session 'Already completed bug' '- Already completed bug (added 2026-04-04) (ref:f78562c0)' f78562c0 not_found already-completed-bug
  expect_count "ref-completed-seeded" "$(count_sessions completed)" 1
  save_snapshot
  run bash "$SCRIPT" "$MERIDIAN_PLANNING_DIR" 1
  expect_status "ref-completed" 0
  expect_jq_output "ref-completed-fields" '.status == "already_complete" and .session.status == "complete"'
  expect_count "ref-completed-no-active-session" "$(count_sessions active)" 0
  expect_count "ref-completed-session-kept" "$(count_sessions completed)" 1
  expect_not_pending "ref-completed-root-todo-removed" 'Already completed bug'

  reset_world
  write_todos_state '- Legacy completed bug (added 2026-04-04) (ref:deadbeef)'
  seed_complete_session 'Legacy completed bug' '- Legacy completed bug (added 2026-04-04) (ref:deadbeef)' deadbeef not_found legacy-completed-bug
  mv "$MERIDIAN_PLANNING_DIR/debugging/completed/${session_id}.md" "$MERIDIAN_PLANNING_DIR/debugging/${session_id}.md"
  rmdir "$MERIDIAN_PLANNING_DIR/debugging/completed"
  save_snapshot
  run bash "$SCRIPT" "$MERIDIAN_PLANNING_DIR" 1
  expect_status "legacy-flat" 0
  expect_jq_output "legacy-flat-fields" '.status == "already_complete" and .session.status == "complete"'
  expect_count "legacy-flat-no-active-session" "$(count_sessions active)" 0
  expect_count "legacy-flat-migrated-to-completed" "$(count_sessions completed)" 1
  expect_no_path "legacy-flat-file-moved" "$MERIDIAN_PLANNING_DIR/debugging/${session_id}.md"
  expect_not_pending "legacy-flat-root-todo-removed" 'Legacy completed bug'

  reset_world
  write_todos_state '- Duplicate bug (added 2026-04-01)' '- Duplicate bug (added 2026-04-01)'
  seed_complete_session 'Duplicate bug' '- Duplicate bug (added 2026-04-01)' none none duplicate-bug
  save_snapshot
  run bash "$SCRIPT" "$MERIDIAN_PLANNING_DIR" 1
  expect_status "refless-duplicates" 0
  expect_jq_output "refless-duplicates-new-session" '.status == "ok"'
  expect_count "refless-duplicates-active-session" "$(count_sessions active)" 1
  expect_count "refless-duplicates-completed-session" "$(count_sessions completed)" 1

  reset_world
  count_file="$BATS_TEST_TMPDIR/list-count.txt"
  instrument_list_todos "$BATS_TEST_TMPDIR/instrumented-scripts" "$count_file"
  write_todos_state '- Selected same-ref bug (added 2026-04-01) (ref:cafebabe)' '- Sibling same-ref bug (added 2026-04-02) (ref:cafebabe)'
  seed_complete_session 'Old same-ref bug one' '- Old same-ref bug one (added 2026-03-01) (ref:cafebabe)' cafebabe none old-one
  seed_complete_session 'Old same-ref bug two' '- Old same-ref bug two (added 2026-03-02) (ref:cafebabe)' cafebabe none old-two
  save_snapshot
  : > "$count_file"
  run bash "$BATS_TEST_TMPDIR/instrumented-scripts/debug-start-selected-todo.sh" "$MERIDIAN_PLANNING_DIR" 1
  expect_status "same-ref-cache" 0
  expect_jq_output "same-ref-cache-fields" '.status == "ok"'
  expect_count "same-ref-cache-active-session" "$(count_sessions active)" 1
  expect_count "same-ref-cache-completed-sessions" "$(count_sessions completed)" 2
  expect_not_pending "same-ref-cache-selected-removed" 'Selected same-ref bug'
  expect_pending "same-ref-cache-sibling-kept" 'Sibling same-ref bug'
  expect_count "same-ref-cache-live-list-calls" "$(wc -l < "$count_file" | tr -d ' ')" 1

  assert_no_case_failures
}

@test "debug-start-selected-todo reports failures as JSON without losing or corrupting state" {
  reset_world
  run bash "$SCRIPT" "$MERIDIAN_PLANNING_DIR"
  expect_status "usage-missing-selection" 0
  expect_jq_output "usage-missing-selection-json" '.status == "error" and .code == "usage"'
  expect_output_has "usage-missing-selection-text" "Usage: debug-start-selected-todo.sh <planning-dir> <N>"

  run bash "$SCRIPT" "" 1
  expect_status "usage-missing-planning-dir" 0
  expect_jq_output "usage-missing-planning-dir-json" '.status == "error" and .code == "usage"'

  run bash "$SCRIPT" "$MERIDIAN_PLANNING_DIR" not-a-number
  expect_status "usage-not-a-number" 0
  expect_jq_output "usage-not-a-number-json" '.status == "error" and .code == "usage"'

  run bash "$SCRIPT" "$MERIDIAN_PLANNING_DIR" 1 --unknown
  expect_status "usage-unknown-flag" 0
  expect_jq_output "usage-unknown-flag-json" '.status == "error" and .code == "usage"'
  expect_output_has "usage-unknown-flag-text" "--unknown"

  run bash "$SCRIPT" "$BATS_TEST_TMPDIR/absent-planning" 1
  expect_status "planning-dir-missing" 0
  expect_jq_output "planning-dir-missing-json" '.status == "error" and .code == "planning_dir_missing"'

  reset_world
  write_state
  save_snapshot
  run bash "$SCRIPT" "$MERIDIAN_PLANNING_DIR" 99
  expect_status "invalid-selection" 0
  expect_jq_output "invalid-selection-json" '.status == "error" and .code == "invalid_selection"'
  expect_no_path "invalid-selection-no-session-dir" "$MERIDIAN_PLANNING_DIR/debugging/active"
  expect_file_line "invalid-selection-state-intact" "$MERIDIAN_PLANNING_DIR/STATE.md" 'Fix parser bug'

  reset_world
  mkdir -p "$MERIDIAN_PLANNING_DIR/milestones/old"
  printf '%s\n' '# Project State' '' '## Todos' '- Archived bug (added 2026-04-01)' > "$MERIDIAN_PLANNING_DIR/milestones/old/STATE.md"
  save_snapshot
  run bash "$SCRIPT" "$MERIDIAN_PLANNING_DIR" 1
  expect_status "archived-state" 0
  expect_jq_output "archived-state-json" '.status == "error"'
  expect_no_path "archived-state-no-session-dir" "$MERIDIAN_PLANNING_DIR/debugging/active"
  expect_file_line "archived-state-untouched" "$MERIDIAN_PLANNING_DIR/milestones/old/STATE.md" 'Archived bug'

  reset_world
  write_todos_state '- Pickup failure bug (added 2026-04-01)'
  save_snapshot
  mkdir -p "$MERIDIAN_PLANNING_DIR/debugging/active"
  chmod u-w "$MERIDIAN_PLANNING_DIR"
  run bash "$SCRIPT" "$MERIDIAN_PLANNING_DIR" 1
  chmod u+w "$MERIDIAN_PLANNING_DIR"
  expect_status "pickup-failure" 0
  expect_jq_output "pickup-failure-json" '.status == "error" and .code == "pickup_failed_after_session" and (.session.id | length > 0) and .session.status == "investigating" and .pickup.status == "error"'
  expect_jq_output "pickup-failure-message" '((.pickup.message // .message // "") | length > 0)'
  expect_path "pickup-failure-session-file" "$(session_file_from_output "$output")"
  expect_count "pickup-failure-active-session" "$(count_sessions active)" 1
  expect_pending "pickup-failure-todo-kept" 'Pickup failure bug'

  assert_no_case_failures
}
