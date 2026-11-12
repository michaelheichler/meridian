#!/usr/bin/env bats

load test_helper
load gate_case_helper
load agent_generator_fixture
load rejection_case_helper

GENERATOR="${SCRIPTS_DIR}/agent-generator.sh"
export GENERATOR

setup() {
  TEST_TEMP_DIR=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/meridian-generator.XXXXXX")" && pwd -P)
  export TEST_TEMP_DIR
  export _ORIG_HOME="${HOME:-}"
  export _ORIG_MERIDIAN_PLANNING_DIR="${MERIDIAN_PLANNING_DIR:-}"
  export HOME="$TEST_TEMP_DIR"
  unset MERIDIAN_PLANNING_DIR CLAUDE_SESSION_ID 2>/dev/null || true
  mkdir -p "$TEST_TEMP_DIR/.meridian"
  write_generator_fixture "$TEST_TEMP_DIR"
  cp "$TEST_TEMP_DIR/.meridian/config.json" "$TEST_TEMP_DIR/.meridian/config.pristine"
  CONTRACT_SEQUENCE=0
  reset_case_failures
}

teardown() {
  teardown_temp_dir
}

generate() {
  local -a arguments=("$@") contract_args=()
  local mode=solo role job="" index=0 value contract task_id
  if [ "${arguments[0]:-}" = "--pair" ]; then mode=pair; index=1; fi
  if [ "${arguments[0]:-}" = "--trio" ]; then mode=trio; index=1; fi
  role="${arguments[$index]:-}"
  if [[ " ${arguments[*]} " != *" --contract "* ]] && jq -e --arg role "${role#meridian-}" 'has($role)' "$PROJECT_ROOT/templates/agent-roles/defaults.json" >/dev/null 2>&1; then
    index=$((index + 1))
    while [ "$index" -lt "${#arguments[@]}" ]; do
      value=${arguments[$index]}
      case "$value" in
        --job) index=$((index + 1)); job=${arguments[$index]} ;;
        --job=*) job=${value#*=} ;;
        --write-allowance|--role-write-allowance)
          index=$((index + 1)); contract_args+=("$value" "${arguments[$index]}") ;;
        --write-allowance=*|--role-write-allowance=*)
          contract_args+=("${value%%=*}" "${value#*=}") ;;
      esac
      index=$((index + 1))
    done
    if [ -n "$job" ]; then
      CONTRACT_SEQUENCE=$((CONTRACT_SEQUENCE + 1))
      task_id="test-${BATS_TEST_NUMBER:-0}-${CONTRACT_SEQUENCE}"
      contract=$(bash "$SCRIPTS_DIR/task-contract.sh" issue "$TEST_TEMP_DIR" "$task_id" \
        --command test --role "${role#meridian-}" --team "$mode" --job "$job" "${contract_args[@]}")
      arguments+=(--contract "$contract" --task-id "$(basename "$contract" .json)")
    fi
  fi
  run bash -c 'cd "$TEST_TEMP_DIR" && exec bash "$GENERATOR" "$@"' _ "${arguments[@]}"
}

make_contract() {
  local role="$1" task="$2" allowances="$3" team="${4:-solo}" job="${5:-contract task}" path item
  local -a args=()
  while IFS= read -r item; do
    [ -n "$item" ] && args+=(--write-allowance "$item")
  done < <(jq -r '.[]' <<< "$allowances")
  path=$(bash "$SCRIPTS_DIR/task-contract.sh" issue "$TEST_TEMP_DIR" "$task" \
    --command test --role "$role" --team "$team" --job "$job" "${args[@]}")
  printf '%s' "$path"
}

generate_raw() {
  run bash -c 'cd "$TEST_TEMP_DIR" && exec bash "$GENERATOR" "$@"' _ "$@"
}

manifest_path() {
  printf '%s' "$TEST_TEMP_DIR/.meridian/.agent-manifest.json"
}

generated_name() {
  printf '%s\n' "$output" | grep -o "meridian-$1-[a-z0-9-]*" | head -1
}

