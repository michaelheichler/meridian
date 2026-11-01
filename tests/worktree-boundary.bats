#!/usr/bin/env bats

load test_helper
load guard_helper
load worktree_helper

setup() {
  setup_temp_dir
  CHILD_PID=""
  cd "$TEST_TEMP_DIR"
}

teardown() {
  [ -z "$CHILD_PID" ] || kill "$CHILD_PID" 2>/dev/null || true
  cd "$PROJECT_ROOT"
  teardown_temp_dir
}

check_context_script() {
  local script="$1" label="$2" payload="$3" map_key="$4" expectation="$5"
  local worktree="$TEST_TEMP_DIR/.lbwc-worktrees/mapped" maps="$TEST_TEMP_DIR/.lbwc-planning/.agent-worktrees" marker
  case "$script" in
    compaction-instructions) marker="your working directory is " ;;
    *) marker="Worktree working directory: " ;;
  esac
  mkdir -p "$worktree" "$maps"
  find "$maps" -name '*.json' -delete
  rm -f "$TEST_TEMP_DIR/.lbwc-planning/.compaction-count"
  [ "$map_key" = "-" ] || printf '{"worktree_path":"%s"}' "$worktree" > "$maps/$map_key.json"

  run env LBWC_PLANNING_DIR="$TEST_TEMP_DIR/.lbwc-planning" bash -c 'cd "$1" && printf "%s" "$2" | bash "$3"' _ "$worktree" "$payload" "$SCRIPTS_DIR/$script.sh"

  expect_status "$script/$label" 0
  case "$expectation" in
    include) expect_output_has "$script/$label" "$marker$worktree" ;;
    omit)
      expect_output_lacks "$script/$label" "$worktree"
      expect_output_lacks "$script/$label" "$marker"
      ;;
  esac
}

@test "compaction hints carry the worktree path only for a mapped implementation agent" {
  while IFS='|' read -r label payload map_key expectation; do
    [ -n "$label" ] || continue
    check_context_script compaction-instructions "$label" "$payload" "$map_key" "$expectation"
    check_context_script post-compact "$label" "$payload" "$map_key" "$expectation"
  done <<'CASES'
exact-name-mapping|{"agent_name":"lbwc-python-engineer-01"}|lbwc-python-engineer-01|include
agent-type-carrying-the-generated-name|{"agent_type":"lbwc-python-engineer-02"}|lbwc-python-engineer-02|include
bare-foreign-agent-type|{"agent_type":"engineer","name":"engineer-01"}|engineer-01|omit
foreign-agent-type-with-generated-name|{"agent_type":"helper-agent","agent_name":"lbwc-python-engineer-01"}|lbwc-python-engineer-01|omit
unmatched-mapping-key|{"agent_type":"python-engineer","agent_id":"agent-abc123"}|lbwc-python-engineer-01|omit
engineer-without-mapping|{"agent_name":"lbwc-python-engineer-01"}|-|omit
reviewer-role-with-mapping|{"agent_name":"lbwc-qa"}|lbwc-qa|omit
lead-role-with-mapping|{"agent_name":"lbwc-lead"}|lbwc-lead|omit
debugger-with-mapping|{"agent_name":"lbwc-debugger-01"}|lbwc-debugger-01|include
docs-with-mapping|{"agent_name":"lbwc-docs-01"}|lbwc-docs-01|include
qa-author-with-mapping|{"agent_name":"lbwc-qa-author-01"}|lbwc-qa-author-01|include
architect-with-mapping|{"agent_name":"lbwc-architect-01"}|lbwc-architect-01|omit
CASES
}

automatic_preserve_row() {
  local label="$1" layout="$2" reason="$3" before after branches_before branches_after
  fresh_repo
  build_layout "$layout"
  before=$(tree_digest "$PWD")
  branches_before=$(branch_listing)

  run env LBWC_AUTOMATIC_CLEANUP=1 bash "$SCRIPTS_DIR/worktree-cleanup.sh" 01 01

  after=$(tree_digest "$PWD")
  branches_after=$(branch_listing)
  expect_status "$label" 0
  expect_output_equals "$label" "scan_only|.lbwc-worktrees/01-01|$reason"
  expect_same_digest "$label" "$before" "$after"
  expect_same_digest "$label" "$branches_before" "$branches_after"
}

@test "automatic cleanup preserves any worktree it cannot prove idle and owned and removes an owned, unmapped, clean worktree and its branch" {
  automatic_preserve_row target-absent-keeps-the-agent-map absent-with-map "cleanup target absent"
  automatic_preserve_row directory-git-does-not-own unowned "unproven ownership"
  automatic_preserve_row active-agent-mapping mapped "active mapping"
  automatic_preserve_row mapping-directory-missing no-map-dir "active mapping inspection unavailable"
  automatic_preserve_row malformed-mapping-file malformed-map "active mapping inspection unavailable"
  automatic_preserve_row uncommitted-changes dirty "dirty worktree"

  fresh_repo
  build_layout clean
  run env LBWC_AUTOMATIC_CLEANUP=1 bash "$SCRIPTS_DIR/worktree-cleanup.sh" 01 01
  expect_status clean-owned 0
  expect_output_lacks clean-owned "scan_only"
  expect_missing clean-owned .lbwc-worktrees/01-01
  [ -z "$(branch_listing)" ] || fail_case clean-owned "branch lbwc/01-01 survived"
  expect_no_match_under clean-owned .git/worktrees 01-01
}

