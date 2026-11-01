#!/usr/bin/env bats

load test_helper
load gate_case_helper
load gate_case_files

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  DOCTOR="$REPO_ROOT/commands/doctor.md"
  CLEANUP="$REPO_ROOT/scripts/doctor-cleanup.sh"
  TEST_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
  PLUGIN_ROOT="$TEST_ROOT/plugin"
  PLUGIN_SCRIPTS="$PLUGIN_ROOT/scripts"
  PROJECT_ROOT="$TEST_ROOT/project"
  FAKE_BIN="$TEST_ROOT/bin"
  COMMAND_SESSION_ID="doctor-${BATS_TEST_NUMBER}-$$"
  ROOT_LINK="/tmp/.lbwc-plugin-root-link-${COMMAND_SESSION_ID}"
  CONTROL_ROOT="$PROJECT_ROOT/.lbwc-planning"
  DOCTOR_HELPER="$REPO_ROOT/scripts/tmux-doctor.sh"
  reset_case_failures
  mkdir -p "$PLUGIN_SCRIPTS/lib" "$PROJECT_ROOT/.lbwc-planning" "$FAKE_BIN"
  printf '%s\n' '{}' > "$PROJECT_ROOT/.lbwc-planning/config.json"
  cp "$REPO_ROOT/scripts/ensure-plugin-root-link.sh" "$PLUGIN_SCRIPTS/ensure-plugin-root-link.sh"
  cp "$REPO_ROOT/scripts/resolve-plugin-root.sh" "$PLUGIN_SCRIPTS/resolve-plugin-root.sh"
  cp "$REPO_ROOT/scripts/tmux-preflight.sh" "$PLUGIN_SCRIPTS/tmux-preflight.sh"
  cp "$REPO_ROOT/scripts/tmux-session-name.sh" "$PLUGIN_SCRIPTS/tmux-session-name.sh"
  copy_script_with_libs "$REPO_ROOT/scripts/lib/lbwc-control-root.sh" "$PLUGIN_SCRIPTS/lib/lbwc-control-root.sh"
  cp "$REPO_ROOT/scripts/lib/lbwc-target-root.sh" "$PLUGIN_SCRIPTS/lib/lbwc-target-root.sh"
  cp "$REPO_ROOT/scripts/lib/tmux-private-fs.py" "$PLUGIN_SCRIPTS/lib/tmux-private-fs.py"
  write_default_fakes "$FAKE_BIN"
  rm -rf "$ROOT_LINK"
}

teardown() {
  rm -rf "$TEST_ROOT" "$ROOT_LINK"
}

write_default_fakes() {
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$1/claude"
  printf '%s\n' '#!/usr/bin/env bash' 'case "$1" in' "  -V) printf '%s\\n' 'tmux 3.4' ;;" \
    '  has-session) exit 1 ;;' '  *) exit 1 ;;' 'esac' > "$1/tmux"
  chmod +x "$1/claude" "$1/tmux"
}

new_tmux_row() {
  PROJECT_ROOT="$TEST_ROOT/rows/$1/project"
  CONTROL_ROOT="$PROJECT_ROOT/.lbwc-planning"
  FAKE_BIN="$TEST_ROOT/rows/$1/bin"
  mkdir -p "$CONTROL_ROOT" "$FAKE_BIN"
  printf '%s\n' '{}' > "$CONTROL_ROOT/config.json"
  write_default_fakes "$FAKE_BIN"
}

resolve_doctor_context() {
  local directive
  directive="$(awk '/^!`/{sub(/^!`/,""); sub(/`$/,""); print; exit}' "$DOCTOR")"
  [ -n "$directive" ] || return 1

  run env -u LINK -u PROJECT_ROOT \
    CLAUDE_SESSION_ID="$COMMAND_SESSION_ID" \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    bash -c "cd \"$PROJECT_ROOT\" && $directive"
  [ "$status" -eq 0 ] || return "$status"

  RESOLVED_LINK="$(printf '%s\n' "$output" | awk -F': ' '/^Plugin root: /{print $2; exit}')"
  RESOLVED_PROJECT_ROOT="$(printf '%s\n' "$output" | awk -F': ' '/^Project root: /{print $2; exit}')"
  [ "$RESOLVED_LINK" = "$PLUGIN_ROOT" ]
  [ "$RESOLVED_PROJECT_ROOT" = "$PROJECT_ROOT" ]
}

