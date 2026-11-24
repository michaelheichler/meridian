#!/usr/bin/env bats

load gate_case_helper
load isolated_case_helper
load rejection_case_helper

setup() {
  unset TMUX TMUX_PANE
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/session-start.sh"
  TEST_ROOT="$(mktemp -d)"
  PLANNING_DIR="$TEST_ROOT/.meridian"
  export CLAUDE_SESSION_ID="session-start-${BATS_TEST_NUMBER}-$$"
  ACTUAL_CHILD_SESSION_ID="actual-child-session-$$"
  SECOND_CHILD_SESSION_ID="second-child-session-$$"
  CONCURRENT_CHILD_SESSION_ID="concurrent-child-session-$$"
  PLUGIN_ROOT_LINK_DIR=/tmp
  PLUGIN_ROOT_LINK_PREFIX="$PLUGIN_ROOT_LINK_DIR/.meridian-plugin-root-link-"
  ROOT_LINK="$PLUGIN_ROOT_LINK_PREFIX$CLAUDE_SESSION_ID"
  rm -rf "$ROOT_LINK"
  CONCURRENT_LINK="$PLUGIN_ROOT_LINK_PREFIX$CONCURRENT_CHILD_SESSION_ID"
  WORKDIR="$TEST_ROOT/project"
  mkdir -p "$WORKDIR"
  git -C "$WORKDIR" init -q
  cd "$WORKDIR"
}

teardown() {
  local session_id
  cd "$BATS_TEST_DIRNAME"
  rm -rf "$TEST_ROOT"
  for session_id in "$CLAUDE_SESSION_ID" "$ACTUAL_CHILD_SESSION_ID" "$SECOND_CHILD_SESSION_ID" "$CONCURRENT_CHILD_SESSION_ID"; do
    [ -z "$session_id" ] || rm -rf "$PLUGIN_ROOT_LINK_PREFIX$session_id"
  done
  unset CLAUDE_SESSION_ID
  [ ! -L "$REPO_ROOT/meridian" ] || { rm -f "$REPO_ROOT/meridian"; return 1; }
}

run_session_start() {
  (
    cd "$WORKDIR"
    MERIDIAN_PLANNING_DIR="$PLANNING_DIR" bash "$SCRIPT" </dev/null
  )
}

run_session_start_from() {
  local script_dir="$1"
  (
    cd "$WORKDIR"
    MERIDIAN_PLANNING_DIR="$PLANNING_DIR" bash "$script_dir/session-start.sh" </dev/null
  )
}