session_stop_keeps_row() {
  local label="$1" layout="$2" age="$3" before after branches_before branches_after
  fresh_repo
  build_layout "$layout"
  [ "$age" != "stale" ] || set_stale_mtime_3h .lbwc-worktrees/01-01
  before=$(tree_digest "$PWD")
  branches_before=$(branch_listing)

  run run_session_stop

  after=$(tree_digest "$PWD")
  branches_after=$(branch_listing)
  expect_status "$label" 0
  expect_output_empty "$label"
  expect_same_digest "$label" "$before" "$after"
  expect_same_digest "$label" "$branches_before" "$branches_after"
}

@test "session stop leaves worktrees alone unless they are stale, owned, unmapped, and clean, and then removes the worktree and its branch" {
  session_stop_keeps_row stale-dirty-worktree dirty stale
  session_stop_keeps_row stale-actively-mapped-worktree mapped stale
  session_stop_keeps_row stale-directory-git-does-not-own unowned stale
  session_stop_keeps_row fresh-clean-worktree clean fresh
  session_stop_keeps_row no-worktrees-directory none fresh

  fresh_repo
  build_layout clean
  set_stale_mtime_3h .lbwc-worktrees/01-01
  run run_session_stop
  expect_status stale-clean 0
  expect_output_empty stale-clean
  expect_missing stale-clean .lbwc-worktrees/01-01
  [ -z "$(branch_listing)" ] || fail_case stale-clean "branch lbwc/01-01 survived"
}

doctor_scan_row() {
  local label="$1" layout="$2"
  plain_dir
  [ "$layout" = "none" ] || mkdir -p .lbwc-worktrees/02-01
  [ "$layout" != "stale" ] || set_stale_mtime_3h .lbwc-worktrees/02-01
  run bash "$SCRIPTS_DIR/doctor-cleanup.sh" scan
  expect_status "$label" 0
}

doctor_cleanup_stale_row() {
  local label="$1" layout="$2"
  fresh_repo
  build_layout "$layout"
  set_stale_mtime_3h .lbwc-worktrees/01-01
  run bash "$SCRIPTS_DIR/doctor-cleanup.sh" cleanup
  expect_status "$label" 0
}

unrelated_claude_process_scan() {
  plain_dir
  mkdir -p "$TEST_TEMP_DIR/bin"
  printf '#!/bin/bash\nprintf "999999 1 claude\\n"\n' > "$TEST_TEMP_DIR/bin/ps"
  chmod +x "$TEST_TEMP_DIR/bin/ps"
  run env PATH="$TEST_TEMP_DIR/bin:$PATH" bash "$SCRIPTS_DIR/doctor-cleanup.sh" scan
}

resolver_unavailable_scan() {
  local isolated_scripts="$TEST_TEMP_DIR/isolated-scripts"
  plain_dir
  mkdir -p "$isolated_scripts"
  cp "$SCRIPTS_DIR/doctor-cleanup.sh" "$isolated_scripts/doctor-cleanup.sh"
  run bash "$isolated_scripts/doctor-cleanup.sh" scan
}

@test "doctor-cleanup scan lists only stale worktrees and real orphans, and cleanup removes only a stale owned clean worktree while reporting what it keeps" {
  doctor_scan_row stale-directory stale
  expect_output_has stale-directory "stale_worktree|02-01|age: 3h"
  doctor_scan_row fresh-directory fresh
  expect_output_lacks fresh-directory "stale_worktree"
  doctor_scan_row no-worktrees-directory none
  expect_output_lacks no-worktrees-directory "stale_worktree"

  unrelated_claude_process_scan
  expect_status unrelated-claude-process 0
  expect_output_lacks unrelated-claude-process "orphan_process|999999"
  resolver_unavailable_scan
  expect_status claude-resolver-unavailable 0
  expect_output_lacks claude-resolver-unavailable "orphan_process|999999"

  doctor_cleanup_stale_row unowned-stale unowned
  expect_exists unowned-stale .lbwc-worktrees/01-01
  expect_file_has unowned-stale .lbwc-planning/.hook-errors.log "scan-only stale worktree"

  doctor_cleanup_stale_row owned-stale clean
  expect_missing owned-stale .lbwc-worktrees/01-01
  expect_file_has owned-stale .lbwc-planning/.hook-errors.log "cleaned stale worktree: 01-01"

  plain_dir
  sleep 30 &
  CHILD_PID=$!
  printf 'lbwc:%s\n' "$CHILD_PID" > .lbwc-planning/.agent-pids
  run bash "$SCRIPTS_DIR/doctor-cleanup.sh" cleanup
  expect_status live-process-record 0
  kill -0 "$CHILD_PID" || fail_case live-process-record "process $CHILD_PID was killed"
  expect_file_has live-process-record .lbwc-planning/.hook-errors.log "scan-only process record: lbwc:$CHILD_PID"
}
