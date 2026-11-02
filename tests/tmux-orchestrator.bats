#!/usr/bin/env bats

load gate_case_helper
load gate_case_files
load rejection_case_helper
load test_helper
load tmux_config_fixture
load tmux_watchdog_fixture

setup() {
  unset TMUX TMUX_PANE
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  ORCHESTRATOR="$REPO_ROOT/scripts/tmux-agent-orchestrator.sh"
  BUS="$REPO_ROOT/scripts/tmux-bus.sh"
  TEST_ROOT="$(mktemp -d)"
  PROJECT_ROOT="$TEST_ROOT/project"
  CONTROL_ROOT="$PROJECT_ROOT/.lbwc-planning"
  BIN_DIR="$TEST_ROOT/bin"
  TMUX_TMPDIR="$TEST_ROOT/tmux"
  TMUX_SERVER="lbwc-$RANDOM-$$"
  command -v tmux >/dev/null 2>&1 || skip "tmux is unavailable"
  command -v jq >/dev/null 2>&1 || skip "jq is unavailable"
  mkdir -p "$CONTROL_ROOT" "$BIN_DIR" "$TMUX_TMPDIR"
  export LBWC_TEST_CHILD_PATH="$BIN_DIR:$PATH"
  export LBWC_TEST_CHILD_SHELL="$(command -v bash)"
  printf '%s\n' '{}' > "$CONTROL_ROOT/config.json"
  cat > "$BIN_DIR/claude" <<'SCRIPT'
#!/usr/bin/env bash
if [ -n "${LBWC_TEST_FAST_CHILD_ENV:-}" ]; then
  set -a
  . "$LBWC_TEST_FAST_CHILD_ENV"
  set +a
  [ -n "${LBWC_TMUX_AGENT:-}" ] && [ -n "${LBWC_TMUX_CONTROL_ROOT:-}" ] && [ -n "${LBWC_TMUX_AGENT_ID:-}" ] && [ -n "${LBWC_TMUX_CONTRACT_ID:-}" ] || exit 1
  [ -z "${LBWC_TMUX_CAPABILITY:-}" ] && [ -z "${LBWC_TMUX_BINDING_TOKEN:-}" ] && [ -z "${LBWC_TMUX_BOOTSTRAP_ID:-}" ] || exit 1
  registry="$LBWC_TMUX_CONTROL_ROOT/.runtime/tmux-bus/registry.json"
  child_status=1
  if [ -d "$LBWC_TMUX_CONTROL_ROOT/.runtime/tmux-bus/inboxes/$LBWC_TMUX_AGENT_ID/acked" ] && jq -e --arg agent_id "$LBWC_TMUX_AGENT_ID" --arg contract_id "$LBWC_TMUX_CONTRACT_ID" 'any(.agents[]; .agent_id == $agent_id and .contract_id == $contract_id and .claude_session_id == null) and .routes[$agent_id].inbox == $agent_id' "$registry" >/dev/null 2>&1; then
    child_status=0
  fi
  export CLAUDE_SESSION_ID=fast-child-session
  printf '%s\n' "$TMUX_PANE" > "$LBWC_TEST_FAST_CHILD_PANE"
  bash "$LBWC_TEST_SESSION_START" > "$LBWC_TEST_FAST_CHILD_OUTPUT" 2>&1 || child_status=1
  printf '%s\n' "$child_status" > "$LBWC_TEST_FAST_CHILD_STATUS"
  [ "$child_status" -eq 0 ] || exit 1
  printf '%s\n' started > "$LBWC_TEST_FAST_CHILD_STARTED"
  trap 'printf "%s\n" stopped > "$LBWC_TEST_FAST_CHILD_EXIT"; exit 0' HUP INT TERM
  printf '%s\n' ready > "$LBWC_TEST_FAST_CHILD_READY"
  while [ ! -e "$LBWC_TEST_FAST_CHILD_RELEASE" ]; do
    sleep 0.05
  done
  printf '%s\n' released > "$LBWC_TEST_FAST_CHILD_EXIT"
  exit 0
fi
exec sleep 30
SCRIPT
  chmod +x "$BIN_DIR/claude"
  cp "$BATS_TEST_DIRNAME/tmux_orchestrator_proxy.bash" "$BIN_DIR/tmux"
  chmod +x "$BIN_DIR/tmux"
  export LBWC_TEST_JQ_BINARY="$(command -v jq)"
  cat > "$BIN_DIR/jq" <<'SCRIPT'
#!/usr/bin/env bash
if [ -n "${LBWC_TEST_JQ_FAIL_MATCH:-}" ]; then
  case "$*" in
    *"$LBWC_TEST_JQ_FAIL_MATCH"*)
      count=0
      [ -f "$LBWC_TEST_JQ_COUNTER" ] && count=$(cat "$LBWC_TEST_JQ_COUNTER")
      count=$((count + 1))
      printf '%s\n' "$count" > "$LBWC_TEST_JQ_COUNTER"
      [ "$count" -ne "$LBWC_TEST_JQ_FAIL_NTH" ] || exit 1
      ;;
  esac
