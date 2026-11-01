#!/usr/bin/env bats

load test_helper
load agent_generator_fixture
load tmux_watchdog_fixture

OLD_BASH=/bin/bash
BASH32_ERROR_PATTERN='invalid option|bad substitution|syntax error'
FULL_RUN_ERROR_PATTERN='requires bash 4\.3|bad substitution|unbound variable|syntax error'

setup() {
  setup_temp_dir
  export CLAUDE_SESSION_ID="bash32-${BATS_TEST_NUMBER}-$$"
}

teardown() {
  cd "$PROJECT_ROOT" || true
  rm -rf "/tmp/.lbwc-phase-detect-live-${CLAUDE_SESSION_ID}.lock" "/tmp/.lbwc-plugin-root-link-${CLAUDE_SESSION_ID}"
  rm -f "/tmp/.lbwc-phase-detect-${CLAUDE_SESSION_ID}.txt" "/tmp/.lbwc-last-list-view-${CLAUDE_SESSION_ID}.json"
  unset CLAUDE_SESSION_ID
  teardown_temp_dir
}

skip_unless_old_bash() {
  local major
  major=$("$OLD_BASH" -c 'printf %s "${BASH_VERSINFO[0]}"')
  [ "$major" = 3 ] || skip "$OLD_BASH is not bash 3.x"
}

calls_bash_guard() {
  grep -Eq '^[[:space:]]*require_bash_43([[:space:]]|$)' "$1"
}

entry_scripts() {
  find "$SCRIPTS_DIR" -maxdepth 1 -name '*.sh' | sort
}

guard_callers() {
  local script
  while IFS= read -r script; do
    if calls_bash_guard "$script"; then
      basename "$script"
    fi
  done < <(entry_scripts)
}

bash32_offenders() {
  local script stderr_text status
  cd "$TEST_TEMP_DIR" || return 1
  while IFS= read -r script; do
    stderr_text=$("$OLD_BASH" "$script" --help 2>&1 >/dev/null </dev/null)
    status=$?
    if [[ "$stderr_text" =~ $BASH32_ERROR_PATTERN ]]; then
      printf '%s (exit %s): %s\n' "$(basename "$script")" "$status" "$(printf '%s' "$stderr_text" | head -n 1)"
    fi
  done < <(entry_scripts)
}

run_old_bash() {
  OLD_STATUS=0
  "$OLD_BASH" "$@" >"$TEST_TEMP_DIR/old.out" 2>"$TEST_TEMP_DIR/old.err" </dev/null || OLD_STATUS=$?
  OLD_STDOUT=$(cat "$TEST_TEMP_DIR/old.out")
  OLD_STDERR=$(cat "$TEST_TEMP_DIR/old.err")
}

case_dir() {
  mkdir -p "$TEST_TEMP_DIR/$1/.lbwc-planning"
  printf '%s\n' "$TEST_TEMP_DIR/$1"
}

report_case_failure() {
  printf 'case=%s %s\nstatus=%s\nstdout=%s\nstderr=%s\n' "$1" "$2" "$OLD_STATUS" "$OLD_STDOUT" "$OLD_STDERR" >&2
}

init_git_repo() {
  git -C "$1" init -q
  git -C "$1" config user.name tester
  git -C "$1" config user.email tester@example.invalid
}

case_phase_detect() {
  local dir
  dir=$(case_dir phase-detect)
  printf '{}\n' > "$dir/.lbwc-planning/config.json"
  cd "$dir" || return 1
  run_old_bash "$SCRIPTS_DIR/phase-detect.sh"
  [[ "$OLD_STDOUT" == *"phase_detect_complete=true"* ]] \
    || { report_case_failure phase-detect "output lacks phase_detect_complete=true"; return 1; }
}

case_qa_gate() {
  local dir
  dir=$(case_dir qa-gate)
  cd "$dir" || return 1
  run_old_bash "$SCRIPTS_DIR/qa-gate.sh"
  [ "$OLD_STATUS" -ne 3 ] || { report_case_failure qa-gate "exited 3, the old bash guard status"; return 1; }
  [[ "$OLD_STDERR" != *"dependency load failed"* ]] \
    || { report_case_failure qa-gate "a dependency failed to load"; return 1; }
}

