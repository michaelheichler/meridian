#!/usr/bin/env bats

load test_helper
load gate_case_helper

setup() {
  setup_temp_dir
  PLANNING_ROOT="$TEST_TEMP_DIR/.meridian"
  GATE_DIR="$TEST_TEMP_DIR/gate-scripts"
  FAKE_BIN="$TEST_TEMP_DIR/fake-bin"
  cd "$TEST_TEMP_DIR"
  reset_case_failures
}

teardown() {
  cd "$PROJECT_ROOT"
  teardown_temp_dir
}

make_phase() {
  local phase_dir="$PLANNING_ROOT/phases/$1"
  mkdir -p "$phase_dir"
  touch "$phase_dir/$2-PLAN.md"
  printf '%s\n' '---' "status: $3" '---' > "$phase_dir/$2-SUMMARY.md"
}

make_gap_phase() {
  make_phase 01-partial 01-01 "$1"
  touch "$PLANNING_ROOT/phases/01-partial/01-02-PLAN.md"
}

write_commit_window() {
  [ -z "$1" ] || printf '{"qa_commit_window_seconds":%s}\n' "$1" > "$PLANNING_ROOT/config.json"
}

write_summary_utils_stub() {
  cat > "$1" <<'EOF'
#!/usr/bin/env bash
extract_summary_status() {
  awk '
    BEGIN { in_fm=0 }
    NR==1 && /^---$/ { in_fm=1; next }
    in_fm && /^---$/ { exit }
    in_fm && /^status:/ { sub(/^status:[[:space:]]*/, ""); print; exit }
  ' "$1" 2>/dev/null
}

is_summary_complete() {
  local status
  status=$(extract_summary_status "$1")
  case "$status" in complete|completed) return 0 ;; *) return 1 ;; esac
}
count_complete_summaries() {
  local dir="$1" count=0 f
  for f in "$dir/"*-SUMMARY.md "$dir/SUMMARY.md"; do
    [ -f "$f" ] || continue
    is_summary_complete "$f" && count=$((count + 1))
  done
  echo "$count"
}
count_terminal_summaries() {
  local dir="$1" count=0 f status
  for f in "$dir/"*-SUMMARY.md "$dir/SUMMARY.md"; do
    [ -f "$f" ] || continue
    status=$(extract_summary_status "$f")
    case "$status" in complete|completed|partial|failed) count=$((count + 1)) ;; esac
  done
  echo "$count"
}
EOF
}

write_phase_support_stub() {
  cat > "$1" <<'EOF'
#!/usr/bin/env bash
phase_has_passing_qa_remediation() { return 1; }
phase_execution_is_satisfied() {
  local phase_dir="$1" plan_count="$2" complete_count="$3"
  [ "$plan_count" -gt 0 ] || return 1
  [ "$complete_count" -ge "$plan_count" ] && return 0
  phase_has_passing_qa_remediation "$phase_dir"
}
EOF
}

make_support_copy() {
  local source_dir="$PROJECT_ROOT/scripts" lib_file sourced_lib
  mkdir -p "$GATE_DIR/lib"
  cp "$source_dir/qa-gate.sh" "$GATE_DIR/"
  cp "$source_dir/lib/qa-gate-decision.sh" "$GATE_DIR/lib/"
  cp "$source_dir/qa-result-gate.sh" "$GATE_DIR/"
  for lib_file in "$source_dir/lib/"qa-result-gate-*.sh; do
    cp "$lib_file" "$GATE_DIR/lib/"
  done
  while IFS= read -r sourced_lib; do
    cp "$source_dir/lib/$sourced_lib" "$GATE_DIR/lib/"
  done < <(sed -n 's|^\. "\$SCRIPT_DIR/lib/\(.*\)"$|\1|p' "$source_dir/qa-result-gate.sh")
  write_summary_utils_stub "$GATE_DIR/summary-utils.sh"
  printf '#!/usr/bin/env bash\n' > "$GATE_DIR/verification-freshness.sh"
  write_phase_support_stub "$GATE_DIR/lib/phase-detect-support.sh"
  cat > "$GATE_DIR/resolve-verification-path.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s/remediation/qa/round-01/R01-VERIFICATION.md\n' "$2"
EOF
  chmod +x "$GATE_DIR/"*.sh "$GATE_DIR/lib/"*.sh
}

make_git_log_fixture() {
  local log_line="$1"

  mkdir -p "$FAKE_BIN"
  cat > "$FAKE_BIN/date" <<'EOF'
#!/bin/bash
printf '%s\n' 1700000000
EOF
  cat > "$FAKE_BIN/git" <<EOF
#!/bin/bash
if [ "\$1" = log ]; then
  printf '%s\\n' '$log_line'
  exit 0
fi
exit 1
EOF
  chmod +x "$FAKE_BIN/date" "$FAKE_BIN/git"
}

run_summary_gap_decision() {
  run bash -c '
    . "$1"
    qa_gate_summary_gap_is_allowed "$2" "$3" "$4"
  ' _ "$PROJECT_ROOT/scripts/lib/qa-gate-decision.sh" "$1" "$2" "$3"
}