agent_file_count() {
  find "$TEST_TEMP_DIR/.claude/agents" -type f 2>/dev/null | wc -l | tr -d ' '
}

agent_definition() {
  printf '%s' "$TEST_TEMP_DIR/.claude/agents/$1.md"
}

reset_generated_state() {
  rm -rf "$TEST_TEMP_DIR/.claude" "$(manifest_path)"
}

restore_pristine_config() {
  cp "$TEST_TEMP_DIR/.meridian/config.pristine" "$TEST_TEMP_DIR/.meridian/config.json"
}

edit_config() {
  jq "$1" "$TEST_TEMP_DIR/.meridian/config.json" > "$TEST_TEMP_DIR/.meridian/config.next"
  mv "$TEST_TEMP_DIR/.meridian/config.next" "$TEST_TEMP_DIR/.meridian/config.json"
}

expect_manifest_jq() {
  local label="$1" name="$2" program="$3" manifest="${4:-$(manifest_path)}" root="${5:-}"
  jq -e --arg name "$name" --arg root "$root" "$program" "$manifest" >/dev/null 2>&1 \
    || record_case_failure "$label" "manifest fails [$program] for $name: $(jq -c ".agents[\"$name\"]" "$manifest" 2>&1)"
}

expect_generated_name() {
  [ -n "$2" ] || record_case_failure "$1" "no generated agent name in output=$output"
}

expect_definition_has() {
  local label="$1" name="$2" fragment="$3"
  grep -qF -- "$fragment" "$(agent_definition "$name")" 2>/dev/null \
    || record_case_failure "$label" "definition of [$name] lacks [$fragment]"
}

expect_rejected_without_mutation() {
  local label="$1" expected="$2"
  [ "$status" -eq 1 ] || record_case_failure "$label" "status=$status output=$output"
  [[ "$output" =~ $expected ]] || record_case_failure "$label" "expected=$expected output=$output"
  [ ! -f "$(manifest_path)" ] || record_case_failure "$label" "manifest was created"
  [ "$(agent_file_count)" -eq 0 ] || record_case_failure "$label" "agent file was rendered"
}

reject_args_row() {
  local label="$1" runner="$2" expected="$3"
  shift 3
  reset_generated_state
  "$runner" "$@"
  expect_rejected_without_mutation "$label" "$expected"
}

contract_mismatch_row() {
  local label="$1" team="$2" contract_allowances="$3" filter="$4" task="$5" requested="$6" expected="$7"
  local contract id allowance
  local -a request_arguments=() mode_arguments=()
  reset_generated_state
  contract=$(make_contract python-engineer "case-$label" "$contract_allowances" "$team" "contract job")
  jq "$filter" "$contract" > "$contract.tmp" && mv "$contract.tmp" "$contract"
  id=$(basename "$contract" .json)
  [ "$task" = "-" ] || id="$task"
  for allowance in $requested; do request_arguments+=(--write-allowance "$allowance"); done
  [ "$team" != "pair" ] || mode_arguments=(--pair)
  generate ${mode_arguments[@]+"${mode_arguments[@]}"} python-engineer --job "contract job" --task-id "$id" \
    --contract "$contract" "${request_arguments[@]}"
  expect_rejected_without_mutation "$label" "$expected"
}

stub_resolver_row() {
  local label="$1" resolver="$TEST_TEMP_DIR/stub-resolver.sh"
  reset_generated_state
  printf '%s\n' '#!/usr/bin/env bash' \
    "printf \"%s\\n\" \"RESOLVED_AGENT_MODEL='nova-route'\" \"RESOLVED_MAX_TURNS=''\" \"RESOLVED_REASONING_JSON='null'\"" > "$resolver"
  MERIDIAN_AGENT_SETTINGS_SCRIPT="$resolver" generate docs --job "write a README"
  expect_rejected_without_mutation "$label" "resolver omitted the max turns value"
}

