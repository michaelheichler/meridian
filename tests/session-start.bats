#!/usr/bin/env bats

setup() {
  unset TMUX TMUX_PANE
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/session-start.sh"
  TEST_ROOT="$(mktemp -d)"
  PLANNING_DIR="$TEST_ROOT/.lbwc-planning"
  export CLAUDE_SESSION_ID="session-start-${BATS_TEST_NUMBER}-$$"
  ROOT_LINK="/tmp/.lbwc-plugin-root-link-${CLAUDE_SESSION_ID}"
  rm -rf "$ROOT_LINK"
  CONCURRENT_LINK="/tmp/.lbwc-plugin-root-link-concurrent-child-session"
  WORKDIR="$TEST_ROOT/project"
  mkdir -p "$WORKDIR"
  git -C "$WORKDIR" init -q
  cd "$WORKDIR"
}

teardown() {
  cd "$BATS_TEST_DIRNAME"
  rm -rf "$TEST_ROOT" "$ROOT_LINK" "$CONCURRENT_LINK"
  unset CLAUDE_SESSION_ID
  [ ! -L "$REPO_ROOT/lbwc" ] || { rm -f "$REPO_ROOT/lbwc"; return 1; }
}

run_session_start() {
  (
    cd "$WORKDIR"
    LBWC_PLANNING_DIR="$PLANNING_DIR" bash "$SCRIPT" </dev/null
  )
}

run_session_start_from() {
  local script_dir="$1"
  (
    cd "$WORKDIR"
    LBWC_PLANNING_DIR="$PLANNING_DIR" bash "$script_dir/session-start.sh" </dev/null
  )
}

run_session_start_with_input() {
  local input="$1"
  (
    cd "$WORKDIR"
    printf '%s' "$input" | LBWC_PLANNING_DIR="$PLANNING_DIR" bash "$SCRIPT"
  )
}

copy_scripts_to() {
  local dest="$1"
  rm -rf "$dest"
  mkdir -p "$(dirname "$dest")"
  cp -R "$REPO_ROOT/scripts" "$dest"
}

replace_script_in_copy() {
  local dest="$1" name="$2" body="$3"
  printf '%s\n' '#!/usr/bin/env bash' "$body" > "$dest/$name"
  chmod +x "$dest/$name"
}

write_project_md() {
  mkdir -p "$PLANNING_DIR"
  printf 'A real project description.\n' > "$PLANNING_DIR/PROJECT.md"
}

seed_compaction_count() {
  mkdir -p "$PLANNING_DIR"
  printf '%s\n' "$1" > "$PLANNING_DIR/.compaction-count"
}

read_compaction_count() {
  cat "$PLANNING_DIR/.compaction-count"
}

SHIM_DIR=""

prepare_cold_start() { :; }

prepare_warm_start() { write_project_md; }

prepare_phase_needing_plan() {
  write_project_md
  mkdir -p "$PLANNING_DIR/phases/01-test"
}

prepare_phase_needing_discussion() {
  prepare_phase_needing_plan
  printf '# Roadmap\n\n### Phase 01: Test\n\n| Phase | Status |\n| 01 | pending |\n' > "$PLANNING_DIR/ROADMAP.md"
  printf '{"require_phase_discussion": true}\n' > "$PLANNING_DIR/config.json"
}

prepare_phase_detect_setup_failure() {
  SHIM_DIR="$TEST_ROOT/scripts-shim"
  copy_scripts_to "$SHIM_DIR"
  replace_script_in_copy "$SHIM_DIR" phase-detect.sh \
    "printf '%s\n' 'phase_detect_error=true' 'phase_detect_reason=setup_failed'; exit 1"
}

prepare_malformed_manifest() {
  write_project_md
  printf '{not valid json\n' > "$PLANNING_DIR/.agent-manifest.json"
}

prepare_unavailable_manifest() {
  SHIM_DIR="$TEST_ROOT/scripts-shim"
  copy_scripts_to "$SHIM_DIR"
  replace_script_in_copy "$SHIM_DIR" agent-lifecycle.sh \
    "printf '%s\n' 'agent_manifest_status=unavailable'; exit 1"
}

