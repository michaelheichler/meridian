#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/agent-lifecycle.sh"
  TEST_ROOT="$(mktemp -d)"
  TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
  PLANNING_DIR="$TEST_ROOT/.meridian"
  MANIFEST="$PLANNING_DIR/.agent-manifest.json"
  ENGINEER=meridian-python-engineer-calm-fox
  CRITIC=meridian-python-critic-calm-owl
  mkdir -p "$PLANNING_DIR/.contracts/tasks"
}

teardown() {
  chmod 755 "$PLANNING_DIR" 2>/dev/null || true
  rm -rf "$TEST_ROOT"
}

event_payload() {
  jq -cn --arg event "$1" --arg agent "$2" '{hook_event_name: $event, agent_type: $agent, teammate_name: $agent}'
}

run_lifecycle() {
  local payload="$1"
  shift
  run --separate-stderr env MERIDIAN_PLANNING_DIR="$PLANNING_DIR" "$@" <<< "$payload"
}

agent_state() {
  jq -r --arg name "$1" '.agents[$name].state' "$MANIFEST"
}

issue_owned_contract() {
  bash "$REPO_ROOT/scripts/task-contract.sh" issue "$TEST_ROOT" "$1" \
    --command test --role python-engineer --team "$2" --job "implement owned script" \
    --write-allowance scripts/owned.sh
}

write_manifest_entry() {
  local name="$1" role="$2" state="$3" allowances="$4" contract_path="$5"
  jq -n --arg name "$name" --arg role "$role" --arg state "$state" --argjson allowances "$allowances" \
    --arg root "$TEST_ROOT" --arg path "$contract_path" \
    --arg id "$(jq -r '.contract_id' "$contract_path")" --arg digest "$(jq -r '.contract_digest' "$contract_path")" '
    {agents: {($name): {
      name: $name, role: $role, state: $state, project_root: $root, write_allowances: $allowances,
      contract_enabled: true, contract_path: $path, contract_id: $id, contract_digest: $digest,
      task_identity: $id, created_at: "2026-08-09T12:00:00Z", last_activity_at: "2026-08-09T12:00:00Z"
    }}}' > "$MANIFEST"
}

write_contract_and_manifest() {
  local state="${1:-running}"
  write_manifest_entry "$ENGINEER" python-engineer "$state" '["scripts/owned.sh"]' "$(issue_owned_contract task-10 solo)"
}

write_idle_sleep_shim() {
  local bin="$TEST_ROOT/idle-bin"
  mkdir -p "$bin"
  cat > "$bin/sleep" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "120" ] || exit 9
printf '%s\n' "$1" > "$MERIDIAN_TEST_SLEEP_LOG"
EOF
  chmod +x "$bin/sleep"
  printf '%s\n' "$bin"
}

prepare_planning_dir() {
  case "$1" in
    absent) rm -rf "$PLANNING_DIR" ;;
    no-manifest) ;;
    empty-manifest) printf '%s\n' '{"agents":{}}' > "$MANIFEST" ;;
    malformed) printf '{not valid json\n' > "$MANIFEST" ;;
    dangling) ln -s "$TEST_ROOT/nowhere.json" "$MANIFEST" ;;
  esac
}

@test "agent-lifecycle: a missing manifest is a silent no-op and a broken or unreadable one fails with its status" {
  local label setup_kind command event agent expected shim_dir="$TEST_ROOT/scripts"
  local -a words
  while IFS='@' read -r label setup_kind command event agent; do
    [ -n "$label" ] || continue
    prepare_planning_dir "$setup_kind"
    read -ra words <<< "$command"
    run_lifecycle "$(event_payload "$event" "$agent")" bash "$SCRIPT" "${words[@]}"
    [ "$status" -eq 0 ] || { echo "case=$label status=$status stdout=$output stderr=$stderr" >&2; return 1; }
    [ -z "$output" ] || { echo "case=$label unexpected stdout=$output" >&2; return 1; }
    [ -z "$stderr" ] || { echo "case=$label unexpected stderr=$stderr" >&2; return 1; }
    mkdir -p "$PLANNING_DIR"
    rm -f "$MANIFEST"
  done <<'CASES'
idle-without-planning-dir@absent@idle@TeammateIdle@meridian-python-engineer-calm-fox
check-without-planning-dir@absent@check@TeammateIdle@meridian-python-engineer-calm-fox
touch-start-without-planning-dir@absent@touch start@SubagentStart@meridian-python-engineer-calm-fox
touch-stop-without-planning-dir@absent@touch stop@SubagentStop@meridian-python-engineer-calm-fox
touch-start-without-manifest@no-manifest@touch start@SubagentStart@meridian-python-engineer-calm-fox
touch-for-unknown-agent@empty-manifest@touch@SubagentStart@unknown-agent
CASES

  while IFS='@' read -r label setup_kind command expected; do
    [ -n "$label" ] || continue
    rm -f "$MANIFEST"
    prepare_planning_dir "$setup_kind"
    run_lifecycle "$(event_payload TeammateIdle "$ENGINEER")" bash "$SCRIPT" "$command"
    [ "$status" -eq 1 ] || { echo "case=$label status=$status stdout=$output stderr=$stderr" >&2; return 1; }
    [ -z "$output" ] || { echo "case=$label unexpected stdout=$output" >&2; return 1; }
    [ "$stderr" = "$expected" ] || { echo "case=$label stderr=$stderr expected=$expected" >&2; return 1; }
  done <<'CASES'
malformed-on-sweep@malformed@sweep@agent_manifest_status=malformed
malformed-on-idle@malformed@idle@agent_manifest_status=malformed
dangling-symlink@dangling@sweep@agent_manifest_status=unavailable
CASES

  rm -f "$MANIFEST"
  mkdir -p "$shim_dir"
  cp "$SCRIPT" "$shim_dir/agent-lifecycle.sh"
  run env MERIDIAN_PLANNING_DIR="$PLANNING_DIR" bash "$shim_dir/agent-lifecycle.sh" sweep
  [ "$status" -ne 0 ]
  [ "$output" = "agent_manifest_status=unavailable" ]

  [ "$(id -u)" -ne 0 ] || skip "root ignores directory permissions"
  chmod 000 "$PLANNING_DIR"
  run --separate-stderr env MERIDIAN_PLANNING_DIR="$PLANNING_DIR" bash "$SCRIPT" sweep
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "agent_manifest_status=unavailable" ]
}