host_enum_gap_row() {
  local label="$1" catalog="$TEST_TEMP_DIR/.meridian/claude-capabilities.json"
  reset_generated_state
  cp "$catalog" "$catalog.saved"
  jq '. + {host_agent_enum: ["sonnet"], agent_model_ids: {sonnet: "sonnet"}}
    | .models += [{selector: "sonnet", label: "Sonnet", description: "Host fixture"}]' \
    "$catalog.saved" > "$catalog"
  generate docs --job "write a README"
  expect_rejected_without_mutation "$label" "not present in the live host Agent enum"
  mv "$catalog.saved" "$catalog"
}

stale_fingerprint_row() {
  local label="$1"
  reset_generated_state
  cp "$ROUTE_BINARY" "$ROUTE_BINARY.saved"
  printf '%s\n' 'changed' >> "$ROUTE_BINARY"
  generate docs --job "write a README"
  expect_rejected "$label" "fingerprint differs"
  [ ! -d "$TEST_TEMP_DIR/.claude/agents" ] || record_case_failure "$label" "agents directory was created"
  mv "$ROUTE_BINARY.saved" "$ROUTE_BINARY"
}

pending_decision_row() {
  local label="$1"
  run bash -c 'bash "$1" create "$2" session-1 && bash "$1" record-bounded "$2" session-1 Fast' \
    _ "$SCRIPTS_DIR/pending-decision.sh" "$TEST_TEMP_DIR/.meridian"
  expect_case "$label" 2 "direct decision transitions are disabled"
  [ ! -e "$TEST_TEMP_DIR/.meridian/.runtime" ] || record_case_failure "$label" "runtime state was created"
}

@test "agent-generator and pending-decision reject invalid requests, stale routes and mismatched contracts before any mutation" {
  reject_args_row no-args generate "Usage: agent-generator.sh"
  reject_args_row unknown-role generate "invalid role" not-a-role --job do-something
  reject_args_row missing-job generate "--job is required" docs
  reject_args_row no-contract generate_raw "--contract is required" docs --job write-a-readme
  reject_args_row missing-contract-file generate "contract not found" python-engineer --job contract-task \
    --task-id task-1 --contract missing.json --write-allowance src/a.py

  stub_resolver_row stub-resolver-without-set-marker
  host_enum_gap_row host-enum-gap
  stale_fingerprint_row stale-binary-fingerprint

  contract_mismatch_row tampered-digest solo '["src/a.py"]' '.task_identity = "tampered"' - src/a.py "contract digest mismatch"
  contract_mismatch_row task-identity-mismatch solo '["src/a.py"]' . task-2 src/a.py "task identity mismatch"
  contract_mismatch_row extra-allowance solo '["src/a.py"]' . - "src/a.py src/b.py" "write allowances do not match contract"
  contract_mismatch_row subset-allowance solo '["src/a.py","src/b.py"]' . - src/a.py "write allowances do not match contract"
  contract_mismatch_row worker-provenance solo '["src/a.py"]' '.created_by = "worker"' - src/a.py "contract digest mismatch|planned main-session contract"
  contract_mismatch_row pair-missing-role pair '["src/a.py"]' '.roles = ["python-engineer"]' - src/a.py "contract"

  pending_decision_row pending-decision-direct-transition

  assert_no_case_failures
}

naming_row() {
  local label="$1" seed="$2" name
  reset_generated_state
  MERIDIAN_AGENT_RANDOM_SEED="$seed" generate docs --job "write a README"
  expect_case "$label" 0
  name=$(generated_name docs)
  expect_fragment "$label" "SPAWN_READY $name"
  [[ "$name" =~ ^meridian-docs-[a-z0-9]+-[a-z0-9]+-[a-z0-9]+$ ]] || record_case_failure "$label" "name=$name"
  [ -f "$(agent_definition "$name")" ] || record_case_failure "$label" "definition missing for $name"
  expect_manifest_jq "$label" "$name" '.agents | has($name)'
}