fi
exec "$LBWC_TEST_JQ_BINARY" "$@"
SCRIPT
  chmod +x "$BIN_DIR/jq"
  export LBWC_TEST_TMUX_BINARY="$(command -v tmux)"
  export LBWC_TEST_TMUX_SERVER="$TMUX_SERVER"
  export LBWC_TEST_PYTHON3="$(command -v python3)"
  cat > "$BIN_DIR/python3" <<'SCRIPT'
#!/usr/bin/env bash
if [ "${LBWC_TEST_FAIL_WRITE:-}" = registry ]; then
  for arg in "$@"; do
    case "$arg" in registry.json) exit 1 ;; esac
  done
fi
if [ "${LBWC_TEST_FAIL_WRITE:-}" = routing ]; then
  for arg in "$@"; do
    case "$arg" in routing-table.json) exit 1 ;; esac
  done
fi
exec "$LBWC_TEST_PYTHON3" "$@"
SCRIPT
  chmod +x "$BIN_DIR/python3"
}

teardown() {
  TMUX_TMPDIR="$TMUX_TMPDIR" tmux -L "$TMUX_SERVER" kill-server >/dev/null 2>&1 || true
  rm -rf "$TEST_ROOT"
}

run_orchestrator() {
  local args=("$@")
  if [ "${1:-}" != provision ] && [ -n "${MAIN_CAPABILITY:-}" ]; then
    args+=(--orchestrator-id main-session --orchestrator-session-id main-session --orchestrator-capability "$MAIN_CAPABILITY")
  fi
  run env -u TMUX -u TMUX_PANE PATH="$BIN_DIR:$PATH" TMUX_TMPDIR="$TMUX_TMPDIR" bash "$ORCHESTRATOR" "${args[@]}"
}

provision_main() {
  run_orchestrator provision --project-root "$PROJECT_ROOT" --control-root "$CONTROL_ROOT" --main-id main-session
  [ "$status" -eq 0 ]
  MAIN_CAPABILITY="$(jq -r '.main_capability' <<<"$output")"
}

prepare_tmux_agents() {
  local name contract contract_id contract_digest definition_path definition_digest manifest entry definitions='[]' canonical_project_root canonical_control_root
  mkdir -p "$PROJECT_ROOT/.claude/agents"
  canonical_project_root="$(cd "$PROJECT_ROOT" && pwd -P)"
  canonical_control_root="$(cd "$CONTROL_ROOT" && pwd -P)"
  for name in "$@"; do
    contract=$(bash "$REPO_ROOT/scripts/task-contract.sh" issue "$PROJECT_ROOT" "$name" \
      --command team --role web-engineer --team solo --job "spawn $name" \
      --control-root "$CONTROL_ROOT" --runtime-kind native-team \
      --communication-policy native-team --requested-backend tmux --resolved-backend tmux \
      --write-capability directory:.) || return 1
    contract_id="$(basename "$contract" .json)"
    bash "$REPO_ROOT/scripts/task-contract.sh" state "$PROJECT_ROOT" "$contract_id" dispatched >/dev/null || return 1
    contract_digest="$(jq -r '.contract_digest' "$contract")"
    definition_path="$canonical_project_root/.claude/agents/$name.md"
    printf '%s\n' "generated definition for $name" > "$definition_path"
    definition_digest="$(shasum -a 256 "$definition_path" | cut -d ' ' -f 1)"
    manifest="${manifest:-$( [ -f "$CONTROL_ROOT/.agent-manifest.json" ] && cat "$CONTROL_ROOT/.agent-manifest.json" || printf '%s' '{"agents":{}}' )}"
    entry=$(jq -cn \
      --arg name "$name" --arg root "$canonical_project_root" --arg control_root "$canonical_control_root" \
      --arg definition_path "$definition_path" --arg definition_digest "$definition_digest" \
      --arg contract_path "$contract" --arg contract_id "$contract_id" --arg contract_digest "$contract_digest" '
      {name:$name,role:"web-engineer",project_root:$root,control_root:$control_root,schema_version:3,
       definition_path:$definition_path,definition_sha256:$definition_digest,definition_authority:"generated-definition",
       state:"registered",model:"test-model",effort:"high",max_turns:1,contract_enabled:true,
       contract_path:$contract_path,contract_id:$contract_id,contract_digest:$contract_digest,task_identity:$contract_id,
       capabilities:[{access:"write",kind:"directory",path:"."}],write_allowances:["."],
       runtime_kind:"native-team",communication_policy:"native-team",
       execution:{role:"web-engineer",model:"test-model",effort:"high",max_turns:1,contract_id:$contract_id,
         contract_digest:$contract_digest,task_identity:$contract_id,requested_backend:"tmux",resolved_backend:"tmux",
         tmux_bootstrap:{child_identity:$name,contract_id:$contract_id,control_root:$control_root}}}') || return 1
    manifest=$(jq -c --arg name "$name" --argjson entry "$entry" '.agents[$name] = $entry' <<<"$manifest") || return 1
    definitions=$(jq -c --arg name "$name" --arg contract_id "$contract_id" --arg contract_digest "$contract_digest" \
      '. + [{agent_id:$name,generated_name:$name,contract_id:$contract_id,contract_digest:$contract_digest}]' <<<"$definitions") || return 1
  done
  printf '%s\n' "$manifest" > "$CONTROL_ROOT/.agent-manifest.json"
  printf '%s\n' "$definitions"
}

run_orchestrator_unauthenticated() {
  run env -u TMUX -u TMUX_PANE PATH="$BIN_DIR:$PATH" TMUX_TMPDIR="$TMUX_TMPDIR" bash "$ORCHESTRATOR" "$@"
}

wait_for_result() {
  local path="$1" attempts=0
  until [ -f "$path" ]; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 100 ] || return 1
    sleep 0.1
  done
}