run_resolved_preflight() {
  local preflight
  resolve_doctor_context || return $?
  preflight="$(sed -n 's/.*run `\(bash "{LINK}\/scripts\/tmux-preflight\.sh"[^`]*\)`.*/\1/p' "$DOCTOR")"
  [ -n "$preflight" ] || return 1
  preflight="${preflight//\{LINK\}/$RESOLVED_LINK}"
  preflight="${preflight//\{PROJECT_ROOT\}/$RESOLVED_PROJECT_ROOT}"
  [[ "$preflight" != *'{LINK}'* ]] || return 1
  [[ "$preflight" != *'{PROJECT_ROOT}'* ]] || return 1
  [[ "$preflight" != *'{project-root}'* ]] || return 1

  run env \
    PATH="$FAKE_BIN:$PATH" \
    CLAUDE_SESSION_ID="$COMMAND_SESSION_ID" \
    bash -c "cd \"$PROJECT_ROOT\" && $preflight"
}

run_tmux_doctor() {
  run env PATH="$FAKE_BIN:$PATH" bash "$DOCTOR_HELPER" \
    --project-root "$PROJECT_ROOT" \
    --control-root "$CONTROL_ROOT"
}

source_runtime() {
  source "$REPO_ROOT/scripts/lib/lbwc-control-root.sh"
  source "$REPO_ROOT/scripts/lib/tmux-runtime.sh"
  tmux_runtime_configure "$CONTROL_ROOT"
}

ensure_bus_layout() {
  tmux_runtime_ensure
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/inboxes"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/outbox"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/outbox/main"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/transactions"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/claims"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/credentials"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/heartbeats"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/locks"
}

plant_healthy_runtime() {
  local hash registry
  source_runtime
  ensure_bus_layout
  jq -n '{agent_execution_mode:"tmux",tmux_execution:{enabled:true,heartbeat_stale_seconds:120}}' > "$CONTROL_ROOT/config.json"
  hash=$(tmux_runtime_capability_hash "$(tmux_runtime_capability)")
  registry=$(jq -n --arg hash "$hash" '{
    schema_version: 2,
    main: {agent_id:"main-session",session_id:"main-session",role:"orchestrator",capability_hash:$hash},
    tmux: {session:"lbwc-main",orchestrator_target:"lbwc-main:0.0",orchestrator_pane:"0",topology:"detached-new-session",managed_session:true,ownership_token:"owned"},
    agents: [{
      agent_id:"agent-a",
      parent_id:"main-session",
      contract_id:"contract-a",
      generated_name:"agent-a",
      tmux_target:"lbwc-main:0.1",
      tmux_pane_id:"%1",
      claude_session_id:"session-a",
      capability_hash:("1" * 64),
      state:"running",
      heartbeat_at_ms:2000000000000
    }],
    routes: {
      "main-session": {inbox:"main-session",tmux_target:"lbwc-main:0.0"},
      "agent-a": {inbox:"agent-a",tmux_target:"lbwc-main:0.1"}
    }
  }')
  tmux_runtime_write_registry_route_bundle "$registry"
  cat > "$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  has-session) [ "$3" = lbwc-main ] && exit 0; exit 1 ;;
  display-message)
    grep -qxF -- "$4" "$(dirname "$0")/gone-panes" 2>/dev/null && exit 0
    printf '%%1\n'
    exit 0 ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$FAKE_BIN/tmux"
}

runtime_checksums() {
  find "$CONTROL_ROOT/.runtime" -type f -exec cksum {} \; | sort
}