deterministic_seed_row() {
  local label="$1" first
  reset_generated_state
  MERIDIAN_AGENT_RANDOM_SEED=42 generate docs --job "first"
  expect_case "$label-first" 0
  first=$(generated_name docs)
  [ -n "$first" ] || record_case_failure "$label-first" "no generated name"
  reset_generated_state
  MERIDIAN_AGENT_RANDOM_SEED=42 generate docs --job "second"
  expect_case "$label" 0 "SPAWN_READY $first"
}

generate_with_question_override() {
  case "$1" in
    empty) generate docs --job "write a README" --disallowed-tools "" --initial-prompt "" ;;
    partial) generate docs --job "write a README" --initial-prompt "Return user_decision_required." ;;
  esac
}

question_override_row() {
  local label="$1" override="$2" pattern="$3" name
  reset_generated_state
  generate_with_question_override "$override"
  expect_case "$label" 0
  name=$(generated_name docs)
  grep -qE -- "$pattern" "$(agent_definition "$name")" 2>/dev/null \
    || record_case_failure "$label" "definition lacks [$pattern]: $(cat "$(agent_definition "$name")" 2>&1)"
}

saved_selector_row() {
  local label="$1" name
  reset_generated_state
  edit_config '.routing.profiles.balanced.roles.architect = {model: "ember-path", reasoning: "swift", status: "resolved"}'
  generate architect --job "build a roadmap"
  expect_case "$label" 0
  name=$(generated_name architect)
  expect_generated_name "$label" "$name"
  expect_manifest_jq "$label" "$name" '.agents[$name].model == "ember-path" and .agents[$name].effort == "swift"'
  expect_definition_has "$label" "$name" 'model: "ember-path"'
  expect_definition_has "$label" "$name" 'effort: "swift"'
  restore_pristine_config
}

default_reasoning_row() {
  local label="$1" name
  reset_generated_state
  edit_config '.routing.profiles.balanced.roles.docs.reasoning = null'
  generate docs --job "write a README"
  expect_case "$label" 0
  name=$(generated_name docs)
  expect_generated_name "$label" "$name"
  [ "$(grep -c '^effort:' "$(agent_definition "$name")" 2>/dev/null)" = "0" ] \
    || record_case_failure "$label" "definition carries an effort line"
  expect_manifest_jq "$label" "$name" '.agents[$name].effort == null'
  restore_pristine_config
}

legacy_catalog_absent_row() {
  local label="$1" isolated="$TEST_TEMP_DIR/plugin" saved_generator="$GENERATOR" name
  reset_generated_state
  mkdir -p "$isolated"
  cp -R "$PROJECT_ROOT/scripts" "$PROJECT_ROOT/templates" "$PROJECT_ROOT/config" "$isolated/"
  GENERATOR="$isolated/scripts/agent-generator.sh"
  generate docs --job "write from saved routing authority"
  GENERATOR="$saved_generator"
  expect_case "$label" 0
  name=$(generated_name docs)
  expect_generated_name "$label" "$name"
  expect_definition_has "$label" "$name" 'model: "nova-route"'
  expect_definition_has "$label" "$name" 'effort: "deliberate"'
}

write_allowance_row() {
  local label="$1" name project_root
  reset_generated_state
  generate python-engineer --job "repair the failing hook" --write-allowance hooks/skill_gate.py
  expect_case "$label" 0
  name=$(generated_name python-engineer)
  expect_generated_name "$label" "$name"
  project_root=$(cd "$TEST_TEMP_DIR" && pwd -P)
  expect_manifest_jq "$label" "$name" '.agents[$name].project_root == $root and .agents[$name].write_allowances == ["hooks/skill_gate.py"]' \
    "$(manifest_path)" "$project_root"
}