@test "agent-lifecycle: only a native start event promotes a registered known agent" {
  local label payload expected
  while IFS='@' read -r label payload expected; do
    [ -n "$label" ] || continue
    write_contract_and_manifest registered
    run_lifecycle "$payload" MERIDIAN_LIFECYCLE_NOW=1786280400 bash "$SCRIPT" touch start
    [ "$status" -eq 0 ] || { echo "case=$label status=$status stdout=$output stderr=$stderr" >&2; return 1; }
    [ "$(agent_state "$ENGINEER")" = "$expected" ] \
      || { echo "case=$label state=$(agent_state "$ENGINEER") expected=$expected" >&2; return 1; }
  done <<'CASES'
native-start-event@{"hook_event_name":"SubagentStart","agent_type":"meridian-python-engineer-calm-fox"}@running
self-reported-state@{"agent_type":"meridian-python-engineer-calm-fox","state":"running"}@registered
CASES
}

@test "agent-lifecycle: the unmatched TeammateIdle hook stops an idle contracted teammate only after revalidation and a valid contract" {
  local label name role team allowances contract bin sleep_log="$TEST_ROOT/sleep.log"
  local active_bin="$TEST_ROOT/bin" contract_path
  run jq -e '
    .hooks.TeammateIdle | length == 1
    and (.[0] | has("matcher") | not)
    and .[0].hooks[0].timeout == 135
    and (.[0].hooks[0].command | contains("agent-lifecycle.sh idle"))
    and (.[0].hooks | length == 1)
  ' "$REPO_ROOT/hooks/hooks.json"
  [ "$status" -eq 0 ]

  bin=$(write_idle_sleep_shim)
  mkdir -p "$TEST_ROOT/.claude/agents"
  while IFS='@' read -r label name role team allowances; do
    [ -n "$label" ] || continue
    contract=$(issue_owned_contract "task-$label" "$team")
    write_manifest_entry "$name" "$role" running "$allowances" "$contract"
    printf 'generated definition\n' > "$TEST_ROOT/.claude/agents/$name.md"
    rm -f "$sleep_log"

    run_lifecycle "$(event_payload TeammateIdle "$name")" PATH="$bin:$PATH" MERIDIAN_TEST_SLEEP_LOG="$sleep_log" \
      MERIDIAN_LIFECYCLE_NOW=1786280400 bash "$SCRIPT" idle

    [ "$status" -eq 0 ] || { echo "case=$label status=$status stdout=$output stderr=$stderr" >&2; return 1; }
    [ "$(jq -r '.continue' <<< "$output")" = "false" ] || { echo "case=$label output=$output" >&2; return 1; }
    [[ "$(jq -r '.stopReason' <<< "$output")" == *"shell-observed inactivity"* ]] || { echo "case=$label output=$output" >&2; return 1; }
    [ "$(agent_state "$name")" = "expired" ] || { echo "case=$label state=$(agent_state "$name")" >&2; return 1; }
    [ "$(jq -r --arg name "$name" '.agents[$name].idle_observed_by' "$MANIFEST")" = "TeammateIdle" ] \
      || { echo "case=$label idle_observed_by missing" >&2; return 1; }
    [ -f "$TEST_ROOT/.claude/agents/$name.md" ] || { echo "case=$label definition was removed" >&2; return 1; }
    [ "$(cat "$sleep_log")" = "120" ] || { echo "case=$label sleep log=$(cat "$sleep_log")" >&2; return 1; }
  done <<'CASES'
solo-engineer@meridian-python-engineer-calm-fox@python-engineer@solo@["scripts/owned.sh"]
paired-critic@meridian-python-critic-calm-owl@python-critic@pair@[]
CASES

  write_contract_and_manifest running
  mkdir -p "$active_bin"
  cat > "$active_bin/sleep" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "120" ] || exit 9