wait_for_binding() {
  local agent_id="$1" attempts=0 registry="$CONTROL_ROOT/.runtime/tmux-bus/registry.json"
  until jq -e --arg agent_id "$agent_id" '.agents[] | select(.agent_id == $agent_id) | .claude_session_id == "fast-child-session"' "$registry" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 100 ] || return 1
    sleep 0.05
  done
}

bus_state_digest() {
  shasum -a 256 "$CONTROL_ROOT/.runtime/tmux-bus/registry.json" "$CONTROL_ROOT/.runtime/tmux-bus/routing-table.json"
}

registry_file() {
  printf '%s' "$CONTROL_ROOT/.runtime/tmux-bus/registry.json"
}

routing_file() {
  printf '%s' "$CONTROL_ROOT/.runtime/tmux-bus/routing-table.json"
}

provisioned_session() {
  jq -r '.tmux.session' "$(registry_file)"
}

tmux_on_test_server() {
  TMUX_TMPDIR="$TMUX_TMPDIR" tmux -L "$TMUX_SERVER" "$@"
}

pane_count() {
  tmux_on_test_server list-panes -t "$1" -F '#{pane_index}' | wc -l | tr -d ' '
}

pane_ids() {
  tmux_on_test_server list-panes -t "$1" -F '#{pane_id}'
}

split_group() {
  run_orchestrator split-group --project-root "$PROJECT_ROOT" --control-root "$CONTROL_ROOT" --session "$1" --agents "$2"
}

reset_world() {
  tmux_on_test_server kill-server >/dev/null 2>&1 || true
  rm -rf "$PROJECT_ROOT"
  mkdir -p "$CONTROL_ROOT"
  printf '%s\n' '{}' > "$CONTROL_ROOT/config.json"
  MAIN_CAPABILITY=""
}

prepare_world() {
  local agents="$1" config="$2"
  reset_world
  [ "$config" = - ] || printf '%s\n' "$config" > "$CONTROL_ROOT/config.json"
  provision_main
  SESSION="$(provisioned_session)"
  DEFINITIONS='[]'
  [ "$agents" = none ] || DEFINITIONS="$(prepare_tmux_agents $agents)"
}

mutate_none() { :; }

mutate_extra_definition_key() {
  DEFINITIONS=$(jq '.[0].messaging_socket = "/tmp/lbwc-worker-a.sock"' <<<"$DEFINITIONS")
}

mutate_generated_name() {
  DEFINITIONS=$(jq '.[0].generated_name = "other-agent"' <<<"$DEFINITIONS")
}

mutate_contract_id() {
  DEFINITIONS=$(jq '.[0].contract_id = "synthetic-contract"' <<<"$DEFINITIONS")
}

mutate_contract_digest() {
  DEFINITIONS=$(jq '.[0].contract_digest = ("0" * 64)' <<<"$DEFINITIONS")
}

mutate_backend_drift() {
  jq '.agents["worker-a"].execution.resolved_backend = "in_process"' "$CONTROL_ROOT/.agent-manifest.json" > "$TEST_ROOT/manifest.json"
  mv "$TEST_ROOT/manifest.json" "$CONTROL_ROOT/.agent-manifest.json"
}

mutate_absent_manifest() {
  DEFINITIONS='[{"agent_id":"worker-a","generated_name":"worker-a","contract_id":"contract-a","contract_digest":"0000000000000000000000000000000000000000000000000000000000000000"}]'
}

mutate_invalid_layout() {
  printf '%s\n' '{"tmux":{"layout":"bogus-layout"}}' > "$CONTROL_ROOT/config.json"
}

inject_failure() {
  local spec="$1" jq_spec
  case "$spec" in
    split-counter)
      rm -f "$TEST_ROOT/split-count"
      export LBWC_TEST_SPLIT_COUNTER="$TEST_ROOT/split-count" ;;
    send-keys)
      rm -f "$TEST_ROOT/send-keys-count"
      export LBWC_TEST_SEND_KEYS_COUNTER="$TEST_ROOT/send-keys-count" LBWC_TEST_FAIL_SEND_KEYS_AFTER=1 ;;
    routing-write) export LBWC_TEST_FAIL_WRITE=routing ;;
    registry-write) export LBWC_TEST_FAIL_WRITE=registry ;;
    layout-select) export LBWC_TEST_FAIL_LAYOUT=1 ;;
    jq:*)
      jq_spec="${spec#jq:}"
      rm -f "$TEST_ROOT/jq-count"
      export LBWC_TEST_JQ_FAIL_MATCH="${jq_spec%@*}" LBWC_TEST_JQ_FAIL_NTH="${jq_spec##*@}" LBWC_TEST_JQ_COUNTER="$TEST_ROOT/jq-count" ;;
  esac
}