case_verification_freshness() {
  local dir phase_dir
  dir=$(case_dir verification-freshness)
  phase_dir="$dir/.lbwc-planning/phases/01-test"
  mkdir -p "$phase_dir" "$dir/src"
  printf '%s\n' '---' 'files_modified:' '  - src/listed.txt' '---' > "$phase_dir/01-01-SUMMARY.md"
  printf 'one\n' > "$dir/src/listed.txt"
  printf 'one\n' > "$dir/src/unlisted.txt"
  init_git_repo "$dir"
  git -C "$dir" add src && git -C "$dir" commit -q -m seed
  printf 'two\n' > "$dir/src/listed.txt"
  printf 'two\n' > "$dir/src/unlisted.txt"
  run_old_bash -c 'source "$1" && cd "$2" && _freshness_working_tree_dirty "$3"' _ \
    "$SCRIPTS_DIR/verification-freshness.sh" "$dir" "$phase_dir"
  [[ "$OLD_STDOUT" == *"src/listed.txt"* ]] \
    || { report_case_failure verification-freshness "recorded path is not reported dirty"; return 1; }
  [[ "$OLD_STDOUT" != *"src/unlisted.txt"* ]] \
    || { report_case_failure verification-freshness "unrecorded path leaked into the pathspec"; return 1; }
}

case_agent_generator() {
  local dir contract
  dir=$(case_dir agent-generator)
  write_generator_fixture "$dir"
  contract=$(cd "$dir" && bash "$SCRIPTS_DIR/task-contract.sh" issue "$dir" bash32-task \
    --command test --role docs --team solo --job "write a README") || return 1
  cd "$dir" || return 1
  run_old_bash "$SCRIPTS_DIR/agent-generator.sh" docs --job "write a README" \
    --contract "$contract" --task-id "$(basename "$contract" .json)"
  [[ "$OLD_STDOUT" == *"SPAWN_READY"* ]] \
    || { report_case_failure agent-generator "output lacks SPAWN_READY"; return 1; }
}

case_render_agent_template() {
  local dir modern_sha old_sha
  local -a render_args=(web-code-critic NAME=x JOB=y MODEL=m MAX_TURNS=3 EFFORT=high)
  dir=$(case_dir render-agent-template)
  cd "$dir" || return 1
  run_old_bash "$SCRIPTS_DIR/render-agent-template.sh" "${render_args[@]}"
  [ "$OLD_STATUS" -eq 0 ] || { report_case_failure render-agent-template "render failed"; return 1; }
  [[ "$OLD_STDOUT" == "---"* ]] \
    || { report_case_failure render-agent-template "output does not start with frontmatter"; return 1; }
  old_sha=$(shasum -a 256 < "$TEST_TEMP_DIR/old.out")
  modern_sha=$(bash "$SCRIPTS_DIR/render-agent-template.sh" "${render_args[@]}" 2>/dev/null </dev/null | shasum -a 256)
  [ "$old_sha" = "$modern_sha" ] \
    || { report_case_failure render-agent-template "bash 3.2 output differs from modern bash"; return 1; }
}

case_workflow_generator() {
  run_old_bash "$SCRIPTS_DIR/workflow-generator.sh" --help
  [ "$OLD_STATUS" -eq 1 ] || { report_case_failure workflow-generator "help did not exit 1"; return 1; }
  [[ "$OLD_STDERR$OLD_STDOUT" == *"Usage:"* ]] \
    || { report_case_failure workflow-generator "output lacks Usage:"; return 1; }
}

case_render_workflow_template() {
  cd "$(case_dir render-workflow-template)" || return 1
  run_old_bash "$SCRIPTS_DIR/render-workflow-template.sh" solo NAME=n DESCRIPTION=d JOB=j TASK_ID=t ROLE=r AGENT_TYPE=a MODEL=m EFFORT=
  [ "$OLD_STATUS" -eq 0 ] || { report_case_failure render-workflow-template "render failed"; return 1; }
  [[ "$OLD_STDOUT" == "export const meta = "* ]] \
    || { report_case_failure render-workflow-template "output does not start with the meta export"; return 1; }
}

case_tmux_spawn_group() {
  cd "$(case_dir tmux-spawn-group)" || return 1
  run_old_bash "$SCRIPTS_DIR/tmux-spawn-group.sh" build-agents --names a,a --contract-id c --contract-digest d
  [ "$OLD_STATUS" -eq 1 ] || { report_case_failure tmux-spawn-group "duplicate names did not exit 1"; return 1; }
  [[ "$OLD_STDERR$OLD_STDOUT" == *"duplicate generated agent name"* ]] \
    || { report_case_failure tmux-spawn-group "duplicate name message is missing"; return 1; }
}

case_plan_import() {
  local dir="$TEST_TEMP_DIR/plan-import-project"
  mkdir -p "$dir/.lbwc-planning"
  printf '%s\n' '# Existing canonical project' > "$dir/.lbwc-planning/PROJECT.md"
  cd "$dir" || return 1
  run_old_bash "$SCRIPTS_DIR/plan-import.sh" stage --adapter gsd --source "$PROJECT_ROOT/tests/fixtures/import/gsd/.planning" \
    --project-root "$dir" --import-id import-one
  [ "$OLD_STATUS" -eq 0 ] || { report_case_failure plan-import "staging over a differing PROJECT.md failed"; return 1; }
}