max_turns_generation_row() {
  local label="$1" filter="$2" want="$3" name definition lines expected_lines=1
  reset_generated_state
  jq "$filter" "$TEST_TEMP_DIR/.meridian/config.pristine" > "$TEST_TEMP_DIR/.meridian/config.json"

  generate docs --job "write a README"

  expect_case "$label" 0 "SPAWN_READY"
  name=$(generated_name docs)
  definition=$(agent_definition "$name")
  jq -e --arg name "$name" --arg want "$want" '.agents[$name].max_turns == $want' "$(manifest_path)" >/dev/null \
    || record_case_failure "$label" "manifest max_turns differs from [$want]"
  lines=$(grep -c '^maxTurns:' "$definition" || true)
  [ -n "$want" ] || expected_lines=0
  [ "$lines" = "$expected_lines" ] || record_case_failure "$label" "definition has $lines maxTurns lines, want $expected_lines"
  [ -z "$want" ] || [[ "$output" == *"  maxTurns: $want"* ]] \
    || record_case_failure "$label" "SPAWN_READY lacks maxTurns $want output=$output"
  [ -n "$want" ] || [[ "$output" != *maxTurns* ]] \
    || record_case_failure "$label" "SPAWN_READY printed maxTurns for an unlimited agent output=$output"
  restore_pristine_config
}

route_override_row() {
  local label="$1"
  reset_generated_state
  generate architect --job route-job --model ember-path --reasoning swift --max-turns 9
  expect_case "$label" 0
  expect_manifest_jq "$label" architect '[.agents[] | select(.role == "architect")] | any(.model == "ember-path" and .effort == "swift" and .max_turns == "9")'
}

task_contract_writer_row() {
  local label="$1" contract id
  reset_generated_state
  cat > "$TEST_TEMP_DIR/PLAN.md" <<'EOF'
phase: 09
<tasks>
<task><name>wire-contract</name><action>implement</action><verify>tests</verify><done>green</done><strategy>small</strategy><role>python-engineer</role><files>src/a.py</files></task>
</tasks>
EOF
  contract=$(bash "$SCRIPTS_DIR/task-contract.sh" open "$TEST_TEMP_DIR/PLAN.md" "$TEST_TEMP_DIR" wire-contract --team solo --job "wire contract")
  id=$(basename "$contract" .json)
  generate python-engineer --job "wire contract" --task-id "$id" --contract "$contract" --write-allowance src/a.py
  expect_case "$label" 0
  expect_manifest_jq "$label" "$id" '.agents[] | select(.contract_id == $name and .contract_enabled == true)'
}

@test "solo generation renders, registers and names agents and carries saved routes, overrides, turn budgets, allowances and contracts into every artifact" {
  naming_row unseeded ""
  naming_row seeded 42
  deterministic_seed_row seed-repeats-name

  question_override_row empty-denial empty '^disallowedTools: "AskUserQuestion"$'
  question_override_row empty-handoff empty 'user_decision_required'
  question_override_row partial-handoff-contract partial '\\"type\\":\\"user_decision_required\\",\\"question\\":\\"clear user question\\",\\"response_shape\\":\\"bounded choices or freeform\\"'

  saved_selector_row saved-selector-and-reasoning
  default_reasoning_row default-reasoning-omitted
  legacy_catalog_absent_row saved-routes-without-legacy-catalogs
  write_allowance_row exact-repository-write-allowance

  max_turns_generation_row roles-zero '.roles.docs.max_turns = 0' ''
  max_turns_generation_row roles-false '.roles.docs.max_turns = false' ''
  max_turns_generation_row agent-max-turns-zero '. * {agent_max_turns: {docs: 0}}' ''
  max_turns_generation_row agent-max-turns-absolute '. * {agent_max_turns: {docs: 12}, effort: "thorough"}' 12
  max_turns_generation_row roles-scaled-by-effort '. * {roles: {docs: {max_turns: 20}}, effort: "thorough"}' 30

  route_override_row explicit-route-override
  task_contract_writer_row real-task-contract-writer

  assert_no_case_failures
}