run_session_start_with_input() {
  local input="$1"
  (
    cd "$WORKDIR"
    printf '%s' "$input" | MERIDIAN_PLANNING_DIR="$PLANNING_DIR" bash "$SCRIPT"
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
  mkdir -p "$PLANNING_DIR"
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
  mkdir -p "$PLANNING_DIR"
  SHIM_DIR="$TEST_ROOT/scripts-shim"
  copy_scripts_to "$SHIM_DIR"
  replace_script_in_copy "$SHIM_DIR" agent-lifecycle.sh \
    "printf '%s\n' 'agent_manifest_status=unavailable'; exit 1"
}

expect_lacks() {
  [[ "$output" != *"$2"* ]] || record_case_failure "$1" "unexpected fragment=[$2] output=$output"
}

context_row() {
  local label="$1" prepare="$2"
  rm -rf "$PLANNING_DIR" "$TEST_ROOT/scripts-shim"
  SHIM_DIR=""
  "$prepare"
  run run_session_start_from "${SHIM_DIR:-$REPO_ROOT/scripts}"
  expect_case "$label" 0
  jq -e '.hookSpecificOutput.additionalContext | type == "string"' <<<"$output" >/dev/null \
    || record_case_failure "$label" "output is not a SessionStart hook document: $output"
}

compaction_count_row() {
  local label="$1" input="$2" expected="$3"
  rm -rf "$PLANNING_DIR"
  seed_compaction_count 5
  run run_session_start_with_input "$input"
  expect_case "$label" 0
  [ "$(read_compaction_count)" = "$expected" ] \
    || record_case_failure "$label" "expected=$expected actual=$(read_compaction_count)"
}

link_session_plugin_root_and_persist_environment() {
  local plugin_root="$TEST_ROOT/plugin" canonical_root
  canonical_root=$(cd "$REPO_ROOT" && pwd -P)
  reset_case_failures

  copy_scripts_to "$plugin_root/scripts"
  replace_script_in_copy "$plugin_root/scripts" ensure-plugin-root-link.sh 'exit 1'
  run run_session_start_from "$plugin_root/scripts"
  expect_case link-bootstrap-fails 1 "MERIDIAN: SessionStart plugin root link bootstrap failed"

  run run_session_start
  expect_case exact-root-link 0
  [ -L "$ROOT_LINK" ] || record_case_failure exact-root-link "no session link at $ROOT_LINK"
  [ "$(readlink "$ROOT_LINK")" = "$canonical_root" ] \
    || record_case_failure exact-root-link "link points to $(readlink "$ROOT_LINK") want $canonical_root"

  export CLAUDE_ENV_FILE="$TEST_ROOT/claude-env"
  : > "$CLAUDE_ENV_FILE"
  run run_session_start
  expect_case env-file-first-run 0
  run run_session_start
  expect_case env-file-second-run 0
  [ "$(grep -cxF 'unset CDPATH' "$CLAUDE_ENV_FILE")" -eq 1 ] \
    || record_case_failure env-file-once "unset CDPATH is not present exactly once"

  printf 'export KEEP=1\n' > "$CLAUDE_ENV_FILE"
  chmod 444 "$CLAUDE_ENV_FILE"
  run run_session_start
  expect_case env-file-not-writable 0
  [ "$(cat "$CLAUDE_ENV_FILE")" = 'export KEEP=1' ] \
    || record_case_failure env-file-not-writable "read-only env file changed"

  local sourced_env
  rm -rf "$PLANNING_DIR" "$ROOT_LINK"
  export CLAUDE_ENV_FILE="$TEST_ROOT/fresh-claude-env"
  : > "$CLAUDE_ENV_FILE"
  run run_session_start
  expect_case_silent no-planning-dir-still-bootstraps 0
  [ "$(readlink "$ROOT_LINK")" = "$canonical_root" ] \
    || record_case_failure no-planning-dir-still-bootstraps "link points to $(readlink "$ROOT_LINK") want $canonical_root"
  sourced_env=$(env -u CLAUDE_PLUGIN_ROOT CDPATH=/elsewhere bash -c '. "$1"; printf "%s|%s" "${CDPATH-unset}" "$CLAUDE_PLUGIN_ROOT"' _ "$CLAUDE_ENV_FILE")
  [ "$sourced_env" = "unset|$canonical_root" ] \
    || record_case_failure no-planning-dir-still-bootstraps "sourcing the env file gives [$sourced_env]"

  assert_no_case_failures
}

report_planning_and_subsystem_context() {
  reset_case_failures

  rm -rf "$PLANNING_DIR"
  run run_session_start
  expect_case_silent cold-start-without-planning-dir-is-silent 0
  context_row warm-start-reports-phase-brief prepare_warm_start
  expect_fragment warm-start-reports-phase-brief "meridian phase"
  context_row phase-needing-plan-routes-to-plan prepare_phase_needing_plan
  expect_fragment phase-needing-plan-routes-to-plan "missing PLAN.md"
  expect_fragment phase-needing-plan-routes-to-plan "/plan 01"
  context_row phase-needing-discussion-routes-to-discuss prepare_phase_needing_discussion
  expect_fragment phase-needing-discussion-routes-to-discuss "missing CONTEXT.md"
  expect_fragment phase-needing-discussion-routes-to-discuss "/discuss 01"
  expect_lacks phase-needing-discussion-routes-to-discuss "/plan 01"
  context_row phase-setup-failure-is-unavailable-not-missing prepare_phase_detect_setup_failure
  expect_fragment phase-setup-failure-is-unavailable-not-missing "meridian: phase status unavailable (setup_failed)."
  expect_lacks phase-setup-failure-is-unavailable-not-missing "no ${PLANNING_DIR}/ directory found"
  context_row malformed-agent-manifest-surfaces prepare_malformed_manifest
  expect_fragment malformed-agent-manifest-surfaces "meridian: agent manifest status malformed."
  context_row unavailable-agent-manifest-surfaces prepare_unavailable_manifest
  expect_fragment unavailable-agent-manifest-surfaces "meridian: agent manifest status unavailable."

  assert_no_case_failures
}

report_guard_owner_context() {
  local owner_home="$TEST_ROOT/owner-home" expiry_line owner_command
  mkdir -p "$owner_home" "$PLANNING_DIR"
  printf -v owner_command 'bash %q' "$REPO_ROOT/scripts/meridian-guard.sh"
  reset_case_failures
  run env -u CLAUDE_PLUGIN_ROOT HOME="$owner_home" bash "$REPO_ROOT/scripts/meridian-guard.sh" allow --for 30m
  expect_case owner-grant-without-plugin-environment 0
  expiry_line="$output"
  run env -u CLAUDE_PLUGIN_ROOT HOME="$owner_home" MERIDIAN_PLANNING_DIR="$PLANNING_DIR" bash "$SCRIPT" </dev/null
  expect_case owner-context-without-plugin-environment 0
  expect_fragment owner-context-expiry "$expiry_line"
  expect_fragment owner-context-absolute-command "$owner_command"
  expect_lacks owner-context-no-plugin-variable 'CLAUDE_PLUGIN_ROOT'
  assert_no_case_failures
}

apply_source_specific_compaction_policy() {
  reset_case_failures

  compaction_count_row startup-resets-stale-count '{"source":"startup"}' 0
  compaction_count_row clear-resets-stale-count '{"source":"clear"}' 0
  compaction_count_row compact-keeps-count '{"source":"compact"}' 5
  compaction_count_row resume-keeps-count '{"source":"resume"}' 5
  compaction_count_row empty-stdin-keeps-count '' 5

  rm -rf "$PLANNING_DIR"
  run run_session_start_with_input '{"source":"startup"}'
  expect_case startup-without-planning-dir 0
  [ ! -e "$PLANNING_DIR" ] || record_case_failure startup-without-planning-dir "planning dir was created"

  local outer_planning="$PLANNING_DIR" conflict_output
  PLANNING_DIR="$WORKDIR/.meridian"
  seed_compaction_count 5
  mkdir "$WORKDIR/.lbwc-planning"
  conflict_output=$(run_session_start_with_input '{"source":"startup"}' 2>"$TEST_ROOT/conflict-stderr") \
    || record_case_failure startup-with-both-planning-dirs "session start exited nonzero"
  jq -e '.hookSpecificOutput.additionalContext | type == "string"' <<<"$conflict_output" >/dev/null \
    || record_case_failure startup-with-both-planning-dirs "no SessionStart context: $conflict_output"
  [ -s "$TEST_ROOT/conflict-stderr" ] || record_case_failure startup-with-both-planning-dirs "conflict warning missing"
  [ -d "$WORKDIR/.lbwc-planning" ] || record_case_failure startup-with-both-planning-dirs "legacy dir removed"
  [ "$(read_compaction_count)" = "0" ] || record_case_failure startup-with-both-planning-dirs "count=$(read_compaction_count) want 0"
  rm -rf "$WORKDIR/.lbwc-planning" "$PLANNING_DIR"
  PLANNING_DIR="$outer_planning"

  seed_compaction_count 9
  run run_session_start_with_input '{"source":"startup"}'
  expect_case near-limit-startup 0
  run env MERIDIAN_PLANNING_DIR="$PLANNING_DIR" bash -c 'printf "%s" "{\"matcher\":\"auto\"}" | bash "$1"' _ "$REPO_ROOT/scripts/compaction-instructions.sh"
  expect_case near-limit-compaction 0
  expect_lacks near-limit-compaction "COMPACTION LOOP DETECTED"
  [ "$(read_compaction_count)" = "1" ] || record_case_failure near-limit-compaction "count=$(read_compaction_count) want 1"

  assert_no_case_failures
}

fixture_session_bus() {
  local control_root="$1" hash registry
  source "$REPO_ROOT/scripts/lib/meridian-control-root.sh"
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
      tmux_target: "meridian-test-main:0.1", tmux_pane_id: null, claude_session_id: null,
      capability_hash: $hash, state: "registered", heartbeat_at_ms: null
    }]
    | .routes[$id] = {inbox: $id, tmux_target: "meridian-test-main:0.1"}
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
  BOUND_CONTROL_ROOT="$TEST_ROOT/tmux-project/.meridian"
  BOUND_CAPABILITY='0123456789abcdef0123456789abcdef'
  rm -rf "$TEST_ROOT/tmux-project"
  mkdir -p "$BOUND_CONTROL_ROOT" "$PLANNING_DIR"
  printf '%s\n' '{}' > "$BOUND_CONTROL_ROOT/config.json"
  fixture_session_bus "$BOUND_CONTROL_ROOT"
  plant_unbound_agent agent-a "$BOUND_CAPABILITY"
}

