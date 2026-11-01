#!/usr/bin/env bats

load gate_case_helper
load rejection_case_helper
load doc_fragment_helper

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  SCRIPT="$REPO_ROOT/scripts/runtime-snapshot.sh"
  TEST_ROOT="$(mktemp -d)"
  PLANNING_DIR="$TEST_ROOT/project/.lbwc-planning"
  PHASE_DIR="$PLANNING_DIR/phases/01-runtime-freeze"
  SNAPSHOT_PATH="$PHASE_DIR/.runtime-snapshot.json"
  CANCEL_PATH="$PHASE_DIR/.runtime-cancelled.json"
  mkdir -p "$PHASE_DIR"
  write_config
  cp "$PLANNING_DIR/config.json" "$PLANNING_DIR/config.pristine"
  reset_case_failures
}

teardown() {
  rm -rf "$TEST_ROOT"
}

write_config() {
  jq -n '
    {
      effort: "balanced",
      agent_execution_mode: "in_process",
      tmux_execution: {
        enabled: false,
        session_name_prefix: "lbwc",
        max_agents: 3,
        attach_policy: "orchestrator_only",
        heartbeat_interval_seconds: 30,
        heartbeat_stale_seconds: 120,
        comms_latency_tolerance_ms: 5000,
        comms_fallback: "bus_only",
        cleanup_policy: "kill_on_complete",
        layout: "main-vertical",
        restrictions: {
          allow_nested_spawn: false,
          allow_agent_git: false,
          allow_agent_ask_user: false,
          require_orchestrator_attach: true
        }
      },
      workflow_execution: {
        enabled: false
      },
      routing: {
        active_profile: "balanced",
        profiles: {
          quality: {roles: {}},
          balanced: {
            roles: {
              "coding-dijkstra": {
                model: "openai/gpt-5.6-terra",
                reasoning: "high",
                status: "resolved"
              }
            }
          },
          turbo: {roles: {}}
        }
      }
    }
  ' > "$PLANNING_DIR/config.json"
}

reset_phase() {
  rm -f "$SNAPSHOT_PATH" "$CANCEL_PATH" "$PLANNING_DIR/claude-capabilities.json"
  cp "$PLANNING_DIR/config.pristine" "$PLANNING_DIR/config.json"
}

edit_config() {
  jq "$1" "$PLANNING_DIR/config.json" > "$PLANNING_DIR/config.json.tmp"
  mv "$PLANNING_DIR/config.json.tmp" "$PLANNING_DIR/config.json"
}

snapshot_digest() {
  shasum -a 256 "$SNAPSHOT_PATH" | awk '{print $1}'
}

run_snapshot() {
  run bash "$SCRIPT" "$@" --planning-dir "$PLANNING_DIR" --phase-dir "$PHASE_DIR"
}

write_capability_catalog() {
  jq -n --argjson available "$1" '
    {
      workflow: (
        {
          min_version: "2.1.154",
          disabled_by_settings: false,
          disabled_by_env: false,
          subagent_model_override_active: false
        }
        + (if $available
            then {host_version: "2.1.200", meets_version_floor: true, available: true, unavailable_reasons: []}
            else {
              host_version: "2.1.100",
              meets_version_floor: false,
              available: false,
              unavailable_reasons: ["Claude Code 2.1.100 is older than the workflow version floor 2.1.154."]
            }
          end)
      )
    }
  ' > "$PLANNING_DIR/claude-capabilities.json"
}

enable_workflow() {
  edit_config ".agent_execution_mode = \"workflow\" | .workflow_execution.enabled = $1"
}

freeze_in_process() {
  run_snapshot freeze --requested-backend in_process --resolved-backend in_process
  expect_case "$1" 0 '"status":"created"'
}

freeze_workflow() {
  enable_workflow true
  write_capability_catalog true
  run_snapshot freeze --requested-backend workflow --resolved-backend workflow
  expect_case "$1" 0 '"status":"created"'
}

expect_snapshot_jq() {
  local label="$1" program="$2"
  jq -e --arg phase "phases/01-runtime-freeze" "$program" "$SNAPSHOT_PATH" >/dev/null \
    || record_case_failure "$label" "snapshot did not satisfy: $program"
}

expect_no_temporary_files() {
  [ -z "$(compgen -G "$PHASE_DIR/.runtime-snapshot.tmp.*")" ] \
    || record_case_failure "$1" "temporary snapshot files remained"
}

validate_matches_row() {
  local label="$1" before
  before=$(snapshot_digest)
  run_snapshot validate
  expect_case "$label" 0 '"status":"matched"'
  [ "$(snapshot_digest)" = "$before" ] || record_case_failure "$label" "validation rewrote the snapshot"
}