issue_schema3() {
  local id="$1" job="$2" capability="$3"
  shift 3
  S3_ID="$id"
  S3_JOB="$job"
  S3_CAPABILITY="$capability"
  S3_ROOT="$TEST_TEMP_DIR/.temporary-agent-runfiles/runs/$id"
  mkdir -p "$S3_ROOT"
  S3_CONTRACT=$(bash "$SCRIPTS_DIR/task-contract.sh" issue "$TEST_TEMP_DIR" "$id" \
    --command team --role web-engineer --team solo --job "$job" \
    --control-root "$S3_ROOT" --write-capability "$capability" "$@")
  S3_ROOT=$(cd -P "$S3_ROOT" && pwd -P)
}

schema3_arguments() {
  S3_ARGUMENTS=(--job "$S3_JOB" --task-id "$(basename "$S3_CONTRACT" .json)"
    --contract "$S3_CONTRACT" --control-root "$S3_ROOT" --write-capability "$S3_CAPABILITY")
}

generate_schema3() {
  schema3_arguments
  generate web-engineer "${S3_ARGUMENTS[@]}" "$@"
}

generate_native_team() {
  schema3_arguments
  run bash "$SCRIPTS_DIR/agent-generator.sh" --native-team web-engineer "${S3_ARGUMENTS[@]}" "$@"
}

schema3_record_row() {
  local label="$1" expression="$2" name
  shift 2
  issue_schema3 "$label" "write the web scope" directory:src/web "$@"
  generate_schema3
  expect_case "$label" 0
  name=$(generated_name web-engineer)
  expect_manifest_jq "$label" "$name" "$expression" "$S3_ROOT/agent-manifest.json" "$S3_ROOT"
  [ -f "$(agent_definition "$name")" ] || record_case_failure "$label" "definition missing for $name"
}

schema3_backend_override_row() {
  local label="$1" contract_backend="$2" override="$3" expected="$4"
  local -a contract_arguments=()
  [ "$contract_backend" = "-" ] || contract_arguments=(--requested-backend "$contract_backend" --resolved-backend "$contract_backend")
  issue_schema3 "$label" "write the web scope" directory:src/web ${contract_arguments[@]+"${contract_arguments[@]}"}
  generate_schema3 --execution-backend "$override"
  expect_case "$label" 1 "$expected"
  [ ! -f "$S3_ROOT/agent-manifest.json" ] || record_case_failure "$label" "manifest was written"
}

schema3_tmux_row() {
  local label="$1" name
  jq -e '."web-engineer".executionBackend == "in_process"' "$PROJECT_ROOT/templates/agent-roles/defaults.json" >/dev/null \
    || record_case_failure "$label" "web-engineer default backend is not in_process"
  issue_schema3 tmux-execution "write the web scope" directory:src/web \
    --requested-backend tmux --resolved-backend tmux
  generate_schema3 --execution-backend tmux
  expect_case "$label" 0
  name=$(generated_name web-engineer)
  expect_generated_name "$label" "$name"
  expect_manifest_jq "$label" "$name" '
    .agents[$name].execution.requested_backend == "tmux"
    and .agents[$name].execution.resolved_backend == "tmux"
    and .agents[$name].execution.role == .agents[$name].role
    and .agents[$name].execution.model == .agents[$name].model
    and .agents[$name].execution.effort == .agents[$name].effort
    and .agents[$name].execution.max_turns == .agents[$name].max_turns
    and .agents[$name].execution.contract_id == .agents[$name].contract_id
    and .agents[$name].execution.contract_digest == .agents[$name].contract_digest
    and .agents[$name].execution.task_identity == .agents[$name].task_identity
    and .agents[$name].execution.tmux_bootstrap.child_identity == $name
    and .agents[$name].execution.tmux_bootstrap.contract_id == .agents[$name].contract_id
    and .agents[$name].execution.tmux_bootstrap.control_root == .agents[$name].control_root
  ' "$S3_ROOT/agent-manifest.json"
  expect_definition_has "$label" "$name" '## TMUX bus loop'
}