clear_failures() {
  unset LBWC_TEST_SPLIT_COUNTER LBWC_TEST_SEND_KEYS_COUNTER LBWC_TEST_FAIL_SEND_KEYS_AFTER LBWC_TEST_FAIL_WRITE \
    LBWC_TEST_FAIL_LAYOUT LBWC_TEST_JQ_FAIL_MATCH LBWC_TEST_JQ_FAIL_NTH LBWC_TEST_JQ_COUNTER
}

assert_exit_status() {
  local expected="$1"
  case "$expected" in
    nonzero) [ "$status" -ne 0 ] ;;
    *) [ "$status" -eq "$expected" ] ;;
  esac
}

expect_output_is() {
  [ "$output" = "$2" ] || record_case_failure "$1" "output=[$output] want=[$2]"
}

expect_registry_jq() {
  jq -e "$2" "$(registry_file)" >/dev/null 2>&1 || record_case_failure "$1" "registry filter failed=[$2] registry=$(cat "$(registry_file)" 2>&1)"
}

provision_attempt() {
  run_orchestrator provision --project-root "$PROJECT_ROOT" --control-root "$CONTROL_ROOT" --main-id main-session "$@"
}

split_agent() {
  run_orchestrator split-agent --project-root "$PROJECT_ROOT" --control-root "$CONTROL_ROOT" --session "$SESSION" --name worker-a --agent "$1"
}

@test "provision rejects an unknown flag, removes its runtime after a registry failure, and titles pane borders" {
  reset_case_failures

  provision_attempt --cancel
  expect_rejected unknown-cancel-flag ""
  expect_no_path unknown-cancel-flag-mints-no-registry "$(registry_file)"

  reset_world
  export LBWC_TEST_FAIL_WRITE=registry
  provision_attempt
  unset LBWC_TEST_FAIL_WRITE
  expect_rejected registry-write-fails ""
  expect_no_path registry-write-fails-removes-runtime "$CONTROL_ROOT/.runtime"

  prepare_world none -
  run tmux_on_test_server show-options -v -t "$SESSION" pane-border-status
  expect_status pane-border-status 0
  expect_output_is pane-border-status-value top
  run tmux_on_test_server show-options -v -t "$SESSION" pane-border-format
  expect_status pane-border-format 0
  expect_output_is pane-border-format-value '#{pane_title}'

  assert_no_case_failures
}

@test "bus init refuses an unprovisioned bus and shares one schema and main route after provision" {
  reset_case_failures

  run env PATH="$BIN_DIR:$PATH" bash "$BUS" --control-root "$CONTROL_ROOT" init --main-id main-session --main-session-id main-session
  expect_rejected init-without-provision "bus is not provisioned"
  expect_no_path init-without-provision-mints-no-registry "$(registry_file)"

  provision_main
  run env PATH="$BIN_DIR:$PATH" bash "$BUS" --control-root "$CONTROL_ROOT" init --main-id main-session --main-session-id main-session --orchestrator-capability "$MAIN_CAPABILITY"
  expect_status init-after-provision 0
  expect_registry_jq init-after-provision-schema '.schema_version == 2 and .tmux.topology == "detached-new-session" and .routes["main-session"].inbox == "main-session"'

  assert_no_case_failures
}

@test "split-agent resolves the exact manifest contract and rejects a generated identity that differs from its agent id" {
  reset_case_failures

  prepare_world worker-a -
  split_agent worker-a
  expect_status matching-identity 0
  expect_registry_jq matching-identity-uses-manifest-contract '.agents | any(.[]; (.agent_id == "worker-a") and (.contract_id | startswith("cmd-team-worker-a-")))'

  prepare_world worker-a -
  split_agent other-agent
  expect_rejected mismatched-identity "agent and generated identities must match"
  expect_registry_jq mismatched-identity-registers-nothing '.agents | length == 0'

  assert_no_case_failures
}

@test "split-group rejects invalid requests before any runtime mutation" {
  local label agents config mutate expected_status fragment registry_before panes_before
  while IFS=';' read -r label agents config mutate expected_status fragment; do
    [ -n "$label" ] || continue
    prepare_world "$agents" "$config"
    "$mutate"
    registry_before="$(cat "$(registry_file)")"
    panes_before="$(pane_ids "$SESSION")"

    split_group "$SESSION" "$DEFINITIONS"

    assert_exit_status "$expected_status" || { echo "case=$label status=$status output=$output" >&2; return 1; }
    [ "$fragment" = - ] || [[ "$output" == *"$fragment"* ]] \
      || { echo "case=$label missing=[$fragment] output=$output" >&2; return 1; }
    [ "$(cat "$(registry_file)")" = "$registry_before" ] || { echo "case=$label registry changed" >&2; return 1; }
    [ "$(pane_ids "$SESSION")" = "$panes_before" ] || { echo "case=$label panes changed" >&2; return 1; }
  done <<'CASES'
extra-definition-key;worker-a;-;mutate_extra_definition_key;nonzero;-
mismatched-generated-name;worker-a;-;mutate_generated_name;nonzero;agent and generated identities must match
synthetic-contract-identity;worker-a;-;mutate_contract_id;nonzero;contract identity does not match generated manifest
tampered-contract-digest;worker-a;-;mutate_contract_digest;nonzero;contract digest does not match generated manifest
frozen-backend-drift;worker-a;-;mutate_backend_drift;nonzero;backend metadata does not match the contract
missing-generated-manifest;none;-;mutate_absent_manifest;nonzero;generated agent manifest is missing
agent-limit-exceeded;worker-a worker-b;{"tmux":{"max_agents":1}};mutate_none;nonzero;agent limit exceeded
invalid-layout-in-config;worker-a;-;mutate_invalid_layout;1;tmux layout is invalid
CASES
}