printf '%s\n' "$1" > "$MERIDIAN_TEST_SLEEP_LOG"
tmp="${MERIDIAN_TEST_MANIFEST}.tmp"
jq 'del(.agents["meridian-python-engineer-calm-fox"].idle_observation_token) | .agents["meridian-python-engineer-calm-fox"].last_activity_at = "2026-08-09T13:00:01Z"' "$MERIDIAN_TEST_MANIFEST" > "$tmp" && mv "$tmp" "$MERIDIAN_TEST_MANIFEST"
EOF
  chmod +x "$active_bin/sleep"
  rm -f "$sleep_log"
  run_lifecycle "$(event_payload TeammateIdle "$ENGINEER")" PATH="$active_bin:$PATH" MERIDIAN_TEST_SLEEP_LOG="$sleep_log" \
    MERIDIAN_TEST_MANIFEST="$MANIFEST" MERIDIAN_LIFECYCLE_NOW=1786280400 bash "$SCRIPT" idle
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(agent_state "$ENGINEER")" = "running" ]
  [ "$(cat "$sleep_log")" = "120" ]

  write_contract_and_manifest running
  contract_path=$(jq -r --arg name "$ENGINEER" '.agents[$name].contract_path' "$MANIFEST")
  jq '.created_by = "worker"' "$contract_path" > "$TEST_ROOT/contract.tmp"
  mv "$TEST_ROOT/contract.tmp" "$contract_path"

  run env MERIDIAN_PLANNING_DIR="$PLANNING_DIR" bash "$SCRIPT" idle <<< "$(event_payload TeammateIdle "$ENGINEER")"

  [ "$status" -ne 0 ]
  [ "$output" = "agent_contract_status=invalid" ]
  [ "$(agent_state "$ENGINEER")" = "running" ]
}

@test "agent-lifecycle: tmux session start fails closed on a malformed runtime registry and heartbeats a bound agent" {
  local control_root="$TEST_ROOT/control" bound_root="$TEST_ROOT/project/.meridian"
  mkdir -p "$control_root/.runtime/tmux-bus"
  printf '{not valid json\n' > "$control_root/.runtime/tmux-bus/registry.json"

  run env \
    MERIDIAN_CONTROL_ROOT="$control_root" \
    MERIDIAN_TMUX_AGENT=1 \
    MERIDIAN_TMUX_AGENT_ID=agent-a \
    MERIDIAN_TMUX_CONTRACT_ID=contract-a \
    MERIDIAN_TMUX_CAPABILITY=0123456789abcdef0123456789abcdef \
    CLAUDE_SESSION_ID=agent-session-a \
    bash "$SCRIPT" tmux-session-start

  [ "$status" -ne 0 ]
  [ "$output" = "tmux_lifecycle_status=malformed" ]

  build_tmux_registry_fixture "$bound_root"
  run env \
    MERIDIAN_CONTROL_ROOT="$bound_root" \
    MERIDIAN_TMUX_AGENT=1 \
    MERIDIAN_TMUX_AGENT_ID=agent-a \
    CLAUDE_SESSION_ID=agent-session-a \
    bash "$SCRIPT" tmux-session-start
  [ "$status" -eq 0 ]
  [ "$output" = "tmux_lifecycle_status=running" ]
  run jq -e '.agents[] | select(.agent_id == "agent-a") | .state == "running" and (.heartbeat_at_ms | type == "number")' "$bound_root/.runtime/tmux-bus/registry.json"
  [ "$status" -eq 0 ]
}

build_tmux_registry_fixture() {
  local control_root="$1" hash registry capability
  mkdir -p "$control_root"
  printf '%s\n' '{}' > "$control_root/config.json"
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
  capability=$(tmux_runtime_capability)
  hash=$(tmux_runtime_capability_hash "$capability")
  registry=$(jq -n --arg main main-session --arg hash "$hash" --arg agent_hash "$hash" '{
    schema_version: 2,
    main: {agent_id: $main, session_id: $main, role: "orchestrator", capability_hash: $hash},
    tmux: {session: null, orchestrator_target: null, orchestrator_pane: null, topology: "pending", managed_session: false, ownership_token: null},
    agents: [{
      agent_id: "agent-a", parent_id: $main, contract_id: "contract-a", generated_name: "agent-a",
      tmux_target: "meridian-test:0.1", tmux_pane_id: null, claude_session_id: "agent-session-a",
      capability_hash: $agent_hash, state: "registered", heartbeat_at_ms: null
    }],
    routes: {($main): {inbox: $main, tmux_target: null}, "agent-a": {inbox: "agent-a", tmux_target: "meridian-test:0.1"}}
  }')
  tmux_runtime_write_registry_route_bundle "$registry"
  tmux_runtime_initialize_inbox main-session
  tmux_runtime_initialize_inbox agent-a
}

