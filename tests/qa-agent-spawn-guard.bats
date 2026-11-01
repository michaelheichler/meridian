#!/usr/bin/env bats

load test_helper
load guard_helper

setup() {
  setup_temp_dir
  create_test_config
  ROUTE_BINARY="$TEST_TEMP_DIR/claude-route-fixture"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\\n" fixture' > "$ROUTE_BINARY"
  chmod +x "$ROUTE_BINARY"
  ROUTE_SHA=$(shasum -a 256 "$ROUTE_BINARY" | awk '{print $1}')
  CUSTOM_HOST_ID="leverframe:openai-oauth:codex-auto-review"
  CONTROL_ROOT=""
  AGENT_NAME=""
  jq -n --arg binary "$ROUTE_BINARY" --arg sha "$ROUTE_SHA" '{schema_version:1,source:{binary_path:$binary,version:"fixture",sha256:$sha,detected_at:"2035-01-02T03:04:05Z"},models:[{selector:"nova-route",label:"Nova Route",description:"Fixture"}],reasoning:{scope:"global",accepted_values:["deliberate"],model_associations:{"nova-route":["deliberate"]}}}' > "$TEST_TEMP_DIR/.lbwc-planning/claude-capabilities.json"
  jq --slurpfile defaults "$PROJECT_ROOT/templates/agent-roles/defaults.json" '. + {schema_version:1,routing:{active_profile:"balanced",profiles:{quality:{roles:{}},balanced:{roles:($defaults[0]|keys|map({key:.,value:{model:"nova-route",reasoning:"deliberate",status:"resolved"}})|from_entries)},turbo:{roles:{}}}}}' "$TEST_TEMP_DIR/.lbwc-planning/config.json" > "$TEST_TEMP_DIR/.lbwc-planning/config.tmp"
  mv "$TEST_TEMP_DIR/.lbwc-planning/config.tmp" "$TEST_TEMP_DIR/.lbwc-planning/config.json"
  cd "$TEST_TEMP_DIR"
}

teardown() {
  cd "$PROJECT_ROOT"
  teardown_temp_dir
}

run_spawn() {
  local name="$1" extra="${2:-}"
  [ -n "$extra" ] || extra='{}'
  jq -cn --arg name "$name" --argjson extra "$extra" '{tool_name:"Agent",tool_input:({subagent_type:$name} + $extra)}' \
    | LBWC_CONTROL_ROOT="$CONTROL_ROOT" CLAUDE_CODE_EXECPATH="$ROUTE_BINARY" bash "$SCRIPTS_DIR/agent-spawn-guard.sh"
}

run_raw_spawn() {
  printf '%s' "$1" | bash "$SCRIPTS_DIR/agent-spawn-guard.sh"
}

install_catalog() {
  local preset="$1" filter
  case "$preset" in
    alias)
      filter='.models += [{selector:"claude-sonnet-5",label:"Sonnet 5",description:"Sonnet 5"},{selector:"sonnet",label:"sonnet",description:"sonnet"},{selector:$custom,label:$custom,description:$custom}]
        | .host_agent_enum = ["sonnet","opus",$custom]
        | .agent_model_ids = {"nova-route":"nova-route","claude-sonnet-5":"sonnet","sonnet":"sonnet"}
        | .agent_model_ids[$custom] = $custom' ;;
    custom)
      filter='.models += [{selector:$custom,label:$custom,description:$custom}]
        | .host_agent_enum = ["sonnet",$custom]
        | .agent_model_ids = {"nova-route":"nova-route"}
        | .agent_model_ids[$custom] = $custom' ;;
    unknown)
      filter='.host_agent_enum = ["sonnet"] | .agent_model_ids = {"sonnet":"sonnet"}' ;;
    *) return 0 ;;
  esac
  jq --arg custom "$CUSTOM_HOST_ID" --arg binary "$ROUTE_BINARY" --arg sha "$ROUTE_SHA" \
    "$filter | .source.binary_path = \$binary | .source.sha256 = \$sha" \
    "$TEST_TEMP_DIR/.lbwc-planning/claude-capabilities.json" > "$CONTROL_ROOT/claude-capabilities.json"
}