@test "kill-agent retries persisted teardown after a registry write failure" {
  provision_main
  local session definitions target
  session="$(provisioned_session)"
  definitions="$(prepare_tmux_agents worker-a)"
  split_group "$session" "$definitions"
  [ "$status" -eq 0 ]
  target="$(jq -r '.agents[] | select(.agent_id == "worker-a") | .tmux_target' "$(registry_file)")"

  export LBWC_TEST_FAIL_WRITE=registry
  run_orchestrator kill-agent --project-root "$PROJECT_ROOT" --control-root "$CONTROL_ROOT" --target "$target"
  unset LBWC_TEST_FAIL_WRITE
  [ "$status" -ne 0 ]
  [ -f "$CONTROL_ROOT/.runtime/tmux-bus/transactions/teardown-worker-a.json" ]
  run jq -e '.agents[] | select(.agent_id == "worker-a") | .state != "shutdown"' "$(registry_file)"
  [ "$status" -eq 0 ]

  run_orchestrator kill-agent --project-root "$PROJECT_ROOT" --control-root "$CONTROL_ROOT" --target "$target"
  [ "$status" -eq 0 ]
  [ ! -e "$CONTROL_ROOT/.runtime/tmux-bus/transactions/teardown-worker-a.json" ]
  run jq -e '.agents[] | select(.agent_id == "worker-a") | .state == "shutdown"' "$(registry_file)"
  [ "$status" -eq 0 ]
}

@test "split-group rolls back panes, identities, and bus state after any mid-split failure" {
  local label agents inject expected_status digest_before
  while IFS=';' read -r label agents inject expected_status; do
    [ -n "$label" ] || continue
    prepare_world "$agents" -
    digest_before="$(bus_state_digest)"
    inject_failure "$inject"

    split_group "$SESSION" "$DEFINITIONS"
    clear_failures

    assert_exit_status "$expected_status" || { echo "case=$label status=$status output=$output" >&2; return 1; }
    [ "$(pane_count "$SESSION")" = 1 ] || { echo "case=$label panes=$(pane_count "$SESSION")" >&2; return 1; }
    [ "$(jq '.agents | length' "$(registry_file)")" = 0 ] || { echo "case=$label agents left in registry" >&2; return 1; }
    [ "$(jq '.routes | keys | length' "$(routing_file)")" = 1 ] || { echo "case=$label routes left behind" >&2; return 1; }
    [ ! -e "$CONTROL_ROOT/.runtime/tmux-bus/credentials/worker-a.json" ] || { echo "case=$label credential left behind" >&2; return 1; }
    [ ! -e "$CONTROL_ROOT/.runtime/tmux-bus/inboxes/worker-a" ] || { echo "case=$label inbox left behind" >&2; return 1; }
    [ "$(bus_state_digest)" = "$digest_before" ] || { echo "case=$label bus state changed" >&2; return 1; }
  done <<'CASES'
later-member-split-fails;worker-a worker-b;split-counter;nonzero
later-member-launch-fails;worker-a worker-b;send-keys;nonzero
routing-table-write-fails;worker-a;routing-write;nonzero
layout-select-fails;worker-a;layout-select;nonzero
registry-write-fails;worker-a;registry-write;nonzero
jq-fails-clearing-panes;worker-a;jq:panes:[]@1;1
jq-fails-first-append;worker-a;jq:+= [$value]@1;1
jq-fails-second-append;worker-a;jq:+= [$value]@2;1
jq-fails-capability-write;worker-a;jq:capability: $capability@1;1
jq-fails-transpose;worker-a;jq:transpose@1;1
CASES
}