run_bound_session_start() {
  local child_session="$1"
  run env MERIDIAN_TMUX_AGENT=1 MERIDIAN_TMUX_AGENT_ID=agent-a MERIDIAN_TMUX_CONTRACT_ID=contract-a MERIDIAN_TMUX_CONTROL_ROOT="$BOUND_CONTROL_ROOT" MERIDIAN_PLANNING_DIR="$PLANNING_DIR" CLAUDE_SESSION_ID="$child_session" bash "$SCRIPT" </dev/null
}

expect_bound_registry() {
  local label="$1" filter="$2"
  jq -e ".agents[] | select(.agent_id == \"agent-a\") | $filter" "$BOUND_CONTROL_ROOT/.runtime/tmux-bus/registry.json" >/dev/null \
    || record_case_failure "$label" "registry entry fails [$filter]"
}

bind_rejected_row() {
  local label="$1"
  run_bound_session_start "$ACTUAL_CHILD_SESSION_ID"
  expect_rejected "$label" "tmux bind failed"
  expect_bound_registry "$label" '.claude_session_id == null'
}

run_concurrent_session_starts() {
  run env SESSION_START="$SCRIPT" CONTROL_ROOT="$BOUND_CONTROL_ROOT" PLANNING_DIR="$PLANNING_DIR" CHILD_SESSION_ID="$CONCURRENT_CHILD_SESSION_ID" bash -c '
    MERIDIAN_TMUX_AGENT=1 MERIDIAN_TMUX_AGENT_ID=agent-a MERIDIAN_TMUX_CONTRACT_ID=contract-a MERIDIAN_TMUX_CONTROL_ROOT="$CONTROL_ROOT" MERIDIAN_PLANNING_DIR="$PLANNING_DIR" CLAUDE_SESSION_ID="$CHILD_SESSION_ID" bash "$SESSION_START" > "$CONTROL_ROOT/first-session-start.log" 2>&1 &
    first=$!
    MERIDIAN_TMUX_AGENT=1 MERIDIAN_TMUX_AGENT_ID=agent-a MERIDIAN_TMUX_CONTRACT_ID=contract-a MERIDIAN_TMUX_CONTROL_ROOT="$CONTROL_ROOT" MERIDIAN_PLANNING_DIR="$PLANNING_DIR" CLAUDE_SESSION_ID="$CHILD_SESSION_ID" bash "$SESSION_START" > "$CONTROL_ROOT/second-session-start.log" 2>&1 &
    second=$!
    wait "$first"; first_status=$?
    wait "$second"; second_status=$?
    { [ "$first_status" -eq 0 ] && [ "$second_status" -ne 0 ]; } || { [ "$first_status" -ne 0 ] && [ "$second_status" -eq 0 ]; }
  '
}