assert_context_fragments() {
  local label="$1" expected="$2" absent="$3" fragment
  local -a fragments=()
  jq -e '.hookSpecificOutput.additionalContext | type == "string"' <<<"$output" >/dev/null \
    || { echo "case=$label output is not a SessionStart hook document: $output" >&2; return 1; }
  IFS='~' read -r -a fragments <<<"$expected"
  for fragment in "${fragments[@]}"; do
    [[ "$output" == *"$fragment"* ]] || { echo "case=$label missing=[$fragment] output=$output" >&2; return 1; }
  done
  [ -z "$absent" ] || [[ "$output" != *"$absent"* ]] \
    || { echo "case=$label unexpected=[$absent] output=$output" >&2; return 1; }
}

@test "session-start fails clearly when a required root link cannot be created" {
  local plugin_root="$TEST_ROOT/plugin"
  copy_scripts_to "$plugin_root/scripts"
  replace_script_in_copy "$plugin_root/scripts" ensure-plugin-root-link.sh 'exit 1'

  run run_session_start_from "$plugin_root/scripts"

  [ "$status" -eq 1 ]
  [[ "$output" == *"LBWC: SessionStart plugin root link bootstrap failed"* ]]
}

@test "session-start creates the exact session plugin root link" {
  local canonical_root
  canonical_root=$(cd "$REPO_ROOT" && pwd -P)

  run run_session_start

  [ "$status" -eq 0 ]
  [ -L "$ROOT_LINK" ]
  [ "$(readlink "$ROOT_LINK")" = "$canonical_root" ]
}

@test "session-start persists unset CDPATH to CLAUDE_ENV_FILE exactly once across runs" {
  export CLAUDE_ENV_FILE="$TEST_ROOT/claude-env"
  : > "$CLAUDE_ENV_FILE"

  run run_session_start
  [ "$status" -eq 0 ]
  run run_session_start
  [ "$status" -eq 0 ]

  [ "$(grep -cxF 'unset CDPATH' "$CLAUDE_ENV_FILE")" -eq 1 ]
}

@test "session-start still succeeds when CLAUDE_ENV_FILE is not writable" {
  export CLAUDE_ENV_FILE="$TEST_ROOT/claude-env"
  printf 'export KEEP=1\n' > "$CLAUDE_ENV_FILE"
  chmod 444 "$CLAUDE_ENV_FILE"

  run run_session_start

  [ "$status" -eq 0 ]
  [ "$(cat "$CLAUDE_ENV_FILE")" = 'export KEEP=1' ]
}

@test "session-start context reflects planning and subsystem state" {
  local label prepare expected absent
  while IFS='|' read -r label prepare expected absent; do
    [ -n "$label" ] || continue
    rm -rf "$PLANNING_DIR" "$TEST_ROOT/scripts-shim"
    SHIM_DIR=""
    "$prepare"

    if [ -n "$SHIM_DIR" ]; then
      run run_session_start_from "$SHIM_DIR"
    else
      run run_session_start
    fi

    [ "$status" -eq 0 ] || { echo "case=$label status=$status output=$output" >&2; return 1; }
    assert_context_fragments "$label" "$expected" "$absent"
  done <<CASES
cold-start-reports-init-needed|prepare_cold_start|no ${PLANNING_DIR}/ directory found|
warm-start-reports-phase-brief|prepare_warm_start|lbwc phase|
phase-needing-plan-routes-to-plan|prepare_phase_needing_plan|missing PLAN.md~/plan 01|
phase-needing-discussion-routes-to-discuss|prepare_phase_needing_discussion|missing CONTEXT.md~/discuss 01|/plan 01
phase-setup-failure-is-unavailable-not-missing|prepare_phase_detect_setup_failure|lbwc: phase status unavailable (setup_failed).|no ${PLANNING_DIR}/ directory found
malformed-agent-manifest-surfaces|prepare_malformed_manifest|lbwc: agent manifest status malformed.|
unavailable-agent-manifest-surfaces|prepare_unavailable_manifest|lbwc: agent manifest status unavailable.|
CASES
}