mutate_manifest() {
  local mutation="$1" filter
  case "$mutation" in
    digest) filter='.agents[$name].contract_digest = "deadbeef"' ;;
    policy) filter='.agents[$name].communication_policy = "critic-relay"' ;;
    runtime) filter='.agents[$name].runtime_kind = "other-runtime"' ;;
    capabilities) filter='.agents[$name].capabilities = []' ;;
    pair) filter='.agents[$name].pair_id = "pair-x"' ;;
    running|used|expired) filter=".agents[\$name].state = \"$mutation\"" ;;
    unknown-model) filter='.agents[$name].model = "not-a-model"' ;;
    alias-model) filter='.agents[$name].model = "claude-sonnet-5"' ;;
    custom-model) filter='.agents[$name].model = $custom' ;;
    *) return 0 ;;
  esac
  jq --arg name "$AGENT_NAME" --arg custom "$CUSTOM_HOST_ID" "$filter" "$CONTROL_ROOT/agent-manifest.json" > "$CONTROL_ROOT/manifest.tmp"
  mv "$CONTROL_ROOT/manifest.tmp" "$CONTROL_ROOT/agent-manifest.json"
}

build_native_agent() {
  local slug="$1" preset="$2" mutation="$3" contract id
  CONTROL_ROOT="$TEST_TEMP_DIR/.temporary-agent-runfiles/runs/$slug"
  mkdir -p "$CONTROL_ROOT"
  install_catalog "$preset"
  contract=$(bash "$SCRIPTS_DIR/task-contract.sh" issue "$TEST_TEMP_DIR" "$slug" \
    --command team --role web-engineer --team solo --job "scope" \
    --control-root "$CONTROL_ROOT" --write-capability directory:.)
  id=$(basename "$contract" .json)
  bash "$SCRIPTS_DIR/agent-generator.sh" --native-team web-engineer --job "scope" \
    --task-id "$id" --contract "$contract" --control-root "$CONTROL_ROOT" \
    --write-capability directory:. >/dev/null
  AGENT_NAME=$(jq -r '.agents | keys[0]' "$CONTROL_ROOT/agent-manifest.json")
  [ "$mutation" = "undispatched" ] || bash "$SCRIPTS_DIR/task-contract.sh" state "$TEST_TEMP_DIR" "$id" dispatched >/dev/null
  mutate_manifest "$mutation"
}

agent_state() {
  jq -r --arg name "$AGENT_NAME" '.agents[$name].state' "$CONTROL_ROOT/agent-manifest.json"
}

prepare_raw_setup() {
  case "$1" in
    no-planning) rm -rf "$TEST_TEMP_DIR/.lbwc-planning" ;;
    empty-manifest) write_manifest "$TEST_TEMP_DIR/.lbwc-planning" '{"agents":{}}' ;;
  esac
}

snapshot_planning() {
  rm -rf "$BATS_TEST_TMPDIR/planning-snapshot"
  cp -R "$TEST_TEMP_DIR/.lbwc-planning" "$BATS_TEST_TMPDIR/planning-snapshot"
}

restore_planning() {
  rm -rf "$TEST_TEMP_DIR/.lbwc-planning"
  cp -R "$BATS_TEST_TMPDIR/planning-snapshot" "$TEST_TEMP_DIR/.lbwc-planning"
}