@test "doctor command document keeps its output contract, diagnostics and cleanup boundaries" {
  local fragment
  while IFS= read -r fragment; do
    [ -n "$fragment" ] || continue
    grep -qF -- "$fragment" "$DOCTOR" || record_case_failure "doctor-md" "missing fragment=[$fragment]"
  done <<'FRAGMENTS'
Result: {N}/20 passed, {W} warnings, {F} failures
  20. Temporary runs       {PASS|WARN|FAIL} {detail}
Runtime diagnostics
tmux-doctor.sh
execution backend
tmux session and pane health
agent lifecycle counts
malformed registry
malformed route
missing tmux
stale heartbeat
read-only
Run `/lbwc:doctor --cleanup`
tmux-preflight.sh
tmux-bus.sh
does not authorize cleanup
Never remove registry, route, lock, claim, pane, or session state
FRAGMENTS

  assert_no_case_failures
}

@test "tmux-doctor reports runtime health from the registry without mutating state" {
  local before after

  new_tmux_row missing-runtime
  run_tmux_doctor
  expect_case "missing-runtime" 0 ""
  expect_jq_output "missing-runtime-status" '.status == "PASS" and .detail == "no tmux runtime"'
  expect_no_path "missing-runtime-no-bus-state" "$CONTROL_ROOT/.runtime"

  new_tmux_row malformed-registry
  source_runtime
  ensure_bus_layout
  python3 "$REPO_ROOT/scripts/lib/tmux-private-fs.py" write-json \
    --root "$TMUX_RUNTIME_BUS_ROOT" --relative registry.json --document '{"nope":true}'
  before=$(cksum "$TMUX_RUNTIME_BUS_ROOT/registry.json")
  run_tmux_doctor
  expect_case "malformed-registry" 0 ""
  expect_jq_output "malformed-registry-status" '.status == "FAIL" and .detail == "malformed registry"'
  after=$(cksum "$TMUX_RUNTIME_BUS_ROOT/registry.json")
  [ "$after" = "$before" ] || record_case_failure "malformed-registry-untouched" "registry changed"

  new_tmux_row healthy
  plant_healthy_runtime
  before=$(runtime_checksums)
  run_tmux_doctor
  expect_case "healthy" 0 ""
  expect_jq_output "healthy-detail" '.status == "PASS" and .detail == "backend=tmux session=lbwc-main panes=2/2 agents=1 running:1 idle:0 failed:0 heartbeats=fresh"'
  after=$(runtime_checksums)
  [ "$after" = "$before" ] || record_case_failure "healthy-untouched" "runtime files changed"

  new_tmux_row gone-pane
  plant_healthy_runtime
  printf '%s\n' '%1' > "$FAKE_BIN/gone-panes"
  run_tmux_doctor
  expect_case "gone-pane" 0 ""
  expect_jq_output "gone-pane-warns" '.status == "WARN" and (.detail | contains("missing pane: %1"))'

  new_tmux_row shutdown-agent
  plant_healthy_runtime
  tmux_runtime_write_registry_route_bundle "$(jq '
    .agents |= map(if .agent_id == "agent-a" then .state = "shutdown" else . end)
    | .routes |= del(.["agent-a"])
  ' "$CONTROL_ROOT/.runtime/tmux-bus/registry.json")"
  run_tmux_doctor
  expect_case "shutdown-agent" 0 ""
  expect_jq_output "shutdown-agent-detail" '.status == "PASS" and .detail == "backend=tmux session=lbwc-main panes=1/1 agents=1 running:0 idle:0 failed:0 heartbeats=fresh"'

  new_tmux_row workflow-backend
  plant_healthy_runtime
  jq '.agent_execution_mode = "workflow"' "$CONTROL_ROOT/config.json" > "$CONTROL_ROOT/config.json.tmp"
  mv "$CONTROL_ROOT/config.json.tmp" "$CONTROL_ROOT/config.json"
  run_tmux_doctor
  expect_case "workflow-backend" 0 ""
  expect_jq_output "workflow-backend-name" '.status == "PASS" and (.detail | startswith("backend=workflow "))'

  assert_no_case_failures
}

@test "doctor resolves the unavailable-runtime preflight helper before invoking it" {
  run grep -c '^!`' "$DOCTOR"
  expect_case "single-directive" 0 "1"
  [ "$output" -eq 1 ] || record_case_failure "single-directive-count" "directive count=$output"

  run_resolved_preflight

  expect_case "preflight" 0 '"preflight": "passed"'
  [ "$RESOLVED_LINK" = "$PLUGIN_ROOT" ] || record_case_failure "resolved-link" "link=$RESOLVED_LINK"
  [ "$RESOLVED_PROJECT_ROOT" = "$PROJECT_ROOT" ] || record_case_failure "resolved-project" "root=$RESOLVED_PROJECT_ROOT"
  assert_no_case_failures
}