@test "child SessionStart binds once and records a heartbeat" {
  export LBWC_TEST_FAST_CHILD_ENV="$TEST_ROOT/fast-child.env"
  export LBWC_TEST_FAST_CHILD_STATUS="$TEST_ROOT/fast-child.status"
  export LBWC_TEST_FAST_CHILD_OUTPUT="$TEST_ROOT/fast-child.output"
  export LBWC_TEST_FAST_CHILD_READY="$TEST_ROOT/fast-child.ready"
  export LBWC_TEST_FAST_CHILD_RELEASE="$TEST_ROOT/fast-child.release"
  export LBWC_TEST_FAST_CHILD_PANE="$TEST_ROOT/fast-child.pane"
  export LBWC_TEST_FAST_CHILD_STARTED="$TEST_ROOT/fast-child.started"
  export LBWC_TEST_FAST_CHILD_EXIT="$TEST_ROOT/fast-child.exit"
  export LBWC_TEST_SESSION_START="$REPO_ROOT/scripts/session-start.sh"
  provision_main
  local session definitions
  session="$(provisioned_session)"
  definitions="$(prepare_tmux_agents worker-a)"

  split_group "$session" "$definitions"

  [ "$status" -eq 0 ]
  wait_for_result "$LBWC_TEST_FAST_CHILD_STATUS"
  [ "$(cat "$LBWC_TEST_FAST_CHILD_STATUS")" = 0 ] || { cat "$LBWC_TEST_FAST_CHILD_OUTPUT" >&3; false; }
  wait_for_binding worker-a || { cat "$LBWC_TEST_FAST_CHILD_OUTPUT" >&3; false; }
  run jq -e '.agents[] | select(.agent_id == "worker-a") | .state == "running" and (.heartbeat_at_ms | type == "number")' "$(registry_file)"
  [ "$status" -eq 0 ]
  [ ! -e "$CONTROL_ROOT/.runtime/tmux-bus/credentials/worker-a.json" ]
  : > "$LBWC_TEST_FAST_CHILD_RELEASE"
  wait_for_result "$LBWC_TEST_FAST_CHILD_EXIT"
  unset LBWC_TEST_FAST_CHILD_ENV LBWC_TEST_FAST_CHILD_STATUS LBWC_TEST_FAST_CHILD_OUTPUT LBWC_TEST_FAST_CHILD_READY LBWC_TEST_FAST_CHILD_RELEASE LBWC_TEST_FAST_CHILD_PANE LBWC_TEST_FAST_CHILD_STARTED LBWC_TEST_FAST_CHILD_EXIT LBWC_TEST_SESSION_START
}

@test "orchestration commands reject a child without the main capability" {
  provision_main
  local session label command fragment
  session="$(provisioned_session)"
  while IFS=';' read -r label command fragment; do
    [ -n "$label" ] || continue
    case "$command" in
      split-group)
        run_orchestrator_unauthenticated split-group --project-root "$PROJECT_ROOT" --control-root "$CONTROL_ROOT" --session "$session" \
          --agents '[{"agent_id":"worker-a","generated_name":"worker-a","contract_id":"contract-a"}]' ;;
      *)
        run_orchestrator_unauthenticated "$command" --project-root "$PROJECT_ROOT" --control-root "$CONTROL_ROOT" ;;
    esac

    [ "$status" -ne 0 ] || { echo "case=$label status=$status output=$output" >&2; return 1; }
    [ "$fragment" = - ] || [[ "$output" == *"$fragment"* ]] \
      || { echo "case=$label missing=[$fragment] output=$output" >&2; return 1; }
  done <<'CASES'
status;status;main orchestrator session and capability
focus-orchestrator;focus-orchestrator;-
split-group;split-group;-
CASES
}

@test "split-group accepts a generated manifest entry with a schema 3 contract and reads the layout only before panes exist" {
  reset_case_failures

  prepare_world worker-a -
  expect_jq manifest-entry-is-object "$CONTROL_ROOT/.agent-manifest.json" '.agents["worker-a"] | type == "object"'
  split_group "$SESSION" "$DEFINITIONS"
  expect_status generated-entry-accepted 0
  expect_registry_jq generated-entry-registered '.agents | any(.[]; .agent_id == "worker-a" and .generated_name == "worker-a")'
  expect_jq generated-route-has-no-socket "$(routing_file)" '.routes["worker-a"] | has("messaging_socket") | not'

  prepare_world worker-a '{"tmux":{"layout":"even-vertical"}}'
  export LBWC_TEST_CONFIG_PATH="$CONTROL_ROOT/config.json" LBWC_TEST_LAYOUT_AFTER_SPLIT=bogus-layout LBWC_TEST_SELECT_LAYOUT_LOG="$TEST_ROOT/select-layout.log"
  split_group "$SESSION" "$DEFINITIONS"
  unset LBWC_TEST_CONFIG_PATH LBWC_TEST_LAYOUT_AFTER_SPLIT LBWC_TEST_SELECT_LAYOUT_LOG
  expect_status layout-read-once 0
  [ "$(cat "$TEST_ROOT/select-layout.log")" = "select-layout -t $SESSION even-vertical" ] \
    || record_case_failure layout-read-once-uses-initial-layout "log=$(cat "$TEST_ROOT/select-layout.log" 2>&1)"

  assert_no_case_failures
}

@test "rollback shuts down a managed session and persists terminal agent state" {
  provision_main
  local session definitions
  session="$(provisioned_session)"
  definitions="$(prepare_tmux_agents worker-a)"
  split_group "$session" "$definitions"
  [ "$status" -eq 0 ]

  run_orchestrator rollback --project-root "$PROJECT_ROOT" --control-root "$CONTROL_ROOT" --run-id rollback-run

  [ "$status" -eq 0 ]
  run tmux_on_test_server has-session -t "$session"
  [ "$status" -ne 0 ]
  run jq -e 'all(.agents[]; .state == "shutdown")' "$(registry_file)"
  [ "$status" -eq 0 ]
}