native_team_row() {
  local label="$1" name
  issue_schema3 native-definition "implement the scoped task" directory:. \
    --runtime-kind native-team --communication-policy native-team
  generate_native_team
  expect_case "$label" 0
  name=$(generated_name web-engineer)
  expect_generated_name "$label" "$name"
  expect_definition_has "$label" "$name" 'SendMessage'
  expect_definition_has "$label" "$name" 'TaskList'
  expect_definition_has "$label" "$name" 'Write'
  expect_manifest_jq "$label" "$name" '.agents[$name].definition_sha256 != null and .agents[$name].tools != null' "$S3_ROOT/agent-manifest.json"
}

native_team_override_row() {
  local label="$1"
  reset_generated_state
  issue_schema3 native-override "implement the scoped task" directory:.
  generate_native_team --model other-model
  expect_rejected "$label" "native-team definition overrides are not allowed"
  [ "$(agent_file_count)" -eq 0 ] || record_case_failure "$label" "agent file was rendered"
}

@test "schema 3 generation records contract-derived and execution fields in the control-root manifest, renders native-team capabilities, and rejects backend and definition overrides" {
  schema3_record_row control-root '.agents[$name].schema_version == 3 and .agents[$name].control_root == $root and .agents[$name].capabilities == [{access:"write",kind:"directory",path:"src/web"}]'
  schema3_record_row runtime-policy '.agents[$name].runtime_kind == "native-team" and .agents[$name].communication_policy == "native-team"' \
    --runtime-kind native-team --communication-policy native-team
  schema3_record_row in-process-execution '.agents[$name].execution.requested_backend == "in_process" and .agents[$name].execution.resolved_backend == "in_process" and .agents[$name].execution.role == "web-engineer" and .agents[$name].execution.model == .agents[$name].model and .agents[$name].execution.effort == .agents[$name].effort and .agents[$name].execution.max_turns == .agents[$name].max_turns and .agents[$name].execution.contract_id == .agents[$name].contract_id and (.agents[$name].execution | has("tmux_bootstrap") | not)'
  schema3_tmux_row tmux-execution-metadata

  schema3_backend_override_row backend-drift tmux in_process "execution backend override conflicts with contract"
  schema3_backend_override_row invalid-selection - unsupported "invalid execution backend override 'unsupported'"

  native_team_row native-team-definition
  native_team_override_row native-team-definition-override

  assert_no_case_failures
}

seed_solo_agent() {
  local state="$1" name
  generate docs --job "seed the solo agent"
  [ "$status" -eq 0 ] || { echo "seed generation failed: $output" >&2; return 1; }
  name=$(jq -r '.agents | keys[0]' "$(manifest_path)")
  jq --arg name "$name" --arg state "$state" '.agents[$name].state = $state' "$(manifest_path)" > "$(manifest_path).tmp"
  mv "$(manifest_path).tmp" "$(manifest_path)"
}

exclusive_blocked_row() {
  local label="$1" transform="$2" expected="$3"
  reset_generated_state
  seed_solo_agent registered
  jq "$transform" "$(manifest_path)" > "$(manifest_path).tmp"
  mv "$(manifest_path).tmp" "$(manifest_path)"
  generate --pair python-engineer --exclusive --job "must wait for the solo"
  expect_case "$label" 1 "$expected"
  [ "$(jq '.agents | length' "$(manifest_path)")" -eq 1 ] || record_case_failure "$label" "manifest gained an agent"
  [ "$(agent_file_count)" -eq 1 ] || record_case_failure "$label" "agent file count changed"
}

exclusive_admitted_row() {
  local label="$1" state="$2" same registered
  reset_generated_state
  seed_solo_agent "$state"
  generate --pair python-engineer --exclusive --job "start after the solo"
  expect_case "$label" 0
  same=$(jq --arg state "$state" '[.agents[] | select(.state == $state)] | length' "$(manifest_path)")
  registered=$(jq '[.agents[] | select(.state == "registered")] | length' "$(manifest_path)")
  [ "$same" -eq 1 ] || record_case_failure "$label" "$state agents=$same output=$output"
  [ "$registered" -eq 2 ] || record_case_failure "$label" "registered agents=$registered output=$output"
}