@test "session-start applies the source-specific compaction count policy" {
  local label input expected
  while IFS='|' read -r label input expected; do
    [ -n "$label" ] || continue
    rm -rf "$PLANNING_DIR"
    seed_compaction_count 5

    run run_session_start_with_input "$input"

    [ "$status" -eq 0 ] || { echo "case=$label status=$status output=$output" >&2; return 1; }
    [ "$(read_compaction_count)" = "$expected" ] \
      || { echo "case=$label expected=$expected actual=$(read_compaction_count)" >&2; return 1; }
  done <<'CASES'
startup-resets-stale-count|{"source":"startup"}|0
clear-resets-stale-count|{"source":"clear"}|0
compact-keeps-count|{"source":"compact"}|5
resume-keeps-count|{"source":"resume"}|5
empty-stdin-keeps-count||5
CASES
}

@test "session-start: a startup session without a planning dir creates nothing" {
  run run_session_start_with_input '{"source":"startup"}'

  [ "$status" -eq 0 ]
  [ ! -e "$PLANNING_DIR" ]
}

@test "session-start: a fresh session after a near-limit run does not trip the compaction loop stop" {
  seed_compaction_count 9

  run run_session_start_with_input '{"source":"startup"}'
  [ "$status" -eq 0 ]

  run env LBWC_PLANNING_DIR="$PLANNING_DIR" bash -c 'printf "%s" "{\"matcher\":\"auto\"}" | bash "$1"' _ "$REPO_ROOT/scripts/compaction-instructions.sh"

  [ "$status" -eq 0 ]
  [[ "$output" != *"COMPACTION LOOP DETECTED"* ]]
  [ "$(read_compaction_count)" = "1" ]
}

fixture_session_bus() {
  local control_root="$1" hash registry
  source "$REPO_ROOT/scripts/lib/lbwc-control-root.sh"
  source "$REPO_ROOT/scripts/lib/tmux-runtime.sh"
  tmux_runtime_configure "$control_root"
  tmux_runtime_ensure
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/inboxes"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/outbox"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/outbox/main"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/transactions"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/claims"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/credentials"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/heartbeats"
  tmux_runtime_private_directory "$TMUX_RUNTIME_BUS_ROOT/locks"
  MAIN_CAPABILITY=$(tmux_runtime_capability)
  hash=$(tmux_runtime_capability_hash "$MAIN_CAPABILITY")
  registry=$(jq -n --arg main main-session --arg hash "$hash" '{
    schema_version: 2,
    main: {agent_id: $main, session_id: $main, role: "orchestrator", capability_hash: $hash},
    tmux: {session: null, orchestrator_target: null, orchestrator_pane: null, topology: "pending", managed_session: false, ownership_token: null},
    agents: [],
    routes: {($main): {inbox: $main, tmux_target: null}}
  }')
  tmux_runtime_write_registry_route_bundle "$registry"
  tmux_runtime_initialize_inbox main-session
}