frozen_command_rejected_row() {
  local label="$1" fragment="$2" before
  shift 2
  before=$(snapshot_digest)
  run_snapshot "$@"
  expect_rejected "$label" "$fragment"
  expect_digest "$label" "$before" "$(snapshot_digest)"
}

@test "validate accepts an identical frozen configuration without rewriting it, validate and cancel refuse to touch a frozen snapshot after drift or a second request, and cancel and cleanup leave terminal state" {
  freeze_in_process in-process-validate-baseline
  validate_matches_row in-process-validate

  reset_phase
  freeze_workflow workflow-validate-baseline
  validate_matches_row workflow-validate

  reset_phase
  freeze_in_process effort-drift-baseline
  edit_config '.effort = "thorough"'
  frozen_command_rejected_row effort-drift 'backend drift' validate

  reset_phase
  freeze_in_process unrelated-key-drift-baseline
  edit_config '.metrics = true'
  frozen_command_rejected_row unrelated-key-drift 'frozen configuration differs' validate

  reset_phase
  freeze_in_process backend-drift-baseline
  edit_config '.agent_execution_mode = "tmux" | .tmux_execution.enabled = true'
  frozen_command_rejected_row backend-drift 'backend drift' validate

  reset_phase
  freeze_in_process routing-drift-baseline
  edit_config '.routing.profiles.balanced.roles["coding-dijkstra"].model = "openai/gpt-5.6-luna"'
  frozen_command_rejected_row routing-drift 'backend drift' validate

  reset_phase
  freeze_in_process workflow-config-baseline
  edit_config '.agent_execution_mode = "workflow"'
  frozen_command_rejected_row workflow-config-over-frozen-backend 'backend drift: configuration requires workflow' validate

  reset_phase
  freeze_in_process cancel-after-freeze-baseline
  frozen_command_rejected_row cancel-after-freeze 'runtime snapshot already exists' cancel
  [ ! -e "$CANCEL_PATH" ] || record_case_failure cancel-after-freeze "cancel marker was written"

  reset_phase
  printf '%s\n' '{"schema_version":1}' > "$SNAPSHOT_PATH"
  run_snapshot validate
  expect_rejected malformed-snapshot 'runtime snapshot is malformed'

  reset_phase
  run_snapshot cancel
  expect_case cancel 0 '"status":"cancelled"'
  [ ! -e "$SNAPSHOT_PATH" ] || record_case_failure cancel "cancel froze a backend"
  jq -e --arg phase "phases/01-runtime-freeze" '
    .schema_version == 1
    and .phase == $phase
    and .status == "cancelled"
  ' "$CANCEL_PATH" >/dev/null || record_case_failure cancel "cancel marker has an unexpected shape"

  reset_phase
  freeze_in_process cleanup-baseline
  run_snapshot cleanup
  expect_case cleanup 0 '"status":"cleaned"'
  [ ! -e "$SNAPSHOT_PATH" ] || record_case_failure cleanup "snapshot remained"

  assert_no_case_failures
}

freeze_rejected_row() {
  local label="$1" fragment="$2" requested="$3" resolved="$4"
  run_snapshot freeze --requested-backend "$requested" --resolved-backend "$resolved"
  expect_rejected "$label" "$fragment"
  [ ! -f "$SNAPSHOT_PATH" ] || record_case_failure "$label" "a snapshot was written"
}

@test "freeze writes the canonical snapshot atomically for each backend and fails closed when the requested workflow backend cannot run" {
  freeze_in_process in-process-freeze
  [ -f "$SNAPSHOT_PATH" ] || record_case_failure in-process-freeze "snapshot file missing"
  expect_snapshot_jq in-process-freeze '
    .schema_version == 1
    and .phase == $phase
    and .requested_backend == "in_process"
    and .resolved_backend == "in_process"
    and .effort == "balanced"
    and .routing_profile == "balanced"
    and .routing_roles["coding-dijkstra"].model == "openai/gpt-5.6-terra"
    and .tmux_execution.restrictions.require_orchestrator_attach == true
    and (.source_config_digest | test("^[0-9a-f]{64}$"))
  '
  expect_no_temporary_files in-process-freeze

  reset_phase
  freeze_workflow workflow-freeze
  [ -f "$SNAPSHOT_PATH" ] || record_case_failure workflow-freeze "snapshot file missing"
  expect_snapshot_jq workflow-freeze '
    .schema_version == 1
    and .phase == $phase
    and .requested_backend == "workflow"
    and .resolved_backend == "workflow"
    and (.source_config_digest | test("^[0-9a-f]{64}$"))
  '

  reset_phase
  edit_config '.agent_execution_mode = "ask"'
  freeze_rejected_row workflow-resolves-elsewhere \
    'workflow requested backend cannot resolve to another backend' workflow in_process

  reset_phase
  enable_workflow true
  write_capability_catalog false
  freeze_rejected_row old-host-version 'workflow backend is unavailable' workflow workflow
  expect_fragment old-host-version 'Claude Code 2.1.100 is older than the workflow version floor 2.1.154.'

  reset_phase
  enable_workflow false
  write_capability_catalog true
  freeze_rejected_row disabled-in-configuration 'workflow backend is disabled in configuration' workflow workflow

  reset_phase
  enable_workflow true
  freeze_rejected_row missing-capability-catalog 'workflow backend is unavailable' workflow workflow

  reset_phase
  enable_workflow true
  write_capability_catalog true
  CLAUDE_CODE_SUBAGENT_MODEL=claude-opus run_snapshot freeze --requested-backend workflow --resolved-backend workflow
  expect_rejected live-subagent-model-override 'CLAUDE_CODE_SUBAGENT_MODEL is set in this session'
  [ ! -f "$SNAPSHOT_PATH" ] || record_case_failure live-subagent-model-override "a snapshot was written"

  CLAUDE_CODE_DISABLE_WORKFLOWS=1 run_snapshot freeze --requested-backend workflow --resolved-backend workflow
  expect_rejected live-workflows-disabled 'CLAUDE_CODE_DISABLE_WORKFLOWS is set in this session'
  [ ! -f "$SNAPSHOT_PATH" ] || record_case_failure live-workflows-disabled "a snapshot was written"

  assert_no_case_failures
}

