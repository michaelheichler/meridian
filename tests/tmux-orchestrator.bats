#!/usr/bin/env bats

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
  cat > "$BIN_DIR/tmux" <<'SCRIPT'
#!/usr/bin/env bash
if [ "$1" = "split-window" ] && [ -n "${LBWC_TEST_SPLIT_COUNTER:-}" ]; then
  count=0
  [ -f "$LBWC_TEST_SPLIT_COUNTER" ] && count=$(cat "$LBWC_TEST_SPLIT_COUNTER")
  count=$((count + 1))
  printf '%s\n' "$count" > "$LBWC_TEST_SPLIT_COUNTER"
  [ "$count" -lt 2 ] || exit 1
fi
if [ "$1" = "split-window" ] && [ -n "${LBWC_TEST_FAST_CHILD_ENV:-}" ]; then
  arguments=("$@")
  : > "$LBWC_TEST_FAST_CHILD_ENV"
  for argument in "$@"; do
    case "$argument" in
      LBWC_TMUX_AGENT=*|LBWC_TMUX_CONTROL_ROOT=*|LBWC_TMUX_AGENT_ID=*|LBWC_TMUX_CONTRACT_ID=*)
        printf '%s\n' "$argument" >> "$LBWC_TEST_FAST_CHILD_ENV"
        ;;
      esac
  done
  pane_id=$("$LBWC_TEST_TMUX_BINARY" -L "$LBWC_TEST_TMUX_SERVER" "${arguments[0]}" \
    -e "PATH=$LBWC_TEST_CHILD_PATH" \
    -e "LBWC_TEST_FAST_CHILD_ENV=$LBWC_TEST_FAST_CHILD_ENV" \
    -e "LBWC_TEST_FAST_CHILD_STATUS=$LBWC_TEST_FAST_CHILD_STATUS" \
    -e "LBWC_TEST_FAST_CHILD_OUTPUT=$LBWC_TEST_FAST_CHILD_OUTPUT" \
    -e "LBWC_TEST_FAST_CHILD_READY=$LBWC_TEST_FAST_CHILD_READY" \
    -e "LBWC_TEST_FAST_CHILD_RELEASE=$LBWC_TEST_FAST_CHILD_RELEASE" \
    -e "LBWC_TEST_FAST_CHILD_PANE=$LBWC_TEST_FAST_CHILD_PANE" \
    -e "LBWC_TEST_FAST_CHILD_STARTED=$LBWC_TEST_FAST_CHILD_STARTED" \
    -e "LBWC_TEST_FAST_CHILD_EXIT=$LBWC_TEST_FAST_CHILD_EXIT" \
    -e "LBWC_TEST_SESSION_START=$LBWC_TEST_SESSION_START" \
    "${arguments[@]:1}" "$LBWC_TEST_CHILD_SHELL" --noprofile --norc) || exit 1
  printf '%s\n' "$pane_id"
  exit 0
fi
if [ "$1" = "send-keys" ] && [ -n "${LBWC_TEST_SEND_KEYS_COUNTER:-}" ]; then
  count=0
  [ -f "$LBWC_TEST_SEND_KEYS_COUNTER" ] && count=$(cat "$LBWC_TEST_SEND_KEYS_COUNTER")
  count=$((count + 1))
  printf '%s\n' "$count" > "$LBWC_TEST_SEND_KEYS_COUNTER"
  [ "$count" -le "${LBWC_TEST_FAIL_SEND_KEYS_AFTER:-0}" ] || exit 1
fi
if [ "$1" = "split-window" ] && [ -n "${LBWC_TEST_LAYOUT_AFTER_SPLIT:-}" ]; then
  printf '{"tmux":{"layout":"%s"}}\n' "$LBWC_TEST_LAYOUT_AFTER_SPLIT" > "$LBWC_TEST_CONFIG_PATH"