cleanup_world() {
  WORLD="$TEST_ROOT/worlds/$1"
  W_PROJECT="$WORLD/project"
  W_PLANNING="$W_PROJECT/.lbwc-planning"
  W_CLAUDE="$WORLD/claude"
  mkdir -p "$W_PLANNING" "$W_CLAUDE/teams" "$W_CLAUDE/tasks" "$WORLD/home"
}

run_cleanup() {
  local action=$1
  run env HOME="$WORLD/home" CLAUDE_CONFIG_DIR="$W_CLAUDE" LBWC_PLANNING_DIR="$W_PLANNING" \
    bash -c 'cd "$1" && bash "$2" "$3"' _ "$W_PROJECT" "${CLEANUP_SCRIPT:-$CLEANUP}" "$action"
}

touch_ago() {
  local file=$1 seconds=$2 epoch stamp
  epoch=$(( $(date +%s) - seconds ))
  stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$epoch" +%Y%m%d%H%M.%S)
  touch -t "$stamp" "$file"
}

make_team() {
  local name=$1 kind=$2
  mkdir -p "$W_CLAUDE/teams/$name"
  case "$kind" in
    stale)
      printf '%s\n' '{}' > "$W_CLAUDE/teams/$name/config.json"
      mkdir -p "$W_CLAUDE/teams/$name/inboxes"
      printf '%s\n' x > "$W_CLAUDE/teams/$name/inboxes/a.json"
      touch -t 202001010000 "$W_CLAUDE/teams/$name/inboxes/a.json"
      ;;
    fresh)
      printf '%s\n' '{}' > "$W_CLAUDE/teams/$name/config.json"
      mkdir -p "$W_CLAUDE/teams/$name/inboxes"
      printf '%s\n' x > "$W_CLAUDE/teams/$name/inboxes/a.json"
      ;;
    noinbox)
      printf '%s\n' '{}' > "$W_CLAUDE/teams/$name/config.json"
      ;;
  esac
}