bound_session_start_stdout() {
  env MERIDIAN_TMUX_AGENT=1 MERIDIAN_TMUX_AGENT_ID=agent-a MERIDIAN_TMUX_CONTRACT_ID=contract-a MERIDIAN_TMUX_CONTROL_ROOT="$BOUND_CONTROL_ROOT" MERIDIAN_PLANNING_DIR="$PLANNING_DIR" CLAUDE_SESSION_ID="$1" bash "$SCRIPT" </dev/null 2>"$TEST_ROOT/bound-stderr"
}

plain_session_start_with_recorded_bus() {
  local plugin="$TEST_ROOT/plain-plugin/scripts" recorder
  recorder="printf '%s\n' \"\$0 \$*\" >> '$TEST_ROOT/tmux-bus.calls'"
  copy_scripts_to "$plugin"
  replace_script_in_copy "$plugin" tmux-bus.sh "$recorder"
  replace_script_in_copy "$plugin" tmux-agent-heartbeat.sh "$recorder"
  (cd "$WORKDIR" && env -u MERIDIAN_TMUX_AGENT -u MERIDIAN_TMUX_AGENT_ID -u MERIDIAN_TMUX_CONTRACT_ID -u MERIDIAN_TMUX_CONTROL_ROOT \
    MERIDIAN_PLANNING_DIR="$PLANNING_DIR" bash "$plugin/session-start.sh" </dev/null 2>"$TEST_ROOT/plain-stderr")
}