fi
if [ "$1" = "select-layout" ] && [ -n "${LBWC_TEST_SELECT_LAYOUT_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$LBWC_TEST_SELECT_LAYOUT_LOG"
fi
if [ "$1" = "select-layout" ] && [ "${LBWC_TEST_FAIL_LAYOUT:-0}" = 1 ]; then
  exit 1
fi
exec "$LBWC_TEST_TMUX_BINARY" -L "$LBWC_TEST_TMUX_SERVER" "$@"
SCRIPT
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

@test "unknown --cancel is usage error" {
  run_orchestrator provision --project-root "$PROJECT_ROOT" --control-root "$CONTROL_ROOT" --main-id main-session --cancel

  [ "$status" -ne 0 ]
  [ ! -e "$(registry_file)" ]
}

@test "orchestrator first then bus shares one schema and main route" {
  provision_main
  run env PATH="$BIN_DIR:$PATH" bash "$BUS" --control-root "$CONTROL_ROOT" init --main-id main-session --main-session-id main-session --orchestrator-capability "$MAIN_CAPABILITY"
  [ "$status" -eq 0 ]
  run jq -e '.schema_version == 2 and .tmux.topology == "detached-new-session" and .routes["main-session"].inbox == "main-session"' "$(registry_file)"
  [ "$status" -eq 0 ]
}

@test "init without provision does not mint a registry" {
  run env PATH="$BIN_DIR:$PATH" bash "$BUS" --control-root "$CONTROL_ROOT" init --main-id main-session --main-session-id main-session
  [ "$status" -ne 0 ]
  [[ "$output" == *"bus is not provisioned"* ]]
  [ ! -e "$(registry_file)" ]
}

@test "provision configures titled pane borders" {
  provision_main
  local session
  session="$(provisioned_session)"

  run tmux_on_test_server show-options -v -t "$session" pane-border-status
  [ "$status" -eq 0 ]
  [ "$output" = top ]
  run tmux_on_test_server show-options -v -t "$session" pane-border-format
  [ "$status" -eq 0 ]
  [ "$output" = '#{pane_title}' ]
}

@test "split-group accepts a generated manifest entry and schema 3 task contract" {
  provision_main
  local session definitions
  session="$(provisioned_session)"
  definitions="$(prepare_tmux_agents worker-a)"
  jq -e '.agents["worker-a"] | type == "object"' "$CONTROL_ROOT/.agent-manifest.json" >/dev/null

  split_group "$session" "$definitions"

  [ "$status" -eq 0 ]
  jq -e '.agents | any(.[]; .agent_id == "worker-a" and .generated_name == "worker-a")' "$(registry_file)" >/dev/null
  run jq -e '.routes["worker-a"] | has("messaging_socket") | not' "$(routing_file)"
  [ "$status" -eq 0 ]
}

@test "split-agent resolves the exact manifest contract instead of fabricating one" {
  provision_main
  local session
  session="$(provisioned_session)"
  prepare_tmux_agents worker-a >/dev/null

  run_orchestrator split-agent --project-root "$PROJECT_ROOT" --control-root "$CONTROL_ROOT" --session "$session" --name worker-a --agent worker-a

  [ "$status" -eq 0 ]
  jq -e '.agents | any(.[]; (.agent_id == "worker-a") and (.contract_id | startswith("cmd-team-worker-a-")))' "$(registry_file)" >/dev/null
}

@test "split-agent rejects a generated identity that differs from its agent id" {
  provision_main
  local session
  session="$(provisioned_session)"
  prepare_tmux_agents worker-a >/dev/null

  run_orchestrator split-agent --project-root "$PROJECT_ROOT" --control-root "$CONTROL_ROOT" --session "$session" --name worker-a --agent other-agent

  [ "$status" -ne 0 ]
  [[ "$output" == *"agent and generated identities must match"* ]]
  [ "$(jq '.agents | length' "$(registry_file)")" = 0 ]
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

@test "provision registry failure removes runtime state created by the attempt" {
  export LBWC_TEST_FAIL_WRITE=registry
  run_orchestrator provision --project-root "$PROJECT_ROOT" --control-root "$CONTROL_ROOT" --main-id main-session
  unset LBWC_TEST_FAIL_WRITE

  [ "$status" -ne 0 ]
  [ ! -e "$CONTROL_ROOT/.runtime" ]
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

@test "split-group reads the layout only before panes exist" {
  printf '%s\n' '{"tmux":{"layout":"even-vertical"}}' > "$CONTROL_ROOT/config.json"
  provision_main
  local session definitions
  session="$(provisioned_session)"
  definitions="$(prepare_tmux_agents worker-a)"
  export LBWC_TEST_CONFIG_PATH="$CONTROL_ROOT/config.json" LBWC_TEST_LAYOUT_AFTER_SPLIT=bogus-layout LBWC_TEST_SELECT_LAYOUT_LOG="$TEST_ROOT/select-layout.log"

  split_group "$session" "$definitions"
  unset LBWC_TEST_CONFIG_PATH LBWC_TEST_LAYOUT_AFTER_SPLIT LBWC_TEST_SELECT_LAYOUT_LOG

  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_ROOT/select-layout.log")" = "select-layout -t $session even-vertical" ]
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
  ! tmux_on_test_server has-session -t "$session"
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