@test "doctor-cleanup scan reports stale teams, process records, markers and temporary runs" {
  local runs

  cleanup_world empty
  run_cleanup scan
  expect_case_silent "nothing-to-report" 0

  cleanup_world ghost-team
  make_team lbwc-ghost ghost
  mkdir -p "$W_CLAUDE/tasks/lbwc-ghost" "$W_CLAUDE/teams/other-ghost"
  run_cleanup scan
  expect_case "ghost-team" 0 "orphaned_team|lbwc-ghost|no config.json (ghost team residual)"
  expect_output_has "ghost-team-tasks" "orphaned_tasks|lbwc-ghost|paired tasks dir"
  expect_output_lacks "ghost-team-ignores-foreign" "other-ghost"

  cleanup_world stale-team
  make_team lbwc-old stale
  make_team lbwc-new fresh
  make_team lbwc-bare noinbox
  make_team other-old stale
  mkdir -p "$W_CLAUDE/tasks/lbwc-old"
  run_cleanup scan
  expect_case "stale-team" 0 "stale_team|lbwc-old|age: "
  expect_output_has "stale-team-tasks" "stale_tasks|lbwc-old|paired tasks dir"
  expect_output_lacks "stale-team-fresh-skipped" "lbwc-new"
  expect_output_lacks "stale-team-no-inbox-skipped" "lbwc-bare"
  expect_output_lacks "stale-team-foreign-skipped" "other-old"

  cleanup_world process-records
  printf '%s\n%s\n' 'lbwc:4242' 'lbwc:4343' > "$W_PLANNING/.agent-pids"
  run_cleanup scan
  expect_case "process-records" 0 "process_record|lbwc:4242|scan-only"
  expect_output_has "process-records-second" "process_record|lbwc:4343|scan-only"

  cleanup_world dead-watchdog
  printf '%s\n' 999999 > "$W_PLANNING/.watchdog-pid"
  run_cleanup scan
  expect_case "dead-watchdog" 0 "stale_marker|.watchdog-pid|dead process"

  cleanup_world live-watchdog
  printf '%s\n' "$$" > "$W_PLANNING/.watchdog-pid"
  run_cleanup scan
  expect_case_silent "live-watchdog" 0

  cleanup_world old-compaction
  printf '%s\n' x > "$W_PLANNING/.compaction-marker"
  touch -t 202001010000 "$W_PLANNING/.compaction-marker"
  run_cleanup scan
  expect_case "old-compaction" 0 "stale_marker|.compaction-marker|age: "

  cleanup_world two-minute-compaction
  printf '%s\n' x > "$W_PLANNING/.compaction-marker"
  touch_ago "$W_PLANNING/.compaction-marker" 120
  run_cleanup scan
  expect_case "two-minute-compaction" 0 "stale_marker|.compaction-marker|age: 12"

  cleanup_world fresh-compaction
  printf '%s\n' x > "$W_PLANNING/.compaction-marker"
  touch_ago "$W_PLANNING/.compaction-marker" 30
  run_cleanup scan
  expect_case_silent "fresh-compaction" 0

  cleanup_world orphan-active-agent
  printf '%s\n' x > "$W_PLANNING/.active-agent"
  run_cleanup scan
  expect_case "orphan-active-agent" 0 "stale_marker|.active-agent|potentially stale"

  cleanup_world tracked-active-agent
  printf '%s\n' x > "$W_PLANNING/.active-agent"
  mkdir -p "$W_PLANNING/.active-agents"
  run_cleanup scan
  expect_case_silent "tracked-active-agent" 0

  cleanup_world temporary-runs
  runs="$W_PROJECT/.temporary-agent-runfiles/runs"
  mkdir -p "$runs/done-old" "$runs/busy" "$runs/broken"
  printf '%s\n' '{"status":"completed","updated_at":"2020-01-01T00:00:00Z"}' > "$runs/done-old/run.json"
  printf '%s\n' '{"status":"running"}' > "$runs/busy/run.json"
  run_cleanup scan
  expect_case "temporary-runs" 0 "temporary_run_terminal|done-old|status: completed"
  expect_output_has "temporary-runs-active" "temporary_run_active|busy|status: running"
  expect_output_has "temporary-runs-unreadable" "temporary_run_unreadable|broken|missing or linked run.json"

  assert_no_case_failures
}