plant_unbound_agent() {
  local agent_id="$1" capability="$2" hash registry updated
  hash=$(tmux_runtime_capability_hash "$capability")
  registry=$(tmux_runtime_registry_read)
  updated=$(jq --arg id "$agent_id" --arg hash "$hash" '
    .agents += [{
      agent_id: $id, parent_id: .main.agent_id, contract_id: "contract-a", generated_name: $id,
      tmux_target: "lbwc-test-main:0.1", tmux_pane_id: null, claude_session_id: null,
      capability_hash: $hash, state: "registered", heartbeat_at_ms: null
    }]
    | .routes[$id] = {inbox: $id, tmux_target: "lbwc-test-main:0.1"}
  ' <<<"$registry")
  tmux_runtime_write_registry_route_bundle "$updated"
  tmux_runtime_initialize_inbox "$agent_id"
}

write_credential() {
  local agent_id="$1" capability="$2"
  jq -n --arg agent_id "$agent_id" --arg contract_id contract-a --arg capability "$capability" '{agent_id:$agent_id,contract_id:$contract_id,capability:$capability}' > "$TEST_ROOT/credential.json"
  python3 "$REPO_ROOT/scripts/lib/tmux-private-fs.py" write-json --root "$TMUX_RUNTIME_BUS_ROOT" --relative "credentials/$agent_id.json" --document "$(cat "$TEST_ROOT/credential.json")"
}

prepare_bound_agent() {
  BOUND_CONTROL_ROOT="$TEST_ROOT/tmux-project/.lbwc-planning"
  BOUND_CAPABILITY='0123456789abcdef0123456789abcdef'
  rm -rf "$TEST_ROOT/tmux-project"
  mkdir -p "$BOUND_CONTROL_ROOT"
  printf '%s\n' '{}' > "$BOUND_CONTROL_ROOT/config.json"
  fixture_session_bus "$BOUND_CONTROL_ROOT"
  plant_unbound_agent agent-a "$BOUND_CAPABILITY"
}

run_bound_session_start() {
  local child_session="$1"
  run env LBWC_TMUX_AGENT=1 LBWC_TMUX_AGENT_ID=agent-a LBWC_TMUX_CONTRACT_ID=contract-a LBWC_TMUX_CONTROL_ROOT="$BOUND_CONTROL_ROOT" LBWC_PLANNING_DIR="$PLANNING_DIR" CLAUDE_SESSION_ID="$child_session" bash "$SCRIPT" </dev/null
}

@test "session-start tmux bind fails closed on a missing or mismatched credential" {
  local label credential
  while IFS='|' read -r label credential; do
    [ -n "$label" ] || continue
    prepare_bound_agent
    [ "$credential" = mismatched ] && write_credential agent-a fedcba9876543210fedcba9876543210

    run_bound_session_start actual-child-session

    [ "$status" -ne 0 ] || { echo "case=$label status=$status output=$output" >&2; return 1; }
    [[ "$output" == *"tmux bind failed"* ]] || { echo "case=$label output=$output" >&2; return 1; }
    run jq -e '.agents[] | select(.agent_id == "agent-a") | .claude_session_id == null' "$BOUND_CONTROL_ROOT/.runtime/tmux-bus/registry.json"
    [ "$status" -eq 0 ] || { echo "case=$label agent was bound despite the failure" >&2; return 1; }
  done <<'CASES'
missing-credential|missing
mismatched-credential|mismatched
CASES
}

@test "session-start consumes a one-shot credential and records a heartbeat" {
  prepare_bound_agent
  write_credential agent-a "$BOUND_CAPABILITY"

  run_bound_session_start actual-child-session

  [ "$status" -eq 0 ]
  [[ "$output" == *"lbwc tmux bind:"* ]]
  [[ "$output" == *"$BOUND_CAPABILITY"* ]]
  [ ! -e "$BOUND_CONTROL_ROOT/.runtime/tmux-bus/credentials/agent-a.json" ]
  run jq -e '.agents[] | select(.agent_id == "agent-a") | .claude_session_id == "actual-child-session" and .state == "running" and (.heartbeat_at_ms | type == "number")' "$BOUND_CONTROL_ROOT/.runtime/tmux-bus/registry.json"
  [ "$status" -eq 0 ]

  write_credential agent-a "$BOUND_CAPABILITY"
  run_bound_session_start second-child-session
  [ "$status" -ne 0 ]
  [[ "$output" == *"tmux bind failed"* ]]
}

@test "concurrent SessionStart attempts bind a credential at most once" {
  prepare_bound_agent
  write_credential agent-a "$BOUND_CAPABILITY"
  bash "$REPO_ROOT/scripts/ensure-plugin-root-link.sh" "$CONCURRENT_LINK" "$(cd -P "$REPO_ROOT" && pwd -P)"

  run env SESSION_START="$SCRIPT" CONTROL_ROOT="$BOUND_CONTROL_ROOT" PLANNING_DIR="$PLANNING_DIR" bash -c '
    LBWC_TMUX_AGENT=1 LBWC_TMUX_AGENT_ID=agent-a LBWC_TMUX_CONTRACT_ID=contract-a LBWC_TMUX_CONTROL_ROOT="$CONTROL_ROOT" LBWC_PLANNING_DIR="$PLANNING_DIR" CLAUDE_SESSION_ID=concurrent-child-session bash "$SESSION_START" > "$CONTROL_ROOT/first-session-start.log" 2>&1 &
    first=$!
    LBWC_TMUX_AGENT=1 LBWC_TMUX_AGENT_ID=agent-a LBWC_TMUX_CONTRACT_ID=contract-a LBWC_TMUX_CONTROL_ROOT="$CONTROL_ROOT" LBWC_PLANNING_DIR="$PLANNING_DIR" CLAUDE_SESSION_ID=concurrent-child-session bash "$SESSION_START" > "$CONTROL_ROOT/second-session-start.log" 2>&1 &
    second=$!
    wait "$first"; first_status=$?
    wait "$second"; second_status=$?
    { [ "$first_status" -eq 0 ] && [ "$second_status" -ne 0 ]; } || { [ "$first_status" -ne 0 ] && [ "$second_status" -eq 0 ]; }
  '

  [ "$status" -eq 0 ]
  [ ! -e "$BOUND_CONTROL_ROOT/.runtime/tmux-bus/credentials/agent-a.json" ]
  run jq -e '.agents[] | select(.agent_id == "agent-a") | .claude_session_id == "concurrent-child-session"' "$BOUND_CONTROL_ROOT/.runtime/tmux-bus/registry.json"
  [ "$status" -eq 0 ]
}

build_cleanup_fixture() {
  local stub_mode="$1" workdir_kind="$2" plugin="$TEST_ROOT/plugin-copy" body
  CLEANUP_PLUGIN_SCRIPTS="$plugin/scripts"
  CLEANUP_ARGV_LOG="$TEST_ROOT/cleanup-stub.argv"
  CLEANUP_WORKDIR="$TEST_ROOT/workdir"
  rm -rf "$plugin" "$CLEANUP_WORKDIR" "$CLEANUP_ARGV_LOG" "$ROOT_LINK"
  mkdir -p "$CLEANUP_WORKDIR"
  [ "$workdir_kind" != git ] || git -C "$CLEANUP_WORKDIR" init -q
  CLEANUP_PROJECT_ROOT="$(cd "$CLEANUP_WORKDIR" && pwd -P)"
  copy_scripts_to "$CLEANUP_PLUGIN_SCRIPTS"
  body="printf '%s\n' \"\$*\" > '$CLEANUP_ARGV_LOG'"
  [ "$stub_mode" != prints ] || body="$body; printf '%s\n' 'retained state inspected'"
  replace_script_in_copy "$CLEANUP_PLUGIN_SCRIPTS" cleanup-temporary-agent-runfiles.sh "$body"
  [ "$stub_mode" != non-executable ] || chmod -x "$CLEANUP_PLUGIN_SCRIPTS/cleanup-temporary-agent-runfiles.sh"
}

run_cleanup_fixture_session_start() {
  run bash -c 'cd "$1" && LBWC_PLANNING_DIR="$2" bash "$3/session-start.sh" </dev/null' _ "$CLEANUP_WORKDIR" "$PLANNING_DIR" "$CLEANUP_PLUGIN_SCRIPTS"
}

@test "session-start runs the temporary run cleanup for the project root and reports retained state" {
  local label stub_mode workdir_kind expect_call expect_line
  while IFS='|' read -r label stub_mode workdir_kind expect_call expect_line; do
    [ -n "$label" ] || continue
    build_cleanup_fixture "$stub_mode" "$workdir_kind"

    run_cleanup_fixture_session_start

    [ "$status" -eq 0 ] || { echo "case=$label status=$status output=$output" >&2; return 1; }
    if [ "$expect_call" = yes ]; then
      [ "$(cat "$CLEANUP_ARGV_LOG" 2>/dev/null)" = "cleanup --project-root $CLEANUP_PROJECT_ROOT" ] \
        || { echo "case=$label argv=$(cat "$CLEANUP_ARGV_LOG" 2>&1) expected root=$CLEANUP_PROJECT_ROOT" >&2; return 1; }
    else
      [ ! -e "$CLEANUP_ARGV_LOG" ] || { echo "case=$label stub ran with argv=$(cat "$CLEANUP_ARGV_LOG")" >&2; return 1; }
    fi
    if [ "$expect_line" = yes ]; then
      [[ "$output" == *"Temporary agent run cleanup inspected retained state."* ]] || { echo "case=$label output=$output" >&2; return 1; }
    else
      [[ "$output" != *"Temporary agent run cleanup"* ]] || { echo "case=$label output=$output" >&2; return 1; }
    fi
  done <<'CASES'
prints-output-adds-context|prints|git|yes|yes
silent-stub-adds-no-context|silent|git|yes|no
non-executable-stub-is-skipped|non-executable|git|no|no
outside-a-git-repo-is-skipped|prints|plain|no|no
CASES
}