trio_scoped_allowance_rejected_row() {
  local label="$1" scoped="$2" expected="$3"
  generate --trio python-engineer --job "add parser coverage" --role-write-allowance "$scoped"
  expect_case "$label" 1 "$expected"
}

@test "pair, trio and exclusive generation register the right roles and allowances within the live-agent capacity and fail closed on blocked or malformed lifecycle states" {
  generate --pair python-engineer --job "build a parser"
  expect_case pair-spawn-lines 0 "ENGINEER: SPAWN_READY meridian-python-engineer-"
  expect_fragment pair-spawn-lines "CRITIC: SPAWN_READY meridian-python-critic-"
  [ "$(printf '%s\n' "$output" | grep -c 'SPAWN_READY')" -eq 2 ] || record_case_failure pair-spawn-lines "SPAWN_READY count is not 2"

  reset_generated_state
  generate --pair python-engineer --job pair-job --pair-role python-critic
  expect_case explicit-pair-role 0
  jq -e '[.agents[].role] | contains(["python-engineer", "python-critic"])' "$(manifest_path)" >/dev/null \
    || record_case_failure explicit-pair-role "roles $(jq -c '[.agents[].role]' "$(manifest_path)")"

  reset_generated_state
  generate --trio python-engineer --job "add parser coverage" \
    --write-allowance src/parser.py \
    --role-write-allowance test-dev:tests/parser.bats
  expect_case trio-test-allowance 0
  jq -e '
    [.agents[] | select(.role == "python-engineer") | .write_allowances] == [["src/parser.py"]]
    and [.agents[] | select(.role == "test-dev") | .write_allowances] == [["tests/parser.bats"]]
    and [.agents[] | select(.role == "python-critic") | .write_allowances] == [[]]
  ' "$(manifest_path)" >/dev/null || record_case_failure trio-test-allowance "allowances $(jq -c '[.agents[] | {role, write_allowances}]' "$(manifest_path)")"

  reset_generated_state
  trio_scoped_allowance_rejected_row critic-role python-critic:reviews/parser.md "only valid for test-dev"
  trio_scoped_allowance_rejected_row test-dev-outside-tests test-dev:src/parser.py "exact repository test path"

  reset_generated_state
  generate --trio python-engineer --job "hold the current build slot"
  expect_case capacity-trio 0
  [ "$(jq '[.agents[] | select(.state == "registered")] | length' "$(manifest_path)")" -eq 3 ] \
    || record_case_failure capacity-trio "registered agents are not 3"
  generate --pair python-engineer --job "must wait for capacity"
  expect_case capacity-pair-rejected 1 "agent cap reached: 4"
  [ "$(jq '.agents | length' "$(manifest_path)")" -eq 3 ] || record_case_failure capacity-pair-rejected "manifest gained agents"

  exclusive_blocked_row solo-registered . "exclusive generation blocked: registered or running agent exists"
  exclusive_blocked_row solo-running '.agents[.agents | keys[0]].state = "running"' "exclusive generation blocked: registered or running agent exists"
  exclusive_admitted_row solo-used used
  exclusive_admitted_row solo-expired expired
  exclusive_blocked_row null-state '.agents[.agents | keys[0]].state = null' "exclusive generation blocked: invalid agent lifecycle state"
  exclusive_blocked_row missing-state 'del(.agents[.agents | keys[0]].state)' "exclusive generation blocked: invalid agent lifecycle state"
  exclusive_blocked_row unknown-state '.agents[.agents | keys[0]].state = "paused"' "exclusive generation blocked: invalid agent lifecycle state"
  exclusive_blocked_row array-entry '.agents[.agents | keys[0]] = []' "exclusive generation blocked: invalid agent lifecycle state"
  exclusive_blocked_row number-entry '.agents[.agents | keys[0]] = 42' "exclusive generation blocked: invalid agent lifecycle state"

  assert_no_case_failures
}