@test "attached external session teardown removes only the LBWC pane and runtime state" {
  external_session="external-$RANDOM-$$"
  provision_result="$TEST_ROOT/provision.json"
  split_result="$TEST_ROOT/split.json"
  kill_result="$TEST_ROOT/kill.json"
  capability_file="$TEST_ROOT/main-capability"
  definitions="$(prepare_tmux_agents worker-a)"

  cat > "$TEST_ROOT/provision.sh" <<SCRIPT
#!/usr/bin/env bash
PATH="$BIN_DIR:\$PATH" TMUX_TMPDIR="$TMUX_TMPDIR" bash "$ORCHESTRATOR" provision --project-root "$PROJECT_ROOT" --control-root "$CONTROL_ROOT" --main-id main-session > "$provision_result" 2>&1
status=\$?
if [ "\$status" -eq 0 ]; then
  jq -r '.main_capability' "$provision_result" > "$capability_file"
fi
printf '%s\n' "\$status" > "$provision_result.status"
SCRIPT
  cat > "$TEST_ROOT/split.sh" <<SCRIPT
#!/usr/bin/env bash
PATH="$BIN_DIR:\$PATH" TMUX_TMPDIR="$TMUX_TMPDIR" bash "$ORCHESTRATOR" split-group --project-root "$PROJECT_ROOT" --control-root "$CONTROL_ROOT" --session "$external_session" --agents '$definitions' --orchestrator-id main-session --orchestrator-session-id main-session --orchestrator-capability "\$(cat "$capability_file")" > "$split_result" 2>&1
printf '%s\n' "\$?" > "$split_result.status"
SCRIPT
  cat > "$TEST_ROOT/kill.sh" <<SCRIPT
#!/usr/bin/env bash
PATH="$BIN_DIR:\$PATH" TMUX_TMPDIR="$TMUX_TMPDIR" bash "$ORCHESTRATOR" kill-session --project-root "$PROJECT_ROOT" --control-root "$CONTROL_ROOT" --session "$external_session" --orchestrator-id main-session --orchestrator-session-id main-session --orchestrator-capability "\$(cat "$capability_file")" > "$kill_result" 2>&1
printf '%s\n' "\$?" > "$kill_result.status"
SCRIPT
  chmod +x "$TEST_ROOT/provision.sh" "$TEST_ROOT/split.sh" "$TEST_ROOT/kill.sh"

  run env PATH="$BIN_DIR:$PATH" TMUX_TMPDIR="$TMUX_TMPDIR" tmux -L "$TMUX_SERVER" new-session -d -s "$external_session" -n external -c "$PROJECT_ROOT" 3>&-
  [ "$status" -eq 0 ]
  external_pane_id="$(TMUX_TMPDIR="$TMUX_TMPDIR" tmux -L "$TMUX_SERVER" list-panes -t "$external_session" -F '#{pane_id}')"

  run env TMUX_TMPDIR="$TMUX_TMPDIR" tmux -L "$TMUX_SERVER" send-keys -t "$external_pane_id" "bash $TEST_ROOT/provision.sh" C-m
  [ "$status" -eq 0 ]
  wait_for_result "$provision_result.status"
  [ "$(cat "$provision_result.status")" -eq 0 ]
  run jq -e --arg session "$external_session" '.tmux_session == $session and .topology == "attached-existing-tmux"' "$provision_result"
  [ "$status" -eq 0 ]

  run env TMUX_TMPDIR="$TMUX_TMPDIR" tmux -L "$TMUX_SERVER" send-keys -t "$external_pane_id" "bash $TEST_ROOT/split.sh" C-m
  [ "$status" -eq 0 ]
  wait_for_result "$split_result.status"
  [ "$(cat "$split_result.status")" -eq 0 ]
  run jq -e '.agents | length == 1' "$CONTROL_ROOT/.runtime/tmux-bus/registry.json"
  [ "$status" -eq 0 ]
  agent_pane_id="$(jq -r '.agents[] | select(.agent_id == "worker-a") | .tmux_pane_id' "$CONTROL_ROOT/.runtime/tmux-bus/registry.json")"
  [[ "$agent_pane_id" =~ ^%[0-9]+$ ]]
  [ "$agent_pane_id" != "$external_pane_id" ]

  run env TMUX_TMPDIR="$TMUX_TMPDIR" tmux -L "$TMUX_SERVER" send-keys -t "$external_pane_id" "bash $TEST_ROOT/kill.sh" C-m
  [ "$status" -eq 0 ]
  wait_for_result "$kill_result.status" || { cat "$split_result" >&3; cat "$kill_result" >&3; false; }
  [ "$(cat "$kill_result.status")" -eq 0 ]
  run jq -e '.state == "agents_shutdown" and .external_session_preserved == true' "$kill_result"
  [ "$status" -eq 0 ]

  run env TMUX_TMPDIR="$TMUX_TMPDIR" tmux -L "$TMUX_SERVER" has-session -t "$external_session"
  [ "$status" -eq 0 ]
  run env TMUX_TMPDIR="$TMUX_TMPDIR" tmux -L "$TMUX_SERVER" list-panes -t "$external_session" -F '#{pane_id}'
  [ "$status" -eq 0 ]
  [ "$output" = "$external_pane_id" ]
  run jq -e '.agents[] | select(.agent_id == "worker-a") | .state == "shutdown" and .tmux_pane_id == null' "$CONTROL_ROOT/.runtime/tmux-bus/registry.json"
  [ "$status" -eq 0 ]
  run jq -e '.routes | keys == ["main-session"]' "$CONTROL_ROOT/.runtime/tmux-bus/registry.json"
  [ "$status" -eq 0 ]
  run jq -e '.routes | keys == ["main-session"]' "$CONTROL_ROOT/.runtime/tmux-bus/routing-table.json"
  [ "$status" -eq 0 ]
  [ ! -e "$CONTROL_ROOT/.runtime/tmux-bus/inboxes/worker-a" ]
}