doc_path() {
  case "$1" in
    build) printf '%s\n' "$REPO_ROOT/commands/build.md" ;;
    vibe) printf '%s\n' "$REPO_ROOT/commands/vibe.md" ;;
    execute-protocol) printf '%s\n' "$REPO_ROOT/references/vibe-mode-execute.md" ;;
  esac
}

doc_fragment_rows() {
  local checker="$1" key fragment
  while IFS='|' read -r key fragment; do
    [ -n "$key" ] || continue
    "$checker" "$checker $key: $fragment" "$(doc_path "$key")" "$fragment"
  done
}

@test "vibe and build command documents wire the snapshot helper and the explicit tmux spawn branch and drop the retired spawn wording" {
  doc_fragment_rows expect_doc_has <<'FRAGMENTS'
vibe|scripts/runtime-snapshot.sh" validate
vibe|scripts/runtime-snapshot.sh" freeze
vibe|scripts/runtime-snapshot.sh" cancel
vibe|.runtime-cancelled.json
vibe|--assert-snapshot
vibe|agent-generator.sh --execution-backend
vibe|Schema 2 generation omits `--execution-backend`
vibe|If `snapshot.resolved_backend` is `in_process`
vibe|If `snapshot.resolved_backend` is `tmux`
vibe|references/tmux-spawn-protocol.md
vibe|Do not call native Agent.
build|scripts/runtime-snapshot.sh" validate
build|scripts/runtime-snapshot.sh" freeze
build|scripts/runtime-snapshot.sh" cancel
build|scripts/runtime-snapshot.sh" cleanup
build|.runtime-cancelled.json
build|agent-generator.sh --execution-backend
build|--requested-backend
build|--resolved-backend
build|--control-root
build|--assert-snapshot
build|[ -f "$SNAPSHOT_PATH" ]
build|references/tmux-spawn-protocol.md
build|tmux-spawn-group.sh" dispatch
build|CLAUDE_SESSION_ID
build|If `snapshot.resolved_backend` is `in_process`
build|If `snapshot.resolved_backend` is `tmux`
build|Do not call native Agent.
build|Schema 2 generation omits `--execution-backend`
execute-protocol|--requested-backend
execute-protocol|--resolved-backend
execute-protocol|--control-root
execute-protocol|--assert-snapshot
execute-protocol|[ -f "$SNAPSHOT_PATH" ]
execute-protocol|agent-generator.sh --execution-backend
execute-protocol|Schema 2 generation omits `--execution-backend`
execute-protocol|references/tmux-spawn-protocol.md
execute-protocol|tmux-spawn-group.sh" dispatch
execute-protocol|CLAUDE_SESSION_ID
execute-protocol|Spawn path (hard branch)
execute-protocol|If `snapshot.resolved_backend` is `in_process`
execute-protocol|If `snapshot.resolved_backend` is `tmux`
execute-protocol|Do not call native Agent.
execute-protocol|.runtime-cancelled.json
FRAGMENTS

  doc_fragment_rows expect_doc_lacks <<'FRAGMENTS'
build|MAIN_ID=main-session
build|$AGENTS_JSON
build|Pane spawn is not wired
vibe|Pane spawn is not wired
execute-protocol|MAIN_ID=main-session
execute-protocol|$AGENTS_JSON
execute-protocol|Pane spawn is not wired
FRAGMENTS

  assert_no_case_failures
}