@test "spawn guard blocks malformed input, passes non-LBWC calls untouched, and strips sidechain fields" {
  local before after json no_jq_path="$TEST_TEMP_DIR/no-jq-bin"
  snapshot_planning

  while IFS='|' read -r label setup reason stdin; do
    [ -n "$label" ] || continue
    prepare_raw_setup "$setup"
    run run_raw_spawn "$stdin"
    expect_status "$label" 2
    expect_output_has "$label" "$reason"
  done <<'CASES'
malformed-json|-|could not parse tool call input|not json at all
generated-identity-without-control-root|no-planning|no resolvable control root or manifest|{"tool_name":"Agent","tool_input":{"subagent_type":"lbwc-docs-missing"}}
generated-identity-without-manifest|-|no resolvable control root or manifest|{"tool_name":"Agent","tool_input":{"subagent_type":"lbwc-docs-missing"}}
CASES

  restore_planning
  mkdir -p "$no_jq_path"
  ln -s "$(command -v bash)" "$no_jq_path/bash"
  run env PATH="$no_jq_path" bash -c "printf '%s' '{}' | bash '$SCRIPTS_DIR/agent-spawn-guard.sh'"
  expect_status jq-missing 2
  expect_output_has jq-missing "jq not available"
  rm -rf "$no_jq_path"

  while IFS='|' read -r label setup stdin; do
    [ -n "$label" ] || continue
    prepare_raw_setup "$setup"
    before=$(tree_digest "$TEST_TEMP_DIR")
    run run_raw_spawn "$stdin"
    after=$(tree_digest "$TEST_TEMP_DIR")
    expect_status "$label" 0
    expect_output_empty "$label"
    expect_same_digest "$label" "$before" "$after"
  done <<'CASES'
ordinary-agent-without-control-root|no-planning|{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose"}}
ordinary-agent-without-manifest|-|{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose"}}
ordinary-agent-unknown-to-manifest|empty-manifest|{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose"}}
task-create-ordinary-agent|empty-manifest|{"tool_name":"TaskCreate","tool_input":{"subagent_type":"general-purpose"}}
unrelated-tool-with-generated-name|empty-manifest|{"tool_name":"Bash","tool_input":{"subagent_type":"lbwc-docs-x"}}
call-without-subagent-type|empty-manifest|{"tool_name":"Agent","tool_input":{}}
ordinary-cwd-and-isolation-kept|empty-manifest|{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose","cwd":"/work/project","isolation":"none"}}
empty-stdin|-|
CASES

  restore_planning
  while IFS='|' read -r label stripped_field extra; do
    [ -n "$label" ] || continue
    prepare_raw_setup empty-manifest
    before=$(tree_digest "$TEST_TEMP_DIR")
    run run_raw_spawn "$(jq -cn --argjson extra "$extra" '{tool_name:"Agent",tool_input:({subagent_type:"general-purpose"} + $extra)}')"
    after=$(tree_digest "$TEST_TEMP_DIR")
    expect_status "$label" 0
    expect_output_has "$label" "lbwc guard: stripped"
    json=$(printf '%s\n' "$output" | grep '^{')
    printf '%s' "$json" | jq -e --arg field "$stripped_field" '
      .hookSpecificOutput.permissionDecision == "allow"
      and (.hookSpecificOutput.updatedInput | has($field) | not)
      and .hookSpecificOutput.updatedInput.subagent_type == "general-purpose"
    ' >/dev/null || fail_case "$label" "updatedInput kept $stripped_field or dropped subagent_type"
    expect_same_digest "$label" "$before" "$after"
  done <<'CASES'
sidechain-cwd|cwd|{"cwd":".lbwc-worktrees/agent-a1"}
sidechain-working-dir|working_dir|{"working_dir":"/project/.lbwc-worktrees/agent-a1/sub"}
worktree-isolation|isolation|{"isolation":"worktree"}
CASES
}

@test "spawn guard refuses wrong generated agents, claims registered ones with host model ids, and holds open groups" {
  local first_contract second_contract first_id second_id first_engineer second_engineer
  while IFS='|' read -r label preset mutation call_name call_extra expected_state reason; do
    [ -n "$label" ] || continue
    build_native_agent "$label" "$preset" "$mutation" </dev/null
    [ "$call_name" != "@agent" ] || call_name="$AGENT_NAME"
    run run_spawn "$call_name" "$call_extra"
    expect_status "$label" 2
    expect_output_has "$label" "$reason"
    [ "$(agent_state)" = "$expected_state" ] || fail_case "$label" "manifest state is $(agent_state), expected $expected_state"
  done <<'CASES'
contract-not-dispatched|default|undispatched|@agent||registered|contract is missing, stale, tampered, or not dispatched
manifest-digest-mismatch|default|digest|@agent||registered|contract is missing, stale, tampered, or not dispatched
manifest-claims-a-pair-for-a-solo-contract|default|pair|@agent||registered|contract is missing, stale, tampered, or not dispatched
communication-policy-mismatch|default|policy|@agent||registered|runtime or communication policy does not match its contract
runtime-kind-mismatch|default|runtime|@agent||registered|runtime or communication policy does not match its contract
capability-set-mismatch|default|capabilities|@agent||registered|runtime or communication policy does not match its contract
call-model-not-in-live-catalog|custom|none|@agent|{"model":"wrong-model"}|registered|call-time model override conflicts with generated definition
call-model-different-from-definition|alias|alias-model|@agent|{"model":"leverframe:openai-oauth:codex-auto-review"}|registered|call-time model override conflicts with generated definition
call-max-turns-conflict|default|none|@agent|{"maxTurns":100000}|registered|call-time maxTurns override conflicts with generated definition
call-effort-conflict|default|none|@agent|{"effort":"bogus"}|registered|call-time effort override conflicts with generated definition
call-tools-conflict|default|none|@agent|{"tools":["Nope"]}|registered|call-time tools override conflicts with generated definition
manifest-model-missing-from-live-enum|unknown|unknown-model|@agent||registered|not present in the live host Agent enum
agent-already-running|default|running|@agent||running|is already running and cannot be spawned again
agent-already-used|default|used|@agent||used|is already used and cannot be spawned again
agent-already-expired|default|expired|@agent||expired|is already expired and cannot be spawned again
generated-name-absent-from-manifest|default|none|lbwc-ghost||registered|has no manifest entry
CASES

  while IFS='|' read -r label preset mutation expected_model; do
    [ -n "$label" ] || continue
    build_native_agent "$label" "$preset" "$mutation" </dev/null
    run run_spawn "$AGENT_NAME"
    expect_status "$label" 0
    printf '%s' "$output" | jq -e --arg model "$expected_model" '
      .hookSpecificOutput.permissionDecision == "allow"
      and .hookSpecificOutput.updatedInput.model == $model
    ' >/dev/null || fail_case "$label" "updatedInput.model is not $expected_model"
    [ "$(agent_state)" = "running" ] || fail_case "$label" "manifest state is $(agent_state), expected running"
  done <<'CASES'
full-selector-mapped-to-host-alias|alias|alias-model|sonnet
custom-host-id-left-unchanged|custom|custom-model|leverframe:openai-oauth:codex-auto-review
CASES

  CONTROL_ROOT=""
  first_contract=$(bash "$SCRIPTS_DIR/task-contract.sh" issue "$TEST_TEMP_DIR" first-pair \
    --command test --role python-engineer --team pair --job "first build team")
  first_id=$(basename "$first_contract" .json)
  run bash "$SCRIPTS_DIR/agent-generator.sh" --pair python-engineer \
    --job "first build team" --contract "$first_contract" --task-id "$first_id"
  expect_status first-group-generated 0
  first_engineer=$(printf '%s\n' "$output" | grep 'ENGINEER: SPAWN_READY' | awk '{print $3}')
  [ -n "$first_engineer" ] || fail_case first-group-generated "no engineer name"
  bash "$SCRIPTS_DIR/task-contract.sh" state "$TEST_TEMP_DIR" "$first_id" dispatched >/dev/null

  second_contract=$(bash "$SCRIPTS_DIR/task-contract.sh" issue "$TEST_TEMP_DIR" second-pair \
    --command test --role python-engineer --team pair --job "second build team")
  second_id=$(basename "$second_contract" .json)
  run bash "$SCRIPTS_DIR/agent-generator.sh" --pair python-engineer \
    --job "second build team" --contract "$second_contract" --task-id "$second_id"
  expect_status second-group-generated 0
  second_engineer=$(printf '%s\n' "$output" | grep 'ENGINEER: SPAWN_READY' | awk '{print $3}')
  [ -n "$second_engineer" ] || fail_case second-group-generated "no engineer name"
  bash "$SCRIPTS_DIR/task-contract.sh" state "$TEST_TEMP_DIR" "$second_id" dispatched >/dev/null

  run run_spawn "$second_engineer"

  expect_status second-group-member 2
  expect_output_has second-group-member "is open, spawn every member before starting other work."
  expect_output_has second-group-member "$first_engineer"
  [ "$(jq -r --arg name "$second_engineer" '.agents[$name].state' "$TEST_TEMP_DIR/.lbwc-planning/.agent-manifest.json")" = "registered" ] \
    || fail_case second-group-member "second group member left the registered state"
}