invalid_mode_session_start() {
  (cd "$WORKDIR" && env MERIDIAN_TMUX_AGENT=yes MERIDIAN_PLANNING_DIR="$PLANNING_DIR" bash "$SCRIPT" </dev/null 2>"$TEST_ROOT/invalid-mode-stderr")
}

expect_bind_only_context() {
  local label="$1" session="$2"
  jq -e --arg session "$session" '.hookSpecificOutput.additionalContext | capture("^meridian tmux bind: (?<bind>.*)[.]$").bind | fromjson | .agent_id == "agent-a" and .session_id == $session' <<<"$output" >/dev/null 2>&1 \
    || record_case_failure "$label" "stdout is not the bind context alone: $output"
}

bind_tmux_session_with_one_shot_credentials() {
  reset_case_failures

  prepare_bound_agent
  bind_rejected_row missing-credential

  prepare_bound_agent
  write_credential agent-a fedcba9876543210fedcba9876543210
  bind_rejected_row mismatched-credential

  prepare_bound_agent
  write_credential agent-a "$BOUND_CAPABILITY"
  run_bound_session_start "$ACTUAL_CHILD_SESSION_ID"
  expect_case one-shot-credential 0 "meridian tmux bind:"
  expect_fragment one-shot-credential "$BOUND_CAPABILITY"
  [ ! -e "$BOUND_CONTROL_ROOT/.runtime/tmux-bus/credentials/agent-a.json" ] \
    || record_case_failure one-shot-credential "credential was not consumed"
  expect_bound_registry one-shot-credential ".claude_session_id == \"$ACTUAL_CHILD_SESSION_ID\" and .state == \"running\" and (.heartbeat_at_ms | type == \"number\")"

  write_credential agent-a "$BOUND_CAPABILITY"
  run_bound_session_start "$SECOND_CHILD_SESSION_ID"
  expect_rejected rebind-after-consumption "tmux bind failed"

  prepare_bound_agent
  write_credential agent-a "$BOUND_CAPABILITY"
  bash "$REPO_ROOT/scripts/ensure-plugin-root-link.sh" "$CONCURRENT_LINK" "$(cd -P "$REPO_ROOT" && pwd -P)"
  run_concurrent_session_starts
  expect_case concurrent-binds-once 0
  [ ! -e "$BOUND_CONTROL_ROOT/.runtime/tmux-bus/credentials/agent-a.json" ] \
    || record_case_failure concurrent-binds-once "credential was not consumed"
  expect_bound_registry concurrent-binds-once ".claude_session_id == \"$CONCURRENT_CHILD_SESSION_ID\""

  prepare_bound_agent
  rm -rf "$PLANNING_DIR"
  write_credential agent-a "$BOUND_CAPABILITY"
  run bound_session_start_stdout planless-child-session
  expect_case tmux-agent-without-planning-dir 0
  [ ! -e "$BOUND_CONTROL_ROOT/.runtime/tmux-bus/credentials/agent-a.json" ] \
    || record_case_failure tmux-agent-without-planning-dir "credential was not consumed"
  expect_bound_registry tmux-agent-without-planning-dir '.claude_session_id == "planless-child-session" and .state == "running" and (.heartbeat_at_ms | type == "number")'
  expect_bind_only_context tmux-agent-without-planning-dir planless-child-session
  [ ! -e "$PLANNING_DIR" ] || record_case_failure tmux-agent-without-planning-dir "planning dir was created"

  rm -rf "$PLANNING_DIR" "$TEST_ROOT/tmux-bus.calls"
  run plain_session_start_with_recorded_bus
  expect_case_silent no-planning-dir-without-tmux-agent 0
  [ ! -e "$TEST_ROOT/tmux-bus.calls" ] \
    || record_case_failure no-planning-dir-without-tmux-agent "bind stubs ran: $(cat "$TEST_ROOT/tmux-bus.calls")"

  rm -rf "$PLANNING_DIR" "$TEST_ROOT/invalid-mode-stderr"
  run invalid_mode_session_start
  expect_case_silent invalid-tmux-agent-mode-without-planning-dir 1
  [ -s "$TEST_ROOT/invalid-mode-stderr" ] \
    || record_case_failure invalid-tmux-agent-mode-without-planning-dir "stderr is empty"
  [ ! -e "$PLANNING_DIR" ] || record_case_failure invalid-tmux-agent-mode-without-planning-dir "planning dir was created"

  assert_no_case_failures
}