@test "doctor-cleanup cleanup removes only stale state and logs each action" {
  local log runs

  cleanup_world markers
  log="$W_PLANNING/.hook-errors.log"
  printf '%s\n' 999999 > "$W_PLANNING/.watchdog-pid"
  printf '%s\n' x > "$W_PLANNING/.compaction-marker"
  touch -t 202001010000 "$W_PLANNING/.compaction-marker"
  printf '%s\n' x > "$W_PLANNING/.active-agent"
  run_cleanup cleanup
  expect_status "stale-markers" 0
  expect_no_path "stale-watchdog-removed" "$W_PLANNING/.watchdog-pid"
  expect_no_path "stale-compaction-removed" "$W_PLANNING/.compaction-marker"
  expect_no_path "orphan-active-agent-removed" "$W_PLANNING/.active-agent"
  expect_file_line "log-started" "$log" 'Doctor cleanup: cleanup started'
  expect_file_line "log-watchdog" "$log" 'removed stale marker: .watchdog-pid'
  expect_file_line "log-marker-total" "$log" 'stale markers cleanup completed: 3 removed'
  expect_file_line "log-summary" "$log" 'cleanup complete: teams=0, process_records=0, markers=3, worktrees=0, temporary_runs=0'

  cleanup_world kept-markers
  log="$W_PLANNING/.hook-errors.log"
  printf '%s\n' "$$" > "$W_PLANNING/.watchdog-pid"
  printf '%s\n' x > "$W_PLANNING/.compaction-marker"
  printf '%s\n' x > "$W_PLANNING/.active-agent"
  mkdir -p "$W_PLANNING/.active-agents"
  run_cleanup cleanup
  expect_status "live-markers" 0
  expect_path "live-watchdog-kept" "$W_PLANNING/.watchdog-pid"
  expect_path "fresh-compaction-kept" "$W_PLANNING/.compaction-marker"
  expect_path "tracked-active-agent-kept" "$W_PLANNING/.active-agent"
  expect_file_line "log-no-removals" "$log" 'stale markers cleanup completed: 0 removed'

  cleanup_world teams
  log="$W_PLANNING/.hook-errors.log"
  make_team lbwc-ghost ghost
  make_team lbwc-old stale
  make_team lbwc-new fresh
  make_team other-old stale
  mkdir -p "$W_CLAUDE/tasks/lbwc-ghost" "$W_CLAUDE/tasks/lbwc-old"
  run_cleanup cleanup
  expect_status "stale-teams" 0
  expect_no_path "ghost-team-removed" "$W_CLAUDE/teams/lbwc-ghost"
  expect_no_path "stale-team-removed" "$W_CLAUDE/teams/lbwc-old"
  expect_no_path "paired-tasks-removed" "$W_CLAUDE/tasks/lbwc-old"
  expect_path "fresh-team-kept" "$W_CLAUDE/teams/lbwc-new"
  expect_path "foreign-team-kept" "$W_CLAUDE/teams/other-old"
  expect_file_line "log-team-removed" "$log" 'Removed stale team: lbwc-old'
  expect_file_line "log-teams-done" "$log" 'stale teams cleanup completed'
  expect_file_line "log-team-count" "$log" 'cleanup complete: teams=4,'

  cleanup_world process-and-runs
  log="$W_PLANNING/.hook-errors.log"
  printf '%s\n' 'lbwc:4242' > "$W_PLANNING/.agent-pids"
  runs="$W_PROJECT/.temporary-agent-runfiles/runs"
  mkdir -p "$runs/done-old" "$runs/busy"
  printf '%s\n' '{"status":"completed","updated_at":"2020-01-01T00:00:00Z"}' > "$runs/done-old/run.json"
  printf '%s\n' '{"status":"running"}' > "$runs/busy/run.json"
  run_cleanup cleanup
  expect_status "process-and-runs" 0
  expect_file_line "log-process-record" "$log" 'scan-only process record: lbwc:4242'
  expect_no_path "terminal-run-removed" "$runs/done-old"
  expect_path "active-run-kept" "$runs/busy"
  expect_file_line "log-run-removed" "$log" 'temporary_run_removed|done-old'
  expect_file_line "log-run-summary" "$log" 'process_records=1, markers=0, worktrees=0, temporary_runs=2'

  assert_no_case_failures
}

@test "doctor-cleanup rejects unknown actions and degrades without optional helpers" {
  local isolated script_path

  cleanup_world usage
  run_cleanup bogus
  expect_case "unknown-action" 1 "Usage:"

  cleanup_world no-team-helper
  isolated="$WORLD/isolated-scripts"
  mkdir -p "$isolated"
  while IFS= read -r script_path; do
    ln -sf "$script_path" "$isolated/$(basename "$script_path")"
  done < <(find "$REPO_ROOT/scripts" -maxdepth 1 -type f -name '*.sh')
  ln -sfn "$REPO_ROOT/scripts/lib" "$isolated/lib"
  rm -f "$isolated/clean-stale-teams.sh"
  make_team lbwc-ghost ghost
  CLEANUP_SCRIPT="$isolated/doctor-cleanup.sh" run_cleanup cleanup
  expect_status "team-helper-missing" 0
  expect_file_line "team-helper-skip-logged" "$W_PLANNING/.hook-errors.log" 'skipped stale teams cleanup: helper unavailable'
  expect_path "team-kept-without-helper" "$W_CLAUDE/teams/lbwc-ghost"

  cleanup_world no-run-helper
  mkdir -p "$W_PROJECT/.temporary-agent-runfiles/runs/busy"
  rm -f "$isolated/cleanup-temporary-agent-runfiles.sh"
  CLEANUP_SCRIPT="$isolated/doctor-cleanup.sh" run_cleanup scan
  expect_case_silent "run-helper-missing-scan" 0

  assert_no_case_failures
}