case_write_verification() {
  local dir phase_dir
  dir=$(case_dir write-verification)
  phase_dir="$dir/.lbwc-planning/phases/01-verification"
  mkdir -p "$phase_dir"
  cat > "$dir/payload.json" <<'JSON'
{"phase": "01", "tier": "standard", "result": "PASS",
 "checks": {"passed": 1, "failed": 0, "total": 1},
 "checks_detail": [{"id": "must-have", "status": "PASS", "category": "must_have", "description": "The artifact exists", "evidence": "observed"}]}
JSON
  cd "$dir" || return 1
  run_old_bash -c '/bin/bash "$1" "$2" < "$3"' _ "$SCRIPTS_DIR/write-verification.sh" "$phase_dir/01-VERIFICATION.md" "$dir/payload.json"
  [ "$OLD_STATUS" -eq 0 ] || { report_case_failure write-verification "write with no plans failed"; return 1; }
}

case_debug_start_selected_todo() {
  local dir
  dir=$(case_dir debug-start)
  printf '{}\n' > "$dir/.lbwc-planning/config.json"
  printf '%s\n' '# Project State' '' '## Todos' '- Fix parser bug (added 2026-04-01)' '' '## Recent Activity' '- 2026-04-01: Existing note' \
    > "$dir/.lbwc-planning/STATE.md"
  (cd "$dir" && LBWC_PLANNING_DIR="$dir/.lbwc-planning" bash "$SCRIPTS_DIR/todo-lifecycle.sh" list-with-snapshot) >/dev/null || return 1
  cd "$dir" || return 1
  LBWC_PLANNING_DIR="$dir/.lbwc-planning" run_old_bash "$SCRIPTS_DIR/debug-start-selected-todo.sh" "$dir/.lbwc-planning" 1
  [ "$OLD_STATUS" -eq 0 ] || { report_case_failure debug-start-selected-todo "start without routing flags failed"; return 1; }
}

case_tmux_bus_watchdog() {
  local dir bin
  dir=$(case_dir tmux-bus-watchdog)
  bin="$dir/bin"
  mkdir -p "$bin"
  printf '%s\n' '#!/usr/bin/env bash' 'case "$1" in display-message) exit 0 ;; *) exit 1 ;; esac' > "$bin/tmux"
  chmod +x "$bin/tmux"
  printf '{}\n' > "$dir/.lbwc-planning/config.json"
  REPO_ROOT="$PROJECT_ROOT" CONTROL_ROOT="$dir/.lbwc-planning" fixture_watchdog_bus || return 1
  REPO_ROOT="$PROJECT_ROOT" CONTROL_ROOT="$dir/.lbwc-planning" plant_bound_agent test:0.1 '%1' || return 1
  PATH="$bin:$PATH" run_old_bash "$SCRIPTS_DIR/tmux-bus-watchdog.sh" --control-root "$dir/.lbwc-planning" check \
    --orchestrator-id main-session --orchestrator-session-id main-session --orchestrator-capability "$MAIN_CAPABILITY" \
    --stale-after-ms 1 --shutdown-timeout-ms 30
  [ "$OLD_STATUS" -eq 1 ] || { report_case_failure tmux-bus-watchdog "stale pass did not exit 1"; return 1; }
}

@test "every entry script parses and starts under bash 3.2" {
  skip_unless_old_bash
  run bash32_offenders
  [ -z "$output" ]
}

@test "no entry script calls the bash 4.3 guard" {
  run guard_callers
  [ -z "$output" ] || { echo "$output" >&2; return 1; }
}

@test "no test line opens with a bare negation that set -e never fails on" {
  run bash -c 'cd "$1" && grep -nE "^[[:space:]]*! " -- *.bats *.bash' _ "$BATS_TEST_DIRNAME"
  [ "$status" -eq 1 ] || { printf 'hollow negation at file:line\n%s\n' "$output" >&2; return 1; }
}

@test "previously guarded entry scripts complete a full run under bash 3.2" {
  skip_unless_old_bash
  local label runner
  while IFS='|' read -r label runner; do
    [ -n "$label" ] || continue
    "$runner" || return 1
    [[ ! "$OLD_STDERR" =~ $FULL_RUN_ERROR_PATTERN ]] \
      || { report_case_failure "$label" "stderr matches $FULL_RUN_ERROR_PATTERN"; return 1; }
  done <<'CASES'
phase-detect|case_phase_detect
qa-gate|case_qa_gate
verification-freshness|case_verification_freshness
agent-generator|case_agent_generator
render-agent-template|case_render_agent_template
workflow-generator|case_workflow_generator
render-workflow-template|case_render_workflow_template
tmux-spawn-group|case_tmux_spawn_group
plan-import|case_plan_import
write-verification|case_write_verification
debug-start-selected-todo|case_debug_start_selected_todo
tmux-bus-watchdog|case_tmux_bus_watchdog
CASES
}