build_cleanup_fixture() {
  local stub_mode="$1" workdir_kind="$2" plugin="$TEST_ROOT/plugin-copy" body
  CLEANUP_PLUGIN_SCRIPTS="$plugin/scripts"
  CLEANUP_ARGV_LOG="$TEST_ROOT/cleanup-stub.argv"
  CLEANUP_WORKDIR="$TEST_ROOT/workdir"
  rm -rf "$plugin" "$CLEANUP_WORKDIR" "$CLEANUP_ARGV_LOG" "$ROOT_LINK"
  mkdir -p "$CLEANUP_WORKDIR" "$PLANNING_DIR"
  [ "$workdir_kind" != git ] || git -C "$CLEANUP_WORKDIR" init -q
  CLEANUP_PROJECT_ROOT="$(cd "$CLEANUP_WORKDIR" && pwd -P)"
  copy_scripts_to "$CLEANUP_PLUGIN_SCRIPTS"
  body="printf '%s\n' \"\$*\" > '$CLEANUP_ARGV_LOG'"
  [ "$stub_mode" != prints ] || body="$body; printf '%s\n' 'retained state inspected'"
  replace_script_in_copy "$CLEANUP_PLUGIN_SCRIPTS" cleanup-temporary-agent-runfiles.sh "$body"
  [ "$stub_mode" != non-executable ] || chmod -x "$CLEANUP_PLUGIN_SCRIPTS/cleanup-temporary-agent-runfiles.sh"
}

run_cleanup_fixture_session_start() {
  run bash -c 'cd "$1" && MERIDIAN_PLANNING_DIR="$2" bash "$3/session-start.sh" </dev/null' _ "$CLEANUP_WORKDIR" "$PLANNING_DIR" "$CLEANUP_PLUGIN_SCRIPTS"
}

cleanup_row() {
  local label="$1" stub_mode="$2" workdir_kind="$3"
  build_cleanup_fixture "$stub_mode" "$workdir_kind"
  run_cleanup_fixture_session_start
  expect_case "$label" 0
}

expect_cleanup_called() {
  [ "$(cat "$CLEANUP_ARGV_LOG" 2>/dev/null)" = "cleanup --project-root $CLEANUP_PROJECT_ROOT" ] \
    || record_case_failure "$1" "argv=$(cat "$CLEANUP_ARGV_LOG" 2>&1) expected root=$CLEANUP_PROJECT_ROOT"
}

expect_cleanup_skipped() {
  [ ! -e "$CLEANUP_ARGV_LOG" ] || record_case_failure "$1" "stub ran with argv=$(cat "$CLEANUP_ARGV_LOG")"
}

@test "session start initializes context and enforces session lifecycle policies" {
  run_scenario_cases link_session_plugin_root_and_persist_environment \
    report_planning_and_subsystem_context report_guard_owner_context apply_source_specific_compaction_policy \
    bind_tmux_session_with_one_shot_credentials cleanup_project_runfiles_and_report_retained_state
}

cleanup_project_runfiles_and_report_retained_state() {
  reset_case_failures

  cleanup_row prints-output-adds-context prints git
  expect_cleanup_called prints-output-adds-context
  expect_fragment prints-output-adds-context "Temporary agent run cleanup inspected retained state."

  cleanup_row silent-stub-adds-no-context silent git
  expect_cleanup_called silent-stub-adds-no-context
  expect_lacks silent-stub-adds-no-context "Temporary agent run cleanup"

  cleanup_row non-executable-stub-is-skipped non-executable git
  expect_cleanup_skipped non-executable-stub-is-skipped
  expect_lacks non-executable-stub-is-skipped "Temporary agent run cleanup"

  cleanup_row outside-a-git-repo-is-skipped prints plain
  expect_cleanup_skipped outside-a-git-repo-is-skipped
  expect_lacks outside-a-git-repo-is-skipped "Temporary agent run cleanup"

  assert_no_case_failures
}