prepare_teardown_agent() {
  export HOME="$TEST_ROOT/home"
  mkdir -p "$HOME"
  cd "$PROJECT_ROOT" || return 1
  git init -q
  provision_main
  SESSION="$(provisioned_session)"
  tmux_on_test_server set-option -t "$SESSION" default-command 'sleep 600'
  DEFINITIONS="$(prepare_tmux_agents worker-a)"
  split_group "$SESSION" "$DEFINITIONS"
  [ "$status" -eq 0 ]
  AGENT_PANE="$(jq -r '.agents[] | select(.agent_id == "worker-a") | .tmux_pane_id' "$(registry_file)")"
  AGENT_TARGET="$(jq -r '.agents[] | select(.agent_id == "worker-a") | .tmux_target' "$(registry_file)")"
}

@test "agent teardown finalizes an agent whose pane already exited without killing the orchestrator" {
  prepare_teardown_agent
  tmux_on_test_server kill-pane -t "$AGENT_PANE"
  run_orchestrator kill-agent --project-root "$PROJECT_ROOT" --control-root "$CONTROL_ROOT" --target "$AGENT_TARGET"
  [ "$status" -eq 0 ]
  jq -e '.agents[] | select(.agent_id == "worker-a") | .state == "shutdown" and .tmux_pane_id == null' "$(registry_file)"
  jq -e '.routes | has("worker-a") | not' "$(routing_file)"
  [ ! -e "$CONTROL_ROOT/.runtime/tmux-bus/inboxes/worker-a" ]
  tmux_on_test_server has-session -t "$SESSION"
}

@test "repeated agent teardown reports shutdown without changing terminal registry or routes" {
  prepare_teardown_agent
  run_orchestrator kill-agent --project-root "$PROJECT_ROOT" --control-root "$CONTROL_ROOT" --target "$AGENT_TARGET"
  [ "$status" -eq 0 ]
  local before
  before="$(bus_state_digest)"
  run_orchestrator kill-agent --project-root "$PROJECT_ROOT" --control-root "$CONTROL_ROOT" --target "$AGENT_TARGET"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' <<< "$output")" = shutdown ]
  [ "$(bus_state_digest)" = "$before" ]
}

@test "focus returns selection to the registered orchestrator rather than an active agent pane" {
  prepare_teardown_agent
  tmux_on_test_server select-pane -t "$AGENT_PANE"
  local orchestrator_target expected_pane
  orchestrator_target="$(jq -r '.tmux.orchestrator_target' "$(registry_file)")"
  expected_pane="$(tmux_on_test_server display-message -p -t "$orchestrator_target" '#{pane_id}')"
  run_orchestrator focus-orchestrator --project-root "$PROJECT_ROOT" --control-root "$CONTROL_ROOT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.orchestrator_target' <<< "$output")" = "$orchestrator_target" ]
  [ "$(tmux_on_test_server display-message -p -t "$SESSION" '#{pane_id}')" = "$expected_pane" ]
}

@test "configured session names remain addressable through owned cleanup" {
  config_test_repo
  run_config_rows name <<'ROWS'
custom-prefix|custom;project;custom-project;none
full-prefix|abcdefghijklmnopqrstuvwxyz123456;project;abcdefghijklmnopqrstuvwxyz123456-project;abcdefghijklmnopqrstuvwxyz123456
dotted-project|missing;my.app;lbwc-my-app;none
colon-project|missing;my:app;lbwc-my-app;none
default-prefix|missing;project;lbwc-project;none
explicit-prefix|custom;project;custom-project;override
ROWS
}

@test "attach policies preserve the requested agent visibility and roll back failed splits" {
  config_test_repo
  run_config_rows policy <<'ROWS'
visible-horizontal|visible_grid;1;success
visible-final-agent|visible_grid;3;success
default-focus|missing;2;success
orchestrator-focus|orchestrator_only;2;success
unsupported-policy|unsupported;1;reject
visible-layout-rollback|visible_grid;1;rollback
ROWS
}

@test "heartbeat intervals preserve liveness without reviving obsolete agents" {
  config_test_repo
  run_config_rows heartbeat <<'ROWS'
running-heartbeat|live;1;none;running
idle-heartbeat|live;1;none;idle
derived-stale-limit|stale;1;none;running
capped-cli-limit|stale;1;90000;running
stricter-config-limit|stale;30;configured;running
stricter-cli-limit|stale;30;2000;running
failed-sender|terminal;1;none;failed
shutdown-sender|terminal;1;none;shutdown
rebound-sender|terminal;1;none;rebound
absent-pane-sender|terminal;1;none;absent
missing-interval|defaults;30;none;running
ROWS
}