run_gate_adapter() {
  run env PATH="$FAKE_BIN:$PATH" MERIDIAN_PLANNING_DIR="$PLANNING_ROOT" bash "$GATE_DIR/qa-gate.sh" </dev/null
}

reset_gate_world() {
  rm -rf "$PLANNING_ROOT" "$GATE_DIR" "$FAKE_BIN"
}

decision_allowed() {
  run_summary_gap_decision "$2" "$3" "$4"
  expect_case_silent "$1" 0
}

decision_denied() {
  run_summary_gap_decision "$2" "$3" "$4"
  expect_case_silent "$1" 1
}

stage_gap_fixture() {
  reset_gate_world
  make_gap_phase complete
  write_commit_window "$2"
  make_support_copy
  make_git_log_fixture "$1"
}

run_gap_adapter() {
  stage_gap_fixture "$1" "$2"
  run_gate_adapter
}

gap_allowed() {
  run_gap_adapter "$2" "$3"
  expect_case_silent "$1" 0
}

gap_denied() {
  run_gap_adapter "$2" "$3"
  expect_case "$1" 2 "1 summaries for 2 plans"
}

dependency_missing() {
  reset_gate_world
  make_gap_phase partial
  make_support_copy
  rm -f "$GATE_DIR/$2"
  run_gate_adapter
  expect_case "$1" 2 "dependency load failed"
}

@test "summary-gap decision allows only a fully summarized phase or one gap with fresh conforming evidence" {
  decision_allowed no-plans-without-git 0 0 unavailable
  decision_allowed every-plan-summarized-without-git 2 2 unavailable
  decision_allowed more-summaries-than-plans 1 2 unavailable
  decision_allowed one-missing-summary-with-fresh-conforming-commit 2 1 fresh-conforming

  decision_denied git-unavailable 2 1 unavailable
  decision_denied nonconforming-git-observation 2 1 nonconforming
  decision_denied stale-git-observation 2 1 stale
  decision_denied two-missing-summaries-even-with-fresh-evidence 3 1 fresh-conforming
  decision_denied non-numeric-plan-count abc 1 fresh-conforming
  decision_denied non-numeric-summary-count 2 x1 fresh-conforming
  decision_denied empty-plan-count '' 1 fresh-conforming
  decision_denied empty-summary-count 2 '' fresh-conforming

  assert_no_case_failures
}

@test "qa-gate adapter permits one missing summary only while a conforming commit sits inside the window" {
  gap_allowed fresh-conforming-commit '1699999999 feat(01-01): active work' ''
  gap_allowed commit-exactly-at-the-default-window-edge '1699992800 feat(01-01): edge work' ''
  gap_allowed commit-older-than-default-but-inside-configured-window '1699992799 feat(01-01): old work' 10000
  gap_allowed zero-window-falls-back-to-default '1699999999 feat(01-01): active work' 0
  gap_allowed non-numeric-window-falls-back-to-default '1699999999 feat(01-01): active work' '"abc"'

  gap_denied stale-conforming-commit '1699992799 feat(01-01): old work' ''
  gap_denied future-dated-conforming-commit '1700000001 feat(01-01): active work' ''
  gap_denied nonconforming-commit-message '1699999999 wip: unrelated change' ''
  gap_denied commit-outside-shortened-window '1699999900 feat(01-01): active work' 50

  stage_gap_fixture '1699999999 feat(01-01): active work' ''
  printf '#!/bin/bash\nexit 1\n' > "$FAKE_BIN/date"
  chmod +x "$FAKE_BIN/date"
  run_gate_adapter
  expect_case current-time-unavailable 2 ""
  [ "$output" = "qa-gate: current time unavailable, cannot verify SUMMARY.md gate" ] \
    || record_case_failure current-time-unavailable-message "output=$output"

  assert_no_case_failures
}

@test "qa-gate passes clean or complete phases and fails closed on partial phases and missing dependencies" {
  rm -rf "$PLANNING_ROOT"
  run env MERIDIAN_PLANNING_DIR="$PLANNING_ROOT" bash "$PROJECT_ROOT/scripts/qa-gate.sh"
  expect_case_silent no-planning-dir 0

  reset_gate_world
  make_phase 01-complete 01-01 complete
  make_support_copy
  run_gate_adapter
  expect_case_silent fully-complete-phase 0

  reset_gate_world
  make_gap_phase partial
  make_support_copy
  run_gate_adapter
  expect_case unresolved-partial-phase 2 "0 summaries for 2 plans"

  reset_gate_world
  make_gap_phase partial
  run env MERIDIAN_PLANNING_DIR="$PLANNING_ROOT" bash "$PROJECT_ROOT/scripts/qa-gate.sh" </dev/null
  expect_case shipped-dependencies-without-git 2 "SUMMARY.md gap detected"
  [[ "$output" != *"dependency load failed"* ]] \
    || record_case_failure shipped-dependencies-load "output=$output"

  dependency_missing verification-freshness-unreadable verification-freshness.sh
  dependency_missing summary-utils-absent summary-utils.sh

  assert_no_case_failures
}
